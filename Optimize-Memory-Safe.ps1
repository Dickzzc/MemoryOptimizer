#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot,
    [switch]$DryRun,
    [switch]$Interactive,
    [switch]$CreateRestorePoint,
    [switch]$SkipBrowserOptimization,
    [switch]$SkipStartupOptimization,
    [switch]$SkipTempCleanup,
    [ValidateRange(1, 3650)][int]$TempCleanupAgeDays
)

Set-StrictMode -Version 2.0
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Memory.Common.ps1')
$config = Get-MemoryConfig -ConfigPath (Join-Path $scriptRoot 'config.json')
$paths = Resolve-MemoryPaths -OutputRoot $OutputRoot -Config $config
$sessionId = [guid]::NewGuid().ToString()
$interactiveMode = $true
if ($PSBoundParameters.ContainsKey('Interactive')) { $interactiveMode = [bool]$Interactive }
if (-not $PSBoundParameters.ContainsKey('TempCleanupAgeDays')) {
    $TempCleanupAgeDays = [int](Get-ConfigValue $config 'TempCleanupAgeDays' 7)
}

function Confirm-MemoryAction {
    param([string]$Prompt, [switch]$SecondConfirmation)
    if ($DryRun) { return $true }
    if (-not $interactiveMode) { return $false }
    $answer = Read-Host $Prompt
    if ($SecondConfirmation) { return ($answer -ceq 'YES') }
    return ($answer -match '^(Y|y|是|yes)$')
}

function Add-BackupRecord {
    param([object]$Backup, [string]$Property, [object]$Record)
    $current = Get-ObjectPropertyValue $Backup $Property @()
    $Backup.$Property = @($current) + @($Record)
}

$backup = [ordered]@{
    Version = 1
    SessionId = $sessionId
    CreatedAt = (Get-Date).ToString('o')
    DryRun = [bool]$DryRun
    RegistryChanges = @()
    TempMoves = @()
    RestorePointCreated = $false
}

Write-MemoryLog -Paths $paths -Message 'Safe optimization session started' -Data @{ SessionId = $sessionId; DryRun = [bool]$DryRun; Interactive = $interactiveMode }
if (-not (Test-MemoryAdministrator)) {
    Write-Warning '当前不是管理员。用户级启动项和临时目录仍可尝试，系统级启动项可能失败；脚本会记录每项错误。'
    Write-MemoryLog -Paths $paths -Level WARN -Message 'Optimization is not elevated' -Data $null
}

if ($CreateRestorePoint) {
    if ($DryRun) {
        Write-Host '[DryRun] 将尝试创建系统还原点。' -ForegroundColor Yellow
        Write-MemoryLog -Paths $paths -Level DRYRUN -Message 'Would create a restore point' -Data $null
    }
    elseif (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue) {
        try {
            Checkpoint-Computer -Description ('ExcelRowMatcher MemoryOptimizer {0}' -f (Get-Date -Format 'yyyyMMddHHmmss')) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            $backup.RestorePointCreated = $true
            Write-MemoryLog -Paths $paths -Message 'System restore point created' -Data $null
        }
        catch {
            Write-Warning ('创建系统还原点失败，继续执行可恢复的文件/启动项备份: {0}' -f $_.Exception.Message)
            Write-MemoryLog -Paths $paths -Level WARN -Message 'System restore point failed' -Data @{ Error = $_.Exception.ToString() }
        }
    }
    else {
        Write-Warning '当前系统没有 Checkpoint-Computer，无法创建系统还原点。'
        Write-MemoryLog -Paths $paths -Level WARN -Message 'Checkpoint-Computer is unavailable' -Data $null
    }
}

