param(
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'RelayStudio.exe')
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$iconPath = Join-Path $repoRoot 'RelayStudio.ico'
$webviewDir = Join-Path $repoRoot 'bin\webview2'
$wvCoreDll = Join-Path $webviewDir 'Microsoft.Web.WebView2.Core.dll'
$wvWinFormsDll = Join-Path $webviewDir 'Microsoft.Web.WebView2.WinForms.dll'

$cscPath = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $cscPath)) {
    throw "未找到 .NET Framework 4.x C# 编译器: $cscPath"
}
if (-not (Test-Path -LiteralPath $wvCoreDll) -or -not (Test-Path -LiteralPath $wvWinFormsDll)) {
    Write-Host "未检测到本地 WebView2 程序集，正在从 NuGet 自动下载 Microsoft.Web.WebView2..."
    [IO.Directory]::CreateDirectory($webviewDir) | Out-Null
    $tempZip = Join-Path ([IO.Path]::GetTempPath()) ('webview2-nuget-' + [Guid]::NewGuid().ToString('N') + '.zip')
    try {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch { }
        Invoke-WebRequest -Uri 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2' -OutFile $tempZip -UseBasicParsing
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($tempZip)
        try {
            $wantedMap = @{
                'lib/net462/Microsoft.Web.WebView2.Core.dll'     = (Join-Path $webviewDir 'Microsoft.Web.WebView2.Core.dll')
                'lib/net462/Microsoft.Web.WebView2.WinForms.dll' = (Join-Path $webviewDir 'Microsoft.Web.WebView2.WinForms.dll')
                'lib/net462/Microsoft.Web.WebView2.Wpf.dll'      = (Join-Path $webviewDir 'Microsoft.Web.WebView2.Wpf.dll')
                'runtimes/win-x64/native/WebView2Loader.dll'     = (Join-Path $webviewDir 'WebView2Loader.dll')
            }
            foreach ($entry in $zip.Entries) {
                $normEntry = ($entry.FullName -replace '\\', '/')
                foreach ($wantedKey in $wantedMap.Keys) {
                    if ([string]::Equals($normEntry, $wantedKey, [StringComparison]::OrdinalIgnoreCase)) {
                        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $wantedMap[$wantedKey], $true)
                    }
                }
            }
        } finally {
            $zip.Dispose()
        }
    } finally {
        if (Test-Path -LiteralPath $tempZip) {
            Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Test-Path -LiteralPath $wvCoreDll) -or -not (Test-Path -LiteralPath $wvWinFormsDll)) {
        throw "未找到 WebView2 程序集: $webviewDir"
    }
}

$smaAssembly = [System.Management.Automation.PowerShell].Assembly.Location

$csSource = @'
using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

[assembly: AssemblyTitle("RelayStudio")]
[assembly: AssemblyDescription("RelayStudio Desktop Workbench")]
[assembly: AssemblyCompany("RelayStudio")]
[assembly: AssemblyProduct("RelayStudio")]
[assembly: AssemblyVersion("1.4.0.0")]
[assembly: AssemblyFileVersion("1.4.0.0")]

namespace RelayStudioLauncher
{
    internal static class NativeMethods
    {
        public const int WM_NCCALCSIZE = 0x0083;
        public const int WM_NCHITTEST = 0x0084;
        public const int HTCLIENT = 1;
        public const int HTLEFT = 10;
        public const int HTRIGHT = 11;
        public const int HTTOP = 12;
        public const int HTTOPLEFT = 13;
        public const int HTTOPRIGHT = 14;
        public const int HTBOTTOM = 15;
        public const int HTBOTTOMLEFT = 16;
        public const int HTBOTTOMRIGHT = 17;

        public const uint SWP_NOSIZE = 0x0001;
        public const uint SWP_NOMOVE = 0x0002;
        public const uint SWP_NOZORDER = 0x0004;
        public const uint SWP_FRAMECHANGED = 0x0020;

        public const int SW_RESTORE = 9;
        public const int SW_SHOW = 5;
        public const uint MONITOR_DEFAULTTONEAREST = 2;

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct NCCALCSIZE_PARAMS
        {
            public RECT rgrc0;
            public RECT rgrc1;
            public RECT rgrc2;
            public IntPtr lppos;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        public struct MONITORINFO
        {
            public int cbSize;
            public RECT rcMonitor;
            public RECT rcWork;
            public uint dwFlags;
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiFlag);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetProcessDPIAware();

        [DllImport("user32.dll")]
        public static extern uint GetDpiForWindow(IntPtr hwnd);

        [DllImport("user32.dll")]
        public static extern uint GetDpiForSystem();

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool IsZoomed(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

        [DllImport("user32.dll")]
        public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);

        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

        public const int UOI_NAME = 2;

        [DllImport("kernel32.dll")]
        public static extern uint GetCurrentThreadId();

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr GetThreadDesktop(uint dwThreadId);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool GetUserObjectInformation(IntPtr hObj, int nIndex, StringBuilder pvInfo, int nLength, out int lpnLengthNeeded);
    }

    internal sealed class LaunchOptions
    {
        public string BaseDir;
        public string DataRoot;
        public bool StartMinimized;
        public bool ForceLegacy;
        public bool SkipBootServices;
        public bool Isolated;
        public bool SmokeTest;
        public string SmokeReceiptPath;
    }

    internal sealed class InitialThemeAndBounds
    {
        public int Width = 1320;
        public int Height = 840;
        public string ThemeMode = "system";
        public bool IsDark = false;
    }

    internal static class Program
    {
        private static string _webviewBinDir;

        [STAThread]
        private static int Main(string[] args)
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            _webviewBinDir = Path.Combine(baseDir, "bin", "webview2");
            AppDomain.CurrentDomain.AssemblyResolve += OnAssemblyResolve;

            TryEnableHighDpi();
            try { NativeMethods.SetCurrentProcessExplicitAppUserModelID("com.relaystudio.desktop"); } catch { }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            LaunchOptions opts = ParseArgs(baseDir, args);

            string desktopName = GetCurrentDesktopName();
            if (!opts.SmokeTest && !opts.Isolated &&
                !string.IsNullOrEmpty(desktopName) &&
                desktopName.StartsWith("exebox-", StringComparison.OrdinalIgnoreCase))
            {
                return 2;
            }

            if (opts.ForceLegacy)
            {
                return RunLegacyWpf(opts.BaseDir, opts.StartMinimized);
            }

            string bridgePath = Path.Combine(opts.BaseDir, "HostBridge.ps1");
            string uiIndexPath = Path.Combine(opts.BaseDir, "ui", "index.html");

            if (!File.Exists(bridgePath) || !File.Exists(uiIndexPath))
            {
                if (opts.SmokeTest)
                {
                    WriteSmokeError(opts.SmokeReceiptPath, "Missing HostBridge.ps1 or ui/index.html");
                    return 1;
                }
                return RunLegacyWpf(opts.BaseDir, opts.StartMinimized);
            }

            string wvVersion = string.Empty;
            if (!TryCheckWebView2Runtime(_webviewBinDir, out wvVersion))
            {
                if (opts.SmokeTest)
                {
                    WriteSmokeError(opts.SmokeReceiptPath, "WebView2 Evergreen Runtime unavailable");
                    return 1;
                }
                return RunLegacyWpf(opts.BaseDir, opts.StartMinimized);
            }

            if (opts.SmokeTest || opts.Isolated)
            {
                return RunModernWebViewHost(opts, wvVersion, null, null);
            }

            bool createdNew = false;
            Mutex mutex = null;
            EventWaitHandle restoreEvent = null;
            try
            {
                mutex = new Mutex(true, "Local\\RelayStudio.OpenAI.ConnectionManager", out createdNew);
                restoreEvent = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\RelayStudio.OpenAI.RestoreEvent");
                if (!createdNew)
                {
                    try { restoreEvent.Set(); } catch { }
                    try
                    {
                        IntPtr existingHwnd = NativeMethods.FindWindow(null, "RelayStudio · 智能体接力与多栏工作台");
                        if (existingHwnd != IntPtr.Zero)
                        {
                            if (NativeMethods.IsIconic(existingHwnd))
                            {
                                NativeMethods.ShowWindow(existingHwnd, NativeMethods.SW_RESTORE);
                            }
                            NativeMethods.SetForegroundWindow(existingHwnd);
                        }
                    }
                    catch { }
                    return 0;
                }

                return RunModernWebViewHost(opts, wvVersion, mutex, restoreEvent);
            }
            finally
            {
                if (restoreEvent != null)
                {
                    try { restoreEvent.Dispose(); } catch { }
                }
                if (mutex != null)
                {
                    if (createdNew)
                    {
                        try { mutex.ReleaseMutex(); } catch { }
                    }
                    try { mutex.Dispose(); } catch { }
                }
            }
        }

        private static Assembly OnAssemblyResolve(object sender, ResolveEventArgs args)
        {
            try
            {
                string simpleName = new AssemblyName(args.Name).Name;
                if (string.IsNullOrEmpty(simpleName)) return null;
                string candidate = Path.Combine(_webviewBinDir, simpleName + ".dll");
                if (File.Exists(candidate))
                {
                    return Assembly.LoadFrom(candidate);
                }
            }
            catch { }
            return null;
        }

