#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot,
    [switch]$NoPause
)

Set-StrictMode -Version 2.0
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Memory.Common.ps1')

$config = Get-MemoryConfig -ConfigPath (Join-Path $scriptRoot 'config.json')
$paths = Resolve-MemoryPaths -OutputRoot $OutputRoot -Config $config
$sessionId = [guid]::NewGuid().ToString()
Write-MemoryLog -Paths $paths -Message 'Check session started' -Data @{ SessionId = $sessionId; OutputRoot = $paths.Root }

$messageConfig = Get-ObjectPropertyValue $config 'Messages' $null
function Get-ReportMessage {
    param([string]$Name, [string]$Fallback)
    $value = Get-ObjectPropertyValue $messageConfig $Name $null
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return $Fallback }
    return [string]$value
}

function Add-InfoLine {
    param([System.Collections.Generic.List[string]]$List, [string]$Name, [object]$Value)
    [void]$List.Add(('{0}: {1}' -f $Name, (ConvertTo-DisplayValue $Value)))
}

function Get-BrowserProcessDetails {
    param([object[]]$Processes)
    $memoryByPid = @{}
    foreach ($process in @($Processes)) {
        if ($null -ne $process -and $null -ne $process.PID) { $memoryByPid[[int]$process.PID] = [double]$process.MemoryMB }
    }
    $cimProcesses = @()
    try { $cimProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.Name -match '^(?i)(chrome|msedge)\.exe$' }) }
    catch { Write-MemoryLog -Paths $paths -Level WARN -Message 'Browser process detail query failed' -Data @{ Error = $_.Exception.ToString() } }
    foreach ($entry in $cimProcesses) {
        $processId = [int]$entry.ProcessId
        $commandLine = [string]$entry.CommandLine
        $typeMatch = [regex]::Match($commandLine, '(?i)--type=([^\s"]+)')
        $processType = if ($typeMatch.Success) { $typeMatch.Groups[1].Value } else { 'browser' }
        $profileMatch = [regex]::Match($commandLine, '(?i)--profile-directory=([^\s"]+)')
        $profileHint = if ($profileMatch.Success) { $profileMatch.Groups[1].Value } else { '' }
        [pscustomobject]@{
            Browser = if ($entry.Name -match '(?i)^chrome') { 'Chrome' } else { 'Edge' }
            PID = $processId
            ParentPID = [int]$entry.ParentProcessId
            MemoryMB = if ($memoryByPid.ContainsKey($processId)) { $memoryByPid[$processId] } else { 0 }
            ProcessType = $processType
            ProfileHint = $profileHint
            UserDataDirectoryArgumentPresent = ($commandLine -match '(?i)--user-data-dir=')
            PossibleExtensionProcess = ($commandLine -match '(?i)extension')
            Notes = if ($processType -eq 'renderer') { 'Renderer usually represents an isolated tab/site; title and extension name require Chrome DevTools/internal pages.' } elseif ($processType -eq 'browser') { 'Browser coordinator process.' } else { 'Browser utility or background process.' }
        }
    }
}

function Write-ReportCsv {
    param([object[]]$Rows, [string]$Path, [string]$Name)
    [void](Invoke-MemorySafe -Name $Name -Paths $paths -ContinueOnError -Action { Write-CsvUtf8 -Rows $Rows -Path $Path })
}

$isAdmin = Test-MemoryAdministrator
if (-not $isAdmin) {
    Write-Warning '当前 PowerShell 不是管理员。检测仍会继续，但部分服务、签名和计划任务信息可能不完整。'
    Write-MemoryLog -Paths $paths -Level WARN -Message 'Not running as administrator; some read-only data may be incomplete' -Data $null
}

$system = Invoke-MemorySafe -Name 'system snapshot' -Paths $paths -ContinueOnError -Action {
    Get-MemorySystemSnapshot -Paths $paths
}
if ($null -eq $system) { $system = [pscustomobject]@{} }

