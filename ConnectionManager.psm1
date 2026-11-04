Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

function New-ConnectionContext {
    param([string]$DataRoot = (Join-Path $PSScriptRoot 'data'), [string]$ReleaseRoot = (Split-Path $PSScriptRoot -Parent), [switch]$Isolated)
    [pscustomobject]@{
        DataRoot = [IO.Path]::GetFullPath($DataRoot)
        ReleaseRoot = [IO.Path]::GetFullPath($ReleaseRoot)
        SettingsPath = Join-Path $DataRoot 'settings.json'
        KeyPath = Join-Path $DataRoot 'openai-key.dpapi'
        TokenPath = Join-Path $DataRoot 'relay-token.dpapi'
        ProfilePath = Join-Path $DataRoot 'profiles\relay-tunnel.yaml'
        StatePath = Join-Path $DataRoot 'runtime.json'
        SessionAliasesPath = Join-Path $DataRoot 'session-aliases.json'
        ProfilesStorePath = Join-Path $DataRoot 'credential-profiles.json'
        TaskArchivesPath = Join-Path $DataRoot 'task-archives.json'
        WindowLayoutPath = Join-Path $DataRoot 'window-layout.json'
        TasksRoot = ''
        ShieldScriptPath = Join-Path $PSScriptRoot 'McpReadOnlyShield.py'
        LegacyKeyPath = if ($Isolated) { '' } else { Join-Path $ReleaseRoot 'openai-tunnel-key.dpapi' }
        LegacyProfilePath = if ($Isolated) { '' } else { Join-Path $ReleaseRoot 'tunnel\profiles\local-coding-agent.yaml' }
        Isolated = [bool]$Isolated
    }
}

function ConvertTo-TunnelId {
    param([string]$Text)
    $decoded = [Uri]::UnescapeDataString($Text.Trim())
    $found = [regex]::Matches($decoded, '(?<![A-Za-z0-9_])tunnel_(?:[a-z0-9]{4}_)?[a-z0-9]{32}(?![A-Za-z0-9_])')
    $ids = @($found | ForEach-Object Value | Select-Object -Unique)
    if ($ids.Count -ne 1) { throw '请粘贴完整的 tunnel_ 开头的隧道编号，或包含该编号的链接。普通隧道列表页不包含编号。' }
    return $ids[0]
}

function Get-DefaultConnectionSettings {
    param($Context)
    $relRoot = if ($Context -and $Context.PSObject.Properties['ReleaseRoot'] -and $Context.ReleaseRoot) { [string]$Context.ReleaseRoot } elseif ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { '' }
    $legProf = if ($Context -and $Context.PSObject.Properties['LegacyProfilePath'] -and $Context.LegacyProfilePath) { [string]$Context.LegacyProfilePath } else { '' }
    $root = if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'bin\relaystudio-core.exe'))) {
        $PSScriptRoot
    } elseif ($relRoot -and (Test-Path -LiteralPath (Join-Path $relRoot 'bin\relaystudio-core.exe'))) {
        $relRoot
    } elseif ($PSScriptRoot) {
        $PSScriptRoot
    } else {
        Join-Path $env:LOCALAPPDATA 'RelayStudio'
    }
    $id = ''; $base = 'https://api.openai.com'
    if ($legProf -and (Test-Path -LiteralPath $legProf)) {
        $text = [IO.File]::ReadAllText($legProf)
        if ($text -match 'tunnel_id:\s*"?([^"\s]+)') { $id = $Matches[1] }
        if ($text -match 'base_url:\s*"?([^"\s]+)') { $base = $Matches[1] }
    }
    $tunBin = if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'bin\tunnel-client.exe'))) {
        Join-Path $PSScriptRoot 'bin\tunnel-client.exe'
    } elseif ($relRoot -and (Test-Path -LiteralPath (Join-Path $relRoot 'bin\tunnel-client.exe'))) {
        Join-Path $relRoot 'bin\tunnel-client.exe'
    } elseif ($relRoot) {
        Join-Path $relRoot 'tunnel\tunnel-client.exe'
    } else { '' }
    [pscustomobject]@{
        schema_version = 1; tunnel_id = $id; api_base_url = $base
        runtime_root = $root; tunnel_client = $tunBin
        health_port = 8789; credential_revision = 'legacy'
        readonly_shield = $true; shield_port = 8766
        core_port = 8765
        acp_max_concurrent_prompts = 4
        acp_default_profile = 'codex'
        browser_enabled = $true
        startup_mode = 'tray'
        auto_archive_completed_mode = '3d'
    }
}

function Read-ConnectionSettings {
    param($Context)
    $defaultSettings = Get-DefaultConnectionSettings $Context
    $settings = Get-DefaultConnectionSettings $Context
    $setPath = if ($Context -and $Context.PSObject.Properties['SettingsPath'] -and $Context.SettingsPath) {
        [string]$Context.SettingsPath
    } elseif ($Context -and $Context.PSObject.Properties['DataRoot'] -and $Context.DataRoot) {
        Join-Path $Context.DataRoot 'settings.json'
    } else { '' }
    if ($setPath -and (Test-Path -LiteralPath $setPath)) {
        $saved = [IO.File]::ReadAllText($setPath) | ConvertFrom-Json
        if ($saved.schema_version -ne 1) { throw '配置版本不兼容，请保留现有文件并查看使用说明。' }
        foreach ($property in $settings.PSObject.Properties.Name) {
            if ($saved.PSObject.Properties.Name -contains $property) { $settings.$property = $saved.$property }
        }
        foreach ($optProp in @('default_browser_profile', 'preferred_browser_profiles', 'workspace_roots', 'skills_junction_target', 'agents_md_target', 'python_path', 'extra_bin_dirs', 'auto_archive_completed_mode', 'custom_cli_agents')) {
            if ($saved.PSObject.Properties.Name -contains $optProp) {
                $settings | Add-Member -NotePropertyName $optProp -NotePropertyValue $saved.$optProp -Force
            }
        }
        if (-not $settings.runtime_root -or -not (Test-Path -LiteralPath $settings.runtime_root)) {
            $settings.runtime_root = $defaultSettings.runtime_root
        }
        if (-not $settings.tunnel_client -or -not (Test-Path -LiteralPath $settings.tunnel_client)) {
            $settings.tunnel_client = $defaultSettings.tunnel_client
        }
        if (-not $settings.api_base_url) {
            $settings.api_base_url = 'https://api.openai.com'
        }
    }
    return $settings
}

function Test-SavedOpenAIKey {
    param($Context)
    return ((Test-Path -LiteralPath $Context.KeyPath) -or ($Context.LegacyKeyPath -and (Test-Path -LiteralPath $Context.LegacyKeyPath)))
}