        private static void TryEnableHighDpi()
        {
            try
            {
                if (NativeMethods.SetProcessDpiAwarenessContext(new IntPtr(-4)))
                {
                    return;
                }
            }
            catch { }
            try { NativeMethods.SetProcessDPIAware(); } catch { }
        }

        private static string GetCurrentDesktopName()
        {
            try
            {
                IntPtr hDesk = NativeMethods.GetThreadDesktop(NativeMethods.GetCurrentThreadId());
                if (hDesk == IntPtr.Zero) return string.Empty;
                StringBuilder sb = new StringBuilder(256);
                int needed = 0;
                if (NativeMethods.GetUserObjectInformation(hDesk, NativeMethods.UOI_NAME, sb, sb.Capacity * 2, out needed))
                {
                    return sb.ToString() ?? string.Empty;
                }
            }
            catch { }
            return string.Empty;
        }

        private static LaunchOptions ParseArgs(string baseDir, string[] args)
        {
            LaunchOptions opts = new LaunchOptions();
            opts.BaseDir = baseDir;
            opts.DataRoot = Path.Combine(baseDir, "data");
            if (args == null) return opts;

            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i] ?? string.Empty;
                if (string.Equals(a, "--minimized", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(a, "-StartMinimized", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(a, "/minimized", StringComparison.OrdinalIgnoreCase))
                {
                    opts.StartMinimized = true;
                }
                else if (string.Equals(a, "--legacy", StringComparison.OrdinalIgnoreCase) ||
                         string.Equals(a, "-LegacyUi", StringComparison.OrdinalIgnoreCase) ||
                         string.Equals(a, "/legacy", StringComparison.OrdinalIgnoreCase))
                {
                    opts.ForceLegacy = true;
                }
                else if (string.Equals(a, "--skip-boot-services", StringComparison.OrdinalIgnoreCase) ||
                         string.Equals(a, "-SkipBootServices", StringComparison.OrdinalIgnoreCase))
                {
                    opts.SkipBootServices = true;
                }
                else if (string.Equals(a, "--isolated", StringComparison.OrdinalIgnoreCase) ||
                         string.Equals(a, "-Isolated", StringComparison.OrdinalIgnoreCase))
                {
                    opts.Isolated = true;
                }
                else if (string.Equals(a, "--data-root", StringComparison.OrdinalIgnoreCase) ||
                         string.Equals(a, "-DataRoot", StringComparison.OrdinalIgnoreCase))
                {
                    if (i + 1 < args.Length && !string.IsNullOrWhiteSpace(args[i + 1]))
                    {
                        opts.DataRoot = Path.GetFullPath(args[++i]);
                    }
                }
                else if (string.Equals(a, "--smoke-test", StringComparison.OrdinalIgnoreCase))
                {
                    opts.SmokeTest = true;
                    if (i + 1 < args.Length && !args[i + 1].StartsWith("-"))
                    {
                        opts.SmokeReceiptPath = Path.GetFullPath(args[++i]);
                    }
                    else
                    {
                        opts.SmokeReceiptPath = Path.Combine(opts.DataRoot, "smoke-receipt.json");
                    }
                }
                else if (a.StartsWith("--smoke-test=", StringComparison.OrdinalIgnoreCase))
                {
                    opts.SmokeTest = true;
                    opts.SmokeReceiptPath = Path.GetFullPath(a.Substring("--smoke-test=".Length).Trim('"'));
                }
            }
            return opts;
        }

        public static void WriteSmokeError(string receiptPath, string errorMsg)
        {
            if (string.IsNullOrEmpty(receiptPath)) return;
            try
            {
                string dir = Path.GetDirectoryName(receiptPath);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                JavaScriptSerializer ser = new JavaScriptSerializer();
                Dictionary<string, object> payload = new Dictionary<string, object>();
                payload["ok"] = false;
                payload["error"] = errorMsg ?? "Unknown error";
                File.WriteAllText(receiptPath, ser.Serialize(payload), new UTF8Encoding(false));
            }
            catch { }
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static bool TryCheckWebView2Runtime(string webviewBinDir, out string version)
        {
            version = string.Empty;
            try
            {
                if (Directory.Exists(webviewBinDir))
                {
                    CoreWebView2Environment.SetLoaderDllFolderPath(webviewBinDir);
                }
                version = CoreWebView2Environment.GetAvailableBrowserVersionString(null);
                return !string.IsNullOrEmpty(version);
            }
            catch
            {
                return false;
            }
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static int RunModernWebViewHost(LaunchOptions opts, string wvVersion, Mutex mutex, EventWaitHandle restoreEvent)
        {
            try
            {
                InitialThemeAndBounds init = ReadInitialThemeAndBounds(opts.DataRoot);
                using (RelayWorkbenchForm form = new RelayWorkbenchForm(opts, wvVersion, init, restoreEvent))
                {
                    Application.Run(form);
                    return form.ExitCode;
                }
            }
            catch (Exception ex)
            {
                if (opts.SmokeTest)
                {
                    WriteSmokeError(opts.SmokeReceiptPath, ex.ToString());
                    return 1;
                }
                return RunLegacyWpf(opts.BaseDir, opts.StartMinimized);
            }
        }

        public static InitialThemeAndBounds ReadInitialThemeAndBounds(string dataRoot)
        {
            InitialThemeAndBounds res = new InitialThemeAndBounds();
            string layoutPath = Path.Combine(dataRoot, "window-layout.json");
            if (File.Exists(layoutPath))
            {
                try
                {
                    JavaScriptSerializer ser = new JavaScriptSerializer();
                    Dictionary<string, object> raw = ser.Deserialize<Dictionary<string, object>>(File.ReadAllText(layoutPath, Encoding.UTF8));
                    if (raw != null)
                    {
                        if (raw.ContainsKey("win_width") && raw["win_width"] != null)
                        {
                            int w = Convert.ToInt32(raw["win_width"]);
                            if (w >= 740 && w <= 3840) res.Width = w;
                        }
                        if (raw.ContainsKey("win_height") && raw["win_height"] != null)
                        {
                            int h = Convert.ToInt32(raw["win_height"]);
                            if (h >= 500 && h <= 2400) res.Height = h;
                        }
                        if (raw.ContainsKey("theme_mode") && raw["theme_mode"] != null)
                        {
                            string tm = Convert.ToString(raw["theme_mode"]).Trim().ToLowerInvariant();
                            if (tm == "light" || tm == "dark" || tm == "system")
                            {
                                res.ThemeMode = tm;
                            }
                        }
                    }
                }
                catch { }
            }
            bool sysDark = IsWindowsSystemDarkTheme();
            if (res.ThemeMode == "dark") res.IsDark = true;
            else if (res.ThemeMode == "light") res.IsDark = false;
            else res.IsDark = sysDark;
            return res;
        }

        public static bool IsWindowsSystemDarkTheme()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                {
                    if (key != null)
                    {
                        object val = key.GetValue("AppsUseLightTheme");
                        if (val != null)
                        {
                            return Convert.ToInt32(val) == 0;
                        }
                    }
                }
            }
            catch { }
            return false;
        }