$topCount = [int](Get-ConfigValue $config 'ProcessTopCount' 30)
$largeMB = [int](Get-ConfigValue $config 'LargeProcessMemoryMB' 1024)
$longHours = [int](Get-ConfigValue $config 'LongRunningHours' 6)
$processes = @(Invoke-MemorySafe -Name 'top process snapshot' -Paths $paths -ContinueOnError -Action {
    Get-ProcessSnapshot -Top $topCount -LargeProcessMemoryMB $largeMB -LongRunningHours $longHours
})
if ($null -eq $processes) { $processes = @() }

$allProcesses = @(Invoke-MemorySafe -Name 'application process aggregate' -Paths $paths -ContinueOnError -Action {
    Get-ProcessSnapshot -Top 0 -LargeProcessMemoryMB $largeMB -LongRunningHours $longHours -SkipMetadata
})
if ($null -eq $allProcesses) { $allProcesses = @() }

$applications = @(Invoke-MemorySafe -Name 'application summary' -Paths $paths -ContinueOnError -Action { Get-ApplicationSummary -Processes $allProcesses })
$browserDetails = @(Get-BrowserProcessDetails -Processes $allProcesses)
$startup = @(Invoke-MemorySafe -Name 'startup items' -Paths $paths -ContinueOnError -Action { Get-StartupItems -Paths $paths })
$services = @(Invoke-MemorySafe -Name 'third party services' -Paths $paths -ContinueOnError -Action { Get-ThirdPartyServices -Paths $paths })
$tasks = @(Invoke-MemorySafe -Name 'third party scheduled tasks' -Paths $paths -ContinueOnError -Action { Get-ThirdPartyScheduledTasks -Paths $paths })
if ($null -eq $startup) { $startup = @() }
if ($null -eq $services) { $services = @() }
if ($null -eq $tasks) { $tasks = @() }

$recommendations = @(Invoke-MemorySafe -Name 'recommendations' -Paths $paths -ContinueOnError -Action { Get-MemoryRecommendations -Processes $processes -Applications $applications -StartupItems $startup -SystemSnapshot $system })

$topPath = Join-Path $paths.Reports 'TopMemoryProcesses.csv'
$startupPath = Join-Path $paths.Reports 'StartupItems.csv'
$servicesPath = Join-Path $paths.Reports 'ThirdPartyServices.csv'
$tasksPath = Join-Path $paths.Reports 'ScheduledTasks.csv'
$appsPath = Join-Path $paths.Reports 'ApplicationSummary.csv'
$browserPath = Join-Path $paths.Reports 'BrowserProcessDetails.csv'
$recommendationsPath = Join-Path $paths.Reports 'Recommendations.csv'
$leakPath = Join-Path $paths.Reports 'MemoryLeakCandidates.csv'

Write-ReportCsv -Rows $processes -Path $topPath -Name 'write top process report'
Write-ReportCsv -Rows $startup -Path $startupPath -Name 'write startup report'
Write-ReportCsv -Rows $services -Path $servicesPath -Name 'write service report'
Write-ReportCsv -Rows $tasks -Path $tasksPath -Name 'write scheduled task report'
Write-ReportCsv -Rows $applications -Path $appsPath -Name 'write application report'
Write-ReportCsv -Rows $browserDetails -Path $browserPath -Name 'write browser process report'
Write-ReportCsv -Rows $recommendations -Path $recommendationsPath -Name 'write recommendation report'
Write-ReportCsv -Rows @($allProcesses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.SnapshotFlag) }) -Path $leakPath -Name 'write leak candidate report'