if ($SkipStartupOptimization) {
    Write-Host '已跳过启动项优化。'
    Write-MemoryLog -Paths $paths -Message 'Startup optimization skipped by parameter' -Data $null
}
else {
    $startupItems = @(Get-StartupItems -Paths $paths)
    $candidates = @($startupItems | Where-Object { $_.Source -eq 'Registry' -and $_.IsCandidate })
    if ($candidates.Count -eq 0) {
        Write-Host '未发现可以安全列出供人工确认的第三方注册表启动项。'
        Write-MemoryLog -Paths $paths -Message 'No actionable startup candidates found' -Data $null
    }
    else {
        Write-Host '第三方注册表启动项候选（不会自动判断为恶意）：' -ForegroundColor Cyan
        for ($index = 0; $index -lt $candidates.Count; $index++) {
            $item = $candidates[$index]
            Write-Host ('[{0}] {1} | {2} | {3} | Publisher={4} | Signature={5}' -f ($index + 1), $item.Name, $item.Location, $item.Command, $item.Publisher, $item.SignatureStatus)
        }
        if ($DryRun) {
            Write-Host ('[DryRun] 将显示 {0} 个候选，实际不会删除启动项。' -f $candidates.Count) -ForegroundColor Yellow
            Write-MemoryLog -Paths $paths -Level DRYRUN -Message 'Would review registry startup candidates' -Data @{ Count = $candidates.Count }
        }
        elseif (-not $interactiveMode) {
            Write-Host '未指定交互确认，启动项保持不变。' -ForegroundColor Yellow
            Write-MemoryLog -Paths $paths -Level WARN -Message 'Startup changes skipped because Interactive was false' -Data @{ Count = $candidates.Count }
        }
        else {
            $selection = Read-Host '输入要禁用的编号（逗号分隔），直接回车跳过'
            $selectedIndexes = @()
            foreach ($token in ($selection -split '[,;\s]+')) {
                $number = 0
                if ([int]::TryParse($token, [ref]$number) -and $number -ge 1 -and $number -le $candidates.Count) { $selectedIndexes += ($number - 1) }
            }
            $selectedIndexes = @($selectedIndexes | Sort-Object -Unique)
            if ($selectedIndexes.Count -gt 0 -and (Confirm-MemoryAction '将禁用所选启动项。输入 YES 确认：' -SecondConfirmation)) {
                foreach ($index in $selectedIndexes) {
                    $item = $candidates[$index]
                    try {
                        $property = Get-ItemProperty -LiteralPath $item.RegistryPath -Name $item.Name -ErrorAction Stop
                        $value = $property.PSObject.Properties[$item.Name].Value
                        $record = [pscustomobject]@{
                            RegistryPath = $item.RegistryPath
                            Name = $item.Name
                            Value = [string]$value
                            ValueKind = 'String'
                            Action = 'Remove-ItemProperty'
                        }
                        Add-BackupRecord -Backup $backup -Property 'RegistryChanges' -Record $record
                        if ($DryRun) {
                            Write-MemoryLog -Paths $paths -Level DRYRUN -Message 'Would remove startup registry value' -Data $record
                        }
                        else {
                            Remove-ItemProperty -LiteralPath $item.RegistryPath -Name $item.Name -ErrorAction Stop
                            Write-MemoryLog -Paths $paths -Message 'Removed startup registry value' -Data $record
                        }
                    }
                    catch {
                        Write-Warning ('启动项 {0} 处理失败: {1}' -f $item.Name, $_.Exception.Message)
                        Write-MemoryLog -Paths $paths -Level ERROR -Message 'Startup item action failed' -Data @{ Name = $item.Name; RegistryPath = $item.RegistryPath; Error = $_.Exception.ToString() }
                    }
                }
            }
            else {
                Write-MemoryLog -Paths $paths -Message 'No startup items selected or confirmation declined' -Data $null
            }
        }
    }
}

if ($SkipBrowserOptimization) {
    Write-Host '已跳过浏览器专项提示。'
    Write-MemoryLog -Paths $paths -Message 'Browser guidance skipped by parameter' -Data $null
}
else {
    $chrome = @(Get-Process -Name chrome -ErrorAction SilentlyContinue)
    $edge = @(Get-Process -Name msedge -ErrorAction SilentlyContinue)
    Write-Host ('浏览器进程：Chrome={0}，Edge={1}。脚本不会删除扩展或浏览器用户数据。' -f $chrome.Count, $edge.Count) -ForegroundColor Cyan
    Write-Host '请在浏览器中人工检查：chrome://settings/performance、chrome://extensions/、chrome://memory-internals/、chrome://system/'
    Write-MemoryLog -Paths $paths -Message 'Browser guidance displayed; no browser data changed' -Data @{ ChromeProcessCount = $chrome.Count; EdgeProcessCount = $edge.Count }
}

