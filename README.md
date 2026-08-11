# MemoryOptimizer

这是一个只使用 Windows PowerShell 5.1/PowerShell 7 内置能力的内存诊断与低风险优化工具。它遵循“先检测、再分析、后优化”：检测阶段只读；安全优化只处理用户明确确认的第三方注册表启动项和超过保留期限的临时文件；不会通过清空工作集制造虚假的内存下降。

仓库根目录的 `MemoryOptimizer.exe` 是一个 .NET 8、Windows x64、自包含单文件启动器。正常启动时它请求管理员权限，并调用同目录的 `Start-MemoryOptimizer.ps1`；PowerShell 脚本仍是实际诊断和优化引擎，因此不依赖本机安装 Excel 或第三方 PowerShell 模块。启动器自检可使用 `MemoryOptimizer.exe --validate`，该参数不会请求管理员权限。

## 目录

```text
MemoryOptimizer/
├─ README.md
├─ Memory.Common.ps1
├─ Check-Memory.ps1
├─ Optimize-Memory-Safe.ps1
├─ Restore-Settings.ps1
├─ Monitor-Memory.ps1
├─ Start-MemoryOptimizer.ps1
├─ MemoryOptimizer.exe
├─ MemoryOptimizer.Launcher.csproj
├─ Program.cs
├─ app.manifest
├─ Start-MemoryOptimizer.bat
├─ Restore-MemorySettings.bat
├─ config.json
├─ Logs/
├─ Reports/
├─ Backup/
└─ Tests/Run-Tests.ps1
```

## 首次使用

