#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot,
    [ValidateRange(0.01, 10080)][double]$DurationMinutes,
    [ValidateRange(1, 3600)][int]$IntervalSeconds
)

Set-StrictMode -Version 2.0
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Memory.Common.ps1')
$config = Get-MemoryConfig -ConfigPath (Join-Path $scriptRoot 'config.json')
$paths = Resolve-MemoryPaths -OutputRoot $OutputRoot -Config $config
if (-not $PSBoundParameters.ContainsKey('DurationMinutes')) { $DurationMinutes = [double](Get-ConfigValue $config 'MonitorDurationMinutes' 30) }
if (-not $PSBoundParameters.ContainsKey('IntervalSeconds')) { $IntervalSeconds = [int](Get-ConfigValue $config 'MonitorIntervalSeconds' 30) }
$topCount = [int](Get-ConfigValue $config 'MonitorTopCount' 15)
$sessionId = [guid]::NewGuid().ToString()

Write-MemoryLog -Paths $paths -Message 'Memory monitor started' -Data @{ SessionId = $sessionId; DurationMinutes = $DurationMinutes; IntervalSeconds = $IntervalSeconds; TopCount = $topCount }
$records = New-Object 'System.Collections.Generic.List[object]'
$start = Get-Date
$deadline = $start.AddMinutes($DurationMinutes)
$sampleNumber = 0

do {
    $sampleTime = Get-Date
    $os = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { Write-MemoryLog -Paths $paths -Level WARN -Message 'Monitor OS sample failed' -Data @{ Error = $_.Exception.ToString() } }
    $totalKB = 0.0
    $freeKB = 0.0
    if ($null -ne $os) { $totalKB = [double]$os.TotalVisibleMemorySize; $freeKB = [double]$os.FreePhysicalMemory }
    $usedKB = [math]::Max(($totalKB - $freeKB), 0)
    $usage = if ($totalKB -gt 0) { [math]::Round(($usedKB / $totalKB) * 100, 1) } else { 0 }
    $processes = @()
    try { $processes = @(Get-ProcessSnapshot -Top $topCount -SkipMetadata -LargeProcessMemoryMB 1024 -LongRunningHours 6) }
    catch { Write-MemoryLog -Paths $paths -Level WARN -Message 'Monitor process sample failed' -Data @{ Error = $_.Exception.ToString() } }
    if ($processes.Count -eq 0) {
        [void]$records.Add([pscustomobject]@{ SessionId = $sessionId; SampleNumber = $sampleNumber; Timestamp = $sampleTime.ToString('o'); MemoryUsagePercent = $usage; Name = ''; PID = ''; MemoryMB = 0; PrivateMemoryMB = 0; CPUPercent = 0; SnapshotFlag = '' })
    }
    else {
        foreach ($process in $processes) {
            [void]$records.Add([pscustomobject]@{
                SessionId = $sessionId
                SampleNumber = $sampleNumber
                Timestamp = $sampleTime.ToString('o')
                MemoryUsagePercent = $usage
                Name = $process.Name
                PID = $process.PID
                MemoryMB = $process.MemoryMB
                PrivateMemoryMB = $process.PrivateMemoryMB
                CPUPercent = $process.CPUPercent
                SnapshotFlag = $process.SnapshotFlag
            })
        }
    }
    $sampleNumber++
    if ((Get-Date) -ge $deadline) { break }
    $remainingSeconds = [math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
    if ($remainingSeconds -gt 0) { Start-Sleep -Seconds ([int][math]::Min($IntervalSeconds, $remainingSeconds)) }
} while ((Get-Date) -lt $deadline)

$detailRows = @($records.ToArray())
$analysisRows = @()
foreach ($group in @($detailRows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Name) } | Group-Object Name,PID)) {
    $ordered = @($group.Group | Sort-Object SampleNumber)
    $first = $ordered[0]
    $last = $ordered[$ordered.Count - 1]
    $memoryValues = @($ordered | ForEach-Object { [double]$_.MemoryMB })
    $growth = [math]::Round(([double]$last.MemoryMB - [double]$first.MemoryMB), 1)
    $baseline = [math]::Max(([double]$first.MemoryMB * 0.2), 200)
    $suspected = ($ordered.Count -ge 3 -and $growth -gt $baseline -and [double]$last.MemoryMB -gt 200)
    $analysisRows += [pscustomobject]@{
        Name = $first.Name
        PID = $first.PID
        Samples = $ordered.Count
        FirstMemoryMB = $first.MemoryMB
        LastMemoryMB = $last.MemoryMB
        MinimumMemoryMB = [math]::Round((($memoryValues | Measure-Object -Minimum).Minimum), 1)
        MaximumMemoryMB = [math]::Round((($memoryValues | Measure-Object -Maximum).Maximum), 1)
        GrowthMB = $growth
        SuspectedLeak = if ($suspected) { 'YES - continuous growth candidate' } else { '' }
        Note = 'A trend candidate still requires application-level confirmation.'
    }
}
$analysisRows = @($analysisRows | Sort-Object @{Expression = { [double]$_.GrowthMB }; Descending = $true})

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$detailPath = Join-Path $paths.Reports ('MemoryTrend_{0}.csv' -f $stamp)
$analysisPath = Join-Path $paths.Reports ('MemoryTrendAnalysis_{0}.csv' -f $stamp)
$htmlPath = Join-Path $paths.Reports ('MemoryTrend_{0}.html' -f $stamp)
Write-CsvUtf8 -Rows $detailRows -Path $detailPath
Write-CsvUtf8 -Rows $analysisRows -Path $analysisPath
$html = @(
    '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><title>Memory Trend</title><style>body{font-family:"Microsoft YaHei",Arial,sans-serif;margin:24px;background:#f6f8fa}table{border-collapse:collapse;background:#fff;width:100%;margin-bottom:18px}th,td{border:1px solid #d0d7de;padding:6px 8px;text-align:left}th{background:#eaf2f8}.note{padding:12px;background:#fff8c5;border:1px solid #d4a72c}</style></head><body>',
    ('<h1>内存趋势报告</h1><div class="note">SessionId: {0}<br>采样数: {1}<br>采样间隔（秒）: {2}<br>没有自动结束任何进程。</div>' -f $sessionId, $sampleNumber, $IntervalSeconds),
    (ConvertTo-HtmlTable -Rows $analysisRows -Title '疑似持续增长进程'),
    (ConvertTo-HtmlTable -Rows $detailRows -Title '采样明细'),
    '</body></html>'
) -join [Environment]::NewLine
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText($htmlPath, $html, $utf8Bom)
Write-MemoryLog -Paths $paths -Message 'Memory monitor completed' -Data @{ SessionId = $sessionId; Samples = $sampleNumber; DetailPath = $detailPath; AnalysisPath = $analysisPath; HtmlPath = $htmlPath }
Write-Host ('监控完成。趋势报告: {0}' -f $htmlPath) -ForegroundColor Green

return [pscustomobject]@{ SessionId = $sessionId; Samples = $sampleNumber; DetailPath = $detailPath; AnalysisPath = $analysisPath; HtmlPath = $htmlPath }
