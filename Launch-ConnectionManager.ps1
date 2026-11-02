$ErrorActionPreference = 'Stop'
Add-Type -Namespace Win32 -Name ConsoleHider -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction SilentlyContinue
try {
    $cHwnd = [Win32.ConsoleHider]::GetConsoleWindow()
    if ($cHwnd -ne [IntPtr]::Zero) { [void][Win32.ConsoleHider]::ShowWindow($cHwnd, 0) }
} catch { }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"')) | Out-Null
    return
}
try {
    . (Join-Path $PSScriptRoot '连接管理.ps1')
} catch {
    Add-Type -AssemblyName PresentationFramework
    [void][Windows.MessageBox]::Show(('连接窗口无法打开：' + $_.Exception.Message + "`n配置位置：" + (Join-Path $PSScriptRoot 'data')), 'RelayStudio管理', 'OK', 'Error')
    exit 1
}
