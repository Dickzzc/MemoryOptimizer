#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot,
    [switch]$NoPause
)

Set-StrictMode -Version 2.0
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$checkScript = Join-Path $scriptRoot 'Check-Memory.ps1'
$optimizeScript = Join-Path $scriptRoot 'Optimize-Memory-Safe.ps1'

Write-Host 'MemoryOptimizer：先检测，再由你确认是否执行 A 级安全优化。' -ForegroundColor Cyan
Write-Host '检测阶段不会修改系统，也不会结束进程。'

$beforeOutput = @()
try {
    $beforeOutput = @(& $checkScript -OutputRoot $OutputRoot -NoPause)
}
catch {
    Write-Warning ('检测脚本执行失败: {0}' -f $_.Exception.Message)
}
$before = @($beforeOutput | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['System'] } | Select-Object -Last 1)
if ($before.Count -eq 0) { $before = $null }
else { $before = $before[0] }
if ($null -ne $before) { Write-Host ('检测报告目录: {0}' -f $before.Paths.Reports) }

$answer = Read-Host '是否执行 A 级低风险优化？输入 Y 执行，其他键跳过'
if ($answer -notmatch '^(Y|y|是|yes)$') {
    Write-Host '已跳过优化。建议先查看 MemoryAnalysisReport.html 和 CSV 报告。' -ForegroundColor Yellow
    if (-not $NoPause) { try { [void](Read-Host '按 Enter 结束') } catch { } }
    return
}

try {
    & $optimizeScript -OutputRoot $OutputRoot -Interactive -CreateRestorePoint
}
catch {
    Write-Warning ('安全优化执行失败: {0}' -f $_.Exception.Message)
}

Write-Host '优化后重新采集检测报告。' -ForegroundColor Cyan
$afterOutput = @()
try {
    $afterOutput = @(& $checkScript -OutputRoot $OutputRoot -NoPause)
}
catch {
    Write-Warning ('优化后检测失败: {0}' -f $_.Exception.Message)
}
$after = @($afterOutput | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['System'] } | Select-Object -Last 1)
$afterValid = $false
if ($after.Count -gt 0) {
    $after = $after[0]
    $afterValid = $true
    Write-Host ('优化后报告目录: {0}' -f $after.Paths.Reports)
}
if ($null -ne $before -and $afterValid) {
    $beforeUsed = [double](Get-ObjectPropertyValue $before.System 'UsedMemoryGB' 0)
    $afterUsed = [double](Get-ObjectPropertyValue $after.System 'UsedMemoryGB' 0)
    $released = [math]::Round(($beforeUsed - $afterUsed), 2)
    Write-Host ('已使用内存变化: {0:N2} GB -> {1:N2} GB；快照差值（仅供参考）: {2:N2} GB' -f $beforeUsed, $afterUsed, $released) -ForegroundColor Green
}
Write-Host '脚本不会自动重启电脑。启动项等设置通常下次登录或重新启动应用后生效；如需重启，请先保存工作。' -ForegroundColor Yellow
if (-not $NoPause) { try { [void](Read-Host '按 Enter 结束') } catch { } }
