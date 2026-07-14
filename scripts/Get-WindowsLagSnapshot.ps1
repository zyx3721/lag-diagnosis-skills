[CmdletBinding()]
param(
    [ValidateRange(1, 30)]
    [int]$SampleSeconds = 3,

    [ValidateRange(1, 50)]
    [int]$Top = 12,

    [string]$JsonPath,

    [ValidateRange(1, 72)]
    [int]$EventLookbackHours = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probeErrors = [System.Collections.Generic.List[object]]::new()

function Invoke-Probe {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$Action
    )

    try {
        & $Action
    }
    catch {
        $probeErrors.Add([pscustomobject]@{
            name = $Name
            message = $_.Exception.Message
        })
        $null
    }
}

function Convert-BytesToMiB {
    param([AllowNull()] [object]$Bytes)

    if ($null -eq $Bytes) {
        return $null
    }

    [math]::Round(([double]$Bytes / 1MB), 1)
}

function Get-ProcessSnapshot {
    $snapshot = @{}
    Get-Process -ErrorAction Stop | ForEach-Object {
        if ($null -ne $_.CPU) {
            $snapshot[[string]$_.Id] = [double]$_.CPU
        }
    }
    $snapshot
}

function Get-ProcessRows {
    param(
        [hashtable]$CpuBefore,
        [int]$SampleDurationSeconds,
        [int]$LogicalProcessorCount
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    Get-Process -ErrorAction Stop | ForEach-Object {
        $cpuPercent = $null
        $key = [string]$_.Id
        if ($CpuBefore.ContainsKey($key) -and $null -ne $_.CPU) {
            $cpuSeconds = [double]$_.CPU - [double]$CpuBefore[$key]
            $cpuPercent = [math]::Round(($cpuSeconds / $SampleDurationSeconds / $LogicalProcessorCount) * 100, 1)
        }

        $rows.Add([pscustomobject]@{
            processName = $_.ProcessName
            processId = $_.Id
            cpuPercent = $cpuPercent
            workingSetMiB = Convert-BytesToMiB $_.WorkingSet64
            privateMemoryMiB = Convert-BytesToMiB $_.PrivateMemorySize64
            handleCount = $_.HandleCount
        })
    }
    $rows
}

function Get-WinEventsOrEmpty {
    param([hashtable]$Filter)

    try {
        @(Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop)
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
            @()
        }
        else {
            throw
        }
    }
}

$startedAt = Get-Date
$logicalProcessorCount = [Environment]::ProcessorCount
$cpuBefore = Invoke-Probe -Name 'processCpuBaseline' -Action { Get-ProcessSnapshot }
Start-Sleep -Seconds $SampleSeconds
$processRows = Invoke-Probe -Name 'processes' -Action {
    Get-ProcessRows -CpuBefore $cpuBefore -SampleDurationSeconds $SampleSeconds -LogicalProcessorCount $logicalProcessorCount
}

$operatingSystem = Invoke-Probe -Name 'operatingSystem' -Action {
    Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, LastBootUpTime, TotalVisibleMemorySize, FreePhysicalMemory
}

$computerSystem = Invoke-Probe -Name 'computerSystem' -Action {
    Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object Manufacturer, Model, TotalPhysicalMemory
}

$cpu = Invoke-Probe -Name 'cpu' -Action {
    Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor |
        Where-Object Name -eq '_Total' |
        Select-Object @{ Name = 'percentProcessorTime'; Expression = { [int]$_.PercentProcessorTime } }
}

$system = Invoke-Probe -Name 'system' -Action {
    Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_System |
        Select-Object @{ Name = 'processorQueueLength'; Expression = { [int]$_.ProcessorQueueLength } },
        @{ Name = 'contextSwitchesPerSec'; Expression = { [int]$_.ContextSwitchesPersec } }
}

$memory = Invoke-Probe -Name 'memory' -Action {
    Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory |
        Select-Object @{ Name = 'availableMiB'; Expression = { [int]$_.AvailableMBytes } },
        @{ Name = 'committedMiB'; Expression = { [math]::Round(([double]$_.CommittedBytes / 1MB), 1) } },
        @{ Name = 'commitLimitMiB'; Expression = { [math]::Round(([double]$_.CommitLimit / 1MB), 1) } },
        @{ Name = 'percentCommittedBytesInUse'; Expression = { [int]$_.PercentCommittedBytesInUse } }
}

