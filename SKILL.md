---
name: lag-diagnosis-skills
description: "诊断 Windows 或 macOS 电脑、桌面客户端、浏览器或开发平台出现严重卡顿、无响应、频繁转圈、输入延迟、磁盘忙、内存不足或整体变慢的问题。用户提到系统很卡、电脑卡死、Mac 卡顿、平台卡顿、CPU/内存/磁盘占用异常、程序无响应、想排查整机性能、找出哪个进程拖慢电脑、分析近期系统错误时，即使没有明确要求运行诊断，也应使用本技能。"
compatibility: "Windows PowerShell 5.1+（CIM/WMI）或 macOS 自带 Bash 3.2+（sysctl、vm_stat、ps、df、netstat、launchctl、log）；默认只读。"
---

# Windows 与 macOS 卡顿诊断

## 目标与边界

把“卡顿”拆成可验证的系统状态：CPU 饱和、内存压力/分页、磁盘容量或延迟、网络拥塞、异常进程、服务状态或近期系统错误。先获取证据，再给建议；单一高指标不等于根因。

默认流程是只读的。不要擅自结束进程、重启服务、清理文件、修改注册表、禁用启动项、更新驱动或安装工具。任何会改变机器状态的动作都要先说明影响、可逆性与理由，并得到用户针对该动作的批准。

## 运行方式

先识别当前系统，再运行对应的随附脚本。不要在 macOS 上调用 PowerShell 脚本，也不要在 Windows 上调用 Bash 脚本。

Windows 使用 PowerShell 脚本，采集 3 秒性能样本和最近两小时的关键事件：

```powershell
& "$env:USERPROFILE\.codex\skills\lag-diagnosis-skills\scripts\Get-WindowsLagSnapshot.ps1" -JsonPath ".\windows-lag-snapshot.json"
```

若卡顿是间歇性的，先让用户在现象出现时执行，或将采样窗口提高到 8-10 秒：

```powershell
& "$env:USERPROFILE\.codex\skills\lag-diagnosis-skills\scripts\Get-WindowsLagSnapshot.ps1" -SampleSeconds 10 -JsonPath ".\windows-lag-snapshot.json"
```

macOS 使用 Bash 脚本，默认采集 3 秒样本和最近两小时的统一日志：

```bash
bash "$HOME/.codex/skills/lag-diagnosis-skills/scripts/Get-MacOSLagSnapshot.sh" --json-path ./macos-lag-snapshot.json
```

间歇性卡顿可在现象出现时采样，或增加采样窗口：

```bash
bash "$HOME/.codex/skills/lag-diagnosis-skills/scripts/Get-MacOSLagSnapshot.sh" --sample-seconds 10 --json-path ./macos-lag-snapshot.json
```

读取 JSON 后再分析。如果脚本某个 `probeErrors` 项失败，说明该项没有采集到，不要把它当作“正常”；继续基于其他证据，并在报告中指出缺口。macOS 的 `log show` 或部分系统计数器可能受系统版本、隐私权限或沙箱限制。

## 判定方法

优先寻找持续压力或两个以上相互印证的信号。以下阈值用于排序，不是机械结论：

| 类别 | 关注信号 | 高优先级线索 |
|------|----------|--------------|
| CPU | `cpu.percentProcessorTime`、Windows 的 `systemLoad.processorQueueLength`、`topProcessesByCpu` | 总 CPU 连续约 85% 以上，或 Windows 队列长度持续大于逻辑核心数，且有单个进程占用高 |
| 内存 | Windows 的 `memory.percentCommittedBytesInUse`；macOS 的 `availableMiB`、`compressedMiB`、`wiredMiB`、`topProcessesByMemory` | Windows 已提交内存约 85% 以上，或 macOS 空闲内存很低且压缩/有线内存持续增长 |
| 磁盘 | Windows 的 `disks.avgDiskSecPerTransferMs`、`disks.currentDiskQueueLength`；所有系统的卷可用空间 | Windows 延迟持续超过 50 ms 或队列堆积；任一系统盘剩余空间低于约 10% 都应标注。macOS 脚本不推断磁盘延迟。 |
| 网络 | `network.bytesTotalPerSec`、对应应用和症状 | 网络流量高且仅联网操作卡顿；不要把低带宽机器的绝对流量直接视为故障 |
| 进程 | CPU、私有内存、工作集、I/O 与进程名 | 同一进程同时占用 CPU、内存或 I/O，且与用户正在操作的应用相关 |
| 系统 | `recentEvents`、`services`、`uptimeHours` | Windows 的磁盘/驱动错误或 macOS 统一日志中的错误事件，与卡顿时间吻合 |

对于正在运行的性能诊断、杀毒扫描、IDE 编译、虚拟机、容器、同步客户端、Windows Update 或 macOS 系统更新/Spotlight 索引，要明确说明它们可能是短暂负载，先确认是否与用户操作一致。不要仅凭进程名断言恶意或故障。

## 报告格式

按下面结构用简体中文输出，内容应只包含有证据支持的结论：

```markdown
# 设备卡顿诊断

## 摘要
- 健康等级：正常 / 需关注 / 严重
- 最可能瓶颈：...
- 证据：...

## 关键发现
1. [严重度] 现象、指标和时间关联。
2. ...

## 建议顺序
1. 无副作用的确认或等待动作。
2. 需要用户批准的具体操作，并说明影响与回退方式。
3. 何时需要进一步采集、重启或升级处理。

## 采集缺口
- 未采集到的探针、权限限制或不确定性；没有则写“无”。
```

健康等级：没有明显持续压力为“正常”；存在一个明确瓶颈或容量预警为“需关注”；持续资源饱和、磁盘/驱动错误、反复崩溃、macOS kernel panic 线索或系统接近无响应为“严重”。

## 后续处置

- 先做低副作用动作：暂停或等待已知的编译/同步/更新任务、关闭用户确认不需要的应用、在复现时重新采样、比较两次快照。
- 需要释放系统盘空间时，转用 `c-drive-cleanup-skills` 做只读空间诊断；不要手动删除系统目录或缓存。
- 出现磁盘 I/O 错误、控制器重置、持续蓝屏、kernel panic、硬件温度/风扇异常或疑似数据损坏时，优先提醒用户备份重要数据；涉及磁盘检测、驱动或系统变更、硬件维修的动作先征求批准。
- 用户只报告某一个应用卡顿、而整机指标正常时，把范围收窄到该应用的日志、扩展、网络和配置，不要把它包装成整机问题。