1. 右键 `Start-MemoryOptimizer.bat`，选择“以管理员身份运行”。脚本会先生成检测报告，再询问是否执行 A 级低风险优化。
2. 建议先单独执行只读检测：

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\Check-Memory.ps1 -NoPause
   ```

3. 查看报告后，先做 DryRun：

   ```powershell
   .\Optimize-Memory-Safe.ps1 -DryRun -Interactive:$false -SkipBrowserOptimization
   ```

4. 确认报告中的启动项和临时文件后，再运行实际优化。实际优化默认需要交互确认，并建议使用系统还原点：

   ```powershell
   .\Optimize-Memory-Safe.ps1 -Interactive -CreateRestorePoint
   ```

5. 监控疑似泄漏：

   ```powershell
   .\Monitor-Memory.ps1 -DurationMinutes 30 -IntervalSeconds 30
   ```

## 报告位置

默认报告根目录是 `C:\MemoryOptimization`，包含 `Reports`、`Logs` 和 `Backup`。如果系统权限或磁盘策略不允许创建该目录，脚本会记录原因，并回退到本项目的 `Reports`、`Logs`、`Backup` 目录，不会静默失败。

主要文件：

- `SystemInfo.txt`：系统版本、架构、物理内存、页面文件、内存压缩、系统盘空间、安全软件、WSL/Docker/虚拟机/模拟器状态。
- `TopMemoryProcesses.csv`：前 30 个进程，包含 PID、工作集、私有内存、CPU、路径、启动时间、实例数、发布者和签名状态。
- `StartupItems.csv`：启动项及其来源、路径、发布者和签名状态。
- `ThirdPartyServices.csv`：当前运行的第三方服务，检测结果不等于可以直接禁用。
- `ScheduledTasks.csv`：可能自动启动第三方软件的计划任务。
- `ApplicationSummary.csv`：Chrome、Edge、微信、Office、VS Code、Codex 以及 WSL/Docker/虚拟机/模拟器的进程数和内存总量。
- `BrowserProcessDetails.csv`：Chrome/Edge 的 renderer、browser、utility 进程、PID、内存和可能的扩展进程提示；不记录完整命令行，不会猜测标签页标题或扩展名称。
- `MemoryAnalysisReport.html`：中文汇总表和风险说明。
- `MemoryLeakCandidates.csv`：只标记“单次快照高占用/长期运行”的候选，不能单凭它认定泄漏。

## 安全边界

- 不结束 Windows 核心进程，不禁用 Defender，不禁用 Windows Update，不关闭驱动或安全软件。
- 不删除桌面、下载、文档、图片、视频、代码仓库、浏览器用户数据、微信聊天记录或 Office 文件。
- 不卸载软件，不修改未知第三方程序，不修改注册表优化项，不关闭虚拟内存，不改变页面文件配置。
- 启动项优化只针对报告中列出的第三方 `Run/RunOnce` 注册表值，并在移除前写入 `Backup\Backup_*.json`。
- 临时清理默认只处理 `%TEMP%`/`%TMP%` 中超过 7 天的文件，实际操作是移动到 `Backup\TempCleanup_*`，不是永久删除。
- 任何文件被占用、权限不足或恢复目标已经存在时都会记录具体错误并继续其他项目。
- `-Interactive:$false` 会跳过实际修改；`-DryRun` 只统计将要处理的对象。

## 参数

`Optimize-Memory-Safe.ps1` 支持：

```text
-DryRun
-Interactive
-CreateRestorePoint
-SkipBrowserOptimization
-SkipStartupOptimization
-SkipTempCleanup
-TempCleanupAgeDays 7
-OutputRoot C:\MemoryOptimization
```

`Check-Memory.ps1` 支持 `-OutputRoot` 和 `-NoPause`。`Monitor-Memory.ps1` 支持 `-DurationMinutes`、`-IntervalSeconds` 和 `-OutputRoot`。配置默认值位于 `config.json`。

## 恢复

默认恢复最新备份并要求输入 `YES`：

```powershell
.\Restore-Settings.ps1
```

恢复指定文件或日期：

```powershell
.\Restore-Settings.ps1 -BackupFile 'Backup_20260802_120000_ab12cd34.json'
.\Restore-Settings.ps1 -BackupDate '2026-08-02'
```

恢复会继续处理其他项目，即使某项失败；报告写入 `RestoreReport_*.txt`。启动项恢复通常不需要重启，但建议重新启动受影响的软件或在方便时重启验证。系统还原点由 Windows 自身决定是否需要重启。

## Chrome 专项检查

脚本不会自动删除扩展、标签页、历史记录、密码或登录状态。请在 Chrome 中人工检查：

```text
chrome://settings/performance
chrome://extensions/
chrome://memory-internals/
chrome://system/
```

重点观察 Chrome 进程总数、单个标签页/扩展、多个用户配置文件、关闭后继续后台运行的网页应用，以及来源不明的扩展。内存节省模式、限制后台运行和停用不使用的扩展应由你逐项确认。

## 虚拟内存

工具只检测页面文件，不自动关闭或改小页面文件。默认建议保持“由系统自动管理分页文件大小”。只有在系统盘空间、崩溃转储或特定应用有明确证据时，才应由管理员手动调整，并记录初始/最大值、风险和恢复方法；这类操作通常需要重启，本工具不会自动执行。

## 风险分级

- A 级：退出不用的软件、确认后禁用第三方启动项、移动旧临时文件、人工调整浏览器标签页和扩展。
- B 级：将第三方服务改为手动、调整计划任务、限制 WSL/Docker/虚拟机、手动设置页面文件。当前版本只给出证据和建议，不自动执行这些修改。
- C 级：注册表清理、禁用系统服务、删除系统组件、关闭内存压缩或安全功能。当前版本不执行，也不建议在没有厂商/微软文档和恢复介质时尝试。

## 验证脚本

在项目目录运行：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Tests\Run-Tests.ps1
```

测试会解析全部 PowerShell 脚本，执行短时只读检测、DryRun 和短时监控，确认报告、日志、CSV 与 HTML 可以生成。测试不会禁用启动项，也不会删除文件。

## 构建启动器

需要 .NET 8 SDK。在项目目录执行以下命令即可重新发布 Windows x64 自包含单文件 EXE：

```powershell
dotnet publish .\MemoryOptimizer.Launcher.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:PublishTrimmed=false -o .\artifacts\win-x64
Copy-Item .\artifacts\win-x64\MemoryOptimizer.exe .\MemoryOptimizer.exe -Force
```

`artifacts`、`bin` 和 `obj` 是构建中间目录，不应提交；根目录的 `MemoryOptimizer.exe` 是随仓库发布的可直接运行文件。
