param(
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'RelayStudio.exe')
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$iconPath = Join-Path $repoRoot 'RelayStudio.ico'
$cscPath = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $cscPath)) {
    throw "未找到 .NET Framework 4.x C# 编译器: $cscPath"
}

$smaAssembly = [System.Management.Automation.PowerShell].Assembly.Location
$csSource = @'
using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

[assembly: AssemblyTitle("RelayStudio")]
[assembly: AssemblyDescription("RelayStudio Desktop Launcher")]
[assembly: AssemblyCompany("RelayStudio")]
[assembly: AssemblyProduct("RelayStudio")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace RelayStudioLauncher
{
    internal static class Program
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);

        [STAThread]
        private static int Main(string[] args)
        {
            try { SetCurrentProcessExplicitAppUserModelID("com.relaystudio.desktop"); } catch { }

            bool startMinimized = false;
            if (args != null)
            {
                foreach (string a in args)
                {
                    if (string.Equals(a, "--minimized", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(a, "-StartMinimized", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(a, "/minimized", StringComparison.OrdinalIgnoreCase))
                    {
                        startMinimized = true;
                    }
                }
            }

            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string scriptPath = Path.Combine(baseDir, "连接管理.ps1");
            if (!File.Exists(scriptPath))
            {
                MessageBox.Show("未找到主程序脚本: " + scriptPath, "RelayStudio", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }

            try
            {
                using (Runspace rs = RunspaceFactory.CreateRunspace())
                {
                    rs.ApartmentState = ApartmentState.STA;
                    rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                    rs.Open();
                    using (PowerShell ps = PowerShell.Create())
                    {
                        ps.Runspace = rs;
                        ps.AddCommand("Set-ExecutionPolicy")
                          .AddParameter("Scope", "Process")
                          .AddParameter("ExecutionPolicy", "Bypass")
                          .AddParameter("Force", true)
                          .Invoke();
                        ps.Commands.Clear();

                        ps.AddCommand(scriptPath);
                        if (startMinimized)
                        {
                            ps.AddParameter("StartMinimized", true);
                        }
                        ps.Invoke();
                    }
                }
                return 0;
            }
            catch (Exception ex)
            {
                MessageBox.Show("RelayStudio 启动失败:\n" + ex.Message, "RelayStudio", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }
    }
}
'@

$tmpCs = Join-Path ([IO.Path]::GetTempPath()) ("RelayStudioLauncher-" + [Guid]::NewGuid().ToString('N') + ".cs")
try {
    [IO.File]::WriteAllText($tmpCs, $csSource, (New-Object Text.UTF8Encoding($true)))
    $cscArgs = @(
        '/nologo',
        '/target:winexe',
        '/optimize+',
        "/out:$OutputPath",
        "/reference:$smaAssembly",
        '/reference:System.Windows.Forms.dll',
        '/reference:System.Drawing.dll'
    )
    if (Test-Path -LiteralPath $iconPath) {
        $cscArgs += "/win32icon:$iconPath"
    }
    $cscArgs += $tmpCs
    & $cscPath @cscArgs
    if ($LASTEXITCODE -ne 0) {
        throw "csc.exe 编译失败 (ExitCode=$LASTEXITCODE)"
    }
    Write-Host "Successfully built launcher: $OutputPath"
} finally {
    if (Test-Path -LiteralPath $tmpCs) {
        Remove-Item -LiteralPath $tmpCs -Force -ErrorAction SilentlyContinue
    }
}
