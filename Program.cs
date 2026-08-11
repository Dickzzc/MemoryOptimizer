using System.Diagnostics;
using System.Security.Principal;
using System.Runtime.Versioning;

[SupportedOSPlatform("windows")]
internal static class Program
{
    private static int Main(string[] args)
    {
        var root = AppContext.BaseDirectory;
        var scriptPath = Path.Combine(root, "Start-MemoryOptimizer.ps1");

        if (args.Any(static arg => string.Equals(arg, "--validate", StringComparison.OrdinalIgnoreCase)))
        {
            if (!File.Exists(scriptPath))
            {
                Console.Error.WriteLine($"Start-MemoryOptimizer.ps1 was not found next to the launcher: {scriptPath}");
                return 2;
            }

            Console.WriteLine("MemoryOptimizer launcher validation passed.");
            return 0;
        }

        if (args.Length > 0)
        {
            Console.Error.WriteLine("Unsupported argument. Use --validate only for a launcher self-check.");
            return 4;
        }

        if (!IsAdministrator())
        {
            try
            {
                var currentExecutable = Environment.ProcessPath;
                if (string.IsNullOrWhiteSpace(currentExecutable))
                {
                    Console.Error.WriteLine("The launcher executable path could not be determined for elevation.");
                    return 7;
                }

                Process.Start(new ProcessStartInfo
                {
                    FileName = currentExecutable,
                    WorkingDirectory = root,
                    UseShellExecute = true,
                    Verb = "runas"
                });
                return 0;
            }
            catch (Exception exception)
            {
                Console.Error.WriteLine($"Administrator elevation was cancelled or failed: {exception.Message}");
                return 7;
            }
        }

        if (!File.Exists(scriptPath))
        {
            Console.Error.WriteLine($"Start-MemoryOptimizer.ps1 was not found next to the launcher: {scriptPath}");
            return 2;
        }

        var powershellPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "System32",
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe");
        if (!File.Exists(powershellPath))
        {
            Console.Error.WriteLine($"Windows PowerShell 5.1 was not found: {powershellPath}");
            return 3;
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = powershellPath,
            WorkingDirectory = root,
            UseShellExecute = false,
            CreateNoWindow = false
        };
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(scriptPath);

        try
        {
            using var process = Process.Start(startInfo);
            if (process is null)
            {
                Console.Error.WriteLine("Windows PowerShell could not be started.");
                return 5;
            }

            process.WaitForExit();
            return process.ExitCode;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"Failed to start the PowerShell workflow: {exception.Message}");
            return 6;
        }
    }

    private static bool IsAdministrator()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(identity);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }
}