$volumes = Invoke-Probe -Name 'volumes' -Action {
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' |
        Select-Object DeviceID, VolumeName,
        @{ Name = 'sizeGiB'; Expression = { [math]::Round(([double]$_.Size / 1GB), 1) } },
        @{ Name = 'freeGiB'; Expression = { [math]::Round(([double]$_.FreeSpace / 1GB), 1) } },
        @{ Name = 'freePercent'; Expression = { if ($_.Size -gt 0) { [math]::Round((([double]$_.FreeSpace / [double]$_.Size) * 100), 1) } else { $null } } }
}

$disks = Invoke-Probe -Name 'disks' -Action {
    Get-CimInstance -ClassName Win32_PerfFormattedData_PerfDisk_PhysicalDisk |
        Where-Object Name -ne '_Total' |
        Select-Object Name,
        @{ Name = 'percentDiskTime'; Expression = { [int]$_.PercentDiskTime } },
        @{ Name = 'currentDiskQueueLength'; Expression = { [int]$_.CurrentDiskQueueLength } },
        @{ Name = 'avgDiskSecPerTransferMs'; Expression = { [math]::Round(([double]$_.AvgDisksecPerTransfer * 1000), 2) } },
        @{ Name = 'diskTransfersPerSec'; Expression = { [int]$_.DiskTransfersPersec } }
}

$network = Invoke-Probe -Name 'network' -Action {
    Get-CimInstance -ClassName Win32_PerfFormattedData_Tcpip_NetworkInterface |
        Where-Object { $_.Name -and $_.BytesTotalPersec -ge 0 } |
        Sort-Object BytesTotalPersec -Descending |
        Select-Object -First $Top Name,
        @{ Name = 'bytesTotalPerSec'; Expression = { [int64]$_.BytesTotalPersec } },
        @{ Name = 'outputQueueLength'; Expression = { [int]$_.OutputQueueLength } },
        @{ Name = 'currentBandwidthBitsPerSec'; Expression = { [int64]$_.CurrentBandwidth } }
}

$services = Invoke-Probe -Name 'services' -Action {
    $serviceNames = @('EventLog', 'Schedule', 'Winmgmt', 'WSearch', 'SysMain')
    Get-Service -Name $serviceNames -ErrorAction SilentlyContinue |
        Select-Object Name, DisplayName, Status, StartType
}

$eventStart = (Get-Date).AddHours(-$EventLookbackHours)
$recentEvents = Invoke-Probe -Name 'recentEvents' -Action {
    $systemEvents = Get-WinEventsOrEmpty -Filter @{ LogName = 'System'; StartTime = $eventStart; Level = 2, 3 } |
        Where-Object { $_.ProviderName -match 'disk|stor|ntfs|volmgr|WHEA|Display|Kernel-Power' } |
        Select-Object -First 20
    $applicationEvents = Get-WinEventsOrEmpty -Filter @{ LogName = 'Application'; StartTime = $eventStart; Level = 2 } |
        Select-Object -First 20

    (@($systemEvents) + @($applicationEvents)) |
        Sort-Object TimeCreated -Descending |
        Select-Object TimeCreated, LogName, ProviderName, Id, LevelDisplayName,
        @{ Name = 'message'; Expression = { if ($_.Message) { $_.Message.Substring(0, [math]::Min($_.Message.Length, 500)) } else { $null } } }
}

$topCpu = @($processRows | Where-Object { $null -ne $_.cpuPercent } | Sort-Object cpuPercent -Descending | Select-Object -First $Top)
$topMemory = @($processRows | Sort-Object privateMemoryMiB -Descending | Select-Object -First $Top)

$result = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString('o')
    sampleSeconds = $SampleSeconds
    system = [ordered]@{
        operatingSystem = $operatingSystem
        computer = $computerSystem
        logicalProcessorCount = $logicalProcessorCount
        uptimeHours = if ($operatingSystem -and $operatingSystem.LastBootUpTime) { [math]::Round((((Get-Date) - $operatingSystem.LastBootUpTime).TotalHours), 1) } else { $null }
    }
    cpu = $cpu
    memory = $memory
    systemLoad = $system
    volumes = @($volumes)
    disks = @($disks)
    network = @($network)
    topProcessesByCpu = $topCpu
    topProcessesByMemory = $topMemory
    services = @($services)
    recentEvents = @($recentEvents)
    probeErrors = @($probeErrors)
}

$json = $result | ConvertTo-Json -Depth 8
if ($JsonPath) {
    $directory = Split-Path -Parent $JsonPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Set-Content -LiteralPath $JsonPath -Value $json -Encoding UTF8
}

$json
