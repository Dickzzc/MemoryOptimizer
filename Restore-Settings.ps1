#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot,
    [string]$BackupFile,
    [datetime]$BackupDate,
    [switch]$Interactive,
    [switch]$NoPause
)

Set-StrictMode -Version 2.0
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Memory.Common.ps1')
$config = Get-MemoryConfig -ConfigPath (Join-Path $scriptRoot 'config.json')
$paths = Resolve-MemoryPaths -OutputRoot $OutputRoot -Config $config
$sessionId = [guid]::NewGuid().ToString()
$interactiveMode = $true
if ($PSBoundParameters.ContainsKey('Interactive')) { $interactiveMode = [bool]$Interactive }
if ($null -eq $BackupDate) { $BackupDate = [datetime]::MinValue }

function Resolve-BackupFile {
    param([string]$RequestedPath, [datetime]$RequestedDate, [object]$Paths)
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidate = $RequestedPath
        if (-not [IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $Paths.Backup $candidate }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
        throw "Backup file was not found: $candidate"
    }
    $files = @(Get-ChildItem -LiteralPath $Paths.Backup -Filter 'Backup_*.json' -File -ErrorAction Stop | Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) { throw "No Backup_*.json files were found in $($Paths.Backup)" }
    if ($RequestedDate -ne [datetime]::MinValue) {
        $sameDay = @($files | Where-Object { $_.LastWriteTime.Date -eq $RequestedDate.Date })
        if ($sameDay.Count -eq 0) { throw "No backup was found for date $($RequestedDate.ToString('yyyy-MM-dd'))" }
        return $sameDay[0].FullName
    }
    return $files[0].FullName
}

Write-MemoryLog -Paths $paths -Message 'Restore session started' -Data @{ SessionId = $sessionId; RequestedBackup = $BackupFile; RequestedDate = if ($BackupDate -eq [datetime]::MinValue) { '' } else { $BackupDate.ToString('o') } }
$reportLines = New-Object 'System.Collections.Generic.List[string]'
[void]$reportLines.Add('MemoryOptimizer restore report')
[void]$reportLines.Add(('SessionId: {0}' -f $sessionId))
[void]$reportLines.Add(('GeneratedAt: {0}' -f (Get-Date).ToString('o')))
$changed = 0
$failed = 0

try {
    $selectedBackup = Resolve-BackupFile -RequestedPath $BackupFile -RequestedDate $BackupDate -Paths $paths
    [void]$reportLines.Add(('BackupFile: {0}' -f $selectedBackup))
    $backup = Get-Content -LiteralPath $selectedBackup -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($interactiveMode) {
        $answer = Read-Host '将恢复该备份中的启动项和临时文件。输入 YES 确认'
        if ($answer -cne 'YES') {
            [void]$reportLines.Add('Cancelled by user.')
            Write-MemoryLog -Paths $paths -Message 'Restore confirmation declined' -Data @{ BackupFile = $selectedBackup }
            $failed = 0
            $changed = 0
        }
        else {
            foreach ($record in @(Get-ObjectPropertyValue $backup 'RegistryChanges' @())) {
                try {
                    $registryPath = [string]$record.RegistryPath
                    $name = [string]$record.Name
                    if (-not $registryPath.StartsWith('Registry::HKEY_', [StringComparison]::OrdinalIgnoreCase)) { throw "Unsupported registry provider path: $registryPath" }
                    New-Item -ItemType Directory -Path $registryPath -Force -ErrorAction Stop | Out-Null
                    New-ItemProperty -Path $registryPath -Name $name -Value ([string]$record.Value) -PropertyType String -Force -ErrorAction Stop | Out-Null
                    [void]$reportLines.Add(('Restored registry value: {0} {1}' -f $registryPath, $name))
                    Write-MemoryLog -Paths $paths -Message 'Restored startup registry value' -Data @{ RegistryPath = $registryPath; Name = $name }
                    $changed++
                }
                catch {
                    $failed++
                    [void]$reportLines.Add(('FAILED registry restore: {0}' -f $_.Exception.Message))
                    Write-MemoryLog -Paths $paths -Level ERROR -Message 'Registry restore failed' -Data @{ Error = $_.Exception.ToString() }
                }
            }
            foreach ($record in @(Get-ObjectPropertyValue $backup 'TempMoves' @())) {
                try {
                    $source = [string]$record.BackupPath
                    $destination = [string]$record.OriginalPath
                    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Backup temp file not found: $source" }
                    if (Test-Path -LiteralPath $destination) { throw "Original path already exists; refusing to overwrite: $destination" }
                    $destinationDirectory = Split-Path -Parent $destination
                    New-Item -ItemType Directory -Path $destinationDirectory -Force -ErrorAction Stop | Out-Null
                    Move-Item -LiteralPath $source -Destination $destination -ErrorAction Stop
                    [void]$reportLines.Add(('Restored temp file: {0}' -f $destination))
                    Write-MemoryLog -Paths $paths -Message 'Restored temp file' -Data @{ Source = $source; Destination = $destination }
                    $changed++
                }
                catch {
                    $failed++
                    [void]$reportLines.Add(('FAILED temp restore: {0}' -f $_.Exception.Message))
                    Write-MemoryLog -Paths $paths -Level ERROR -Message 'Temp restore failed' -Data @{ Error = $_.Exception.ToString() }
                }
            }
        }
    }
    else {
        [void]$reportLines.Add('Interactive confirmation was disabled; no changes were made.')
        Write-MemoryLog -Paths $paths -Level WARN -Message 'Restore skipped because Interactive was false' -Data @{ BackupFile = $selectedBackup }
    }
    [void]$reportLines.Add(('Changed: {0}; Failed: {1}' -f $changed, $failed))
    [void]$reportLines.Add('Restart: normally not required for restored startup values; restart or relaunch the affected application to verify. System Restore may require a restart if used separately.')
}
catch {
    $failed++
    [void]$reportLines.Add(('FAILED restore session: {0}' -f $_.Exception.Message))
    Write-MemoryLog -Paths $paths -Level ERROR -Message 'Restore session failed' -Data @{ Error = $_.Exception.ToString() }
}

$reportPath = Join-Path $paths.Reports ('RestoreReport_{0}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllLines($reportPath, $reportLines.ToArray(), $utf8Bom)
Write-MemoryLog -Paths $paths -Message 'Restore session completed' -Data @{ SessionId = $sessionId; ReportPath = $reportPath; Changed = $changed; Failed = $failed }
Write-Host ('恢复处理完成。报告: {0}' -f $reportPath) -ForegroundColor Green
if ($failed -gt 0) { Write-Warning ('有 {0} 项恢复失败；请查看报告和日志。' -f $failed) }
else { Write-Host '没有报告恢复错误。' }

if (-not $NoPause -and $Host.Name -notmatch 'ServerRemoteHost') {
    try { [void](Read-Host '按 Enter 结束') } catch { }
}

return [pscustomobject]@{ SessionId = $sessionId; ReportPath = $reportPath; Changed = $changed; Failed = $failed }