$systemInfoLines = New-Object 'System.Collections.Generic.List[string]'
[void]$systemInfoLines.Add((Get-ReportMessage 'SystemInfoTitle' 'System information'))
[void]$systemInfoLines.Add(('SessionId: {0}' -f $sessionId))
Add-InfoLine $systemInfoLines (Get-ReportMessage 'GeneratedAt' 'Generated at') (Get-Date)
Add-InfoLine $systemInfoLines 'Administrator' $isAdmin
Add-InfoLine $systemInfoLines 'OS' (Get-ObjectPropertyValue $system 'OS' '')
Add-InfoLine $systemInfoLines 'Version' (Get-ObjectPropertyValue $system 'Version' '')
Add-InfoLine $systemInfoLines 'Build' (Get-ObjectPropertyValue $system 'Build' '')
Add-InfoLine $systemInfoLines 'Architecture' (Get-ObjectPropertyValue $system 'Architecture' '')
Add-InfoLine $systemInfoLines (Get-ReportMessage 'TotalMemory' 'Total memory GB') (Get-ObjectPropertyValue $system 'TotalMemoryGB' '')
Add-InfoLine $systemInfoLines (Get-ReportMessage 'UsedMemory' 'Used memory GB') (Get-ObjectPropertyValue $system 'UsedMemoryGB' '')
Add-InfoLine $systemInfoLines (Get-ReportMessage 'FreeMemory' 'Free memory GB') (Get-ObjectPropertyValue $system 'FreeMemoryGB' '')
Add-InfoLine $systemInfoLines (Get-ReportMessage 'Usage' 'Memory usage') (('{0}%' -f (Get-ObjectPropertyValue $system 'MemoryUsagePercent' 0)))
Add-InfoLine $systemInfoLines (Get-ReportMessage 'Uptime' 'Uptime') (Get-ObjectPropertyValue $system 'Uptime' '')
Add-InfoLine $systemInfoLines 'Last boot' (Get-ObjectPropertyValue $system 'LastBoot' '')

$automaticPagefile = Get-ObjectPropertyValue $system 'AutomaticManagedPagefile' $null
$pagefileValue = if ($null -eq $automaticPagefile) { 'Unknown' } elseif ($automaticPagefile) { 'System managed' } else { 'Manual configuration' }
Add-InfoLine $systemInfoLines (Get-ReportMessage 'Pagefile' 'Page file') $pagefileValue
$pageUsage = @(Get-ObjectPropertyValue $system 'PageFileUsage' @())
$pageSettings = @(Get-ObjectPropertyValue $system 'PageFileSettings' @())
foreach ($item in $pageSettings) {
    [void]$systemInfoLines.Add(('PageFileSetting: {0} InitialMB={1} MaximumMB={2}' -f $item.Name, $item.InitialSize, $item.MaximumSize))
}
foreach ($item in $pageUsage) {
    [void]$systemInfoLines.Add(('PageFileUsage: {0} AllocatedMB={1} CurrentMB={2} PeakMB={3}' -f $item.Name, $item.AllocatedBaseSize, $item.CurrentUsage, $item.PeakUsage))
}

