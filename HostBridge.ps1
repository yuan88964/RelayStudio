Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BaseDirectory = ''
$script:HostContext = $null
$script:StudioToken = ''
$script:SkipBootServices = $false

$script:CachedBrowserProfiles = $null
$script:CachedBrowserProfilesUtc = [DateTime]::MinValue
$script:CachedCliAgents = $null
$script:CachedCliAgentsUtc = [DateTime]::MinValue
$script:DisplaySummaryCache = $null
$script:DisplaySummaryCacheUtc = [DateTime]::MinValue

$script:GuardianCoreStrikes = 0
$script:GuardianCoreNextRetryUtc = [DateTime]::MinValue
$script:GuardianShieldStrikes = 0
$script:GuardianShieldNextRetryUtc = [DateTime]::MinValue
$script:GuardianOpenAiStrikes = 0
$script:GuardianOpenAiNextRetryUtc = [DateTime]::MinValue
$script:GuardianPublicStrikes = 0
$script:GuardianPublicNextRetryUtc = [DateTime]::MinValue
$script:GuardianLastDigestSig = ''

function Reset-RelayHostBridgeCaches {
    param([switch]$ResetGuardian)
    $script:CachedBrowserProfiles = $null
    $script:CachedBrowserProfilesUtc = [DateTime]::MinValue
    $script:CachedCliAgents = $null
    $script:CachedCliAgentsUtc = [DateTime]::MinValue
    $script:DisplaySummaryCache = $null
    $script:DisplaySummaryCacheUtc = [DateTime]::MinValue
    if ($ResetGuardian) {
        $script:GuardianCoreStrikes = 0
        $script:GuardianCoreNextRetryUtc = [DateTime]::MinValue
        $script:GuardianShieldStrikes = 0
        $script:GuardianShieldNextRetryUtc = [DateTime]::MinValue
        $script:GuardianOpenAiStrikes = 0
        $script:GuardianOpenAiNextRetryUtc = [DateTime]::MinValue
        $script:GuardianPublicStrikes = 0
        $script:GuardianPublicNextRetryUtc = [DateTime]::MinValue
        $script:GuardianLastDigestSig = ''
    }
}

function Initialize-RelayHostBridge {
    param(
        [string]$BaseDirectory = $PSScriptRoot,
        [string]$DataRoot = '',
        [switch]$Isolated,
        [switch]$SkipBootServices
    )
    if (-not $BaseDirectory) {
        $BaseDirectory = [AppDomain]::CurrentDomain.BaseDirectory
    }
    $script:BaseDirectory = [IO.Path]::GetFullPath($BaseDirectory)
    $effDataRoot = if ($DataRoot -and $DataRoot.Trim()) {
        [IO.Path]::GetFullPath($DataRoot.Trim())
    } else {
        Join-Path $script:BaseDirectory 'data'
    }
    [IO.Directory]::CreateDirectory($effDataRoot) | Out-Null

    $modulePath = Join-Path $script:BaseDirectory 'ConnectionManager.psm1'
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw "未找到核心模块: $modulePath"
    }
    Import-Module $modulePath -Force -DisableNameChecking

    $script:HostContext = New-ConnectionContext -DataRoot $effDataRoot -ReleaseRoot $script:BaseDirectory -Isolated:$Isolated
    $script:SkipBootServices = [bool]$SkipBootServices

    Ensure-RelayStudioToken

    Reset-RelayHostBridgeCaches -ResetGuardian

    return [pscustomobject]@{
        Ok               = $true
        BaseDirectory    = $script:BaseDirectory
        DataRoot         = $effDataRoot
        Isolated         = [bool]$Isolated
        SkipBootServices = [bool]$script:SkipBootServices
    }
}

