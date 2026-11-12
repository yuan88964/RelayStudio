$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
$hostBridgePath = Join-Path $repoRoot 'HostBridge.ps1'
$buildLauncherPath = Join-Path $repoRoot 'scripts\build-launcher.ps1'
$buildReleasePath = Join-Path $repoRoot 'scripts\build-release.ps1'
$selfTestPath = $MyInvocation.MyCommand.Path

$script:PassCount = 0
$script:FailCount = 0

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        $script:FailCount++
        throw "ASSERTION FAILED: $Message"
    }
    $script:PassCount++
}

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [string]$Message
    )
    if ($Actual -ne $Expected) {
        $script:FailCount++
        throw "ASSERTION FAILED: $Message (Expected='$Expected', Actual='$Actual')"
    }
    $script:PassCount++
}

function Invoke-TestRpc {
    param(
        [string]$Method,
        $Params = @{},
        [string]$Id = ('test_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    )
    $reqJson = ([ordered]@{
        type   = 'rpc_request'
        id     = $Id
        method = $Method
        params = $Params
    } | ConvertTo-Json -Depth 10 -Compress)
    $rawJson = Invoke-RelayHostRpc -RequestJson $reqJson
    $parsed = $rawJson | ConvertFrom-Json
    return [pscustomobject]@{
        RawJson  = $rawJson
        Envelope = $parsed
    }
}

$origEnvToken = $env:RELAYSTUDIO_LOCAL_TOKEN
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('relay-hostbridge-test-' + [Guid]::NewGuid().ToString('N'))
$testDataRoot = Join-Path $tempRoot 'data'
[IO.Directory]::CreateDirectory($testDataRoot) | Out-Null

try {
    Write-Host '=== RelayStudio HostBridge & WebView2 Launcher Test Suite ==='

    # 1. UTF-8 BOM & PowerShell 5.1 AST Parse Verification
    $w2Files = @($hostBridgePath, $buildLauncherPath, $buildReleasePath, $selfTestPath)
    foreach ($filePath in $w2Files) {
        Assert-True (Test-Path -LiteralPath $filePath) "W2 file exists: $filePath"
        $bytes = [IO.File]::ReadAllBytes($filePath)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        Assert-True $hasBom "UTF-8 BOM (0xEF 0xBB 0xBF) preserved on: $filePath"

        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($filePath, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal @($parseErrors).Count 0 "Zero PowerShell AST syntax errors in: $filePath"
    }

    $releaseText = [IO.File]::ReadAllText($buildReleasePath, [Text.Encoding]::UTF8)
    Assert-True ($releaseText -match 'HostBridge\.ps1') 'build-release.ps1 stages HostBridge.ps1'
    Assert-True ($releaseText -match 'cloudflared\.exe') 'build-release.ps1 stages bin\cloudflared.exe'
    Assert-True ($releaseText -match 'webview2') 'build-release.ps1 stages bin\webview2\*.dll'
    Assert-True ($releaseText -match "'ui'") 'build-release.ps1 stages ui directory'

    $launcherText = [IO.File]::ReadAllText($buildLauncherPath, [Text.Encoding]::UTF8)
    Assert-True ($launcherText -match 'nuget\.org/api/v2/package/Microsoft\.Web\.WebView2') 'build-launcher.ps1 includes NuGet WebView2 auto-download fallback'

    $exePath = Join-Path $repoRoot 'RelayStudio.exe'
    Assert-True (Test-Path -LiteralPath $exePath) 'RelayStudio.exe exists in repository root'
    $rootDlls = @(Get-ChildItem -Path $repoRoot -Filter '*.dll' -File -ErrorAction SilentlyContinue)
    Assert-Equal $rootDlls.Count 0 'Zero extra DLLs placed in repository root'

    # 2. Dot-source HostBridge.ps1 & Initialize-RelayHostBridge (-Isolated -SkipBootServices)
    . $hostBridgePath
    $initRes = Initialize-RelayHostBridge -BaseDirectory $repoRoot -DataRoot $testDataRoot -Isolated -SkipBootServices
    Assert-True ([bool]$initRes.Ok) 'Initialize-RelayHostBridge returns Ok=true'
    Assert-True ([bool]$initRes.Isolated) 'Initialize-RelayHostBridge sets Isolated=true'
    Assert-True ([bool]$initRes.SkipBootServices) 'Initialize-RelayHostBridge sets SkipBootServices=true'

    $tokenFile = Join-Path $testDataRoot 'studio-local.token'
    Assert-True (Test-Path -LiteralPath $tokenFile) 'studio-local.token created in DataRoot'
    $tokBytes = [IO.File]::ReadAllBytes($tokenFile)
    $tokHasBom = ($tokBytes.Length -ge 3 -and $tokBytes[0] -eq 0xEF -and $tokBytes[1] -eq 0xBB -and $tokBytes[2] -eq 0xBF)
    Assert-True (-not $tokHasBom) 'studio-local.token written as UTF-8 without BOM'
    $diskToken = ([IO.File]::ReadAllText($tokenFile, [Text.Encoding]::UTF8)).Trim()
    Assert-True ($diskToken -match '^[0-9a-f]{32}$') 'studio-local.token is a 32-hex token'
    Assert-Equal $env:RELAYSTUDIO_LOCAL_TOKEN $diskToken 'RELAYSTUDIO_LOCAL_TOKEN env synced to studio-local.token'

    # Re-initialize preserves same token
    [void](Initialize-RelayHostBridge -BaseDirectory $repoRoot -DataRoot $testDataRoot -Isolated -SkipBootServices)
    $diskToken2 = ([IO.File]::ReadAllText($tokenFile, [Text.Encoding]::UTF8)).Trim()
    Assert-Equal $diskToken2 $diskToken 'Re-initializing HostBridge preserves existing studio-local.token'

    # 3. get_fast_bootstrap (<500ms cold, <80ms warm), boot_init & get_infra_bundle Contract
    $swFastCold = [Diagnostics.Stopwatch]::StartNew()
    $fastBootCall = Invoke-TestRpc -Method 'get_fast_bootstrap' -Id 'rpc_fast_boot_1'
    $swFastCold.Stop()
    Assert-Equal $fastBootCall.Envelope.type 'rpc_response' 'get_fast_bootstrap envelope type'
    Assert-Equal $fastBootCall.Envelope.id 'rpc_fast_boot_1' 'get_fast_bootstrap envelope id'
    Assert-True ([bool]$fastBootCall.Envelope.ok) 'get_fast_bootstrap ok=true'
    Assert-True ($swFastCold.Elapsed.TotalMilliseconds -lt 500.0) "get_fast_bootstrap cold finishes under 500ms (Actual=$([Math]::Round($swFastCold.Elapsed.TotalMilliseconds, 2))ms)"
    $fastBootInfra = $fastBootCall.Envelope.result
    Assert-Equal $fastBootInfra.shieldBaseUrl 'http://127.0.0.1:8766' 'get_fast_bootstrap shieldBaseUrl'
    Assert-Equal $fastBootInfra.studioToken $diskToken 'get_fast_bootstrap studioToken matches'
    Assert-True ($null -ne $fastBootInfra.profiles) 'get_fast_bootstrap includes valid profiles'
    Assert-True ($null -ne $fastBootInfra.layout) 'get_fast_bootstrap includes valid layout'

    # Clear $script:StudioToken in memory and verify get_fast_bootstrap reloads studio-local.token from disk
    $script:StudioToken = ''
    $swFastWarm = [Diagnostics.Stopwatch]::StartNew()
    $fastBootWarmCall = Invoke-TestRpc -Method 'get_fast_bootstrap' -Id 'rpc_fast_boot_2'
    $swFastWarm.Stop()
    Assert-True ([bool]$fastBootWarmCall.Envelope.ok) 'warm get_fast_bootstrap ok=true'
    Assert-Equal $fastBootWarmCall.Envelope.result.studioToken $diskToken 'get_fast_bootstrap reloads studio-local.token when empty'
    Assert-True ($swFastWarm.Elapsed.TotalMilliseconds -lt 80.0) "warm get_fast_bootstrap finishes under 80ms (Actual=$([Math]::Round($swFastWarm.Elapsed.TotalMilliseconds, 2))ms)"

    $bootCall = Invoke-TestRpc -Method 'boot_init' -Id 'rpc_boot_1'
    Assert-Equal $bootCall.Envelope.type 'rpc_response' 'boot_init envelope type'
    Assert-Equal $bootCall.Envelope.id 'rpc_boot_1' 'boot_init envelope id'
    Assert-True ([bool]$bootCall.Envelope.ok) 'boot_init ok=true'
    $bootInfra = $bootCall.Envelope.result
    Assert-Equal $bootInfra.shieldBaseUrl 'http://127.0.0.1:8766' 'boot_init shieldBaseUrl'
    Assert-Equal $bootInfra.studioToken $diskToken 'boot_init studioToken matches'
    Assert-True ($null -ne $bootInfra.profiles) 'boot_init includes profiles bundle'
    Assert-True ($null -ne $bootInfra.publicTunnel) 'boot_init includes publicTunnel state'
    Assert-True ($null -ne $bootInfra.display) 'boot_init includes display summary'
    Assert-True ($bootInfra.display.PSObject.Properties.Name -contains 'RunningProfileId') 'display summary includes RunningProfileId'
    Assert-True ($bootInfra.display.PSObject.Properties.Name -contains 'RunningTunnelId') 'display summary includes RunningTunnelId'
    Assert-Equal $bootInfra.display.RunningProfileId '' 'offline display RunningProfileId is empty'
    Assert-Equal $bootInfra.display.RunningTunnelId '' 'offline display RunningTunnelId is empty'
    $deskCarrier = @($bootInfra.browserProfiles | Where-Object { $_.Id -eq 'Desktop:ChatGPT' }) | Select-Object -First 1
    Assert-True ($null -ne $deskCarrier) 'browserProfiles includes Desktop:ChatGPT carrier'
    Assert-Equal $deskCarrier.Label 'ChatGPT 桌面端' 'Desktop:ChatGPT carrier has clean label ChatGPT 桌面端'
    Assert-True ($null -ne $bootInfra.layout) 'boot_init includes layout memory'
    Assert-True ($null -ne $bootInfra.engineConfig) 'boot_init includes engineConfig'

    # Warm latency benchmark for get_infra_bundle
    [void](Invoke-TestRpc -Method 'get_infra_bundle')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $fastBundleCall = Invoke-TestRpc -Method 'get_infra_bundle'
    $sw.Stop()
    Assert-True ([bool]$fastBundleCall.Envelope.ok) 'warm get_infra_bundle ok=true'
    Assert-True ($sw.Elapsed.TotalMilliseconds -lt 80.0) "warm get_infra_bundle finishes fast (Actual=$([Math]::Round($sw.Elapsed.TotalMilliseconds, 2))ms)"

    # 4. Security Redaction (PlainKey MUST NEVER appear in raw JSON)
    $secretOpenAiKey = 'sk-proj-UltraSecretUnitKey9876543210ABCDEF'
    $secretCfToken = 'eyJhSecretCloudflareNamedToken999888777'
    $validTunnelId = 'tunnel_0123456789abcdef0123456789abcdef'

    $saveOpenAiCall = Invoke-TestRpc -Method 'profile_save' -Params @{
        profileId  = 'prof_primary'
        name       = '主力测试号'
        platform   = 'chatgpt'
        kind       = 'tunnel'
        tunnelId   = $validTunnelId
        apiKey     = $secretOpenAiKey
        apiBaseUrl = 'https://api.openai.com/v1'
        activate   = $true
    }
    Assert-True ([bool]$saveOpenAiCall.Envelope.ok) 'profile_save OpenAI profile ok=true'
    Assert-True ($saveOpenAiCall.RawJson -notmatch '(?i)PlainKey') 'profile_save raw JSON contains NO PlainKey field'
    Assert-True (-not $saveOpenAiCall.RawJson.Contains($secretOpenAiKey)) 'profile_save raw JSON redacts secret OpenAI key'

    $savedProf = $saveOpenAiCall.Envelope.result.profiles.Profiles | Where-Object { $_.Id -eq 'prof_primary' } | Select-Object -First 1
    Assert-True ($null -ne $savedProf) 'prof_primary exists in returned safe profiles'
    Assert-True ([bool]$savedProf.HasKey) 'prof_primary HasKey=true'
    Assert-True ($savedProf.MaskedKey -match '••••') 'prof_primary MaskedKey is masked'
    Assert-Equal $savedProf.TunnelId $validTunnelId 'prof_primary TunnelId persisted'
    Assert-True (-not ($savedProf.PSObject.Properties.Name -contains 'PlainKey')) 'SafeConnectionProfile has no PlainKey property'

    # Updating profile name with blank apiKey (without clearKey) preserves existing DPAPI key
    $renameProfCall = Invoke-TestRpc -Method 'profile_save' -Params @{
        profileId = 'prof_primary'
        name      = '主力号已改名'
        platform  = 'chatgpt'
        kind      = 'tunnel'
        tunnelId  = $validTunnelId
        apiKey    = ''
    }
    Assert-True ([bool]$renameProfCall.Envelope.ok) 'profile_save rename with blank apiKey ok=true'
    $renamedProf = $renameProfCall.Envelope.result.profiles.Profiles | Where-Object { $_.Id -eq 'prof_primary' } | Select-Object -First 1
    Assert-Equal $renamedProf.Name '主力号已改名' 'Profile Name updated'
    Assert-True ([bool]$renamedProf.HasKey) 'Existing DPAPI key preserved when apiKey is blank'

    # Add Gemini platform + save secret public tunnel token & check PlainKey redaction across RPCs
    $addGemCall = Invoke-TestRpc -Method 'capsule_add_platform' -Params @{ platform = 'gemini' }
    Assert-True ([bool]$addGemCall.Envelope.ok) 'capsule_add_platform gemini ok=true'
    Assert-True (@($addGemCall.Envelope.result.profiles.EnabledPlatforms) -contains 'gemini') 'gemini in EnabledPlatforms'

    $saveGemCall = Invoke-TestRpc -Method 'profile_save' -Params @{
        profileId = 'prof_gemini_default'
        name      = 'Gemini Funnel'
        platform  = 'gemini'
        kind      = 'public_tunnel'
        baseUrl   = 'https://unit-box.tailnet.ts.net'
        apiKey    = $secretCfToken
        activate  = $true
    }
    Assert-True ([bool]$saveGemCall.Envelope.ok) 'profile_save gemini ok=true'

    foreach ($checkMethod in @('get_fast_bootstrap', 'get_infra_bundle', 'boot_init')) {
        $chk = Invoke-TestRpc -Method $checkMethod
        Assert-True ($chk.RawJson -notmatch '(?i)PlainKey') "$checkMethod raw JSON contains NO PlainKey"
        Assert-True (-not $chk.RawJson.Contains($secretOpenAiKey)) "$checkMethod raw JSON does not leak OpenAI key"
        Assert-True (-not $chk.RawJson.Contains($secretCfToken)) "$checkMethod raw JSON does not leak Cloudflare token"
    }

    # Explicit profile_get_secret verification (saved DPAPI key + default 'relaystudio' OAuth fallback)
    $secOpenAi = Invoke-TestRpc -Method 'profile_get_secret' -Params @{ profileId = 'prof_primary' }
    Assert-True ([bool]$secOpenAi.Envelope.ok) 'profile_get_secret OpenAI ok=true'
    Assert-Equal $secOpenAi.Envelope.result.secret $secretOpenAiKey 'profile_get_secret returns decrypted DPAPI OpenAI key'
    Assert-Equal ([bool]$secOpenAi.Envelope.result.isDefaultOAuth) $false 'profile_get_secret OpenAI isDefaultOAuth=false'

    $secGem = Invoke-TestRpc -Method 'profile_get_secret' -Params @{ profileId = 'prof_gemini_default' }
    Assert-True ([bool]$secGem.Envelope.ok) 'profile_get_secret gemini custom token ok=true'
    Assert-Equal $secGem.Envelope.result.secret $secretCfToken 'profile_get_secret returns decrypted gemini token'
    Assert-Equal ([bool]$secGem.Envelope.result.isDefaultOAuth) $false 'profile_get_secret custom gemini isDefaultOAuth=false'

    $addClaudeForOauth = Invoke-TestRpc -Method 'capsule_add_platform' -Params @{ platform = 'claude' }
    $claudeDefaultProf = $addClaudeForOauth.Envelope.result.profiles.Profiles | Where-Object { $_.Platform -eq 'claude' } | Select-Object -First 1
    Assert-True ($null -ne $claudeDefaultProf) 'Default claude profile created on capsule_add_platform'
    $secClaudeDefault = Invoke-TestRpc -Method 'profile_get_secret' -Params @{ profileId = $claudeDefaultProf.Id }
    Assert-True ([bool]$secClaudeDefault.Envelope.ok) 'profile_get_secret claude default OAuth ok=true'
    Assert-Equal $secClaudeDefault.Envelope.result.secret 'relaystudio' 'profile_get_secret claude without saved key falls back to relaystudio'
    Assert-Equal ([bool]$secClaudeDefault.Envelope.result.isDefaultOAuth) $true 'profile_get_secret claude fallback sets isDefaultOAuth=true'

    $secMissing = Invoke-TestRpc -Method 'profile_get_secret' -Params @{ profileId = 'prof_does_not_exist' }
    Assert-True ([bool]$secMissing.Envelope.ok) 'profile_get_secret missing profile ok=true'
    Assert-Equal $secMissing.Envelope.result.secret '' 'profile_get_secret missing profile returns empty secret'
    Assert-Equal ([bool]$secMissing.Envelope.result.isDefaultOAuth) $false 'profile_get_secret missing profile isDefaultOAuth=false'

    # 5. Profile Select, Toggle Enabled, Remove & Capsule Platform Removal
    $newBackupCall = Invoke-TestRpc -Method 'profile_save' -Params @{
        profileId = 'new'
        name      = '备用二号'
        platform  = 'chatgpt'
        kind      = 'tunnel'
        tunnelId  = 'tunnel_fedcba9876543210fedcba9876543210'
        apiKey    = 'sk-proj-BackupSecretKey1234567890XYZ'
        activate  = $false
    }
    Assert-True ([bool]$newBackupCall.Envelope.ok) 'profile_save new backup profile ok=true'
    $backupProf = $newBackupCall.Envelope.result.profiles.Profiles | Where-Object { $_.Name -eq '备用二号' } | Select-Object -First 1
    Assert-True ($null -ne $backupProf) 'Backup profile created via profileId=new'

    $selBackupCall = Invoke-TestRpc -Method 'profile_select' -Params @{ profileId = $backupProf.Id }
    Assert-True ([bool]$selBackupCall.Envelope.ok) 'profile_select backup without reconnect param ok=true'
    Assert-Equal $selBackupCall.Envelope.result.profiles.ActiveProfileId $backupProf.Id 'ActiveProfileId switched to backup without reconnect param'
    Assert-True ($selBackupCall.RawJson -notmatch '(?i)PlainKey') 'profile_select raw JSON contains NO PlainKey'

    # Verify RunningProfileId & RunningTunnelId stay pinned to running tunnel in runtime.json even when another profile is selected
    [IO.File]::WriteAllText($script:HostContext.StatePath, (@{
        signature   = 'sig_fixture_primary'
        tunnel_id   = $validTunnelId
        endpoint    = 'http://127.0.0.1:8766/mcp'
        wrapper_pid = 99999
        started_at  = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    $prevIsoFlag = $script:HostContext.Isolated
    try {
        $script:HostContext.Isolated = $false
        $runIdInfo = Resolve-RunningOpenAiTunnelIdentity -Settings (Read-ConnectionSettings $script:HostContext) -Running $true
        Assert-Equal $runIdInfo.RunningTunnelId $validTunnelId 'Resolve-RunningOpenAiTunnelIdentity reads running tunnel_id from StatePath'
        Assert-Equal $runIdInfo.RunningProfileId 'prof_primary' 'Resolve-RunningOpenAiTunnelIdentity identifies prof_primary as running even while backup profile is selected'
    } finally {
        $script:HostContext.Isolated = $prevIsoFlag
        Remove-Item -LiteralPath $script:HostContext.StatePath -Force -ErrorAction SilentlyContinue
    }

    # Verify profile_select non-isolated AutoReconnect decoupling: omitting reconnect NEVER passes -AutoReconnect:$true
    $capturedAutoReconnect = $null
    function global:Select-ConnectionProfile {
        param($Context, $Settings = $null, [string]$ProfileId, [switch]$AutoReconnect)
        $script:capturedAutoReconnect = [bool]$AutoReconnect
        $mod = Get-Module ConnectionManager
        return (& $mod { param($c, $s, $p) Select-ConnectionProfile -Context $c -Settings $s -ProfileId $p -AutoReconnect:$false } $Context $Settings $ProfileId)
    }
    try {
        $script:HostContext.Isolated = $false
        [void](Invoke-TestRpc -Method 'profile_select' -Params @{ profileId = $backupProf.Id })
        Assert-Equal $script:capturedAutoReconnect $false 'profile_select without reconnect param passes AutoReconnect=false even when non-isolated'
    } finally {
        $script:HostContext.Isolated = $prevIsoFlag
        Remove-Item Function:\global:Select-ConnectionProfile -ErrorAction SilentlyContinue
    }

    # Verify openai_tunnel_connect accepts optional profileId and switches active profile cleanly
    $connectSwitchCall = Invoke-TestRpc -Method 'openai_tunnel_connect' -Params @{ profileId = 'prof_primary' }
    Assert-True ([bool]$connectSwitchCall.Envelope.ok) 'openai_tunnel_connect with profileId ok=true'
    Assert-Equal $connectSwitchCall.Envelope.result.profiles.ActiveProfileId 'prof_primary' 'openai_tunnel_connect switches ActiveProfileId to requested profileId'
    Assert-Equal (Read-ConnectionSettings $script:HostContext).tunnel_id $validTunnelId 'openai_tunnel_connect syncs settings.json tunnel_id to requested profileId'

    $toggleCall = Invoke-TestRpc -Method 'profile_toggle_enabled' -Params @{ profileId = $backupProf.Id; enabled = $false }
    Assert-True ([bool]$toggleCall.Envelope.ok) 'profile_toggle_enabled ok=true'
    $toggledProf = $toggleCall.Envelope.result.profiles.Profiles | Where-Object { $_.Id -eq $backupProf.Id } | Select-Object -First 1
    Assert-Equal ([bool]$toggledProf.Enabled) $false 'Backup profile Enabled=false'

    # Switch back to primary and remove backup
    [void](Invoke-TestRpc -Method 'profile_select' -Params @{ profileId = 'prof_primary'; reconnect = $false })
    $remBackupCall = Invoke-TestRpc -Method 'profile_remove' -Params @{ profileId = $backupProf.Id }
    Assert-True ([bool]$remBackupCall.Envelope.ok) 'profile_remove backup ok=true'
    $stillThere = $remBackupCall.Envelope.result.profiles.Profiles | Where-Object { $_.Id -eq $backupProf.Id }
    Assert-Equal @($stillThere).Count 0 'Removed backup profile no longer in Profiles'

    # Add claude then remove gemini & claude
    $addClaudeCall = Invoke-TestRpc -Method 'capsule_add_platform' -Params @{ platform = 'claude' }
    Assert-True (@($addClaudeCall.Envelope.result.profiles.EnabledPlatforms) -contains 'claude') 'claude added to EnabledPlatforms'
    $remGemCall = Invoke-TestRpc -Method 'capsule_remove_platform' -Params @{ platform = 'gemini' }
    Assert-True (@($remGemCall.Envelope.result.profiles.EnabledPlatforms) -notcontains 'gemini') 'gemini removed from EnabledPlatforms'
    $remClaudeCall = Invoke-TestRpc -Method 'capsule_remove_platform' -Params @{ platform = 'claude' }
    Assert-True (@($remClaudeCall.Envelope.result.profiles.EnabledPlatforms) -notcontains 'claude') 'claude removed from EnabledPlatforms'
    Assert-True (@($remClaudeCall.Envelope.result.profiles.EnabledPlatforms) -contains 'chatgpt') 'chatgpt remains enabled'

    # 6. Window Layout Save / Reset & Theme Mode RPCs
    $themeDarkCall = Invoke-TestRpc -Method 'set_theme_mode' -Params @{ themeMode = 'dark' }
    Assert-True ([bool]$themeDarkCall.Envelope.ok) 'set_theme_mode dark ok=true'
    Assert-Equal $themeDarkCall.Envelope.result.themeMode 'dark' 'themeMode=dark'
    Assert-Equal $themeDarkCall.Envelope.result.effectiveTheme 'dark' 'effectiveTheme=dark'

    $stepThemeCall = Invoke-TestRpc -Method 'step_quick_theme' -Params @{}
    Assert-True ([bool]$stepThemeCall.Envelope.ok) 'step_quick_theme ok=true'
    Assert-Equal $stepThemeCall.Envelope.result.effectiveTheme 'light' 'step_quick_theme toggled dark -> light'

    [void](Invoke-TestRpc -Method 'set_theme_mode' -Params @{ mode = 'dark' })

    $saveLayoutFlat = Invoke-TestRpc -Method 'save_layout' -Params @{
        WinWidth      = 1440
        WinHeight     = 900
        RailWidth     = 312
        RailCollapsed = $true
        ShowArchived  = $true
    }
    Assert-True ([bool]$saveLayoutFlat.Envelope.ok) 'save_layout flat params ok=true'
    Assert-Equal ([int]$saveLayoutFlat.Envelope.result.WinWidth) 1440 'save_layout WinWidth=1440'
    Assert-Equal ([int]$saveLayoutFlat.Envelope.result.RailWidth) 312 'save_layout RailWidth=312'
    Assert-Equal ([bool]$saveLayoutFlat.Envelope.result.RailCollapsed) $true 'save_layout RailCollapsed=true'

    $saveLayoutNested = Invoke-TestRpc -Method 'save_layout' -Params @{
        layout = @{
            WinWidth = 1520
            Panes    = @(
                @{ id = 101; session_key = 'sess_alpha'; width_weight = 62.5; show_summary = $true },
                @{ id = 102; session_key = 'sess_beta'; width_weight = 37.5; show_summary = $false }
            )
        }
    }
    Assert-True ([bool]$saveLayoutNested.Envelope.ok) 'save_layout nested layout param ok=true'
    Assert-Equal ([int]$saveLayoutNested.Envelope.result.WinWidth) 1520 'save_layout nested WinWidth=1520'
    Assert-Equal @($saveLayoutNested.Envelope.result.Panes).Count 2 'save_layout persisted 2 panes'
    Assert-Equal $saveLayoutNested.Envelope.result.Panes[0].session_key 'sess_alpha' 'Pane[0] session_key=sess_alpha'

    $resetLayoutCall = Invoke-TestRpc -Method 'reset_layout' -Params @{}
    Assert-True ([bool]$resetLayoutCall.Envelope.ok) 'reset_layout ok=true'
    Assert-Equal ([int]$resetLayoutCall.Envelope.result.WinWidth) 1320 'reset_layout WinWidth=1320'
    Assert-Equal ([int]$resetLayoutCall.Envelope.result.WinHeight) 840 'reset_layout WinHeight=840'
    Assert-Equal ([bool]$resetLayoutCall.Envelope.result.RailCollapsed) $false 'reset_layout resets RailCollapsed=false'
    Assert-Equal $resetLayoutCall.Envelope.result.ThemeMode 'dark' 'reset_layout preserves ThemeMode=dark'

    $hiDpiLayoutCall = Invoke-TestRpc -Method 'save_layout' -Params @{ WinWidth = 3200; WinHeight = 2000 }
    Assert-True ([bool]$hiDpiLayoutCall.Envelope.ok) 'save_layout 3200x2000 ok=true'
    Assert-Equal ([int]$hiDpiLayoutCall.Envelope.result.WinWidth) 3200 'save_layout preserves 3200 logical width (<3840 upper clamp)'
    Assert-Equal ([int]$hiDpiLayoutCall.Envelope.result.WinHeight) 2000 'save_layout preserves 2000 logical height (<2400 upper clamp)'

    # 7. Engine Config ('window' <-> 'popup' StartupMode normalization), CLI Agent & Commits
    $saveEngineCall = Invoke-TestRpc -Method 'save_engine_config' -Params @{
        StartupMode              = 'window'
        AcpMaxConcurrentPrompts  = 6
        BrowserEnabled           = $false
        AutoArchiveCompletedMode = '7d'
        AcpDefaultProfile        = 'claude'
    }
    Assert-True ([bool]$saveEngineCall.Envelope.ok) 'save_engine_config ok=true'
    $retEngine = $saveEngineCall.Envelope.result.engineConfig
    Assert-Equal $retEngine.StartupMode 'window' 'engineConfig returns normalized UI StartupMode=window'
    Assert-Equal ([int]$retEngine.AcpMaxConcurrentPrompts) 6 'engineConfig AcpMaxConcurrentPrompts=6'
    Assert-Equal ([bool]$retEngine.BrowserEnabled) $false 'engineConfig BrowserEnabled=false'
    Assert-Equal $retEngine.AutoArchiveCompletedMode '7d' 'engineConfig AutoArchiveCompletedMode=7d'
    Assert-Equal $retEngine.AcpDefaultProfile 'claude' 'engineConfig AcpDefaultProfile=claude'

    $rawDiskSettings = [IO.File]::ReadAllText((Join-Path $testDataRoot 'settings.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-Equal $rawDiskSettings.startup_mode 'popup' 'settings.json persists startup_mode=popup for window alias'

    # pick_and_add_cli_agent (cancelled vs valid custom CLI path)
    $cancelCliCall = Invoke-TestRpc -Method 'pick_and_add_cli_agent' -Params @{}
    Assert-True ([bool]$cancelCliCall.Envelope.ok) 'pick_and_add_cli_agent empty path ok=true'
    Assert-True ([bool]$cancelCliCall.Envelope.result.cancelled) 'pick_and_add_cli_agent empty path returns cancelled=true'

    $dummyCliCmd = Join-Path $tempRoot 'my-custom-agent.cmd'
    [IO.File]::WriteAllText($dummyCliCmd, "@echo off`r`necho ok`r`n", [Text.Encoding]::ASCII)
    $addCliCall = Invoke-TestRpc -Method 'pick_and_add_cli_agent' -Params @{
        path        = $dummyCliCmd
        displayName = 'My Custom CLI'
    }
    Assert-True ([bool]$addCliCall.Envelope.ok) 'pick_and_add_cli_agent with path ok=true'
    Assert-Equal ([bool]$addCliCall.Envelope.result.cancelled) $false 'pick_and_add_cli_agent cancelled=false'
    $customMatch = @($addCliCall.Envelope.result.infra.cliAgents | Where-Object { $_.is_custom -and $_.command -eq $dummyCliCmd })
    Assert-Equal $customMatch.Count 1 'Custom CLI agent registered and returned in infra.cliAgents'

    # rescan_cli_agents, open_browser_bridge_dir & shutdown_all_services (isolated)
    $rescanCliCall = Invoke-TestRpc -Method 'rescan_cli_agents' -Params @{}
    Assert-True ([bool]$rescanCliCall.Envelope.ok) 'rescan_cli_agents ok=true'
    $rescannedCustom = @($rescanCliCall.Envelope.result.cliAgents | Where-Object { $_.is_custom -and $_.command -eq $dummyCliCmd })
    Assert-Equal $rescannedCustom.Count 1 'rescan_cli_agents returns custom CLI agent in refreshed bundle'

    $openBridgeCall = Invoke-TestRpc -Method 'open_browser_bridge_dir' -Params @{}
    Assert-True ([bool]$openBridgeCall.Envelope.ok) 'open_browser_bridge_dir ok=true'
    $expectedBridgeDir = [IO.Path]::GetFullPath((Join-Path $repoRoot 'browser-bridge'))
    Assert-Equal $openBridgeCall.Envelope.result.path $expectedBridgeDir 'open_browser_bridge_dir resolves browser-bridge path without spawning explorer in isolated mode'

    $shutdownCall = Invoke-TestRpc -Method 'shutdown_all_services' -Params @{}
    Assert-True ([bool]$shutdownCall.Envelope.ok) 'shutdown_all_services ok=true in isolated mode'
    Assert-True ([bool]$shutdownCall.Envelope.result.ok) 'shutdown_all_services result.ok=true'

    # get_workspace_commits + guardian tick + error handling
    $commitsCall = Invoke-TestRpc -Method 'get_workspace_commits' -Params @{ workspaceRoot = $repoRoot }
    Assert-True ([bool]$commitsCall.Envelope.ok) 'get_workspace_commits ok=true'
    Assert-True ($commitsCall.Envelope.result.PSObject.Properties.Name -contains 'commits') 'get_workspace_commits returns { commits: [...] }'

    $guardianObj = Invoke-RelayHostGuardianTickJson | ConvertFrom-Json
    Assert-Equal ([bool]$guardianObj.changed) $false 'Guardian tick is no-op in Isolated/SkipBootServices mode'

    $unknownRpc = Invoke-TestRpc -Method 'non_existent_rpc_method' -Id 'err_check_1'
    Assert-Equal ([bool]$unknownRpc.Envelope.ok) $false 'Unknown RPC method returns ok=false cleanly'
    Assert-Equal $unknownRpc.Envelope.id 'err_check_1' 'Unknown RPC error preserves request id'
    Assert-True ([string]$unknownRpc.Envelope.error -match 'non_existent_rpc_method') 'Unknown RPC error includes method name'

    # 7b. Unified Public Tunnel Pool RPCs, Simultaneous Runtime, Platform Binding & open_handover_window carrier
    $expectedPubKeys = @(
        'Id', 'Name', 'IsBuiltin', 'BaseUrl', 'EffectiveUrl', 'HasKey', 'MaskedKey',
        'Mode', 'ModeLabel', 'Running', 'Status', 'HealthPhase', 'PublicRttMs',
        'ErrorReason', 'ProcessId', 'UsedByPlatforms'
    )
    $initPubBundle = (Invoke-TestRpc -Method 'get_infra_bundle').Envelope.result
    Assert-True ($initPubBundle.PSObject.Properties.Name -contains 'publicTunnels') 'InfraBundle includes publicTunnels array'
    Assert-True ($initPubBundle.PSObject.Properties.Name -contains 'selectedPublicTunnelByPlatform') 'InfraBundle includes selectedPublicTunnelByPlatform'
    Assert-True (@($initPubBundle.publicTunnels).Count -ge 1) 'publicTunnels contains built-in quick tunnel'
    $builtinItem = $initPubBundle.publicTunnels[0]
    Assert-Equal $builtinItem.Id 'pub_builtin_quick' 'First publicTunnels item is pub_builtin_quick'
    Assert-Equal $builtinItem.Name '免费临时隧道' 'Built-in item Name is 免费临时隧道'
    Assert-Equal ([bool]$builtinItem.IsBuiltin) $true 'Built-in item IsBuiltin=true'
    foreach ($reqKey in $expectedPubKeys) {
        Assert-True ($builtinItem.PSObject.Properties.Name -contains $reqKey) "PublicTunnelItem exposes exact PascalCase key: $reqKey"
    }

    # Built-in item cannot be removed
    $remBuiltinRpc = Invoke-TestRpc -Method 'public_tunnel_item_remove' -Params @{ tunnelId = 'pub_builtin_quick' }
    Assert-Equal ([bool]$remBuiltinRpc.Envelope.ok) $false 'public_tunnel_item_remove refuses built-in pub_builtin_quick'

    # Save custom Cloudflare Named Tunnel item & custom Tailscale item (MUST NOT auto-start or leak PlainKey)
    $pubSecretKey = 'eyJh SuperSecretNamedTunnelKey_NoSpaces' -replace '\s+', ''
    $savePubCf = Invoke-TestRpc -Method 'public_tunnel_item_save' -Params @{
        tunnelId   = ''
        name       = '工作室专线'
        baseUrl    = 'https://studio-cf.example.com'
        startupKey = $pubSecretKey
    }
    Assert-True ([bool]$savePubCf.Envelope.ok) 'public_tunnel_item_save Cloudflare专线 ok=true'
    Assert-True ($savePubCf.RawJson -notmatch '(?i)PlainKey') 'public_tunnel_item_save raw JSON contains NO PlainKey'
    Assert-True (-not $savePubCf.RawJson.Contains($pubSecretKey)) 'public_tunnel_item_save redacts startupKey from bundle JSON'
    $cfPubObj = @($savePubCf.Envelope.result.publicTunnels | Where-Object { $_.Name -eq '工作室专线' }) | Select-Object -First 1
    Assert-True ($null -ne $cfPubObj) 'Custom Cloudflare专线 item created'
    Assert-Equal ([bool]$cfPubObj.Running) $false 'public_tunnel_item_save NEVER auto-starts tunnel'
    Assert-Equal $cfPubObj.Mode 'cloudflare_key' 'Mode inferred as cloudflare_key'
    Assert-Equal $cfPubObj.ModeLabel 'Cloudflare 专线' 'ModeLabel is Cloudflare 专线'
    Assert-Equal ([bool]$cfPubObj.HasKey) $true 'HasKey=true on saved Cloudflare专线'
    Assert-Equal $cfPubObj.BaseUrl 'https://studio-cf.example.com/mcp' 'BaseUrl normalized with /mcp'

    $getPubSec = Invoke-TestRpc -Method 'public_tunnel_item_get_secret' -Params @{ tunnelId = $cfPubObj.Id }
    Assert-True ([bool]$getPubSec.Envelope.ok) 'public_tunnel_item_get_secret ok=true'
    Assert-Equal $getPubSec.Envelope.result.secret $pubSecretKey 'public_tunnel_item_get_secret decrypts exact DPAPI startupKey'

    $savePubTs = Invoke-TestRpc -Method 'public_tunnel_item_save' -Params @{
        name    = 'Tailscale节点'
        baseUrl = 'https://workstation.tail29988f.ts.net'
    }
    Assert-True ([bool]$savePubTs.Envelope.ok) 'public_tunnel_item_save Tailscale item ok=true'
    $tsPubObj = @($savePubTs.Envelope.result.publicTunnels | Where-Object { $_.Name -eq 'Tailscale节点' }) | Select-Object -First 1
    Assert-Equal $tsPubObj.Mode 'tailscale' 'Mode inferred as tailscale for *.ts.net without key'

    # public_tunnel_detect_tailscale discovers *.ts.net from pool fallback in isolated mode
    $detectTsRpc = Invoke-TestRpc -Method 'public_tunnel_detect_tailscale' -Params @{}
    Assert-True ([bool]$detectTsRpc.Envelope.ok) 'public_tunnel_detect_tailscale envelope ok=true'
    Assert-True ([bool]$detectTsRpc.Envelope.result.ok) 'public_tunnel_detect_tailscale result.ok=true'
    Assert-Equal $detectTsRpc.Envelope.result.url 'https://workstation.tail29988f.ts.net/mcp' 'public_tunnel_detect_tailscale returns normalized *.ts.net/mcp URL'

    # Platform binding & UsedByPlatforms filtered by EnabledPlatforms
    [void](Invoke-TestRpc -Method 'capsule_add_platform' -Params @{ platform = 'gemini' })
    $bindGemRpc = Invoke-TestRpc -Method 'platform_bind_public_tunnel' -Params @{
        platform = 'gemini'
        tunnelId = $cfPubObj.Id
    }
    Assert-True ([bool]$bindGemRpc.Envelope.ok) 'platform_bind_public_tunnel gemini ok=true'
    Assert-Equal $bindGemRpc.Envelope.result.selectedPublicTunnelByPlatform.gemini $cfPubObj.Id 'selectedPublicTunnelByPlatform.gemini updated'
    $cfAfterBind = @($bindGemRpc.Envelope.result.publicTunnels | Where-Object { $_.Id -eq $cfPubObj.Id }) | Select-Object -First 1
    Assert-Equal ([bool]$cfAfterBind.Running) $false 'platform_bind_public_tunnel does NOT start tunnel'
    Assert-True (@($cfAfterBind.UsedByPlatforms) -contains 'gemini') 'UsedByPlatforms includes enabled gemini'
    Assert-True (@($cfAfterBind.UsedByPlatforms) -notcontains 'claude') 'UsedByPlatforms excludes disabled claude'

    # Bind disabled claude to cfPubObj.Id -> still excluded from UsedByPlatforms until claude is added to EnabledPlatforms
    $bindClaDisabled = Invoke-TestRpc -Method 'platform_bind_public_tunnel' -Params @{
        platform = 'claude'
        tunnelId = $cfPubObj.Id
    }
    $cfWhileClaDisabled = @($bindClaDisabled.Envelope.result.publicTunnels | Where-Object { $_.Id -eq $cfPubObj.Id }) | Select-Object -First 1
    Assert-True (@($cfWhileClaDisabled.UsedByPlatforms) -notcontains 'claude') 'UsedByPlatforms excludes claude while claude is not in EnabledPlatforms'
    $afterAddCla = Invoke-TestRpc -Method 'capsule_add_platform' -Params @{ platform = 'claude' }
    $cfAfterAddCla = @($afterAddCla.Envelope.result.publicTunnels | Where-Object { $_.Id -eq $cfPubObj.Id }) | Select-Object -First 1
    Assert-True ((@($cfAfterAddCla.UsedByPlatforms) -contains 'gemini') -and (@($cfAfterAddCla.UsedByPlatforms) -contains 'claude')) 'UsedByPlatforms includes both gemini and claude once both are enabled'

    # Simultaneous connect of pub_builtin_quick AND cfPubObj.Id + legacy publicTunnel sync
    $connBuiltinRpc = Invoke-TestRpc -Method 'public_tunnel_item_connect' -Params @{ tunnelId = 'pub_builtin_quick' }
    Assert-True ([bool]$connBuiltinRpc.Envelope.ok) 'public_tunnel_item_connect pub_builtin_quick ok=true'
    $connCfRpc = Invoke-TestRpc -Method 'public_tunnel_item_connect' -Params @{ tunnelId = $cfPubObj.Id }
    Assert-True ([bool]$connCfRpc.Envelope.ok) 'public_tunnel_item_connect custom cloudflare_key ok=true'

    $bothRunningBundle = $connCfRpc.Envelope.result
    $runBuiltin = @($bothRunningBundle.publicTunnels | Where-Object { $_.Id -eq 'pub_builtin_quick' }) | Select-Object -First 1
    $runCf = @($bothRunningBundle.publicTunnels | Where-Object { $_.Id -eq $cfPubObj.Id }) | Select-Object -First 1
    $runTs = @($bothRunningBundle.publicTunnels | Where-Object { $_.Id -eq $tsPubObj.Id }) | Select-Object -First 1
    Assert-True ([bool]$runBuiltin.Running -and $runBuiltin.EffectiveUrl -match '\.trycloudflare\.com/mcp$') 'pub_builtin_quick is Running simultaneously'
    Assert-True ([bool]$runCf.Running -and $runCf.EffectiveUrl -eq 'https://studio-cf.example.com/mcp') 'Custom Cloudflare专线 is Running simultaneously'
    Assert-Equal ([bool]$runTs.Running) $false 'Unstarted Tailscale item remains stopped'
    Assert-Equal ([bool]$bothRunningBundle.publicTunnel.Running) $true 'Legacy publicTunnel.Running synced to true'
    Assert-Equal $bothRunningBundle.publicTunnel.Url 'https://studio-cf.example.com/mcp' 'Legacy publicTunnel.Url prefers tunnel bound to enabled gemini/claude'

    # one_click_reconnect respects desired_running == true (keeps pub_builtin_quick & cfPubObj running, leaves tsPubObj stopped)
    $oneClickRpc = Invoke-TestRpc -Method 'one_click_reconnect' -Params @{}
    Assert-True ([bool]$oneClickRpc.Envelope.ok) 'one_click_reconnect ok=true'
    $tsAfterOneClick = @($oneClickRpc.Envelope.result.publicTunnels | Where-Object { $_.Id -eq $tsPubObj.Id }) | Select-Object -First 1
    $cfAfterOneClick = @($oneClickRpc.Envelope.result.publicTunnels | Where-Object { $_.Id -eq $cfPubObj.Id }) | Select-Object -First 1
    Assert-Equal ([bool]$cfAfterOneClick.Running) $true 'one_click_reconnect keeps desired_running=true item running'
    Assert-Equal ([bool]$tsAfterOneClick.Running) $false 'one_click_reconnect respects desired_running=false and does not start tsPubObj'

    # Disconnect pub_builtin_quick -> ONLY stops pub_builtin_quick, leaving cfPubObj running
    $discBuiltinRpc = Invoke-TestRpc -Method 'public_tunnel_item_disconnect' -Params @{ tunnelId = 'pub_builtin_quick' }
    Assert-True ([bool]$discBuiltinRpc.Envelope.ok) 'public_tunnel_item_disconnect pub_builtin_quick ok=true'
    $bAfterDisc = @($discBuiltinRpc.Envelope.result.publicTunnels | Where-Object { $_.Id -eq 'pub_builtin_quick' }) | Select-Object -First 1
    $cfAfterDisc = @($discBuiltinRpc.Envelope.result.publicTunnels | Where-Object { $_.Id -eq $cfPubObj.Id }) | Select-Object -First 1
    Assert-Equal ([bool]$bAfterDisc.Running) $false 'pub_builtin_quick stopped after disconnect'
    Assert-Equal ([bool]$cfAfterDisc.Running) $true 'cfPubObj remains running when pub_builtin_quick is disconnected'

    # Remove cfPubObj -> stops it and rebinds gemini & claude back to pub_builtin_quick
    $remCfRpc = Invoke-TestRpc -Method 'public_tunnel_item_remove' -Params @{ tunnelId = $cfPubObj.Id }
    Assert-True ([bool]$remCfRpc.Envelope.ok) 'public_tunnel_item_remove custom tunnel ok=true'
    Assert-Equal $remCfRpc.Envelope.result.selectedPublicTunnelByPlatform.gemini 'pub_builtin_quick' 'Removing bound tunnel rebinds gemini to pub_builtin_quick'
    Assert-Equal $remCfRpc.Envelope.result.selectedPublicTunnelByPlatform.claude 'pub_builtin_quick' 'Removing bound tunnel rebinds claude to pub_builtin_quick'

    # open_handover_window accepts carrier parameter and forwards it as BrowserProfile to Open-BridgeHandoverWindow
    $capturedHandoverCarrier = ''
    $capturedHandoverUrl = ''
    function global:Open-BridgeHandoverWindow {
        param([string]$Url, [string]$BrowserProfile = '', $Context = $null)
        $script:capturedHandoverUrl = $Url
        $script:capturedHandoverCarrier = $BrowserProfile
    }
    $prevIsoHandover = $script:HostContext.Isolated
    try {
        $script:HostContext.Isolated = $false
        $handoverRpc = Invoke-TestRpc -Method 'open_handover_window' -Params @{
            url     = 'https://gemini.google.com/app'
            carrier = 'Edge:Profile 2'
        }
        Assert-True ([bool]$handoverRpc.Envelope.ok) 'open_handover_window with carrier ok=true'
        Assert-Equal $script:capturedHandoverUrl 'https://gemini.google.com/app' 'open_handover_window forwards url'
        Assert-Equal $script:capturedHandoverCarrier 'Edge:Profile 2' 'open_handover_window maps carrier parameter to BrowserProfile'
    } finally {
        $script:HostContext.Isolated = $prevIsoHandover
        Remove-Item Function:\global:Open-BridgeHandoverWindow -ErrorAction SilentlyContinue
    }

    # Verify automatic migration through HostBridge on legacy DataRoot with shared *.ts.net across yuanyang & yuan
    $migDataDir = Join-Path $tempRoot 'legacy-upgrade-data'
    [IO.Directory]::CreateDirectory($migDataDir) | Out-Null
    $legacyCtx = New-ConnectionContext -DataRoot $migDataDir -ReleaseRoot $repoRoot -Isolated
    [void](Add-CapsulePlatform -Context $legacyCtx -Platform 'gemini')
    [void](Add-CapsulePlatform -Context $legacyCtx -Platform 'claude')
    $legProfs = Get-ConnectionProfiles $legacyCtx
    $legGemId = ($legProfs.Profiles | Where-Object { $_.Platform -eq 'gemini' } | Select-Object -First 1).Id
    $legClaId = ($legProfs.Profiles | Where-Object { $_.Platform -eq 'claude' } | Select-Object -First 1).Id
    [void](Save-ConnectionProfile -Context $legacyCtx -ProfileId $legGemId -Name 'yuanyang' -Platform 'gemini' -Kind 'public_tunnel' -BaseUrl 'https://thinkbook16pl.tail29988f.ts.net/mcp' -SetActive)
    [void](Save-ConnectionProfile -Context $legacyCtx -ProfileId $legClaId -Name 'yuan' -Platform 'claude' -Kind 'public_tunnel' -BaseUrl 'https://thinkbook16pl.tail29988f.ts.net/' -SetActive)
    [void](Initialize-RelayHostBridge -BaseDirectory $repoRoot -DataRoot $migDataDir -Isolated -SkipBootServices)
    $migBootBundle = (Invoke-TestRpc -Method 'get_fast_bootstrap').Envelope.result
    Assert-Equal @($migBootBundle.publicTunnels).Count 2 'HostBridge migrates & deduplicates shared legacy Gemini/Claude URL into 1 custom item + builtin'
    $migSharedItem = $migBootBundle.publicTunnels[1]
    Assert-Equal $migSharedItem.Name 'yuanyang' 'HostBridge migration preserves custom profile name yuanyang'
    Assert-Equal $migBootBundle.selectedPublicTunnelByPlatform.gemini $migSharedItem.Id 'Migrated gemini bound to shared item'
    Assert-Equal $migBootBundle.selectedPublicTunnelByPlatform.claude $migSharedItem.Id 'Migrated claude bound to shared item'
    [void](Initialize-RelayHostBridge -BaseDirectory $repoRoot -DataRoot $testDataRoot -Isolated -SkipBootServices)

    # 8. Isolated End-to-End RelayStudio.exe --smoke-test Verification
    $smokeStage = Join-Path $tempRoot 'smoke-app'
    $smokeBinWv = Join-Path $smokeStage 'bin\webview2'
    $smokeUiDir = Join-Path $smokeStage 'ui'
    $smokeDataDir = Join-Path $smokeStage 'data'
    $smokeReceipt = Join-Path $smokeStage 'smoke-receipt.json'
    [IO.Directory]::CreateDirectory($smokeBinWv) | Out-Null
    [IO.Directory]::CreateDirectory($smokeUiDir) | Out-Null
    [IO.Directory]::CreateDirectory($smokeDataDir) | Out-Null

    Copy-Item -LiteralPath (Join-Path $repoRoot 'RelayStudio.exe') -Destination (Join-Path $smokeStage 'RelayStudio.exe') -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'HostBridge.ps1') -Destination (Join-Path $smokeStage 'HostBridge.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'ConnectionManager.psm1') -Destination (Join-Path $smokeStage 'ConnectionManager.psm1') -Force
    Copy-Item -Path (Join-Path $repoRoot 'bin\webview2\*.dll') -Destination $smokeBinWv -Force

    $smokeHtml = @'
<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>RelayStudio Smoke Harness</title></head>
<body>
<script>
(function () {
  if (!window.chrome || !window.chrome.webview) return;
  var t0 = performance.now();
  window.chrome.webview.addEventListener('message', function (ev) {
    var d = typeof ev.data === 'string' ? JSON.parse(ev.data) : ev.data;
    if (d && d.type === 'rpc_response' && d.id === 'smoke_fast_1' && d.ok && d.result) {
      var elapsed = Math.round(performance.now() - t0);
      window.chrome.webview.postMessage({
        type: 'rpc_request',
        id: 'smoke_widen_1',
        method: 'window_ensure_min_width',
        params: { minWidth: 1280 }
      });
      window.chrome.webview.postMessage({
        type: 'rpc_request',
        id: 'smoke_dirty_1',
        method: 'set_unsaved_edits',
        params: { dirty: false }
      });
      window.chrome.webview.postMessage({
        type: 'smoke_ready',
        title: document.title,
        shieldBaseUrl: d.result.shieldBaseUrl,
        hubReachable: true,
        fastBootMs: elapsed
      });
    }
  });
  window.chrome.webview.postMessage({
    type: 'rpc_request',
    id: 'smoke_fast_1',
    method: 'get_fast_bootstrap',
    params: {}
  });
})();
</script>
</body>
</html>
'@
    [IO.File]::WriteAllText((Join-Path $smokeUiDir 'index.html'), $smokeHtml, (New-Object System.Text.UTF8Encoding($false)))

    $smokeProc = Start-Process -FilePath (Join-Path $smokeStage 'RelayStudio.exe') -ArgumentList @(
        '--smoke-test', $smokeReceipt,
        '--isolated',
        '--skip-boot-services',
        '--data-root', $smokeDataDir
    ) -PassThru -Wait
    Assert-Equal $smokeProc.ExitCode 0 'RelayStudio.exe --smoke-test exited with code 0'
    Assert-True (Test-Path -LiteralPath $smokeReceipt) 'Smoke receipt JSON written'
    $receiptObj = [IO.File]::ReadAllText($smokeReceipt, [Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-True ([bool]$receiptObj.ok) 'Smoke receipt ok=true'
    Assert-True ([string]$receiptObj.webviewVersion.Length -gt 0) "Smoke receipt webviewVersion=$($receiptObj.webviewVersion)"
    Assert-Equal $receiptObj.url 'https://studio.relaystudio.local/index.html' 'Smoke receipt virtual host URL verified'
    Assert-Equal $receiptObj.shieldBaseUrl 'http://127.0.0.1:8766' 'Smoke receipt round-tripped HostBridge get_fast_bootstrap shieldBaseUrl'
    Assert-Equal ([bool]$receiptObj.hubReachable) $true 'Smoke receipt preserves hubReachable=true'
    Assert-True ([int]$receiptObj.fastBootMs -ge 0) "Smoke receipt preserves fastBootMs=$($receiptObj.fastBootMs)"
    Assert-True (Test-Path -LiteralPath (Join-Path $smokeDataDir 'webview2-smoke-cache')) 'Smoke test isolates WebView2 cache under webview2-smoke-cache'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $smokeDataDir 'webview2-cache')) $false 'Smoke test does not lock production webview2-cache'

    # 9. Verify sandbox virtual-desktop (exebox-*) guard never hijacks Default desktop mutex
    Add-Type -Namespace Win32DeskTest -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern IntPtr GetThreadDesktop(uint dwThreadId);
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool GetUserObjectInformation(IntPtr hObj, int nIndex, System.Text.StringBuilder pvInfo, int nLength, out int lpnLengthNeeded);
'@ -ErrorAction SilentlyContinue
    $deskSb = New-Object System.Text.StringBuilder 256
    $deskNeed = 0
    [void][Win32DeskTest.Native]::GetUserObjectInformation([Win32DeskTest.Native]::GetThreadDesktop([Win32DeskTest.Native]::GetCurrentThreadId()), 2, $deskSb, 512, [ref]$deskNeed)
    if ($deskSb.ToString() -like 'exebox-*') {
        $guardProc = Start-Process -FilePath (Join-Path $smokeStage 'RelayStudio.exe') -PassThru -Wait
        Assert-Equal $guardProc.ExitCode 2 'RelayStudio.exe refuses non-isolated daemon launch inside exebox-* virtual desktop (ExitCode=2)'
    }

    Write-Host "ALL TESTS PASSED: $($script:PassCount) assertions succeeded, 0 failed."
} finally {
    $env:RELAYSTUDIO_LOCAL_TOKEN = $origEnvToken
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