        private static int RunLegacyWpf(string baseDir, bool startMinimized)
        {
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

    internal sealed class HostRunspaceWorker : IDisposable
    {
        private readonly LaunchOptions _opts;
        private readonly BlockingCollection<Action> _queue = new BlockingCollection<Action>();
        private readonly Thread _thread;
        private readonly ManualResetEventSlim _readyEvent = new ManualResetEventSlim(false);
        private Runspace _runspace;
        private Exception _initError;
        private volatile bool _disposed;

        public HostRunspaceWorker(LaunchOptions opts)
        {
            _opts = opts;
            _thread = new Thread(WorkerLoop);
            _thread.Name = "RelayStudio.HostBridgeWorker";
            _thread.IsBackground = true;
            _thread.SetApartmentState(ApartmentState.STA);
            _thread.Start();
        }

        private void WorkerLoop()
        {
            try
            {
                _runspace = RunspaceFactory.CreateRunspace();
                _runspace.ApartmentState = ApartmentState.STA;
                _runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                _runspace.Open();

                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = _runspace;
                    ps.AddCommand("Set-ExecutionPolicy")
                      .AddParameter("Scope", "Process")
                      .AddParameter("ExecutionPolicy", "Bypass")
                      .AddParameter("Force", true)
                      .Invoke();
                    ps.Commands.Clear();

                    string bridgePath = Path.Combine(_opts.BaseDir, "HostBridge.ps1");
                    string dotSourceScript = ". '" + bridgePath.Replace("'", "''") + "'";
                    ps.AddScript(dotSourceScript, false);
                    ps.Invoke();
                    ps.Commands.Clear();

                    ps.AddCommand("Initialize-RelayHostBridge")
                      .AddParameter("BaseDirectory", _opts.BaseDir)
                      .AddParameter("DataRoot", _opts.DataRoot);
                    if (_opts.Isolated)
                    {
                        ps.AddParameter("Isolated", true);
                    }
                    if (_opts.SkipBootServices)
                    {
                        ps.AddParameter("SkipBootServices", true);
                    }
                    ps.Invoke();
                }
            }
            catch (Exception ex)
            {
                _initError = ex;
            }
            finally
            {
                _readyEvent.Set();
            }

            if (_initError != null)
            {
                return;
            }

            foreach (Action job in _queue.GetConsumingEnumerable())
            {
                if (_disposed) break;
                try
                {
                    job();
                }
                catch { }
            }

            if (_runspace != null)
            {
                try { _runspace.Close(); } catch { }
                try { _runspace.Dispose(); } catch { }
                _runspace = null;
            }
        }

        public void WaitReady(int timeoutMs)
        {
            _readyEvent.Wait(timeoutMs);
            if (_initError != null)
            {
                throw _initError;
            }
        }

        public void EnqueueRpc(string requestJson, Action<string> onCompleted)
        {
            if (_disposed) return;
            try
            {
                _queue.Add(delegate
                {
                    string responseJson = InvokePsStringCommand("Invoke-RelayHostRpc", "RequestJson", requestJson);
                    if (onCompleted != null)
                    {
                        onCompleted(responseJson);
                    }
                });
            }
            catch { }
        }

        public void EnqueueGuardianTick(Action<string> onCompleted)
        {
            if (_disposed) return;
            try
            {
                _queue.Add(delegate
                {
                    string tickJson = InvokePsStringCommand("Invoke-RelayHostGuardianTickJson", null, null);
                    if (onCompleted != null)
                    {
                        onCompleted(tickJson);
                    }
                });
            }
            catch { }
        }

        private string InvokePsStringCommand(string commandName, string paramName, object paramVal)
        {
            try
            {
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = _runspace;
                    ps.AddCommand(commandName);
                    if (!string.IsNullOrEmpty(paramName))
                    {
                        ps.AddParameter(paramName, paramVal);
                    }
                    var results = ps.Invoke();
                    if (results != null && results.Count > 0 && results[results.Count - 1] != null)
                    {
                        return results[results.Count - 1].BaseObject.ToString();
                    }
                }
            }
            catch (Exception ex)
            {
                JavaScriptSerializer ser = new JavaScriptSerializer();
                Dictionary<string, object> err = new Dictionary<string, object>();
                err["type"] = "rpc_response";
                err["id"] = "";
                err["ok"] = false;
                err["error"] = ex.Message;
                return ser.Serialize(err);
            }
            return "{}";
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            try { _queue.CompleteAdding(); } catch { }
        }
    }

    internal sealed class RelayWorkbenchForm : Form
    {
        private static readonly Color DarkBg = Color.FromArgb(255, 17, 17, 20);
        private static readonly Color LightBg = Color.FromArgb(255, 243, 244, 246);

        private readonly LaunchOptions _opts;
        private readonly string _webviewVersion;
        private readonly EventWaitHandle _restoreEvent;
        private readonly JavaScriptSerializer _json;
        private readonly HostRunspaceWorker _worker;
        private readonly WebView2 _webView;

        private NotifyIcon _notifyIcon;
        private ContextMenuStrip _trayMenu;
        private ToolStripMenuItem _trayItemThemeToggle;
        private ToolStripMenuItem _trayItemThemeSystem;
        private System.Windows.Forms.Timer _suspendTimer;
        private System.Windows.Forms.Timer _guardianTimer;
        private System.Windows.Forms.Timer _smokeTimeoutTimer;
        private System.Windows.Forms.Timer _smokeFallbackProbeTimer;
        private Thread _ipcRestoreThread;

        private string _themeMode;
        private bool _isDarkTheme;
        private bool _exiting;
        private bool _hasUnsavedEdits;
        private bool _trayHintShown;
        private bool _guardianInFlight;
        private bool _coreReady;
        private bool _smokeCompleted;
        private FormWindowState _lastReportedWindowState;

        public int ExitCode { get; private set; }

        public RelayWorkbenchForm(LaunchOptions opts, string wvVersion, InitialThemeAndBounds init, EventWaitHandle restoreEvent)
        {
            _opts = opts;
            _webviewVersion = wvVersion;
            _restoreEvent = restoreEvent;
            _themeMode = init.ThemeMode;
            _isDarkTheme = init.IsDark;
            _json = new JavaScriptSerializer();
            _json.MaxJsonLength = int.MaxValue;

            this.Text = "RelayStudio · 智能体接力与多栏工作台";
            this.AutoScaleMode = AutoScaleMode.None;
            double initScale = GetCurrentDpiScale();
            this.MinimumSize = new Size(LogicalToPhysical(760, initScale), LogicalToPhysical(520, initScale));
            Screen initScreen = null;
            if (!_opts.SmokeTest)
            {
                try { initScreen = Screen.FromPoint(Cursor.Position); } catch { initScreen = Screen.PrimaryScreen; }
            }
            this.Size = ClampPhysicalSizeToWorkingArea(
                LogicalToPhysical(init.Width, initScale),
                LogicalToPhysical(init.Height, initScale),
                initScreen
            );
            this.FormBorderStyle = FormBorderStyle.Sizable;
            this.BackColor = _isDarkTheme ? DarkBg : LightBg;
            this.Padding = new Padding(4);

            string icoPath = Path.Combine(_opts.BaseDir, "RelayStudio.ico");
            if (File.Exists(icoPath))
            {
                try { this.Icon = new Icon(icoPath); } catch { }
            }

            if (_opts.SmokeTest)
            {
                this.StartPosition = FormStartPosition.Manual;
                this.Location = new Point(-32000, -32000);
                this.ShowInTaskbar = false;
                this.Opacity = 0;
            }
            else if (_opts.StartMinimized)
            {
                this.StartPosition = FormStartPosition.CenterScreen;
                this.ShowInTaskbar = false;
                this.WindowState = FormWindowState.Minimized;
                this.Opacity = 0;
            }
            else
            {
                this.StartPosition = FormStartPosition.CenterScreen;
            }

            _worker = new HostRunspaceWorker(_opts);

            _webView = new WebView2();
            _webView.Dock = DockStyle.Fill;
            _webView.DefaultBackgroundColor = _isDarkTheme ? DarkBg : LightBg;
            this.Controls.Add(_webView);

            if (!_opts.SmokeTest)
            {
                InitializeTrayIcon(icoPath);
                StartRestoreEventListener();
                SystemEvents.UserPreferenceChanged += OnSystemUserPreferenceChanged;
            }

            _suspendTimer = new System.Windows.Forms.Timer();
            _suspendTimer.Interval = 420;
            _suspendTimer.Tick += OnSuspendTimerTick;

            if (!_opts.SmokeTest && !_opts.SkipBootServices && !_opts.Isolated)
            {
                _guardianTimer = new System.Windows.Forms.Timer();
                _guardianTimer.Interval = 10000;
                _guardianTimer.Tick += OnGuardianTimerTick;
            }

            if (_opts.SmokeTest)
            {
                _smokeTimeoutTimer = new System.Windows.Forms.Timer();
                _smokeTimeoutTimer.Interval = 12000;
                _smokeTimeoutTimer.Tick += delegate
                {
                    _smokeTimeoutTimer.Stop();
                    CompleteSmokeTest(false, null, "Smoke test timed out after 12s");
                };
                _smokeTimeoutTimer.Start();
            }

            this.Load += OnFormLoad;
            this.Shown += OnFormShown;
            this.Resize += OnFormResize;
            this.ResizeEnd += OnFormResizeEnd;
            this.FormClosing += OnFormClosing;
        }

        private double GetCurrentDpiScale()
        {
            double dpi = 0.0;
            if (this.IsHandleCreated)
            {
                try
                {
                    uint winDpi = NativeMethods.GetDpiForWindow(this.Handle);
                    if (winDpi >= 96 && winDpi <= 480)
                    {
                        dpi = (double)winDpi;
                    }
                }
                catch { }
            }
            if (dpi <= 0.0)
            {
                try
                {
                    uint sysDpi = NativeMethods.GetDpiForSystem();
                    if (sysDpi >= 96 && sysDpi <= 480)
                    {
                        dpi = (double)sysDpi;
                    }
                }
                catch { }
            }
            if (dpi <= 0.0)
            {
                try
                {
                    using (Graphics g = Graphics.FromHwnd(IntPtr.Zero))
                    {
                        if (g.DpiX >= 72f && g.DpiX <= 480f)
                        {
                            dpi = (double)g.DpiX;
                        }
                    }
                }
                catch { }
            }
            if (dpi <= 0.0)
            {
                dpi = 96.0;
            }
            double scale = dpi / 96.0;
            if (scale < 1.0) scale = 1.0;
            if (scale > 4.0) scale = 4.0;
            return scale;
        }

        private static int LogicalToPhysical(int logicalPx, double scale)
        {
            return (int)Math.Round(logicalPx * scale);
        }

        private static int PhysicalToLogical(int physicalPx, double scale)
        {
            return (int)Math.Round(physicalPx / scale);
        }