$compression = Get-ObjectPropertyValue $system 'MemoryAgent' $null
$compressionText = if ($null -eq $compression) { 'Unavailable' } else { ($compression | Out-String).Trim() }
Add-InfoLine $systemInfoLines (Get-ReportMessage 'Compression' 'Memory compression') $compressionText
Add-InfoLine $systemInfoLines 'Memory compression process count' (Get-ObjectPropertyValue $system 'MemoryCompressionProcessCount' 0)
$disks = @(Get-ObjectPropertyValue $system 'Disks' @())
foreach ($disk in $disks) {
    [void]$systemInfoLines.Add(('Disk {0}: FreeGB={1}; SizeGB={2}' -f $disk.DeviceID, $disk.FreeGB, $disk.SizeGB))
}
$physicalDisks = @(Get-ObjectPropertyValue $system 'PhysicalDisks' @())
foreach ($disk in $physicalDisks) {
    [void]$systemInfoLines.Add(('PhysicalDisk {0}: MediaType={1}; BusType={2}; SizeGB={3}; Health={4}' -f $disk.FriendlyName, $disk.MediaType, $disk.BusType, $disk.SizeGB, (Get-ObjectPropertyValue $disk 'HealthStatus' (Get-ObjectPropertyValue $disk 'Status' ''))))
}
$security = @(Get-ObjectPropertyValue $system 'SecurityProducts' @())
Add-InfoLine $systemInfoLines (Get-ReportMessage 'Security' 'Security products') ($security.Count)
foreach ($product in $security) { [void]$systemInfoLines.Add(('Security: {0}; Path={1}; State={2}' -f $product.displayName, $product.pathToSignedProductExe, $product.productState)) }
$defender = Get-ObjectPropertyValue $system 'Defender' $null
if ($null -ne $defender) { [void]$systemInfoLines.Add(('Defender: {0}' -f (($defender | Out-String).Trim()))) }
$virtualization = Get-ObjectPropertyValue $system 'Virtualization' $null
if ($null -ne $virtualization) {
    Add-InfoLine $systemInfoLines (Get-ReportMessage 'Virtualization' 'Virtualization') (Get-ObjectPropertyValue $virtualization 'RunningProcessCount' 0)
    [void]$systemInfoLines.Add(('WSL status: {0}' -f (Get-ObjectPropertyValue $virtualization 'WslStatus' '')))
    [void]$systemInfoLines.Add(('Docker detected: {0}; VM detected: {1}; Android emulator detected: {2}' -f $virtualization.DockerDetected, $virtualization.VirtualMachineDetected, $virtualization.AndroidEmulatorDetected))
}
[void]$systemInfoLines.Add(('Process rows in top report: {0}' -f @($processes).Count))
[void]$systemInfoLines.Add(('Chrome/Edge process detail rows: {0}; renderer rows: {1}; possible extension rows: {2}' -f @($browserDetails).Count, @($browserDetails | Where-Object { $_.ProcessType -eq 'renderer' }).Count, @($browserDetails | Where-Object { $_.PossibleExtensionProcess }).Count))
[void]$systemInfoLines.Add(('Startup rows: {0}; third-party services: {1}; scheduled tasks: {2}' -f @($startup).Count, @($services).Count, @($tasks).Count))
[void]$systemInfoLines.Add(('Duplicate process names: {0}' -f @($allProcesses | Group-Object Name | Where-Object { $_.Count -gt 1 }).Count))
[void]$systemInfoLines.Add(('Duplicate startup executable paths: {0}' -f @($startup | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) } | Group-Object ExecutablePath | Where-Object { $_.Count -gt 1 }).Count))
[void]$systemInfoLines.Add(('Startup entries whose executable path was not found: {0}' -f @($startup | Where-Object { $_.ResidualCandidate }).Count))
[void]$systemInfoLines.Add(('Third-party services whose executable path was not found: {0}' -f @($services | Where-Object { $_.ResidualCandidate }).Count))
[void]$systemInfoLines.Add(('Scheduled tasks whose executable path was not found: {0}' -f @($tasks | Where-Object { $_.ResidualCandidate }).Count))
[void]$systemInfoLines.Add('Leak detection limitation: a single snapshot cannot prove a memory leak; use Monitor-Memory.ps1 for a trend.')

$systemInfoPath = Join-Path $paths.Reports 'SystemInfo.txt'
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllLines($systemInfoPath, $systemInfoLines.ToArray(), $utf8Bom)

$summaryRows = @(
    [pscustomobject]@{ Metric = (Get-ReportMessage 'TotalMemory' 'Total memory GB'); Value = Get-ObjectPropertyValue $system 'TotalMemoryGB' '' },
    [pscustomobject]@{ Metric = (Get-ReportMessage 'UsedMemory' 'Used memory GB'); Value = Get-ObjectPropertyValue $system 'UsedMemoryGB' '' },
    [pscustomobject]@{ Metric = (Get-ReportMessage 'FreeMemory' 'Free memory GB'); Value = Get-ObjectPropertyValue $system 'FreeMemoryGB' '' },
    [pscustomobject]@{ Metric = (Get-ReportMessage 'Usage' 'Memory usage'); Value = ('{0}%' -f (Get-ObjectPropertyValue $system 'MemoryUsagePercent' 0)) },
    [pscustomobject]@{ Metric = 'Top process rows'; Value = @($processes).Count },
    [pscustomobject]@{ Metric = 'Startup items'; Value = @($startup).Count },
    [pscustomobject]@{ Metric = 'Third-party services'; Value = @($services).Count },
    [pscustomobject]@{ Metric = 'Scheduled tasks'; Value = @($tasks).Count }
)

