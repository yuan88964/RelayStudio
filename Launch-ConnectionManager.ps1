param(
    [switch]$Legacy,
    [switch]$StartMinimized
)
$ErrorActionPreference = 'Stop'
Add-Type -Namespace Win32 -Name ConsoleHider -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction SilentlyContinue
try {
    $cHwnd = [Win32.ConsoleHider]::GetConsoleWindow()
    if ($cHwnd -ne [IntPtr]::Zero) { [void][Win32.ConsoleHider]::ShowWindow($cHwnd, 0) }
} catch { }

$launcherExe = Join-Path $PSScriptRoot 'RelayStudio.exe'
if (-not $Legacy -and (Test-Path -LiteralPath $launcherExe)) {
    $exeArgs = @()
    if ($StartMinimized) { $exeArgs += '--minimized' }
    if ($exeArgs.Count -gt 0) {
        Start-Process -FilePath $launcherExe -ArgumentList $exeArgs -WorkingDirectory $PSScriptRoot | Out-Null
    } else {
        Start-Process -FilePath $launcherExe -WorkingDirectory $PSScriptRoot | Out-Null
    }
    return
}

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) { $pwsh = 'powershell.exe' }
    $psArgs = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"'))
    if ($Legacy) { $psArgs += '-Legacy' }
    if ($StartMinimized) { $psArgs += '-StartMinimized' }
    Start-Process -FilePath $pwsh -ArgumentList $psArgs | Out-Null
    return
}
try {
    . (Join-Path $PSScriptRoot '连接管理.ps1') -StartMinimized:$StartMinimized
} catch {
    Add-Type -AssemblyName PresentationFramework
    [void][Windows.MessageBox]::Show(('连接窗口无法打开：' + $_.Exception.Message + "`n配置位置：" + (Join-Path $PSScriptRoot 'data')), 'RelayStudio管理', 'OK', 'Error')
    exit 1
}