        private Size ClampPhysicalSizeToWorkingArea(int physW, int physH, Screen targetScreen)
        {
            double scale = GetCurrentDpiScale();
            int minW = LogicalToPhysical(740, scale);
            int minH = LogicalToPhysical(500, scale);
            if (_opts != null && _opts.SmokeTest)
            {
                return new Size(Math.Max(minW, physW), Math.Max(minH, physH));
            }
            Screen scr = targetScreen ?? Screen.PrimaryScreen;
            if (scr == null)
            {
                return new Size(Math.Max(minW, physW), Math.Max(minH, physH));
            }
            Rectangle wa = scr.WorkingArea;
            int clampedW = Math.Max(minW, Math.Min(physW, wa.Width - 24));
            int clampedH = Math.Max(minH, Math.Min(physH, wa.Height - 24));
            return new Size(clampedW, clampedH);
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            ApplyWin11WindowAttributes();
        }

        private void ApplyWin11WindowAttributes()
        {
            if (!this.IsHandleCreated) return;
            try
            {
                int roundPref = 2; // DWMWCP_ROUND
                NativeMethods.DwmSetWindowAttribute(this.Handle, 33, ref roundPref, sizeof(int));
            }
            catch { }
            ApplyDwmDarkMode(_isDarkTheme);
            try
            {
                NativeMethods.SetWindowPos(
                    this.Handle,
                    IntPtr.Zero,
                    0, 0, 0, 0,
                    NativeMethods.SWP_NOMOVE | NativeMethods.SWP_NOSIZE | NativeMethods.SWP_NOZORDER | NativeMethods.SWP_FRAMECHANGED
                );
            }
            catch { }
        }

        private void ApplyDwmDarkMode(bool isDark)
        {
            if (!this.IsHandleCreated) return;
            try
            {
                int darkFlag = isDark ? 1 : 0;
                NativeMethods.DwmSetWindowAttribute(this.Handle, 20, ref darkFlag, sizeof(int));
            }
            catch { }
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == NativeMethods.WM_NCCALCSIZE && m.WParam != IntPtr.Zero)
            {
                if (NativeMethods.IsZoomed(this.Handle))
                {
                    NativeMethods.NCCALCSIZE_PARAMS ncp = (NativeMethods.NCCALCSIZE_PARAMS)Marshal.PtrToStructure(
                        m.LParam, typeof(NativeMethods.NCCALCSIZE_PARAMS));
                    IntPtr hMon = NativeMethods.MonitorFromWindow(this.Handle, NativeMethods.MONITOR_DEFAULTTONEAREST);
                    NativeMethods.MONITORINFO mi = new NativeMethods.MONITORINFO();
                    mi.cbSize = Marshal.SizeOf(typeof(NativeMethods.MONITORINFO));
                    if (NativeMethods.GetMonitorInfo(hMon, ref mi))
                    {
                        ncp.rgrc0 = mi.rcWork;
                        Marshal.StructureToPtr(ncp, m.LParam, false);
                    }
                }
                m.Result = IntPtr.Zero;
                return;
            }

            if (m.Msg == NativeMethods.WM_NCHITTEST)
            {
                base.WndProc(ref m);
                if ((int)m.Result == NativeMethods.HTCLIENT && this.WindowState == FormWindowState.Normal)
                {
                    int lp = m.LParam.ToInt32();
                    int screenX = (short)(lp & 0xFFFF);
                    int screenY = (short)((lp >> 16) & 0xFFFF);
                    Point clientPt = this.PointToClient(new Point(screenX, screenY));
                    const int grip = 6;
                    const int corner = 12;

                    bool left = clientPt.X < grip;
                    bool right = clientPt.X >= this.ClientSize.Width - grip;
                    bool top = clientPt.Y < grip;
                    bool bottom = clientPt.Y >= this.ClientSize.Height - grip;

                    if (clientPt.Y < corner && clientPt.X < corner && (top || left)) { m.Result = (IntPtr)NativeMethods.HTTOPLEFT; return; }
                    if (clientPt.Y < corner && clientPt.X >= this.ClientSize.Width - corner && (top || right)) { m.Result = (IntPtr)NativeMethods.HTTOPRIGHT; return; }
                    if (clientPt.Y >= this.ClientSize.Height - corner && clientPt.X < corner && (bottom || left)) { m.Result = (IntPtr)NativeMethods.HTBOTTOMLEFT; return; }
                    if (clientPt.Y >= this.ClientSize.Height - corner && clientPt.X >= this.ClientSize.Width - corner && (bottom || right)) { m.Result = (IntPtr)NativeMethods.HTBOTTOMRIGHT; return; }
                    if (left) { m.Result = (IntPtr)NativeMethods.HTLEFT; return; }
                    if (right) { m.Result = (IntPtr)NativeMethods.HTRIGHT; return; }
                    if (top) { m.Result = (IntPtr)NativeMethods.HTTOP; return; }
                    if (bottom) { m.Result = (IntPtr)NativeMethods.HTBOTTOM; return; }
                }
                return;
            }

            base.WndProc(ref m);
        }

        private async void OnFormLoad(object sender, EventArgs e)
        {
            try
            {
                string cacheDirName = (_opts.SmokeTest || _opts.Isolated) ? "webview2-smoke-cache" : "webview2-cache";
                string cacheFolder = Path.Combine(_opts.DataRoot, cacheDirName);
                Directory.CreateDirectory(cacheFolder);

                CoreWebView2Environment env = await CoreWebView2Environment.CreateAsync(null, cacheFolder, null);
                await _webView.EnsureCoreWebView2Async(env);

                CoreWebView2 core = _webView.CoreWebView2;
                core.Settings.IsNonClientRegionSupportEnabled = true;
                core.Settings.IsStatusBarEnabled = false;
                core.Settings.AreDefaultContextMenusEnabled = false;
                core.Settings.AreDevToolsEnabled = true;
                core.Settings.AreBrowserAcceleratorKeysEnabled = true;
                core.Settings.IsPinchZoomEnabled = false;

                string uiDir = Path.Combine(_opts.BaseDir, "ui");
                core.SetVirtualHostNameToFolderMapping(
                    "studio.relaystudio.local",
                    uiDir,
                    CoreWebView2HostResourceAccessKind.Allow
                );

                core.WebMessageReceived += OnWebMessageReceived;
                core.NewWindowRequested += OnNewWindowRequested;
                core.NavigationCompleted += OnNavigationCompleted;

                _coreReady = true;
                core.Navigate("https://studio.relaystudio.local/index.html");

                if (_guardianTimer != null)
                {
                    _guardianTimer.Start();
                }
            }
            catch (Exception ex)
            {
                if (_opts.SmokeTest)
                {
                    CompleteSmokeTest(false, null, "WebView2 init failed: " + ex.Message);
                    return;
                }
                MessageBox.Show("WebView2 初始化失败:\n" + ex.Message, "RelayStudio", MessageBoxButtons.OK, MessageBoxIcon.Error);
                _exiting = true;
                ExitCode = 1;
                this.Close();
            }
        }

        private void OnFormShown(object sender, EventArgs e)
        {
            if (_opts.StartMinimized && !_opts.SmokeTest)
            {
                this.Hide();
                this.Opacity = 1.0;
            }
        }

        private void OnFormResize(object sender, EventArgs e)
        {
            this.Padding = (this.WindowState == FormWindowState.Maximized) ? Padding.Empty : new Padding(4);
            if (_coreReady && this.WindowState != _lastReportedWindowState)
            {
                _lastReportedWindowState = this.WindowState;
                double scale = GetCurrentDpiScale();
                Dictionary<string, object> push = new Dictionary<string, object>();
                push["type"] = "window_state";
                push["maximized"] = (this.WindowState == FormWindowState.Maximized);
                push["width"] = PhysicalToLogical(this.Width, scale);
                push["height"] = PhysicalToLogical(this.Height, scale);
                PostObjectToWeb(push);
            }
        }

        private void OnFormResizeEnd(object sender, EventArgs e)
        {
            if (_opts.SmokeTest || _exiting || this.IsDisposed || this.WindowState != FormWindowState.Normal)
            {
                return;
            }
            try
            {
                double scale = GetCurrentDpiScale();
                int logW = PhysicalToLogical(this.Width, scale);
                int logH = PhysicalToLogical(this.Height, scale);
                if (logW < 740 || logH < 500)
                {
                    return;
                }
                Dictionary<string, object> layoutDict = new Dictionary<string, object>();
                layoutDict["WinWidth"] = logW;
                layoutDict["WinHeight"] = logH;
                Dictionary<string, object> paramsDict = new Dictionary<string, object>();
                paramsDict["layout"] = layoutDict;
                Dictionary<string, object> req = new Dictionary<string, object>();
                req["type"] = "rpc_request";
                req["id"] = "host_resize";
                req["method"] = "save_layout";
                req["params"] = paramsDict;
                _worker.EnqueueRpc(_json.Serialize(req), null);
            }
            catch { }
        }

        private void OnNavigationCompleted(object sender, CoreWebView2NavigationCompletedEventArgs e)
        {
            if (_opts.SmokeTest)
            {
                if (!e.IsSuccess)
                {
                    CompleteSmokeTest(false, null, "Navigation failed with status: " + e.WebErrorStatus.ToString());
                    return;
                }
                _smokeFallbackProbeTimer = new System.Windows.Forms.Timer();
                _smokeFallbackProbeTimer.Interval = 1800;
                _smokeFallbackProbeTimer.Tick += OnSmokeFallbackProbeTick;
                _smokeFallbackProbeTimer.Start();
            }
        }

