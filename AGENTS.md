# MemoryOptimizer project guidance

## Scope and architecture

- Target: Windows 10/11, Windows PowerShell 5.1 and PowerShell 7; no third-party modules.
- `Memory.Common.ps1` is the shared read-only/utility layer. It owns configuration loading, path fallback, structured logging, process snapshots, startup/service/task discovery, classification, CSV and HTML helpers.
- `Check-Memory.ps1` is read-only and produces the required six reports plus supporting CSV files.
- The check also writes `BrowserProcessDetails.csv`; it uses process type/profile hints only and deliberately does not log full browser command lines or browser content.
- `Optimize-Memory-Safe.ps1` is intentionally limited to A-level actions: confirmed third-party registry `Run/RunOnce` values and old files under `%TEMP%`/`%TMP%` moved to a reversible backup. It never ends processes or disables Windows services, Defender, Windows Update, pagefile, or security features.
- `Restore-Settings.ps1` replays the JSON backup and continues after individual failures.
- `Monitor-Memory.ps1` samples memory and the top processes without terminating anything; a single snapshot is never labeled a confirmed leak.
- `Start-MemoryOptimizer.ps1` and the BAT files provide the elevated, detect-confirm-optimize-detect workflow.
- `Program.cs` and `MemoryOptimizer.Launcher.csproj` build the self-contained `MemoryOptimizer.exe` launcher for `win-x64`; normal mode requests UAC and invokes the adjacent Windows PowerShell 5.1 entry script, while `--validate` performs a non-elevated adjacency check.

## Safety invariants

1. Failures are logged with a session id and exception text; no broad catch silently claims success.
2. User documents, browser profiles, passwords, bookmarks, chat history, development repositories and Office files are outside the modification scope.
3. The default pagefile recommendation is system-managed. This project does not modify virtual memory or perform aggressive registry/service changes.
4. Every startup change is recorded before removal. Temporary files are moved, not permanently deleted, and restore refuses to overwrite an existing destination.
5. `-DryRun` and `-Interactive:$false` must not make system changes. Browser extensions and browser data are informational only.

## Build, syntax and verification

Run the PowerShell verification from this directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-Tests.ps1
```

The test runner parses every PowerShell file and executes a read-only check, a DryRun and a short monitor. For a real diagnostic, run `Check-Memory.ps1 -NoPause` as administrator when possible, then inspect `Reports\MemoryAnalysisReport.html` before any optimization.

Build and smoke-test the launcher with:

```powershell
dotnet publish .\MemoryOptimizer.Launcher.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:PublishTrimmed=false -o .\artifacts\win-x64
Copy-Item .\artifacts\win-x64\MemoryOptimizer.exe .\MemoryOptimizer.exe -Force
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-LauncherTest.ps1
```

The published EXE is intentionally kept in the repository root for download. Build output directories are ignored by `.gitignore`.

## Encoding and compatibility

PowerShell scripts are UTF-8 with BOM so Windows PowerShell 5.1 reads Chinese strings correctly. Use `-LiteralPath` for file operations where the cmdlet supports it; `New-Item` uses `-Path` because Windows PowerShell 5.1 does not expose `-LiteralPath` for that cmdlet. Do not introduce PowerShell 7-only syntax.