function Ensure-RelayStudioToken {
    if ($script:StudioToken -and $script:StudioToken.Trim()) {
        $env:RELAYSTUDIO_LOCAL_TOKEN = $script:StudioToken
        return
    }
    $effDataRoot = if ($script:HostContext -and $script:HostContext.DataRoot) {
        [string]$script:HostContext.DataRoot
    } elseif ($script:BaseDirectory) {
        Join-Path $script:BaseDirectory 'data'
    } else {
        Join-Path $PSScriptRoot 'data'
    }
    [IO.Directory]::CreateDirectory($effDataRoot) | Out-Null
    $tokenPath = Join-Path $effDataRoot 'studio-local.token'
    $tok = ''
    if (Test-Path -LiteralPath $tokenPath) {
        try {
            $tok = ([IO.File]::ReadAllText($tokenPath, [Text.Encoding]::UTF8)).Trim()
        } catch {
            $tok = ''
        }
    }
    if (-not $tok) {
        $tok = [Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($tokenPath, $tok, (New-Object System.Text.UTF8Encoding($false)))
    }
    $script:StudioToken = $tok
    $env:RELAYSTUDIO_LOCAL_TOKEN = $script:StudioToken
}

function Assert-RelayHostBridgeReady {
    if ($null -eq $script:HostContext) {
        [void](Initialize-RelayHostBridge)
    }
}

function Test-RpcHasParam {
    param(
        $ParamsObj,
        [string[]]$CandidateNames
    )
    if ($null -eq $ParamsObj) { return $false }
    if ($ParamsObj -is [System.Collections.IDictionary]) {
        foreach ($cand in $CandidateNames) {
            foreach ($k in $ParamsObj.Keys) {
                if ([string]::Equals([string]$k, $cand, [StringComparison]::OrdinalIgnoreCase)) {
                    return $true
                }
            }
        }
        return $false
    }
    foreach ($cand in $CandidateNames) {
        foreach ($prop in $ParamsObj.PSObject.Properties) {
            if ([string]::Equals($prop.Name, $cand, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

function Get-RpcParam {
    param(
        $ParamsObj,
        [string[]]$CandidateNames,
        $DefaultValue = $null
    )
    if ($null -eq $ParamsObj) { return $DefaultValue }
    if ($ParamsObj -is [System.Collections.IDictionary]) {
        foreach ($cand in $CandidateNames) {
            foreach ($k in $ParamsObj.Keys) {
                if ([string]::Equals([string]$k, $cand, [StringComparison]::OrdinalIgnoreCase)) {
                    $v = $ParamsObj[$k]
                    if ($null -ne $v) { return $v }
                    return $null
                }
            }
        }
        return $DefaultValue
    }
    foreach ($cand in $CandidateNames) {
        foreach ($prop in $ParamsObj.PSObject.Properties) {
            if ([string]::Equals($prop.Name, $cand, [StringComparison]::OrdinalIgnoreCase)) {
                return $prop.Value
            }
        }
    }
    return $DefaultValue
}

function Get-RpcBoolParam {
    param(
        $ParamsObj,
        [string[]]$CandidateNames,
        [bool]$DefaultValue = $false
    )
    if (-not (Test-RpcHasParam $ParamsObj $CandidateNames)) {
        return $DefaultValue
    }
    $val = Get-RpcParam $ParamsObj $CandidateNames $DefaultValue
    if ($null -eq $val) {
        return $DefaultValue
    }
    if ($val -is [bool]) {
        return $val
    }
    $strVal = ([string]$val).Trim().ToLowerInvariant()
    if ($strVal -in @('true', '1', 'yes')) {
        return $true
    }
    if ($strVal -in @('false', '0', 'no', '')) {
        return $false
    }
    return [bool]$val
}

function ConvertTo-SafeProfilesBundle {
    param($RawProfilesState)
    $safeProfiles = New-Object 'System.Collections.Generic.List[object]'
    if ($RawProfilesState -and $RawProfilesState.PSObject.Properties['Profiles'] -and $RawProfilesState.Profiles) {
        foreach ($p in @($RawProfilesState.Profiles)) {
            if ($null -eq $p) { continue }
            $safeItem = [ordered]@{
                Id        = [string]$p.Id
                Name      = [string]$p.Name
                Platform  = [string]$p.Platform
                Kind      = [string]$p.Kind
                TunnelId  = [string]$p.TunnelId
                BaseUrl   = [string]$p.BaseUrl
                ApiBaseUrl = [string]$p.ApiBaseUrl
                KeyFile   = [string]$p.KeyFile
                HasKey    = [bool]$p.HasKey
                MaskedKey = [string]$p.MaskedKey
                Enabled   = [bool]$p.Enabled
                IsActive  = [bool]$p.IsActive
            }
            [void]$safeProfiles.Add([pscustomobject]$safeItem)
        }
    }
    $actMap = [ordered]@{}
    if ($RawProfilesState -and $RawProfilesState.PSObject.Properties['ActiveProfileByPlatform'] -and $RawProfilesState.ActiveProfileByPlatform) {
        if ($RawProfilesState.ActiveProfileByPlatform -is [System.Collections.IDictionary]) {
            foreach ($k in $RawProfilesState.ActiveProfileByPlatform.Keys) {
                $actMap[[string]$k] = [string]$RawProfilesState.ActiveProfileByPlatform[$k]
            }
        } else {
            foreach ($prop in $RawProfilesState.ActiveProfileByPlatform.PSObject.Properties) {
                $actMap[[string]$prop.Name] = [string]$prop.Value
            }
        }
    }
    $enPlats = @(if ($RawProfilesState -and $RawProfilesState.PSObject.Properties['EnabledPlatforms'] -and $RawProfilesState.EnabledPlatforms) {
        $RawProfilesState.EnabledPlatforms | ForEach-Object { [string]$_ }
    } else {
        @('chatgpt')
    })
    return [pscustomobject]([ordered]@{
        ActiveProfileId         = $(if ($RawProfilesState -and $RawProfilesState.PSObject.Properties['ActiveProfileId']) { [string]$RawProfilesState.ActiveProfileId } else { 'prof_primary' })
        EnabledPlatforms        = [string[]]@($enPlats)
        ActiveProfileByPlatform = [pscustomobject]$actMap
        Profiles                = [object[]]@($safeProfiles.ToArray())
    })
}

function ConvertTo-SerializableLayout {
    param($RawLayout)
    $panesList = New-Object 'System.Collections.Generic.List[object]'
    if ($RawLayout -and $RawLayout.PSObject.Properties['Panes'] -and $RawLayout.Panes) {
        foreach ($p in @($RawLayout.Panes)) {
            if ($null -eq $p) { continue }
            [void]$panesList.Add([pscustomobject]([ordered]@{
                id           = [int]$p.id
                session_key  = [string]$p.session_key
                width_weight = [double]$p.width_weight
                show_summary = [bool]$p.show_summary
            }))
        }
    }
    $hiddenObj = $null
    if ($RawLayout -and $RawLayout.PSObject.Properties['HiddenRightPane'] -and $null -ne $RawLayout.HiddenRightPane) {
        $hp = $RawLayout.HiddenRightPane
        $hiddenObj = [pscustomobject]([ordered]@{
            id           = [int]$hp.id
            session_key  = [string]$hp.session_key
            width_weight = [double]$hp.width_weight
            show_summary = [bool]$hp.show_summary
        })
    }
    return [pscustomobject]([ordered]@{
        WinWidth        = [int]$RawLayout.WinWidth
        WinHeight       = [int]$RawLayout.WinHeight
        RailWidth       = [int]$RawLayout.RailWidth
        RailCollapsed   = [bool]$RawLayout.RailCollapsed
        ShowArchived    = [bool]$RawLayout.ShowArchived
        ThemeMode       = ([string]$RawLayout.ThemeMode).ToLowerInvariant()
        HiddenRightPane = $hiddenObj
        Panes           = [object[]]@($panesList.ToArray())
    })
}

function Resolve-RunningOpenAiTunnelIdentity {
    param(
        $Settings,
        [bool]$Running,
        [bool]$IsLegacy = $false
    )
    if ((-not $Running) -or $IsLegacy -or $null -eq $script:HostContext -or $script:HostContext.Isolated) {
        return [pscustomobject]@{
            RunningProfileId = ''
            RunningTunnelId  = ''
        }
    }

    $stateTunnelId = ''
    $stateSig = ''
    $stateEndpoint = ''
    if ($script:HostContext.StatePath -and (Test-Path -LiteralPath $script:HostContext.StatePath)) {
        try {
            $stObj = [IO.File]::ReadAllText($script:HostContext.StatePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($null -ne $stObj) {
                if ($stObj.PSObject.Properties['tunnel_id'] -and $stObj.tunnel_id) {
                    $stateTunnelId = ([string]$stObj.tunnel_id).Trim()
                }
                if ($stObj.PSObject.Properties['signature'] -and $stObj.signature) {
                    $stateSig = ([string]$stObj.signature).Trim()
                }
                if ($stObj.PSObject.Properties['endpoint'] -and $stObj.endpoint) {
                    $stateEndpoint = ([string]$stObj.endpoint).Trim()
                }
            }
        } catch { }
    }
    if ((-not $stateTunnelId) -and $script:HostContext.ProfilePath -and (Test-Path -LiteralPath $script:HostContext.ProfilePath)) {
        try {
            $profYaml = [IO.File]::ReadAllText($script:HostContext.ProfilePath, [Text.Encoding]::UTF8)
            if ($profYaml -match '(?m)^\s*tunnel_id:\s*"?([^"\r\n]+)"?\s*$') {
                $stateTunnelId = $Matches[1].Trim()
            }
        } catch { }
    }

    $profsState = try { Get-ConnectionProfiles $script:HostContext $Settings } catch { $null }
    $chatProfiles = @(if ($profsState -and $profsState.PSObject.Properties['Profiles'] -and $profsState.Profiles) {
        $profsState.Profiles | Where-Object { $null -ne $_ -and ((-not $_.Platform) -or ([string]$_.Platform -eq 'chatgpt')) }
    })

    $resolvedProfileId = ''
    $resolvedTunnelId = $stateTunnelId

    if ($stateTunnelId) {
        $exactMatches = @($chatProfiles | Where-Object { [string]$_.TunnelId -eq $stateTunnelId })
        if ($exactMatches.Count -gt 0) {
            $actMatch = $exactMatches | Where-Object { $_.IsActive } | Select-Object -First 1
            $chosen = if ($null -ne $actMatch) { $actMatch } else { $exactMatches[0] }
            $resolvedProfileId = [string]$chosen.Id
        }
    }

    if ((-not $resolvedProfileId) -and $stateSig -and $Settings) {
        $effEp = if ($stateEndpoint) {
            $stateEndpoint
        } else {
            $coreEp = try { Get-OfficialCoreEndpoint $Settings } catch { 'http://127.0.0.1:8765/mcp' }
            try { Get-EffectiveTunnelEndpoint $Settings $coreEp } catch { 'http://127.0.0.1:8766/mcp' }
        }
        foreach ($cp in $chatProfiles) {
            if (-not $cp.TunnelId) { continue }
            $candSettings = $Settings.PSObject.Copy()
            $candSettings.tunnel_id = [string]$cp.TunnelId
            $candSig = try { Get-ConnectionSignature $candSettings $effEp } catch { '' }
            if ($candSig -and ($candSig -eq $stateSig)) {
                $resolvedProfileId = [string]$cp.Id
                if (-not $resolvedTunnelId) {
                    $resolvedTunnelId = [string]$cp.TunnelId
                }
                break
            }
        }
    }

    $settingsTunId = if ($Settings -and $Settings.PSObject.Properties['tunnel_id'] -and $Settings.tunnel_id) { ([string]$Settings.tunnel_id).Trim() } else { '' }
    $activeProfId = if ($profsState -and $profsState.PSObject.Properties['ActiveProfileId'] -and $profsState.ActiveProfileId) {
        [string]$profsState.ActiveProfileId
    } elseif ($Settings -and $Settings.PSObject.Properties['active_profile_id'] -and $Settings.active_profile_id) {
        [string]$Settings.active_profile_id
    } else { '' }

    if ((-not $resolvedProfileId) -and $activeProfId) {
        if ((-not $stateTunnelId) -or ($settingsTunId -eq $stateTunnelId)) {
            $actProfObj = $chatProfiles | Where-Object { [string]$_.Id -eq $activeProfId } | Select-Object -First 1
            if ($actProfObj -and ((-not $stateTunnelId) -or ([string]$actProfObj.TunnelId -eq $stateTunnelId))) {
                $resolvedProfileId = [string]$actProfObj.Id
                if (-not $resolvedTunnelId) {
                    $resolvedTunnelId = [string]$actProfObj.TunnelId
                }
            }
        }
    }

    if ((-not $resolvedTunnelId) -and (-not $stateTunnelId) -and $settingsTunId) {
        $resolvedTunnelId = $settingsTunId
    }

    return [pscustomobject]@{
        RunningProfileId = [string]$resolvedProfileId
        RunningTunnelId  = [string]$resolvedTunnelId
    }
}

function Get-FastConnectionDisplaySummary {
    param(
        $Settings,
        [switch]$ForceProbe,
        [switch]$TcpListenersOnly
    )
    $endpoint = try { Get-OfficialCoreEndpoint $Settings } catch { '尚未找到本地内核' }
    if ($script:HostContext.Isolated) {
        return [pscustomobject]([ordered]@{
            Endpoint         = [string]$endpoint
            Core             = '等待内核启动'
            Tunnel           = '尚未连接'
            Session          = '等待连接后显示实时脉搏'
            SessionColor     = '#505D70'
            IsFault          = $false
            Running          = $false
            RunningProfileId = ''
            RunningTunnelId  = ''
            UiUrl            = ''
        })
    }
    $nowUtc = [DateTime]::UtcNow
    if ((-not $ForceProbe) -and $null -ne $script:DisplaySummaryCache -and (($nowUtc - $script:DisplaySummaryCacheUtc).TotalSeconds -lt 6.0)) {
        return $script:DisplaySummaryCache
    }

    $shieldPort = if ($Settings.PSObject.Properties['shield_port'] -and [int]$Settings.shield_port -gt 0) { [int]$Settings.shield_port } else { 8766 }
    $healthPort = if ($Settings.PSObject.Properties['health_port'] -and [int]$Settings.health_port -gt 0) { [int]$Settings.health_port } else { 8789 }
    $corePort = if ($Settings.PSObject.Properties['core_port'] -and [int]$Settings.core_port -gt 0) { [int]$Settings.core_port } else { 8765 }

    if ($TcpListenersOnly) {
        $openPorts = New-Object 'System.Collections.Generic.HashSet[int]'
        try {
            foreach ($ep in [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) {
                [void]$openPorts.Add([int]$ep.Port)
            }
        } catch { }

        $coreOpen = $openPorts.Contains($corePort)
        $shieldOpen = $openPorts.Contains($shieldPort)
        $healthOpen = $openPorts.Contains($healthPort)
        $legacyOpen = $openPorts.Contains(8788)

        $coreText = if ($coreOpen) { '已准备好' } else { '尚未启动（连接时自动拉起）' }
        $tunnelText = '尚未连接'
        $sessionText = '尚未连接'
        $sessionColor = '#505D70'
        $isFault = $false
        $uiUrl = ''
        $running = $false

        if ($legacyOpen) {
            $running = $true
            $tunnelText = '旧脚本连接仍在运行'
            $uiUrl = 'http://127.0.0.1:8788/ui'
            $sessionText = '● 请先切换到本地内核隧道（当前旧连接通向 8787）'
            $sessionColor = '#B42318'
            $isFault = $true
        } elseif ($healthOpen) {
            $running = $true
            $uiUrl = "http://127.0.0.1:$healthPort/ui"
            if ($shieldOpen) {
                $tunnelText = '已就绪'
                $sessionText = '● 实时通道运行中'
                $sessionColor = '#16A34A'
            } else {
                $tunnelText = '已就绪（本地桥接异常）'
                $sessionText = '● 本地桥接核心未响应 · 请点击「重新连接」'
                $sessionColor = '#B42318'
                $isFault = $true
            }
        } elseif (@(Get-Process -Name 'tunnel-client' -ErrorAction SilentlyContinue).Count -gt 0) {
            $running = $true
            $uiUrl = "http://127.0.0.1:$healthPort/ui"
            $tunnelText = '连接中 / 尚未就绪'
            $sessionText = '正在建立隧道连接…'
            $sessionColor = '#D97706'
        }

        $fastIdentity = Resolve-RunningOpenAiTunnelIdentity -Settings $Settings -Running $running -IsLegacy $legacyOpen
        $fastSummary = [pscustomobject]([ordered]@{
            Endpoint         = [string]$endpoint
            Core             = [string]$coreText
            Tunnel           = [string]$tunnelText
            Session          = [string]$sessionText
            SessionColor     = [string]$sessionColor
            IsFault          = [bool]$isFault
            Running          = [bool]$running
            RunningProfileId = [string]$fastIdentity.RunningProfileId
            RunningTunnelId  = [string]$fastIdentity.RunningTunnelId
            UiUrl            = [string]$uiUrl
        })
        $script:DisplaySummaryCache = $fastSummary
        $script:DisplaySummaryCacheUtc = $nowUtc
        return $fastSummary
    }

    $coreText = '尚未启动（连接时自动拉起）'
    if ($endpoint -match '^http' -and (Test-LocalUrlPortOpen $endpoint)) {
        $health = Invoke-ConnectionProbe ($endpoint -replace '/mcp$', '/healthz') -TimeoutMs 900
        if ($health.Status -eq 200 -and $health.Body -match '"ok"\s*:\s*true') {
            $coreText = '已准备好'
        }
    }

    $related = @(Get-RelatedTunnelProcesses $script:HostContext $Settings)
    $relatedCount = $related.Count
    $hasLegacy = (@($related | Where-Object Kind -eq 'Legacy').Count -gt 0)

    $tunnelText = '尚未连接'
    $sessionText = '尚未连接'
    $sessionColor = '#505D70'
    $isFault = $false
    $uiUrl = ''
    $running = ($relatedCount -gt 0)

    if ($hasLegacy) {
        $tunnelText = '旧脚本连接仍在运行'
        $uiUrl = 'http://127.0.0.1:8788/ui'
        $sessionText = '● 请先切换到本地内核隧道（当前旧连接通向 8787）'
        $sessionColor = '#B42318'
        $isFault = $true
    } elseif ($relatedCount -gt 0) {
        $urlProbe = "http://127.0.0.1:$healthPort"
        $uiUrl = "$urlProbe/ui"
        $readyStatus = 0
        if (Test-LocalUrlPortOpen $urlProbe) {
            $ready = Invoke-ConnectionProbe "$urlProbe/readyz" -TimeoutMs 900
            $readyStatus = [int]$ready.Status
        }
        if ($readyStatus -eq 200) {
            $activeProfileText = if (Test-Path -LiteralPath $script:HostContext.ProfilePath) { [IO.File]::ReadAllText($script:HostContext.ProfilePath) } else { '' }
            if ($activeProfileText -match (':' + $shieldPort + '/mcp')) {
                if (Test-LocalUrlPortOpen "http://127.0.0.1:$shieldPort") {
                    $tunnelText = '已就绪'
                    $sessionText = '● 实时通道运行中'
                    $sessionColor = '#16A34A'
                } else {
                    $tunnelText = '已就绪（本地桥接异常）'
                    $sessionText = '● 本地桥接核心未响应 · 请点击「重新连接」'
                    $sessionColor = '#B42318'
                    $isFault = $true
                }
            } else {
                $tunnelText = '已就绪'
                $sessionText = '● 实时通道运行中'
                $sessionColor = '#16A34A'
            }
        } else {
            $tunnelText = '连接中 / 尚未就绪'
            $sessionText = '正在建立隧道连接…'
            $sessionColor = '#D97706'
        }
    }

    $runIdentity = Resolve-RunningOpenAiTunnelIdentity -Settings $Settings -Running $running -IsLegacy $hasLegacy
    $summary = [pscustomobject]([ordered]@{
        Endpoint         = [string]$endpoint
        Core             = [string]$coreText
        Tunnel           = [string]$tunnelText
        Session          = [string]$sessionText
        SessionColor     = [string]$sessionColor
        IsFault          = [bool]$isFault
        Running          = [bool]$running
        RunningProfileId = [string]$runIdentity.RunningProfileId
        RunningTunnelId  = [string]$runIdentity.RunningTunnelId
        UiUrl            = [string]$uiUrl
    })
    $script:DisplaySummaryCache = $summary
    $script:DisplaySummaryCacheUtc = $nowUtc
    return $summary
}

function Get-CachedHostBrowserProfiles {
    param([switch]$Force)
    $nowUtc = [DateTime]::UtcNow
    if ((-not $Force) -and $null -ne $script:CachedBrowserProfiles -and (($nowUtc - $script:CachedBrowserProfilesUtc).TotalSeconds -lt 30.0)) {
        return $script:CachedBrowserProfiles
    }
    $rawList = @(Get-AvailableBrowserProfiles -ForceRefresh:$Force -Context $script:HostContext)
    $mapped = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $rawList) {
        if ($null -eq $item) { continue }
        [void]$mapped.Add([pscustomobject]([ordered]@{
            Id        = [string]$item.Id
            Label     = [string]$item.Label
            UserName  = $(if ($item.PSObject.Properties['UserName']) { [string]$item.UserName } else { '' })
            IsDefault = [bool]($item.PSObject.Properties['IsDefault'] -and $item.IsDefault)
        }))
    }
    $arr = [object[]]@($mapped.ToArray())
    $script:CachedBrowserProfiles = $arr
    $script:CachedBrowserProfilesUtc = $nowUtc
    return $arr
}

function Get-CachedHostCliAgents {
    param(
        $Settings,
        [switch]$Force
    )
    $nowUtc = [DateTime]::UtcNow
    if ((-not $Force) -and $null -ne $script:CachedCliAgents -and (($nowUtc - $script:CachedCliAgentsUtc).TotalSeconds -lt 30.0)) {
        return $script:CachedCliAgents
    }
    $rawAgents = @(Get-DetectedCliAgents -ForceRescan:$Force -Settings $Settings -Context $script:HostContext)
    $mapped = New-Object 'System.Collections.Generic.List[object]'
    foreach ($ag in $rawAgents) {
        if ($null -eq $ag) { continue }
        $agArgs = @(if ($ag.PSObject.Properties['args'] -and $ag.args) { $ag.args | ForEach-Object { [string]$_ } })
        [void]$mapped.Add([pscustomobject]([ordered]@{
            id           = [string]$ag.id
            display_name = [string]$ag.display_name
            kind         = [string]$ag.kind
            command      = [string]$ag.command
            args         = [string[]]@($agArgs)
            is_custom    = [bool]($ag.PSObject.Properties['is_custom'] -and $ag.is_custom)
        }))
    }
    $arr = [object[]]@($mapped.ToArray())
    $script:CachedCliAgents = $arr
    $script:CachedCliAgentsUtc = $nowUtc
    return $arr
}

function Get-RelayHostInfraBundle {
    param(
        [switch]$DeepPublicProbe,
        [switch]$ForceDisplayProbe,
        [switch]$TcpListenersOnly
    )
    Assert-RelayHostBridgeReady
    Ensure-RelayStudioToken

    $settings = Read-ConnectionSettings $script:HostContext
    $layout = ConvertTo-SerializableLayout (Get-WindowLayoutMemory $script:HostContext)
    $rawProfiles = Get-ConnectionProfiles $script:HostContext $settings
    $safeProfiles = ConvertTo-SafeProfilesBundle $rawProfiles

    if ($DeepPublicProbe) {
        Clear-PublicMcpTunnelLogCache
    }
    $pubRaw = Get-PublicMcpTunnelState $script:HostContext
    $pubRunning = [bool]$pubRaw.Running
    $pubStatus = [string]$pubRaw.Status
    $pubPhase = [string]$pubRaw.HealthPhase
    $pubRtt = [int]$pubRaw.PublicRttMs
    $pubIngress = [string]$pubRaw.VerifiedIngressIp
    $pubCheckedUtc = [string]$pubRaw.LastCheckedUtc

    if ($DeepPublicProbe -and (-not $script:HostContext.Isolated) -and $pubRaw.Url -and $pubRaw.Mode -in @('tailscale', 'external_fixed')) {
        $checkedDto = [DateTimeOffset]::MinValue
        $isFreshCheck = ($pubCheckedUtc -and [DateTimeOffset]::TryParse($pubCheckedUtc, [ref]$checkedDto) -and (([DateTimeOffset]::UtcNow - $checkedDto).TotalSeconds -lt 15.0))
        if (-not $isFreshCheck) {
            try {
                $edge = Test-PublicMcpEdgeHealth -Url ([string]$pubRaw.Url) -Context $script:HostContext -TimeoutMs 8000
                if ($edge) {
                    $pubRunning = [bool]$edge.Reachable
                    $pubPhase = [string]$edge.Phase
                    $pubStatus = if (-not $edge.Reachable) { '离线' } elseif ($edge.Phase -eq 'Degraded') { '偏慢' } else { '在线' }
                    $pubRtt = [int]$edge.PublicRttMs
                    $pubIngress = [string]$edge.IngressIp
                    $pubCheckedUtc = [DateTime]::UtcNow.ToString('o')
                }
            } catch { }
        }
    }

    $safePub = [pscustomobject]([ordered]@{
        Running           = $pubRunning
        Url               = [string]$pubRaw.Url
        ProcessId         = [int]$pubRaw.ProcessId
        StartedAt         = $(if ($null -ne $pubRaw.StartedAt) { [string]$pubRaw.StartedAt } else { '' })
        Status            = $pubStatus
        Mode              = [string]$pubRaw.Mode
        ModeLabel         = [string]$pubRaw.ModeLabel
        ProfileId         = [string]$pubRaw.ProfileId
        FallbackFrom      = [string]$pubRaw.FallbackFrom
        HealthPhase       = $pubPhase
        PublicRttMs       = $pubRtt
        VerifiedIngressIp = $pubIngress
        LastCheckedUtc    = $pubCheckedUtc
    })

    $safeDisp = Get-FastConnectionDisplaySummary -Settings $settings -ForceProbe:([bool]($ForceDisplayProbe -or $DeepPublicProbe)) -TcpListenersOnly:$TcpListenersOnly

    $ecfgRaw = Get-CoreEngineConfig $script:HostContext
    $uiStartupMode = if ([string]$ecfgRaw.StartupMode -eq 'popup') { 'window' } else { [string]$ecfgRaw.StartupMode }
    $safeEcfg = [pscustomobject]([ordered]@{
        CorePort                 = [int]$ecfgRaw.CorePort
        AcpDefaultProfile        = [string]$ecfgRaw.AcpDefaultProfile
        AcpMaxConcurrentPrompts  = [int]$ecfgRaw.AcpMaxConcurrentPrompts
        BrowserEnabled           = [bool]$ecfgRaw.BrowserEnabled
        StartupMode              = $uiStartupMode
        AutoArchiveCompletedMode = [string]$ecfgRaw.AutoArchiveCompletedMode
        DefaultBrowserProfile    = [string]$ecfgRaw.DefaultBrowserProfile
    })

    $bProfs = Get-CachedHostBrowserProfiles
    $cliAgents = Get-CachedHostCliAgents -Settings $settings

    $sysTheme = ([string](Get-SystemThemePreference)).ToLowerInvariant()
    $themeMode = ([string]$layout.ThemeMode).ToLowerInvariant()
    $effTheme = ([string](Resolve-EffectiveTheme -ThemeMode $themeMode -SystemTheme $sysTheme)).ToLowerInvariant()

    $shieldPort = if ($settings.PSObject.Properties['shield_port'] -and [int]$settings.shield_port -gt 0) { [int]$settings.shield_port } else { 8766 }

    return [pscustomobject]([ordered]@{
        shieldBaseUrl   = "http://127.0.0.1:$shieldPort"
        studioToken     = [string]$script:StudioToken
        profiles        = $safeProfiles
        publicTunnel    = $safePub
        display         = $safeDisp
        layout          = $layout
        engineConfig    = $safeEcfg
        browserProfiles = [object[]]@($bProfs)
        cliAgents       = [object[]]@($cliAgents)
        themeMode       = $themeMode
        systemTheme     = $sysTheme
        effectiveTheme  = $effTheme
        windowMaximized = $false
    })
}

function Invoke-RelayHostRpcObject {
    param(
        [string]$Method,
        $Params = $null
    )
    Assert-RelayHostBridgeReady
    $normMethod = ([string]$Method).Trim()

    switch ($normMethod) {
        'get_fast_bootstrap' {
            Ensure-RelayStudioToken
            $script:DisplaySummaryCache = $null
            return (Get-RelayHostInfraBundle -ForceDisplayProbe -TcpListenersOnly)
        }

        'boot_init' {
            Reset-RelayHostBridgeCaches
            $settings = Read-ConnectionSettings $script:HostContext
            if ((-not $script:SkipBootServices) -and (-not $script:HostContext.Isolated)) {
                try { [void](Start-OfficialCoreIfNeeded $script:HostContext $settings) } catch { }
                $coreEp = try { Get-OfficialCoreEndpoint $settings } catch { 'http://127.0.0.1:8765/mcp' }
                $shieldPort = if ($settings.PSObject.Properties['shield_port'] -and [int]$settings.shield_port -gt 0) { [int]$settings.shield_port } else { 8766 }
                if (-not (Test-LocalUrlPortOpen "http://127.0.0.1:$shieldPort")) {
                    try { [void](Start-ReadOnlyShield $script:HostContext $settings $coreEp) } catch { }
                }
                $profs = Get-ConnectionProfiles $script:HostContext $settings
                $enPlats = @($profs.EnabledPlatforms)
                if ($enPlats -contains 'chatgpt') {
                    $actChat = $profs.Profiles | Where-Object { $_.Platform -eq 'chatgpt' -and $_.IsActive } | Select-Object -First 1
                    $dispNow = Get-FastConnectionDisplaySummary -Settings $settings -ForceProbe
                    if ($actChat -and $actChat.HasKey -and $actChat.TunnelId -and (-not $dispNow.Running)) {
                        try { [void](Start-ConnectionTunnel $script:HostContext $settings) } catch { }
                    }
                }
                if (($enPlats -contains 'gemini') -or ($enPlats -contains 'claude')) {
                    $pubState = Get-PublicMcpTunnelState $script:HostContext
                    $pubProf = $profs.Profiles | Where-Object { $_.Platform -in @('gemini', 'claude') -and $_.IsActive -and ($_.BaseUrl -or $_.PlainKey) } | Select-Object -First 1
                    if (-not $pubProf) {
                        $pubProf = $profs.Profiles | Where-Object { $_.Platform -in @('gemini', 'claude') -and ($_.BaseUrl -or $_.PlainKey) } | Select-Object -First 1
                    }
                    $hasTs = [bool](Get-TailscaleFunnelSelfUrl -Context $script:HostContext)
                    $needPubStart = (-not $pubState.Running)
                    if ($pubState.Running -and $pubState.Url) {
                        try {
                            $ec = Test-PublicMcpEdgeHealth -Url ([string]$pubState.Url) -Context $script:HostContext -TimeoutMs 8000
                            if (-not $ec.Reachable) { $needPubStart = $true }
                        } catch { }
                    }
                    if ($needPubStart -and ($pubProf -or $hasTs -or (Get-Command cloudflared.exe -ErrorAction SilentlyContinue))) {
                        $fDom = if ($pubProf -and $pubProf.BaseUrl) { [string]$pubProf.BaseUrl } else { '' }
                        $fTok = if ($pubProf -and $pubProf.PlainKey) { [string]$pubProf.PlainKey } else { '' }
                        $fPid = if ($pubProf -and $pubProf.Id) { [string]$pubProf.Id } else { '' }
                        try {
                            [void](Start-PublicMcpTunnel -Context $script:HostContext -FixedDomain $fDom -Token $fTok -Port $shieldPort -ProfileId $fPid -PreferTailscale:$hasTs -ForceReconnect)
                        } catch { }
                    }
                }
                try { [void](Repair-RelayProcessPriority $script:HostContext $settings) } catch { }
                $script:DisplaySummaryCache = $null
            }
            return (Get-RelayHostInfraBundle -ForceDisplayProbe)
        }

        'get_infra_bundle' {
            $deep = [bool](Get-RpcParam $Params @('deep', 'Deep', 'deepPublicProbe') $false)
            return (Get-RelayHostInfraBundle -DeepPublicProbe:$deep)
        }

        'save_layout' {
            $layoutSrc = if (Test-RpcHasParam $Params @('layout', 'Layout')) {
                Get-RpcParam $Params @('layout', 'Layout') $Params
            } else {
                $Params
            }
            $cur = Get-WindowLayoutMemory $script:HostContext
            if (Test-RpcHasParam $layoutSrc @('WinWidth', 'winWidth', 'win_width')) {
                $cur.WinWidth = [int][Math]::Round([double](Get-RpcParam $layoutSrc @('WinWidth', 'winWidth', 'win_width') $cur.WinWidth))
            }
            if (Test-RpcHasParam $layoutSrc @('WinHeight', 'winHeight', 'win_height')) {
                $cur.WinHeight = [int][Math]::Round([double](Get-RpcParam $layoutSrc @('WinHeight', 'winHeight', 'win_height') $cur.WinHeight))
            }
            if (Test-RpcHasParam $layoutSrc @('RailWidth', 'railWidth', 'rail_width')) {
                $cur.RailWidth = [int][Math]::Round([double](Get-RpcParam $layoutSrc @('RailWidth', 'railWidth', 'rail_width') $cur.RailWidth))
            }
            if (Test-RpcHasParam $layoutSrc @('RailCollapsed', 'railCollapsed', 'rail_collapsed')) {
                $cur.RailCollapsed = [bool](Get-RpcParam $layoutSrc @('RailCollapsed', 'railCollapsed', 'rail_collapsed') $cur.RailCollapsed)
            }
            if (Test-RpcHasParam $layoutSrc @('ShowArchived', 'showArchived', 'show_archived')) {
                $cur.ShowArchived = [bool](Get-RpcParam $layoutSrc @('ShowArchived', 'showArchived', 'show_archived') $cur.ShowArchived)
            }
            if (Test-RpcHasParam $layoutSrc @('ThemeMode', 'themeMode', 'theme_mode')) {
                $tmRaw = [string](Get-RpcParam $layoutSrc @('ThemeMode', 'themeMode', 'theme_mode') $cur.ThemeMode)
                $cur.ThemeMode = Resolve-NormalizedThemeMode $tmRaw
            }
            if (Test-RpcHasParam $layoutSrc @('HiddenRightPane', 'hiddenRightPane', 'hidden_right_pane')) {
                $hpRaw = Get-RpcParam $layoutSrc @('HiddenRightPane', 'hiddenRightPane', 'hidden_right_pane') $null
                if ($null -eq $hpRaw) {
                    $cur.HiddenRightPane = $null
                } else {
                    $cur.HiddenRightPane = [pscustomobject]@{
                        id           = [int](Get-RpcParam $hpRaw @('id', 'Id') 199)
                        session_key  = [string](Get-RpcParam $hpRaw @('session_key', 'sessionKey', 'SessionKey') '')
                        width_weight = [double](Get-RpcParam $hpRaw @('width_weight', 'widthWeight', 'WidthWeight') 38)
                        show_summary = [bool](Get-RpcParam $hpRaw @('show_summary', 'showSummary', 'ShowSummary') $false)
                    }
                }
            }
            if (Test-RpcHasParam $layoutSrc @('Panes', 'panes')) {
                $rawPanes = @(Get-RpcParam $layoutSrc @('Panes', 'panes') @())
                $normPanes = New-Object 'System.Collections.Generic.List[object]'
                $idx = 101
                foreach ($rp in $rawPanes) {
                    if ($null -eq $rp) { continue }
                    [void]$normPanes.Add([pscustomobject]@{
                        id           = [int](Get-RpcParam $rp @('id', 'Id') $idx)
                        session_key  = [string](Get-RpcParam $rp @('session_key', 'sessionKey', 'SessionKey') '')
                        width_weight = [double](Get-RpcParam $rp @('width_weight', 'widthWeight', 'WidthWeight') 50)
                        show_summary = [bool](Get-RpcParam $rp @('show_summary', 'showSummary', 'ShowSummary') $false)
                    })
                    $idx++
                }
                if ($normPanes.Count -gt 0) {
                    $cur.Panes = $normPanes.ToArray()
                }
            }
            Save-WindowLayoutMemory -Context $script:HostContext -Layout $cur
            return (ConvertTo-SerializableLayout (Get-WindowLayoutMemory $script:HostContext))
        }

        'reset_layout' {
            [void](Reset-WindowLayoutMemory $script:HostContext)
            return (ConvertTo-SerializableLayout (Get-WindowLayoutMemory $script:HostContext))
        }

        'set_theme_mode' {
            $rawMode = [string](Get-RpcParam $Params @('themeMode', 'ThemeMode', 'mode', 'Mode') 'system')
            $normMode = Resolve-NormalizedThemeMode $rawMode
            $cur = Get-WindowLayoutMemory $script:HostContext
            $cur.ThemeMode = $normMode
            Save-WindowLayoutMemory -Context $script:HostContext -Layout $cur
            $sysTheme = ([string](Get-SystemThemePreference -ResetCache)).ToLowerInvariant()
            $effTheme = ([string](Resolve-EffectiveTheme -ThemeMode $normMode -SystemTheme $sysTheme)).ToLowerInvariant()
            return [pscustomobject]([ordered]@{
                themeMode      = $normMode
                systemTheme    = $sysTheme
                effectiveTheme = $effTheme
            })
        }

        'step_quick_theme' {
            $cur = Get-WindowLayoutMemory $script:HostContext
            $sysTheme = ([string](Get-SystemThemePreference -ResetCache)).ToLowerInvariant()
            $curEff = ([string](Resolve-EffectiveTheme -ThemeMode ([string]$cur.ThemeMode) -SystemTheme $sysTheme)).ToLowerInvariant()
            $act = [string](Get-RpcParam $Params @('action', 'Action') 'invert')
            $nextMode = ([string](Step-QuickThemeToggle -CurrentThemeMode ([string]$cur.ThemeMode) -EffectiveTheme $curEff -Action $act)).ToLowerInvariant()
            $cur.ThemeMode = $nextMode
            Save-WindowLayoutMemory -Context $script:HostContext -Layout $cur
            $newEff = ([string](Resolve-EffectiveTheme -ThemeMode $nextMode -SystemTheme $sysTheme)).ToLowerInvariant()
            return [pscustomobject]([ordered]@{
                themeMode      = $nextMode
                systemTheme    = $sysTheme
                effectiveTheme = $newEff
            })
        }

        'profile_save' {
            $settings = Read-ConnectionSettings $script:HostContext
            $profId = [string](Get-RpcParam $Params @('profileId', 'ProfileId', 'id', 'Id') '')
            $name = [string](Get-RpcParam $Params @('name', 'Name') '')
            $plat = [string](Get-RpcParam $Params @('platform', 'Platform') '')
            $kind = [string](Get-RpcParam $Params @('kind', 'Kind') '')
            $tunId = [string](Get-RpcParam $Params @('tunnelId', 'TunnelId') '')
            $baseUrl = [string](Get-RpcParam $Params @('baseUrl', 'BaseUrl', 'apiBaseUrl', 'ApiBaseUrl') '')
            $activate = Get-RpcBoolParam $Params @('activate', 'Activate', 'setActive', 'SetActive') $false
            $connectNow = Get-RpcBoolParam $Params @('connectNow', 'ConnectNow') $false
            $clearKey = Get-RpcBoolParam $Params @('clearKey', 'ClearKey') $false

            $saveArgs = @{
                Context   = $script:HostContext
                Settings  = $settings
                ProfileId = $profId
                Name      = $name
                Platform  = $plat
                Kind      = $kind
                TunnelId  = $tunId
                BaseUrl   = $baseUrl
            }
            if (Test-RpcHasParam $Params @('enabled', 'Enabled')) {
                $enVal = Get-RpcParam $Params @('enabled', 'Enabled') $null
                if ($null -ne $enVal) {
                    $saveArgs['Enabled'] = [bool]$enVal
                }
            }
            if ($activate -or $connectNow) {
                $saveArgs['SetActive'] = $true
            }
            if (Test-RpcHasParam $Params @('apiKey', 'ApiKey', 'token', 'Token')) {
                $rawKeyVal = Get-RpcParam $Params @('apiKey', 'ApiKey', 'token', 'Token') $null
                if ($null -ne $rawKeyVal -and ([string]$rawKeyVal).Trim().Length -gt 0) {
                    $saveArgs['ApiKey'] = [string]$rawKeyVal
                } elseif ($clearKey) {
                    $saveArgs['ApiKey'] = ''
                }
            } elseif ($clearKey) {
                $saveArgs['ApiKey'] = ''
            }

            $savedState = Save-ConnectionProfile @saveArgs
            $savedId = [string]$savedState.LastSavedProfileId
            if ($connectNow -and (-not $script:HostContext.Isolated)) {
                $savedProf = $savedState.Profiles | Where-Object { $_.Id -eq $savedId } | Select-Object -First 1
                if ($savedProf) {
                    if ($savedProf.Platform -eq 'chatgpt') {
                        [void](Select-ConnectionProfile -Context $script:HostContext -ProfileId $savedId -AutoReconnect)
                    } else {
                        $selRes = Select-ConnectionProfile -Context $script:HostContext -ProfileId $savedId
                        $actPub = $selRes.ActiveProfile
                        $sPort = if ($settings.PSObject.Properties['shield_port'] -and [int]$settings.shield_port -gt 0) { [int]$settings.shield_port } else { 8766 }
                        $coreEp = try { Get-OfficialCoreEndpoint $settings } catch { 'http://127.0.0.1:8765/mcp' }
                        if (-not (Test-LocalUrlPortOpen "http://127.0.0.1:$sPort")) {
                            [void](Start-ReadOnlyShield $script:HostContext $settings $coreEp)
                        }
                        Stop-PublicMcpTunnel $script:HostContext
                        [void](Start-PublicMcpTunnel -Context $script:HostContext -FixedDomain ([string]$actPub.BaseUrl) -Token ([string]$actPub.PlainKey) -Port $sPort -ProfileId $savedId -ForceReconnect)
                    }
                }
            }
            $script:DisplaySummaryCache = $null
            return (Get-RelayHostInfraBundle -DeepPublicProbe:$connectNow -ForceDisplayProbe)
        }

        'profile_remove' {
            $profId = [string](Get-RpcParam $Params @('profileId', 'ProfileId', 'id', 'Id') '')
            [void](Remove-ConnectionProfile -Context $script:HostContext -ProfileId $profId)
            $script:DisplaySummaryCache = $null
            return (Get-RelayHostInfraBundle)
        }

        'profile_select' {
            $profId = [string](Get-RpcParam $Params @('profileId', 'ProfileId', 'id', 'Id') '')
            $reconnectVal = Get-RpcBoolParam $Params @('reconnect', 'Reconnect', 'autoReconnect', 'AutoReconnect') $false

            $settings = Read-ConnectionSettings $script:HostContext
            $curState = Get-ConnectionProfiles $script:HostContext $settings
            $target = $curState.Profiles | Where-Object { $_.Id -eq $profId } | Select-Object -First 1
            if (-not $target) {
                throw "找不到指定的连接配置 ($profId)。"
            }

            $didPublicReconnect = $false
            if ($target.Platform -eq 'chatgpt') {
                $doAuto = $reconnectVal -and (-not $script:HostContext.Isolated)
                [void](Select-ConnectionProfile -Context $script:HostContext -Settings $settings -ProfileId $profId -AutoReconnect:$doAuto)
            } else {
                $selRes = Select-ConnectionProfile -Context $script:HostContext -Settings $settings -ProfileId $profId
                if ($reconnectVal -and (-not $script:HostContext.Isolated)) {
                    $actPub = $selRes.ActiveProfile
                    $sPort = if ($settings.PSObject.Properties['shield_port'] -and [int]$settings.shield_port -gt 0) { [int]$settings.shield_port } else { 8766 }
                    $coreEp = try { Get-OfficialCoreEndpoint $settings } catch { 'http://127.0.0.1:8765/mcp' }
                    if (-not (Test-LocalUrlPortOpen "http://127.0.0.1:$sPort")) {
                        [void](Start-ReadOnlyShield $script:HostContext $settings $coreEp)
                    }
                    Stop-PublicMcpTunnel $script:HostContext
                    [void](Start-PublicMcpTunnel -Context $script:HostContext -FixedDomain ([string]$actPub.BaseUrl) -Token ([string]$actPub.PlainKey) -Port $sPort -ProfileId $profId -ForceReconnect)
                    $didPublicReconnect = $true
                }
            }
            $script:DisplaySummaryCache = $null
            return (Get-RelayHostInfraBundle -DeepPublicProbe:$didPublicReconnect -ForceDisplayProbe)
        }

        'profile_toggle_enabled' {
            $profId = [string](Get-RpcParam $Params @('profileId', 'ProfileId', 'id', 'Id') '')
            $curState = Get-ConnectionProfiles $script:HostContext
            $target = $curState.Profiles | Where-Object { $_.Id -eq $profId } | Select-Object -First 1
            if (-not $target) {
                throw "找不到指定的平台配置 ($profId)。"
            }
            $newEnabled = if (Test-RpcHasParam $Params @('enabled', 'Enabled')) {
                [bool](Get-RpcParam $Params @('enabled', 'Enabled') $false)
            } else {
                (-not [bool]$target.Enabled)
            }
            [void](Set-ConnectionProfileEnabled -Context $script:HostContext -ProfileId $profId -Enabled $newEnabled)
            return (Get-RelayHostInfraBundle)
        }

        'profile_get_secret' {
            $profId = [string](Get-RpcParam $Params @('profileId', 'ProfileId', 'id', 'Id') '')
            $settings = Read-ConnectionSettings $script:HostContext
            $profs = Get-ConnectionProfiles $script:HostContext $settings
            $prof = if ($profId) {
                $profs.Profiles | Where-Object { $_.Id -eq $profId } | Select-Object -First 1
            } else {
                $null
            }
            if ($prof -and $prof.PSObject.Properties['PlainKey'] -and ([string]$prof.PlainKey).Length -gt 0) {
                return [pscustomobject]([ordered]@{
                    ok             = $true
                    secret         = [string]$prof.PlainKey
                    isDefaultOAuth = $false
                })
            } elseif ($prof -and ([string]$prof.Platform).Trim().ToLowerInvariant() -in @('gemini', 'claude')) {
                return [pscustomobject]([ordered]@{
                    ok             = $true
                    secret         = 'relaystudio'
                    isDefaultOAuth = $true
                })
            } else {
                return [pscustomobject]([ordered]@{
                    ok             = $true
                    secret         = ''
                    isDefaultOAuth = $false
                })
            }
        }

        'capsule_add_platform' {
            $plat = [string](Get-RpcParam $Params @('platform', 'Platform') '')
            [void](Add-CapsulePlatform -Context $script:HostContext -Platform $plat)
            return (Get-RelayHostInfraBundle)
        }

        'capsule_remove_platform' {
            $plat = ([string](Get-RpcParam $Params @('platform', 'Platform') '')).Trim().ToLowerInvariant()
            if ($plat -eq 'openai') { $plat = 'chatgpt' }
            $afterState = Remove-CapsulePlatform -Context $script:HostContext -Platform $plat
            if (-not $script:HostContext.Isolated) {
                $remPlats = @($afterState.EnabledPlatforms)
                if ($plat -in @('gemini', 'claude') -and ($remPlats -notcontains 'gemini') -and ($remPlats -notcontains 'claude')) {
                    try { Stop-PublicMcpTunnel $script:HostContext } catch { }
                } elseif ($plat -eq 'chatgpt') {
                    try { [void](Stop-ConnectionTunnel $script:HostContext (Read-ConnectionSettings $script:HostContext)) } catch { }
                }
            }
            $script:DisplaySummaryCache = $null
            return (Get-RelayHostInfraBundle -ForceDisplayProbe)
        }

        'openai_tunnel_connect' {
            $settings = Read-ConnectionSettings $script:HostContext
            $reqProfId = ([string](Get-RpcParam $Params @('profileId', 'ProfileId', 'id', 'Id') '')).Trim()
            if ($reqProfId) {
                [void](Select-ConnectionProfile -Context $script:HostContext -Settings $settings -ProfileId $reqProfId -AutoReconnect:$false)
                $settings = Read-ConnectionSettings $script:HostContext
            }
            if (-not $script:HostContext.Isolated) {
                if (@(Get-RelatedTunnelProcesses $script:HostContext $settings).Count -gt 0) {
                    [void](Stop-ConnectionTunnel $script:HostContext $settings)
                    $hPort = if ($settings.PSObject.Properties['health_port'] -and [int]$settings.health_port -gt 0) { [int]$settings.health_port } else { 8789 }
                    $stopDeadline = [DateTime]::UtcNow.AddMilliseconds(1500)
                    while ([DateTime]::UtcNow -lt $stopDeadline) {
                        if ((@(Get-RelatedTunnelProcesses $script:HostContext $settings).Count -eq 0) -and (-not (Test-LocalTcpPortOpen -Port $hPort))) {
                            break
                        }
                        Start-Sleep -Milliseconds 80
                    }
                }
                [void](Start-ConnectionTunnel $script:HostContext $settings)
            }
            $script:GuardianOpenAiStrikes = 0
            $script:GuardianOpenAiNextRetryUtc = [DateTime]::MinValue
            $script:DisplaySummaryCache = $null
            return (Get-RelayHostInfraBundle -ForceDisplayProbe)
        }

        'openai_tunnel_disconnect' {
            $settings = Read-ConnectionSettings $script:HostContext
            if (-not $script:HostContext.Isolated) {
                [void](Stop-ConnectionTunnel $script:HostContext $settings)
            }
            $script:DisplaySummaryCache = $null
            return (Get-RelayHostInfraBundle -ForceDisplayProbe)
        }

        'public_tunnel_connect' {
            $settings = Read-ConnectionSettings $script:HostContext
            $sPort = if ($settings.PSObject.Properties['shield_port'] -and [int]$settings.shield_port -gt 0) { [int]$settings.shield_port } else { 8766 }
            $profs = Get-ConnectionProfiles $script:HostContext $settings
            $reqProfId = [string](Get-RpcParam $Params @('profileId', 'ProfileId', 'id', 'Id') '')
            $reqPlat = ([string](Get-RpcParam $Params @('platform', 'Platform') '')).Trim().ToLowerInvariant()

            $prof = $null
            if ($reqProfId) {
                $selRes = Select-ConnectionProfile -Context $script:HostContext -Settings $settings -ProfileId $reqProfId
                $prof = $selRes.ActiveProfile
            } elseif ($reqPlat -and $reqPlat -in @('gemini', 'claude')) {
                $prof = $profs.Profiles | Where-Object { $_.Platform -eq $reqPlat -and $_.IsActive } | Select-Object -First 1
            } else {
                $prof = $profs.Profiles | Where-Object { $_.Platform -in @('gemini', 'claude') -and $_.IsActive } | Select-Object -First 1
            }

            $fDom = if (Test-RpcHasParam $Params @('fixedDomain', 'FixedDomain', 'baseUrl', 'BaseUrl')) {
                [string](Get-RpcParam $Params @('fixedDomain', 'FixedDomain', 'baseUrl', 'BaseUrl') '')
            } elseif ($prof) {
                [string]$prof.BaseUrl
            } else { '' }
            $fTok = if (Test-RpcHasParam $Params @('token', 'Token')) {
                [string](Get-RpcParam $Params @('token', 'Token') '')
            } elseif ($prof) {
                [string]$prof.PlainKey
            } else { '' }
            $fPid = if ($prof) { [string]$prof.Id } else { $reqProfId }

            if (-not $script:HostContext.Isolated) {
                $coreEp = try { Get-OfficialCoreEndpoint $settings } catch { 'http://127.0.0.1:8765/mcp' }
                if (-not (Test-LocalUrlPortOpen "http://127.0.0.1:$sPort")) {
                    [void](Start-ReadOnlyShield $script:HostContext $settings $coreEp)
                }
            }
            $hasTs = [bool](Get-TailscaleFunnelSelfUrl -Context $script:HostContext)
            Stop-PublicMcpTunnel $script:HostContext
            [void](Start-PublicMcpTunnel -Context $script:HostContext -FixedDomain $fDom -Token $fTok -Port $sPort -ProfileId $fPid -PreferTailscale:$hasTs -ForceReconnect)
            $script:GuardianPublicStrikes = 0
            $script:GuardianPublicNextRetryUtc = [DateTime]::MinValue
            return (Get-RelayHostInfraBundle -DeepPublicProbe)
        }

        'public_tunnel_disconnect' {
            Stop-PublicMcpTunnel $script:HostContext
            return (Get-RelayHostInfraBundle -DeepPublicProbe)
        }

        'one_click_reconnect' {
            Reset-RelayHostBridgeCaches -ResetGuardian
            $settings = Read-ConnectionSettings $script:HostContext
            if (-not $script:HostContext.Isolated) {
                try { [void](Start-OfficialCoreIfNeeded $script:HostContext $settings) } catch { }
                $coreEp = try { Get-OfficialCoreEndpoint $settings } catch { 'http://127.0.0.1:8765/mcp' }
                $sPort = if ($settings.PSObject.Properties['shield_port'] -and [int]$settings.shield_port -gt 0) { [int]$settings.shield_port } else { 8766 }
                if (-not (Test-LocalUrlPortOpen "http://127.0.0.1:$sPort")) {
                    try { [void](Start-ReadOnlyShield $script:HostContext $settings $coreEp) } catch { }
                }
                $profs = Get-ConnectionProfiles $script:HostContext $settings
                $enPlats = @($profs.EnabledPlatforms)
                if ($enPlats -contains 'chatgpt') {
                    $actChat = $profs.Profiles | Where-Object { $_.Platform -eq 'chatgpt' -and $_.IsActive } | Select-Object -First 1
                    if ($actChat -and $actChat.HasKey -and $actChat.TunnelId) {
                        try { [void](Stop-ConnectionTunnel $script:HostContext $settings) } catch { }
                        try { [void](Start-ConnectionTunnel $script:HostContext $settings) } catch { }
                    }
                }
                if (($enPlats -contains 'gemini') -or ($enPlats -contains 'claude')) {
                    $pubProf = $profs.Profiles | Where-Object { $_.Platform -in @('gemini', 'claude') -and $_.IsActive } | Select-Object -First 1
                    $fDom = if ($pubProf) { [string]$pubProf.BaseUrl } else { '' }
                    $fTok = if ($pubProf) { [string]$pubProf.PlainKey } else { '' }
                    $fPid = if ($pubProf) { [string]$pubProf.Id } else { '' }
                    $hasTs = [bool](Get-TailscaleFunnelSelfUrl -Context $script:HostContext)
                    try { Stop-PublicMcpTunnel $script:HostContext } catch { }
                    try { [void](Start-PublicMcpTunnel -Context $script:HostContext -FixedDomain $fDom -Token $fTok -Port $sPort -ProfileId $fPid -PreferTailscale:$hasTs -ForceReconnect) } catch { }
                }
                try { [void](Repair-RelayProcessPriority $script:HostContext $settings) } catch { }
                $script:DisplaySummaryCache = $null
            }
            return (Get-RelayHostInfraBundle -DeepPublicProbe -ForceDisplayProbe)
        }

        'restart_core' {
            $settings = Read-ConnectionSettings $script:HostContext
            [void](Restart-LocalCoreEngine $script:HostContext $settings)
            $script:DisplaySummaryCache = $null
            return (Get-RelayHostInfraBundle -ForceDisplayProbe)
        }

        'save_engine_config' {
            if (Test-RpcHasParam $Params @('acpMaxConcurrentPrompts', 'AcpMaxConcurrentPrompts')) {
                $acpLim = [int](Get-RpcParam $Params @('acpMaxConcurrentPrompts', 'AcpMaxConcurrentPrompts') 4)
                [void](Set-AcpConcurrencyLimit -Context $script:HostContext -Limit $acpLim)
            }
            $cfgSplat = @{ Context = $script:HostContext }
            if (Test-RpcHasParam $Params @('acpDefaultProfile', 'AcpDefaultProfile')) {
                $cfgSplat['AcpDefaultProfile'] = [string](Get-RpcParam $Params @('acpDefaultProfile', 'AcpDefaultProfile') '')
            }
            if (Test-RpcHasParam $Params @('browserEnabled', 'BrowserEnabled')) {
                $bVal = Get-RpcParam $Params @('browserEnabled', 'BrowserEnabled') $null
                if ($null -ne $bVal) { $cfgSplat['BrowserEnabled'] = [bool]$bVal }
            }
            if (Test-RpcHasParam $Params @('startupMode', 'StartupMode')) {
                $smRaw = ([string](Get-RpcParam $Params @('startupMode', 'StartupMode') '')).Trim().ToLowerInvariant()
                $smMapped = if ($smRaw -eq 'window') { 'popup' } else { $smRaw }
                if ($smMapped -in @('popup', 'tray', 'off')) {
                    $cfgSplat['StartupMode'] = $smMapped
                }
            }
            if (Test-RpcHasParam $Params @('autoArchiveCompletedMode', 'AutoArchiveCompletedMode')) {
                $cfgSplat['AutoArchiveCompletedMode'] = [string](Get-RpcParam $Params @('autoArchiveCompletedMode', 'AutoArchiveCompletedMode') '')
            }
            if (Test-RpcHasParam $Params @('defaultBrowserProfile', 'DefaultBrowserProfile')) {
                $cfgSplat['DefaultBrowserProfile'] = [string](Get-RpcParam $Params @('defaultBrowserProfile', 'DefaultBrowserProfile') '')
            }
            [void](Set-CoreEngineConfig @cfgSplat)
            $script:CachedCliAgents = $null
            $script:CachedBrowserProfiles = $null
            return (Get-RelayHostInfraBundle)
        }

        'add_cli_agent_path' {
            $cmdPath = [string](Get-RpcParam $Params @('path', 'Path', 'commandPath', 'CommandPath', 'command', 'Command') '')
            $dispName = [string](Get-RpcParam $Params @('displayName', 'DisplayName', 'name', 'Name') '')
            $cliArgs = @(if (Test-RpcHasParam $Params @('args', 'Args')) {
                @(Get-RpcParam $Params @('args', 'Args') @()) | ForEach-Object { [string]$_ }
            })
            [void](Add-CustomCliAgent -Context $script:HostContext -CommandPath $cmdPath -DisplayName $dispName -Args $cliArgs)
            $script:CachedCliAgents = $null
            return (Get-RelayHostInfraBundle)
        }

        'pick_and_add_cli_agent' {
            $cmdPath = [string](Get-RpcParam $Params @('path', 'Path', 'commandPath', 'CommandPath', 'command', 'Command') '')
            if (-not $cmdPath) {
                return [pscustomobject]([ordered]@{ cancelled = $true })
            }
            $dispName = [string](Get-RpcParam $Params @('displayName', 'DisplayName', 'name', 'Name') '')
            $cliArgs = @(if (Test-RpcHasParam $Params @('args', 'Args')) {
                @(Get-RpcParam $Params @('args', 'Args') @()) | ForEach-Object { [string]$_ }
            })
            [void](Add-CustomCliAgent -Context $script:HostContext -CommandPath $cmdPath -DisplayName $dispName -Args $cliArgs)
            $script:CachedCliAgents = $null
            return [pscustomobject]([ordered]@{
                cancelled = $false
                infra     = (Get-RelayHostInfraBundle)
            })
        }

        'open_session_web' {
            $sessParam = Get-RpcParam $Params @('session', 'Session') $null
            $srcObj = if ($null -ne $sessParam) { $sessParam } else { $Params }
            $sKey = [string](Get-RpcParam $srcObj @('SessionKey', 'sessionKey', 'session_key') '')
            if (-not $sKey) { throw '未指定会话标识 (SessionKey)，无法打开对应网页。' }
            $sessObj = [pscustomobject]@{
                SessionKey     = $sKey
                WfrId          = [string](Get-RpcParam $srcObj @('WfrId', 'wfrId', 'wfr_id') '')
                Title          = [string](Get-RpcParam $srcObj @('Title', 'title', 'ShortTitle', 'shortTitle') '')
                ShortTitle     = [string](Get-RpcParam $srcObj @('ShortTitle', 'shortTitle', 'Title', 'title') '')
                BrowserProfile = [string](Get-RpcParam $srcObj @('BrowserProfile', 'browserProfile', 'browser_profile') '')
                Provider       = [string](Get-RpcParam $srcObj @('Provider', 'provider') '')
            }
            $prov = [string](Get-RpcParam $Params @('provider', 'Provider') $sessObj.Provider)
            $reqBound = [bool](Get-RpcParam $Params @('requireBoundConversation', 'RequireBoundConversation', 'requireBound') $false)
            $openRes = Open-SessionWebPage -Context $script:HostContext -Session $sessObj -Provider $prov -RequireBoundConversation:$reqBound
            return [pscustomobject]([ordered]@{
                ok     = $true
                action = $(if ($openRes -and $openRes.PSObject.Properties['Action']) { [string]$openRes.Action } else { '' })
                url    = $(if ($openRes -and $openRes.PSObject.Properties['Url']) { [string]$openRes.Url } else { '' })
            })
        }

        'open_handover_window' {
            $url = [string](Get-RpcParam $Params @('url', 'Url') 'https://chatgpt.com/?relay_handover=1')
            $bProf = [string](Get-RpcParam $Params @('browserProfile', 'BrowserProfile', 'browser_profile') '')
            if (-not $script:HostContext.Isolated) {
                [void](Open-BridgeHandoverWindow -Url $url -BrowserProfile $bProf -Context $script:HostContext)
            }
            return [pscustomobject]([ordered]@{ ok = $true })
        }

        'open_workspace_folder' {
            $folderPath = [string](Get-RpcParam $Params @('path', 'Path', 'workspaceRoot', 'WorkspaceRoot', 'folder', 'Folder') '')
            if (-not $folderPath) {
                $folderPath = [string]$script:HostContext.DataRoot
            }
            if ((-not $script:HostContext.Isolated) -and (Test-Path -LiteralPath $folderPath)) {
                $fullDir = [IO.Path]::GetFullPath($folderPath)
                Start-Process explorer.exe -ArgumentList ('"' + $fullDir + '"') | Out-Null
            }
            return [pscustomobject]([ordered]@{ ok = $true })
        }

        'get_workspace_commits' {
            $wsRoot = [string](Get-RpcParam $Params @('workspaceRoot', 'WorkspaceRoot', 'path', 'Path') '')
            $wsName = [string](Get-RpcParam $Params @('workspaceName', 'WorkspaceName', 'name', 'Name') '')
            $rawCommits = @(Get-WorkspaceRecentCommits -Context $script:HostContext -WorkspaceRoot $wsRoot -WorkspaceName $wsName)
            $normCommits = New-Object 'System.Collections.Generic.List[object]'
            foreach ($c in $rawCommits) {
                if ($null -eq $c) { continue }
                $shortSha = if ($c.PSObject.Properties['ShortHash'] -and $c.ShortHash) { [string]$c.ShortHash } elseif ($c.PSObject.Properties['Sha']) { [string]$c.Sha } else { '' }
                $fullSha = if ($c.PSObject.Properties['Hash'] -and $c.Hash) { [string]$c.Hash } else { $shortSha }
                $subj = if ($c.PSObject.Properties['Subject'] -and $c.Subject) { [string]$c.Subject } elseif ($c.PSObject.Properties['Message']) { [string]$c.Message } else { '' }
                $tAgo = if ($c.PSObject.Properties['TimeAgo'] -and $c.TimeAgo) { [string]$c.TimeAgo } elseif ($c.PSObject.Properties['AgoText']) { [string]$c.AgoText } elseif ($c.PSObject.Properties['TimeText']) { [string]$c.TimeText } else { '' }
                $auth = if ($c.PSObject.Properties['Author'] -and $c.Author) { [string]$c.Author } else { '' }
                [void]$normCommits.Add([pscustomobject]([ordered]@{
                    Hash      = $fullSha
                    ShortHash = $shortSha
                    Subject   = $subj
                    TimeAgo   = $tAgo
                    Author    = $auth
                }))
            }
            return [pscustomobject]([ordered]@{
                commits = [object[]]@($normCommits.ToArray())
            })
        }

        'repair_priority' {
            $settings = Read-ConnectionSettings $script:HostContext
            [void](Repair-RelayProcessPriority $script:HostContext $settings)
            return [pscustomobject]([ordered]@{ ok = $true })
        }

        'rescan_cli_agents' {
            $script:CachedCliAgents = $null
            $settings = Read-ConnectionSettings $script:HostContext
            [void](Get-CachedHostCliAgents -Settings $settings -Force)
            return (Get-RelayHostInfraBundle)
        }

        'open_browser_bridge_dir' {
            $baseRoot = if ($PSScriptRoot) { $PSScriptRoot } else { $script:BaseDirectory }
            $bridgeDir = Join-Path $baseRoot 'browser-bridge'
            if (-not (Test-Path -LiteralPath $bridgeDir)) {
                $settings = Read-ConnectionSettings $script:HostContext
                if ($settings -and $settings.PSObject.Properties['runtime_root'] -and $settings.runtime_root) {
                    $altDir = Join-Path ([string]$settings.runtime_root) 'browser-bridge'
                    if (Test-Path -LiteralPath $altDir) {
                        $bridgeDir = $altDir
                    }
                }
            }
            $fullDir = [IO.Path]::GetFullPath($bridgeDir)
            if ((-not $script:HostContext.Isolated) -and (Test-Path -LiteralPath $fullDir)) {
                Start-Process explorer.exe -ArgumentList ('"' + $fullDir + '"') | Out-Null
            }
            return [pscustomobject]([ordered]@{
                ok   = $true
                path = $fullDir
            })
        }

        'shutdown_all_services' {
            if (-not $script:HostContext.Isolated) {
                try { [void](Stop-ConnectionTunnel $script:HostContext (Read-ConnectionSettings $script:HostContext)) } catch { }
                try { Stop-PublicMcpTunnel $script:HostContext } catch { }
                try { Get-Process -Name 'relaystudio-core' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
            }
            return [pscustomobject]([ordered]@{ ok = $true })
        }

        default {
            throw "未知的 HostBridge RPC 方法: $normMethod"
        }
    }
}

function Invoke-RelayHostRpc {
    param([string]$RequestJson)
    $reqId = ''
    try {
        if (-not $RequestJson -or -not $RequestJson.Trim()) {
            throw '空的 RPC 请求负载。'
        }
        $reqObj = $RequestJson | ConvertFrom-Json
        $reqId = if ($reqObj -and $reqObj.PSObject.Properties['id'] -and $null -ne $reqObj.id) { [string]$reqObj.id } else { '' }
        $method = if ($reqObj -and $reqObj.PSObject.Properties['method'] -and $reqObj.method) { [string]$reqObj.method } else { '' }
        if (-not $method) {
            throw 'RPC 请求缺少 method 字段。'
        }
        $paramsObj = if ($reqObj.PSObject.Properties['params']) { $reqObj.params } else { $null }
        $resObj = Invoke-RelayHostRpcObject -Method $method -Params $paramsObj
        $envelope = [pscustomobject]([ordered]@{
            type   = 'rpc_response'
            id     = $reqId
            ok     = $true
            result = $resObj
        })
        return ($envelope | ConvertTo-Json -Depth 12 -Compress)
    } catch {
        $errEnvelope = [pscustomobject]([ordered]@{
            type  = 'rpc_response'
            id    = $reqId
            ok    = $false
            error = [string]$_.Exception.Message
        })
        return ($errEnvelope | ConvertTo-Json -Depth 6 -Compress)
    }
}

function Get-GuardianBackoffSeconds {
    param([int]$Strikes)
    if ($Strikes -le 1) { return 20 }
    if ($Strikes -eq 2) { return 60 }
    return 300
}

function Invoke-RelayHostGuardianTick {
    Assert-RelayHostBridgeReady
    if ($script:SkipBootServices -or $script:HostContext.Isolated) {
        return [pscustomobject]([ordered]@{
            changed = $false
            infra   = $null
        })
    }

    $nowUtc = [DateTime]::UtcNow
    $settings = Read-ConnectionSettings $script:HostContext
    $healedAny = $false

    # 1. Core (:8765) guardian with 3-strike circuit breaker
    $coreEp = try { Get-OfficialCoreEndpoint $settings } catch { 'http://127.0.0.1:8765/mcp' }
    if ($coreEp -match '^http') {
        if (Test-LocalUrlPortOpen $coreEp) {
            $script:GuardianCoreStrikes = 0
        } elseif ($nowUtc -ge $script:GuardianCoreNextRetryUtc) {
            $okCore = $false
            try { $okCore = [bool](Start-OfficialCoreIfNeeded $script:HostContext $settings) } catch { $okCore = $false }
            if ($okCore) {
                $script:GuardianCoreStrikes = 0
                $healedAny = $true
            } else {
                $script:GuardianCoreStrikes++
                $script:GuardianCoreNextRetryUtc = $nowUtc.AddSeconds((Get-GuardianBackoffSeconds $script:GuardianCoreStrikes))
            }
        }
    }

    # 2. Shield (:8766) guardian with 3-strike circuit breaker
    $shieldPort = if ($settings.PSObject.Properties['shield_port'] -and [int]$settings.shield_port -gt 0) { [int]$settings.shield_port } else { 8766 }
    if (Test-LocalUrlPortOpen "http://127.0.0.1:$shieldPort") {
        $script:GuardianShieldStrikes = 0
    } elseif ($nowUtc -ge $script:GuardianShieldNextRetryUtc) {
        $okShield = $false
        try {
            [void](Start-ReadOnlyShield $script:HostContext $settings $coreEp)
            $okShield = (Test-LocalUrlPortOpen "http://127.0.0.1:$shieldPort")
        } catch { $okShield = $false }
        if ($okShield) {
            $script:GuardianShieldStrikes = 0
            $healedAny = $true
        } else {
            $script:GuardianShieldStrikes++
            $script:GuardianShieldNextRetryUtc = $nowUtc.AddSeconds((Get-GuardianBackoffSeconds $script:GuardianShieldStrikes))
        }
    }

    $profs = Get-ConnectionProfiles $script:HostContext $settings
    $enPlats = @($profs.EnabledPlatforms)

    # 3. OpenAI Tunnel (:8789) guardian with 3-strike circuit breaker
    $disp = Get-FastConnectionDisplaySummary -Settings $settings -ForceProbe
    if ($enPlats -contains 'chatgpt') {
        $actChat = $profs.Profiles | Where-Object { $_.Platform -eq 'chatgpt' -and $_.IsActive } | Select-Object -First 1
        if ($disp.Running -and (-not $disp.IsFault)) {
            $script:GuardianOpenAiStrikes = 0
        } elseif ($actChat -and $actChat.HasKey -and $actChat.TunnelId -and (-not $disp.Running) -and ($nowUtc -ge $script:GuardianOpenAiNextRetryUtc)) {
            $okTun = $false
            try {
                [void](Start-ConnectionTunnel $script:HostContext $settings)
                $okTun = $true
            } catch { $okTun = $false }
            if ($okTun) {
                $script:GuardianOpenAiStrikes = 0
                $healedAny = $true
                $disp = Get-FastConnectionDisplaySummary -Settings $settings -ForceProbe
            } else {
                $script:GuardianOpenAiStrikes++
                $script:GuardianOpenAiNextRetryUtc = $nowUtc.AddSeconds((Get-GuardianBackoffSeconds $script:GuardianOpenAiStrikes))
            }
        }
    }

    # 4. Public MCP Tunnel guardian with 2-strike / 3-strike backoff
    $pub = Get-PublicMcpTunnelState $script:HostContext
    if (($enPlats -contains 'gemini') -or ($enPlats -contains 'claude')) {
        if ($pub.Running) {
            $script:GuardianPublicStrikes = 0
        } elseif ($nowUtc -ge $script:GuardianPublicNextRetryUtc) {
            $pubProf = $profs.Profiles | Where-Object { $_.Platform -in @('gemini', 'claude') -and $_.IsActive -and ($_.BaseUrl -or $_.PlainKey) } | Select-Object -First 1
            $hasTs = [bool](Get-TailscaleFunnelSelfUrl -Context $script:HostContext)
            if ($pubProf -or $hasTs) {
                $okPub = $false
                try {
                    $fDom = if ($pubProf) { [string]$pubProf.BaseUrl } else { '' }
                    $fTok = if ($pubProf) { [string]$pubProf.PlainKey } else { '' }
                    $fPid = if ($pubProf) { [string]$pubProf.Id } else { '' }
                    $stPub = Start-PublicMcpTunnel -Context $script:HostContext -FixedDomain $fDom -Token $fTok -Port $shieldPort -ProfileId $fPid -PreferTailscale:$hasTs -ForceReconnect
                    $okPub = [bool]($stPub -and $stPub.Running)
                } catch { $okPub = $false }
                $pub = Get-PublicMcpTunnelState $script:HostContext
                if ($okPub) {
                    $script:GuardianPublicStrikes = 0
                    $healedAny = $true
                } else {
                    $script:GuardianPublicStrikes++
                    $script:GuardianPublicNextRetryUtc = $nowUtc.AddSeconds((Get-GuardianBackoffSeconds $script:GuardianPublicStrikes))
                }
            }
        }
    }

    $digestSig = "$($disp.Core)|$($disp.Tunnel)|$($disp.Running)|$($disp.IsFault)|$($disp.RunningProfileId)|$($disp.RunningTunnelId)|$($pub.Running)|$($pub.Status)|$($pub.HealthPhase)|$($pub.PublicRttMs)|$($pub.Url)"
    $hadPrevSig = ($script:GuardianLastDigestSig -ne '')
    $sigChanged = ($hadPrevSig -and ($script:GuardianLastDigestSig -ne $digestSig))
    $script:GuardianLastDigestSig = $digestSig

    if ($healedAny -or $sigChanged) {
        return [pscustomobject]([ordered]@{
            changed = $true
            infra   = (Get-RelayHostInfraBundle -ForceDisplayProbe)
        })
    }
    return [pscustomobject]([ordered]@{
        changed = $false
        infra   = $null
    })
}

function Invoke-RelayHostGuardianTickJson {
    $res = Invoke-RelayHostGuardianTick
    return ($res | ConvertTo-Json -Depth 12 -Compress)
}