if ($SkipTempCleanup) {
    Write-Host '已跳过临时文件清理。'
    Write-MemoryLog -Paths $paths -Message 'Temporary cleanup skipped by parameter' -Data $null
}
else {
    $tempRoots = @($env:TEMP, $env:TMP) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object -Unique
    $cutoff = (Get-Date).AddDays(-1 * $TempCleanupAgeDays)
    $tempFiles = @()
    $seenFiles = @{}
    foreach ($tempRoot in $tempRoots) {
        if (-not (Test-Path -LiteralPath $tempRoot -PathType Container)) { continue }
        try {
            foreach ($file in @(Get-ChildItem -LiteralPath $tempRoot -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff })) {
                $key = $file.FullName.ToLowerInvariant()
                if (-not $seenFiles.ContainsKey($key)) { $seenFiles[$key] = $true; $tempFiles += $file }
            }
        }
        catch {
            Write-MemoryLog -Paths $paths -Level WARN -Message 'Enumerating temp files failed' -Data @{ Root = $tempRoot; Error = $_.Exception.ToString() }
        }
    }
    $totalMeasure = $tempFiles | Measure-Object -Property Length -Sum
    $totalBytes = 0.0
    if ($null -ne $totalMeasure -and $null -ne $totalMeasure.Sum) { $totalBytes = [double]$totalMeasure.Sum }
    if ($tempFiles.Count -gt 0 -and -not $DryRun) {
        $previewCount = [math]::Min(20, $tempFiles.Count)
        for ($previewIndex = 0; $previewIndex -lt $previewCount; $previewIndex++) {
            Write-Host ('  待处理: {0} ({1:N1} MB)' -f $tempFiles[$previewIndex].FullName, ([double]$tempFiles[$previewIndex].Length / 1MB))
        }
        if ($tempFiles.Count -gt $previewCount) { Write-Host ('  ...还有 {0} 个文件未逐项显示。' -f ($tempFiles.Count - $previewCount)) }
    }
    if ($tempFiles.Count -eq 0) {
        Write-Host '没有找到超过保留期限的临时文件。'
        Write-MemoryLog -Paths $paths -Message 'No eligible temporary files found' -Data @{ AgeDays = $TempCleanupAgeDays }
    }
    elseif ($DryRun) {
        $previewCount = [math]::Min(20, $tempFiles.Count)
        for ($previewIndex = 0; $previewIndex -lt $previewCount; $previewIndex++) {
            Write-Host ('  [DryRun] {0} ({1:N1} MB)' -f $tempFiles[$previewIndex].FullName, ([double]$tempFiles[$previewIndex].Length / 1MB))
        }
        if ($tempFiles.Count -gt $previewCount) { Write-Host ('  [DryRun] ...还有 {0} 个文件未逐项显示。' -f ($tempFiles.Count - $previewCount)) }
        Write-Host ('[DryRun] 将处理 {0} 个临时文件，约 {1:N1} MB；实际不会移动或删除。' -f $tempFiles.Count, ($totalBytes / 1MB)) -ForegroundColor Yellow
        Write-MemoryLog -Paths $paths -Level DRYRUN -Message 'Would move old temporary files to backup' -Data @{ Count = $tempFiles.Count; SizeMB = [math]::Round(($totalBytes / 1MB), 1); AgeDays = $TempCleanupAgeDays }
    }
    elseif (-not $interactiveMode) {
        Write-Host '未指定交互确认，临时文件保持不变。' -ForegroundColor Yellow
        Write-MemoryLog -Paths $paths -Level WARN -Message 'Temporary cleanup skipped because Interactive was false' -Data @{ Count = $tempFiles.Count }
    }
    elseif (Confirm-MemoryAction ('将把 {0} 个超过 {1} 天的临时文件移动到备份目录（不删除）。输入 Y 确认：' -f $tempFiles.Count, $TempCleanupAgeDays)) {
        $tempBackupRoot = Join-Path $paths.Backup ('TempCleanup_{0}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        New-Item -ItemType Directory -Path $tempBackupRoot -Force | Out-Null
        foreach ($file in $tempFiles) {
            $record = $null
            try {
                $root = $tempRoots | Where-Object { $file.FullName.StartsWith($_.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
                if ([string]::IsNullOrWhiteSpace($root)) { continue }
                $relative = $file.FullName.Substring($root.TrimEnd('\').Length).TrimStart('\')
                $destination = Join-Path $tempBackupRoot (Join-Path ([IO.Path]::GetFileName($root)) $relative)
                $destinationDirectory = Split-Path -Parent $destination
                New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
                $record = [pscustomobject]@{ OriginalPath = $file.FullName; BackupPath = $destination; Length = [long]$file.Length; LastWriteTime = $file.LastWriteTime.ToString('o'); Status = 'Planned' }
                Add-BackupRecord -Backup $backup -Property 'TempMoves' -Record $record
                Write-MemoryLog -Paths $paths -Message 'Temp file move planned' -Data $record
                Move-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction Stop
                $record.Status = 'Moved'
                Write-MemoryLog -Paths $paths -Message 'Moved old temp file to reversible backup' -Data $record
            }
            catch {
                if ($null -ne $record) { $record.Status = 'Failed' }
                Write-MemoryLog -Paths $paths -Level WARN -Message 'Temp file move failed; skipped' -Data @{ Path = $file.FullName; Error = $_.Exception.ToString() }
            }
        }
    }
    else {
        Write-MemoryLog -Paths $paths -Message 'Temporary cleanup confirmation declined' -Data @{ Count = $tempFiles.Count }
    }
}

$backupName = if ($DryRun) { 'DryRun_{0}_{1}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $sessionId.Substring(0, 8) } else { 'Backup_{0}_{1}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $sessionId.Substring(0, 8) }
$backupPath = Join-Path $paths.Backup $backupName
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText($backupPath, ($backup | ConvertTo-Json -Depth 10), $utf8Bom)
Write-MemoryLog -Paths $paths -Message 'Safe optimization session completed' -Data @{ SessionId = $sessionId; BackupPath = $backupPath; RegistryChanges = @($backup.RegistryChanges).Count; TempMoves = @($backup.TempMoves).Count }
Write-Host ('安全优化处理完成。备份/审计记录: {0}' -f $backupPath) -ForegroundColor Green

return [pscustomobject]@{
    SessionId = $sessionId
    DryRun = [bool]$DryRun
    BackupPath = $backupPath
    RegistryChanges = @($backup.RegistryChanges).Count
    TempMoves = @($backup.TempMoves).Count
    RestorePointCreated = [bool]$backup.RestorePointCreated
}