        private async void OnSmokeFallbackProbeTick(object sender, EventArgs e)
        {
            if (_smokeFallbackProbeTimer != null) _smokeFallbackProbeTimer.Stop();
            if (_smokeCompleted) return;
            try
            {
                string rawTitleJson = await _webView.CoreWebView2.ExecuteScriptAsync("document.title");
                string docTitle = string.Empty;
                try { docTitle = _json.Deserialize<string>(rawTitleJson); } catch { docTitle = rawTitleJson; }
                string currentUrl = _webView.CoreWebView2.Source;

                string bootReq = "{\"type\":\"rpc_request\",\"id\":\"smoke_boot_probe\",\"method\":\"get_fast_bootstrap\",\"params\":{}}";
                _worker.EnqueueRpc(bootReq, delegate(string respJson)
                {
                    if (_smokeCompleted) return;
                    this.BeginInvoke((MethodInvoker)delegate
                    {
                        if (_smokeCompleted) return;
                        try
                        {
                            Dictionary<string, object> env = _json.Deserialize<Dictionary<string, object>>(respJson);
                            bool ok = env != null && env.ContainsKey("ok") && Convert.ToBoolean(env["ok"]);
                            if (!ok)
                            {
                                string err = (env != null && env.ContainsKey("error") && env["error"] != null) ? env["error"].ToString() : "boot_init failed";
                                CompleteSmokeTest(false, null, err);
                                return;
                            }
                            Dictionary<string, object> resObj = env.ContainsKey("result") ? env["result"] as Dictionary<string, object> : null;
                            string shieldUrl = (resObj != null && resObj.ContainsKey("shieldBaseUrl") && resObj["shieldBaseUrl"] != null)
                                ? resObj["shieldBaseUrl"].ToString()
                                : "";

                            Dictionary<string, object> receipt = new Dictionary<string, object>();
                            receipt["ok"] = true;
                            receipt["webviewVersion"] = _webviewVersion;
                            receipt["title"] = docTitle ?? string.Empty;
                            receipt["url"] = currentUrl ?? string.Empty;
                            receipt["shieldBaseUrl"] = shieldUrl;
                            CompleteSmokeTest(true, receipt, null);
                        }
                        catch (Exception ex)
                        {
                            CompleteSmokeTest(false, null, ex.Message);
                        }
                    });
                });
            }
            catch (Exception ex)
            {
                CompleteSmokeTest(false, null, ex.Message);
            }
        }

        private void CompleteSmokeTest(bool ok, Dictionary<string, object> receiptData, string errorMsg)
        {
            if (_smokeCompleted) return;
            _smokeCompleted = true;
            if (_smokeTimeoutTimer != null) _smokeTimeoutTimer.Stop();
            if (_smokeFallbackProbeTimer != null) _smokeFallbackProbeTimer.Stop();

            if (ok && receiptData != null)
            {
                try
                {
                    string dir = Path.GetDirectoryName(_opts.SmokeReceiptPath);
                    if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                    File.WriteAllText(_opts.SmokeReceiptPath, _json.Serialize(receiptData), new UTF8Encoding(false));
                    ExitCode = 0;
                }
                catch (Exception ex)
                {
                    Program.WriteSmokeError(_opts.SmokeReceiptPath, ex.Message);
                    ExitCode = 1;
                }
            }
            else
            {
                Program.WriteSmokeError(_opts.SmokeReceiptPath, errorMsg);
                ExitCode = 1;
            }

            _exiting = true;
            this.Close();
        }