$htmlParts = New-Object 'System.Collections.Generic.List[string]'
[void]$htmlParts.Add('<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><title>Memory Analysis Report</title><style>body{font-family:"Microsoft YaHei",Arial,sans-serif;margin:24px;background:#f6f8fa;color:#1f2328}h1{color:#0b5394}h2{margin-top:28px;color:#245269}table{border-collapse:collapse;background:#fff;width:100%;margin-bottom:18px}th,td{border:1px solid #d0d7de;padding:6px 8px;text-align:left;vertical-align:top;word-break:break-word}th{background:#eaf2f8}.note{background:#fff8c5;border:1px solid #d4a72c;padding:12px}</style></head><body>')
[void]$htmlParts.Add(('<h1>{0}</h1><div class="note">SessionId: {1}<br>{2}: {3}</div>' -f (Get-ReportMessage 'SummaryTitle' 'Memory analysis report'), $sessionId, (Get-ReportMessage 'GeneratedAt' 'Generated at'), (Get-Date)))
[void]$htmlParts.Add((ConvertTo-HtmlTable -Rows $summaryRows -Title (Get-ReportMessage 'SummaryTitle' 'Summary')))
[void]$htmlParts.Add((ConvertTo-HtmlTable -Rows $applications -Title (Get-ReportMessage 'ApplicationsTitle' 'Applications')))
[void]$htmlParts.Add((ConvertTo-HtmlTable -Rows $browserDetails -Title 'Chrome/Edge 进程明细（不含标签页标题或扩展内容）'))
[void]$htmlParts.Add((ConvertTo-HtmlTable -Rows $processes -Title (Get-ReportMessage 'ProcessTitle' 'Top processes')))
[void]$htmlParts.Add((ConvertTo-HtmlTable -Rows $startup -Title (Get-ReportMessage 'StartupTitle' 'Startup items')))
[void]$htmlParts.Add((ConvertTo-HtmlTable -Rows $services -Title (Get-ReportMessage 'ServicesTitle' 'Third-party services')))
[void]$htmlParts.Add((ConvertTo-HtmlTable -Rows $tasks -Title (Get-ReportMessage 'TasksTitle' 'Scheduled tasks')))
[void]$htmlParts.Add((ConvertTo-HtmlTable -Rows $recommendations -Title (Get-ReportMessage 'RecommendationsTitle' 'Recommendations')))
[void]$htmlParts.Add(('<h2>{0}</h2><p>进程的单次工作集快照不能证明泄漏；签名和发布者读取失败时会明确标记，不会猜测。Windows 核心进程、安全软件、驱动和系统更新不在自动优化范围内。</p>' -f (Get-ReportMessage 'LimitationsTitle' 'Limitations')))
[void]$htmlParts.Add('</body></html>')
$htmlPath = Join-Path $paths.Reports 'MemoryAnalysisReport.html'
[IO.File]::WriteAllText($htmlPath, ($htmlParts -join [Environment]::NewLine), $utf8Bom)

Write-MemoryLog -Paths $paths -Message 'Check session completed' -Data @{ SessionId = $sessionId; Reports = $paths.Reports; MemoryUsagePercent = Get-ObjectPropertyValue $system 'MemoryUsagePercent' 0; TopProcessCount = @($processes).Count }
Write-Host ('检测完成。报告目录: {0}' -f $paths.Reports) -ForegroundColor Green
Write-Host ('HTML报告: {0}' -f $htmlPath)
Write-Host ('日志: {0}' -f $paths.LogFile)

if (-not $NoPause -and $Host.Name -notmatch 'ServerRemoteHost') {
    try { [void](Read-Host '按 Enter 结束') } catch { }
}

return [pscustomobject]@{
    SessionId = $sessionId
    Paths = $paths
    System = $system
    Processes = $processes
    Applications = $applications
    Startup = $startup
    Services = $services
    Tasks = $tasks
    Recommendations = $recommendations
    Reports = @($systemInfoPath, $topPath, $startupPath, $servicesPath, $tasksPath, $htmlPath, $browserPath)
}