function Protect-ConnectionSecret {
    param([string]$Secret)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Secret)
    try {
        $cipher = [Security.Cryptography.ProtectedData]::Protect($bytes, [Text.Encoding]::UTF8.GetBytes('relaystudio.connection.v1'), [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Convert]::ToBase64String($cipher)
    } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Read-ConnectionSecret {
    param([string]$Path, [string]$Entropy = 'relaystudio.connection.v1')
    $cipher = [Convert]::FromBase64String([IO.File]::ReadAllText($Path).Trim())
    $plain = [Security.Cryptography.ProtectedData]::Unprotect($cipher, [Text.Encoding]::UTF8.GetBytes($Entropy), [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { return [Text.Encoding]::UTF8.GetString($plain) } finally { [Array]::Clear($plain, 0, $plain.Length) }
}

function Write-AtomicConnectionText {
    param([string]$Path, [string]$Text)
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Save-ConnectionSettings {
    param($Context, $Settings, [string]$ApiKey = '', [string]$RelayToken = '', [scriptblock]$BeforeCommit)
    $Settings.tunnel_id = ConvertTo-TunnelId $Settings.tunnel_id
    $base = $null
    if (-not [Uri]::TryCreate($Settings.api_base_url, [UriKind]::Absolute, [ref]$base) -or $base.Scheme -ne 'https' -or $base.UserInfo -or $base.Query -or $base.Fragment) {
        throw 'OpenAI 服务地址须为完整的 HTTPS 地址，不能包含密钥、查询参数或登录信息。'
    }
    $Settings.api_base_url = $base.AbsoluteUri.TrimEnd('/')
    $Settings.runtime_root = [IO.Path]::GetFullPath($Settings.runtime_root.Trim())
    $Settings.tunnel_client = [IO.Path]::GetFullPath($Settings.tunnel_client.Trim())
    $ApiKey = $ApiKey.Trim(); $RelayToken = $RelayToken.Trim()
    if ($ApiKey -and ($ApiKey -match '^[a-z]+://' -or $ApiKey -match '\s' -or $ApiKey.Length -lt 12)) { throw 'API Key 栏请粘贴密钥本身，不是网页链接；密钥中不能有空格或换行。' }
    if ($RelayToken -match '^Bearer\s+(.+)$') { $RelayToken = $Matches[1] }
    if ($RelayToken -match '\s') { throw 'RelayStudio 访问令牌中不能有空格或换行。' }
    if (-not $ApiKey -and -not (Test-SavedOpenAIKey $Context)) { throw '请先粘贴 OpenAI API Key，再保存。' }
    $writes = [ordered]@{}
    if ($ApiKey) { $writes[$Context.KeyPath] = Protect-ConnectionSecret $ApiKey }
    if ($RelayToken) { $writes[$Context.TokenPath] = Protect-ConnectionSecret $RelayToken }
    if ($ApiKey -or $RelayToken) { $Settings.credential_revision = [Guid]::NewGuid().ToString('N') }
    if (Test-Path -LiteralPath $Context.SettingsPath) {
        try {
            $diskSaved = [IO.File]::ReadAllText($Context.SettingsPath) | ConvertFrom-Json
            foreach ($optProp in @('default_browser_profile', 'preferred_browser_profiles', 'workspace_roots', 'skills_junction_target', 'agents_md_target', 'python_path', 'extra_bin_dirs', 'auto_archive_completed_mode', 'custom_cli_agents')) {
                if (-not ($Settings.PSObject.Properties.Name -contains $optProp) -and ($diskSaved.PSObject.Properties.Name -contains $optProp)) {
                    $Settings | Add-Member -NotePropertyName $optProp -NotePropertyValue $diskSaved.$optProp -Force
                }
            }
        } catch {}
    }
    $writes[$Context.SettingsPath] = $Settings | ConvertTo-Json -Depth 6
    [IO.Directory]::CreateDirectory($Context.DataRoot) | Out-Null
    $lock = [IO.File]::Open((Join-Path $Context.DataRoot 'save.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $before = @{}; $committed = New-Object 'System.Collections.Generic.List[string]'
    try {
        foreach ($path in $writes.Keys) { $before[$path] = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllBytes($path) } else { $null } }
        if ($BeforeCommit) { & $BeforeCommit }
        foreach ($path in $writes.Keys) { Write-AtomicConnectionText $path $writes[$path]; $committed.Add($path) }
    } catch {
        foreach ($path in $committed) {
            if ($null -ne $before[$path]) { [IO.File]::WriteAllBytes($path, $before[$path]) }
            elseif (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        throw
    } finally { $lock.Dispose() }
}

function Get-OfficialCoreEndpoint {
    param($Settings)
    $port = if ($Settings -and ($Settings.PSObject.Properties.Name -contains 'core_port') -and [int]$Settings.core_port -gt 0) { [int]$Settings.core_port } else { 8765 }
    $manifestPath = if ($Settings -and $Settings.runtime_root) { Join-Path $Settings.runtime_root 'runtime.json' } else { '' }
    $standaloneBin = if ($Settings -and $Settings.runtime_root) { Join-Path $Settings.runtime_root 'bin\relaystudio-core.exe' } else { '' }
    if ($manifestPath -and (Test-Path -LiteralPath $manifestPath)) {
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        if ($manifest.PSObject.Properties.Name -contains 'port' -and $manifest.port) { $port = [int]$manifest.port }
        $cpPath = Join-Path $Settings.runtime_root 'control-panel-settings.json'
        if (Test-Path -LiteralPath $cpPath) {
            $cp = [IO.File]::ReadAllText($cpPath) | ConvertFrom-Json
            if ($cp.PSObject.Properties.Name -contains 'port' -and $cp.port) { $port = [int]$cp.port }
        }
    } elseif ($standaloneBin -and (Test-Path -LiteralPath $standaloneBin)) {
        # Standalone RelayStudio engine directory
    } elseif ($Settings -and $Settings.runtime_root -and (Test-Path -LiteralPath $Settings.runtime_root)) {
        # Valid RelayStudio directory
    } else {
        throw '找不到 RelayStudio 本地内核目录。请在高级设置中检查内核文件夹路径。'
    }
    if ($port -lt 1 -or $port -gt 65535) { throw '配置中的内核端口无效。' }
    return "http://127.0.0.1:$port/mcp"
}

function Get-LocalCoreEndpoint {
    param($Settings)
    return (Get-OfficialCoreEndpoint $Settings)
}

function Test-LocalTcpPortOpen {
    param([int]$Port)
    if ($Port -le 0) { return $false }
    try {
        foreach ($ep in [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) {
            if ($ep.Port -eq $Port) { return $true }
        }
        return $false
    } catch {
        return $true
    }
}

function Test-LocalUrlPortOpen {
    param([string]$Url)
    if (-not $Url) { return $false }
    $parsed = $null
    if ([Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$parsed)) {
        if ($parsed.Host -in @('127.0.0.1', 'localhost', '::1')) {
            return (Test-LocalTcpPortOpen -Port $parsed.Port)
        }
    }
    return $true
}

function Invoke-ConnectionProbe {
    param([string]$Url, [string]$Authorization = '', [switch]$HeadersOnly)
    if (-not (Test-LocalUrlPortOpen $Url)) {
        return [pscustomobject]@{Status=0; Body=''}
    }
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.Proxy = $null
    $request.Timeout = 900; $request.ReadWriteTimeout = 900; $request.AllowAutoRedirect = $false
    if ($Authorization) { $request.Headers['Authorization'] = $Authorization }
    $response = $null
    try {
        try { $response = $request.GetResponse() }
        catch [Net.WebException] { if ($_.Exception.Response) { $response = $_.Exception.Response } else { return [pscustomobject]@{Status=0; Body=''} } }
        $body = ''
        if (-not $HeadersOnly) {
            $reader = New-Object IO.StreamReader($response.GetResponseStream())
            try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        return [pscustomobject]@{Status=[int]$response.StatusCode; Body=$body}
    } finally { if ($response) { $response.Dispose() } }
}

$script:cachedTunnelPidSig = ''
$script:cachedTunnelProcList = @()

function Get-RelatedTunnelProcesses {
    param($Context, $Settings)
    if ($Context.Isolated) { return @() }
    $fastProcs = @(Get-Process -Name 'tunnel-client' -ErrorAction SilentlyContinue)
    if ($fastProcs.Count -eq 0) {
        if (Test-Path -LiteralPath $Context.StatePath) {
            $healthPort = if ($Settings -and ($Settings.PSObject.Properties['health_port']) -and [int]$Settings.health_port -gt 0) { [int]$Settings.health_port } else { 8789 }
            $readyProbe = Invoke-ConnectionProbe "http://127.0.0.1:$healthPort/readyz"
            if ($readyProbe.Status -eq 200) {
                $st = try { [IO.File]::ReadAllText($Context.StatePath) | ConvertFrom-Json } catch { $null }
                $wPid = if ($st -and $st.PSObject.Properties['wrapper_pid']) { [int]$st.wrapper_pid } else { 99999 }
                return @([pscustomobject]@{Id=$wPid; Created=$null; Kind='Managed'; Path=$Settings.tunnel_client; CommandLine='--config'})
            }
        }
        $script:cachedTunnelPidSig = ''
        $script:cachedTunnelProcList = @()
        return @()
    }
    $pidSig = (($fastProcs | Select-Object -ExpandProperty Id | Sort-Object) -join ',') + '|' + $Context.ProfilePath
    if ($pidSig -eq $script:cachedTunnelPidSig -and $script:cachedTunnelProcList.Count -gt 0) {
        return $script:cachedTunnelProcList
    }
    $legacyDir = Join-Path $Context.ReleaseRoot 'tunnel\profiles'
    $allowed = @($Settings.tunnel_client, (Join-Path $Context.ReleaseRoot 'tunnel\tunnel-client.exe'))
    if (Test-Path -LiteralPath $Context.StatePath) {
        $state = [IO.File]::ReadAllText($Context.StatePath) | ConvertFrom-Json
        if ($state.PSObject.Properties.Name -contains 'client_path') { $allowed += $state.client_path }
    }
    $profilePattern = '(?:^|\s)--config\s+(?:"' + [regex]::Escape($Context.ProfilePath) + '"|' + [regex]::Escape($Context.ProfilePath) + ')(?:\s|$)'
    $legacyPattern = '(?:^|\s)--profile-dir\s+(?:"' + [regex]::Escape($legacyDir) + '"|' + [regex]::Escape($legacyDir) + ')(?:\s|$)'
    $result = @(foreach ($proc in @(Get-CimInstance Win32_Process -Filter "Name='tunnel-client.exe'" -ErrorAction SilentlyContinue)) {
        if (-not $proc.ExecutablePath -or -not $proc.CommandLine) { continue }
        if ([IO.Path]::GetFullPath($proc.ExecutablePath) -notin $allowed) { continue }
        $kind = ''
        if ($proc.CommandLine -match $profilePattern) { $kind = 'Managed' }
        elseif ($proc.CommandLine -match $legacyPattern -and $proc.CommandLine -match '--profile\s+local-coding-agent\b') { $kind = 'Legacy' }
        if ($kind) { [pscustomobject]@{Id=[int]$proc.ProcessId; Created=$proc.CreationDate; Kind=$kind; Path=$proc.ExecutablePath; CommandLine=$proc.CommandLine} }
    })
    if ($result.Count -eq 0 -and (Test-Path -LiteralPath $Context.StatePath)) {
        $healthPort = if ($Settings -and ($Settings.PSObject.Properties['health_port']) -and [int]$Settings.health_port -gt 0) { [int]$Settings.health_port } else { 8789 }
        $readyProbe = Invoke-ConnectionProbe "http://127.0.0.1:$healthPort/readyz"
        if ($readyProbe.Status -eq 200) {
            $result = @([pscustomobject]@{Id=[int]$fastProcs[0].Id; Created=$null; Kind='Managed'; Path=$Settings.tunnel_client; CommandLine='--config'})
        }
    }
    $script:cachedTunnelPidSig = $pidSig
    $script:cachedTunnelProcList = @($result)
    return $script:cachedTunnelProcList
}

function Get-EffectiveTunnelEndpoint {
    param($Settings, [string]$CoreEndpoint)
    $useShield = ($Settings.PSObject.Properties.Name -contains 'readonly_shield') -and [bool]$Settings.readonly_shield
    $shieldPort = if (($Settings.PSObject.Properties.Name -contains 'shield_port') -and [int]$Settings.shield_port -gt 0) { [int]$Settings.shield_port } else { 8766 }
    if ($useShield) { return "http://127.0.0.1:$shieldPort/mcp" }
    return $CoreEndpoint
}

function Get-RelatedShieldProcesses {
    param($Context)
    if ($Context.Isolated) { return @() }
    $scriptPattern = [regex]::Escape($Context.ShieldScriptPath)
    $tagPattern = '--profile-tag\s+(?:"' + [regex]::Escape($Context.ProfilePath) + '"|' + [regex]::Escape($Context.ProfilePath) + ')(?:\s|$)'
    $result = foreach ($proc in @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue)) {
        if (-not $proc.CommandLine) { continue }
        if ($proc.CommandLine -match $scriptPattern -and $proc.CommandLine -match $tagPattern) {
            [pscustomobject]@{Id=[int]$proc.ProcessId; Created=$proc.CreationDate; Path=$proc.ExecutablePath; CommandLine=$proc.CommandLine}
        }
    }
    return @($result)
}

function Stop-ReadOnlyShield {
    param($Context)
    $count = 0
    foreach ($proc in @(Get-RelatedShieldProcesses $Context)) {
        $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction SilentlyContinue
        if ($current -and $current.CreationDate -eq $proc.Created -and $current.CommandLine -eq $proc.CommandLine) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue; $count++
        }
    }
    return $count
}

function Start-InteractiveHiddenCmd {
    param(
        [string]$CommandLine,
        [string]$WorkingDirectory,
        $EnvironmentOverrides = $null
    )
    $cmdArgs = if ($CommandLine -match '^cmd(?:\.exe)?\s+(.*)$') { $matches[1] } else { "/d /s /c `"$CommandLine`"" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = $cmdArgs
    if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory)) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.UseShellExecute = $false
    if ($EnvironmentOverrides) {
        foreach ($k in $EnvironmentOverrides.Keys) {
            $psi.EnvironmentVariables[[string]$k] = [string]$EnvironmentOverrides[$k]
        }
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc) {
        return [pscustomobject]@{ ReturnValue = 1; ProcessId = 0 }
    }
    return [pscustomobject]@{ ReturnValue = 0; ProcessId = [int]$proc.Id }
}

function Start-ReadOnlyShield {
    param($Context, $Settings, [string]$CoreEndpoint)
    if ($Context.Isolated) { throw '隔离检查禁止启动真实桥接内核。' }
    Stop-ReadOnlyShield $Context | Out-Null
    $shieldPort = if (($Settings.PSObject.Properties.Name -contains 'shield_port') -and [int]$Settings.shield_port -gt 0) { [int]$Settings.shield_port } else { 8766 }
    if (Get-NetTCPConnection -State Listen -LocalPort $shieldPort -ErrorAction SilentlyContinue) {
        throw "本地桥接内核端口 $shieldPort 已被其他程序占用，请检查或关闭冲突进程。"
    }
    $customPy = if ($Settings -and $Settings.PSObject.Properties['python_path'] -and $Settings.python_path -and (Test-Path -LiteralPath ([string]$Settings.python_path))) { [string]$Settings.python_path } else { '' }
    $pythonCmd = Get-Command python.exe -ErrorAction SilentlyContinue
    $pythonExe = if ($customPy) { $customPy } elseif ($pythonCmd) { $pythonCmd.Source } else {
        $stdPy = Get-ChildItem -Path "$env:LOCALAPPDATA\Programs\Python\Python*\python.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($stdPy) { $stdPy.FullName } else { throw '找不到 Python 运行环境，无法启动本地桥接内核。' }
    }
    $logs = Join-Path $Context.DataRoot 'logs'
    [IO.Directory]::CreateDirectory($logs) | Out-Null
    $out = Join-Path $logs 'shield.out.log'; $err = Join-Path $logs 'shield.err.log'
    $command = 'cmd.exe /d /s /c ""' + $pythonExe + '" "' + $Context.ShieldScriptPath + '" --listen-port ' + $shieldPort + ' --upstream-url "' + $CoreEndpoint + '" --profile-tag "' + $Context.ProfilePath + '" 1>"' + $out + '" 2>"' + $err + '""'
    $result = Start-InteractiveHiddenCmd -CommandLine $command -WorkingDirectory (Split-Path $Context.ShieldScriptPath -Parent)
    if ($result.ReturnValue -ne 0) { throw '无法启动本地桥接内核进程。' }
    $shieldHealthUrl = "http://127.0.0.1:$shieldPort/shieldz"
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Milliseconds 150
        $probe = Invoke-ConnectionProbe $shieldHealthUrl
        if ($probe.Status -eq 200 -and $probe.Body -match '"ok"\s*:\s*true') { return "http://127.0.0.1:$shieldPort/mcp" }
    }
    Stop-ReadOnlyShield $Context | Out-Null
    throw '本地桥接内核启动超时，请查看配置与诊断文件夹中的 shield.err.log。'
}

function Get-ConnectionSignature {
    param($Settings, [string]$Endpoint)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Settings | ConvertTo-Json -Compress) + $Endpoint))) }
    finally { $sha.Dispose() }
}

function ConvertTo-YamlQuoted { param([string]$Text); return ($Text | ConvertTo-Json -Compress) }

function New-TunnelProfileText {
    param($Settings, [string]$Endpoint)
    $base = ConvertTo-YamlQuoted $Settings.api_base_url
    $id = ConvertTo-YamlQuoted $Settings.tunnel_id
    $target = ConvertTo-YamlQuoted $Endpoint
    return @"
config_version: 1
control_plane:
  base_url: $base
  tunnel_id: $id
  api_key: "env:CONTROL_PLANE_API_KEY"
health:
  listen_addr: "127.0.0.1:$($Settings.health_port)"
admin_ui:
  open_browser: false
log:
  level: info
  format: json
mcp:
  server_urls:
    - channel: main
      url: $target
"@
}

function Start-OfficialCoreIfNeeded {
    param($Context, $Settings = $null)
    if ($null -eq $Settings -and $null -ne $Context -and $Context.PSObject.Properties['runtime_root']) {
        $Settings = $Context
        $Context = New-ConnectionContext
    }
    if ($Context.Isolated) { return $false }
    if (-not $Settings) { $Settings = Read-ConnectionSettings $Context }
    $coreEndpoint = try { Get-OfficialCoreEndpoint $Settings } catch { '' }
    if (-not $coreEndpoint) { return $false }
    $healthUrl = ($coreEndpoint -replace '/mcp$', '/healthz')
    $health = Invoke-ConnectionProbe $healthUrl
    if ($health.Status -eq 200 -and $health.Body -match '"ok"\s*:\s*true') {
        [void](Repair-RelayProcessPriority $Context $Settings)
        return $true
    }
    $standaloneCore = ''
    foreach ($cand in @(
        $(if ($Settings.runtime_root) { Join-Path $Settings.runtime_root 'bin\relaystudio-core.exe' } else { '' }),
        $(if ($Context.ReleaseRoot) { Join-Path $Context.ReleaseRoot 'bin\relaystudio-core.exe' } else { '' }),
        $(if ($PSScriptRoot) { Join-Path $PSScriptRoot 'bin\relaystudio-core.exe' } else { '' })
    )) {
        if ($cand -and (Test-Path -LiteralPath $cand)) { $standaloneCore = $cand; break }
    }
    if ($standaloneCore) {
        try {
            $rootDir = Split-Path (Split-Path $standaloneCore -Parent) -Parent
            $engineHome = Join-Path $rootDir 'engine-data'
            $wsDir = Join-Path $rootDir 'workspace'
            $logsDir = Join-Path $Context.DataRoot 'logs'
            [IO.Directory]::CreateDirectory($engineHome) | Out-Null
            [IO.Directory]::CreateDirectory($wsDir) | Out-Null
            [IO.Directory]::CreateDirectory($logsDir) | Out-Null
            $port = if ($Settings.PSObject.Properties['core_port'] -and [int]$Settings.core_port -gt 0) { [int]$Settings.core_port } else { 8765 }
            $acpDef = if ($Settings.PSObject.Properties['acp_default_profile'] -and $Settings.acp_default_profile) { [string]$Settings.acp_default_profile } else { 'codex' }
            $acpLim = if ($Settings.PSObject.Properties['acp_max_concurrent_prompts'] -and $null -ne $Settings.acp_max_concurrent_prompts -and [int]$Settings.acp_max_concurrent_prompts -ge 0) { [int]$Settings.acp_max_concurrent_prompts } else { 4 }
            $skillsDir = Join-Path $engineHome 'skills'
            if ($Settings.PSObject.Properties['skills_junction_target'] -and $Settings.skills_junction_target) {
                $junctionTarget = [string]$Settings.skills_junction_target
                if ((Test-Path -LiteralPath $junctionTarget) -and -not (Test-Path -LiteralPath $skillsDir)) {
                    try { New-Item -ItemType Junction -Path $skillsDir -Target $junctionTarget -ErrorAction SilentlyContinue | Out-Null } catch {}
                }
            } else {
                $builtinSkillsDir = Join-Path $rootDir 'builtin-skills\skills'
                if ((Test-Path -LiteralPath $builtinSkillsDir) -and (-not (Test-Path -LiteralPath $skillsDir) -or @(Get-ChildItem -LiteralPath $skillsDir -Directory -ErrorAction SilentlyContinue).Count -eq 0)) {
                    [IO.Directory]::CreateDirectory($skillsDir) | Out-Null
                    Copy-Item -Path (Join-Path $builtinSkillsDir '*') -Destination $skillsDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            $agentsMdPath = Join-Path $engineHome 'AGENTS.md'
            if ($Settings.PSObject.Properties['agents_md_target'] -and $Settings.agents_md_target) {
                $agentsTarget = [string]$Settings.agents_md_target
                if ((Test-Path -LiteralPath $agentsTarget) -and -not (Test-Path -LiteralPath $agentsMdPath)) {
                    try {
                        New-Item -ItemType HardLink -Path $agentsMdPath -Target $agentsTarget -ErrorAction Stop | Out-Null
                    } catch {
                        try { Copy-Item -LiteralPath $agentsTarget -Destination $agentsMdPath -Force -ErrorAction SilentlyContinue } catch {}
                    }
                }
            } else {
                $builtinAgentsMd = Join-Path $rootDir 'builtin-skills\AGENTS.md'
                if ((Test-Path -LiteralPath $builtinAgentsMd) -and -not (Test-Path -LiteralPath $agentsMdPath)) {
                    try { Copy-Item -LiteralPath $builtinAgentsMd -Destination $agentsMdPath -Force -ErrorAction SilentlyContinue } catch {}
                }
            }
            $browserEn = if ($Settings.PSObject.Properties['browser_enabled']) { [bool]$Settings.browser_enabled } else { $true }
            $detectedAgents = @(Get-DetectedCliAgents -ForceRescan -Settings $Settings -Context $Context)
            $acpList = @(foreach ($ag in $detectedAgents) {
                $rawKind = ([string]$ag.kind).Trim().ToLowerInvariant()
                $safeKind = if ($rawKind -in @('codex', 'claude')) { $rawKind } else { 'custom' }
                @{
                    id = [string]$ag.id
                    display_name = [string]$ag.display_name
                    kind = $safeKind
                    command = [string]$ag.command
                    args = @($ag.args)
                    enabled = $true
                }
            })
            $acpProfilesJson = if ($acpList.Count -gt 0) { ConvertTo-Json -InputObject @($acpList) -Depth 4 -Compress } else { '[]' }
            if ($acpList.Count -eq 1 -and -not $acpProfilesJson.StartsWith('[')) {
                $acpProfilesJson = '[' + $acpProfilesJson + ']'
            }
            $environment = [Environment]::GetEnvironmentVariables()
            $environment['GODEBUG'] = 'winsymlink=0'
            $environment['RELAYCORE_HOME'] = $engineHome
            $environment['RELAYCORE_DEFAULT_DIR'] = $wsDir
            $environment['RELAYCORE_PORT'] = "$port"
            $environment['RELAYCORE_MCP_APPS_MODE'] = 'off'
            $environment['RELAYCORE_BROWSER_ENABLED'] = $(if ($browserEn) { 'true' } else { 'false' })
            $environment['RELAYCORE_BROWSER_REUSE_EXISTING_CDP'] = 'true'
            $environment['RELAYCORE_ACP_ENABLED'] = $(if ($acpLim -gt 0) { 'true' } else { 'false' })
            $environment['RELAYCORE_ACP_DEFAULT_PROFILE'] = $acpDef
            $environment['RELAYCORE_ACP_MAX_CONCURRENT_PROMPTS'] = "$(if ($acpLim -gt 0) { $acpLim } else { 1 })"
            $environment['RELAYCORE_ACP_PROFILES_JSON'] = $acpProfilesJson
            $list = @($environment.Keys | ForEach-Object { "$_=$($environment[$_])" })
            $outLog = Join-Path $logsDir 'core.out.log'
            $errLog = Join-Path $logsDir 'core.err.log'
            $cmdLine = 'cmd.exe /d /s /c ""' + $standaloneCore + '" -host 127.0.0.1 -port ' + $port + ' -mcp-apps-mode off 1>>"' + $outLog + '" 2>>"' + $errLog + '""'
            [void](Start-InteractiveHiddenCmd -CommandLine $cmdLine -WorkingDirectory $rootDir -EnvironmentOverrides $environment)
        } catch {}
    }
    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Milliseconds 200
        $probe = Invoke-ConnectionProbe $healthUrl
        if ($probe.Status -eq 200 -and $probe.Body -match '"ok"\s*:\s*true') {
            [void](Repair-RelayProcessPriority $Context $Settings)
            return $true
        }
    }
    return $false
}

function Start-LocalCoreIfNeeded {
    param($Context, $Settings)
    return (Start-OfficialCoreIfNeeded $Context $Settings)
}

$script:InfraProbeCache = @{}
$script:StudioHubSnapshotCache = @{}
$script:WorkspaceCommitsCache = @{}

function Reset-ConnectionInfraCache {
    $script:InfraProbeCache = @{}
    $script:StudioHubSnapshotCache = @{}
}

function Restart-LocalCoreEngine {
    param($Context, $Settings = $null)
    Reset-ConnectionInfraCache
    if (-not $Settings) { $Settings = Read-ConnectionSettings $Context }
    $endpoint = try { Get-OfficialCoreEndpoint $Settings } catch { 'http://127.0.0.1:8765/mcp' }
    if ($Context.Isolated) {
        return [pscustomobject]@{ Restarted = $false; Isolated = $true; Endpoint = $endpoint }
    }
    Get-Process -Name 'relaystudio-core' -ErrorAction SilentlyContinue | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    Start-Sleep -Milliseconds 250
    $ok = Start-OfficialCoreIfNeeded $Context $Settings
    Reset-ConnectionInfraCache
    return [pscustomobject]@{ Restarted = [bool]$ok; Isolated = $false; Endpoint = $endpoint }
}

function Start-ConnectionTunnel {
    param($Context, $Settings)
    if ($Context.Isolated) { throw '隔离检查禁止启动真实连接。' }
    $Settings = Read-ConnectionSettings $Context
    $coreEndpoint = Get-OfficialCoreEndpoint $Settings
    $tunnelEndpoint = Get-EffectiveTunnelEndpoint $Settings $coreEndpoint
    $health = Invoke-ConnectionProbe ($coreEndpoint -replace '/mcp$', '/healthz')
    if ($health.Status -ne 200 -or $health.Body -notmatch '"ok"\s*:\s*true') {
        [void](Start-OfficialCoreIfNeeded $Context $Settings)
        $health = Invoke-ConnectionProbe ($coreEndpoint -replace '/mcp$', '/healthz')
    }
    if ($health.Status -ne 200 -or $health.Body -notmatch '"ok"\s*:\s*true') { throw '本地 RelayStudio 内核尚未准备好。请点击配置面板中的“重启内核”，再重新连接。' }
    $related = @(Get-RelatedTunnelProcesses $Context $Settings)
    if (@($related | Where-Object Kind -eq 'Legacy').Count) { throw '旧脚本的隧道仍在运行，目标是 8787。请先点击“断开”，再连接到本地内核。' }
    if ($related.Count) {
        if (Test-Path -LiteralPath $Context.StatePath) {
            $state = [IO.File]::ReadAllText($Context.StatePath) | ConvertFrom-Json
            if ($state.signature -eq (Get-ConnectionSignature $Settings $tunnelEndpoint)) { return '已有连接正在运行，没有重新启动。' }
        }
        throw '连接配置已改变。请先断开，再按新配置连接。'
    }
    if (-not (Test-Path -LiteralPath $Settings.tunnel_client)) { throw '找不到 OpenAI 连接程序。请检查高级设置中的程序位置。' }
    if (Get-NetTCPConnection -State Listen -LocalPort $Settings.health_port -ErrorAction SilentlyContinue) { throw "状态端口 $($Settings.health_port) 已被其他程序占用，请查看诊断。" }
    $auth = ''
    if (Test-Path -LiteralPath $Context.TokenPath) { $auth = 'Bearer ' + (Read-ConnectionSecret $Context.TokenPath) }
    $mcp = Invoke-ConnectionProbe $coreEndpoint $auth -HeadersOnly
    if ($mcp.Status -eq 401 -or $mcp.Status -eq 403) { throw '本地内核需要有效的访问令牌。请在“高级设置 → RelayStudio 访问令牌”中检查或清空，保存后再连接。' }
    $key = if (Test-Path -LiteralPath $Context.KeyPath) { Read-ConnectionSecret $Context.KeyPath }
        else { throw '尚未保存 OpenAI API Key。' }
    if ($Settings.readonly_shield) {
        $tunnelEndpoint = Start-ReadOnlyShield $Context $Settings $coreEndpoint
    } else {
        Stop-ReadOnlyShield $Context | Out-Null
    }
    $logs = Join-Path $Context.DataRoot 'logs'
    [IO.Directory]::CreateDirectory($logs) | Out-Null
    Write-AtomicConnectionText $Context.ProfilePath (New-TunnelProfileText $Settings $tunnelEndpoint)
    $out = Join-Path $logs 'tunnel.out.log'; $err = Join-Path $logs 'tunnel.err.log'
    foreach ($path in @($Settings.tunnel_client, $Context.ProfilePath, $out, $err)) {
        if ($path -match '["%\r\n]') { throw '程序或配置路径包含不支持的字符。请选择不含双引号或百分号的路径。' }
    }
    $args = 'run --config "' + $Context.ProfilePath + '"'
    if ($auth) { $args += ' --mcp.extra-headers "Authorization: env:RELAY_AUTHORIZATION" --mcp.discovery-extra-headers "Authorization: env:RELAY_AUTHORIZATION"' }
    $command = 'cmd.exe /d /s /c ""' + $Settings.tunnel_client + '" ' + $args + ' 1>>"' + $out + '" 2>>"' + $err + '""'
    try {
        $environment = [Environment]::GetEnvironmentVariables()
        $environment['CONTROL_PLANE_API_KEY'] = $key
        $environment['CONTROL_PLANE_TUNNEL_ID'] = $Settings.tunnel_id
        if ($auth) { $environment['RELAY_AUTHORIZATION'] = $auth }
        $list = @($environment.Keys | ForEach-Object { "$_=$($environment[$_])" })
        $result = Start-InteractiveHiddenCmd -CommandLine $command -WorkingDirectory (Split-Path $Settings.tunnel_client -Parent) -EnvironmentOverrides $environment
        if ($result.ReturnValue -ne 0) { throw '无法启动连接程序，请检查 Windows 的进程启动权限。' }
        Write-AtomicConnectionText $Context.StatePath ([pscustomobject]@{signature=(Get-ConnectionSignature $Settings $tunnelEndpoint); endpoint=$tunnelEndpoint; core_endpoint=$coreEndpoint; readonly_shield=[bool]$Settings.readonly_shield; client_path=$Settings.tunnel_client; wrapper_pid=$result.ProcessId; started_at=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json)
    } finally { $key=$null; $auth=$null; $environment=$null; $list=$null; $startup=$null }
    Reset-ConnectionInfraCache
    return '连接程序已启动，正在检查隧道就绪状态。'
}

function Stop-ConnectionTunnel {
    param($Context, $Settings)
    $count = 0
    foreach ($proc in @(Get-RelatedTunnelProcesses $Context $Settings)) {
        $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction SilentlyContinue
        if ($current -and $current.CreationDate -eq $proc.Created -and $current.ExecutablePath -eq $proc.Path -and $current.CommandLine -eq $proc.CommandLine) {
            Stop-Process -Id $proc.Id -ErrorAction Stop; $count++
        }
    }
    Stop-ReadOnlyShield $Context | Out-Null
    Reset-ConnectionInfraCache
    return "已断开 $count 个对应的隧道连接。RelayStudio 本地内核保持运行。"
}

function Format-MaskedApiKey {
    param([string]$ApiKey)
    if (-not $ApiKey) { return '尚未保存密钥' }
    $clean = $ApiKey.Trim()
    if ($clean.Length -le 16) {
        return ($clean.Substring(0, [Math]::Min(4, $clean.Length)) + '••••••••••••')
    }
    return ($clean.Substring(0, 12) + '••••••••••••••••••••••••••••••••' + $clean.Substring($clean.Length - 4))
}

function Get-SavedOpenAIKeyPlaintext {
    param($Context)
    try {
        if (Test-Path -LiteralPath $Context.KeyPath) { return (Read-ConnectionSecret $Context.KeyPath) }
    } catch { }
    return ''
}

function Get-ConnectionProfiles {
    param($Context, $Settings = $null)
    if (-not $Settings) { $Settings = Read-ConnectionSettings $Context }
    $storePath = if ($Context.PSObject.Properties.Name -contains 'ProfilesStorePath' -and $Context.ProfilesStorePath) {
        $Context.ProfilesStorePath
    } else {
        Join-Path $Context.DataRoot 'credential-profiles.json'
    }
    $activeId = 'prof_primary'
    $rawItems = @()
    $hasExplicitProfilesStore = $false
    if (Test-Path -LiteralPath $storePath) {
        try {
            $storeObj = [IO.File]::ReadAllText($storePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($null -ne $storeObj -and ($storeObj.PSObject.Properties.Name -contains 'profiles')) {
                $hasExplicitProfilesStore = $true
            }
            if ($storeObj.PSObject.Properties.Name -contains 'active_profile_id') {
                $activeId = [string]$storeObj.active_profile_id
            }
            if ($storeObj.PSObject.Properties.Name -contains 'profiles' -and $storeObj.profiles) {
                $rawItems = @($storeObj.profiles)
            }
        } catch { $rawItems = @() }
    }

    if ($rawItems.Count -eq 0 -and -not $hasExplicitProfilesStore) {
        $currentKey = Get-SavedOpenAIKeyPlaintext $Context
        $primKeyFile = 'openai-key-prof_primary.dpapi'
        $primKeyPath = Join-Path $Context.DataRoot $primKeyFile
        if ($currentKey -and -not (Test-Path -LiteralPath $primKeyPath)) {
            try { Write-AtomicConnectionText $primKeyPath (Protect-ConnectionSecret $currentKey) } catch { }
        }
        $rawItems = @(
            [pscustomobject]@{
                id = 'prof_primary'
                name = '主工作台隧道'
                tunnel_id = [string]$Settings.tunnel_id
                api_base_url = [string]$Settings.api_base_url
                key_file = $primKeyFile
            }
        )
    }

    $profiles = @(foreach ($item in $rawItems) {
        $pidStr = [string]$item.id
        $keyFile = if ($item.PSObject.Properties.Name -contains 'key_file' -and $item.key_file) { [string]$item.key_file } else { "openai-key-$pidStr.dpapi" }
        $keyFullPath = Join-Path $Context.DataRoot $keyFile
        $plain = ''
        if (Test-Path -LiteralPath $keyFullPath) {
            try { $plain = Read-ConnectionSecret $keyFullPath } catch { $plain = '' }
        } elseif ($pidStr -eq $activeId) {
            $plain = Get-SavedOpenAIKeyPlaintext $Context
        }
        $tunId = if ($item.PSObject.Properties.Name -contains 'tunnel_id' -and $item.tunnel_id) { [string]$item.tunnel_id } elseif ($pidStr -eq $activeId) { [string]$Settings.tunnel_id } else { '' }
        $baseUrl = if ($item.PSObject.Properties.Name -contains 'api_base_url' -and $item.api_base_url) { [string]$item.api_base_url } else { [string]$Settings.api_base_url }
        # Skip legacy empty 'Business 席位号' placeholder if unconfigured
        if ($pidStr -eq 'prof_business' -and [string]$item.name -eq 'Business 席位号' -and (-not $tunId) -and (-not $plain) -and ($pidStr -ne $activeId)) {
            continue
        }
        $displayName = if ([string]$item.name -eq '个人主力号') { '主工作台隧道' } else { [string]$item.name }
        [pscustomobject]@{
            Id = $pidStr
            Name = $displayName
            TunnelId = $tunId
            ApiBaseUrl = $baseUrl
            KeyFile = $keyFile
            HasKey = [bool]($plain.Length -gt 0)
            PlainKey = $plain
            MaskedKey = (Format-MaskedApiKey $plain)
            IsActive = ($pidStr -eq $activeId)
        }
    })
    return [pscustomobject]@{
        ActiveProfileId = $activeId
        Profiles = $profiles
    }
}

function Save-ConnectionProfile {
    param(
        $Context,
        $Settings = $null,
        [string]$ProfileId = '',
        [string]$Name = '',
        [string]$TunnelId = '',
        [string]$ApiKey = '',
        [switch]$SetActive
    )
    if (-not $Settings) { $Settings = Read-ConnectionSettings $Context }
    if (-not $ProfileId -or $ProfileId -eq 'new') {
        $ProfileId = 'prof_' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
    $state = Get-ConnectionProfiles $Context $Settings
    $cleanTun = if ($TunnelId.Trim()) { ConvertTo-TunnelId $TunnelId } else { '' }
    $cleanKey = $ApiKey.Trim()
    if ($cleanKey -and ($cleanKey -match '^[a-z]+://' -or $cleanKey -match '\s' -or $cleanKey.Length -lt 12)) {
        throw 'API Key 栏请粘贴密钥本身，不是网页链接；密钥中不能有空格或换行。'
    }
    $storePath = if ($Context.PSObject.Properties.Name -contains 'ProfilesStorePath' -and $Context.ProfilesStorePath) {
        $Context.ProfilesStorePath
    } else {
        Join-Path $Context.DataRoot 'credential-profiles.json'
    }
    $activeId = if ($SetActive) { $ProfileId } else { $state.ActiveProfileId }
    $updatedList = New-Object 'System.Collections.Generic.List[object]'
    $found = $false
    foreach ($p in $state.Profiles) {
        if ($p.Id -eq $ProfileId) {
            $found = $true
            $newName = if ($Name.Trim()) { $Name.Trim() } else { $p.Name }
            $newTun = if ($cleanTun) { $cleanTun } else { $p.TunnelId }
            $keyFile = $p.KeyFile
            if ($cleanKey) {
                Write-AtomicConnectionText (Join-Path $Context.DataRoot $keyFile) (Protect-ConnectionSecret $cleanKey)
            }
            $updatedList.Add([pscustomobject]@{
                id = $p.Id
                name = $newName
                tunnel_id = $newTun
                api_base_url = $p.ApiBaseUrl
                key_file = $keyFile
            })
        } else {
            $updatedList.Add([pscustomobject]@{
                id = $p.Id
                name = $p.Name
                tunnel_id = $p.TunnelId
                api_base_url = $p.ApiBaseUrl
                key_file = $p.KeyFile
            })
        }
    }
    if (-not $found) {
        $keyFile = "openai-key-$ProfileId.dpapi"
        if ($cleanKey) {
            Write-AtomicConnectionText (Join-Path $Context.DataRoot $keyFile) (Protect-ConnectionSecret $cleanKey)
        }
        $idxNum = $updatedList.Count + 1
        $updatedList.Add([pscustomobject]@{
            id = $ProfileId
            name = $(if ($Name.Trim()) { $Name.Trim() } else { "自定义隧道配置 #$idxNum" })
            tunnel_id = $cleanTun
            api_base_url = $Settings.api_base_url
            key_file = $keyFile
        })
    }
    $storePayload = [pscustomobject]@{
        schema_version = 1
        active_profile_id = $activeId
        profiles = $updatedList.ToArray()
    } | ConvertTo-Json -Depth 5
    Write-AtomicConnectionText $storePath $storePayload

    if ($activeId -eq $ProfileId -and $cleanTun) {
        $Settings.tunnel_id = $cleanTun
        $effectiveKey = $cleanKey
        if (-not $effectiveKey) {
            $keyFilePath = Join-Path $Context.DataRoot "openai-key-$ProfileId.dpapi"
            if (Test-Path -LiteralPath $keyFilePath) { $effectiveKey = Read-ConnectionSecret $keyFilePath }
        }
        Save-ConnectionSettings -Context $Context -Settings $Settings -ApiKey $effectiveKey
    }
    $retState = Get-ConnectionProfiles $Context (Read-ConnectionSettings $Context)
    $retState | Add-Member -NotePropertyName 'LastSavedProfileId' -NotePropertyValue $ProfileId -Force
    return $retState
}

function Remove-ConnectionProfile {
    param($Context, $Settings = $null, [string]$ProfileId)
    if (-not $Settings) { $Settings = Read-ConnectionSettings $Context }
    $state = Get-ConnectionProfiles $Context $Settings
    $targetProf = $state.Profiles | Where-Object { $_.Id -eq $ProfileId } | Select-Object -First 1
    $remaining = @($state.Profiles | Where-Object { $_.Id -ne $ProfileId })
    if ($remaining.Count -eq @($state.Profiles).Count) {
        throw "找不到要删除的配置 ($ProfileId)。"
    }
    if ($targetProf -and $targetProf.KeyFile) {
        $delKeyPath = Join-Path $Context.DataRoot $targetProf.KeyFile
        if (Test-Path -LiteralPath $delKeyPath) {
            Remove-Item -LiteralPath $delKeyPath -Force -ErrorAction SilentlyContinue
        }
    }
    $newActiveId = $state.ActiveProfileId
    if ($remaining.Count -eq 0) {
        $newActiveId = ''
    } elseif ($newActiveId -eq $ProfileId) {
        $newActiveId = $remaining[0].Id
    }
    $storePath = if ($Context.PSObject.Properties.Name -contains 'ProfilesStorePath' -and $Context.ProfilesStorePath) {
        $Context.ProfilesStorePath
    } else {
        Join-Path $Context.DataRoot 'credential-profiles.json'
    }
    $rawProfiles = @(foreach ($p in $remaining) {
        [pscustomobject]@{
            id = $p.Id
            name = $p.Name
            tunnel_id = $p.TunnelId
            api_base_url = $p.ApiBaseUrl
            key_file = $p.KeyFile
        }
    })
    $storePayload = [pscustomobject]@{
        schema_version = 1
        active_profile_id = $newActiveId
        profiles = $rawProfiles
    } | ConvertTo-Json -Depth 5
    Write-AtomicConnectionText $storePath $storePayload
    return (Get-ConnectionProfiles $Context $Settings)
}

function Select-ConnectionProfile {
    param($Context, $Settings = $null, [string]$ProfileId, [switch]$AutoReconnect)
    if (-not $Settings) { $Settings = Read-ConnectionSettings $Context }
    $state = Get-ConnectionProfiles $Context $Settings
    $target = $state.Profiles | Where-Object { $_.Id -eq $ProfileId } | Select-Object -First 1
    if (-not $target) { throw "找不到指定的连接配置 ($ProfileId)。" }
    if (-not $target.TunnelId -or -not $target.HasKey) {
        throw "配置「$($target.Name)」尚未填写隧道编号或 API Key，请先点击修改并粘贴凭据。"
    }
    $storePath = if ($Context.PSObject.Properties.Name -contains 'ProfilesStorePath' -and $Context.ProfilesStorePath) {
        $Context.ProfilesStorePath
    } else {
        Join-Path $Context.DataRoot 'credential-profiles.json'
    }
    $rawProfiles = @(foreach ($p in $state.Profiles) {
        [pscustomobject]@{
            id = $p.Id
            name = $p.Name
            tunnel_id = $p.TunnelId
            api_base_url = $p.ApiBaseUrl
            key_file = $p.KeyFile
        }
    })
    $storePayload = [pscustomobject]@{
        schema_version = 1
        active_profile_id = $ProfileId
        profiles = $rawProfiles
    } | ConvertTo-Json -Depth 5
    Write-AtomicConnectionText $storePath $storePayload

    $Settings.tunnel_id = $target.TunnelId
    Save-ConnectionSettings -Context $Context -Settings $Settings -ApiKey $target.PlainKey
    $newSettings = Read-ConnectionSettings $Context
    Reset-ConnectionInfraCache
    $reconnectMsg = "已切换至「$($target.Name)」配置。"
    if ($AutoReconnect -and -not $Context.Isolated) {
        Stop-ConnectionTunnel $Context $newSettings | Out-Null
        $startMsg = Start-ConnectionTunnel $Context $newSettings
        $reconnectMsg = "已自动切换至「$($target.Name)」并重新建立隧道连接（$startMsg）"
    }
    return [pscustomobject]@{
        ActiveProfile = $target
        Settings = $newSettings
        Message = $reconnectMsg
    }
}

function Invoke-StudioHubSnapshot {
    param($Context, [string]$SinceRev = '')
    if (-not $Context) { return $null }
    $baseUri = if ($Context.PSObject.Properties['HubUrl'] -and $Context.HubUrl) {
        ([string]$Context.HubUrl).TrimEnd('/')
    } elseif ($Context.Isolated -or ([string]$Context.DataRoot -match 'connection-test-')) {
        ''
    } else {
        'http://127.0.0.1:8766'
    }
    if (-not $baseUri) { return $null }
    if (-not (Test-LocalUrlPortOpen $baseUri)) { return $null }
    $snapUri = if ($SinceRev) {
        "$baseUri/studio/snapshot?since_sig=$([Uri]::EscapeDataString($SinceRev))"
    } else {
        "$baseUri/studio/snapshot"
    }
    try {
        $resp = Invoke-RestMethod -Uri $snapUri -Method Get -TimeoutSec 2 -ErrorAction Stop
        if ($resp -and $resp.ok) { return $resp }
    } catch { }
    return $null
}

function Invoke-StudioHubQueueDigest {
    param($Context, [string]$SinceRev = '')
    if (-not $Context) { return $null }
    $baseUri = if ($Context.PSObject.Properties['HubUrl'] -and $Context.HubUrl) {
        ([string]$Context.HubUrl).TrimEnd('/')
    } elseif ($Context.Isolated -or ([string]$Context.DataRoot -match 'connection-test-')) {
        ''
    } else {
        'http://127.0.0.1:8766'
    }
    if (-not $baseUri) { return $null }
    if (-not (Test-LocalUrlPortOpen $baseUri)) { return $null }
    $digestUri = if ($SinceRev) {
        "$baseUri/studio/queue-digest?since_rev=$([Uri]::EscapeDataString($SinceRev))"
    } else {
        "$baseUri/studio/queue-digest"
    }
    try {
        $resp = Invoke-RestMethod -Uri $digestUri -Method Get -TimeoutSec 1 -ErrorAction Stop
        if ($resp -and $resp.ok) { return $resp }
    } catch { }
    return $null
}

function Invoke-StudioHubAction {
    param($Context, [hashtable]$Payload)
    if (-not $Context) { return $null }
    $baseUri = if ($Context.PSObject.Properties['HubUrl'] -and $Context.HubUrl) {
        ([string]$Context.HubUrl).TrimEnd('/')
    } elseif ($Context.Isolated -or ([string]$Context.DataRoot -match 'connection-test-')) {
        ''
    } else {
        'http://127.0.0.1:8766'
    }
    if (-not $baseUri) { return $null }
    if (-not (Test-LocalUrlPortOpen $baseUri)) { return $null }
    try {
        $json = $Payload | ConvertTo-Json -Depth 6 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $resp = Invoke-RestMethod -Uri "$baseUri/studio/action" -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 3 -ErrorAction Stop
        if ($resp -and $resp.ok) { return $resp }
    } catch { }
    return $null
}

function Get-TaskRegistryPath {
    param($Context)
    if ($Context -and $Context.PSObject.Properties['TaskRegistryPath'] -and $Context.TaskRegistryPath) {
        return [string]$Context.TaskRegistryPath
    }
    return (Join-Path $Context.DataRoot 'task-registry.json')
}

function Get-LocalTaskRegistry {
    param($Context)
    $path = Get-TaskRegistryPath $Context
    if ($path -and (Test-Path -LiteralPath $path)) {
        try {
            $obj = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($obj -and $obj.PSObject.Properties['tasks'] -and $obj.tasks) {
                return $obj
            }
        } catch { }
    }
    return [pscustomobject]@{
        schema_version = 1
        tasks = [pscustomobject]@{}
    }
}

function Save-LocalTaskRegistry {
    param($Context, $Registry)
    $path = Get-TaskRegistryPath $Context
    if (-not $path) { return }
    $json = $Registry | ConvertTo-Json -Depth 10
    Write-AtomicConnectionText $path $json
}

function Add-LocalRetireAction {
    param(
        $Context,
        [string]$TaskId,
        [string]$ConvUuid,
        [string]$BrowserProfile = '',
        [string]$ProjectPrefix = '',
        [ValidateSet('archive','unarchive','delete')][string]$Operation = 'archive',
        [switch]$StopBeforeAction,
        [switch]$CloseTab
    )
    if (-not $Context -or -not $ConvUuid) { return }
    try {
        $state = Get-WebBridgeState $Context
        $actions = New-Object 'System.Collections.Generic.List[object]'
        $alreadyQueued = $false
        if ($state.PSObject.Properties['retire_actions'] -and $state.retire_actions) {
            foreach ($ra in @($state.retire_actions)) {
                if (-not $ra) { continue }
                $raOp = if ($ra.PSObject.Properties['operation'] -and $ra.operation) { [string]$ra.operation } else { 'archive' }
                if ([string]$ra.conv_uuid -eq $ConvUuid -and [string]$ra.status -eq 'pending' -and $raOp -eq $Operation) {
                    $alreadyQueued = $true
                }
                [void]$actions.Add($ra)
            }
        }
        if (-not $alreadyQueued) {
            [void]$actions.Add([pscustomobject]@{
                id = 'ret_' + ([guid]::NewGuid().ToString('N').Substring(0, 10))
                session_key = $TaskId
                conv_uuid = $ConvUuid
                browser_profile = $BrowserProfile
                project_prefix = $ProjectPrefix
                operation = $Operation
                stop_before_archive = [bool]$StopBeforeAction
                stop_before_action = [bool]$StopBeforeAction
                close_tab = [bool]$CloseTab
                status = 'pending'
                created_at = [DateTimeOffset]::UtcNow.ToString('o')
            })
            if ($actions.Count -gt 50) {
                $actions = New-Object 'System.Collections.Generic.List[object]' (,($actions | Select-Object -Last 50))
            }
            $state | Add-Member -NotePropertyName 'retire_actions' -NotePropertyValue $actions.ToArray() -Force
            Save-WebBridgeState $Context $state
        }
    } catch { }
}

function Get-TaskArchiveOverrides {
    param($Context)
    $result = @{}
    $path = if ($Context.PSObject.Properties.Name -contains 'TaskArchivesPath' -and $Context.TaskArchivesPath) {
        $Context.TaskArchivesPath
    } else {
        Join-Path $Context.DataRoot 'task-archives.json'
    }
    if (Test-Path -LiteralPath $path) {
        try {
            $obj = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($obj -and $obj.PSObject.Properties.Name -contains 'overrides' -and $obj.overrides) {
                foreach ($p in $obj.overrides.PSObject.Properties) {
                    if ($p.Value -and [string]$p.Value -ne 'deleted') { $result[$p.Name] = [string]$p.Value }
                }
            }
        } catch { }
    }
    $reg = Get-LocalTaskRegistry $Context
    if ($reg -and $reg.tasks) {
        foreach ($tp in $reg.tasks.PSObject.Properties) {
            if ($tp.Value -and $tp.Value.PSObject.Properties['lifecycle'] -and $tp.Value.lifecycle) {
                $lc = [string]$tp.Value.lifecycle
                if ($lc -eq 'archived') {
                    $result[$tp.Name] = 'archived'
                } elseif ($lc -in @('active', 'completed') -and (-not $result.ContainsKey($tp.Name))) {
                    $result[$tp.Name] = $lc
                }
            }
        }
    }
    return $result
}

function Get-TaskArchiveTimestamps {
    param($Context)
    $result = @{}
    $path = if ($Context.PSObject.Properties.Name -contains 'TaskArchivesPath' -and $Context.TaskArchivesPath) {
        $Context.TaskArchivesPath
    } else {
        Join-Path $Context.DataRoot 'task-archives.json'
    }
    if (Test-Path -LiteralPath $path) {
        try {
            $obj = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($obj -and $obj.PSObject.Properties.Name -contains 'archived_at' -and $obj.archived_at) {
                foreach ($p in $obj.archived_at.PSObject.Properties) {
                    if ($p.Value) {
                        $dto = ConvertTo-LocalDateTimeOffset $p.Value $null
                        if ($dto) { $result[$p.Name] = $dto }
                    }
                }
            }
        } catch { }
    }
    return $result
}

function Set-TaskArchiveState {
    param($Context, [string]$TaskId, [ValidateSet('archived','active','completed','auto')][string]$State)
    if (-not $TaskId) { return }
    $effState = if ($State -eq 'auto') { 'active' } else { $State }
    $hubResp = Invoke-StudioHubAction -Context $Context -Payload @{ action = 'set_archive_state'; task_id = $TaskId; session_key = $TaskId; state = $effState }
    if ($hubResp -and $hubResp.ok) { return }
    $nowIso = [DateTimeOffset]::UtcNow.ToString('o')
    $path = if ($Context.PSObject.Properties.Name -contains 'TaskArchivesPath' -and $Context.TaskArchivesPath) {
        $Context.TaskArchivesPath
    } else {
        Join-Path $Context.DataRoot 'task-archives.json'
    }
    $overrides = Get-TaskArchiveOverrides $Context
    $archivedAtRaw = @{}
    if (Test-Path -LiteralPath $path) {
        try {
            $obj = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($obj -and $obj.PSObject.Properties.Name -contains 'archived_at' -and $obj.archived_at) {
                foreach ($p in $obj.archived_at.PSObject.Properties) {
                    if ($p.Value) { $archivedAtRaw[$p.Name] = [string]$p.Value }
                }
            }
        } catch { }
    }
    if ($State -eq 'auto') {
        [void]$overrides.Remove($TaskId)
        [void]$archivedAtRaw.Remove($TaskId)
    } else {
        $overrides[$TaskId] = $effState
        if ($effState -eq 'archived') {
            $archivedAtRaw[$TaskId] = $nowIso
        } else {
            [void]$archivedAtRaw.Remove($TaskId)
        }
    }
    $ordered = [ordered]@{}
    foreach ($k in ($overrides.Keys | Sort-Object)) { $ordered[$k] = $overrides[$k] }
    $orderedTs = [ordered]@{}
    foreach ($k in ($archivedAtRaw.Keys | Sort-Object)) { $orderedTs[$k] = $archivedAtRaw[$k] }
    $payload = [pscustomobject]@{
        schema_version = 2
        overrides = [pscustomobject]$ordered
        archived_at = [pscustomobject]$orderedTs
    } | ConvertTo-Json -Depth 4
    Write-AtomicConnectionText $path $payload

    # Sync Ledger 1 (data\task-registry.json) & cloud retire_actions in offline fallback
    $reg = Get-LocalTaskRegistry $Context
    if (-not ($reg.PSObject.Properties['tasks'] -and $reg.tasks)) {
        $reg | Add-Member -NotePropertyName 'tasks' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $entry = if ($reg.tasks.PSObject.Properties[$TaskId]) { $reg.tasks.$TaskId } else { $null }
    if (-not $entry) {
        $entry = [pscustomobject]@{
            task_id = $TaskId
            title = ''
            lifecycle = $effState
            created_at = $nowIso
            updated_at = $nowIso
            completed_at = $null
            archived_at = $null
            archive_reason = $null
            active_binding = $null
            retired_sessions = @()
        }
        $reg.tasks | Add-Member -NotePropertyName $TaskId -NotePropertyValue $entry -Force
    }
    $entry | Add-Member -NotePropertyName 'lifecycle' -NotePropertyValue $effState -Force
    $entry | Add-Member -NotePropertyName 'updated_at' -NotePropertyValue $nowIso -Force
    if ($effState -eq 'archived') {
        $entry | Add-Member -NotePropertyName 'archived_at' -NotePropertyValue $nowIso -Force
        $entry | Add-Member -NotePropertyName 'archive_reason' -NotePropertyValue 'manual' -Force
    } elseif ($effState -eq 'completed') {
        $entry | Add-Member -NotePropertyName 'completed_at' -NotePropertyValue $nowIso -Force
    } else {
        $entry | Add-Member -NotePropertyName 'archived_at' -NotePropertyValue $null -Force
        $entry | Add-Member -NotePropertyName 'archive_reason' -NotePropertyValue $null -Force
    }
    Save-LocalTaskRegistry $Context $reg

    try {
        $wb = Get-WebBridgeState $Context
        $bind = if ($wb.PSObject.Properties['session_bindings'] -and $wb.session_bindings -and $wb.session_bindings.PSObject.Properties[$TaskId]) { $wb.session_bindings.$TaskId } else { $null }
        $primaryUuid = if ($entry.active_binding -and $entry.active_binding.PSObject.Properties['conv_uuid'] -and $entry.active_binding.conv_uuid) {
            [string]$entry.active_binding.conv_uuid
        } elseif ($bind -and $bind.PSObject.Properties['conv_uuid'] -and $bind.conv_uuid) {
            [string]$bind.conv_uuid
        } else { '' }
        $bProf = if ($bind -and $bind.PSObject.Properties['browser_profile'] -and $bind.browser_profile) { [string]$bind.browser_profile } else { '' }
        $pPref = if ($bind -and $bind.PSObject.Properties['project_prefix'] -and $bind.project_prefix) { [string]$bind.project_prefix } else { '' }
        if ($effState -eq 'archived') {
            if ($primaryUuid) {
                Add-LocalRetireAction -Context $Context -TaskId $TaskId -ConvUuid $primaryUuid -BrowserProfile $bProf -ProjectPrefix $pPref -Operation 'archive' -StopBeforeAction -CloseTab
            }
            if ($bind -and $bind.PSObject.Properties['retired_uuids'] -and $bind.retired_uuids) {
                foreach ($ru in @($bind.retired_uuids)) {
                    if ($ru) {
                        Add-LocalRetireAction -Context $Context -TaskId $TaskId -ConvUuid ([string]$ru) -BrowserProfile $bProf -ProjectPrefix $pPref -Operation 'archive' -StopBeforeAction -CloseTab
                    }
                }
            }
        } elseif ($effState -eq 'active' -and $primaryUuid) {
            Add-LocalRetireAction -Context $Context -TaskId $TaskId -ConvUuid $primaryUuid -BrowserProfile $bProf -ProjectPrefix $pPref -Operation 'unarchive'
        }
    } catch { }
}

function Remove-ArchivedTaskSession {
    param($Context, [string]$SessionKey, [switch]$PhysicalPurge, $Settings = $null)
    if (-not $SessionKey) {
        return [pscustomobject]@{ SessionKey = ''; PurgedTaskFile = $false; CleanedState = $false }
    }
    $hubResp = Invoke-StudioHubAction -Context $Context -Payload @{ action = 'delete_session'; session_key = $SessionKey; physical_purge = $true }
    if ($hubResp -and $hubResp.ok) {
        $purged = if ($hubResp.PSObject.Properties['purged_task_file']) {
            [bool]$hubResp.purged_task_file
        } elseif ($hubResp.PSObject.Properties['purged_files']) {
            (@($hubResp.purged_files).Count -gt 0)
        } else { $true }
        return [pscustomobject]@{
            SessionKey = $SessionKey
            PurgedTaskFile = $purged
            CleanedState = $true
        }
    }
    $tasksDir = ''
    if ($Context.PSObject.Properties.Name -contains 'TasksRoot' -and $Context.TasksRoot) {
        $tasksDir = $Context.TasksRoot
    } elseif (-not $Context.Isolated -and $Settings -and ($Settings.PSObject.Properties.Name -contains 'runtime_root') -and $Settings.runtime_root) {
        foreach ($cand in @(
            (Join-Path $Settings.runtime_root 'engine-data\tasks'),
            (Join-Path $Settings.runtime_root 'data\tasks'),
            $(if ($PSScriptRoot) { Join-Path $PSScriptRoot 'engine-data\tasks' } else { '' })
        )) {
            if ($cand -and (Test-Path -LiteralPath $cand)) { $tasksDir = $cand; break }
        }
    } elseif (-not $Context.Isolated -and $PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'engine-data\tasks'))) {
        $tasksDir = Join-Path $PSScriptRoot 'engine-data\tasks'
    }

    $purgedTaskFile = $false
    if ($tasksDir -and (Test-Path -LiteralPath $tasksDir)) {
        $tFile = Join-Path $tasksDir "$SessionKey.json"
        if (Test-Path -LiteralPath $tFile) {
            try {
                Remove-Item -LiteralPath $tFile -Force -ErrorAction Stop
                $purgedTaskFile = $true
            } catch { }
        }
    }

    # Collect bound and retired conv_uuids before removing registry/binding entries so we can enqueue cloud delete
    $uuidsToDelete = New-Object 'System.Collections.Generic.List[object]'
    $reg = Get-LocalTaskRegistry $Context
    if ($reg -and $reg.tasks -and $reg.tasks.PSObject.Properties[$SessionKey]) {
        $tEntry = $reg.tasks.$SessionKey
        if ($tEntry.PSObject.Properties['active_binding'] -and $tEntry.active_binding -and $tEntry.active_binding.PSObject.Properties['conv_uuid'] -and $tEntry.active_binding.conv_uuid) {
            [void]$uuidsToDelete.Add([pscustomobject]@{
                ConvUuid = [string]$tEntry.active_binding.conv_uuid
                BrowserProfile = $(if ($tEntry.active_binding.PSObject.Properties['browser_profile']) { [string]$tEntry.active_binding.browser_profile } else { '' })
                ProjectPrefix = $(if ($tEntry.active_binding.PSObject.Properties['project_prefix']) { [string]$tEntry.active_binding.project_prefix } else { '' })
            })
        }
        if ($tEntry.PSObject.Properties['retired_sessions'] -and $tEntry.retired_sessions) {
            foreach ($rs in @($tEntry.retired_sessions)) {
                if ($rs -and $rs.PSObject.Properties['conv_uuid'] -and $rs.conv_uuid) {
                    [void]$uuidsToDelete.Add([pscustomobject]@{
                        ConvUuid = [string]$rs.conv_uuid
                        BrowserProfile = $(if ($rs.PSObject.Properties['browser_profile']) { [string]$rs.browser_profile } else { '' })
                        ProjectPrefix = $(if ($rs.PSObject.Properties['project_prefix']) { [string]$rs.project_prefix } else { '' })
                    })
                }
            }
        }
        $reg.tasks.PSObject.Properties.Remove($SessionKey)
        Save-LocalTaskRegistry $Context $reg
    }

    $archPath = if ($Context.PSObject.Properties.Name -contains 'TaskArchivesPath' -and $Context.TaskArchivesPath) {
        $Context.TaskArchivesPath
    } else {
        Join-Path $Context.DataRoot 'task-archives.json'
    }
    $overrides = @{}
    $archivedAtRaw = @{}
    if (Test-Path -LiteralPath $archPath) {
        try {
            $obj = [IO.File]::ReadAllText($archPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($obj -and $obj.PSObject.Properties.Name -contains 'overrides' -and $obj.overrides) {
                foreach ($p in $obj.overrides.PSObject.Properties) {
                    if ($p.Value -and [string]$p.Value -ne 'deleted') { $overrides[$p.Name] = [string]$p.Value }
                }
            }
            if ($obj -and $obj.PSObject.Properties.Name -contains 'archived_at' -and $obj.archived_at) {
                foreach ($p in $obj.archived_at.PSObject.Properties) {
                    if ($p.Value) { $archivedAtRaw[$p.Name] = [string]$p.Value }
                }
            }
        } catch { }
    }
    [void]$overrides.Remove($SessionKey)
    [void]$archivedAtRaw.Remove($SessionKey)
    $ordered = [ordered]@{}
    foreach ($k in ($overrides.Keys | Sort-Object)) { $ordered[$k] = $overrides[$k] }
    $orderedTs = [ordered]@{}
    foreach ($k in ($archivedAtRaw.Keys | Sort-Object)) { $orderedTs[$k] = $archivedAtRaw[$k] }
    Write-AtomicConnectionText $archPath ([pscustomobject]@{
        schema_version = 2
        overrides = [pscustomobject]$ordered
        archived_at = [pscustomobject]$orderedTs
    } | ConvertTo-Json -Depth 4)

    Set-SessionAlias -Context $Context -SessionKey $SessionKey -Title ''

    try {
        $state = Get-WebBridgeState $Context
        $wbChanged = $false
        if ($state.PSObject.Properties['session_bindings'] -and $state.session_bindings -and $state.session_bindings.PSObject.Properties[$SessionKey]) {
            $bind = $state.session_bindings.$SessionKey
            $bProf = if ($bind -and $bind.PSObject.Properties['browser_profile'] -and $bind.browser_profile) { [string]$bind.browser_profile } else { '' }
            $pPref = if ($bind -and $bind.PSObject.Properties['project_prefix'] -and $bind.project_prefix) { [string]$bind.project_prefix } else { '' }
            if ($bind -and $bind.PSObject.Properties['conv_uuid'] -and $bind.conv_uuid) {
                [void]$uuidsToDelete.Add([pscustomobject]@{ ConvUuid = [string]$bind.conv_uuid; BrowserProfile = $bProf; ProjectPrefix = $pPref })
            }
            if ($bind -and $bind.PSObject.Properties['retired_uuids'] -and $bind.retired_uuids) {
                foreach ($ru in @($bind.retired_uuids)) {
                    if ($ru) {
                        [void]$uuidsToDelete.Add([pscustomobject]@{ ConvUuid = [string]$ru; BrowserProfile = $bProf; ProjectPrefix = $pPref })
                    }
                }
            }
            $state.session_bindings.PSObject.Properties.Remove($SessionKey)
            $wbChanged = $true
        }
        if ($state.PSObject.Properties['breakers'] -and $state.breakers -and $state.breakers.PSObject.Properties[$SessionKey]) {
            $state.breakers.PSObject.Properties.Remove($SessionKey)
            $wbChanged = $true
        }
        if ($state.PSObject.Properties['breaker'] -and $state.breaker -and $state.breaker.PSObject.Properties[$SessionKey]) {
            $state.breaker.PSObject.Properties.Remove($SessionKey)
            $wbChanged = $true
        }
        if ($state.PSObject.Properties['queue'] -and $state.queue) {
            $filteredQ = @($state.queue | Where-Object { $_ -and $_.session_key -ne $SessionKey })
            if ($filteredQ.Count -ne @($state.queue).Count) {
                $state.queue = $filteredQ
                $wbChanged = $true
            }
        }
        if ($state.PSObject.Properties['outbox'] -and $state.outbox) {
            $filteredO = @($state.outbox | Where-Object { $_ -and $_.session_key -ne $SessionKey })
            if ($filteredO.Count -ne @($state.outbox).Count) {
                $state.outbox = $filteredO
                $wbChanged = $true
            }
        }
        if ($wbChanged) { Save-WebBridgeState $Context $state }
        foreach ($ud in $uuidsToDelete) {
            if ($ud -and $ud.ConvUuid) {
                Add-LocalRetireAction -Context $Context -TaskId $SessionKey -ConvUuid $ud.ConvUuid -BrowserProfile $ud.BrowserProfile -ProjectPrefix $ud.ProjectPrefix -Operation 'delete' -StopBeforeAction -CloseTab
            }
        }
    } catch { }

    $logPath = Join-Path (Join-Path $Context.DataRoot 'logs') 'tunnel.out.log'
    if (Test-Path -LiteralPath $logPath) {
        try {
            $lines = @([IO.File]::ReadAllLines($logPath, [Text.Encoding]::UTF8) | Where-Object { $_ -notmatch [regex]::Escape($SessionKey) })
            Write-AtomicConnectionText $logPath (($lines -join "`r`n") + $(if ($lines.Count -gt 0) { "`r`n" } else { '' }))
            if ((Get-Variable -Name 'TunnelLogTailCache' -Scope Script -ErrorAction SilentlyContinue) -and $script:TunnelLogTailCache -and $script:TunnelLogTailCache.ContainsKey($logPath)) {
                [void]$script:TunnelLogTailCache.Remove($logPath)
            }
        } catch { }
    }

    return [pscustomobject]@{
        SessionKey = $SessionKey
        PurgedTaskFile = $purgedTaskFile
        CleanedState = $true
    }
}

function Invoke-PurgeArchivedSession {
    param($Context, [string]$SessionKey, [switch]$PhysicalPurge, $Settings = $null)
    return (Remove-ArchivedTaskSession -Context $Context -SessionKey $SessionKey -PhysicalPurge -Settings $Settings)
}

function Clear-AllArchivedSessions {
    param($Context, $ArchivedSessions = @(), [switch]$PhysicalPurge, $Settings = $null)
    $overrides = Get-TaskArchiveOverrides $Context
    $clearedKeys = New-Object 'System.Collections.Generic.List[string]'
    $previousStates = @{}
    foreach ($ar in @($ArchivedSessions)) {
        $k = if ($ar -is [string]) { $ar } elseif ($ar -and $ar.PSObject.Properties['SessionKey']) { [string]$ar.SessionKey } else { '' }
        if ($k) {
            $previousStates[$k] = if ($overrides.ContainsKey($k)) { $overrides[$k] } else { 'archived' }
            if (-not $clearedKeys.Contains($k)) { $clearedKeys.Add($k) }
        }
    }
    foreach ($existingKey in @($overrides.Keys)) {
        if ($overrides[$existingKey] -eq 'archived' -and -not $clearedKeys.Contains($existingKey)) {
            $previousStates[$existingKey] = 'archived'
            $clearedKeys.Add($existingKey)
        }
    }
    $hubClearResp = Invoke-StudioHubAction -Context $Context -Payload @{
        action = 'clear_archived'
        physical_purge = $true
        session_keys = $clearedKeys.ToArray()
    }
    if ($hubClearResp -and $hubClearResp.ok) {
        $purgedCnt = if ($hubClearResp.PSObject.Properties['purged']) { @($hubClearResp.purged).Count } else { $clearedKeys.Count }
        return [pscustomobject]@{
            ClearedCount = [Math]::Max($clearedKeys.Count, $purgedCnt)
            ClearedKeys = $clearedKeys.ToArray()
            PreviousStates = $previousStates
            PurgedFileCount = $purgedCnt
        }
    }
    $purgedFiles = 0
    foreach ($ck in $clearedKeys) {
        $pr = Remove-ArchivedTaskSession -Context $Context -SessionKey $ck -PhysicalPurge -Settings $Settings
        if ($pr.PurgedTaskFile) { $purgedFiles++ }
    }
    return [pscustomobject]@{
        ClearedCount = $clearedKeys.Count
        ClearedKeys = $clearedKeys.ToArray()
        PreviousStates = $previousStates
        PurgedFileCount = $purgedFiles
    }
}

function Invoke-PurgeAllArchivedSessions {
    param($Context, $ArchivedSessions = @(), [switch]$PhysicalPurge, $Settings = $null)
    return (Clear-AllArchivedSessions -Context $Context -ArchivedSessions $ArchivedSessions -PhysicalPurge -Settings $Settings)
}

function Get-VerifiedBindingConvUuid {
    param($State, $Binding, [string]$WfrId = '')
    if (-not $Binding -or -not $Binding.PSObject.Properties['conv_uuid'] -or -not $Binding.conv_uuid) { return '' }
    $cand = [string]$Binding.conv_uuid
    $retired = @(if ($Binding.PSObject.Properties['retired_uuids'] -and $Binding.retired_uuids) { @($Binding.retired_uuids) })
    if ($retired -contains $cand) { return '' }
    if ($State -and $State.tabs) {
        foreach ($tp in $State.tabs.PSObject.Properties) {
            $tVal = $tp.Value
            if ($tVal -and $tVal.PSObject.Properties['conv_uuid'] -and [string]$tVal.conv_uuid -eq $cand) { return $cand }
        }
    }
    if ($cand -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -and $cand -ne $WfrId) {
        return $cand
    }
    return ''
}

function Initialize-RelayWindowWake {
    # Loads the Win32 helper used to find / restore / focus a top-level window. Returns $true when the type is usable.
    if ('Win32.RelayWindowWake' -as [type]) { return $true }
    $src = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace Win32 {
    public static class RelayWindowWake {
        public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] public struct WINDOWPLACEMENT {
            public int length; public int flags; public int showCmd;
            public POINT ptMinPosition; public POINT ptMaxPosition; public RECT rcNormalPosition;
        }
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
        [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT wp);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextLength(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int cmd);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hWnd);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
        [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

        // Largest top-level window (visible OR hidden) with a non-empty title owned by any of the given PIDs.
        public static IntPtr FindMainWindow(int[] pids, string className) {
            IntPtr best = IntPtr.Zero;
            long bestArea = -1;
            if (pids == null || pids.Length == 0) return best;
            EnumWindows(delegate(IntPtr h, IntPtr l) {
                uint pid;
                GetWindowThreadProcessId(h, out pid);
                if (Array.IndexOf(pids, (int)pid) < 0) return true;
                if (!string.IsNullOrEmpty(className)) {
                    StringBuilder sb = new StringBuilder(256);
                    GetClassName(h, sb, 256);
                    if (sb.ToString() != className) return true;
                }
                if (GetWindowTextLength(h) <= 0) return true;
                RECT r = new RECT();
                if (IsIconic(h)) {
                    WINDOWPLACEMENT wp = new WINDOWPLACEMENT();
                    wp.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
                    if (GetWindowPlacement(h, ref wp)) r = wp.rcNormalPosition;
                } else {
                    GetWindowRect(h, out r);
                }
                long area = (long)Math.Max(0, r.Right - r.Left) * (long)Math.Max(0, r.Bottom - r.Top);
                if (area > bestArea) { bestArea = area; best = h; }
                return true;
            }, IntPtr.Zero);
            return best;
        }

        public static bool IsShown(IntPtr h) {
            if (h == IntPtr.Zero) return false;
            if (!IsWindowVisible(h) || IsIconic(h)) return false;
            RECT r;
            if (!GetWindowRect(h, out r)) return false;
            return (r.Right - r.Left) > 0 && (r.Bottom - r.Top) > 0;
        }

        public static bool Wake(IntPtr h) {
            if (h == IntPtr.Zero) return false;
            bool minimized = IsIconic(h);
            if (minimized) ShowWindow(h, 9);            // SW_RESTORE
            else if (!IsWindowVisible(h)) ShowWindow(h, 5); // SW_SHOW
            uint dummy;
            IntPtr fg = GetForegroundWindow();
            uint fgThread = fg != IntPtr.Zero ? GetWindowThreadProcessId(fg, out dummy) : 0;
            uint tgtThread = GetWindowThreadProcessId(h, out dummy);
            bool attached = false;
            if (fgThread != 0 && tgtThread != 0 && fgThread != tgtThread) attached = AttachThreadInput(fgThread, tgtThread, true);
            keybd_event(0x12, 0, 0, UIntPtr.Zero);       // VK_MENU down
            keybd_event(0x12, 0, 2, UIntPtr.Zero);       // VK_MENU up
            bool ok = SetForegroundWindow(h);
            if (!ok || GetForegroundWindow() != h) {
                const uint flags = 0x0001 | 0x0002 | 0x0040; // NOSIZE | NOMOVE | SHOWWINDOW
                SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, flags); // HWND_TOPMOST
                SetWindowPos(h, new IntPtr(-2), 0, 0, 0, 0, flags); // HWND_NOTOPMOST
                BringWindowToTop(h);
                SetForegroundWindow(h);
            }
            if (attached) AttachThreadInput(fgThread, tgtThread, false);
            return IsShown(h);
        }
    }
}
'@
    try { Add-Type -TypeDefinition $src -Language CSharp -ErrorAction SilentlyContinue } catch { }
    return [bool]('Win32.RelayWindowWake' -as [type])
}

function Wait-RelayWindowShown {
    # Polls until the given HWND is visible, non-minimized and has a real size. Never throws.
    param([IntPtr]$Handle, [int]$TimeoutMs = 2500)
    try {
        if ($Handle -eq [IntPtr]::Zero -or -not (Initialize-RelayWindowWake)) { return $false }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            if ([Win32.RelayWindowWake]::IsShown($Handle)) { return $true }
            if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { return $false }
            Start-Sleep -Milliseconds 100
        }
    } catch { return $false }
}

function Show-RelayProcessMainWindow {
    # Finds the main window (hidden ones included) of the given process names, restores it, unlocks foreground focus
    # and verifies it is really visible on screen. Never kills processes. Returns [bool]; $false when no such process/window.
    # -Focus: always run the wake sequence (bring to front). Without it, an already visible window is accepted as-is
    # and the wake sequence only starts after -WakeDelayMs.
    param(
        [string[]]$ProcessName = @('ChatGPT'),
        [string]$ClassName = 'Chrome_WidgetWin_1',
        [int]$TimeoutMs = 2500,
        [int]$WakeDelayMs = 0,
        [switch]$Focus
    )
    try {
        if (-not $ProcessName -or -not (Initialize-RelayWindowWake)) { return $false }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $lastWake = -100000
        while ($true) {
            $pids = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
            if ($pids.Count -gt 0) {
                $h = [Win32.RelayWindowWake]::FindMainWindow([int[]]$pids, $ClassName)
                if ($h -ne [IntPtr]::Zero) {
                    if ((-not $Focus) -and [Win32.RelayWindowWake]::IsShown($h)) { return $true }
                    $elapsed = [int]$sw.ElapsedMilliseconds
                    if ($elapsed -ge $WakeDelayMs -and ($elapsed - $lastWake) -ge 600) {
                        $lastWake = $elapsed
                        if ([Win32.RelayWindowWake]::Wake($h)) { return $true }
                    }
                }
            }
            if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { return $false }
            Start-Sleep -Milliseconds 100
        }
    } catch { return $false }
}

function Invoke-ForegroundBrowserWindowActivate {
    # Restores + focuses an existing browser window and returns $true only when it is verified visible on screen.
    param([string]$BrowserExeName = 'chrome', [string]$TitleHint = '')
    $procs = @(Get-Process -Name $BrowserExeName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
    if ($procs.Count -eq 0) { return $false }
    try {
        if (-not (Initialize-RelayWindowWake)) { return $false }
        $target = $null
        if ($TitleHint) {
            $target = $procs | Where-Object { $_.MainWindowTitle -and $_.MainWindowTitle.IndexOf($TitleHint, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1
        }
        if (-not $target) {
            $target = $procs | Where-Object { $_.MainWindowTitle -match 'ChatGPT' } | Select-Object -First 1
        }
        if (-not $target) { $target = $procs[0] }
        $hwnd = $target.MainWindowHandle
        [void][Win32.RelayWindowWake]::Wake($hwnd)
        return (Wait-RelayWindowShown -Handle $hwnd -TimeoutMs 2000)
    } catch {
        return $false
    }
}

function Open-SessionWebPage {
    param(
        $Context,
        $Session,
        [switch]$NoLaunchBrowser,
        [switch]$RequireBoundConversation
    )
    if (-not $Session) { throw '未指定会话，无法打开对应网页。' }
    $sKey = [string]$Session.SessionKey
    $wfrId = if ($Session.PSObject.Properties['WfrId'] -and $Session.WfrId) { [string]$Session.WfrId } else { '' }
    $sTitle = if ($Session.PSObject.Properties['ShortTitle'] -and $Session.ShortTitle) { [string]$Session.ShortTitle } elseif ($Session.PSObject.Properties['Title']) { [string]$Session.Title } else { '' }
    $sessProf = if ($Session.PSObject.Properties['BrowserProfile'] -and $Session.BrowserProfile) { Resolve-RelayBrowserProfile ([string]$Session.BrowserProfile) $Context } else { '' }
    $doForegroundLaunch = (-not $NoLaunchBrowser) -and (-not $Context.Isolated)
    # Only a real foreground launch is verified against the screen; isolated / no-launch runs report $true.
    $windowOk = $true
    $hubPayload = @{
        action = 'open_tab'
        session_key = $sKey
        wfr_id = $wfrId
        title = $sTitle
        require_bound = [bool]$RequireBoundConversation
        no_launch = $true
    }
    if ($sessProf) {
        $hubPayload['browser_profile'] = $sessProf
        $hubPayload['browser'] = ($sessProf -split ':')[0]
    }
    $hubOpenResp = Invoke-StudioHubAction -Context $Context -Payload $hubPayload
    if ($hubOpenResp -and $hubOpenResp.ok) {
        $resAction = if ($hubOpenResp.PSObject.Properties['action'] -and $hubOpenResp.action) { [string]$hubOpenResp.action } else { 'OpenedBrowserUrl' }
        $resTabId = if ($hubOpenResp.PSObject.Properties['tab_id']) { [string]$hubOpenResp.tab_id } else { '' }
        $resConv = if ($hubOpenResp.PSObject.Properties['conv_uuid']) { [string]$hubOpenResp.conv_uuid } else { '' }
        $resBrowser = if ($hubOpenResp.PSObject.Properties['browser'] -and $hubOpenResp.browser) { [string]$hubOpenResp.browser } else { 'Chrome' }
        $resProf = if ($hubOpenResp.PSObject.Properties['browser_profile'] -and $hubOpenResp.browser_profile) { [string]$hubOpenResp.browser_profile } elseif ($sessProf) { $sessProf } else { Resolve-RelayBrowserProfile '' $Context }
        $resUrl = if ($hubOpenResp.PSObject.Properties['url'] -and $hubOpenResp.url) { [string]$hubOpenResp.url } elseif ($resAction -eq 'UnboundConversation') { '' } else { 'https://chatgpt.com/' }

        if ($doForegroundLaunch -and $resAction -ne 'UnboundConversation') {
            if ($resAction -eq 'FocusedDesktopApp') {
                $windowOk = [bool](Open-BridgeHandoverWindow -Url $resUrl -BrowserProfile 'Desktop:ChatGPT' -Context $Context)
                [void](Invoke-StudioHubAction -Context $Context -Payload @{
                    action = 'open_tab'
                    session_key = $sKey
                    conv_uuid = $resConv
                    browser_profile = 'Desktop:ChatGPT'
                    desktop_navigate_only = $true
                    no_launch = $true
                })
            } elseif ($resAction -eq 'FocusedExistingTab') {
                $bExeName = if ($resBrowser -match 'Edge' -or $resProf -match '^Edge:') { 'msedge' } else { 'chrome' }
                if (-not (Invoke-ForegroundBrowserWindowActivate -BrowserExeName $bExeName -TitleHint $sTitle)) {
                    $resAction = 'OpenedBrowserUrl'
                    $resBrowser = $resProf
                    $windowOk = [bool](Open-BridgeHandoverWindow -Url $resUrl -BrowserProfile $resProf -Context $Context)
                }
            } else {
                $windowOk = [bool](Open-BridgeHandoverWindow -Url $resUrl -BrowserProfile $resProf -Context $Context)
            }
        }
        return [pscustomobject]@{
            Action = $resAction
            TabId = $resTabId
            ConvUuid = $resConv
            Browser = $resBrowser
            BrowserProfile = $resProf
            Url = $resUrl
            WindowVerifiedVisible = $windowOk
        }
    }
    $state = Get-WebBridgeState $Context

    $bEntry = if ($state.session_bindings -and $state.session_bindings.PSObject.Properties[$sKey]) {
        $state.session_bindings.$sKey
    } else { $null }

    $retiredUuids = @(if ($bEntry -and $bEntry.PSObject.Properties['retired_uuids'] -and $bEntry.retired_uuids) { @($bEntry.retired_uuids) })
    $projPrefix = if ($bEntry -and $bEntry.PSObject.Properties['project_prefix'] -and $bEntry.project_prefix) { ([string]$bEntry.project_prefix).TrimEnd('/') } else { '' }
    $convUuid = Get-VerifiedBindingConvUuid -State $state -Binding $bEntry -WfrId $wfrId

    $browserProf = if ($bEntry -and $bEntry.PSObject.Properties['browser_profile'] -and $bEntry.browser_profile) {
        Resolve-RelayBrowserProfile ([string]$bEntry.browser_profile) $Context
    } elseif ($sessProf) {
        Resolve-RelayBrowserProfile $sessProf $Context
    } else {
        Resolve-RelayBrowserProfile '' $Context
    }
    $boundTabId = if ($bEntry -and $bEntry.PSObject.Properties['tab_id'] -and $bEntry.tab_id) { [string]$bEntry.tab_id } else { '' }

    $sessionMsgIds = @{}
    $sessionTabIds = @{}
    $latestOfflineHandoverUrl = ''
    if ($state.PSObject.Properties['queue'] -and $state.queue) {
        foreach ($qm in @($state.queue)) {
            if ($qm -and $sKey -and [string]$qm.session_key -eq $sKey -and [string]$qm.status -notin @('superseded', 'cancelled')) {
                if ($qm.PSObject.Properties['id'] -and $qm.id) { $sessionMsgIds[[string]$qm.id] = $true }
                foreach ($tf in @('claimed_tab_id', 'delivered_tab_id')) {
                    if ($qm.PSObject.Properties[$tf] -and $qm.$tf) { $sessionTabIds[[string]$qm.$tf] = $true }
                }
                if (-not $convUuid -and $qm.PSObject.Properties['mode'] -and [string]$qm.mode -eq 'new_window_handover' -and [string]$qm.status -in @('pending', 'claimed') -and $qm.PSObject.Properties['id'] -and $qm.id) {
                    $baseU = if ($projPrefix) { $projPrefix } else { 'https://chatgpt.com' }
                    $profQs = if ($browserProf) { '&relay_profile=' + [Uri]::EscapeDataString($browserProf) } else { '' }
                    $latestOfflineHandoverUrl = "$baseU/?relay_handover=1&msg_id=$([string]$qm.id)$profQs"
                }
            }
        }
    }

    if ($browserProf -match '^Desktop:') {
        $deskTab = if ($state.tabs -and $state.tabs.PSObject.Properties['tab_desktop_chatgpt']) { $state.tabs.tab_desktop_chatgpt } elseif ($state.tabs -and $state.tabs.PSObject.Properties['desktop_chatgpt_app']) { $state.tabs.desktop_chatgpt_app } else { $null }
        if (-not $convUuid -and $deskTab) {
            if ($deskTab.PSObject.Properties['conv_uuid'] -and $deskTab.conv_uuid) {
                $dUuid = [string]$deskTab.conv_uuid
                $dHints = @(if ($deskTab.PSObject.Properties['page_hints'] -and $deskTab.page_hints) { $deskTab.page_hints })
                if (($retiredUuids -notcontains $dUuid) -and $sKey -and ($dHints -contains $sKey)) {
                    $convUuid = $dUuid
                }
            }
            if (-not $convUuid -and $deskTab.PSObject.Properties['cabinet_drawers'] -and $deskTab.cabinet_drawers) {
                foreach ($drw in @($deskTab.cabinet_drawers)) {
                    if (-not $drw -or -not ($drw.PSObject.Properties['conv_uuid'] -and $drw.conv_uuid)) { continue }
                    $drwUuid = [string]$drw.conv_uuid
                    if ($retiredUuids -contains $drwUuid) { continue }
                    $drwHints = @(if ($drw.PSObject.Properties['task_hints'] -and $drw.task_hints) { $drw.task_hints })
                    if ($sKey -and ($drwHints -contains $sKey)) {
                        $convUuid = $drwUuid
                        break
                    }
                }
            }
        }
        if ($RequireBoundConversation -and (-not $convUuid) -and ($sessionMsgIds.Count -eq 0)) {
            return [pscustomobject]@{
                Action = 'UnboundConversation'
                TabId = ''
                ConvUuid = ''
                Browser = 'Desktop'
                BrowserProfile = $browserProf
                Url = ''
                WindowVerifiedVisible = $windowOk
            }
        }
        $deskUrl = if ($convUuid) { "app://-/index.html#c/$convUuid" } else { 'app://-/index.html' }
        if ($doForegroundLaunch) {
            $windowOk = [bool](Open-BridgeHandoverWindow -Url $deskUrl -BrowserProfile $browserProf -Context $Context)
        }
        return [pscustomobject]@{
            Action = 'FocusedDesktopApp'
            TabId = 'desktop_chatgpt_app'
            ConvUuid = $convUuid
            Browser = 'Desktop'
            BrowserProfile = $browserProf
            Url = $deskUrl
            WindowVerifiedVisible = $windowOk
        }
    }

    $nowUtc = [DateTimeOffset]::UtcNow
    $matchedLiveTab = $null

    # Pass 1: Discover conv_uuid from any same-profile tab matching session key, handover_msg_id, or wfrId (strictly excluding retired_uuids)
    if ($state.tabs) {
        foreach ($tp in $state.tabs.PSObject.Properties) {
            $tVal = $tp.Value
            if (-not $tVal) { continue }
            $tProf = if ($tVal.PSObject.Properties['browser_profile'] -and $tVal.browser_profile) { [string]$tVal.browser_profile } else { '' }
            if ($tProf -and $browserProf -and ($tProf -split ':')[0] -ne ($browserProf -split ':')[0]) { continue }
            $tUuid = if ($tVal.PSObject.Properties['conv_uuid'] -and $tVal.conv_uuid) { [string]$tVal.conv_uuid } else { '' }
            if (-not $tUuid) { continue }
            if ($retiredUuids -contains $tUuid) { continue }
            $tHmId = if ($tVal.PSObject.Properties['handover_msg_id'] -and $tVal.handover_msg_id) { [string]$tVal.handover_msg_id } else { '' }
            $hints = @(if ($tVal.PSObject.Properties['page_hints'] -and $tVal.page_hints) { $tVal.page_hints })
            $semanticMatch = ($convUuid -and $tUuid -eq $convUuid) -or
                             ($tHmId -and $sessionMsgIds.ContainsKey($tHmId)) -or
                             ($sKey -and ($hints -contains $sKey)) -or
                             ($wfrId -and ($hints -contains $wfrId))
            if ($semanticMatch) {
                if (-not $convUuid) { $convUuid = $tUuid }
                if (-not $projPrefix -and $tVal.PSObject.Properties['project_prefix'] -and $tVal.project_prefix) {
                    $projPrefix = ([string]$tVal.project_prefix).TrimEnd('/')
                } elseif (-not $projPrefix -and $tVal.PSObject.Properties['url'] -and [string]$tVal.url -match '^(https://chatgpt\.com/g/g-p-[a-zA-Z0-9_-]+)') {
                    $projPrefix = $matches[1]
                }
                break
            }
        }
    }

    # Pass 2: Find a live tab (<15s old) in strict 3-tier priority (conv_uuid -> claimed/delivered/handover_msg_id -> page_hints), zero fallbackLiveTab!
    $tier1Tab = $null; $tier2Tab = $null; $tier3Tab = $null
    if ($state.tabs) {
        foreach ($tp in $state.tabs.PSObject.Properties) {
            $tVal = $tp.Value
            if (-not $tVal) { continue }
            $tProf = if ($tVal.PSObject.Properties['browser_profile'] -and $tVal.browser_profile) { [string]$tVal.browser_profile } else { '' }
            if ($tProf -and $browserProf -and ($tProf -split ':')[0] -ne ($browserProf -split ':')[0]) { continue }
            $ageSec = 999999.0
            $lastSeenRaw = if ($tVal.PSObject.Properties['last_seen_at'] -and $tVal.last_seen_at) {
                [string]$tVal.last_seen_at
            } elseif ($tVal.PSObject.Properties['last_seen'] -and $tVal.last_seen) {
                [string]$tVal.last_seen
            } else { '' }
            if ($lastSeenRaw) {
                try {
                    $ageSec = ($nowUtc - [DateTimeOffset]::Parse($lastSeenRaw)).TotalSeconds
                } catch { $ageSec = 999999.0 }
            }
            if ($ageSec -gt 15.0) { continue }
            $tUuid = if ($tVal.PSObject.Properties['conv_uuid'] -and $tVal.conv_uuid) { [string]$tVal.conv_uuid } else { '' }
            if ($tUuid -and ($retiredUuids -contains $tUuid)) { continue }
            $tId = if ($tVal.PSObject.Properties['tab_id'] -and $tVal.tab_id) { [string]$tVal.tab_id } else { [string]$tp.Name }
            $tHmId = if ($tVal.PSObject.Properties['handover_msg_id'] -and $tVal.handover_msg_id) { [string]$tVal.handover_msg_id } else { '' }
            $tUrl = if ($tVal.PSObject.Properties['url'] -and $tVal.url) { [string]$tVal.url } else { '' }
            $hints = @(if ($tVal.PSObject.Properties['page_hints'] -and $tVal.page_hints) { $tVal.page_hints })

            if ($convUuid -and $tUuid -and $tUuid -eq $convUuid) {
                $tier1Tab = $tVal
                break
            }
            $urlMatchesMsg = $false
            foreach ($mk in $sessionMsgIds.Keys) {
                if ($tUrl -match ([regex]::Escape("msg_id=$mk"))) { $urlMatchesMsg = $true; break }
            }
            if (-not $tier2Tab -and (($tId -and $sessionTabIds.ContainsKey($tId)) -or ($tHmId -and $sessionMsgIds.ContainsKey($tHmId)) -or $urlMatchesMsg -or ($boundTabId -and $tId -eq $boundTabId -and (-not $convUuid -or $tUuid -eq $convUuid)))) {
                $tier2Tab = $tVal
            }
            if (-not $tier3Tab -and (($sKey -and ($hints -contains $sKey)) -or ($wfrId -and ($hints -contains $wfrId)))) {
                $tier3Tab = $tVal
            }
        }
    }
    $matchedLiveTab = if ($tier1Tab) { $tier1Tab } elseif ($tier2Tab) { $tier2Tab } else { $tier3Tab }
    if ($matchedLiveTab) {
        if (-not $convUuid -and $matchedLiveTab.PSObject.Properties['conv_uuid'] -and $matchedLiveTab.conv_uuid) {
            $convUuid = [string]$matchedLiveTab.conv_uuid
        }
        if (-not $projPrefix -and $matchedLiveTab.PSObject.Properties['project_prefix'] -and $matchedLiveTab.project_prefix) {
            $projPrefix = ([string]$matchedLiveTab.project_prefix).TrimEnd('/')
        }
    }

    if ($convUuid) {
        [void](Set-SessionBridgeBinding -Context $Context -SessionKey $sKey -ConvUuid $convUuid -ProjectPrefix $projPrefix -TabId $(if ($matchedLiveTab -and $matchedLiveTab.PSObject.Properties['tab_id'] -and $matchedLiveTab.tab_id) { [string]$matchedLiveTab.tab_id } else { $boundTabId }) -Title $(if ($matchedLiveTab -and $matchedLiveTab.PSObject.Properties['title'] -and $matchedLiveTab.title) { [string]$matchedLiveTab.title } else { $sTitle }))
        $state = Get-WebBridgeState $Context
    }

    if ($RequireBoundConversation -and (-not $convUuid) -and (-not $projPrefix) -and (-not $matchedLiveTab) -and (-not $latestOfflineHandoverUrl)) {
        return [pscustomobject]@{
            Action = 'UnboundConversation'
            TabId = ''
            ConvUuid = ''
            Browser = ($browserProf -split ':')[0]
            BrowserProfile = $browserProf
            Url = ''
            WindowVerifiedVisible = $windowOk
        }
    }

    $baseUrl = if ($projPrefix) { $projPrefix } else { 'https://chatgpt.com' }
    if ($matchedLiveTab) {
        $targetTabId = [string]$matchedLiveTab.tab_id
        $resolvedTabUrl = if ($matchedLiveTab.PSObject.Properties['url'] -and $matchedLiveTab.url -and $matchedLiveTab.url -match '/c/') { [string]$matchedLiveTab.url } elseif ($convUuid) { "$baseUrl/c/$convUuid" } elseif ($latestOfflineHandoverUrl) { $latestOfflineHandoverUrl } else { "$baseUrl/" }
        $bName = if (($matchedLiveTab.PSObject.Properties['browser'] -and $matchedLiveTab.browser -eq 'Edge') -or $browserProf -match '^Edge:') { 'msedge' } else { 'chrome' }
        $state | Add-Member -NotePropertyName 'focus_tab_id' -NotePropertyValue $targetTabId -Force
        Save-WebBridgeState $Context $state
        if ($doForegroundLaunch) {
            if (-not (Invoke-ForegroundBrowserWindowActivate -BrowserExeName $bName -TitleHint $sTitle)) {
                $fallbackOk = [bool](Open-BridgeHandoverWindow -Url $resolvedTabUrl -BrowserProfile $browserProf -Context $Context)
                return [pscustomobject]@{
                    Action = 'OpenedBrowserUrl'
                    TabId = ''
                    ConvUuid = $convUuid
                    Browser = $browserProf
                    BrowserProfile = $browserProf
                    Url = $resolvedTabUrl
                    WindowVerifiedVisible = $fallbackOk
                }
            }
        }
        return [pscustomobject]@{
            Action = 'FocusedExistingTab'
            TabId = $targetTabId
            ConvUuid = $convUuid
            Browser = $(if ($matchedLiveTab.PSObject.Properties['browser'] -and $matchedLiveTab.browser) { [string]$matchedLiveTab.browser } else { 'Chrome' })
            BrowserProfile = $browserProf
            Url = $resolvedTabUrl
            WindowVerifiedVisible = $windowOk
        }
    }

    $targetUrl = if ($convUuid) { "$baseUrl/c/$convUuid" } elseif ($latestOfflineHandoverUrl) { $latestOfflineHandoverUrl } else { "$baseUrl/" }
    if ($doForegroundLaunch) {
        $windowOk = [bool](Open-BridgeHandoverWindow -Url $targetUrl -BrowserProfile $browserProf -Context $Context)
    }
    return [pscustomobject]@{
        Action = 'OpenedBrowserUrl'
        TabId = ''
        ConvUuid = $convUuid
        Browser = $browserProf
        BrowserProfile = $browserProf
        Url = $targetUrl
        WindowVerifiedVisible = $windowOk
    }
}

function Get-OpenWebPageToastText {
    # Pure text router for the "打开网页 ↗" toast: success copy only when the window was verified visible on screen.
    param($Result)
    if (-not $Result) { return '' }
    $action = [string]$Result.Action
    if ($action -eq 'UnboundConversation') { return '该任务尚未关联网页对话' }
    $verified = [bool]($Result.PSObject.Properties['WindowVerifiedVisible'] -and $Result.WindowVerifiedVisible -eq $true)
    if (-not $verified) { return '⚠ 已请求打开窗口，但屏幕上未检测到可见窗口（可能仍在后台托盘），请从任务栏/托盘手动恢复' }
    $hasRoom = [bool]($Result.PSObject.Properties['ConvUuid'] -and [string]$Result.ConvUuid)
    if ($action -eq 'FocusedDesktopApp') {
        if ($hasRoom) { return '↗ 已激活并切到 ChatGPT 桌面端对应对话' }
        return '↗ 已为您打开 ChatGPT 窗口'
    }
    if ($action -eq 'FocusedExistingTab') {
        if ($hasRoom) { return "↗ 已激活并切到 $($Result.Browser) 中对应的 ChatGPT 网页标签页" }
        return '↗ 已为您打开 ChatGPT 窗口'
    }
    return "↗ 已在 $($Result.Browser) 打开对应的 ChatGPT 网页（$($Result.Url)）"
}

function New-StallWakeupPrompt {
    param($Session, [string]$CustomUserText = '')
    if (-not $Session) { return $(if ($CustomUserText) { $CustomUserText } else { '请继续推进当前未完成步骤。' }) }
    $steps = @(if ($Session.PSObject.Properties.Name -contains 'Steps' -and $Session.Steps) { $Session.Steps })
    $totSteps = $steps.Count
    $compSteps = @($steps | Where-Object { $_.Status -in @('completed', 'quarantined') }).Count
    $inProg = $steps | Where-Object { $_.Status -eq 'in_progress' } | Select-Object -First 1
    $curStepLabel = if ($inProg) { "步骤 $($inProg.Id)：$($inProg.Title)" } elseif ($Session.ActionText) { $Session.ActionText } else { '当前未完步骤' }
    $ckpts = @(if ($Session.PSObject.Properties.Name -contains 'ReadableCheckpoints' -and $Session.ReadableCheckpoints) { $Session.ReadableCheckpoints })
    $latestCkpt = if ($ckpts.Count -gt 0) { "$($ckpts[0].Title)（$($ckpts[0].Prose)）" } elseif ($Session.LatestSummary) { $Session.LatestSummary } else { '无额外检查点文字' }
    $commits = @(if ($Session.PSObject.Properties.Name -contains 'RecentCommits' -and $Session.RecentCommits) { $Session.RecentCommits })
    $commitInfo = if ($commits.Count -gt 0) { "[$($commits[0].Sha)] $($commits[0].Message)（$($commits[0].AgoText)）" } else { '暂无近期 Git 提交记录' }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    if ($totSteps -gt 0 -or ($Session.SessionKey -and $Session.SessionKey -match '^tsk_')) {
        $lines.Add("【本机进度同步与续跑指令】")
        $lines.Add("- 任务契约：$($Session.Title)（编号：$($Session.SessionKey)）")
        $lines.Add("- 当前阶段：$curStepLabel（已完成 $compSteps / $totSteps 步，进度 $($Session.ProgressPercent)%）")
        $lines.Add("- 最近检查点：$latestCkpt")
        $lines.Add("- 最近 Git 提交：$commitInfo")
        if ($CustomUserText.Trim()) {
            $lines.Add("- 用户补充指令：$($CustomUserText.Trim())")
        } else {
            $lines.Add("- 续跑要求：本机 MCP 隧道与本机工具（含 task_manage 接口）正常在线，后台无卡死进程。请核对上述本机最新进度，直接从【$curStepLabel】剩余部分继续推进，严禁重复前面已完成步骤。")
        }
    } else {
        if ($CustomUserText.Trim()) {
            $lines.Add("【本机状态同步】当前会话（$($Session.Title)，尾号 $($Session.ShortId)）已累计调用 $($Session.CommandCount) 次本机工具。最近 Git 提交：$commitInfo。")
            $lines.Add("用户指令：$($CustomUserText.Trim())")
        } else {
            $lines.Add("【本机状态同步】当前会话（$($Session.Title)，尾号 $($Session.ShortId)）本机 MCP 隧道畅通（累计已执行 $($Session.CommandCount) 次工具调用，最近 Git 提交：$commitInfo）。请按刚才的上下文直接继续推进剩余步骤。")
        }
    }
    return ($lines.ToArray() -join "`n")
}

function New-HandoverPrompt {
    param($Session, [string]$CustomUserText = '')
    if (-not $Session) { return '请调用当前已连接的本机 MCP 工具（含 task_manage 接口）读取本机当前任务状态并继续执行。' }
    $steps = @(if ($Session.PSObject.Properties.Name -contains 'Steps' -and $Session.Steps) { $Session.Steps })
    $totSteps = $steps.Count
    $compList = @($steps | Where-Object { $_.Status -in @('completed', 'quarantined') })
    $compSteps = $compList.Count
    $compSummary = if ($compSteps -gt 0) {
        (($compList | Select-Object -Last 6 | ForEach-Object { "步骤$($_.Id)($($_.Title))" }) -join '、')
    } else { '尚无标记完成的步骤' }
    $inProg = $steps | Where-Object { $_.Status -eq 'in_progress' } | Select-Object -First 1
    $curStepLabel = if ($inProg) { "步骤 $($inProg.Id)：$($inProg.Title)" } else { '当前进行中阶段' }
    $ckpts = @(if ($Session.PSObject.Properties.Name -contains 'ReadableCheckpoints' -and $Session.ReadableCheckpoints) { $Session.ReadableCheckpoints })
    $latestCkpt = if ($ckpts.Count -gt 0) { "$($ckpts[0].Title) —— $($ckpts[0].Prose)" } elseif ($Session.PSObject.Properties['LatestSummary'] -and $Session.LatestSummary) { [string]$Session.LatestSummary } else { '请直接通过 task_manage 查询' }
    $commits = @(if ($Session.PSObject.Properties.Name -contains 'RecentCommits' -and $Session.RecentCommits) { $Session.RecentCommits })
    $commitInfo = if ($commits.Count -gt 0) { "[$($commits[0].Sha)] $($commits[0].Message)（$($commits[0].TimeText) · $($commits[0].AgoText)）" } else { '请执行 git log -n 3 查看' }
    $goalVal = if ($Session.PSObject.Properties['Goal'] -and $Session.Goal) { [string]$Session.Goal } else { [string]$Session.Title }
    $progVal = if ($Session.PSObject.Properties['ProgressPercent'] -and $null -ne $Session.ProgressPercent) { [int]$Session.ProgressPercent } else { 0 }

    $lines = @(
        "【RelayStudio 跨窗口无缝交接指令】",
        "原 ChatGPT 网页会话因超长或超时中断，现开启新窗口接力续跑。请立即通过当前已连接的本机 MCP 工具（含 `task_manage` 接口）接管本机现场，严禁从头重做：",
        "1. 任务契约编号：$($Session.SessionKey)（任务标题：$($Session.Title)）",
        "2. 任务总目标：$goalVal",
        "3. 已完成阶段（$compSteps / $totSteps 步，$progVal%）：$compSummary",
        "4. 当前接力起点：【$curStepLabel】",
        "5. 本机最近检查点：$latestCkpt",
        "6. 本机最近 Git 提交：$commitInfo",
        "7. 接力执行铁律：请先调用 `task_manage`（读取任务 $($Session.SessionKey)）与 `exec_command`（核对工作区 git status），确认上述本机现场后，直接从【$curStepLabel】未完成处继续往下推进！"
    )
    if ($CustomUserText.Trim()) {
        $lines += "8. 用户附加要求：$($CustomUserText.Trim())"
    }
    return ($lines -join "`n")
}

function Get-WebBridgeState {
    param($Context)
    $logDir = Join-Path $Context.DataRoot 'logs'
    [IO.Directory]::CreateDirectory($logDir) | Out-Null
    $bpath = Join-Path $logDir 'web-bridge-state.json'
    if (Test-Path -LiteralPath $bpath) {
        try {
            $raw = [IO.File]::ReadAllText($bpath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($raw) { return $raw }
        } catch { }
    }
    return [pscustomobject]@{
        schema_version = 1
        updated_at = [DateTimeOffset]::UtcNow.ToString('o')
        tabs = [pscustomobject]@{}
        session_bindings = [pscustomobject]@{}
        queue = @()
        breakers = [pscustomobject]@{}
    }
}

function Save-WebBridgeState {
    param($Context, $State)
    if (-not $State) { return }
    $logDir = Join-Path $Context.DataRoot 'logs'
    [IO.Directory]::CreateDirectory($logDir) | Out-Null
    $bpath = Join-Path $logDir 'web-bridge-state.json'
    if ($State.PSObject.Properties.Name -contains 'updated_at') {
        $State.updated_at = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $json = $State | ConvertTo-Json -Depth 8
    Write-AtomicConnectionText $bpath $json
}

$script:BrowserProfilesCache = $null
$script:BrowserProfilesCacheUtc = [DateTime]::MinValue

function Resolve-RelayBrowserProfile {
    param(
        [string]$ProfileSpec = '',
        $Context = $null
    )
    $raw = if ($null -ne $ProfileSpec) { $ProfileSpec.Trim() } else { '' }
    if ($raw -match '^Profile\s+\d+$' -or $raw -eq 'Default') {
        return "Chrome:$raw"
    }
    if ($raw) {
        return $raw
    }
    try {
        $s = if ($Context) { Read-ConnectionSettings $Context } else { $null }
        if ($s -and $s.PSObject.Properties['default_browser_profile'] -and $s.default_browser_profile) {
            $cfgProf = ([string]$s.default_browser_profile).Trim()
            if ($cfgProf -match '^Profile\s+\d+$' -or $cfgProf -eq 'Default') { return "Chrome:$cfgProf" }
            return $cfgProf
        }
        $defSettingsPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'data\settings.json' } else { '' }
        if ($defSettingsPath -and (Test-Path -LiteralPath $defSettingsPath)) {
            $rawSet = [IO.File]::ReadAllText($defSettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($rawSet -and $rawSet.PSObject.Properties['default_browser_profile'] -and $rawSet.default_browser_profile) {
                $cfgProf2 = ([string]$rawSet.default_browser_profile).Trim()
                if ($cfgProf2 -match '^Profile\s+\d+$' -or $cfgProf2 -eq 'Default') { return "Chrome:$cfgProf2" }
                return $cfgProf2
            }
        }
        $avail = @(Get-AvailableBrowserProfiles -Context $Context)
        $defObj = $avail | Where-Object { $_.IsDefault } | Select-Object -First 1
        if ($defObj -and $defObj.Id) {
            return [string]$defObj.Id
        }
    } catch {}
    return 'Desktop:ChatGPT'
}

function Get-AvailableBrowserProfiles {
    param(
        [switch]$ForceRefresh,
        $Context = $null
    )
    $configuredDefault = ''
    $preferredIds = @()
    try {
        if ($Context -and $Context.PSObject.Properties['SettingsPath'] -and $Context.SettingsPath -and (Test-Path -LiteralPath $Context.SettingsPath)) {
            $ctxSet = [IO.File]::ReadAllText($Context.SettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($ctxSet -and $ctxSet.PSObject.Properties['default_browser_profile'] -and $ctxSet.default_browser_profile) {
                $configuredDefault = ([string]$ctxSet.default_browser_profile).Trim()
            }
            if ($ctxSet -and $ctxSet.PSObject.Properties['preferred_browser_profiles'] -and $ctxSet.preferred_browser_profiles) {
                $preferredIds = @($ctxSet.preferred_browser_profiles | ForEach-Object { [string]$_ })
            }
        }
        $defSettingsPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'data\settings.json' } else { '' }
        if ($defSettingsPath -and (Test-Path -LiteralPath $defSettingsPath)) {
            $rawSet = [IO.File]::ReadAllText($defSettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ((-not $configuredDefault) -and $rawSet -and $rawSet.PSObject.Properties['default_browser_profile'] -and $rawSet.default_browser_profile) {
                $configuredDefault = ([string]$rawSet.default_browser_profile).Trim()
            }
            if ($preferredIds.Count -eq 0 -and $rawSet -and $rawSet.PSObject.Properties['preferred_browser_profiles'] -and $rawSet.preferred_browser_profiles) {
                $preferredIds = @($rawSet.preferred_browser_profiles | ForEach-Object { [string]$_ })
            }
        }
    } catch {}
    if ($configuredDefault -match '^Profile\s+\d+$' -or $configuredDefault -eq 'Default') {
        $configuredDefault = "Chrome:$configuredDefault"
    }
    if ((-not $ForceRefresh) -and $script:BrowserProfilesCache -and (([DateTime]::UtcNow - $script:BrowserProfilesCacheUtc).TotalSeconds -lt 15.0)) {
        $cachedDefault = ($script:BrowserProfilesCache | Where-Object { $_.IsDefault } | Select-Object -First 1)
        if ((-not $configuredDefault) -or ($cachedDefault -and [string]$cachedDefault.Id -eq $configuredDefault)) {
            return $script:BrowserProfilesCache
        }
    }
    $extDetected = New-Object 'System.Collections.Generic.List[object]'
    $browsers = @(
        @{ Name = 'Chrome'; Root = "$env:LOCALAPPDATA\Google\Chrome\User Data" },
        @{ Name = 'Edge';   Root = "$env:LOCALAPPDATA\Microsoft\Edge\User Data" }
    )
    foreach ($b in $browsers) {
        $lsPath = Join-Path $b.Root 'Local State'
        if (-not (Test-Path -LiteralPath $lsPath)) { continue }
        try {
            $ls = [IO.File]::ReadAllText($lsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $cache = $ls.profile.info_cache
            if (-not $cache) { continue }
            foreach ($prop in $cache.PSObject.Properties) {
                $profDir = [string]$prop.Name
                $info = $prop.Value
                $pFolder = Join-Path $b.Root $profDir
                $hasExt = $false
                foreach ($prefFile in @('Preferences', 'Secure Preferences')) {
                    $pf = Join-Path $pFolder $prefFile
                    if (Test-Path -LiteralPath $pf) {
                        $rawPref = [IO.File]::ReadAllText($pf, [Text.Encoding]::UTF8)
                        if ($rawPref -match 'browser-bridge|RelayStudio') {
                            $hasExt = $true
                            break
                        }
                    }
                }
                if (-not $hasExt) { continue }
                $id = "$($b.Name):$profDir"
                $uName = if ($info.PSObject.Properties['user_name'] -and $info.user_name) { [string]$info.user_name } else { '' }
                $pName = if ($info.PSObject.Properties['name'] -and $info.name) { [string]$info.name } else { $profDir }
                $emailPrefix = if ($uName -match '^([^@]+)@') { $matches[1] } else { '' }
                $label = if ($emailPrefix) {
                    "$($b.Name) · $emailPrefix"
                } elseif ($pName) {
                    "$($b.Name) · $pName"
                } else {
                    "$($b.Name) · $profDir"
                }
                $prefIdx = [Array]::IndexOf($preferredIds, $id)
                $priority = if ($prefIdx -ge 0) { $prefIdx + 1 } else { 10 }
                $extDetected.Add([pscustomobject]@{
                    Id = $id
                    Label = $label
                    UserName = $uName
                    IsDefault = $false
                    SortOrder = $priority
                })
            }
        } catch { }
    }
    $detected = New-Object 'System.Collections.Generic.List[object]'
    foreach ($ep in ($extDetected | Sort-Object SortOrder, Label)) {
        $detected.Add($ep)
    }
    $detected.Add([pscustomobject]@{
        Id = 'Desktop:ChatGPT'
        Label = '💻 ChatGPT 桌面端 (桌面客户端)'
        UserName = 'ChatGPT Desktop App'
        IsDefault = $false
        SortOrder = 20
    })
    if ($extDetected.Count -eq 0) {
        $detected.Add([pscustomobject]@{ Id = 'Chrome:Default'; Label = 'Chrome · Default'; UserName = ''; IsDefault = $false; SortOrder = 21 })
        $detected.Add([pscustomobject]@{ Id = 'Edge:Default';   Label = 'Edge · Default';   UserName = ''; IsDefault = $false; SortOrder = 22 })
    }
    if ($configuredDefault) {
        $existingMatch = $detected | Where-Object { $_.Id -eq $configuredDefault } | Select-Object -First 1
        if (-not $existingMatch) {
            $cfgLabel = ($configuredDefault -replace ':', ' · ')
            $detected.Insert(0, [pscustomobject]@{
                Id = $configuredDefault
                Label = $cfgLabel
                UserName = ''
                IsDefault = $true
                SortOrder = 0
            })
        } else {
            $existingMatch.IsDefault = $true
        }
    } elseif ($extDetected.Count -gt 0) {
        $detected[0].IsDefault = $true
    } else {
        $deskItem = $detected | Where-Object { $_.Id -eq 'Desktop:ChatGPT' } | Select-Object -First 1
        if ($deskItem) { $deskItem.IsDefault = $true }
    }
    $sortedProfs = @($detected | Sort-Object SortOrder, Label)
    if (-not ($sortedProfs | Where-Object { $_.IsDefault })) {
        $sortedProfs[0].IsDefault = $true
    }
    $finalProfs = @($sortedProfs | ForEach-Object {
        [pscustomobject]@{
            Id = $_.Id
            Label = $_.Label
            UserName = $_.UserName
            IsDefault = [bool]$_.IsDefault
        }
    })
    $script:BrowserProfilesCache = $finalProfs
    $script:BrowserProfilesCacheUtc = [DateTime]::UtcNow
    return $finalProfs
}

function Set-SessionBridgeBinding {
    param(
        $Context,
        [string]$SessionKey,
        [string]$ConvUuid = '',
        [string]$TabId = '',
        [string]$Title = '',
        [string]$BrowserProfile = '',
        [string]$TargetMode = '',
        [string]$ProjectPrefix = '',
        [string]$TargetModel = '',
        [string]$ReasoningEffort = ''
    )
    if (-not $SessionKey) { return $null }
    $fwd = @{
        Context = $Context
        SessionKey = $SessionKey
        HubAction = 'bind_session'
    }
    foreach ($k in @('ConvUuid','TabId','Title','BrowserProfile','TargetMode','ProjectPrefix','TargetModel','ReasoningEffort')) {
        if ($PSBoundParameters.ContainsKey($k)) { $fwd[$k] = $PSBoundParameters[$k] }
    }
    $res = Set-TaskComposerConfig @fwd
    if ($res -and $res.PSObject.Properties['binding'] -and $res.binding) { return $res.binding }
    return $res
}

function Set-TaskComposerConfig {
    param(
        $Context,
        [Parameter(Mandatory)][string]$SessionKey,
        [string]$TargetMode = '',
        [string]$BrowserProfile = '',
        [string]$TargetModel = '',
        [string]$ReasoningEffort = '',
        $AutoResendEnabled = $null,
        [int]$StallSeconds = 0,
        [double]$StallMinutes = 0,
        [int]$MaxRetries = 0,
        [string]$ConvUuid = '',
        [string]$TabId = '',
        [string]$Title = '',
        [string]$ProjectPrefix = '',
        [string]$HubAction = 'set_task_composer_config'
    )
    if (-not $SessionKey) { return $null }
    $payload = @{
        action = $(if ($HubAction) { $HubAction } else { 'set_task_composer_config' })
        session_key = $SessionKey
    }
    if ($TargetMode) { $payload['target_mode'] = $TargetMode }
    if ($BrowserProfile) { $payload['browser_profile'] = $BrowserProfile }
    if ($TargetModel) { $payload['target_model'] = $TargetModel }
    if ($ReasoningEffort) { $payload['reasoning_effort'] = $ReasoningEffort }
    if ($null -ne $AutoResendEnabled) { $payload['auto_resend_enabled'] = [bool]$AutoResendEnabled }
    if ($StallSeconds -gt 0) {
        $payload['stall_seconds'] = $StallSeconds
        $payload['stall_minutes'] = if ($StallSeconds -lt 60) { [Math]::Round($StallSeconds / 60.0, 2) } else { [int][Math]::Round($StallSeconds / 60.0) }
    } elseif ($StallMinutes -gt 0) {
        $payload['stall_minutes'] = $StallMinutes
        $payload['stall_seconds'] = [int][Math]::Round($StallMinutes * 60)
    }
    if ($MaxRetries -gt 0) { $payload['max_retries'] = $MaxRetries }
    if ($PSBoundParameters.ContainsKey('ConvUuid')) { $payload['conv_uuid'] = $ConvUuid }
    if ($PSBoundParameters.ContainsKey('TabId')) { $payload['tab_id'] = $TabId }
    if ($PSBoundParameters.ContainsKey('Title')) { $payload['title'] = $Title }
    if ($PSBoundParameters.ContainsKey('ProjectPrefix')) { $payload['project_prefix'] = $ProjectPrefix }

    $hubResp = Invoke-StudioHubAction -Context $Context -Payload $payload
    if ($hubResp -and $hubResp.ok) {
        return $hubResp
    }

    $state = Get-WebBridgeState $Context
    if (-not $state.session_bindings) {
        $state | Add-Member -NotePropertyName 'session_bindings' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not $state.breakers) {
        $state | Add-Member -NotePropertyName 'breakers' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $existing = if ($state.session_bindings.PSObject.Properties[$SessionKey]) { $state.session_bindings.$SessionKey } else { $null }
    $oldProfile = if ($existing -and $existing.PSObject.Properties['browser_profile'] -and $existing.browser_profile) { [string]$existing.browser_profile } else { Resolve-RelayBrowserProfile '' $Context }
    $oldUuid = if ($existing -and $existing.PSObject.Properties['conv_uuid'] -and $existing.conv_uuid) { [string]$existing.conv_uuid } else { '' }
    $oldLocked = if ($existing -and $existing.PSObject.Properties['user_locked_browser']) { [bool]$existing.user_locked_browser } else { $false }
    $retiredList = New-Object 'System.Collections.Generic.List[string]'
    if ($existing -and $existing.PSObject.Properties['retired_uuids'] -and $existing.retired_uuids) {
        foreach ($ru in @($existing.retired_uuids)) {
            if ($ru -and -not $retiredList.Contains([string]$ru)) {
                $retiredList.Add([string]$ru)
            }
        }
    }

    $resolvedConvUuid = if ($PSBoundParameters.ContainsKey('ConvUuid')) { $ConvUuid } else { $oldUuid }
    $resolvedTabId = if ($PSBoundParameters.ContainsKey('TabId')) { $TabId } elseif ($existing -and $existing.PSObject.Properties['tab_id']) { [string]$existing.tab_id } else { '' }
    $resolvedTitle = if ($PSBoundParameters.ContainsKey('Title')) { $Title } elseif ($existing -and $existing.PSObject.Properties['title']) { [string]$existing.title } else { '' }
    $resolvedProfile = if ($BrowserProfile) { $BrowserProfile } else { $oldProfile }
    $resolvedLocked = if ($BrowserProfile) { $true } else { $oldLocked }
    $resolvedProjPrefix = if ($PSBoundParameters.ContainsKey('ProjectPrefix') -and $ProjectPrefix) {
        $ProjectPrefix.TrimEnd('/')
    } elseif ($existing -and $existing.PSObject.Properties['project_prefix'] -and $existing.project_prefix) {
        ([string]$existing.project_prefix).TrimEnd('/')
    } else { '' }

    if ($BrowserProfile -and $BrowserProfile -ne $oldProfile -and -not $PSBoundParameters.ContainsKey('ConvUuid')) {
        if ($oldUuid -and -not $retiredList.Contains($oldUuid)) {
            $retiredList.Add($oldUuid)
        }
        $resolvedConvUuid = ''
        $resolvedTabId = ''
    } elseif ($PSBoundParameters.ContainsKey('ConvUuid') -and $ConvUuid -and $oldUuid -and $ConvUuid -ne $oldUuid) {
        if (-not $retiredList.Contains($oldUuid)) {
            $retiredList.Add($oldUuid)
        }
        if ($retiredList.Contains($ConvUuid)) {
            [void]$retiredList.Remove($ConvUuid)
        }
    } elseif ($PSBoundParameters.ContainsKey('ConvUuid') -and $ConvUuid -and $retiredList.Contains($ConvUuid)) {
        [void]$retiredList.Remove($ConvUuid)
    }
    if ($PSBoundParameters.ContainsKey('ConvUuid') -and $ConvUuid -and $state.PSObject.Properties['queue'] -and $state.queue) {
        foreach ($qItem in @($state.queue)) {
            if ($qItem -and [string]$qItem.session_key -eq $SessionKey -and [string]$qItem.status -eq 'pending' -and [string]$qItem.mode -eq 'new_window_handover') {
                $qItem | Add-Member -NotePropertyName 'status' -NotePropertyValue 'superseded' -Force
            }
        }
    }

    $rawMode = if ($TargetMode) { $TargetMode } elseif ($existing -and $existing.PSObject.Properties['target_mode'] -and $existing.target_mode) { [string]$existing.target_mode } else { 'follow_window' }
    $resolvedMode = if ($rawMode -eq 'new_window') { 'new_window' } else { 'follow_window' }
    $resolvedModel = if ($TargetModel) { $TargetModel } elseif ($existing -and $existing.PSObject.Properties['target_model'] -and $existing.target_model) { [string]$existing.target_model } else { 'inherit' }
    $resolvedEffort = if ($ReasoningEffort) { $ReasoningEffort } elseif ($existing -and $existing.PSObject.Properties['reasoning_effort'] -and $existing.reasoning_effort) { [string]$existing.reasoning_effort } else { 'inherit' }
    if ($ReasoningEffort) {
        if ($ReasoningEffort -in @('低', '中', '高', '轻度', '标准', '深度', '极高', '最高', '深入', '超强', '极简', 'min', 'minimal', 'light', 'low', 'standard', 'medium', 'extended', 'high', 'xhigh', 'max', 'ultra')) {
            if ($resolvedModel -in @('gpt-6', 'gpt-6-instant')) { $resolvedModel = 'gpt-6-thinking' }
            elseif ($resolvedModel -in @('gpt-5-6', 'gpt-5-6-instant')) { $resolvedModel = 'gpt-5-6-thinking' }
        } elseif ($ReasoningEffort -in @('即时', '未开启思考', 'instant', 'none')) {
            $resolvedEffort = 'none'
            if ($resolvedModel -in @('gpt-6', 'gpt-6-thinking', 'inherit')) { $resolvedModel = 'gpt-6-instant' }
            elseif ($resolvedModel -in @('gpt-5-6', 'gpt-5-6-thinking')) { $resolvedModel = 'gpt-5-6-instant' }
        }
    } elseif ($TargetModel -in @('gpt-6-instant', 'gpt-5-6-instant')) {
        $resolvedEffort = 'none'
    }
    $resolvedAuto = if ($null -ne $AutoResendEnabled) { [bool]$AutoResendEnabled } elseif ($existing -and $existing.PSObject.Properties['auto_resend_enabled'] -and $null -ne $existing.auto_resend_enabled) { [bool]$existing.auto_resend_enabled } else { $true }
    $resolvedStallSec = if ($StallSeconds -gt 0) {
        $StallSeconds
    } elseif ($StallMinutes -gt 0) {
        [int][Math]::Round($StallMinutes * 60)
    } elseif ($existing -and $existing.PSObject.Properties['stall_seconds'] -and [int]$existing.stall_seconds -gt 0) {
        [int]$existing.stall_seconds
    } elseif ($existing -and $existing.PSObject.Properties['stall_minutes'] -and [double]$existing.stall_minutes -gt 0) {
        [int][Math]::Round([double]$existing.stall_minutes * 60)
    } else { 180 }
    $resolvedStall = if ($resolvedStallSec -lt 60) { [Math]::Round($resolvedStallSec / 60.0, 2) } else { [int][Math]::Max(1, [Math]::Round($resolvedStallSec / 60.0)) }
    $resolvedRetries = if ($MaxRetries -gt 0) { $MaxRetries } elseif ($existing -and $existing.PSObject.Properties['max_retries'] -and [int]$existing.max_retries -gt 0) { [int]$existing.max_retries } else { 1 }
    $lockedModel = if ($PSBoundParameters.ContainsKey('TargetModel') -and $TargetModel) {
        $TargetModel -notin @('inherit', 'auto')
    } elseif ($existing -and $existing.PSObject.Properties['user_locked_model']) {
        [bool]$existing.user_locked_model
    } else {
        $resolvedModel -notin @('', 'inherit', 'auto')
    }
    $lockedEffort = if ($PSBoundParameters.ContainsKey('ReasoningEffort') -and $ReasoningEffort) {
        $resolvedEffort -notin @('inherit', 'auto')
    } elseif ($TargetModel -in @('gpt-6-instant', 'gpt-5-6-instant')) {
        $true
    } elseif ($existing -and $existing.PSObject.Properties['user_locked_effort']) {
        [bool]$existing.user_locked_effort
    } else {
        $resolvedEffort -notin @('', 'inherit', 'auto')
    }
    $lastLiveModel = if ($existing -and $existing.PSObject.Properties['last_live_model'] -and $existing.last_live_model) { [string]$existing.last_live_model } else { '' }
    $lastLiveEffort = if ($existing -and $existing.PSObject.Properties['last_live_effort'] -and $existing.last_live_effort) { [string]$existing.last_live_effort } else { '' }

    $newBinding = [pscustomobject]@{
        conv_uuid = $resolvedConvUuid
        tab_id = $resolvedTabId
        title = $resolvedTitle
        browser = ($resolvedProfile -split ':')[0]
        browser_profile = $resolvedProfile
        user_locked_browser = $resolvedLocked
        target_mode = $resolvedMode
        target_model = $resolvedModel
        reasoning_effort = $resolvedEffort
        user_locked_model = $lockedModel
        user_locked_effort = $lockedEffort
        last_live_model = $lastLiveModel
        last_live_effort = $lastLiveEffort
        auto_resend_enabled = $resolvedAuto
        stall_seconds = $resolvedStallSec
        stall_minutes = $resolvedStall
        max_retries = $resolvedRetries
        project_prefix = $resolvedProjPrefix
        retired_uuids = $retiredList.ToArray()
        updated_at = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $state.session_bindings | Add-Member -NotePropertyName $SessionKey -NotePropertyValue $newBinding -Force

    $curBrk = if ($state.breakers.PSObject.Properties[$SessionKey]) { $state.breakers.$SessionKey } else { [pscustomobject]@{ session_key = $SessionKey; stage = 'Idle'; retry_count = 0 } }
    $curBrk | Add-Member -NotePropertyName 'auto_enabled' -NotePropertyValue $resolvedAuto -Force
    $curBrk | Add-Member -NotePropertyName 'stall_seconds' -NotePropertyValue $resolvedStallSec -Force
    $curBrk | Add-Member -NotePropertyName 'stall_minutes' -NotePropertyValue $resolvedStall -Force
    $curBrk | Add-Member -NotePropertyName 'max_retries' -NotePropertyValue $resolvedRetries -Force
    if ($resolvedAuto -and $curBrk.PSObject.Properties['stage'] -and $curBrk.stage -eq 'Tripped') {
        $curBrk.stage = 'Idle'
        $curBrk | Add-Member -NotePropertyName 'tripped' -NotePropertyValue $false -Force
        $curBrk | Add-Member -NotePropertyName 'retry_count' -NotePropertyValue 0 -Force
    }
    $state.breakers | Add-Member -NotePropertyName $SessionKey -NotePropertyValue $curBrk -Force

    Save-WebBridgeState $Context $state
    return [pscustomobject]@{
        ok = $true
        binding = $newBinding
        breaker = $curBrk
    }
}

function Resolve-BrowserExecutablePath {
    param([string]$BrowserName = 'Chrome')
    $isEdge = ($BrowserName -match 'Edge|msedge')
    $candidates = if ($isEdge) {
        @(
            'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
            'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
            "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
        )
    } else {
        @(
            'C:\Program Files\Google\Chrome\Application\chrome.exe',
            'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
            "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
        )
    }
    foreach ($cand in $candidates) {
        if ($cand -and (Test-Path -LiteralPath $cand)) { return $cand }
    }
    $regLeaf = if ($isEdge) { 'msedge.exe' } else { 'chrome.exe' }
    foreach ($regPath in @(
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$regLeaf",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$regLeaf"
    )) {
        try {
            $val = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue).'(default)'
            if ($val) {
                $cleanVal = ([string]$val).Trim('"')
                if (Test-Path -LiteralPath $cleanVal) { return $cleanVal }
            }
        } catch { }
    }
    return ''
}

function Start-ChatGptDesktopApp {
    # Cold-start or wake the ChatGPT Desktop App (MSIX `OpenAI.Codex`). Never falls back to a browser and never kills the process
    # (it also hosts the user's local Codex tasks).
    # Non-minimized path returns [bool]: $true only when a visible, non-minimized ChatGPT window was verified on screen.
    param([switch]$Minimized, $Context = $null)
    $exe = ''
    $aumid = 'OpenAI.Codex_2p2nqsd0c76g0!App'
    try {
        $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
        if ($pkg) {
            if ($pkg.PackageFamilyName) { $aumid = "$($pkg.PackageFamilyName)!App" }
            if ($pkg.InstallLocation) {
                $candidate = Join-Path $pkg.InstallLocation 'app\ChatGPT.exe'
                if (Test-Path -LiteralPath $candidate) { $exe = $candidate }
            }
        }
    } catch { }

    $allProcs = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)
    if ($Minimized) {
        if ($allProcs.Count -gt 0) { return }
        if ($exe) {
            Start-Process -FilePath $exe -ArgumentList '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=9222' -WindowStyle Minimized | Out-Null
        } else {
            Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$aumid" | Out-Null
        }
        return
    }

    if ($allProcs.Count -gt 0) {
        # a) Ask the desktop app itself (through the hub / CDP) to run its built-in open-current-main-window + stealFocus. Silent on failure.
        try { [void](Invoke-StudioHubAction -Context $Context -Payload @{ action = 'desktop_wake_main_window' }) } catch { }
        # b-d) Enumerate every ChatGPT.exe top-level window (hidden ones included), restore + focus-unlock, verify within 2.5s.
        if (Show-RelayProcessMainWindow -ProcessName @('ChatGPT') -TimeoutMs 2500 -Focus) { return $true }
        # Still no visible window (tray-only): MSIX shell activation re-opens the main window of the SAME process (keeps CDP alive).
        try { Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$aumid" | Out-Null } catch { }
        return [bool](Show-RelayProcessMainWindow -ProcessName @('ChatGPT') -TimeoutMs 2500 -Focus)
    }

    # Completely closed: cold-start with remote-debugging-port=9222 in normal foreground mode, then verify within 8s.
    try {
        if ($exe) {
            Start-Process -FilePath $exe -ArgumentList '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=9222' -WindowStyle Normal | Out-Null
        } else {
            Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$aumid" | Out-Null
        }
    } catch { return $false }
    return [bool](Show-RelayProcessMainWindow -ProcessName @('ChatGPT') -TimeoutMs 8000 -Focus)
}

function Open-BridgeHandoverWindow {
    # Opens (or wakes) the handover window. Returns [bool]: whether a visible, non-minimized window was verified on screen.
    param(
        [string]$Url = 'https://chatgpt.com/?relay_handover=1',
        [string]$BrowserProfile = '',
        $Context = $null
    )
    $BrowserProfile = Resolve-RelayBrowserProfile $BrowserProfile $Context
    if ($BrowserProfile -match '^Desktop:') {
        return [bool](Start-ChatGptDesktopApp -Context $Context)
    }
    if ($BrowserProfile -match '^Edge:(.+)$') {
        $edgeProf = $matches[1]
        $edgeExe = Resolve-BrowserExecutablePath -BrowserName 'Edge'
        if ($edgeExe) {
            Start-Process -FilePath $edgeExe -ArgumentList "--profile-directory=`"$edgeProf`"", "`"$Url`"" -WindowStyle Normal | Out-Null
            return [bool](Show-RelayProcessMainWindow -ProcessName @('msedge') -TimeoutMs 4000 -WakeDelayMs 1500)
        }
    }
    $chromeProf = if ($BrowserProfile -match '^Chrome:(.+)$') { $matches[1] } elseif ($BrowserProfile) { $BrowserProfile } else { 'Default' }
    $chromeExe = Resolve-BrowserExecutablePath -BrowserName 'Chrome'
    if ($chromeExe) {
        Start-Process -FilePath $chromeExe -ArgumentList "--profile-directory=`"$chromeProf`"", "`"$Url`"" -WindowStyle Normal | Out-Null
        return [bool](Show-RelayProcessMainWindow -ProcessName @('chrome') -TimeoutMs 4000 -WakeDelayMs 1500)
    }
    Start-Process $Url | Out-Null
    return [bool](Show-RelayProcessMainWindow -ProcessName @('chrome', 'msedge', 'firefox') -ClassName '' -TimeoutMs 4000 -WakeDelayMs 1500)
}

function Build-OfflineSessionQueueSlice {
    param($State, [string]$SessionKey)
    if (-not $SessionKey) {
        return [pscustomobject]@{
            PendingQueue = @()
            PendingQueueCount = 0
            SentWebMessages = @()
            HasInFlightQueue = $false
        }
    }
    $qArr = @(if ($State -and $State.PSObject.Properties['queue'] -and $State.queue) { $State.queue })
    $pendingOnly = @(foreach ($qItem in @($qArr | Where-Object { $_ -and [string]$_.session_key -eq $SessionKey -and [string]$_.status -eq 'pending' })) {
        $dtQ = ConvertTo-LocalDateTimeOffset $qItem.created_at $null
        $tStr = if ($dtQ) { $dtQ.ToString('MM-dd HH:mm:ss') } else { '刚刚' }
        $dTxt = if ($qItem.PSObject.Properties['display_text'] -and $qItem.display_text) { [string]$qItem.display_text } elseif ($qItem.PSObject.Properties['prompt'] -and $qItem.prompt) { [string]$qItem.prompt } else { '' }
        [pscustomobject]@{
            Id = $(if ($qItem.PSObject.Properties['id']) { [string]$qItem.id } else { '' })
            TimeText = $tStr
            CreatedAt = $(if ($qItem.PSObject.Properties['created_at']) { [string]$qItem.created_at } else { '' })
            Text = $dTxt
            Prompt = $(if ($qItem.PSObject.Properties['prompt']) { [string]$qItem.prompt } else { $dTxt })
            Status = [string]$qItem.status
            Mode = $(if ($qItem.PSObject.Properties['mode']) { [string]$qItem.mode } else { '' })
            DeferUntilStopped = [bool]($qItem.PSObject.Properties['defer_until_stopped'] -and $qItem.defer_until_stopped)
            BrowserProfile = $(if ($qItem.PSObject.Properties['browser_profile']) { [string]$qItem.browser_profile } else { '' })
            TargetModel = $(if ($qItem.PSObject.Properties['target_model']) { [string]$qItem.target_model } else { 'inherit' })
            ReasoningEffort = $(if ($qItem.PSObject.Properties['reasoning_effort']) { [string]$qItem.reasoning_effort } else { 'inherit' })
        }
    })
    $rawMsgs = @(foreach ($qItem in @($qArr | Where-Object { $_ -and [string]$_.session_key -eq $SessionKey -and [string]$_.status -notin @('superseded', 'cancelled') })) {
        $dtQ = ConvertTo-LocalDateTimeOffset $qItem.created_at $null
        $tStr = if ($dtQ) { $dtQ.ToString('MM-dd HH:mm:ss') } else { '刚刚' }
        $dTxt = if ($qItem.PSObject.Properties['display_text'] -and $qItem.display_text) { [string]$qItem.display_text } elseif ($qItem.PSObject.Properties['prompt'] -and $qItem.prompt) { [string]$qItem.prompt } else { '' }
        [pscustomobject]@{
            Id = $(if ($qItem.PSObject.Properties['id']) { [string]$qItem.id } else { '' })
            TimeText = $tStr
            CreatedAt = $(if ($qItem.PSObject.Properties['created_at']) { [string]$qItem.created_at } else { '' })
            Text = $dTxt
            Prompt = $(if ($qItem.PSObject.Properties['prompt']) { [string]$qItem.prompt } else { $dTxt })
            Status = [string]$qItem.status
            Mode = $(if ($qItem.PSObject.Properties['mode']) { [string]$qItem.mode } else { '' })
            DeferUntilStopped = [bool]($qItem.PSObject.Properties['defer_until_stopped'] -and $qItem.defer_until_stopped)
            BrowserProfile = $(if ($qItem.PSObject.Properties['browser_profile']) { [string]$qItem.browser_profile } else { '' })
            TargetModel = $(if ($qItem.PSObject.Properties['target_model']) { [string]$qItem.target_model } else { 'inherit' })
            ReasoningEffort = $(if ($qItem.PSObject.Properties['reasoning_effort']) { [string]$qItem.reasoning_effort } else { 'inherit' })
        }
    })
    if ($rawMsgs.Count -gt 1) { [Array]::Reverse($rawMsgs) }
    $hasClaimed = @($rawMsgs | Where-Object { $_.Status -eq 'claimed' }).Count -gt 0
    return [pscustomobject]@{
        PendingQueue = $pendingOnly
        PendingQueueCount = $pendingOnly.Count
        SentWebMessages = @($rawMsgs | Select-Object -First 20)
        HasInFlightQueue = ($pendingOnly.Count -gt 0 -or $hasClaimed)
    }
}

function Send-WebBridgeMessage {
    param(
        $Context,
        $Session,
        [ValidateSet('in_place_wakeup','new_window_handover','custom_message','follow_window')][string]$Mode = 'in_place_wakeup',
        [string]$CustomUserText = '',
        [string]$BrowserProfile = '',
        [string]$TargetModel = '',
        [string]$ReasoningEffort = '',
        [switch]$DeferUntilStopped,
        [switch]$StopAndRetire,
        [switch]$OpenBrowserOnHandover,
        [bool]$IsSinglePaneReplace = $true
    )
    if (-not $Session) {
        $Session = [pscustomobject]@{
            SessionKey = '__new_task__'
            WfrId = '__new_task__'
            Title = '新发起任务'
            ShortTitle = '新发起任务'
            StepCountText = '0 / 0 步'
            CommandCount = 0
            ProgressPercent = 0
        }
        $Mode = 'new_window_handover'
    }
    $wfrId = if ($Session.PSObject.Properties['WfrId'] -and $Session.WfrId) { [string]$Session.WfrId } else { [string]$Session.SessionKey }
    $shortTitle = if ($Session.PSObject.Properties['ShortTitle'] -and $Session.ShortTitle) { [string]$Session.ShortTitle } else { [string]$Session.Title }

    # Primary Path (Cleanup 2): Delegate directly to Python Hub (:8766) first without duplicate local disk reads!
    $hubPayload = @{
        action = 'enqueue_message'
        session_key = [string]$Session.SessionKey
        wfr_id = $wfrId
        target_title = $shortTitle
        mode = $(if ($Mode -eq 'follow_window') { '' } else { $Mode })
        user_text = $CustomUserText
        command_count = [int]$Session.CommandCount
        progress_percent = [int]$Session.ProgressPercent
        defer_until_stopped = [bool]$DeferUntilStopped
        stop_and_retire = [bool]$StopAndRetire
        open_browser = [bool]($OpenBrowserOnHandover -and (-not $DeferUntilStopped) -and (-not $Context.Isolated))
        is_single_pane_replace = [bool]$IsSinglePaneReplace
    }
    if ($BrowserProfile) { $hubPayload['browser_profile'] = $BrowserProfile }
    if ($TargetModel) { $hubPayload['target_model'] = $TargetModel }
    if ($ReasoningEffort) { $hubPayload['reasoning_effort'] = $ReasoningEffort }

    $hubMsgResp = Invoke-StudioHubAction -Context $Context -Payload $hubPayload
    if ($hubMsgResp -and $hubMsgResp.ok) {
        $mObj = if ($hubMsgResp.PSObject.Properties['message'] -and $hubMsgResp.message) { $hubMsgResp.message } else { $null }
        $retMsgId = if ($hubMsgResp.PSObject.Properties['message_id'] -and $hubMsgResp.message_id) { [string]$hubMsgResp.message_id } elseif ($mObj -and $mObj.id) { [string]$mObj.id } else { '' }
        $retMode = if ($mObj -and $mObj.PSObject.Properties['mode'] -and $mObj.mode) { [string]$mObj.mode } else { $Mode }
        $retPrompt = if ($mObj -and $mObj.PSObject.Properties['prompt'] -and $mObj.prompt) { [string]$mObj.prompt } else { $CustomUserText }
        $retHandoverUrl = if ($hubMsgResp.PSObject.Properties['handover_url'] -and $hubMsgResp.handover_url) { [string]$hubMsgResp.handover_url } else { '' }
        $retProf = if ($mObj -and $mObj.PSObject.Properties['browser_profile'] -and $mObj.browser_profile) { [string]$mObj.browser_profile } elseif ($BrowserProfile) { $BrowserProfile } else { '' }
        $retModel = if ($mObj -and $mObj.PSObject.Properties['target_model'] -and $mObj.target_model) { [string]$mObj.target_model } elseif ($TargetModel) { $TargetModel } else { 'inherit' }
        $retEffort = if ($mObj -and $mObj.PSObject.Properties['reasoning_effort'] -and $mObj.reasoning_effort) { [string]$mObj.reasoning_effort } elseif ($ReasoningEffort) { $ReasoningEffort } else { 'inherit' }
        $retStage = if ($hubMsgResp.PSObject.Properties['stage'] -and $hubMsgResp.stage) { [string]$hubMsgResp.stage } else { 'WakeupSent' }
        # Spec v4.1: a send from the launchpad makes the hub mint the formal tsk_<16hex> task; report its real key.
        $retSessionKey = if ($hubMsgResp.PSObject.Properties['session_key'] -and $hubMsgResp.session_key) { [string]$hubMsgResp.session_key } else { [string]$Session.SessionKey }
        $retCreated = [bool]($hubMsgResp.PSObject.Properties['created_task'] -and $hubMsgResp.created_task)
        $retQueueSlice = if ($hubMsgResp.PSObject.Properties['queue_slice']) { $hubMsgResp.queue_slice } else { $null }
        return [pscustomobject]@{
            MessageId = $retMsgId
            SessionKey = $retSessionKey
            CreatedTask = $retCreated
            Mode = $retMode
            Prompt = $retPrompt
            HandoverUrl = $retHandoverUrl
            BrowserProfile = $retProf
            TargetModel = $retModel
            ReasoningEffort = $retEffort
            StatusText = $(if ($retMode -eq 'new_window_handover') { '已触发新窗口接力交接' } else { '已向网页端投递消息' })
            Stage = $retStage
            QueueSlice = $retQueueSlice
            queue_slice = $retQueueSlice
        }
    }

    # Offline Fallback (only used when :8766 Hub is not running, e.g., isolated unit tests)
    $state = Get-WebBridgeState $Context
    $bEntry = if ($state.session_bindings -and $state.session_bindings.PSObject.Properties[$Session.SessionKey]) {
        $state.session_bindings.$($Session.SessionKey)
    } else { $null }
    $browserProf = if ($BrowserProfile) { Resolve-RelayBrowserProfile $BrowserProfile $Context } elseif ($bEntry -and $bEntry.PSObject.Properties['browser_profile'] -and $bEntry.browser_profile) { Resolve-RelayBrowserProfile ([string]$bEntry.browser_profile) $Context } else { Resolve-RelayBrowserProfile '' $Context }
    $projPrefix = if ($bEntry -and $bEntry.PSObject.Properties['project_prefix'] -and $bEntry.project_prefix) { ([string]$bEntry.project_prefix).TrimEnd('/') } else { '' }
    $effModel = if ($TargetModel) { $TargetModel } elseif ($bEntry -and $bEntry.PSObject.Properties['target_model'] -and $bEntry.target_model) { [string]$bEntry.target_model } else { 'inherit' }
    $effEffort = if ($ReasoningEffort) { $ReasoningEffort } elseif ($bEntry -and $bEntry.PSObject.Properties['reasoning_effort'] -and $bEntry.reasoning_effort) { [string]$bEntry.reasoning_effort } else { 'inherit' }

    $convUuid = Get-VerifiedBindingConvUuid -State $state -Binding $bEntry -WfrId $wfrId
    $retiredUuids = @(if ($bEntry -and $bEntry.PSObject.Properties['retired_uuids'] -and $bEntry.retired_uuids) { @($bEntry.retired_uuids) })

    # Spec v4.4 Batch Follow Queueing + Cross-Browser Auto-Upgrade
    $existingPioneer = $null
    foreach ($qi in @($state.queue)) {
        if ($qi -and [string]$qi.session_key -eq [string]$Session.SessionKey -and [string]$qi.mode -eq 'new_window_handover' -and [string]$qi.status -in @('pending', 'claimed')) {
            $existingPioneer = $qi
            break
        }
    }
    $wouldHandover = ($Mode -eq 'new_window_handover') -or ($bEntry -and $bEntry.PSObject.Properties['target_mode'] -and $bEntry.target_mode -eq 'new_window') -or ((-not $convUuid) -and ($retiredUuids.Count -gt 0))
    if ($existingPioneer -and $wouldHandover -and (-not $StopAndRetire) -and [string]$Session.SessionKey -ne '__new_task__') {
        if (-not $CustomUserText.Trim()) {
            if ((-not $DeferUntilStopped) -and $existingPioneer.PSObject.Properties['defer_until_stopped'] -and [bool]$existingPioneer.defer_until_stopped) {
                $existingPioneer | Add-Member -NotePropertyName 'defer_until_stopped' -NotePropertyValue $false -Force
                Save-WebBridgeState $Context $state
            }
            return [pscustomobject]@{
                MessageId = [string]$existingPioneer.id
                SessionKey = [string]$Session.SessionKey
                CreatedTask = $false
                Mode = 'new_window_handover'
                Prompt = [string]$existingPioneer.prompt
                HandoverUrl = [string]$existingPioneer.handover_url
                BrowserProfile = $browserProf
                TargetModel = $effModel
                ReasoningEffort = $effEffort
                StatusText = '已复用在途新窗口接力交接'
                Stage = 'HandoverSent'
            }
        }
        $Mode = 'custom_message'
        $convUuid = ''
        $DeferUntilStopped = $false
        $OpenBrowserOnHandover = $false
    } elseif ($bEntry -and $bEntry.PSObject.Properties['target_mode'] -and $bEntry.target_mode -eq 'new_window' -and $Mode -ne 'new_window_handover') {
        $Mode = 'new_window_handover'
        $OpenBrowserOnHandover = (-not $DeferUntilStopped)
    } elseif ((-not $convUuid) -and ($retiredUuids.Count -gt 0) -and $Mode -ne 'new_window_handover') {
        $Mode = 'new_window_handover'
        $OpenBrowserOnHandover = (-not $DeferUntilStopped)
    }

    $liveMod = ''
    $liveEff = ''
    if ($Mode -eq 'new_window_handover' -and $state.PSObject.Properties['tabs'] -and $state.tabs) {
        $matchConv = if ($bEntry -and $bEntry.PSObject.Properties['conv_uuid'] -and $bEntry.conv_uuid) { [string]$bEntry.conv_uuid } else { $convUuid }
        $matchTab = if ($bEntry -and $bEntry.PSObject.Properties['tab_id'] -and $bEntry.tab_id) { [string]$bEntry.tab_id } else { '' }
        foreach ($tpLive in $state.tabs.PSObject.Properties) {
            $tvLive = $tpLive.Value
            if (-not $tvLive) { continue }
            $tvConv = if ($tvLive.PSObject.Properties['conv_uuid']) { [string]$tvLive.conv_uuid } else { '' }
            $tvId = if ($tvLive.PSObject.Properties['tab_id']) { [string]$tvLive.tab_id } else { [string]$tpLive.Name }
            if (($matchConv -and $tvConv -eq $matchConv) -or ($matchTab -and $tvId -eq $matchTab)) {
                if ($tvLive.PSObject.Properties['current_model'] -and $tvLive.current_model -and [string]$tvLive.current_model -notin @('inherit', 'auto')) {
                    $liveMod = [string]$tvLive.current_model
                    if ($bEntry) { $bEntry | Add-Member -NotePropertyName 'last_live_model' -NotePropertyValue $liveMod -Force }
                }
                if ($tvLive.PSObject.Properties['current_effort'] -and $tvLive.current_effort -and [string]$tvLive.current_effort -notin @('inherit', 'auto')) {
                    $liveEff = [string]$tvLive.current_effort
                    if ($bEntry) { $bEntry | Add-Member -NotePropertyName 'last_live_effort' -NotePropertyValue $liveEff -Force }
                }
                break
            }
        }
    }

    if ($Mode -eq 'new_window_handover' -and $StopAndRetire) {
        $oldConvToStop = if ($bEntry -and $bEntry.PSObject.Properties['conv_uuid'] -and $bEntry.conv_uuid) { [string]$bEntry.conv_uuid } else { $convUuid }
        if ($oldConvToStop) {
            $retList = New-Object 'System.Collections.Generic.List[object]'
            if ($state.PSObject.Properties['retire_actions'] -and $state.retire_actions) {
                foreach ($ra in @($state.retire_actions)) {
                    if ($ra) { $retList.Add($ra) }
                }
            }
            $retList.Add([pscustomobject]@{
                id = 'ret_' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
                session_key = [string]$Session.SessionKey
                conv_uuid = $oldConvToStop
                tab_id = $(if ($bEntry -and $bEntry.PSObject.Properties['tab_id']) { [string]$bEntry.tab_id } else { '' })
                browser_profile = $browserProf
                project_prefix = $projPrefix
                reason = 'manual_stop_and_retire'
                stop_before_archive = $true
                status = 'pending'
                attempts = 0
                created_at = [DateTimeOffset]::UtcNow.ToString('o')
            })
            while ($retList.Count -gt 50) { $retList.RemoveAt(0) }
            $state | Add-Member -NotePropertyName 'retire_actions' -NotePropertyValue $retList.ToArray() -Force
            if ($bEntry) {
                if ($oldConvToStop -notin $retiredUuids) {
                    $retiredUuids = @($retiredUuids) + @($oldConvToStop)
                    $bEntry | Add-Member -NotePropertyName 'retired_uuids' -NotePropertyValue $retiredUuids -Force
                }
                $bEntry | Add-Member -NotePropertyName 'conv_uuid' -NotePropertyValue '' -Force
                $bEntry | Add-Member -NotePropertyName 'tab_id' -NotePropertyValue '' -Force
            }
            $convUuid = ''
        }
    }

    if ($Mode -eq 'new_window_handover') {
        if ((-not $TargetModel) -and $effModel -in @('', 'inherit', 'auto')) {
            if ($liveMod) { $effModel = $liveMod }
            elseif ($bEntry -and $bEntry.PSObject.Properties['last_live_model'] -and $bEntry.last_live_model -and [string]$bEntry.last_live_model -notin @('inherit', 'auto')) {
                $effModel = [string]$bEntry.last_live_model
            }
        }
        if ((-not $ReasoningEffort) -and $effEffort -in @('', 'inherit', 'auto')) {
            if ($liveEff) { $effEffort = $liveEff }
            elseif ($bEntry -and $bEntry.PSObject.Properties['last_live_effort'] -and $bEntry.last_live_effort -and [string]$bEntry.last_live_effort -notin @('inherit', 'auto')) {
                $effEffort = [string]$bEntry.last_live_effort
            }
        }
    } elseif ($bEntry) {
        if ((-not $TargetModel) -and $bEntry.PSObject.Properties['user_locked_model'] -and (-not [bool]$bEntry.user_locked_model)) {
            $effModel = 'inherit'
        }
        if ((-not $ReasoningEffort) -and $bEntry.PSObject.Properties['user_locked_effort'] -and (-not [bool]$bEntry.user_locked_effort)) {
            $effEffort = 'inherit'
        }
    }

    $autoCfg = Get-AutoResendConfig $Context
    $prompt = if ($Session.SessionKey -eq '__new_task__') {
        if ($CustomUserText.Trim()) { $CustomUserText.Trim() } else { '请调用当前已连接的本机 MCP 工具（含 task_manage 接口）接管并开始新任务。' }
    } elseif ($Mode -eq 'new_window_handover') {
        $baseHandover = New-HandoverPrompt -Session $Session -CustomUserText ''
        if ($CustomUserText.Trim()) {
            "$baseHandover`n`n【用户追加指令】：`n$($CustomUserText.Trim())"
        } else {
            $baseHandover
        }
    } elseif ($Mode -in @('follow_window', 'custom_message')) {
        if ($CustomUserText.Trim()) {
            $CustomUserText.Trim()
        } else {
            '请继续'
        }
    } else {
        New-StallWakeupPrompt -Session $Session -CustomUserText $CustomUserText
    }

    $displayText = if ($Session.SessionKey -eq '__new_task__') {
        $prompt
    } elseif ($Mode -eq 'new_window_handover') {
        if ($CustomUserText.Trim()) {
            "【新窗交接 + 追加指令】$($CustomUserText.Trim())"
        } else {
            $prompt
        }
    } elseif ($CustomUserText.Trim()) {
        $CustomUserText.Trim()
    } elseif ($Mode -eq 'follow_window') {
        '请继续'
    } else {
        "请核对本机最新进度（$($Session.StepCountText)），继续推进当前未完成步骤。"
    }

    $modelSlug = ''
    if ($effModel -and $effModel -notin @('inherit', 'auto') -and $effModel -notmatch '网页当前|跟随') {
        $availModels = @(if ($state -and $state.PSObject.Properties['available_models'] -and $state.available_models) { $state.available_models })
        foreach ($am in $availModels) {
            if ($am -and $am.PSObject.Properties['slug'] -and $am.slug) {
                $amSlug = [string]$am.slug
                $amTitle = if ($am.PSObject.Properties['title']) { [string]$am.title } else { '' }
                if ($effModel -ieq $amSlug -or ($amTitle -and $effModel -ieq $amTitle)) {
                    $modelSlug = $amSlug
                    break
                }
            }
        }
        if (-not $modelSlug) {
            $modelSlug = ([regex]::Replace($effModel.ToLowerInvariant().Replace('.', '-'), '[^a-z0-9_-]+', '-')).Trim('-')
        }
    }

    $msgId = 'msg_' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + '_' + [Guid]::NewGuid().ToString('N').Substring(0, 4)
    $baseUrl = if ($projPrefix) { $projPrefix } else { 'https://chatgpt.com' }
    $handoverUrl = "$baseUrl/?relay_handover=1&msg_id=$msgId"
    if ($modelSlug) {
        $handoverUrl += "&model=$modelSlug"
    }

    $effDefer = [bool]($DeferUntilStopped -and [string]$Session.SessionKey -ne '__new_task__')
    $newItem = [pscustomobject]@{
        id = $msgId
        session_key = [string]$Session.SessionKey
        wfr_id = $wfrId
        conv_uuid = $(if ($Mode -eq 'new_window_handover') { '' } else { $convUuid })
        browser_profile = $browserProf
        project_prefix = $projPrefix
        target_title = $shortTitle
        mode = $Mode
        target_model = $effModel
        reasoning_effort = $effEffort
        handover_url = $handoverUrl
        display_text = $displayText
        prompt = $prompt
        text = $prompt
        status = 'pending'
        defer_until_stopped = $effDefer
        manual_send = $true
        has_user_text = [bool]$CustomUserText.Trim()
        is_auto_wakeup = $false
        created_at = [DateTimeOffset]::UtcNow.ToString('o')
        delivered_at = ''
        delivered_tab_id = ''
    }

    $qList = New-Object 'System.Collections.Generic.List[object]'
    foreach ($existingItem in @($state.queue)) {
        if (-not $existingItem) { continue }
        if ([string]$existingItem.session_key -eq [string]$Session.SessionKey -and [string]$existingItem.status -eq 'pending') {
            $isAutoWake = ($existingItem.PSObject.Properties['is_auto_wakeup'] -and [bool]$existingItem.is_auto_wakeup) -or ([string]$existingItem.mode -eq 'in_place_wakeup')
            $existingHasUserText = ($existingItem.PSObject.Properties['has_user_text'] -and [bool]$existingItem.has_user_text)
            if ($isAutoWake -or ($Mode -eq 'new_window_handover' -and [string]$existingItem.mode -eq 'new_window_handover' -and ($StopAndRetire -or (-not $existingHasUserText)))) {
                $existingItem | Add-Member -NotePropertyName 'status' -NotePropertyValue 'superseded' -Force
            }
        }
        $qList.Add($existingItem)
    }
    $qList.Add($newItem)
    while ($qList.Count -gt 40) { $qList.RemoveAt(0) }
    $state.queue = $qList.ToArray()

    if (-not $state.breakers) {
        $state | Add-Member -NotePropertyName 'breakers' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $fp = "$($Session.SessionKey)|$($Session.CommandCount)|$($Session.ProgressPercent)"
    $nowIso = [DateTimeOffset]::UtcNow.ToString('o')
    $curBreaker = if ($state.breakers -and $state.breakers.PSObject.Properties[$Session.SessionKey]) {
        $state.breakers.$($Session.SessionKey)
    } else { $null }
    $autoEn = if ($curBreaker -and $curBreaker.PSObject.Properties['auto_enabled']) { [bool]$curBreaker.auto_enabled } else { [bool]$autoCfg.Enabled }
    $prevRetries = if ($curBreaker -and $curBreaker.PSObject.Properties['retry_count']) { [int]$curBreaker.retry_count } else { 0 }
    $newRetryCount = if ($Mode -in @('custom_message', 'follow_window')) { $prevRetries } elseif ($Mode -eq 'new_window_handover') { 0 } else { [Math]::Min([int]$autoCfg.MaxRetries, $prevRetries + 1) }

    $newStage = if ($Mode -eq 'new_window_handover') { 'HandoverSent' } else { 'WakeupSent' }
    $statusNote = if ($Mode -eq 'new_window_handover') {
        if ($effDefer) { '已加入待发队列（等原网页本轮停稳后自动换新窗接力）' } else { "已发起新窗口接力交接" }
    } elseif ($Mode -in @('custom_message', 'follow_window')) {
        '已向网页端投递自定义消息（等待网页响应）'
    } else {
        "已自动重发 $newRetryCount/$($autoCfg.MaxRetries) 次"
    }

    $prevHandoverFp = if ($curBreaker -and $curBreaker.PSObject.Properties['handover_fingerprint'] -and $curBreaker.handover_fingerprint) { [string]$curBreaker.handover_fingerprint } else { '' }
    $bObj = [pscustomobject]@{
        session_key = [string]$Session.SessionKey
        fingerprint = $fp
        handover_fingerprint = $(if ($Mode -eq 'new_window_handover') { $fp } else { $prevHandoverFp })
        baseline_command_count = [int]$Session.CommandCount
        stage = $newStage
        retry_count = $newRetryCount
        max_retries = [int]$autoCfg.MaxRetries
        wakeup_sent_at = $(if ($Mode -ne 'new_window_handover') { $nowIso } elseif ($curBreaker -and $curBreaker.PSObject.Properties['wakeup_sent_at']) { [string]$curBreaker.wakeup_sent_at } else { '' })
        handover_sent_at = $(if ($Mode -eq 'new_window_handover') { $nowIso } else { '' })
        tripped_at = ''
        last_message = $statusNote
        auto_enabled = $autoEn
    }
    $state.breakers | Add-Member -NotePropertyName $Session.SessionKey -NotePropertyValue $bObj -Force
    Save-WebBridgeState $Context $state

    if ($Mode -eq 'new_window_handover' -and $OpenBrowserOnHandover -and (-not $effDefer) -and (-not $Context.Isolated)) {
        $hasLiveConnectedTab = $false
        $nowUtc = [DateTimeOffset]::UtcNow
        $targetFam = ($browserProf -split ':')[0]
        if ($state.tabs) {
            foreach ($tp in $state.tabs.PSObject.Properties) {
                $tVal = $tp.Value
                if ($tVal -and $tVal.PSObject.Properties['last_seen_at'] -and $tVal.last_seen_at) {
                    $seenDto = ConvertTo-LocalDateTimeOffset $tVal.last_seen_at $null
                    if ($seenDto -and ($nowUtc.ToLocalTime() - $seenDto).TotalSeconds -le 6.0) {
                        $tProf = if ($tVal.PSObject.Properties['browser_profile'] -and $tVal.browser_profile) { [string]$tVal.browser_profile } else { '' }
                        $tFam = ($tProf -split ':')[0]
                        if ($tFam -eq $targetFam -and (-not $tProf -or $tProf -eq $browserProf)) {
                            $hasLiveConnectedTab = $true
                            break
                        }
                    }
                }
            }
        }
        if (-not $hasLiveConnectedTab) {
            [void](Open-BridgeHandoverWindow -Url $handoverUrl -BrowserProfile $browserProf -Context $Context)
        }
    }
    $offQueueSlice = Build-OfflineSessionQueueSlice -State $state -SessionKey ([string]$Session.SessionKey)
    return [pscustomobject]@{
        MessageId = $msgId
        SessionKey = [string]$Session.SessionKey
        Mode = $Mode
        Prompt = $prompt
        HandoverUrl = $handoverUrl
        BrowserProfile = $browserProf
        TargetModel = $effModel
        ReasoningEffort = $effEffort
        StatusText = $statusNote
        Stage = $newStage
        QueueSlice = $offQueueSlice
        queue_slice = $offQueueSlice
    }
}

function Remove-WebBridgeQueuedMessage {
    param(
        $Context,
        [string]$SessionKey = '',
        [string]$MessageId = '',
        [switch]$CancelAllPending
    )
    $hubResp = Invoke-StudioHubAction -Context $Context -Payload @{
        action = 'delete_queued_message'
        session_key = $SessionKey
        msg_id = $MessageId
        cancel_all_pending = [bool]$CancelAllPending
    }
    if ($hubResp -and $hubResp.ok) {
        return $hubResp
    }
    $state = Get-WebBridgeState $Context
    $deletedCount = 0
    $resolvedSk = $SessionKey
    $nowIso = [DateTimeOffset]::UtcNow.ToString('o')
    foreach ($qi in @($state.queue)) {
        if (-not $qi -or [string]$qi.status -ne 'pending') { continue }
        if ($SessionKey -and [string]$qi.session_key -ne $SessionKey) { continue }
        if ($CancelAllPending -or ($MessageId -and [string]$qi.id -eq $MessageId)) {
            if (-not $resolvedSk -and $qi.PSObject.Properties['session_key'] -and $qi.session_key) {
                $resolvedSk = [string]$qi.session_key
            }
            $qi | Add-Member -NotePropertyName 'status' -NotePropertyValue 'cancelled' -Force
            $qi | Add-Member -NotePropertyName 'cancelled_at' -NotePropertyValue $nowIso -Force
            $deletedCount++
        }
    }
    if ($deletedCount -gt 0) {
        Save-WebBridgeState $Context $state
    }
    $offSlice = if ($resolvedSk) { Build-OfflineSessionQueueSlice -State $state -SessionKey $resolvedSk } else { $null }
    return [pscustomobject]@{
        ok = $true
        action = 'delete_queued_message'
        session_key = $resolvedSk
        msg_id = $MessageId
        changed = ($deletedCount -gt 0)
        deleted_count = $deletedCount
        queue_slice = $offSlice
        QueueSlice = $offSlice
    }
}

function Move-WebBridgeQueuedMessage {
    param(
        $Context,
        [string]$SessionKey = '',
        [Parameter(Mandatory)][string]$MessageId,
        [ValidateSet('up','down')][string]$Direction = 'up'
    )
    $hubResp = Invoke-StudioHubAction -Context $Context -Payload @{
        action = 'move_queued_message'
        session_key = $SessionKey
        msg_id = $MessageId
        direction = $Direction
    }
    if ($hubResp -and $hubResp.ok) {
        return $hubResp
    }
    $state = Get-WebBridgeState $Context
    $qArr = @($state.queue)
    $targetIdx = -1
    for ($idx = 0; $idx -lt $qArr.Count; $idx++) {
        if ($qArr[$idx] -and [string]$qArr[$idx].id -eq $MessageId -and [string]$qArr[$idx].status -eq 'pending') {
            $targetIdx = $idx
            break
        }
    }
    if ($targetIdx -lt 0) {
        $emptySlice = if ($SessionKey) { Build-OfflineSessionQueueSlice -State $state -SessionKey $SessionKey } else { $null }
        return [pscustomobject]@{ ok = $true; action = 'move_queued_message'; session_key = $SessionKey; msg_id = $MessageId; direction = $Direction; changed = $false; queue_slice = $emptySlice; QueueSlice = $emptySlice }
    }
    $effSk = if ($SessionKey) { $SessionKey } else { [string]$qArr[$targetIdx].session_key }
    $pendingIndices = New-Object 'System.Collections.Generic.List[int]'
    for ($idx = 0; $idx -lt $qArr.Count; $idx++) {
        if ($qArr[$idx] -and [string]$qArr[$idx].session_key -eq $effSk -and [string]$qArr[$idx].status -eq 'pending') {
            $pendingIndices.Add($idx)
        }
    }
    $pos = $pendingIndices.IndexOf($targetIdx)
    $changed = $false
    if ($Direction -eq 'up' -and $pos -gt 0) {
        $swapIdx = $pendingIndices[$pos - 1]
        $tmp = $qArr[$targetIdx]
        $qArr[$targetIdx] = $qArr[$swapIdx]
        $qArr[$swapIdx] = $tmp
        $changed = $true
    } elseif ($Direction -eq 'down' -and $pos -ge 0 -and $pos -lt ($pendingIndices.Count - 1)) {
        $swapIdx = $pendingIndices[$pos + 1]
        $tmp = $qArr[$targetIdx]
        $qArr[$targetIdx] = $qArr[$swapIdx]
        $qArr[$swapIdx] = $tmp
        $changed = $true
    }
    if ($changed) {
        $state.queue = $qArr
        Save-WebBridgeState $Context $state
    }
    $offSlice = Build-OfflineSessionQueueSlice -State $state -SessionKey $effSk
    return [pscustomobject]@{
        ok = $true
        action = 'move_queued_message'
        session_key = $effSk
        msg_id = $MessageId
        direction = $Direction
        changed = $changed
        queue_slice = $offSlice
        QueueSlice = $offSlice
    }
}

function Get-AutoResendConfig {
    param($Context)
    $state = Get-WebBridgeState $Context
    $raw = if ($state -and $state.PSObject.Properties['auto_resend_config'] -and $state.auto_resend_config) {
        $state.auto_resend_config
    } else { $null }
    $enabled = if ($raw -and $raw.PSObject.Properties['enabled'] -and $null -ne $raw.enabled) { [bool]$raw.enabled } else { $true }
    $stallMins = if ($raw -and $raw.PSObject.Properties['stall_minutes'] -and [double]$raw.stall_minutes -gt 0) { [double]$raw.stall_minutes } else { 3 }
    $stallSecs = if ($raw -and $raw.PSObject.Properties['stall_seconds'] -and [int]$raw.stall_seconds -gt 0) { [int]$raw.stall_seconds } else { [int][Math]::Round($stallMins * 60) }
    $maxRetries = if ($raw -and $raw.PSObject.Properties['max_retries'] -and [int]$raw.max_retries -ge 1) { [int]$raw.max_retries } else { 1 }
    return [pscustomobject]@{
        Enabled = $enabled
        StallMinutes = $(if ($stallSecs -lt 60) { [Math]::Round($stallSecs / 60.0, 2) } else { [int][Math]::Round($stallSecs / 60.0) })
        StallSeconds = $stallSecs
        MaxRetries = $maxRetries
    }
}

function Set-AutoResendConfig {
    param(
        $Context,
        [bool]$Enabled = $true,
        [int]$StallMinutes = 3,
        [int]$StallSeconds = 0,
        [int]$MaxRetries = 1
    )
    $state = Get-WebBridgeState $Context
    $effSecs = if ($StallSeconds -gt 0) { [Math]::Max(30, [Math]::Min(1800, $StallSeconds)) } else { [Math]::Max(1, [Math]::Min(30, $StallMinutes)) * 60 }
    $effMins = if ($effSecs -lt 60) { [Math]::Round($effSecs / 60.0, 2) } else { [int][Math]::Round($effSecs / 60.0) }
    $cfgObj = [pscustomobject]@{
        enabled = $Enabled
        stall_minutes = $effMins
        stall_seconds = $effSecs
        max_retries = [Math]::Max(1, [Math]::Min(5, $MaxRetries))
        updated_at = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $state | Add-Member -NotePropertyName 'auto_resend_config' -NotePropertyValue $cfgObj -Force
    if ($state.breakers) {
        foreach ($bp in $state.breakers.PSObject.Properties) {
            if ($bp.Value) {
                $bp.Value | Add-Member -NotePropertyName 'auto_enabled' -NotePropertyValue $Enabled -Force
                $bp.Value | Add-Member -NotePropertyName 'max_retries' -NotePropertyValue $cfgObj.max_retries -Force
                if ($Enabled -and $bp.Value.stage -eq 'Tripped') {
                    $bp.Value.stage = 'Idle'
                    $bp.Value | Add-Member -NotePropertyName 'retry_count' -NotePropertyValue 0 -Force
                }
            }
        }
    }
    $hubCfgResp = Invoke-StudioHubAction -Context $Context -Payload @{
        action = 'update_resend_config'
        enabled = $Enabled
        stall_minutes = $cfgObj.stall_minutes
        stall_seconds = $cfgObj.stall_seconds
        max_retries = $cfgObj.max_retries
    }
    if (-not ($hubCfgResp -and $hubCfgResp.ok)) {
        Save-WebBridgeState $Context $state
    }
    return (Get-AutoResendConfig $Context)
}

function Set-SessionAutoWakeup {
    param($Context, [string]$SessionKey, [bool]$Enabled)
    $hubWakeResp = Invoke-StudioHubAction -Context $Context -Payload @{
        action = 'set_auto_wakeup'
        session_key = $SessionKey
        enabled = $Enabled
    }
    if ($hubWakeResp -and $hubWakeResp.ok) { return }
    $curCfg = Get-AutoResendConfig $Context
    if (-not $SessionKey) { return }
    $state = Get-WebBridgeState $Context
    if (-not $state.breakers) {
        $state | Add-Member -NotePropertyName 'breakers' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $cur = if ($state.breakers -and $state.breakers.PSObject.Properties[$SessionKey]) { $state.breakers.$SessionKey } else { $null }
    if ($cur) {
        $cur | Add-Member -NotePropertyName 'auto_enabled' -NotePropertyValue $Enabled -Force
        if ($Enabled -and $cur.stage -eq 'Tripped') {
            $cur.stage = 'Idle'
            $cur.last_message = "自动重发守护已就绪 (>$($curCfg.StallMinutes)分钟静默触发)"
        }
    } else {
        $bObj = [pscustomobject]@{
            session_key = $SessionKey
            fingerprint = ''
            baseline_command_count = 0
            stage = 'Idle'
            retry_count = 0
            max_retries = [int]$curCfg.MaxRetries
            wakeup_sent_at = ''
            handover_sent_at = ''
            tripped_at = ''
            last_message = $(if ($Enabled) { "自动重发守护已就绪 (>$($curCfg.StallMinutes)分钟静默触发)" } else { '自动重发已关闭' })
            auto_enabled = $Enabled
        }
        $state.breakers | Add-Member -NotePropertyName $SessionKey -NotePropertyValue $bObj -Force
    }
    Save-WebBridgeState $Context $state
}

function Get-WindowLayoutMemory {
    param($Context)
    $path = if ($Context.PSObject.Properties.Name -contains 'WindowLayoutPath' -and $Context.WindowLayoutPath) {
        $Context.WindowLayoutPath
    } else {
        Join-Path $Context.DataRoot 'window-layout.json'
    }
    $defaultPanes = @(
        [pscustomobject]@{ id = 101; session_key = ''; width_weight = 54; show_summary = $false }
    )
    $result = [pscustomobject]@{
        WinWidth = 1180
        WinHeight = 700
        RailWidth = 260
        RailCollapsed = $false
        ShowArchived = $true
        ThemeMode = 'system'
        HiddenRightPane = $null
        Panes = $defaultPanes
    }
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($raw) {
                if ($raw.PSObject.Properties.Name -contains 'win_width' -and [double]$raw.win_width -ge 700) {
                    $result.WinWidth = [int][Math]::Min(1920, [Math]::Max(700, [int]$raw.win_width))
                }
                if ($raw.PSObject.Properties.Name -contains 'win_height' -and [double]$raw.win_height -ge 480) {
                    $result.WinHeight = [int][Math]::Min(1200, [Math]::Max(480, [int]$raw.win_height))
                }
                if ($raw.PSObject.Properties.Name -contains 'rail_width' -and [double]$raw.rail_width -ge 150) {
                    $result.RailWidth = [int][Math]::Min(380, [Math]::Max(150, [int]$raw.rail_width))
                }
                if ($raw.PSObject.Properties.Name -contains 'rail_collapsed') {
                    $result.RailCollapsed = [bool]$raw.rail_collapsed
                }
                if ($raw.PSObject.Properties.Name -contains 'show_archived') {
                    $result.ShowArchived = [bool]$raw.show_archived
                }
                if ($raw.PSObject.Properties.Name -contains 'theme_mode' -and $raw.theme_mode) {
                    $result.ThemeMode = Resolve-NormalizedThemeMode ([string]$raw.theme_mode)
                }
                if ($raw.PSObject.Properties.Name -contains 'hidden_right_pane' -and $raw.hidden_right_pane) {
                    $hp = $raw.hidden_right_pane
                    $result.HiddenRightPane = [pscustomobject]@{
                        id = if ($hp.id) { [int]$hp.id } else { 199 }
                        session_key = if ($hp.session_key) { [string]$hp.session_key } else { '' }
                        width_weight = if ($hp.width_weight) { [double]$hp.width_weight } else { 38 }
                        show_summary = [bool]$hp.show_summary
                    }
                }
                if ($raw.PSObject.Properties.Name -contains 'panes' -and @($raw.panes).Count -gt 0) {
                    $seenIds = @{}
                    $maxId = 100
                    $loadedPanes = New-Object 'System.Collections.Generic.List[object]'
                    foreach ($p in @($raw.panes | Select-Object -First 4)) {
                        $sKey = if ($p.session_key) { [string]$p.session_key } else { '' }
                        $candId = if ($p.id) { [int]$p.id } else { $maxId + 1 }
                        if ($seenIds.ContainsKey($candId)) {
                            $candId = $maxId + 1
                        }
                        $seenIds[$candId] = $true
                        if ($candId -gt $maxId) { $maxId = $candId }
                        $loadedPanes.Add([pscustomobject]@{
                            id = $candId
                            session_key = $sKey
                            width_weight = if ($p.width_weight -and [double]$p.width_weight -gt 5) { [double]$p.width_weight } else { 50 }
                            show_summary = [bool]$p.show_summary
                        })
                    }
                    if ($loadedPanes.Count -gt 0) { $result.Panes = $loadedPanes.ToArray() }
                }
            }
        } catch { }
    }
    return $result
}

function Save-WindowLayoutMemory {
    param($Context, $Layout)
    if (-not $Layout) { return }
    $path = if ($Context.PSObject.Properties.Name -contains 'WindowLayoutPath' -and $Context.WindowLayoutPath) {
        $Context.WindowLayoutPath
    } else {
        Join-Path $Context.DataRoot 'window-layout.json'
    }
    $panesPayload = @(foreach ($p in @($Layout.Panes | Select-Object -First 4)) {
        [pscustomobject]@{
            id = [int]$p.id
            session_key = [string]$p.session_key
            width_weight = [Math]::Round([double]$p.width_weight, 1)
            show_summary = [bool]$p.show_summary
        }
    })
    $hiddenPayload = $null
    if ($Layout.PSObject.Properties.Name -contains 'HiddenRightPane' -and $Layout.HiddenRightPane) {
        $hp = $Layout.HiddenRightPane
        $hiddenPayload = [pscustomobject]@{
            id = [int]$hp.id
            session_key = [string]$hp.session_key
            width_weight = [Math]::Round([double]$hp.width_weight, 1)
            show_summary = [bool]$hp.show_summary
        }
    }
    $themeModeVal = if ($Layout.PSObject.Properties.Name -contains 'ThemeMode') {
        Resolve-NormalizedThemeMode ([string]$Layout.ThemeMode)
    } else {
        'system'
    }
    $payload = [pscustomobject]@{
        schema_version = 1
        win_width = [int][Math]::Round([double]$Layout.WinWidth)
        win_height = [int][Math]::Round([double]$Layout.WinHeight)
        rail_width = [int][Math]::Round([double]$Layout.RailWidth)
        rail_collapsed = [bool]$Layout.RailCollapsed
        show_archived = [bool]$Layout.ShowArchived
        theme_mode = $themeModeVal
        hidden_right_pane = $hiddenPayload
        panes = $panesPayload
    } | ConvertTo-Json -Depth 6
    Write-AtomicConnectionText $path $payload
}

function Reset-WindowLayoutMemory {
    param($Context)
    $prevTheme = (Get-WindowLayoutMemory $Context).ThemeMode
    $path = if ($Context.PSObject.Properties.Name -contains 'WindowLayoutPath' -and $Context.WindowLayoutPath) {
        $Context.WindowLayoutPath
    } else {
        Join-Path $Context.DataRoot 'window-layout.json'
    }
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    $fresh = Get-WindowLayoutMemory $Context
    $fresh.ThemeMode = Resolve-NormalizedThemeMode ([string]$prevTheme)
    Save-WindowLayoutMemory -Context $Context -Layout $fresh
    return $fresh
}

function ConvertTo-CleanGoalSubtitle {
    param([string]$Goal, [string]$LatestSummary = '')
    if (-not $Goal) { return '通过 OpenAI 隧道转发本机 MCP 工具指令' }
    $clean = $Goal.Trim()
    # Strip raw Windows paths, repo relative paths, and hex SHAs so the subtitle stays calm and readable
    $clean = [regex]::Replace($clean, '[A-Za-z]:\\[^\s，。；、）)]+', '')
    $clean = [regex]::Replace($clean, '(?<![A-Za-z0-9_-])(?:docs|src|tests|worktree|control)[\\/][^\s，。；、）)]+', '')
    $clean = [regex]::Replace($clean, '候选\s*[0-9a-f]{7,40}\s*干净[，、\s]*', '')
    $clean = [regex]::Replace($clean, '(?<![A-Za-z0-9_])(?:SHA)?[0-9a-f]{7,40}(?![A-Za-z0-9_])', '')
    $clean = [regex]::Replace($clean, '(?<![A-Za-z0-9_-])worktree(?![A-Za-z0-9_-])', '独立工作树')
    $clean = [regex]::Replace($clean, '(?<![A-Za-z0-9_-])spec(?![A-Za-z0-9_-])', '设计规范')
    $clean = [regex]::Replace($clean, '(?<![A-Za-z0-9_-])integration(?![A-Za-z0-9_-])', '集成')
    $clean = [regex]::Replace($clean, '\s{2,}', ' ').Trim()
    $clean = $clean -replace '在独立\s*独立工作树\s*中', '于独立工作树'
    $clean = $clean -replace '按\s*顺序', '按计划顺序'
    $clean = $clean -replace '集成\s*开发与集成', '集成开发与'
    $clean = [regex]::Replace($clean, '(?<=[\u4e00-\u9fa5])\s+(?=[\u4e00-\u9fa5])', '')
    $clean = $clean.Trim('，', '。', '；', '、', ' ')
    $firstSentence = ($clean -split '[。；\r\n]')[0].Trim()
    if ($firstSentence.Length -gt 56) {
        $clauses = @($firstSentence -split '，' | Where-Object { $_.Trim().Length -gt 0 })
        if ($clauses.Count -ge 2) {
            $short = ($clauses[0..1] -join '，')
            if ($short.Length -gt 56) { $short = $short.Substring(0, 54) + '…' }
            return $short
        }
        return ($firstSentence.Substring(0, 54) + '…')
    }
    return $firstSentence
}

function ConvertTo-ReadableMilestone {
    param(
        [Alias('RawSummary')][string]$Summary,
        [Alias('Timestamp')][string]$TimeText = '',
        $Steps = @(),
        [string]$LatestAction = ''
    )
    if (-not $Summary) {
        return [pscustomobject]@{
            Title = '阶段进展已更新'
            TimeText = $TimeText
            Prose = '已记录最新阶段检查点。'
            TraceText = ''
            RawText = ''
            IsSuccess = $true
        }
    }
    $raw = $Summary.Trim()
    $techPart = $raw
    $body = $raw
    if ($raw -match '^(.*?)\s*\|\|\s*(.+)$') {
        $body = $matches[1].Trim()
        $techPart = $matches[2].Trim()
    }

    $stepId = ''
    if ($body -match '^completed=\[([^\]]*)\],\s*current=([^:：]+)[:：]\s*(.+)$') {
        $stepId = $matches[2].Trim()
        $body = $matches[3].Trim()
    } elseif ($body -match '^([a-zA-Z0-9_-]+)=(?:in_progress|completed|pending|done|blocked|failed)[:：]\s*(.+)$') {
        $stepId = $matches[1].Trim()
        $body = $matches[2].Trim()
    }
    if ($body -match '^(?:pass|done|completed|in_progress|step\s*\d+)[:：]\s*(.+)$') {
        $body = $matches[1].Trim()
    }

    # Build a crisp, distinct 1-line headline + 2-sentence plain-Chinese prose based on key milestone patterns
    $headline = ''
    $traceLine = ''

    if ($body -match '汇总诊断及有界后续提案已交付|已完整读取.*策略交接并落实诊断优先') {
        $headline = '已完成测试策略诊断报告并同步后续方案'
        $distilledProse = '已按最新测试策略完成只读诊断，期间未改动业务代码或发起新测试批次；汇总诊断报告与分步收敛方案已生成并同步至 GitHub。'
    } elseif ($body -match '最新策略交接.*转只读诊断与重新排期方案|切换到只读诊断与测试策略设计模式') {
        $headline = '切换为只读诊断模式并重排验证计划'
        $distilledProse = '已读取最新测试策略交接文档，暂停自动打补丁与整批跑测，转为只读诊断与最小闭环方案梳理，既有工作区文件保持完好。'
    } elseif ($body -match 'shared-gc-green-\d+\s*(\d+)/(\d+)\s*ACCEPTED' -and $body -match 'layout-navigation-green-\d+\s*(\d+)=(\d+)P(\d+)F') {
        $headline = '资源回收 99 项全过，页面导航 12/17 项通过'
        $distilledProse = '共享资源回收 99/99 项测试全部通过；页面布局与导航 17 项中 12 项通过，剩余 5 项旧测试夹具正在独立分支补齐。'
    } elseif ($body -match '此前95关联ACCEPTED' -and $body -match '前端23项22绿') {
        $headline = '后端 95 项关联验证通过，前端布局完成修复'
        $distilledProse = '此前 95 项后端关联验证已通过，前端 23 项中 22 项通过；正按单槽串行规则依次运行 Python 与前端回归测试。'
    } elseif ($body -match '117既有关键门禁及本轮来源96关联已通过') {
        $headline = '117 项关键门禁与 96 项关联验证已通过'
        $distilledProse = '既有 117 项核心门禁与本轮 96 项关联测试均已通过；前端 12 项验证中 8 项通过，剩余冲突提示细节正在隔离分支修复。'
    } elseif ($body -match '改为只读架构诊断，不继续编码或启动测试') {
        $headline = '启动前后端契约与失败证据只读架构诊断'
        $distilledProse = '按最新要求暂停编码与跑测，集中核对前后端数据契约与失败证据，梳理后端优先的最小业务闭环方案。'
    } else {
        # General fallback translator for any other unseparated checkpoint string
        $readable = $body
        $readable = [regex]::Replace($readable, 'https?://[^\s，。；、）)]+', '')
        $readable = [regex]::Replace($readable, '[A-Za-z]:\\[^\s，。；、）)]+', '本地交接文档')
        $readable = [regex]::Replace($readable, '(?<![A-Za-z0-9_-])(?:docs|src|tests|worktree|control)[\\/][^\s，。；、）)]+', '本地报告')
        $readable = [regex]::Replace($readable, '[A-Za-z0-9_.-]+\.(?:md|json|py|ts|js|ps1)', '')
        $readable = [regex]::Replace($readable, 'shared-gc-green-\d+\s*(\d+)/(\d+)\s*ACCEPTED', '资源回收 $1/$2 项通过')
        $readable = [regex]::Replace($readable, 'layout-navigation-green-\d+\s*(\d+)=(\d+)P(\d+)F', '页面导航 $1 项中 $2 项通过')
        $readable = [regex]::Replace($readable, '(?<![A-Za-z0-9_])(?:SHA)?[0-9a-f]{7,40}(?![A-Za-z0-9_])', '')
        $readable = [regex]::Replace($readable, '\+[a-z]+\d+[a-f0-9]+', '')
        $readable = [regex]::Replace($readable, 'session-[0-9a-f-]*', '单槽测试队列')
        $readable = [regex]::Replace($readable, '(?<![A-Za-z0-9_])c4-[a-z0-9-]+(?![A-Za-z0-9_])', '独立分支')
        $readable = [regex]::Replace($readable, '(?<![A-Za-z0-9_])r(\d+)(?![A-Za-z0-9_])', '第 $1 轮')
        $readable = [regex]::Replace($readable, '(\d+)/(\d+)\s*(?:pass|绿|ACCEPTED)', '$1/$2 项通过')
        $readable = [regex]::Replace($readable, '(\d+)=(\d+)P(\d+)F', '$1 项中 $2 项通过、$3 项待修')
        $readable = [regex]::Replace($readable, '(\d+)P(\d+)F', '$1 项通过、$2 项待修')
        $readable = $readable -replace '0skip/(?:unknown|cancel)/(?:notexecuted/)?(?:residual|残留)', '无跳过或残留项'
        $readable = $readable -replace 'native启动|原生启动', '原生进程启动'
        $readable = $readable -replace 'Spec/Standards|Standards/Spec|Standards\+Spec|双审', '代码规范与规格审查'
        $readable = $readable -replace 'ACCEPTED', '已通过'
        $readable = $readable -replace 'REJECTED', '已退回重测'
        $readable = $readable -replace '全部绿|全绿|已真绿|全部转绿|目标绿', '全部验证通过'
        $readable = $readable -replace '真红|仍红', '待修复'
        $readable = [regex]::Replace($readable, '\([^\)]{12,}\)', '')
        $readable = [regex]::Replace($readable, '（[^）]{14,}）', '')
        $readable = [regex]::Replace($readable, '\s{2,}', ' ').Trim()

        $sentences = @(
            ($readable -split '[。；\r\n]') |
            ForEach-Object { $_.Trim() } |
            Where-Object {
                $_.Length -gt 4 -and
                $_ -notmatch '^(?:integration|主线|恢复候选|原WIP|用户两笔记|两笔记|20未|21未|无push|现场)'
            }
        )
        $distilledProse = if ($sentences.Count -ge 2) {
            "$($sentences[0])；$($sentences[1])。"
        } elseif ($sentences.Count -eq 1) {
            "$($sentences[0])。"
        } else {
            $readable
        }
        if ($distilledProse.Length -gt 92) {
            $distilledProse = $distilledProse.Substring(0, 89).TrimEnd('，', '、', '；', '。', ' ') + '…'
        }

        $firstClause = ($distilledProse -split '[，。；：]')[0].Trim()
        if ($firstClause.Length -ge 6 -and $firstClause.Length -le 22) {
            $headline = $firstClause
        } elseif ($firstClause.Length -gt 22) {
            $headline = $firstClause.Substring(0, 21) + '…'
        } else {
            $headline = '阶段验证进展更新'
        }
    }

    return [pscustomobject]@{
        Title = $headline
        TimeText = $TimeText
        Prose = $distilledProse
        TraceText = $traceLine
        RawText = $techPart
        IsSuccess = ($raw -notmatch '失败|阻塞|仍红|1fail|[1-9]F')
    }
}

function Get-SessionAliases {
    param($Context)
    $result = @{}
    $path = if ($Context.PSObject.Properties.Name -contains 'SessionAliasesPath' -and $Context.SessionAliasesPath) { $Context.SessionAliasesPath } else { Join-Path $Context.DataRoot 'session-aliases.json' }
    if (Test-Path -LiteralPath $path) {
        try {
            $obj = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($obj -and $obj.PSObject.Properties.Name -contains 'aliases' -and $obj.aliases) {
                foreach ($p in $obj.aliases.PSObject.Properties) {
                    if ($p.Value) { $result[$p.Name] = [string]$p.Value }
                }
            }
        } catch { }
    }
    return $result
}

function Set-SessionAlias {
    param($Context, [string]$SessionKey, [string]$Title)
    if (-not $SessionKey) { return }
    $clean = if ($null -ne $Title) { $Title.Trim() } else { '' }
    $hubResp = Invoke-StudioHubAction -Context $Context -Payload @{ action = 'set_alias'; session_key = $SessionKey; title = $clean }
    if ($hubResp -and $hubResp.ok) { return }
    $path = if ($Context.PSObject.Properties.Name -contains 'SessionAliasesPath' -and $Context.SessionAliasesPath) { $Context.SessionAliasesPath } else { Join-Path $Context.DataRoot 'session-aliases.json' }
    $aliases = Get-SessionAliases $Context
    if ($clean.Length -gt 0) {
        $aliases[$SessionKey] = $clean
    } else {
        [void]$aliases.Remove($SessionKey)
    }
    $ordered = [ordered]@{}
    foreach ($k in ($aliases.Keys | Sort-Object)) { $ordered[$k] = $aliases[$k] }
    $payload = [pscustomobject]@{ schema_version = 1; aliases = [pscustomobject]$ordered } | ConvertTo-Json -Depth 4
    Write-AtomicConnectionText $path $payload
}

function ConvertTo-LocalDateTimeOffset {
    param($Value, $Fallback = $null)
    if ($null -eq $Value) { return $Fallback }
    try {
        if ($Value -is [DateTimeOffset]) { return $Value.ToLocalTime() }
        if ($Value -is [DateTime]) {
            if ($Value.Kind -eq [DateTimeKind]::Utc) {
                return ([DateTimeOffset]::new($Value, [TimeSpan]::Zero)).ToLocalTime()
            }
            return ([DateTimeOffset]$Value).ToLocalTime()
        }
        $s = [string]$Value
        if (-not $s.Trim()) { return $Fallback }
        return ([DateTimeOffset]::Parse($s, [Globalization.CultureInfo]::InvariantCulture)).ToLocalTime()
    } catch {
        return $Fallback
    }
}

function Get-RelayTasks {
    param($Context, $Settings = $null)
    $tasksDir = ''
    if ($Context.PSObject.Properties.Name -contains 'TasksRoot' -and $Context.TasksRoot) {
        $tasksDir = $Context.TasksRoot
    } elseif (-not $Context.Isolated -and $Settings -and ($Settings.PSObject.Properties.Name -contains 'runtime_root') -and $Settings.runtime_root) {
        foreach ($cand in @(
            (Join-Path $Settings.runtime_root 'engine-data\tasks'),
            (Join-Path $Settings.runtime_root 'data\tasks'),
            $(if ($PSScriptRoot) { Join-Path $PSScriptRoot 'engine-data\tasks' } else { '' })
        )) {
            if ($cand -and (Test-Path -LiteralPath $cand)) { $tasksDir = $cand; break }
        }
    }
    if (-not $tasksDir -or -not (Test-Path -LiteralPath $tasksDir)) { return @() }
    $tasks = @(foreach ($file in @(Get-ChildItem -LiteralPath $tasksDir -Filter 'tsk_*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10)) {
        try {
            $raw = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $created = ConvertTo-LocalDateTimeOffset $raw.created_at ([DateTimeOffset]$file.CreationTime)
            $updated = ConvertTo-LocalDateTimeOffset $raw.updated_at ([DateTimeOffset]$file.LastWriteTime)
            $stepText = ''
            $stepItems = @()
            $completedSteps = 0
            $totalSteps = 0
            if ($raw.PSObject.Properties.Name -contains 'steps' -and $raw.steps) {
                $rawSteps = @($raw.steps)
                $totalSteps = $rawSteps.Count
                $inProg = @($rawSteps | Where-Object { $_.status -eq 'in_progress' })
                $chosen = if ($inProg.Count -gt 0) { $inProg[0] } else { @($rawSteps | Where-Object { $_.status -in @('completed', 'quarantined') }) | Select-Object -Last 1 }
                if ($chosen) { $stepText = "步骤 $($chosen.id)：$($chosen.title)" }
                $stepItems = @(foreach ($st in $rawSteps) {
                    $stStatus = [string]$st.status
                    if ($stStatus -in @('completed', 'quarantined')) { $completedSteps++ }
                    $stUpdated = ''
                    if ($st.PSObject.Properties.Name -contains 'updated_at' -and $st.updated_at) {
                        $dtSt = ConvertTo-LocalDateTimeOffset $st.updated_at $null
                        if ($dtSt) { $stUpdated = $dtSt.ToString('HH:mm:ss') }
                    }
                    $label = if ($stStatus -eq 'completed') { '✔ 已完成' } elseif ($stStatus -eq 'quarantined') { '⊘ 已隔离' } elseif ($stStatus -eq 'in_progress') { '▶ 正在执行' } else { '○ 排队待命' }
                    $bg = if ($stStatus -eq 'completed') { '#DCFCE7' } elseif ($stStatus -eq 'quarantined') { '#FEF3C7' } elseif ($stStatus -eq 'in_progress') { '#DBEAFE' } else { '#F4F4F5' }
                    $fg = if ($stStatus -eq 'completed') { '#166534' } elseif ($stStatus -eq 'quarantined') { '#92400E' } elseif ($stStatus -eq 'in_progress') { '#1E40AF' } else { '#71717A' }
                    [pscustomobject]@{
                        Id = [string]$st.id
                        Title = [string]$st.title
                        Status = $stStatus
                        StatusLabel = $label
                        BadgeBg = $bg
                        BadgeFg = $fg
                        UpdatedText = $stUpdated
                    }
                })
            }
            $progressPct = if ($totalSteps -gt 0) { [int][Math]::Round(($completedSteps * 100.0) / $totalSteps) } else { 0 }
            $goalText = if ($raw.PSObject.Properties.Name -contains 'goal' -and $raw.goal) { [string]$raw.goal } else { '' }
            $phaseText = if ($raw.PSObject.Properties.Name -contains 'phase' -and $raw.phase) { [string]$raw.phase } else { '' }
            $summaryText = if ($raw.PSObject.Properties.Name -contains 'summary' -and $raw.summary) { [string]$raw.summary } else { '' }
            $condList = @(if ($raw.PSObject.Properties.Name -contains 'conditions' -and $raw.conditions) {
                foreach ($c in @($raw.conditions)) { if ($c.text) { [string]$c.text } }
            })
            $ckptList = @(if ($raw.PSObject.Properties.Name -contains 'events' -and $raw.events) {
                $evArr = @($raw.events | Where-Object { $_.type -eq 'checkpoint' })
                [Array]::Reverse($evArr)
                foreach ($ev in ($evArr | Select-Object -First 6)) {
                    $evTime = ''
                    if ($ev.created_at) {
                        $dtEv = ConvertTo-LocalDateTimeOffset $ev.created_at $null
                        if ($dtEv) { $evTime = $dtEv.ToString('HH:mm:ss') }
                    }
                    [pscustomobject]@{
                        TimeText = $evTime
                        Summary = [string]$ev.summary
                    }
                }
            })
            [pscustomobject]@{
                TaskId = [string]$raw.id
                Title = [string]$raw.title
                Goal = $goalText
                Phase = $phaseText
                Status = [string]$raw.status
                CreatedAt = $created
                UpdatedAt = $updated
                CurrentStep = $stepText
                Summary = $summaryText
                Steps = $stepItems
                CompletedStepCount = $completedSteps
                TotalStepCount = $totalSteps
                ProgressPercent = $progressPct
                Conditions = $condList
                Checkpoints = $ckptList
            }
        } catch { }
    })
    return @($tasks | Sort-Object { if ($_.UpdatedAt) { $_.UpdatedAt } else { [DateTimeOffset]::MinValue } } -Descending)
}

function Get-WorkspaceRecentCommits {
    param($Context)
    if ($Context.Isolated) { return @() }
    $candidates = @()
    if ($PSScriptRoot) { $candidates += (Join-Path $PSScriptRoot '.git\logs\HEAD') }
    try {
        $s = Read-ConnectionSettings $Context
        if ($s -and $s.PSObject.Properties['workspace_roots'] -and $s.workspace_roots) {
            foreach ($wr in @($s.workspace_roots)) {
                if ($wr) { $candidates += (Join-Path ([string]$wr) '.git\logs\HEAD') }
            }
        }
    } catch {}
    foreach ($reflogPath in $candidates) {
        if (-not (Test-Path -LiteralPath $reflogPath)) { continue }
        try {
            $fs = [IO.FileStream]::new($reflogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                $sr = [IO.StreamReader]::new($fs, [Text.Encoding]::UTF8)
                $text = $sr.ReadToEnd()
            } finally {
                $fs.Dispose()
            }
            $lines = @($text -split "\r?\n" | Where-Object { $_ -match '\tcommit:' })
            if ($lines.Count -eq 0) { continue }
            [Array]::Reverse($lines)
            $now = [DateTimeOffset]::Now
            $commits = @(foreach ($l in ($lines | Select-Object -First 4)) {
                if ($l -match '^[0-9a-f]{40}\s+([0-9a-f]{40})\s+.*?\s+(\d+)\s+([+-]\d{4})\tcommit:\s*(.+)$') {
                    $sha = $matches[1].Substring(0, 7)
                    $epoch = [long]$matches[2]
                    $msg = $matches[4].Trim()
                    $dt = [DateTimeOffset]::FromUnixTimeSeconds($epoch).ToLocalTime()
                    $agoMin = [Math]::Max(0, [int][Math]::Floor(($now - $dt).TotalMinutes))
                    $agoStr = if ($agoMin -le 1) { '刚刚' } elseif ($agoMin -lt 60) { "${agoMin}分钟前" } else { "$([int][Math]::Floor($agoMin/60))小时前" }
                    [pscustomobject]@{
                        Sha = $sha
                        TimeText = $dt.ToString('HH:mm:ss')
                        AgoText = $agoStr
                        Message = $msg
                    }
                }
            })
            return @($commits)
        } catch { }
    }
    return @()
}

function Read-ShieldActivityMap {
    param($Context)
    $map = @{}
    $actPath = Join-Path (Join-Path $Context.DataRoot 'logs') 'shield-activity.json'
    if (Test-Path -LiteralPath $actPath) {
        try {
            $raw = [IO.File]::ReadAllText($actPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($raw -and $raw.PSObject.Properties.Name -contains 'calls' -and $raw.calls) {
                foreach ($p in $raw.calls.PSObject.Properties) {
                    $map[$p.Name] = $p.Value
                }
            }
            if ($raw -and $raw.PSObject.Properties.Name -contains 'zero_rpc_events' -and $raw.zero_rpc_events) {
                $map['__zero_rpc_events__'] = @($raw.zero_rpc_events)
            }
            if ($raw -and $raw.PSObject.Properties.Name -contains 'in_flight_count') {
                $map['__in_flight_count__'] = [int]$raw.in_flight_count
            }
        } catch { }
    }
    return $map
}

function New-PulseResult {
    param(
        [string]$Session,
        [string]$SessionColor = '#505D70',
        [bool]$IsFault = $false,
        [int]$RecentMinuteCount = 0,
        [int]$CommandCount = 0,
        $Sessions = @(),
        $ArchivedSessions = @(),
        [int]$HiddenIdleCount = 0,
        [int]$SubagentCallCount = 0,
        $NonTaskHeartbeat = $null,
        $AvailableModels = @()
    )
    return [pscustomobject]@{
        Session = $Session
        SessionColor = $SessionColor
        IsFault = $IsFault
        RecentMinuteCount = $RecentMinuteCount
        CommandCount = $CommandCount
        Sessions = @($Sessions)
        ArchivedSessions = @($ArchivedSessions)
        HiddenIdleCount = $HiddenIdleCount
        SubagentCallCount = $SubagentCallCount
        NonTaskHeartbeat = $NonTaskHeartbeat
        AvailableModels = @($AvailableModels)
    }
}

function Add-TaskComposerMetadataToSession {
    param($SessionObj, $BridgeState, $AutoCfg)
    if (-not $SessionObj) { return }
    $sk = [string]$SessionObj.SessionKey
    $bEntry = if ($BridgeState -and $BridgeState.session_bindings -and $BridgeState.session_bindings.PSObject.Properties[$sk]) {
        $BridgeState.session_bindings.$sk
    } elseif ($BridgeState -and $BridgeState.session_bindings -and $BridgeState.session_bindings.PSObject.Properties['__new_task__']) {
        $BridgeState.session_bindings.__new_task__
    } else { $null }
    $rawMode = if ($bEntry -and $bEntry.PSObject.Properties['target_mode'] -and $bEntry.target_mode) { [string]$bEntry.target_mode } else { 'follow_window' }
    $tMode = if ($rawMode -eq 'new_window') { 'new_window' } else { 'follow_window' }
    $bProf = if ($bEntry -and $bEntry.PSObject.Properties['browser_profile'] -and $bEntry.browser_profile) { Resolve-RelayBrowserProfile ([string]$bEntry.browser_profile) } else { Resolve-RelayBrowserProfile '' }
    $uLocked = if ($bEntry -and $bEntry.PSObject.Properties['user_locked_browser']) { [bool]$bEntry.user_locked_browser } else { $false }
    $tModel = if ($bEntry -and $bEntry.PSObject.Properties['target_model'] -and $bEntry.target_model) { [string]$bEntry.target_model } else { 'inherit' }
    $rEffort = if ($bEntry -and $bEntry.PSObject.Properties['reasoning_effort'] -and $bEntry.reasoning_effort) { [string]$bEntry.reasoning_effort } else { 'inherit' }
    $sMins = if ($bEntry -and $bEntry.PSObject.Properties['stall_minutes'] -and [double]$bEntry.stall_minutes -gt 0) { [double]$bEntry.stall_minutes } elseif ($SessionObj.PSObject.Properties['StallMinutes'] -and [double]$SessionObj.StallMinutes -gt 0) { [double]$SessionObj.StallMinutes } else { 3 }
    $sSecs = if ($bEntry -and $bEntry.PSObject.Properties['stall_seconds'] -and [int]$bEntry.stall_seconds -gt 0) { [int]$bEntry.stall_seconds } elseif ($SessionObj.PSObject.Properties['StallSeconds'] -and [int]$SessionObj.StallSeconds -gt 0) { [int]$SessionObj.StallSeconds } else { [int][Math]::Round([double]$sMins * 60) }
    $mRetries = if ($bEntry -and $bEntry.PSObject.Properties['max_retries'] -and [int]$bEntry.max_retries -gt 0) { [int]$bEntry.max_retries } elseif ($SessionObj.PSObject.Properties['MaxRetries'] -and [int]$SessionObj.MaxRetries -gt 0) { [int]$SessionObj.MaxRetries } else { 1 }
    $aEnabled = if ($bEntry -and $bEntry.PSObject.Properties['auto_resend_enabled'] -and $null -ne $bEntry.auto_resend_enabled) { [bool]$bEntry.auto_resend_enabled } elseif ($SessionObj.PSObject.Properties['AutoWakeupEnabled']) { [bool]$SessionObj.AutoWakeupEnabled } else { $true }

    $webModel = ''
    $webEffort = ''
    if ($BridgeState -and $BridgeState.tabs) {
        $convUuid = if ($bEntry -and $bEntry.PSObject.Properties['conv_uuid'] -and $bEntry.conv_uuid) { [string]$bEntry.conv_uuid } else { '' }
        foreach ($tp in $BridgeState.tabs.PSObject.Properties) {
            $tv = $tp.Value
            if (-not $tv) { continue }
            if ($convUuid -and $tv.PSObject.Properties['conv_uuid'] -and [string]$tv.conv_uuid -eq $convUuid) {
                if ($tv.PSObject.Properties['current_model'] -and $tv.current_model) { $webModel = [string]$tv.current_model }
                if ($tv.PSObject.Properties['current_effort'] -and $tv.current_effort) { $webEffort = [string]$tv.current_effort }
                break
            }
        }
        if (-not $webModel -and $bProf) {
            foreach ($tp in $BridgeState.tabs.PSObject.Properties) {
                $tv = $tp.Value
                if ($tv -and $tv.PSObject.Properties['browser_profile'] -and [string]$tv.browser_profile -eq $bProf -and $tv.PSObject.Properties['current_model'] -and $tv.current_model) {
                    $webModel = [string]$tv.current_model
                    if (-not $webEffort -and $tv.PSObject.Properties['current_effort'] -and $tv.current_effort) {
                        $webEffort = [string]$tv.current_effort
                    }
                    break
                }
            }
        }
        if (-not $webModel) {
            foreach ($tp in $BridgeState.tabs.PSObject.Properties) {
                $tv = $tp.Value
                if ($tv -and $tv.PSObject.Properties['current_model'] -and $tv.current_model) {
                    $webModel = [string]$tv.current_model
                    if (-not $webEffort -and $tv.PSObject.Properties['current_effort'] -and $tv.current_effort) {
                        $webEffort = [string]$tv.current_effort
                    }
                    break
                }
            }
        }
    }
    $profAvailModels = @(if ($bProf -and $BridgeState -and $BridgeState.PSObject.Properties['available_models_by_profile'] -and $BridgeState.available_models_by_profile -and $BridgeState.available_models_by_profile.PSObject.Properties[$bProf]) { $BridgeState.available_models_by_profile.$bProf })
    $availModels = @(if ($profAvailModels.Count -gt 0) { $profAvailModels } elseif ($BridgeState -and $BridgeState.PSObject.Properties['available_models'] -and $BridgeState.available_models) { $BridgeState.available_models })

    $SessionObj | Add-Member -NotePropertyName 'TargetMode' -NotePropertyValue $tMode -Force
    $SessionObj | Add-Member -NotePropertyName 'BrowserProfile' -NotePropertyValue $bProf -Force
    $SessionObj | Add-Member -NotePropertyName 'UserLockedBrowser' -NotePropertyValue $uLocked -Force
    $SessionObj | Add-Member -NotePropertyName 'TargetModel' -NotePropertyValue $tModel -Force
    $SessionObj | Add-Member -NotePropertyName 'ReasoningEffort' -NotePropertyValue $rEffort -Force
    $SessionObj | Add-Member -NotePropertyName 'WebCurrentModel' -NotePropertyValue $webModel -Force
    $SessionObj | Add-Member -NotePropertyName 'WebCurrentEffort' -NotePropertyValue $webEffort -Force
    $SessionObj | Add-Member -NotePropertyName 'AvailableModels' -NotePropertyValue $availModels -Force
    $SessionObj | Add-Member -NotePropertyName 'AutoWakeupEnabled' -NotePropertyValue $aEnabled -Force
    $SessionObj | Add-Member -NotePropertyName 'AutoResendEnabled' -NotePropertyValue $aEnabled -Force
    $SessionObj | Add-Member -NotePropertyName 'StallMinutes' -NotePropertyValue $(if ($sSecs -lt 60) { [Math]::Round($sSecs / 60.0, 2) } else { [int][Math]::Round($sSecs / 60.0) }) -Force
    $SessionObj | Add-Member -NotePropertyName 'StallSeconds' -NotePropertyValue $sSecs -Force
    $SessionObj | Add-Member -NotePropertyName 'MaxRetries' -NotePropertyValue $mRetries -Force

    $existingSent = @(if ($SessionObj.PSObject.Properties['SentWebMessages'] -and $SessionObj.SentWebMessages) { $SessionObj.SentWebMessages })
    if ($existingSent.Count -eq 0 -and $BridgeState -and $BridgeState.PSObject.Properties['queue'] -and $BridgeState.queue) {
        $pendingOnly = @(foreach ($qItem in @($BridgeState.queue | Where-Object { $_ -and $_.session_key -eq $sk -and $_.status -eq 'pending' })) {
            $dtQ = ConvertTo-LocalDateTimeOffset $qItem.created_at $null
            $tStr = if ($dtQ) { $dtQ.ToString('MM-dd HH:mm:ss') } else { '刚刚' }
            $dTxt = if ($qItem.PSObject.Properties['display_text'] -and $qItem.display_text) { [string]$qItem.display_text } else { [string]$qItem.prompt }
            [pscustomobject]@{
                Id = $(if ($qItem.PSObject.Properties['id']) { [string]$qItem.id } else { '' })
                TimeText = $tStr
                Text = $dTxt
                Prompt = [string]$qItem.prompt
                Status = [string]$qItem.status
                Mode = [string]$qItem.mode
                DeferUntilStopped = [bool]($qItem.PSObject.Properties['defer_until_stopped'] -and $qItem.defer_until_stopped)
            }
        })
        $rawMsgs = @(foreach ($qItem in @($BridgeState.queue | Where-Object { $_ -and $_.session_key -eq $sk -and $_.status -notin @('superseded', 'cancelled') })) {
            $dtQ = ConvertTo-LocalDateTimeOffset $qItem.created_at $null
            $tStr = if ($dtQ) { $dtQ.ToString('MM-dd HH:mm:ss') } else { '刚刚' }
            $dTxt = if ($qItem.PSObject.Properties['display_text'] -and $qItem.display_text) { [string]$qItem.display_text } else { [string]$qItem.prompt }
            [pscustomobject]@{
                Id = $(if ($qItem.PSObject.Properties['id']) { [string]$qItem.id } else { '' })
                TimeText = $tStr
                Text = $dTxt
                Prompt = [string]$qItem.prompt
                Status = [string]$qItem.status
                Mode = [string]$qItem.mode
                DeferUntilStopped = [bool]($qItem.PSObject.Properties['defer_until_stopped'] -and $qItem.defer_until_stopped)
            }
        })
        if ($rawMsgs.Count -gt 1) { [Array]::Reverse($rawMsgs) }
        $SessionObj | Add-Member -NotePropertyName 'PendingQueue' -NotePropertyValue $pendingOnly -Force
        $SessionObj | Add-Member -NotePropertyName 'PendingQueueCount' -NotePropertyValue $pendingOnly.Count -Force
        $SessionObj | Add-Member -NotePropertyName 'SentWebMessages' -NotePropertyValue $rawMsgs -Force
    }
}

function Get-TunnelActivityPulse {
    param($Context, [bool]$TunnelRunning = $true, $Settings = $null)
    if ($Context.Isolated -or -not $TunnelRunning) {
        return (New-PulseResult -Session '等待连接后显示实时脉搏')
    }
    $snapCacheKey = [string]$Context.DataRoot
    $canCacheSnap = (-not $Context.Isolated) -and ($snapCacheKey -notmatch 'connection-test-')
    $cachedSnapEntry = if ($canCacheSnap -and $script:StudioHubSnapshotCache.ContainsKey($snapCacheKey)) { $script:StudioHubSnapshotCache[$snapCacheKey] } else { $null }
    $sinceRev = if ($cachedSnapEntry -and $cachedSnapEntry.Rev) { [string]$cachedSnapEntry.Rev } else { '' }
    $hubSnap = Invoke-StudioHubSnapshot -Context $Context -SinceRev $sinceRev
    if ($hubSnap -and $hubSnap.ok) {
        if ($hubSnap.PSObject.Properties['not_modified'] -and $hubSnap.not_modified -and $cachedSnapEntry -and $cachedSnapEntry.Pulse) {
            return $cachedSnapEntry.Pulse
        }
        $commits = @()
        if ($canCacheSnap -and $script:WorkspaceCommitsCache.ContainsKey($snapCacheKey) -and (([DateTime]::UtcNow - $script:WorkspaceCommitsCache[$snapCacheKey].CheckedUtc).TotalSeconds -lt 6.0)) {
            $commits = @($script:WorkspaceCommitsCache[$snapCacheKey].Commits)
        } else {
            $commits = @(Get-WorkspaceRecentCommits $Context)
            if ($canCacheSnap) {
                $script:WorkspaceCommitsCache[$snapCacheKey] = @{ Commits = $commits; CheckedUtc = [DateTime]::UtcNow }
            }
        }
        foreach ($hs in @($hubSnap.sessions) + @($hubSnap.archived_sessions)) {
            if (-not $hs) { continue }
            if ($commits.Count -gt 0 -and (-not $hs.RecentCommits -or @($hs.RecentCommits).Count -eq 0)) {
                $hs | Add-Member -NotePropertyName 'RecentCommits' -NotePropertyValue $commits -Force
            }
            $autoVal = if ($hs.PSObject.Properties['AutoResendEnabled'] -and $null -ne $hs.AutoResendEnabled) {
                [bool]$hs.AutoResendEnabled
            } elseif ($hs.PSObject.Properties['AutoWakeupEnabled'] -and $null -ne $hs.AutoWakeupEnabled) {
                [bool]$hs.AutoWakeupEnabled
            } else {
                $true
            }
            $hs | Add-Member -NotePropertyName 'AutoResendEnabled' -NotePropertyValue $autoVal -Force
            $hs | Add-Member -NotePropertyName 'AutoWakeupEnabled' -NotePropertyValue $autoVal -Force
        }
        $nth = if ($hubSnap.PSObject.Properties['non_task_heartbeat']) { $hubSnap.non_task_heartbeat } else { $null }
        $availModels = @(if ($hubSnap.PSObject.Properties['web_bridge'] -and $hubSnap.web_bridge -and $hubSnap.web_bridge.PSObject.Properties['available_models'] -and $hubSnap.web_bridge.available_models) { $hubSnap.web_bridge.available_models })
        $pulseRes = (New-PulseResult `
            -Session ([string]$hubSnap.session) `
            -SessionColor ([string]$hubSnap.session_color) `
            -IsFault ([bool]$hubSnap.is_fault) `
            -RecentMinuteCount ([int]$hubSnap.recent_minute_count) `
            -CommandCount ([int]$hubSnap.command_count) `
            -Sessions @($hubSnap.sessions) `
            -ArchivedSessions @($hubSnap.archived_sessions) `
            -HiddenIdleCount ([int]$hubSnap.hidden_idle_count) `
            -SubagentCallCount ([int]$hubSnap.subagent_call_count) `
            -NonTaskHeartbeat $nth `
            -AvailableModels $availModels)
        if ($canCacheSnap) {
            $revVal = if ($hubSnap.PSObject.Properties['rev'] -and $hubSnap.rev) { [string]$hubSnap.rev } else { '' }
            $script:StudioHubSnapshotCache[$snapCacheKey] = @{ Rev = $revVal; Pulse = $pulseRes; UpdatedUtc = [DateTime]::UtcNow }
        }
        return $pulseRes
    }
    $logPath = Join-Path (Join-Path $Context.DataRoot 'logs') 'tunnel.out.log'
    if (-not (Test-Path -LiteralPath $logPath)) {
        return (New-PulseResult -Session '● 待命中 · 等待首次工具调用')
    }
    try {
        if (-not (Get-Variable -Name 'TunnelLogTailCache' -Scope Script -ErrorAction SilentlyContinue)) {
            $script:TunnelLogTailCache = @{}
        }
        $fileInfo = Get-Item -LiteralPath $logPath -ErrorAction Stop
        $fileLen = [long]$fileInfo.Length
        $cacheEntry = if ($script:TunnelLogTailCache.ContainsKey($logPath)) { $script:TunnelLogTailCache[$logPath] } else { $null }
        $fs = [IO.FileStream]::new($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $headCount = [int][Math]::Min([long]256, $fileLen)
            $headBuf = New-Object byte[] $headCount
            $headRead = if ($headCount -gt 0) { $fs.Read($headBuf, 0, $headCount) } else { 0 }
            $headSig = if ($headRead -gt 0) { [Convert]::ToBase64String($headBuf, 0, $headRead) } else { '' }
            if (-not $cacheEntry -or $fileLen -lt [long]$cacheEntry.ByteOffset -or $headSig -ne [string]$cacheEntry.HeadSig) {
                $cacheEntry = @{
                    ByteOffset = [long]0
                    HeadSig    = $headSig
                    Lines      = New-Object 'System.Collections.Generic.List[string]'
                }
                $script:TunnelLogTailCache[$logPath] = $cacheEntry
            }
            if ($fileLen -gt [long]$cacheEntry.ByteOffset) {
                [void]$fs.Seek([long]$cacheEntry.ByteOffset, [IO.SeekOrigin]::Begin)
                $sr = [IO.StreamReader]::new($fs, [Text.Encoding]::UTF8)
                $newChunk = $sr.ReadToEnd()
                $cacheEntry.ByteOffset = [long]$fs.Position
                foreach ($nl in @($newChunk -split "\r?\n")) {
                    if ($nl.Trim().Length -gt 0) {
                        $cacheEntry.Lines.Add($nl)
                    }
                }
            }
        } finally {
            $fs.Dispose()
        }
        $lines = @($cacheEntry.Lines.ToArray())
        if ($lines.Count -eq 0) {
            return (New-PulseResult -Session '● 待命中 · 隧道刚启动，等待指令')
        }
        if ($lines.Count -gt 2500) {
            $lines = @($lines | Select-Object -Last 2000)
            $cacheEntry.Lines.Clear()
            foreach ($kl in $lines) { $cacheEntry.Lines.Add($kl) }
            try {
                Write-AtomicConnectionText $logPath (($lines -join "`r`n") + "`r`n")
                [void]$script:TunnelLogTailCache.Remove($logPath)
            } catch { }
        }
        $dispatchLines = @($lines | Where-Object { $_ -match '"dispatcher forwarded command to MCP server"' })
        $aliases = Get-SessionAliases $Context
        $tasks = @(Get-RelayTasks $Context $Settings)
        $shieldMap = Read-ShieldActivityMap $Context

        $now = [DateTimeOffset]::Now
        $wfrStreams = [ordered]@{}
        $slashStreams = [ordered]@{}
        $subagentEvents = New-Object 'System.Collections.Generic.List[object]'
        $validToolCount = 0
        $recentMinuteCount = 0
        $zeroEvents = @(if ($shieldMap.ContainsKey('__zero_rpc_events__')) { $shieldMap['__zero_rpc_events__'] })
        $cidCounts = @{}
        $hasWfrStream = $false
        foreach ($dl in $dispatchLines) {
            if ($dl -match '"rpc_request_id":"openai-mcp-discover"') { continue }
            if ($dl -match '"cmd_request_id":"([^"]+)"') {
                $c = $matches[1]
                $cidCounts[$c] = if ($cidCounts.ContainsKey($c)) { $cidCounts[$c] + 1 } else { 1 }
                if ($c -match '^wfr_') { $hasWfrStream = $true }
            }
        }

        foreach ($line in $dispatchLines) {
            $cid = if ($line -match '"cmd_request_id":"([^"]+)"') { $matches[1] } else { '' }
            if (-not $cid) { continue }
            # Skip connector discovery probes (fired when opening ChatGPT plugin pages), not real tool calls
            if ($line -match '"rpc_request_id":"openai-mcp-discover"') { continue }
            $time = $null
            if ($line -match '"time":"([^"]+)"') {
                $time = ConvertTo-LocalDateTimeOffset $matches[1] $null
            }
            $rpcId = if ($line -match '"rpc_request_id":"([^"]+)"') { $matches[1] } else { '' }

            # Normalize wfr_<hex>/<4char> workflow calls AND pure 36-char UUID conversation streams to their base ID
            $baseWfr = ''
            if ($cid -match '^(wfr_[0-9a-zA-Z_]+)(?:/[a-z0-9]{3,6})?$') {
                $baseWfr = $matches[1]
            } elseif ($cid -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -and ((-not $hasWfrStream) -or ($cidCounts[$cid] -ge 2) -or ($rpcId -and $shieldMap.ContainsKey($rpcId)))) {
                $baseWfr = $cid
            }
            if ($baseWfr) {
                $validToolCount++
                if ($time -and (($now - $time).TotalSeconds -le 60)) { $recentMinuteCount++ }
                if (-not $wfrStreams.Contains($baseWfr)) {
                    $wfrStreams[$baseWfr] = [pscustomobject]@{
                        WfrId = $baseWfr
                        FirstTime = $time
                        LastTime = $time
                        Count = 0
                        SubagentCount = 0
                        RpcIds = New-Object 'System.Collections.Generic.List[string]'
                        TaskId = ''
                        TitleHint = ''
                        WorkspaceHint = ''
                        LastAction = ''
                    }
                }
                $entry = $wfrStreams[$baseWfr]
                $entry.Count++
                if ($time -and (-not $entry.FirstTime -or $time -lt $entry.FirstTime)) { $entry.FirstTime = $time }
                if ($time -and (-not $entry.LastTime -or $time -gt $entry.LastTime)) { $entry.LastTime = $time }
                if ($rpcId) {
                    $entry.RpcIds.Add($rpcId)
                    if ($shieldMap.ContainsKey($rpcId)) {
                        $meta = $shieldMap[$rpcId]
                        if ($meta.PSObject.Properties.Name -contains 'task_id' -and $meta.task_id) { $entry.TaskId = [string]$meta.task_id }
                        if ($meta.PSObject.Properties.Name -contains 'title_hint' -and $meta.title_hint) { $entry.TitleHint = [string]$meta.title_hint }
                        if ($meta.PSObject.Properties.Name -contains 'workspace_hint' -and $meta.workspace_hint) { $entry.WorkspaceHint = [string]$meta.workspace_hint }
                        if ($meta.action) { $entry.LastAction = [string]$meta.action }
                    }
                } elseif ($time -and $zeroEvents.Count -gt 0) {
                    foreach ($ze in $zeroEvents) {
                        $zeTime = ConvertTo-LocalDateTimeOffset $ze.time $null
                        if ($zeTime -and [Math]::Abs(($zeTime - $time).TotalSeconds) -le 4) {
                            if ($ze.PSObject.Properties.Name -contains 'task_id' -and $ze.task_id) { $entry.TaskId = [string]$ze.task_id }
                            if ($ze.PSObject.Properties.Name -contains 'title_hint' -and $ze.title_hint) { $entry.TitleHint = [string]$ze.title_hint }
                            if ($ze.PSObject.Properties.Name -contains 'workspace_hint' -and $ze.workspace_hint) { $entry.WorkspaceHint = [string]$ze.workspace_hint }
                            if ($ze.PSObject.Properties.Name -contains 'action' -and $ze.action) { $entry.LastAction = [string]$ze.action }
                        }
                    }
                }
                continue
            }

            # Standard ChatGPT Web conversation calls use <conversation_uuid>/<4char_call_id> with rpc_request_id:0.
            # Group by <conversation_uuid>; 1-shot calls (Count == 1) are connector discovery pings, while Count >= 2 are real conversations.
            if ($cid -match '^([0-9a-fA-F-]{36})/[a-z0-9]{3,6}$') {
                $convUuid = $matches[1]
                if (-not $slashStreams.Contains($convUuid)) {
                    $slashStreams[$convUuid] = [pscustomobject]@{
                        WfrId = $convUuid
                        FirstTime = $time
                        LastTime = $time
                        Count = 0
                        RecentMinuteCount = 0
                        RpcIds = New-Object 'System.Collections.Generic.List[string]'
                        HasRealCall = $false
                        LastAction = '通过 MCP 转发本机工具指令（常规网页对话）'
                    }
                }
                $sEntry = $slashStreams[$convUuid]
                $sEntry.Count++
                if ($rpcId -and $rpcId -ne '0' -and $rpcId -ne 'openai-mcp-discover') {
                    if (-not $sEntry.RpcIds.Contains($rpcId)) { $sEntry.RpcIds.Add($rpcId) }
                    if ($shieldMap.ContainsKey($rpcId)) { $sEntry.HasRealCall = $true }
                }
                if ($time -and (($now - $time).TotalSeconds -le 60)) { $sEntry.RecentMinuteCount++ }
                if ($time -and (-not $sEntry.FirstTime -or $time -lt $sEntry.FirstTime)) { $sEntry.FirstTime = $time }
                if ($time -and (-not $sEntry.LastTime -or $time -gt $sEntry.LastTime)) { $sEntry.LastTime = $time }
                continue
            }

            # Skip any other numeric handshake pings
            if ($cid -match '/[a-z0-9]{3,6}$' -or $line -match '"rpc_request_id":\s*\d+') { continue }

            $validToolCount++
            if ($time -and (($now - $time).TotalSeconds -le 60)) { $recentMinuteCount++ }
            $subAction = ''
            if ($rpcId -and $shieldMap.ContainsKey($rpcId) -and $shieldMap[$rpcId].action) {
                $subAction = [string]$shieldMap[$rpcId].action
            }
            $subagentEvents.Add([pscustomobject]@{ Cid = $cid; Time = $time; RpcId = $rpcId; Action = $subAction })
        }

        # Match wfrStreams to RelayStudio tasks and roll up sequential turns of the same task
        $groupedSessions = [ordered]@{}
        $hiddenIdleCount = 0
        foreach ($wfr in $wfrStreams.Values) {
            $matchedTask = $null
            if ($wfr.TaskId) {
                $matchedTask = $tasks | Where-Object { $_.TaskId -eq $wfr.TaskId } | Select-Object -First 1
            }
            if (-not $matchedTask -and $wfr.WorkspaceHint -and $tasks.Count -gt 0) {
                $matchedTask = $tasks | Where-Object {
                    $_.Title -and $_.Title.IndexOf($wfr.WorkspaceHint, [StringComparison]::OrdinalIgnoreCase) -ge 0
                } | Select-Object -First 1
            }
            $isDistinctWorkspace = ($wfr.WorkspaceHint -and ($wfr.WorkspaceHint -in @('tool', 'RelayStudio', 'Obsidian Vault')))
            if (-not $matchedTask -and -not $isDistinctWorkspace -and $tasks.Count -gt 0 -and $wfr.LastTime) {
                $matchedTask = $tasks | Where-Object {
                    $wfr.FirstTime -ge $_.CreatedAt.AddMinutes(-5) -and (($now - $_.UpdatedAt).TotalHours -lt 24) -and ($_.Status -eq 'active' -or $wfr.LastTime -le $_.UpdatedAt.AddHours(6))
                } | Select-Object -First 1
            }
            if ($matchedTask) {
                $key = $matchedTask.TaskId
                if ($groupedSessions.Contains($key)) {
                    $existing = $groupedSessions[$key]
                    $existing.Count += $wfr.Count
                    if ($wfr.LastTime -and (-not $existing.LastTime -or $wfr.LastTime -gt $existing.LastTime)) {
                        $existing.LastTime = $wfr.LastTime
                        $existing.WfrId = $wfr.WfrId
                    }
                    if ($wfr.LastAction) { $existing.LastAction = $wfr.LastAction }
                    continue
                }
                $groupedSessions[$key] = [pscustomobject]@{
                    SessionKey = $key
                    WfrId = $wfr.WfrId
                    TaskId = $matchedTask.TaskId
                    TaskTitle = $matchedTask.Title
                    CurrentStep = $matchedTask.CurrentStep
                    TaskSummary = $matchedTask.Summary
                    TaskObj = $matchedTask
                    TitleHint = $wfr.TitleHint
                    LastAction = $wfr.LastAction
                    FirstTime = $wfr.FirstTime
                    LastTime = $wfr.LastTime
                    Count = $wfr.Count
                    SubagentCount = 0
                }
            } elseif ($wfr.LastTime -and (($now - $wfr.LastTime).TotalSeconds -gt 900)) {
                $hiddenIdleCount++
            }
        }

        # Roll up subagent tool calls into their parent workflow session
        $subagentTotal = $subagentEvents.Count
        if ($groupedSessions.Count -gt 0) {
            $sessionList = @($groupedSessions.Values)
            foreach ($sub in $subagentEvents) {
                $target = $null
                if ($sub.Time) {
                    $candidates = @($sessionList | Where-Object { $_.FirstTime -and $_.FirstTime -le $sub.Time.AddSeconds(5) } | Sort-Object LastTime -Descending)
                    if ($candidates.Count -gt 0) { $target = $candidates[0] }
                }
                if (-not $target) { $target = $sessionList[-1] }
                $target.Count++
                $target.SubagentCount++
                if ($sub.Time -and (-not $target.LastTime -or $sub.Time -gt $target.LastTime)) {
                    $target.LastTime = $sub.Time
                }
                if ($sub.Action) { $target.LastAction = "子代理 · $($sub.Action)" }
            }
        }

        # Handle <uuid>/<4char> streams (Count >= 2):
        # - In C4, OpenAI cloud fresh subagents use <uuid>/<4char> with rpc_request_id:0.
        # - Only promote <uuid>/<4char> to an independent main conversation if shield-activity.json confirms a non-C4 workspace_hint,
        #   or the user assigned a custom alias, or there are no wfr_ workflow sessions at all.
        # - Otherwise, roll them up into the parent wfr_ main conversation as cloud subagent calls so C4 never splits!
        $zeroEvents = @(if ($shieldMap.ContainsKey('__zero_rpc_events__')) { $shieldMap['__zero_rpc_events__'] })
        $slashGroups = New-Object 'System.Collections.Generic.List[object]'
        $archiveOverridesPre = Get-TaskArchiveOverrides $Context
        $bridgeStatePre = Get-WebBridgeState $Context
        foreach ($slash in $slashStreams.Values) {
            if ($slash.Count -ge 2 -or $slash.HasRealCall -or $aliases.ContainsKey($slash.WfrId)) {
                $validToolCount += $slash.Count
                $recentMinuteCount += $slash.RecentMinuteCount

                $slashTaskId = ''
                $slashWsHint = ''
                $slashActionHint = ''
                foreach ($rId in $slash.RpcIds) {
                    if ($shieldMap.ContainsKey($rId)) {
                        $meta = $shieldMap[$rId]
                        if ($meta.PSObject.Properties.Name -contains 'task_id' -and $meta.task_id) { $slashTaskId = [string]$meta.task_id }
                        if ($meta.PSObject.Properties.Name -contains 'workspace_hint' -and $meta.workspace_hint) {
                            $candWs = [string]$meta.workspace_hint
                            if ($candWs -notin @('tool', 'RelayStudio', 'Obsidian Vault')) {
                                $slashWsHint = $candWs
                            } elseif ($candWs -ne 'tool' -and -not $slashWsHint) {
                                $slashWsHint = $candWs
                            }
                        }
                        if ($meta.PSObject.Properties.Name -contains 'action' -and $meta.action) { $slashActionHint = [string]$meta.action }
                    }
                }
                foreach ($ze in $zeroEvents) {
                    $zeTime = ConvertTo-LocalDateTimeOffset $ze.time $null
                    if ($zeTime -and $slash.FirstTime -and $slash.LastTime -and $zeTime -ge $slash.FirstTime.AddSeconds(-5) -and $zeTime -le $slash.LastTime.AddSeconds(5)) {
                        if ($ze.PSObject.Properties.Name -contains 'task_id' -and $ze.task_id) { $slashTaskId = [string]$ze.task_id }
                        if ($ze.PSObject.Properties.Name -contains 'workspace_hint' -and $ze.workspace_hint) {
                            $candWs = [string]$ze.workspace_hint
                            if ($candWs -notin @('tool', 'RelayStudio', 'Obsidian Vault')) {
                                $slashWsHint = $candWs
                            } elseif ($candWs -ne 'tool' -and -not $slashWsHint) {
                                $slashWsHint = $candWs
                            }
                        }
                        if ($ze.PSObject.Properties.Name -contains 'action' -and $ze.action) { $slashActionHint = [string]$ze.action }
                    }
                }

                $targetSession = $null
                $skippedBoundTask = $false
                $isPrimaryWsHint = (-not $slashWsHint) -or ($slashWsHint -notin @('tool', 'RelayStudio', 'Obsidian Vault'))
                if ($slashTaskId -and $groupedSessions.Contains($slashTaskId)) {
                    $targetSession = $groupedSessions[$slashTaskId]
                } elseif ($isPrimaryWsHint) {
                    foreach ($gs in @($groupedSessions.Values | Sort-Object { if ($_.LastTime) { $_.LastTime } else { [DateTimeOffset]::MinValue } } -Descending)) {
                        $gsOv = if ($archiveOverridesPre.ContainsKey($gs.SessionKey)) { $archiveOverridesPre[$gs.SessionKey] } elseif ($archiveOverridesPre.ContainsKey($gs.WfrId)) { $archiveOverridesPre[$gs.WfrId] } else { '' }
                        if ($gsOv -ne 'archived' -and $gs.TaskId) {
                            $boundObj = if ($bridgeStatePre -and $bridgeStatePre.session_bindings -and $bridgeStatePre.session_bindings.PSObject.Properties[$gs.TaskId]) { $bridgeStatePre.session_bindings.$($gs.TaskId) } else { $null }
                            $boundUuid = if ($boundObj -and $boundObj.PSObject.Properties['conv_uuid'] -and $boundObj.conv_uuid) { [string]$boundObj.conv_uuid } else { '' }
                            if ($slash.HasRealCall -and -not $slashTaskId -and $boundUuid -and $boundUuid -ne $slash.WfrId) {
                                $skippedBoundTask = $true
                                continue
                            }
                            $targetSession = $gs
                            break
                        }
                    }
                    if (-not $targetSession -and -not $slash.HasRealCall -and -not $skippedBoundTask) {
                        foreach ($gs in @($groupedSessions.Values | Sort-Object { if ($_.LastTime) { $_.LastTime } else { [DateTimeOffset]::MinValue } } -Descending)) {
                            $gsOv = if ($archiveOverridesPre.ContainsKey($gs.SessionKey)) { $archiveOverridesPre[$gs.SessionKey] } elseif ($archiveOverridesPre.ContainsKey($gs.WfrId)) { $archiveOverridesPre[$gs.WfrId] } else { '' }
                            if ($gsOv -ne 'archived') {
                                $targetSession = $gs
                                break
                            }
                        }
                    }
                    if (-not $targetSession -and -not $skippedBoundTask -and ($slashTaskId -or ($slashWsHint -and $isPrimaryWsHint)) -and $tasks.Count -gt 0) {
                        $activeTaskCandidate = $tasks | Where-Object {
                            $tOv = if ($archiveOverridesPre.ContainsKey($_.TaskId)) { $archiveOverridesPre[$_.TaskId] } else { '' }
                            $bObj = if ($bridgeStatePre -and $bridgeStatePre.session_bindings -and $bridgeStatePre.session_bindings.PSObject.Properties[$_.TaskId]) { $bridgeStatePre.session_bindings.$($_.TaskId) } else { $null }
                            $bUuid = if ($bObj -and $bObj.PSObject.Properties['conv_uuid'] -and $bObj.conv_uuid) { [string]$bObj.conv_uuid } else { '' }
                            $notBoundToOther = (-not ($slash.HasRealCall -and -not $slashTaskId -and $bUuid -and $bUuid -ne $slash.WfrId))
                            $isRecentActive = ($_.Status -eq 'active')
                            $notBoundToOther -and (($slashTaskId -and $_.TaskId -eq $slashTaskId) -or ($tOv -eq 'active') -or ($tOv -ne 'archived' -and $isRecentActive))
                        } | Select-Object -First 1
                        if ($activeTaskCandidate) {
                            $tKey = $activeTaskCandidate.TaskId
                            $groupedSessions[$tKey] = [pscustomobject]@{
                                SessionKey = $tKey
                                WfrId = $slash.WfrId
                                TaskId = $activeTaskCandidate.TaskId
                                TaskTitle = $activeTaskCandidate.Title
                                CurrentStep = $activeTaskCandidate.CurrentStep
                                TaskSummary = $activeTaskCandidate.Summary
                                TaskObj = $activeTaskCandidate
                                TitleHint = ''
                                LastAction = $slash.LastAction
                                FirstTime = $slash.FirstTime
                                LastTime = $slash.LastTime
                                Count = 0
                                SubagentCount = 0
                            }
                            $targetSession = $groupedSessions[$tKey]
                        }
                    }
                }

                if ($targetSession -and $isPrimaryWsHint) {
                    # Roll up cloud fresh subagent / handover calls into the active main workflow session so C4 stays a single card
                    $targetSession.Count += $slash.Count
                    $targetSession.SubagentCount += $slash.Count
                    $subagentTotal += $slash.Count
                    if ($slash.LastTime -and (-not $targetSession.LastTime -or $slash.LastTime -gt $targetSession.LastTime)) {
                        $targetSession.LastTime = $slash.LastTime
                    }
                    if ($slashActionHint) { $targetSession.LastAction = "子代理 · $slashActionHint" }
                }
            }
        }

        if ($validToolCount -eq 0) {
            $validToolCount = $dispatchLines.Count
        }

        # Sort main conversations by LastTime descending and apply 15-minute (900s) auto-cleanup
        $sorted = @($groupedSessions.Values | Sort-Object { if ($_.LastTime) { $_.LastTime } else { [DateTimeOffset]::MinValue } } -Descending)
        $kept = New-Object 'System.Collections.Generic.List[object]'
        for ($i = 0; $i -lt $sorted.Count; $i++) {
            $item = $sorted[$i]
            $elapsed = if ($item.LastTime) { [Math]::Max(0, [int]($now - $item.LastTime).TotalSeconds) } else { 0 }
            if ($elapsed -le 900 -or $i -eq 0) {
                $kept.Add($item)
            } else {
                $hiddenIdleCount++
            }
        }

        $autoCfg = Get-AutoResendConfig $Context
        $stallThresholdSec = [Math]::Max(60, [int]$autoCfg.StallMinutes * 60)
        $recentCommits = @(Get-WorkspaceRecentCommits $Context)
        $archiveOverrides = Get-TaskArchiveOverrides $Context
        $archiveTimestamps = Get-TaskArchiveTimestamps $Context
        $inFlightCount = if ($shieldMap.ContainsKey('__in_flight_count__')) { [int]$shieldMap['__in_flight_count__'] } else { 0 }
        $rawFormattedSessions = @(foreach ($s in $kept) {
            $shortWfr = if ($s.WfrId -match '^wfr_') {
                'wfr_…' + $s.WfrId.Substring([Math]::Max(0, $s.WfrId.Length - 6))
            } elseif ($s.WfrId -match '^[0-9a-fA-F]{8}-') {
                $s.WfrId.Substring(0, 4) + '…' + $s.WfrId.Substring([Math]::Max(0, $s.WfrId.Length - 6))
            } else {
                $s.WfrId.Substring(0, [Math]::Min(10, $s.WfrId.Length))
            }
            $customTitle = ''
            if ($aliases.ContainsKey($s.SessionKey)) { $customTitle = $aliases[$s.SessionKey] }
            elseif ($aliases.ContainsKey($s.WfrId)) { $customTitle = $aliases[$s.WfrId] }
            $displayTitle = if ($customTitle) { $customTitle }
                elseif ($s.TaskTitle) { $s.TaskTitle }
                elseif ($s.TitleHint) { $s.TitleHint }
                else { "ChatGPT 网页主对话 ($shortWfr)" }
            $shortTitle = ($displayTitle -replace '：工单\s*\d+[–-]\d+$', '')

            $elapsedSec = if ($s.LastTime) { [Math]::Max(0, [int]($now - $s.LastTime).TotalSeconds) } else { 0 }
            $isStalled = ($elapsedSec -ge $stallThresholdSec -and $inFlightCount -eq 0)
            $stallAlertText = if ($isStalled) { '已停顿3分钟，请检查网页端' } else { '' }
            $badgeText = '● 活跃运行中'
            $badgeFg = '#166534'
            $badgeBg = '#DCFCE7'
            $badgeBorder = '#BBF7D0'
            $dotColor = '#16A34A'
            $timeLabel = '刚刚'

            if ($elapsedSec -le 90) {
                $timeLabel = if ($elapsedSec -le 3) { '刚刚' } else { "${elapsedSec} 秒前" }
            } elseif ($elapsedSec -le 300) {
                $mins = [int][Math]::Floor($elapsedSec / 60)
                $secs = $elapsedSec % 60
                $timeLabel = "${mins}分${secs}秒前"
                $badgeText = if ($isStalled) { '● 已停顿3分钟' } else { '● 思考或跑测试中' }
                $badgeFg = '#9A3412'
                $badgeBg = '#FEF3C7'
                $badgeBorder = '#FDE68A'
                $dotColor = '#D97706'
            } else {
                $mins = [int][Math]::Floor($elapsedSec / 60)
                $timeLabel = "${mins} 分钟前"
                $badgeText = '● 已停工待命'
                $badgeFg = '#9A3412'
                $badgeBg = '#FEF3C7'
                $badgeBorder = '#FDE68A'
                $dotColor = '#D97706'
            }

            $cleanAction = if ($s.LastAction) { $s.LastAction -replace '\(@''\)', '(运行诊断脚本)' } else { '' }
            $stepPart = if ($s.CurrentStep -and $cleanAction) { "$($s.CurrentStep) · $cleanAction" }
                elseif ($cleanAction) { $cleanAction }
                elseif ($s.CurrentStep) { "当前在 $($s.CurrentStep)" }
                else { '转发本机 MCP 工具指令' }

            $actionLine = if ($elapsedSec -le 300) {
                "${timeLabel}调工具 · ${stepPart}（累计 $($s.Count) 次）"
            } else {
                "上次调用在 ${timeLabel} · ${stepPart}（累计 $($s.Count) 次，请检查网页端是否停下）"
            }

            $metaTag = if ($s.SubagentCount -gt 0) {
                "会话尾号 $shortWfr · 已自动合并 $($s.SubagentCount) 次子代理调用"
            } else {
                "会话尾号 $shortWfr"
            }

            $tObj = $s.TaskObj
            $goalText = if ($tObj -and $tObj.Goal) { $tObj.Goal } else { '通过 OpenAI 隧道转发本机 MCP 工具指令' }
            $stepsArr = @(if ($tObj -and $tObj.Steps) { $tObj.Steps })
            $compSteps = if ($tObj) { [int]$tObj.CompletedStepCount } else { 0 }
            $totSteps = if ($tObj) { [int]$tObj.TotalStepCount } else { 0 }
            $progPct = if ($tObj) { [int]$tObj.ProgressPercent } else { 100 }
            $progText = if ($totSteps -gt 0) {
                "已完成 $compSteps / $totSteps 个阶段（$progPct%） · 累计 $($s.Count) 次调用（含 $($s.SubagentCount) 次子代理）"
            } else {
                "累计转发 $($s.Count) 次本机工具调用（含 $($s.SubagentCount) 次子代理）"
            }
            $stepCountText = if ($totSteps -gt 0) { "$compSteps / $totSteps 步已完成" } else { "累计 $($s.Count) 次调用" }
            $railSubtitle = if ($isStalled) { '已停顿3分钟，请检查网页端' } elseif ($s.CurrentStep) { "$($s.CurrentStep) · $timeLabel" } else { "${timeLabel}调工具 · 累计 $($s.Count) 次" }
            $curStepLabel = if ($s.CurrentStep) { $s.CurrentStep } else { '本机工具调用' }
            $diagnosis = if ($elapsedSec -le 90) {
                "结论：该对话正在持续活跃工作（${timeLabel}刚调用过本机工具）。当前正处于【$curStepLabel】，整体已完成 $compSteps / $totSteps 个阶段（$progPct%），无需人工干预。"
            } elseif ($elapsedSec -le 300) {
                "结论：距上次工具调用已过 ${timeLabel}，模型通常正在云端思考、编写长代码或等待子智能体跑测试。当前处于【$curStepLabel】（已完成 $compSteps / $totSteps 个阶段，$progPct%）。"
            } else {
                $commitHint = if ($recentCommits.Count -gt 0) { "（最近一次代码库提交在 $($recentCommits[0].TimeText) · $($recentCommits[0].AgoText)）" } else { '' }
                "结论：距上次本机工具调用已过 ${timeLabel}$commitHint。若云端子智能体仍在后台跑任务可继续观察；若 ChatGPT 网页端已停止输出，请切回网页发送『继续』。"
            }
            $latestSum = if ($s.TaskSummary) { $s.TaskSummary } elseif ($s.LastAction) { $s.LastAction } else { '暂无阶段文字摘要，请参考下方工具调用与代码库提交记录。' }
            $ckptArr = @(if ($tObj -and $tObj.Checkpoints) { $tObj.Checkpoints })
            $readableCkpts = @(foreach ($ck in $ckptArr) { ConvertTo-ReadableMilestone $ck.Summary $ck.TimeText $stepsArr })
            $condArr = @(if ($tObj -and $tObj.Conditions) { $tObj.Conditions })

            [pscustomobject]([ordered]@{
                SessionKey = $s.SessionKey
                WfrId = $s.WfrId
                ShortId = $shortWfr
                Title = $displayTitle
                ShortTitle = $shortTitle
                IsCustomTitle = [bool]$customTitle
                StatusBadge = $badgeText
                StatusFg = $badgeFg
                StatusBg = $badgeBg
                StatusBorder = $badgeBorder
                DotColor = $dotColor
                ActionText = $actionLine
                RailSubtitle = $railSubTitle
                StepCountText = $stepCountText
                IsStalled = $isStalled
                StallAlertText = $stallAlertText
                MetaText = $metaTag
                CommandCount = $s.Count
                SubagentCount = $s.SubagentCount
                ElapsedSeconds = $elapsedSec
                Goal = $goalText
                CleanGoal = (ConvertTo-CleanGoalSubtitle $goalText)
                HumanDiagnosis = $diagnosis
                ProgressText = $progText
                ProgressPercent = $progPct
                Steps = $stepsArr
                LatestSummary = $latestSum
                Checkpoints = $ckptArr
                ReadableCheckpoints = $readableCkpts
                RecentCommits = $recentCommits
                Conditions = $condArr
                IsArchived = $false
                ArchiveReason = ''
                BreakerStage = 'Idle'
                BreakerMessage = ''
                AutoWakeupEnabled = [bool]$autoCfg.Enabled
                RetryCount = 0
                MaxRetries = [int]$autoCfg.MaxRetries
                StallMinutes = [int]$autoCfg.StallMinutes
                SentWebMessages = @()
            })
        })

        $bridgeState = Get-WebBridgeState $Context
        $bridgeQueue = @(if ($bridgeState -and $bridgeState.PSObject.Properties.Name -contains 'queue' -and $bridgeState.queue) { $bridgeState.queue })
        $activeList = New-Object 'System.Collections.Generic.List[object]'
        $archivedList = New-Object 'System.Collections.Generic.List[object]'
        $seenTaskIds = @{}
        foreach ($fsItem in $rawFormattedSessions) {
            if ($fsItem.SessionKey) { $seenTaskIds[$fsItem.SessionKey] = $true }
            if ($fsItem.WfrId) { $seenTaskIds[$fsItem.WfrId] = $true }
            $ovKey = if ($archiveOverrides.ContainsKey($fsItem.SessionKey)) { $fsItem.SessionKey }
                     elseif ($archiveOverrides.ContainsKey($fsItem.WfrId)) { $fsItem.WfrId }
                     else { '' }
            $ov = if ($ovKey) { $archiveOverrides[$ovKey] } else { '' }

            # Auto-persist conv_uuid from browser tabs if not bound yet (respecting retired_uuids)
            if ($bridgeState -and $bridgeState.tabs) {
                $existingBind = if ($bridgeState.session_bindings -and $bridgeState.session_bindings.PSObject.Properties[$fsItem.SessionKey]) { $bridgeState.session_bindings.$($fsItem.SessionKey) } else { $null }
                $retiredUuids = @(if ($existingBind -and $existingBind.PSObject.Properties['retired_uuids'] -and $existingBind.retired_uuids) { @($existingBind.retired_uuids) })
                if (-not ($existingBind -and $existingBind.PSObject.Properties['conv_uuid'] -and $existingBind.conv_uuid)) {
                    foreach ($tp in $bridgeState.tabs.PSObject.Properties) {
                        $tVal = $tp.Value
                        if (-not $tVal -or -not ($tVal.PSObject.Properties['conv_uuid'] -and $tVal.conv_uuid)) { continue }
                        $candUuid = [string]$tVal.conv_uuid
                        if ($retiredUuids -contains $candUuid) { continue }
                        $hints = @(if ($tVal.PSObject.Properties['page_hints'] -and $tVal.page_hints) { $tVal.page_hints })
                        $tTitle = if ($tVal.PSObject.Properties['title'] -and $tVal.title) { [string]$tVal.title } else { '' }
                        $tProj = if ($tVal.PSObject.Properties['project_prefix'] -and $tVal.project_prefix) { [string]$tVal.project_prefix } else { '' }
                        if (($hints -contains $fsItem.SessionKey) -or ($fsItem.WfrId -and ($hints -contains $fsItem.WfrId)) -or ($fsItem.ShortTitle -and $tTitle -and $tTitle.IndexOf($fsItem.ShortTitle, [StringComparison]::OrdinalIgnoreCase) -ge 0)) {
                            [void](Set-SessionBridgeBinding -Context $Context -SessionKey $fsItem.SessionKey -ConvUuid $candUuid -ProjectPrefix $tProj -TabId ([string]$tVal.tab_id) -Title $tTitle)
                            break
                        }
                    }
                }
            }

            $pendingMatchedMsgs = @(foreach ($qItem in @($bridgeQueue | Where-Object { $_ -and $_.session_key -eq $fsItem.SessionKey -and $_.status -eq 'pending' })) {
                if (-not $qItem) { continue }
                $dtQ = ConvertTo-LocalDateTimeOffset $qItem.created_at $null
                $tStr = if ($dtQ) { $dtQ.ToString('MM-dd HH:mm:ss') } else { '刚刚' }
                $dTxt = if ($qItem.PSObject.Properties.Name -contains 'display_text' -and $qItem.display_text) { [string]$qItem.display_text } else { [string]$qItem.prompt }
                [pscustomobject]@{
                    Id = $(if ($qItem.PSObject.Properties['id']) { [string]$qItem.id } else { '' })
                    TimeText = $tStr
                    Text = $dTxt
                    Prompt = [string]$qItem.prompt
                    Status = [string]$qItem.status
                    Mode = [string]$qItem.mode
                    DeferUntilStopped = [bool]($qItem.PSObject.Properties['defer_until_stopped'] -and $qItem.defer_until_stopped)
                }
            })
            $rawMatchedMsgs = @(foreach ($qItem in @($bridgeQueue | Where-Object { $_ -and $_.session_key -eq $fsItem.SessionKey -and $_.status -notin @('superseded', 'cancelled') })) {
                if (-not $qItem) { continue }
                $dtQ = ConvertTo-LocalDateTimeOffset $qItem.created_at $null
                $tStr = if ($dtQ) { $dtQ.ToString('MM-dd HH:mm:ss') } else { '刚刚' }
                $dTxt = if ($qItem.PSObject.Properties.Name -contains 'display_text' -and $qItem.display_text) { [string]$qItem.display_text } else { [string]$qItem.prompt }
                [pscustomobject]@{
                    Id = $(if ($qItem.PSObject.Properties['id']) { [string]$qItem.id } else { '' })
                    TimeText = $tStr
                    Text = $dTxt
                    Prompt = [string]$qItem.prompt
                    Status = [string]$qItem.status
                    Mode = [string]$qItem.mode
                    DeferUntilStopped = [bool]($qItem.PSObject.Properties['defer_until_stopped'] -and $qItem.defer_until_stopped)
                }
            })
            if ($rawMatchedMsgs.Count -gt 1) { [Array]::Reverse($rawMatchedMsgs) }
            $matchedMsgs = $rawMatchedMsgs
            $fsItem | Add-Member -NotePropertyName 'PendingQueue' -NotePropertyValue $pendingMatchedMsgs -Force
            $fsItem | Add-Member -NotePropertyName 'PendingQueueCount' -NotePropertyValue $pendingMatchedMsgs.Count -Force
            $fsItem.SentWebMessages = $matchedMsgs
            if ($ov -eq 'archived') {
                $fsItem.IsArchived = $true
                $fsItem.ArchiveReason = '手动归档'
                $archivedList.Add($fsItem)
            } else {
                if (-not $fsItem.RailSubtitle) { $fsItem.RailSubtitle = $fsItem.ActionText }
                $bState = if ($bridgeState -and $bridgeState.PSObject.Properties['breakers'] -and $bridgeState.breakers -and $bridgeState.breakers.PSObject.Properties[$fsItem.SessionKey]) {
                    $bridgeState.breakers.$($fsItem.SessionKey)
                } else { $null }
                if ($bState) {
                    if ($bState.PSObject.Properties['stage'] -and $bState.stage) { $fsItem.BreakerStage = [string]$bState.stage }
                    if ($bState.PSObject.Properties['last_message'] -and $bState.last_message) { $fsItem.BreakerMessage = [string]$bState.last_message }
                    if ($bState.PSObject.Properties['auto_enabled'] -and $null -ne $bState.auto_enabled) { $fsItem.AutoWakeupEnabled = ([bool]$autoCfg.Enabled -and [bool]$bState.auto_enabled) }
                    if ($bState.PSObject.Properties['retry_count']) { $fsItem.RetryCount = [int]$bState.retry_count }
                    if ($bState.PSObject.Properties['max_retries']) { $fsItem.MaxRetries = [int]$bState.max_retries }
                }
                $activeList.Add($fsItem)
            }
        }

        $autoArchMode = '3d'
        try {
            $sCfgLocal = Read-ConnectionSettings $Context
            if ($sCfgLocal -and $sCfgLocal.PSObject.Properties['auto_archive_completed_mode'] -and $sCfgLocal.auto_archive_completed_mode) {
                $autoArchMode = [string]$sCfgLocal.auto_archive_completed_mode
            }
        } catch { }
        foreach ($t in $tasks) {
            if ($seenTaskIds.ContainsKey($t.TaskId)) { continue }
            $ov = if ($archiveOverrides.ContainsKey($t.TaskId)) { $archiveOverrides[$t.TaskId] } else { '' }
            $idleSec = if ($t.UpdatedAt) { [Math]::Max(0, [int]($now - $t.UpdatedAt).TotalSeconds) } else { 999999 }
            $idleHours = $idleSec / 3600.0
            $isCompletedAutoArchived = if ($t.Status -eq 'completed') {
                switch ($autoArchMode) {
                    'off'       { $false }
                    'immediate' { $true }
                    '1d'        { ($idleHours -ge 24.0) }
                    '7d'        { ($idleHours -ge 168.0) }
                    default     { ($idleHours -ge 72.0) }
                }
            } else { $false }
            $isAutoArchived = $isCompletedAutoArchived
            $isActiveTask = ($ov -eq 'active') -or ($ov -ne 'archived' -and -not $isAutoArchived -and $t.Status -in @('active', 'in_progress', 'completed'))
            $isRestoredAncient = ($ov -eq 'active' -and $isAutoArchived)
            $isTaskStalled = ($isActiveTask -and -not $isRestoredAncient -and $idleSec -ge $stallThresholdSec -and $inFlightCount -eq 0)

            $customTitle = if ($aliases.ContainsKey($t.TaskId)) { $aliases[$t.TaskId] } else { '' }
            $tTitle = if ($customTitle) { $customTitle } elseif ($t.Title) { $t.Title } else { "任务 $($t.TaskId)" }
            $tShortTitle = ($tTitle -replace '：工单\s*\d+[–-]\d+$', '')
            $tStepCountText = if ($t.TotalStepCount -gt 0) { "$($t.CompletedStepCount) / $($t.TotalStepCount) 步已完成" } else { '历史会话' }
            $tReadableCkpts = @(foreach ($ck in @($t.Checkpoints)) { ConvertTo-ReadableMilestone $ck.Summary $ck.TimeText $t.Steps })
            $idleMins = [int][Math]::Max(1, [Math]::Floor($idleHours * 60))
            $archReason = if ($ov -eq 'archived') { '手动归档' }
                          elseif ($isRestoredAncient) { '已从归档还原' }
                          elseif ($isTaskStalled) { '已停顿3分钟，请检查网页端' }
                          elseif ($isActiveTask) { '活跃运行中' }
                          elseif ($t.Status -eq 'completed') { '已完工自动归档' }
                          else { '手动归档' }

            # Auto-persist conv_uuid for task if present in tabs (respecting retired_uuids)
            if ($bridgeState -and $bridgeState.tabs) {
                $existingBind = if ($bridgeState.session_bindings -and $bridgeState.session_bindings.PSObject.Properties[$t.TaskId]) { $bridgeState.session_bindings.$($t.TaskId) } else { $null }
                $retiredUuids = @(if ($existingBind -and $existingBind.PSObject.Properties['retired_uuids'] -and $existingBind.retired_uuids) { @($existingBind.retired_uuids) })
                if (-not ($existingBind -and $existingBind.PSObject.Properties['conv_uuid'] -and $existingBind.conv_uuid)) {
                    foreach ($tp in $bridgeState.tabs.PSObject.Properties) {
                        $tVal = $tp.Value
                        if (-not $tVal -or -not ($tVal.PSObject.Properties['conv_uuid'] -and $tVal.conv_uuid)) { continue }
                        $candUuid = [string]$tVal.conv_uuid
                        if ($retiredUuids -contains $candUuid) { continue }
                        $hints = @(if ($tVal.PSObject.Properties['page_hints'] -and $tVal.page_hints) { $tVal.page_hints })
                        $tTitleTab = if ($tVal.PSObject.Properties['title'] -and $tVal.title) { [string]$tVal.title } else { '' }
                        $tProjTab = if ($tVal.PSObject.Properties['project_prefix'] -and $tVal.project_prefix) { [string]$tVal.project_prefix } else { '' }
                        if (($hints -contains $t.TaskId) -or ($tShortTitle -and $tTitleTab -and $tTitleTab.IndexOf($tShortTitle, [StringComparison]::OrdinalIgnoreCase) -ge 0)) {
                            [void](Set-SessionBridgeBinding -Context $Context -SessionKey $t.TaskId -ConvUuid $candUuid -ProjectPrefix $tProjTab -TabId ([string]$tVal.tab_id) -Title $tTitleTab)
                            break
                        }
                    }
                }
            }

            $taskSessionObj = [pscustomobject]([ordered]@{
                SessionKey = [string]$t.TaskId
                WfrId = $t.TaskId
                ShortId = $t.TaskId
                Title = $tTitle
                ShortTitle = $tShortTitle
                IsCustomTitle = [bool]$customTitle
                StatusBadge = $(if ($isRestoredAncient) { '● 已从归档还原' } elseif ($isTaskStalled) { '● 已停顿3分钟，请检查网页端' } elseif ($isActiveTask) { '● 活跃运行中' } else { '● 已归档' })
                StatusFg = $(if ($isRestoredAncient -or ($isActiveTask -and -not $isTaskStalled)) { '#166534' } elseif ($isTaskStalled) { '#9A3412' } else { '#52525B' })
                StatusBg = $(if ($isRestoredAncient -or ($isActiveTask -and -not $isTaskStalled)) { '#DCFCE7' } elseif ($isTaskStalled) { '#FEF3C7' } else { '#F4F4F5' })
                StatusBorder = $(if ($isRestoredAncient -or ($isActiveTask -and -not $isTaskStalled)) { '#BBF7D0' } elseif ($isTaskStalled) { '#FDE68A' } else { '#E4E4E7' })
                DotColor = $(if ($isRestoredAncient -or ($isActiveTask -and -not $isTaskStalled)) { '#16A34A' } elseif ($isTaskStalled) { '#D97706' } else { '#A1A1AA' })
                ActionText = $(if ($isTaskStalled -and $t.CurrentStep) { "上次调用在 ${idleMins} 分钟前 · $($t.CurrentStep)（请检查网页端是否停下）" } elseif ($isActiveTask -and $t.CurrentStep) { "刚刚更新 · $($t.CurrentStep)" } elseif ($t.CurrentStep) { "$($t.CurrentStep) · $archReason" } else { $archReason })
                RailSubtitle = $(if ($isTaskStalled) { '已停顿3分钟，请检查网页端' } elseif ($t.CurrentStep) { "$($t.CurrentStep) · $archReason" } else { "$archReason · $tStepCountText" })
                StepCountText = $tStepCountText
                IsStalled = [bool]$isTaskStalled
                StallAlertText = $(if ($isTaskStalled) { '已停顿3分钟，请检查网页端' } else { '' })
                MetaText = "任务编号 $($t.TaskId) · $tStepCountText"
                CommandCount = 0
                SubagentCount = 0
                ElapsedSeconds = $idleSec
                Goal = $(if ($t.Goal) { $t.Goal } else { '历史归档任务记录' })
                CleanGoal = (ConvertTo-CleanGoalSubtitle $(if ($t.Goal) { $t.Goal } else { '历史归档任务记录' }))
                HumanDiagnosis = "结论：该任务状态为【$archReason】（$tStepCountText）。可在任意分栏打开查看完整阶段与检查点记录。"
                ProgressText = $tStepCountText
                ProgressPercent = [int]$t.ProgressPercent
                Steps = @($t.Steps)
                LatestSummary = $(if ($t.Summary) { $t.Summary } else { '历史任务记录' })
                Checkpoints = @($t.Checkpoints)
                ReadableCheckpoints = $tReadableCkpts
                RecentCommits = $recentCommits
                Conditions = @($t.Conditions)
                IsArchived = (-not $isActiveTask)
                ArchiveReason = $archReason
                BreakerStage = 'Idle'
                BreakerMessage = $(if ($autoCfg.Enabled) { "自动重发守护已就绪 (>$($autoCfg.StallMinutes)分钟静默触发)" } else { '自动重发已关闭' })
                AutoWakeupEnabled = [bool]$autoCfg.Enabled
                RetryCount = 0
                MaxRetries = [int]$autoCfg.MaxRetries
                StallMinutes = [int]$autoCfg.StallMinutes
                SentWebMessages = @()
            })
            if ($isActiveTask) {
                $bState = if ($bridgeState -and $bridgeState.PSObject.Properties['breakers'] -and $bridgeState.breakers -and $bridgeState.breakers.PSObject.Properties[$t.TaskId]) {
                    $bridgeState.breakers.$($t.TaskId)
                } else { $null }
                if ($bState) {
                    if ($bState.PSObject.Properties['stage'] -and $bState.stage) { $taskSessionObj.BreakerStage = [string]$bState.stage }
                    if ($bState.PSObject.Properties['last_message'] -and $bState.last_message) { $taskSessionObj.BreakerMessage = [string]$bState.last_message }
                    if ($bState.PSObject.Properties['auto_enabled'] -and $null -ne $bState.auto_enabled) { $taskSessionObj.AutoWakeupEnabled = ([bool]$autoCfg.Enabled -and [bool]$bState.auto_enabled) }
                    if ($bState.PSObject.Properties['retry_count']) { $taskSessionObj.RetryCount = [int]$bState.retry_count }
                    if ($bState.PSObject.Properties['max_retries']) { $taskSessionObj.MaxRetries = [int]$bState.max_retries }
                }
                $activeList.Add($taskSessionObj)
            } else {
                $archivedList.Add($taskSessionObj)
            }
        }
        foreach ($sItem in $activeList) {
            Add-TaskComposerMetadataToSession -SessionObj $sItem -BridgeState $bridgeState -AutoCfg $autoCfg
        }
        foreach ($arItem in $archivedList) {
            Add-TaskComposerMetadataToSession -SessionObj $arItem -BridgeState $bridgeState -AutoCfg $autoCfg
        }
        $formattedSessions = $activeList.ToArray()
        $archivedSessions = $archivedList.ToArray()

        $lastLine = $lines[-1]
        if ($lastLine -match '"poll failed; backing off"') {
            if ($lastLine -match '127\.0\.0\.1:(\d+).*actively refused') {
                return (New-PulseResult -Session "● 网络代理中断 · 本机代理端口 $($matches[1]) 拒绝连接，正在重试…" -SessionColor '#B42318' -IsFault $true -RecentMinuteCount $recentMinuteCount -CommandCount $validToolCount -Sessions $formattedSessions -ArchivedSessions $archivedSessions -HiddenIdleCount $hiddenIdleCount -SubagentCallCount $subagentTotal)
            }
            return (New-PulseResult -Session "● 隧道网络波动 · 轮询中断正在自动重连（累计已执行 $validToolCount 次）" -SessionColor '#B42318' -IsFault $true -RecentMinuteCount $recentMinuteCount -CommandCount $validToolCount -Sessions $formattedSessions -ArchivedSessions $archivedSessions -HiddenIdleCount $hiddenIdleCount -SubagentCallCount $subagentTotal)
        }

        if ($dispatchLines.Count -eq 0) {
            return (New-PulseResult -Session '● 待命中 · 隧道畅通，等待网页端会话下发指令' -Sessions $formattedSessions -ArchivedSessions $archivedSessions -SubagentCallCount $subagentTotal)
        }

        if (@($formattedSessions).Count -gt 0) {
            $onlineCount = @($formattedSessions).Count
            $top = $formattedSessions[0]
            $elapsedSec = $top.ElapsedSeconds
            $totalCount = $validToolCount
            if ($elapsedSec -le 90) {
                return (New-PulseResult -Session "● $onlineCount 个对话在线（活跃运行中） ｜ ⚡ 近 1 分钟 $recentMinuteCount 次工具调用" -SessionColor '#166534' -RecentMinuteCount $recentMinuteCount -CommandCount $totalCount -Sessions $formattedSessions -ArchivedSessions $archivedSessions -HiddenIdleCount $hiddenIdleCount -SubagentCallCount $subagentTotal)
            } elseif ($elapsedSec -le 300) {
                return (New-PulseResult -Session "● $onlineCount 个对话在线（思考或本地测试中） ｜ ⚡ 近 1 分钟 $recentMinuteCount 次工具调用" -SessionColor '#9A3412' -RecentMinuteCount $recentMinuteCount -CommandCount $totalCount -Sessions $formattedSessions -ArchivedSessions $archivedSessions -HiddenIdleCount $hiddenIdleCount -SubagentCallCount $subagentTotal)
            } else {
                $mins = [int][Math]::Floor($elapsedSec / 60)
                return (New-PulseResult -Session "● $onlineCount 个对话待命中 ｜ ⚡ 近 1 分钟 0 次工具调用 · 上次在 ${mins} 分钟前" -CommandCount $totalCount -Sessions $formattedSessions -ArchivedSessions $archivedSessions -HiddenIdleCount $hiddenIdleCount -SubagentCallCount $subagentTotal)
            }
        }

        $lastDispatch = $dispatchLines[-1]
        $sessionShort = '握手检测'
        if ($lastDispatch -match '"cmd_request_id":"([^"]+)"') {
            $cid = $matches[1]
            $sessionShort = if ($cid -match '^wfr_') { 'wfr_…' + $cid.Substring([Math]::Max(0, $cid.Length - 6)) } else { $cid.Substring(0, [Math]::Min(10, $cid.Length)) }
        }
        return (New-PulseResult -Session "● 已累计转发 $($dispatchLines.Count) 次工具调用（会话 $sessionShort）" -SessionColor '#166534' -RecentMinuteCount $recentMinuteCount -CommandCount $dispatchLines.Count -Sessions $formattedSessions -ArchivedSessions $archivedSessions -SubagentCallCount $subagentTotal)
    } catch {
        return (New-PulseResult -Session '状态读取中…')
    }
}

function Get-ConnectionDisplayState {
    param($Context, $Settings, [switch]$ForceInfraProbe)
    $endpoint = try { Get-OfficialCoreEndpoint $Settings } catch { '尚未找到本地内核' }
    if ($Context.Isolated) { return [pscustomobject]([ordered]@{Endpoint=$endpoint; Core='等待内核启动'; Tunnel='尚未连接'; Session='等待连接后显示实时脉搏'; SessionColor='#505D70'; IsFault=$false; RecentMinuteCount=0; Sessions=@(); ArchivedSessions=@(); HiddenIdleCount=0; SubagentCallCount=0; Detail='保存配置后点击连接，将自动启动本地内核并建立隧道。'; UiUrl=''; Running=$false}) }
    $shieldPort = if (($Settings.PSObject.Properties.Name -contains 'shield_port') -and [int]$Settings.shield_port -gt 0) { [int]$Settings.shield_port } else { 8766 }
    $allowInfraCache = ([string]$Context.DataRoot -notmatch 'connection-test-')
    $infraKey = "$($Context.DataRoot)|$endpoint|$($Settings.health_port)|$shieldPort|$($Settings.readonly_shield)"
    $infraHit = $null
    if ($allowInfraCache -and (-not $ForceInfraProbe) -and $script:InfraProbeCache.ContainsKey($infraKey)) {
        $candInfra = $script:InfraProbeCache[$infraKey]
        if ($candInfra -and (([DateTime]::UtcNow - $candInfra.CheckedUtc).TotalSeconds -lt 6.0)) {
            $infraHit = $candInfra
        }
    }
    if ($infraHit) {
        $core = $infraHit.Core
        $relatedCount = [int]$infraHit.RelatedCount
        $hasLegacy = [bool]$infraHit.HasLegacy
        $readyStatus = [int]$infraHit.ReadyStatus
        $activeProfileHasShield = [bool]$infraHit.ActiveProfileHasShield
        $shieldStatus = [int]$infraHit.ShieldStatus
    } else {
        $core = '尚未启动（连接时自动拉起）'
        if ($endpoint -match '^http') {
            $health = Invoke-ConnectionProbe ($endpoint -replace '/mcp$', '/healthz')
            if ($health.Status -eq 200 -and $health.Body -match '"ok"\s*:\s*true') { $core = '已准备好' }
        }
        $related = @(Get-RelatedTunnelProcesses $Context $Settings)
        $relatedCount = $related.Count
        $hasLegacy = (@($related | Where-Object Kind -eq 'Legacy').Count -gt 0)
        $readyStatus = 0
        $activeProfileHasShield = $false
        $shieldStatus = 0
        if ((-not $hasLegacy) -and $relatedCount -gt 0) {
            $urlProbe = "http://127.0.0.1:$($Settings.health_port)"
            $ready = Invoke-ConnectionProbe ($urlProbe + '/readyz')
            $readyStatus = [int]$ready.Status
            if ($readyStatus -eq 200) {
                $activeProfileText = if (Test-Path -LiteralPath $Context.ProfilePath) { [IO.File]::ReadAllText($Context.ProfilePath) } else { '' }
                if ($activeProfileText -match (':' + $shieldPort + '/mcp')) {
                    $activeProfileHasShield = $true
                    $shieldProbe = Invoke-ConnectionProbe "http://127.0.0.1:$shieldPort/shieldz"
                    $shieldStatus = [int]$shieldProbe.Status
                }
            }
        }
        if ($allowInfraCache) {
            $script:InfraProbeCache[$infraKey] = @{
                CheckedUtc = [DateTime]::UtcNow
                Core = $core
                RelatedCount = $relatedCount
                HasLegacy = $hasLegacy
                ReadyStatus = $readyStatus
                ActiveProfileHasShield = $activeProfileHasShield
                ShieldStatus = $shieldStatus
            }
        }
    }
    $tunnel = '尚未连接'; $detail = '先保存配置，再连接。'; $ui=''
    $session = '尚未连接'; $sessionColor = '#505D70'; $isFault = $false; $recentMinuteCount = 0; $sessions = @(); $archivedSessions = @(); $hiddenIdleCount = 0; $subagentCallCount = 0; $availableModels = @()
    if ($hasLegacy) {
        $tunnel='旧脚本连接仍在运行'; $detail='当前旧连接通向 8787。改用本地内核时，先断开，再连接。'; $ui='http://127.0.0.1:8788/ui'
        $session='● 请先切换到本地内核隧道（当前旧连接通向 8787）'; $sessionColor='#B42318'; $isFault=$true
    } elseif ($relatedCount -gt 0) {
        $url = "http://127.0.0.1:$($Settings.health_port)"
        $ui = $url + '/ui'
        $pulse = Get-TunnelActivityPulse $Context $true $Settings
        $session = $pulse.Session
        $sessionColor = $pulse.SessionColor
        $isFault = [bool]$pulse.IsFault
        $recentMinuteCount = [int]$pulse.RecentMinuteCount
        $sessions = @($pulse.Sessions)
        $archivedSessions = @(if ($pulse.PSObject.Properties.Name -contains 'ArchivedSessions' -and $pulse.ArchivedSessions) { $pulse.ArchivedSessions })
        $hiddenIdleCount = $pulse.HiddenIdleCount
        $subagentCallCount = $pulse.SubagentCallCount
        $availableModels = @(if ($pulse.PSObject.Properties.Name -contains 'AvailableModels' -and $pulse.AvailableModels) { $pulse.AvailableModels })
        if ($readyStatus -eq 200) {
            if ($activeProfileHasShield) {
                if ($shieldStatus -eq 200) {
                    $tunnel = '已就绪'
                    $detail = '隧道与本机桥接核心已就绪，可在 ChatGPT 连续调用本机工具。'
                } else {
                    $tunnel = '已就绪（本地桥接异常）'
                    $detail = '隧道已连接，但本地桥接核心未响应；请点击“断开”后再“重新连接”。'
                    $session = '● 本地桥接核心未响应 · 请点击「断开」后再「重新连接」'
                    $sessionColor = '#B42318'
                    $isFault = $true
                }
            } elseif ($Settings.readonly_shield) {
                $tunnel = '已就绪'
                $detail = '隧道已连接，可在 ChatGPT 调用本机工具。'
            } else {
                $tunnel = '已就绪'
                $detail = '请在 ChatGPT 调用一次工具，确认整条连接可用。'
            }
        }
        else { $tunnel='连接中 / 尚未就绪'; $detail='可打开隧道状态页查看身份验证与连接结果。' }
    } else {
        $offlinePulse = Get-TunnelActivityPulse $Context $true $Settings
        $sessions = @($offlinePulse.Sessions)
        $archivedSessions = @(if ($offlinePulse.PSObject.Properties.Name -contains 'ArchivedSessions' -and $offlinePulse.ArchivedSessions) { $offlinePulse.ArchivedSessions })
        $hiddenIdleCount = $offlinePulse.HiddenIdleCount
        $subagentCallCount = $offlinePulse.SubagentCallCount
        $availableModels = @(if ($offlinePulse.PSObject.Properties.Name -contains 'AvailableModels' -and $offlinePulse.AvailableModels) { $offlinePulse.AvailableModels })
    }
    [pscustomobject]@{Endpoint=$endpoint; Core=$core; Tunnel=$tunnel; Session=$session; SessionColor=$sessionColor; IsFault=$isFault; RecentMinuteCount=$recentMinuteCount; Sessions=$sessions; ArchivedSessions=$archivedSessions; HiddenIdleCount=$hiddenIdleCount; SubagentCallCount=$subagentCallCount; AvailableModels=$availableModels; Detail=$detail; UiUrl=$ui; Running=($relatedCount -gt 0)}
}

function Get-AcpConcurrencyLimit {
    param($Context)
    $settings = Read-ConnectionSettings $Context
    $limit = if (($settings.PSObject.Properties.Name -contains 'acp_max_concurrent_prompts') -and $null -ne $settings.acp_max_concurrent_prompts -and [int]$settings.acp_max_concurrent_prompts -ge 0) {
        [int]$settings.acp_max_concurrent_prompts
    } else {
        4
    }
    if ($limit -lt 0) { $limit = 0 }
    if ($limit -gt 8) { $limit = 8 }
    return $limit
}

function Set-AcpConcurrencyLimit {
    param($Context, [int]$Limit = 4)
    if ($Limit -lt 0 -or $Limit -gt 8) {
        throw 'ACP 子代理并发上限需在 0 到 8 之间。'
    }
    $settings = Read-ConnectionSettings $Context
    $prevLimit = if (($settings.PSObject.Properties.Name -contains 'acp_max_concurrent_prompts') -and $null -ne $settings.acp_max_concurrent_prompts) {
        [int]$settings.acp_max_concurrent_prompts
    } else {
        4
    }
    if ($settings.PSObject.Properties.Name -contains 'acp_max_concurrent_prompts') {
        $settings.acp_max_concurrent_prompts = $Limit
    } else {
        $settings | Add-Member -NotePropertyName 'acp_max_concurrent_prompts' -NotePropertyValue $Limit -Force
    }
    Write-AtomicConnectionText $Context.SettingsPath ($settings | ConvertTo-Json -Depth 5)

    # Sync to official control-panel-settings.json if present
    $cpPath = if ($settings.runtime_root) { Join-Path $settings.runtime_root 'control-panel-settings.json' } else { '' }
    if ($cpPath -and (Test-Path -LiteralPath $cpPath)) {
        try {
            $cpObj = [IO.File]::ReadAllText($cpPath) | ConvertFrom-Json
            if ($cpObj.PSObject.Properties.Name -contains 'acp_max_concurrent_prompts') {
                $cpObj.acp_max_concurrent_prompts = $Limit
            } else {
                $cpObj | Add-Member -NotePropertyName 'acp_max_concurrent_prompts' -NotePropertyValue $Limit -Force
            }
            Write-AtomicConnectionText $cpPath ($cpObj | ConvertTo-Json -Depth 8)
        } catch {}
    }

    # If not isolated, apply live to running relaystudio-core
    if (-not $Context.Isolated) {
        if ($Limit -eq 0 -or $prevLimit -eq 0) {
            try { [void](Restart-LocalCoreEngine $Context $settings) } catch {}
        } else {
            try {
                $pyPatch = @"
import ctypes
from ctypes import wintypes
import os
import struct
import subprocess

PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010
PROCESS_VM_WRITE = 0x0020
PROCESS_VM_OPERATION = 0x0008
MEM_COMMIT = 0x1000

class MEMORY_BASIC_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("BaseAddress", ctypes.c_void_p),
        ("AllocationBase", ctypes.c_void_p),
        ("AllocationProtect", wintypes.DWORD),
        ("PartitionId", wintypes.WORD),
        ("RegionSize", ctypes.c_size_t),
        ("State", wintypes.DWORD),
        ("Protect", wintypes.DWORD),
        ("Type", wintypes.DWORD),
    ]

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
k32.OpenProcess.restype = wintypes.HANDLE
k32.VirtualQueryEx.argtypes = [wintypes.HANDLE, ctypes.c_void_p, ctypes.POINTER(MEMORY_BASIC_INFORMATION), ctypes.c_size_t]
k32.VirtualQueryEx.restype = ctypes.c_size_t
k32.ReadProcessMemory.argtypes = [wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
k32.ReadProcessMemory.restype = wintypes.BOOL
k32.WriteProcessMemory.argtypes = [wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
k32.WriteProcessMemory.restype = wintypes.BOOL

target_limit = $Limit
out = subprocess.check_output(["powershell", "-NoProfile", "-Command", "(Get-Process relaystudio-core -ErrorAction SilentlyContinue | Select-Object -First 1).Id"], text=True).strip()
if out.isdigit():
    core_pid = int(out)
    h = k32.OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ | PROCESS_VM_WRITE | PROCESS_VM_OPERATION, False, core_pid)
    if h:
        def read_mem(addr, size):
            buf = ctypes.create_string_buffer(size)
            n = ctypes.c_size_t(0)
            if k32.ReadProcessMemory(h, ctypes.c_void_p(addr), buf, size, ctypes.byref(n)):
                return buf.raw[:n.value]
            return b""
        def write_qword(addr, val):
            raw = struct.pack("<Q", val)
            n = ctypes.c_size_t(0)
            k32.WriteProcessMemory(h, ctypes.c_void_p(addr), raw, 8, ctypes.byref(n))
        to_pat = struct.pack("<Q", 300000000000)
        addr = 0x10000
        mbi = MEMORY_BASIC_INFORMATION()
        while addr < 0x7fffffffffff:
            res = k32.VirtualQueryEx(h, ctypes.c_void_p(addr), ctypes.byref(mbi), ctypes.sizeof(mbi))
            if not res:
                break
            base = mbi.BaseAddress or 0
            size = mbi.RegionSize
            if mbi.State == MEM_COMMIT and (mbi.Protect & 0xFF) == 0x04 and size <= 128 * 1024 * 1024:
                chunk = read_mem(base, size)
                idx = 0
                while True:
                    i = chunk.find(to_pat, idx)
                    if i == -1:
                        break
                    if i >= 104:
                        mgr = base + i - 104
                        mgr_bytes = read_mem(mgr, 272)
                        if len(mgr_bytes) == 272:
                            cur_lim = struct.unpack_from("<Q", mgr_bytes, 96)[0]
                            hchan = struct.unpack_from("<Q", mgr_bytes, 256)[0]
                            if 1 <= cur_lim <= 8 and 0x10000 <= hchan < 0x7fffffffffff:
                                hc = read_mem(hchan, 32)
                                if len(hc) == 32:
                                    qcount, dataqsiz, buf_ptr, elemsize = struct.unpack_from("<QQQH", hc, 0)
                                    if 1 <= dataqsiz <= 8 and elemsize == 0 and buf_ptr == hchan + 16:
                                        write_qword(hchan + 8, target_limit)
                                        write_qword(mgr + 96, target_limit)
                    idx = i + 1
            addr = base + size
"@
                $tmpPy = Join-Path $Context.DataRoot 'set_acp_limit_temp.py'
                [IO.File]::WriteAllText($tmpPy, $pyPatch, (New-Object Text.UTF8Encoding($false)))
                try {
                    $pyCmd = Get-PythonLauncherPath
                    if ($pyCmd) {
                        Start-Process -FilePath $pyCmd -ArgumentList @($tmpPy) -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
                    }
                } finally {
                    if (Test-Path -LiteralPath $tmpPy) { Remove-Item -LiteralPath $tmpPy -Force -ErrorAction SilentlyContinue }
                }
            } catch {}
        }
    }
    return [pscustomobject]@{
        Limit = $Limit
        Applied = $true
    }
}

$script:DetectedCliAgentsCache = $null
$script:DetectedCliAgentsCacheSig = ''

function Get-DetectedCliAgents {
    param(
        [switch]$ForceRescan,
        $Settings = $null,
        $Context = $null
    )
    if ((-not $Settings) -and $Context) {
        try { $Settings = Read-ConnectionSettings $Context } catch {}
    }
    $extraDirs = @()
    if ($Settings -and $Settings.PSObject.Properties['extra_bin_dirs'] -and $Settings.extra_bin_dirs) {
        $extraDirs += @($Settings.extra_bin_dirs | ForEach-Object { [string]$_ } | Where-Object { $_ })
    }
    $customArr = @()
    if ($Settings -and $Settings.PSObject.Properties['custom_cli_agents'] -and $Settings.custom_cli_agents) {
        $customArr = @($Settings.custom_cli_agents)
    }
    $customSig = (@($customArr | ForEach-Object { "$($_.id)|$($_.command)" }) -join ';')
    $sig = (($extraDirs -join ';') + '||' + $customSig)
    if ((-not $ForceRescan) -and $null -ne $script:DetectedCliAgentsCache -and $script:DetectedCliAgentsCacheSig -eq $sig) {
        return $script:DetectedCliAgentsCache
    }

    $searchDirs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($ed in $extraDirs) {
        if ($ed -and -not $searchDirs.Contains($ed)) { [void]$searchDirs.Add($ed) }
    }
    foreach ($fixedDir in @(
        'D:\Dev\npm-global',
        $(if ($env:APPDATA) { Join-Path $env:APPDATA 'npm' } else { '' }),
        'D:\Dev\antigravity-cli\bin',
        'D:\workbuddy'
    )) {
        if ($fixedDir -and -not $searchDirs.Contains($fixedDir)) { [void]$searchDirs.Add($fixedDir) }
    }
    if ($env:PATH) {
        foreach ($pd in ($env:PATH -split ';')) {
            $pt = if ($pd) { $pd.Trim() } else { '' }
            if ($pt -and -not $searchDirs.Contains($pt)) { [void]$searchDirs.Add($pt) }
        }
    }

    $findBin = {
        param([string[]]$CandidateNames)
        foreach ($cn in $CandidateNames) {
            foreach ($dir in $searchDirs) {
                try {
                    $full = [IO.Path]::Combine($dir, $cn)
                    if ([IO.File]::Exists($full)) { return $full }
                } catch {}
            }
        }
        return ''
    }

    $results = New-Object 'System.Collections.Generic.List[object]'
    $seenIds = @{}

    $codexPath = & $findBin @('codex-acp.cmd', 'codex.cmd', 'codex.exe')
    if ($codexPath) {
        $seenIds['codex'] = $true
        [void]$results.Add([pscustomobject]@{
            id = 'codex'; display_name = 'Codex'; kind = 'codex'; command = $codexPath; args = @(); is_custom = $false
        })
    }

    $claudePath = & $findBin @('claude-agent-acp.cmd', 'claude.cmd', 'claude.exe')
    if ($claudePath) {
        $seenIds['claude'] = $true
        [void]$results.Add([pscustomobject]@{
            id = 'claude'; display_name = 'Claude'; kind = 'claude'; command = $claudePath; args = @(); is_custom = $false
        })
    }

    $wbCmdPath = & $findBin @('codebuddy.cmd')
    $wbExePath = if (-not $wbCmdPath) { & $findBin @('WorkBuddy.exe') } else { '' }
    if ($wbCmdPath) {
        $seenIds['workbuddy'] = $true
        [void]$results.Add([pscustomobject]@{
            id = 'workbuddy'; display_name = 'WorkBuddy'; kind = 'custom'; command = $wbCmdPath; args = @('--acp'); is_custom = $false
        })
    } elseif ($wbExePath) {
        $seenIds['workbuddy'] = $true
        [void]$results.Add([pscustomobject]@{
            id = 'workbuddy'; display_name = 'WorkBuddy'; kind = 'custom'; command = $wbExePath; args = @(); is_custom = $false
        })
    }

    $agyPath = & $findBin @('agy.exe', 'agy-node.cmd', 'agy.cmd')
    if ($agyPath) {
        $seenIds['agy'] = $true
        [void]$results.Add([pscustomobject]@{
            id = 'agy'; display_name = 'AGY'; kind = 'custom'; command = $agyPath; args = @(); is_custom = $false
        })
    }

    foreach ($c in $customArr) {
        if (-not $c) { continue }
        $cId = if ($c.PSObject.Properties['id'] -and $c.id) { ([string]$c.id).Trim() } else { '' }
        $cCmd = if ($c.PSObject.Properties['command'] -and $c.command) { ([string]$c.command).Trim() } else { '' }
        if (-not $cId -or -not $cCmd -or $seenIds.ContainsKey($cId)) { continue }
        if (-not [IO.File]::Exists($cCmd)) { continue }
        $cDisp = if ($c.PSObject.Properties['display_name'] -and $c.display_name) { ([string]$c.display_name).Trim() } else { $cId }
        $rawCKind = if ($c.PSObject.Properties['kind'] -and $c.kind) { ([string]$c.kind).Trim().ToLowerInvariant() } else { 'custom' }
        $cKind = if ($rawCKind -in @('codex', 'claude')) { $rawCKind } else { 'custom' }
        $cArgs = @(if ($c.PSObject.Properties['args'] -and $c.args) { $c.args | ForEach-Object { [string]$_ } })
        $seenIds[$cId] = $true
        [void]$results.Add([pscustomobject]@{
            id = $cId; display_name = $cDisp; kind = $cKind; command = $cCmd; args = $cArgs; is_custom = $true
        })
    }

    $finalArr = @($results.ToArray())
    $script:DetectedCliAgentsCache = $finalArr
    $script:DetectedCliAgentsCacheSig = $sig
    return $finalArr
}
Set-Alias -Name Discover-LocalCliAgents -Value Get-DetectedCliAgents

function Add-CustomCliAgent {
    param(
        $Context,
        [string]$CommandPath,
        [string]$DisplayName = '',
        [string[]]$Args = @()
    )
    $cleanPath = if ($CommandPath) { $CommandPath.Trim() } else { '' }
    if (-not $cleanPath -or -not (Test-Path -LiteralPath $cleanPath)) {
        throw "未找到指定的 CLI 可执行文件：$cleanPath"
    }
    $fullPath = [IO.Path]::GetFullPath($cleanPath)
    $baseName = [IO.Path]::GetFileNameWithoutExtension($fullPath)
    $idSlug = (($baseName.ToLowerInvariant() -replace '[^a-z0-9_-]', '-').Trim('-'))
    if (-not $idSlug) { $idSlug = 'custom-cli' }
    $disp = if ($DisplayName -and $DisplayName.Trim()) { $DisplayName.Trim() } else { $baseName }
    $settings = Read-ConnectionSettings $Context
    $existing = @(if ($settings.PSObject.Properties['custom_cli_agents'] -and $settings.custom_cli_agents) { $settings.custom_cli_agents })
    $filtered = @($existing | Where-Object { $_ -and [string]$_.id -ne $idSlug })
    $newEntry = [pscustomobject]@{
        id = $idSlug
        display_name = $disp
        kind = 'custom'
        command = $fullPath
        args = @($Args)
    }
    $updatedList = @($filtered) + @($newEntry)
    $settings | Add-Member -NotePropertyName 'custom_cli_agents' -NotePropertyValue $updatedList -Force
    Write-AtomicConnectionText $Context.SettingsPath ($settings | ConvertTo-Json -Depth 6)
    $agents = @(Get-DetectedCliAgents -ForceRescan -Settings $settings -Context $Context)
    return [pscustomobject]@{
        AddedAgent = $newEntry
        Agents = $agents
        Settings = $settings
    }
}

function Get-CoreEngineConfig {
    param($Context)
    $settings = Read-ConnectionSettings $Context
    $corePort = if (($settings.PSObject.Properties.Name -contains 'core_port') -and [int]$settings.core_port -gt 0) { [int]$settings.core_port } else { 8765 }
    $acpProf = if (($settings.PSObject.Properties.Name -contains 'acp_default_profile') -and [string]$settings.acp_default_profile) { ([string]$settings.acp_default_profile).Trim() } else { 'codex' }
    $browserEn = if ($settings.PSObject.Properties.Name -contains 'browser_enabled') { [bool]$settings.browser_enabled } else { $true }
    $startupMode = if (($settings.PSObject.Properties.Name -contains 'startup_mode') -and [string]$settings.startup_mode -in @('popup','tray','off')) { [string]$settings.startup_mode } else { 'tray' }
    $autoArchiveMode = if (($settings.PSObject.Properties.Name -contains 'auto_archive_completed_mode') -and [string]$settings.auto_archive_completed_mode -in @('immediate','1d','3d','7d','off')) { [string]$settings.auto_archive_completed_mode } else { '3d' }
    $defCarrier = Resolve-RelayBrowserProfile '' $Context
    return [pscustomobject]@{
        CorePort = $corePort
        AcpDefaultProfile = $acpProf
        AcpMaxConcurrentPrompts = (Get-AcpConcurrencyLimit $Context)
        BrowserEnabled = $browserEn
        StartupMode = $startupMode
        AutoArchiveCompletedMode = $autoArchiveMode
        DefaultBrowserProfile = $defCarrier
        Settings = $settings
    }
}

function Set-CoreEngineConfig {
    param(
        $Context,
        [string]$AcpDefaultProfile = '',
        $BrowserEnabled = $null,
        [string]$StartupMode = '',
        [string]$AutoArchiveCompletedMode = '',
        [string]$DefaultBrowserProfile = '',
        [switch]$ApplyStartup
    )
    $settings = Read-ConnectionSettings $Context
    if ($AcpDefaultProfile -and $AcpDefaultProfile.Trim()) {
        $cleanAcp = $AcpDefaultProfile.Trim()
        if ($settings.PSObject.Properties.Name -contains 'acp_default_profile') {
            $settings.acp_default_profile = $cleanAcp
        } else {
            $settings | Add-Member -NotePropertyName 'acp_default_profile' -NotePropertyValue $cleanAcp -Force
        }
    }
    if ($null -ne $BrowserEnabled) {
        $bVal = [bool]$BrowserEnabled
        if ($settings.PSObject.Properties.Name -contains 'browser_enabled') {
            $settings.browser_enabled = $bVal
        } else {
            $settings | Add-Member -NotePropertyName 'browser_enabled' -NotePropertyValue $bVal -Force
        }
    }
    if ($StartupMode -in @('popup','tray','off')) {
        if ($settings.PSObject.Properties.Name -contains 'startup_mode') {
            $settings.startup_mode = $StartupMode
        } else {
            $settings | Add-Member -NotePropertyName 'startup_mode' -NotePropertyValue $StartupMode -Force
        }
    }
    if ($AutoArchiveCompletedMode -in @('immediate','1d','3d','7d','off')) {
        if ($settings.PSObject.Properties.Name -contains 'auto_archive_completed_mode') {
            $settings.auto_archive_completed_mode = $AutoArchiveCompletedMode
        } else {
            $settings | Add-Member -NotePropertyName 'auto_archive_completed_mode' -NotePropertyValue $AutoArchiveCompletedMode -Force
        }
        [void](Invoke-StudioHubAction -Context $Context -Payload @{ action = 'set_global_settings'; auto_archive_completed_mode = $AutoArchiveCompletedMode })
    }
    if ($DefaultBrowserProfile -and $DefaultBrowserProfile.Trim()) {
        $cleanDefProf = $DefaultBrowserProfile.Trim()
        if ($settings.PSObject.Properties.Name -contains 'default_browser_profile') {
            $settings.default_browser_profile = $cleanDefProf
        } else {
            $settings | Add-Member -NotePropertyName 'default_browser_profile' -NotePropertyValue $cleanDefProf -Force
        }
        $script:BrowserProfilesCache = $null
        [void](Invoke-StudioHubAction -Context $Context -Payload @{ action = 'set_global_settings'; default_browser_profile = $cleanDefProf })
    }
    Write-AtomicConnectionText $Context.SettingsPath ($settings | ConvertTo-Json -Depth 6)

    # Sync to legacy control-panel-settings.json if present
    $cpPath = if ($settings.runtime_root) { Join-Path $settings.runtime_root 'control-panel-settings.json' } else { '' }
    if ($cpPath -and (Test-Path -LiteralPath $cpPath)) {
        try {
            $cpObj = [IO.File]::ReadAllText($cpPath) | ConvertFrom-Json
            if ($AcpDefaultProfile -and $AcpDefaultProfile.Trim()) {
                if ($cpObj.PSObject.Properties.Name -contains 'acp_default_profile') { $cpObj.acp_default_profile = $AcpDefaultProfile.Trim() }
                else { $cpObj | Add-Member -NotePropertyName 'acp_default_profile' -NotePropertyValue $AcpDefaultProfile.Trim() -Force }
            }
            if ($null -ne $BrowserEnabled) {
                if ($cpObj.PSObject.Properties.Name -contains 'browser_enabled') { $cpObj.browser_enabled = [bool]$BrowserEnabled }
                else { $cpObj | Add-Member -NotePropertyName 'browser_enabled' -NotePropertyValue ([bool]$BrowserEnabled) -Force }
            }
            Write-AtomicConnectionText $cpPath ($cpObj | ConvertTo-Json -Depth 8)
        } catch {}
    }

    # Sync Windows startup registry if not isolated and StartupMode was specified
    if (-not $Context.Isolated -and $StartupMode -in @('popup','tray','off')) {
        try {
            $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            $exePath = if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'RelayStudio.exe'))) {
                Join-Path $PSScriptRoot 'RelayStudio.exe'
            } elseif (Test-Path -LiteralPath (Join-Path $Context.ReleaseRoot 'RelayStudio.exe')) {
                Join-Path $Context.ReleaseRoot 'RelayStudio.exe'
            } else {
                Join-Path $PSScriptRoot 'RelayStudio.exe'
            }
            if ($StartupMode -eq 'off') {
                Remove-ItemProperty -Path $runKey -Name 'RelayStudio' -ErrorAction SilentlyContinue
            } elseif ($StartupMode -eq 'tray') {
                Set-ItemProperty -Path $runKey -Name 'RelayStudio' -Value ('"' + $exePath + '" --minimized') -ErrorAction SilentlyContinue
            } elseif ($StartupMode -eq 'popup') {
                Set-ItemProperty -Path $runKey -Name 'RelayStudio' -Value ('"' + $exePath + '"') -ErrorAction SilentlyContinue
            }
        } catch {}
    }
    return (Get-CoreEngineConfig $Context)
}

function Get-RelayStartupMode {
    param($Context)
    return (Get-CoreEngineConfig $Context).StartupMode
}

function Set-RelayStartupMode {
    param($Context, [string]$Mode = 'tray')
    return (Set-CoreEngineConfig -Context $Context -StartupMode $Mode)
}

function Repair-RelayProcessPriority {
    param($Context, $Settings)
    if ($Context.Isolated) { return $false }
    Get-Process -Name 'relaystudio-core','python','node' -ErrorAction SilentlyContinue | ForEach-Object {
        try { if ($_.BasePriority -lt 8) { $_.PriorityClass = 'Normal' } } catch {}
    }
    return $true
}

function Test-ShouldRunUiRefreshTimer {
    param(
        [bool]$IsVisible = $true,
        $WindowState = 'Normal',
        [bool]$IsActive = $false,
        [bool]$Busy = $false
    )
    if ($Busy) { return $false }
    if (-not $IsVisible) { return $false }
    if ([string]$WindowState -eq 'Minimized') { return $false }
    return $true
}


$script:DarkThemeColorMap = @{
    '#F3F4F6'   = '#111114'
    '#F4F4F6'   = '#111114'
    '#FFFFFF'   = '#18181B'
    'WHITE'     = '#18181B'
    '#FAFAFA'   = '#202025'
    '#F8FAFC'   = '#202025'
    '#FCFCFD'   = '#202025'
    '#F4F4F5'   = '#27272A'
    '#EFEFF1'   = '#27272A'
    '#EEF2F6'   = '#27272A'
    '#E4E4E7'   = '#2E2E34'
    '#E2E8F0'   = '#2E2E34'
    '#F1F1F4'   = '#25252B'
    '#D4D4D8'   = '#3F3F46'
    '#CBD5E1'   = '#3F3F46'
    '#18181B'   = '#F4F4F5'
    '#09090B'   = '#F4F4F5'
    '#3F3F46'   = '#D4D4D8'
    '#475569'   = '#D4D4D8'
    '#505D70'   = '#D4D4D8'
    '#52525B'   = '#A1A1AA'
    '#71717A'   = '#9CA3AF'
    '#A1A1AA'   = '#71717A'
    # Dedicated semantic tokens: #FEFEFF (BadgeForegroundWhite: always-white ink on solid blue/dark badges)
    # and #18181F (BadgeSurfaceDark: dark pill/badge fill that stays dark #27272A in Dark Mode instead of inverting to light text)
    '#FEFEFF'              = '#FFFFFF'
    'BADGEFOREGROUNDWHITE' = '#FFFFFF'
    '#18181F'              = '#27272A'
    'BADGESURFACEDARK'     = '#27272A'
    '#27272A'   = '#3F3F46'
    '#EFF6FF'   = '#172554'
    '#EFF4FC'   = '#172554'
    '#DBEAFE'   = '#1E3A8A'
    '#BFDBFE'   = '#1E3A8A'
    '#93C5FD'   = '#2563EB'
    '#1E3A8A'   = '#93C5FD'
    '#1E40AF'   = '#93C5FD'
    '#1D4ED8'   = '#60A5FA'
    '#234975'   = '#93C5FD'
    '#2563EB'   = '#2563EB'
    '#3B82F6'   = '#3B82F6'
    '#60A5FA'   = '#60A5FA'
    '#DCFCE7'   = '#052E16'
    '#F0FDF4'   = '#052E16'
    '#BBF7D0'   = '#14532D'
    '#86EFAC'   = '#166534'
    '#166534'   = '#4ADE80'
    '#15803D'   = '#4ADE80'
    '#14532D'   = '#86EFAC'
    '#16A34A'   = '#22C55E'
    '#22C55E'   = '#22C55E'
    '#FEF2F2'   = '#3B1219'
    '#FEE2E2'   = '#3B1219'
    '#FDEDE9'   = '#3B1219'
    '#FECACA'   = '#7F1D1D'
    '#991B1B'   = '#FCA5A5'
    '#B91C1C'   = '#FCA5A5'
    '#B42318'   = '#F87171'
    '#8A241C'   = '#FCA5A5'
    '#DC2626'   = '#F87171'
    '#EF4444'   = '#EF4444'
    '#FFFBEB'   = '#3B2106'
    '#FEF3C7'   = '#3B2106'
    '#FDE68A'   = '#78350F'
    '#92400E'   = '#FCD34D'
    '#9A3412'   = '#FCD34D'
    '#B45309'   = '#B45309'
    '#D97706'   = '#D97706'
    '#F59E0B'   = '#F59E0B'
    '#2871717A' = '#44A1A1AA'
    '#6671717A' = '#88A1A1AA'
    '#6618181B' = '#99050507'
    '#9918181B' = '#B8050507'
    '#E618181B' = '#E627272A'
}

$script:LightThemeColorMap = @{
    'WHITE'                = '#FFFFFF'
    '#FEFEFF'              = '#FFFFFF'
    'BADGEFOREGROUNDWHITE' = '#FFFFFF'
    '#18181F'              = '#18181B'
    'BADGESURFACEDARK'     = '#18181B'
}

function Resolve-NormalizedThemeMode {
    param([string]$ThemeMode = 'system')
    $norm = ([string]$ThemeMode).Trim().ToLowerInvariant()
    if ($norm -in @('system', 'light', 'dark')) {
        return $norm
    }
    return 'system'
}

function Get-SystemThemePreference {
    param([Nullable[int]]$RegistryValue = $null)
    if ($null -ne $RegistryValue) {
        return $(if ([int]$RegistryValue -eq 0) { 'dark' } else { 'light' })
    }
    try {
        $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        if (Test-Path -LiteralPath $regPath) {
            $prop = Get-ItemProperty -LiteralPath $regPath -Name 'AppsUseLightTheme' -ErrorAction SilentlyContinue
            if ($null -ne $prop -and $prop.PSObject.Properties.Name -contains 'AppsUseLightTheme') {
                return $(if ([int]$prop.AppsUseLightTheme -eq 0) { 'dark' } else { 'light' })
            }
        }
    } catch {}
    return 'light'
}

function Resolve-EffectiveTheme {
    param(
        [string]$ThemeMode = 'system',
        [string]$SystemTheme = ''
    )
    $norm = Resolve-NormalizedThemeMode $ThemeMode
    if ($norm -eq 'dark') { return 'dark' }
    if ($norm -eq 'light') { return 'light' }
    $sys = ([string]$SystemTheme).Trim().ToLowerInvariant()
    if ($sys -in @('light', 'dark')) {
        return $sys
    }
    return (Get-SystemThemePreference)
}

function Step-QuickThemeToggle {
    param(
        [string]$CurrentThemeMode = 'system',
        [string]$EffectiveTheme = 'light',
        [string]$Action = 'invert'
    )
    $act = ([string]$Action).Trim().ToLowerInvariant()
    if ($act -in @('system', 'light', 'dark')) {
        return $act
    }
    $eff = ([string]$EffectiveTheme).Trim().ToLowerInvariant()
    if ($eff -notin @('light', 'dark')) {
        $eff = Resolve-EffectiveTheme -ThemeMode $CurrentThemeMode
    }
    return $(if ($eff -eq 'dark') { 'light' } else { 'dark' })
}

function Resolve-ThemeColorHex {
    param(
        [string]$Hex,
        [string]$Theme = 'light'
    )
    if (-not $Hex) { return 'Transparent' }
    $trimmed = $Hex.Trim()
    $upper = $trimmed.ToUpperInvariant()
    if ($upper -eq 'TRANSPARENT') { return 'Transparent' }
    $isDark = (([string]$Theme).Trim().ToLowerInvariant() -eq 'dark')
    if ($isDark) {
        if ($script:DarkThemeColorMap.ContainsKey($upper)) {
            return $script:DarkThemeColorMap[$upper]
        }
        return $trimmed
    } else {
        if ($script:LightThemeColorMap.ContainsKey($upper)) {
            return $script:LightThemeColorMap[$upper]
        }
        return $trimmed
    }
}

Export-ModuleMember -Function *-* -Alias *