        private void OnNewWindowRequested(object sender, CoreWebView2NewWindowRequestedEventArgs e)
        {
            e.Handled = true;
            try
            {
                string uri = e.Uri;
                if (!string.IsNullOrEmpty(uri) &&
                    (uri.StartsWith("https://", StringComparison.OrdinalIgnoreCase) ||
                     uri.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) &&
                    uri.IndexOf("studio.relaystudio.local", StringComparison.OrdinalIgnoreCase) < 0)
                {
                    Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true });
                }
            }
            catch { }
        }

        private void OnWebMessageReceived(object sender, CoreWebView2WebMessageReceivedEventArgs e)
        {
            string rawJson = null;
            try
            {
                rawJson = e.WebMessageAsJson;
                if (!string.IsNullOrEmpty(rawJson) && rawJson[0] == '"')
                {
                    try { rawJson = e.TryGetWebMessageAsString(); } catch { }
                }
            }
            catch { return; }

            if (string.IsNullOrEmpty(rawJson)) return;

            Dictionary<string, object> msg = null;
            try
            {
                msg = _json.Deserialize<Dictionary<string, object>>(rawJson);
            }
            catch { return; }
            if (msg == null) return;

            string msgType = msg.ContainsKey("type") && msg["type"] != null ? msg["type"].ToString() : string.Empty;

            if (string.Equals(msgType, "smoke_ready", StringComparison.OrdinalIgnoreCase))
            {
                if (_opts.SmokeTest && !_smokeCompleted)
                {
                    string shieldUrl = msg.ContainsKey("shieldBaseUrl") && msg["shieldBaseUrl"] != null
                        ? msg["shieldBaseUrl"].ToString()
                        : "http://127.0.0.1:8766";
                    string titleVal = msg.ContainsKey("title") && msg["title"] != null
                        ? msg["title"].ToString()
                        : _webView.CoreWebView2.DocumentTitle;
                    Dictionary<string, object> receipt = new Dictionary<string, object>();
                    receipt["ok"] = true;
                    receipt["webviewVersion"] = _webviewVersion;
                    receipt["title"] = titleVal ?? string.Empty;
                    receipt["url"] = _webView.CoreWebView2.Source ?? string.Empty;
                    receipt["shieldBaseUrl"] = shieldUrl;
                    if (msg.ContainsKey("hubReachable") && msg["hubReachable"] != null)
                    {
                        try { receipt["hubReachable"] = Convert.ToBoolean(msg["hubReachable"]); } catch { receipt["hubReachable"] = msg["hubReachable"]; }
                    }
                    if (msg.ContainsKey("fastBootMs") && msg["fastBootMs"] != null)
                    {
                        receipt["fastBootMs"] = msg["fastBootMs"];
                    }
                    CompleteSmokeTest(true, receipt, null);
                }
                return;
            }

            if (!string.Equals(msgType, "rpc_request", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            string id = msg.ContainsKey("id") && msg["id"] != null ? msg["id"].ToString() : string.Empty;
            string method = msg.ContainsKey("method") && msg["method"] != null ? msg["method"].ToString() : string.Empty;
            Dictionary<string, object> rpcParams = msg.ContainsKey("params") ? (msg["params"] as Dictionary<string, object>) : null;

            if (string.Equals(method, "window_minimize", StringComparison.OrdinalIgnoreCase))
            {
                this.WindowState = FormWindowState.Minimized;
                PostRpcSuccess(id, CreateOkDict());
                return;
            }

            if (string.Equals(method, "window_toggle_maximize", StringComparison.OrdinalIgnoreCase))
            {
                this.WindowState = (this.WindowState == FormWindowState.Maximized)
                    ? FormWindowState.Normal
                    : FormWindowState.Maximized;
                bool isMax = (this.WindowState == FormWindowState.Maximized);
                Dictionary<string, object> res = new Dictionary<string, object>();
                res["ok"] = true;
                res["maximized"] = isMax;
                PostRpcSuccess(id, res);
                return;
            }

            if (string.Equals(method, "window_close_to_tray", StringComparison.OrdinalIgnoreCase))
            {
                if (!ConfirmDiscardUnsavedEditsIfNeeded())
                {
                    Dictionary<string, object> cancelRes = new Dictionary<string, object>();
                    cancelRes["ok"] = false;
                    cancelRes["cancelled"] = true;
                    PostRpcSuccess(id, cancelRes);
                    return;
                }
                PostRpcSuccess(id, CreateOkDict());
                HideToTray();
                return;
            }

            if (string.Equals(method, "open_external_url", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    string url = string.Empty;
                    if (rpcParams != null)
                    {
                        if (rpcParams.ContainsKey("url") && rpcParams["url"] != null) url = rpcParams["url"].ToString();
                        else if (rpcParams.ContainsKey("Url") && rpcParams["Url"] != null) url = rpcParams["Url"].ToString();
                    }
                    if (!string.IsNullOrWhiteSpace(url) &&
                        (url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
                         url.StartsWith("https://", StringComparison.OrdinalIgnoreCase)))
                    {
                        Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
                    }
                    PostRpcSuccess(id, CreateOkDict());
                }
                catch (Exception ex)
                {
                    PostRpcError(id, ex.Message);
                }
                return;
            }

            if (string.Equals(method, "window_ensure_min_width", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    int minWidth = 0;
                    if (rpcParams != null)
                    {
                        if (rpcParams.ContainsKey("minWidth") && rpcParams["minWidth"] != null) minWidth = Convert.ToInt32(rpcParams["minWidth"]);
                        else if (rpcParams.ContainsKey("MinWidth") && rpcParams["MinWidth"] != null) minWidth = Convert.ToInt32(rpcParams["MinWidth"]);
                    }
                    double scale = GetCurrentDpiScale();
                    int physMinWidth = LogicalToPhysical(minWidth, scale);
                    if (this.WindowState == FormWindowState.Normal && physMinWidth > this.Width)
                    {
                        if (_opts.SmokeTest)
                        {
                            this.Width = Math.Max(LogicalToPhysical(740, scale), physMinWidth);
                        }
                        else
                        {
                            Rectangle wa = Screen.FromControl(this).WorkingArea;
                            int floorW = LogicalToPhysical(740, scale);
                            int targetW = Math.Min(Math.Max(floorW, wa.Width - 24), physMinWidth);
                            if (targetW > this.Width)
                            {
                                this.Width = targetW;
                                if (this.Right > wa.Right)
                                {
                                    this.Left = Math.Max(wa.Left + 12, wa.Right - this.Width - 12);
                                }
                            }
                        }
                    }
                    Dictionary<string, object> wRes = new Dictionary<string, object>();
                    wRes["ok"] = true;
                    wRes["width"] = PhysicalToLogical(this.Width, scale);
                    PostRpcSuccess(id, wRes);
                }
                catch (Exception ex)
                {
                    PostRpcError(id, ex.Message);
                }
                return;
            }

            if (string.Equals(method, "set_unsaved_edits", StringComparison.OrdinalIgnoreCase))
            {
                bool dirty = false;
                if (rpcParams != null)
                {
                    if (rpcParams.ContainsKey("dirty") && rpcParams["dirty"] != null)
                    {
                        try { dirty = Convert.ToBoolean(rpcParams["dirty"]); } catch { dirty = false; }
                    }
                    else if (rpcParams.ContainsKey("Dirty") && rpcParams["Dirty"] != null)
                    {
                        try { dirty = Convert.ToBoolean(rpcParams["Dirty"]); } catch { dirty = false; }
                    }
                }
                _hasUnsavedEdits = dirty;
                PostRpcSuccess(id, CreateOkDict());
                return;
            }

            if (string.Equals(method, "show_balloon_tip", StringComparison.OrdinalIgnoreCase))
            {
                string title = string.Empty;
                string message = string.Empty;
                int timeoutMs = 2500;
                if (rpcParams != null)
                {
                    if (rpcParams.ContainsKey("title") && rpcParams["title"] != null) title = rpcParams["title"].ToString();
                    else if (rpcParams.ContainsKey("Title") && rpcParams["Title"] != null) title = rpcParams["Title"].ToString();
                    if (rpcParams.ContainsKey("message") && rpcParams["message"] != null) message = rpcParams["message"].ToString();
                    else if (rpcParams.ContainsKey("Message") && rpcParams["Message"] != null) message = rpcParams["Message"].ToString();
                    if (rpcParams.ContainsKey("timeoutMs") && rpcParams["timeoutMs"] != null)
                    {
                        try { timeoutMs = Convert.ToInt32(rpcParams["timeoutMs"]); } catch { timeoutMs = 2500; }
                    }
                    else if (rpcParams.ContainsKey("TimeoutMs") && rpcParams["TimeoutMs"] != null)
                    {
                        try { timeoutMs = Convert.ToInt32(rpcParams["TimeoutMs"]); } catch { timeoutMs = 2500; }
                    }
                }
                if (timeoutMs < 500) timeoutMs = 500;
                if (_notifyIcon != null && !_opts.SmokeTest && (!string.IsNullOrEmpty(title) || !string.IsNullOrEmpty(message)))
                {
                    try
                    {
                        _notifyIcon.ShowBalloonTip(
                            timeoutMs,
                            string.IsNullOrEmpty(title) ? "RelayStudio" : title,
                            message ?? string.Empty,
                            ToolTipIcon.None
                        );
                    }
                    catch { }
                }
                PostRpcSuccess(id, CreateOkDict());
                return;
            }

            if (string.Equals(method, "copy_clipboard", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    string text = string.Empty;
                    if (rpcParams != null)
                    {
                        if (rpcParams.ContainsKey("text") && rpcParams["text"] != null) text = rpcParams["text"].ToString();
                        else if (rpcParams.ContainsKey("Text") && rpcParams["Text"] != null) text = rpcParams["Text"].ToString();
                    }
                    if (!string.IsNullOrEmpty(text))
                    {
                        Clipboard.SetText(text);
                    }
                    PostRpcSuccess(id, CreateOkDict());
                }
                catch (Exception ex)
                {
                    PostRpcError(id, ex.Message);
                }
                return;
            }

            if (string.Equals(method, "pick_and_add_cli_agent", StringComparison.OrdinalIgnoreCase))
            {
                string suppliedPath = string.Empty;
                if (rpcParams != null && rpcParams.ContainsKey("path") && rpcParams["path"] != null)
                {
                    suppliedPath = rpcParams["path"].ToString();
                }
                if (string.IsNullOrWhiteSpace(suppliedPath))
                {
                    using (OpenFileDialog dlg = new OpenFileDialog())
                    {
                        dlg.Title = "选择本地 CLI 智能体可执行程序";
                        dlg.Filter = "CLI 可执行程序 (*.exe;*.cmd;*.bat;*.ps1)|*.exe;*.cmd;*.bat;*.ps1|所有文件 (*.*)|*.*";
                        dlg.CheckFileExists = true;
                        if (dlg.ShowDialog(this) != DialogResult.OK || string.IsNullOrWhiteSpace(dlg.FileName))
                        {
                            Dictionary<string, object> cancelledRes = new Dictionary<string, object>();
                            cancelledRes["cancelled"] = true;
                            PostRpcSuccess(id, cancelledRes);
                            return;
                        }
                        suppliedPath = dlg.FileName;
                    }
                }
                if (rpcParams == null) rpcParams = new Dictionary<string, object>();
                rpcParams["path"] = suppliedPath;
                msg["params"] = rpcParams;
                rawJson = _json.Serialize(msg);
            }

            _worker.EnqueueRpc(rawJson, delegate(string respJson)
            {
                if (this.IsDisposed) return;
                try
                {
                    this.BeginInvoke((MethodInvoker)delegate
                    {
                        if (this.IsDisposed) return;
                        respJson = SyncHostChromeFromRpcResponse(method, respJson);
                        PostJsonToWeb(respJson);
                    });
                }
                catch { }
            });
        }

        private string SyncHostChromeFromRpcResponse(string method, string respJson)
        {
            if (method != "get_fast_bootstrap" &&
                method != "boot_init" &&
                method != "set_theme_mode" &&
                method != "step_quick_theme" &&
                method != "get_infra_bundle" &&
                method != "rescan_cli_agents" &&
                method != "reset_layout")
            {
                return respJson;
            }
            try
            {
                Dictionary<string, object> env = _json.Deserialize<Dictionary<string, object>>(respJson);
                if (env == null || !env.ContainsKey("ok") || !Convert.ToBoolean(env["ok"])) return respJson;
                Dictionary<string, object> res = env.ContainsKey("result") ? (env["result"] as Dictionary<string, object>) : null;
                if (res == null) return respJson;

                if (method == "reset_layout" && this.WindowState == FormWindowState.Normal)
                {
                    int rw = res.ContainsKey("WinWidth") && res["WinWidth"] != null ? Convert.ToInt32(res["WinWidth"]) : 1320;
                    int rh = res.ContainsKey("WinHeight") && res["WinHeight"] != null ? Convert.ToInt32(res["WinHeight"]) : 840;
                    if (rw >= 740 && rh >= 500)
                    {
                        double scale = GetCurrentDpiScale();
                        Screen curScreen = null;
                        if (!_opts.SmokeTest)
                        {
                            try { curScreen = Screen.FromControl(this); } catch { curScreen = Screen.PrimaryScreen; }
                        }
                        this.Size = ClampPhysicalSizeToWorkingArea(
                            LogicalToPhysical(rw, scale),
                            LogicalToPhysical(rh, scale),
                            curScreen
                        );
                        if (!_opts.SmokeTest && curScreen != null)
                        {
                            Rectangle wa = curScreen.WorkingArea;
                            if (this.Right > wa.Right)
                            {
                                this.Left = Math.Max(wa.Left + 12, wa.Right - this.Width - 12);
                            }
                            if (this.Bottom > wa.Bottom)
                            {
                                this.Top = Math.Max(wa.Top + 12, wa.Bottom - this.Height - 12);
                            }
                        }
                    }
                    return respJson;
                }

                bool themeTouched = false;
                if (res.ContainsKey("themeMode") && res["themeMode"] != null)
                {
                    _themeMode = res["themeMode"].ToString().ToLowerInvariant();
                    themeTouched = true;
                }
                if (res.ContainsKey("effectiveTheme") && res["effectiveTheme"] != null)
                {
                    bool nextDark = string.Equals(res["effectiveTheme"].ToString(), "dark", StringComparison.OrdinalIgnoreCase);
                    themeTouched = true;
                    if (nextDark != _isDarkTheme)
                    {
                        _isDarkTheme = nextDark;
                        Color bg = _isDarkTheme ? DarkBg : LightBg;
                        this.BackColor = bg;
                        _webView.DefaultBackgroundColor = bg;
                        ApplyDwmDarkMode(_isDarkTheme);
                    }
                }
                if (themeTouched)
                {
                    ApplyTrayTheme();
                }
                if (res.ContainsKey("shieldBaseUrl"))
                {
                    res["windowMaximized"] = (this.WindowState == FormWindowState.Maximized);
                    env["result"] = res;
                    return _json.Serialize(env);
                }
            }
            catch { }
            return respJson;
        }

        private static Dictionary<string, object> CreateOkDict()
        {
            Dictionary<string, object> d = new Dictionary<string, object>();
            d["ok"] = true;
            return d;
        }

        private void PostRpcSuccess(string id, object resultObj)
        {
            Dictionary<string, object> env = new Dictionary<string, object>();
            env["type"] = "rpc_response";
            env["id"] = id ?? string.Empty;
            env["ok"] = true;
            env["result"] = resultObj;
            PostObjectToWeb(env);
        }

        private void PostRpcError(string id, string errorMsg)
        {
            Dictionary<string, object> env = new Dictionary<string, object>();
            env["type"] = "rpc_response";
            env["id"] = id ?? string.Empty;
            env["ok"] = false;
            env["error"] = errorMsg ?? "Unknown error";
            PostObjectToWeb(env);
        }

        private void PostObjectToWeb(object obj)
        {
            try
            {
                PostJsonToWeb(_json.Serialize(obj));
            }
            catch { }
        }

        private void PostJsonToWeb(string json)
        {
            if (!_coreReady || _webView == null || _webView.IsDisposed || _webView.CoreWebView2 == null) return;
            try
            {
                _webView.CoreWebView2.PostWebMessageAsJson(json);
            }
            catch { }
        }

        private void InitializeTrayIcon(string icoPath)
        {
            _trayMenu = new ContextMenuStrip();

            ToolStripMenuItem openItem = new ToolStripMenuItem("打开 RelayStudio 工作台");
            openItem.Font = new Font(_trayMenu.Font, FontStyle.Bold);
            openItem.Click += delegate { RestoreFromTray(); };
            _trayMenu.Items.Add(openItem);

            ToolStripMenuItem reconnectItem = new ToolStripMenuItem("一键重连本地内核与隧道");
            reconnectItem.Click += delegate { InvokeTrayRpc("one_click_reconnect", null, "已完成内核与隧道重连自检"); };
            _trayMenu.Items.Add(reconnectItem);

            _trayMenu.Items.Add(new ToolStripSeparator());

            _trayItemThemeToggle = new ToolStripMenuItem(_isDarkTheme
                ? "\u2600 切换为浅色模式 (Ctrl+Shift+D)"
                : "\uD83C\uDF19 切换为深色模式 (Ctrl+Shift+D)");
            _trayItemThemeToggle.Click += delegate { InvokeTrayThemeRpc("step_quick_theme", null); };
            _trayMenu.Items.Add(_trayItemThemeToggle);

            _trayItemThemeSystem = new ToolStripMenuItem("\uD83D\uDDA5 外观主题：跟随系统");
            _trayItemThemeSystem.Checked = string.Equals(_themeMode, "system", StringComparison.OrdinalIgnoreCase);
            _trayItemThemeSystem.Click += delegate
            {
                Dictionary<string, object> p = new Dictionary<string, object>();
                p["themeMode"] = "system";
                InvokeTrayThemeRpc("set_theme_mode", p);
            };
            _trayMenu.Items.Add(_trayItemThemeSystem);

            _trayMenu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem exitItem = new ToolStripMenuItem("彻底退出 RelayStudio（关闭后台服务）");
            exitItem.Click += delegate { ExitAndShutdownAllServices(); };
            _trayMenu.Items.Add(exitItem);

            ApplyTrayTheme();

            _notifyIcon = new NotifyIcon();
            _notifyIcon.Text = "RelayStudio · 智能体接力与多栏工作台";
            if (File.Exists(icoPath))
            {
                try { _notifyIcon.Icon = new Icon(icoPath); } catch { }
            }
            if (_notifyIcon.Icon == null)
            {
                _notifyIcon.Icon = BuildFallbackTrayIcon();
            }
            _notifyIcon.ContextMenuStrip = _trayMenu;
            _notifyIcon.MouseClick += delegate(object s, MouseEventArgs me)
            {
                if (me.Button == MouseButtons.Left)
                {
                    RestoreFromTray();
                }
            };
            _notifyIcon.DoubleClick += delegate { RestoreFromTray(); };
            _notifyIcon.Visible = true;
        }

        private void ApplyTrayTheme()
        {
            if (_trayMenu == null) return;
            try
            {
                Color trayBg = _isDarkTheme ? Color.FromArgb(24, 24, 27) : Color.White;
                Color trayFg = _isDarkTheme ? Color.FromArgb(244, 244, 245) : Color.FromArgb(24, 24, 27);
                _trayMenu.BackColor = trayBg;
                _trayMenu.ForeColor = trayFg;
                foreach (ToolStripItem it in _trayMenu.Items)
                {
                    if (it != null)
                    {
                        it.BackColor = trayBg;
                        it.ForeColor = trayFg;
                    }
                }
                if (_trayItemThemeToggle != null)
                {
                    _trayItemThemeToggle.Text = _isDarkTheme
                        ? "\u2600 切换为浅色模式 (Ctrl+Shift+D)"
                        : "\uD83C\uDF19 切换为深色模式 (Ctrl+Shift+D)";
                }
                if (_trayItemThemeSystem != null)
                {
                    _trayItemThemeSystem.Checked = string.Equals(_themeMode, "system", StringComparison.OrdinalIgnoreCase);
                }
            }
            catch { }
        }

        private void ExitAndShutdownAllServices()
        {
            _exiting = true;
            _hasUnsavedEdits = false;
            if (_guardianTimer != null) _guardianTimer.Stop();
            if (_suspendTimer != null) _suspendTimer.Stop();
            if (_notifyIcon != null)
            {
                try { _notifyIcon.Visible = false; } catch { }
            }
            try
            {
                ManualResetEventSlim done = new ManualResetEventSlim(false);
                string shutdownReq = "{\"type\":\"rpc_request\",\"id\":\"tray_shutdown\",\"method\":\"shutdown_all_services\",\"params\":{}}";
                _worker.EnqueueRpc(shutdownReq, delegate(string _)
                {
                    try { done.Set(); } catch { }
                });
                done.Wait(1800);
            }
            catch { }
            if (!_opts.Isolated)
            {
                try
                {
                    foreach (Process p in Process.GetProcessesByName("relaystudio-core"))
                    {
                        try { p.Kill(); } catch { }
                        try { p.Dispose(); } catch { }
                    }
                }
                catch { }
            }
            this.Close();
        }

        private static Icon BuildFallbackTrayIcon()
        {
            using (Bitmap bmp = new Bitmap(32, 32))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    using (SolidBrush bg = new SolidBrush(Color.FromArgb(255, 24, 24, 27)))
                    {
                        g.FillEllipse(bg, 1, 1, 30, 30);
                    }
                    using (Font f = new Font("Segoe UI", 16f, FontStyle.Bold, GraphicsUnit.Pixel))
                    using (StringFormat sf = new StringFormat())
                    {
                        sf.Alignment = StringAlignment.Center;
                        sf.LineAlignment = StringAlignment.Center;
                        g.DrawString("R", f, Brushes.White, new RectangleF(0, 1, 32, 32), sf);
                    }
                }
                return Icon.FromHandle(bmp.GetHicon());
            }
        }

        private void InvokeTrayRpc(string method, Dictionary<string, object> rpcParams, string toastMessage)
        {
            Dictionary<string, object> req = new Dictionary<string, object>();
            req["type"] = "rpc_request";
            req["id"] = "tray_" + Guid.NewGuid().ToString("N");
            req["method"] = method;
            req["params"] = rpcParams ?? new Dictionary<string, object>();

            _worker.EnqueueRpc(_json.Serialize(req), delegate(string respJson)
            {
                if (this.IsDisposed) return;
                this.BeginInvoke((MethodInvoker)delegate
                {
                    if (this.IsDisposed) return;
                    try
                    {
                        Dictionary<string, object> env = _json.Deserialize<Dictionary<string, object>>(respJson);
                        if (env != null && env.ContainsKey("ok") && Convert.ToBoolean(env["ok"]) && env.ContainsKey("result"))
                        {
                            Dictionary<string, object> push = new Dictionary<string, object>();
                            push["type"] = "infra_updated";
                            push["infra"] = env["result"];
                            if (!string.IsNullOrEmpty(toastMessage)) push["toast"] = toastMessage;
                            PostObjectToWeb(push);
                        }
                    }
                    catch { }
                });
            });
        }

        private void InvokeTrayThemeRpc(string method, Dictionary<string, object> rpcParams)
        {
            Dictionary<string, object> req = new Dictionary<string, object>();
            req["type"] = "rpc_request";
            req["id"] = "tray_theme_" + Guid.NewGuid().ToString("N");
            req["method"] = method;
            req["params"] = rpcParams ?? new Dictionary<string, object>();

            _worker.EnqueueRpc(_json.Serialize(req), delegate(string respJson)
            {
                if (this.IsDisposed) return;
                this.BeginInvoke((MethodInvoker)delegate
                {
                    if (this.IsDisposed) return;
                    SyncHostChromeFromRpcResponse(method, respJson);
                    try
                    {
                        Dictionary<string, object> env = _json.Deserialize<Dictionary<string, object>>(respJson);
                        Dictionary<string, object> res = (env != null && env.ContainsKey("result")) ? (env["result"] as Dictionary<string, object>) : null;
                        if (res != null)
                        {
                            Dictionary<string, object> push = new Dictionary<string, object>();
                            push["type"] = "theme_changed";
                            push["themeMode"] = res.ContainsKey("themeMode") ? res["themeMode"] : _themeMode;
                            push["systemTheme"] = res.ContainsKey("systemTheme") ? res["systemTheme"] : (Program.IsWindowsSystemDarkTheme() ? "dark" : "light");
                            push["effectiveTheme"] = res.ContainsKey("effectiveTheme") ? res["effectiveTheme"] : (_isDarkTheme ? "dark" : "light");
                            PostObjectToWeb(push);
                        }
                    }
                    catch { }
                });
            });
        }

        private void OnSystemUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
        {
            if (this.IsDisposed) return;
            try
            {
                this.BeginInvoke((MethodInvoker)delegate
                {
                    if (this.IsDisposed) return;
                    bool sysDark = Program.IsWindowsSystemDarkTheme();
                    string sysStr = sysDark ? "dark" : "light";
                    if (string.Equals(_themeMode, "system", StringComparison.OrdinalIgnoreCase))
                    {
                        if (sysDark != _isDarkTheme)
                        {
                            _isDarkTheme = sysDark;
                            Color bg = _isDarkTheme ? DarkBg : LightBg;
                            this.BackColor = bg;
                            _webView.DefaultBackgroundColor = bg;
                            ApplyDwmDarkMode(_isDarkTheme);
                        }
                        ApplyTrayTheme();
                        Dictionary<string, object> push = new Dictionary<string, object>();
                        push["type"] = "theme_changed";
                        push["themeMode"] = "system";
                        push["systemTheme"] = sysStr;
                        push["effectiveTheme"] = sysStr;
                        PostObjectToWeb(push);
                    }
                });
            }
            catch { }
        }

        private void StartRestoreEventListener()
        {
            if (_restoreEvent == null) return;
            _ipcRestoreThread = new Thread(delegate()
            {
                while (!_exiting && !this.IsDisposed)
                {
                    try
                    {
                        if (_restoreEvent.WaitOne(500))
                        {
                            if (!this.IsDisposed)
                            {
                                this.BeginInvoke((MethodInvoker)delegate { RestoreFromTray(); });
                            }
                        }
                    }
                    catch { break; }
                }
            });
            _ipcRestoreThread.IsBackground = true;
            _ipcRestoreThread.Name = "RelayStudio.RestoreEventListener";
            _ipcRestoreThread.Start();
        }

        private bool ConfirmDiscardUnsavedEditsIfNeeded()
        {
            if (!_hasUnsavedEdits || _exiting || _opts.SmokeTest)
            {
                return true;
            }
            DialogResult ans = MessageBox.Show(
                this,
                "尚有未保存的输入。最小化到托盘前是否放弃这些未保存输入？",
                "RelayStudio",
                MessageBoxButtons.OKCancel,
                MessageBoxIcon.Question
            );
            if (ans == DialogResult.Cancel)
            {
                return false;
            }
            _hasUnsavedEdits = false;
            Dictionary<string, object> discardMsg = new Dictionary<string, object>();
            discardMsg["type"] = "discard_unsaved_edits";
            PostObjectToWeb(discardMsg);
            return true;
        }

        private void HideToTray()
        {
            this.ShowInTaskbar = false;
            this.Hide();

            if (_coreReady && _webView.CoreWebView2 != null)
            {
                Dictionary<string, object> push = new Dictionary<string, object>();
                push["type"] = "lifecycle";
                push["visible"] = false;
                PostObjectToWeb(push);
                _suspendTimer.Stop();
                _suspendTimer.Start();
            }

            if (_notifyIcon != null && !_trayHintShown && !_opts.SmokeTest)
            {
                _trayHintShown = true;
                try
                {
                    _notifyIcon.ShowBalloonTip(
                        2000,
                        "RelayStudio 仍在后台运行",
                        "双击右下角 R 托盘图标可随时唤出工作台；右键托盘图标可彻底退出。",
                        ToolTipIcon.None
                    );
                }
                catch { }
            }
        }

        private async void OnSuspendTimerTick(object sender, EventArgs e)
        {
            _suspendTimer.Stop();
            if (this.Visible || !_coreReady || _webView == null || _webView.IsDisposed || _webView.CoreWebView2 == null)
            {
                return;
            }
            try
            {
                if (!_webView.CoreWebView2.IsSuspended)
                {
                    await _webView.CoreWebView2.TrySuspendAsync();
                }
            }
            catch { }
        }

        public void RestoreFromTray()
        {
            _suspendTimer.Stop();
            try
            {
                if (_coreReady && _webView != null && !_webView.IsDisposed && _webView.CoreWebView2 != null)
                {
                    if (_webView.CoreWebView2.IsSuspended)
                    {
                        _webView.CoreWebView2.Resume();
                    }
                }
            }
            catch { }

            this.ShowInTaskbar = true;
            this.Opacity = 1.0;
            if (!this.Visible)
            {
                this.Show();
            }
            if (this.WindowState == FormWindowState.Minimized)
            {
                this.WindowState = FormWindowState.Normal;
            }
            try
            {
                NativeMethods.ShowWindow(this.Handle, NativeMethods.SW_SHOW);
                NativeMethods.SetForegroundWindow(this.Handle);
            }
            catch { }
            this.Activate();

            if (_coreReady && _webView.CoreWebView2 != null)
            {
                Dictionary<string, object> push = new Dictionary<string, object>();
                push["type"] = "lifecycle";
                push["visible"] = true;
                push["maximized"] = (this.WindowState == FormWindowState.Maximized);
                PostObjectToWeb(push);
            }
        }

        private void OnGuardianTimerTick(object sender, EventArgs e)
        {
            if (_guardianInFlight || _exiting || this.IsDisposed) return;
            _guardianInFlight = true;
            _worker.EnqueueGuardianTick(delegate(string tickJson)
            {
                _guardianInFlight = false;
                if (this.IsDisposed || _exiting) return;
                try
                {
                    Dictionary<string, object> tick = _json.Deserialize<Dictionary<string, object>>(tickJson);
                    if (tick != null && tick.ContainsKey("changed") && Convert.ToBoolean(tick["changed"]) && tick.ContainsKey("infra") && tick["infra"] != null)
                    {
                        this.BeginInvoke((MethodInvoker)delegate
                        {
                            if (this.IsDisposed || _exiting || !this.Visible) return;
                            Dictionary<string, object> push = new Dictionary<string, object>();
                            push["type"] = "infra_updated";
                            push["infra"] = tick["infra"];
                            PostObjectToWeb(push);
                        });
                    }
                }
                catch { }
            });
        }

        private void OnFormClosing(object sender, FormClosingEventArgs e)
        {
            if (!_opts.SmokeTest && !_exiting && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                if (!ConfirmDiscardUnsavedEditsIfNeeded())
                {
                    return;
                }
                HideToTray();
                return;
            }

            _exiting = true;
            if (_suspendTimer != null) _suspendTimer.Stop();
            if (_guardianTimer != null) _guardianTimer.Stop();
            if (_smokeTimeoutTimer != null) _smokeTimeoutTimer.Stop();
            if (_smokeFallbackProbeTimer != null) _smokeFallbackProbeTimer.Stop();

            if (!_opts.SmokeTest)
            {
                try { SystemEvents.UserPreferenceChanged -= OnSystemUserPreferenceChanged; } catch { }
            }
            if (_notifyIcon != null)
            {
                try { _notifyIcon.Visible = false; } catch { }
                try { _notifyIcon.Dispose(); } catch { }
                _notifyIcon = null;
            }
            if (_worker != null)
            {
                try { _worker.Dispose(); } catch { }
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
        '/platform:x64',
        '/optimize+',
        "/out:$OutputPath",
        "/reference:$smaAssembly",
        "/reference:$wvCoreDll",
        "/reference:$wvWinFormsDll",
        '/reference:System.Windows.Forms.dll',
        '/reference:System.Drawing.dll',
        '/reference:System.Web.Extensions.dll'
    )
    if (Test-Path -LiteralPath $iconPath) {
        $cscArgs += "/win32icon:$iconPath"
    }
    $cscArgs += $tmpCs
    & $cscPath @cscArgs
    if ($LASTEXITCODE -ne 0) {
        throw "csc.exe 编译失败 (ExitCode=$LASTEXITCODE)"
    }
    Write-Host "Successfully built WebView2 launcher: $OutputPath"
} finally {
    if (Test-Path -LiteralPath $tmpCs) {
        Remove-Item -LiteralPath $tmpCs -Force -ErrorAction SilentlyContinue
    }
}
