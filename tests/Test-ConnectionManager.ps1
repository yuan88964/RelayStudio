param([string]$EvidenceRoot = (Join-Path ([IO.Path]::GetTempPath()) 'relaystudio-test-outputs'), [switch]$PublicTunnelOnly, [switch]$ModelCatalogOnly, [switch]$SkipPythonSeams)

$ErrorActionPreference='Stop'

$managerRoot=Split-Path $PSScriptRoot -Parent

Import-Module (Join-Path $managerRoot 'ConnectionManager.psm1') -Force

$scratchParent=(Join-Path ([IO.Path]::GetTempPath()) 'relaystudio-test-work')

$testRoot=Join-Path $scratchParent ('connection-test-' + [Guid]::NewGuid().ToString('N'))

[IO.Directory]::CreateDirectory($testRoot) | Out-Null

$script:passed=0

function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:passed++ }

function Assert-Throws([scriptblock]$Action,[string]$Message) { $thrown=$false;try { & $Action | Out-Null }catch { $thrown=$true }; Assert $thrown $Message }

function Invoke-UnifiedPublicTunnelPoolAndEnvTests {
    param([string]$SuiteRoot, [string]$RepoRoot)

    # A. Resolve-CloudflaredClientPath prioritizes ReleaseRoot\bin\cloudflared.exe & repo bin\cloudflared.exe
    $cfStageRoot = Join-Path $SuiteRoot 'cf-rel'
    $cfStageBin = Join-Path $cfStageRoot 'bin'
    [IO.Directory]::CreateDirectory($cfStageBin) | Out-Null
    $stagedCfExe = Join-Path $cfStageBin 'cloudflared.exe'
    [IO.File]::WriteAllBytes($stagedCfExe, [byte[]](0x4D, 0x5A, 0x90, 0x00))
    $cfCtx = New-ConnectionContext -DataRoot (Join-Path $SuiteRoot 'cf-data') -ReleaseRoot $cfStageRoot -Isolated
    Assert ((Resolve-CloudflaredClientPath -Context $cfCtx -SkipScriptRootFallback) -eq $stagedCfExe) 'Resolve-CloudflaredClientPath checks ReleaseRoot\bin\cloudflared.exe first'
    if (Test-Path -LiteralPath (Join-Path $RepoRoot 'bin\cloudflared.exe')) {
        $repoResolvedCf = Resolve-CloudflaredClientPath -Context (New-ConnectionContext -DataRoot (Join-Path $SuiteRoot 'cf-data2') -ReleaseRoot (Join-Path $SuiteRoot 'empty-rel') -Isolated)
        Assert ($repoResolvedCf -eq (Join-Path $RepoRoot 'bin\cloudflared.exe')) 'Resolve-CloudflaredClientPath resolves PSScriptRoot\bin\cloudflared.exe'
    }

    # B. Resolve-PythonExePath skips WindowsApps stub & 0-byte files and throws clear Chinese error when none valid
    $pyTestDir = Join-Path $SuiteRoot 'py-discovery'
    $winAppsDir = Join-Path $pyTestDir 'Microsoft\WindowsApps'
    $zeroDir = Join-Path $pyTestDir 'ZeroStub'
    $realPyDir = Join-Path $pyTestDir 'OfficialPython312'
    [IO.Directory]::CreateDirectory($winAppsDir) | Out-Null
    [IO.Directory]::CreateDirectory($zeroDir) | Out-Null
    [IO.Directory]::CreateDirectory($realPyDir) | Out-Null
    $winAppsPy = Join-Path $winAppsDir 'python.exe'
    $zeroPy = Join-Path $zeroDir 'python.exe'
    $validPy = Join-Path $realPyDir 'python.exe'
    [IO.File]::WriteAllBytes($winAppsPy, [byte[]](0x4D, 0x5A, 0x01, 0x02))
    [IO.File]::WriteAllBytes($zeroPy, [byte[]]@())
    [IO.File]::WriteAllBytes($validPy, [byte[]](0x4D, 0x5A, 0x90, 0x00))

    $resolvedPy = Resolve-PythonExePath -CandidatePathsOverride @($winAppsPy, $zeroPy, $validPy)
    Assert ($resolvedPy -eq ([IO.Path]::GetFullPath($validPy))) 'Resolve-PythonExePath skips Microsoft\WindowsApps stub and 0-byte python.exe'
    $pyErrMsg = ''
    try {
        [void](Resolve-PythonExePath -CandidatePathsOverride @($winAppsPy, $zeroPy))
    } catch {
        $pyErrMsg = [string]$_.Exception.Message
    }
    Assert ($pyErrMsg -eq '未检测到可用的 Python 3.11+ 环境（已跳过微软商店空壳别名），请先安装官方 Python 3.11+ 并勾选 Add to PATH。') "Resolve-PythonExePath throws exact Chinese guidance when only stubs exist (actual=$pyErrMsg)"

    # C. Resolve-PublicMcpDohIpv4List 1200ms default timeout & OS DNS public-IPv4 fallback when DoH fails
    $mod = Get-Module ConnectionManager
    $dohDefaultTimeout = & $mod { (Get-Command Resolve-PublicMcpDohIpv4List).Parameters['TimeoutMs'].Attributes | Out-Null; $ast = (Get-Command Resolve-PublicMcpDohIpv4List).ScriptBlock.Ast; ($ast.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'TimeoutMs' }).DefaultValue.Extent.Text }
    Assert ($dohDefaultTimeout -eq '1200') "Resolve-PublicMcpDohIpv4List default TimeoutMs is 1200 (actual=$dohDefaultTimeout)"
    try {
        Set-PublicMcpDnsTestOverrides -DisableDoh $true -SystemDnsOverride {
            param($TargetHost)
            return @(
                [Net.IPAddress]::Parse('198.18.0.25'),
                [Net.IPAddress]::Parse('100.100.100.100'),
                [Net.IPAddress]::Parse('127.0.0.1'),
                [Net.IPAddress]::Parse('192.168.1.10'),
                [Net.IPAddress]::Parse('103.84.155.153')
            )
        }
        $fallbackIps = @(Resolve-PublicMcpDohIpv4List -HostName 'fallback-check.example.com')
        Assert ($fallbackIps.Count -eq 1 -and $fallbackIps[0] -eq '103.84.155.153') 'Resolve-PublicMcpDohIpv4List falls back to OS DNS filtered through Test-IsPublicRoutableIpv4 when DoH fails'
    } finally {
        Set-PublicMcpDnsTestOverrides -DisableDoh $false -SystemDnsOverride $null
    }

    # D. Automatic Non-Destructive Migration & Deduplication from credential-profiles.json
    $migCtx = New-ConnectionContext -DataRoot (Join-Path $SuiteRoot 'pool-mig') -Isolated
    [void](Add-CapsulePlatform -Context $migCtx -Platform 'gemini')
    [void](Add-CapsulePlatform -Context $migCtx -Platform 'claude')
    $migProfs = Get-ConnectionProfiles $migCtx
    $gemProfId = ($migProfs.Profiles | Where-Object { $_.Platform -eq 'gemini' } | Select-Object -First 1).Id
    $claProfId = ($migProfs.Profiles | Where-Object { $_.Platform -eq 'claude' } | Select-Object -First 1).Id
    [void](Save-ConnectionProfile -Context $migCtx -ProfileId $gemProfId -Name 'yuanyang' -Platform 'gemini' -Kind 'public_tunnel' -BaseUrl 'https://thinkbook16pl.tail29988f.ts.net/' -SetActive)
    [void](Save-ConnectionProfile -Context $migCtx -ProfileId $claProfId -Name 'yuan' -Platform 'claude' -Kind 'public_tunnel' -BaseUrl 'https://thinkbook16pl.tail29988f.ts.net/mcp' -SetActive)

    Assert (-not (Test-Path -LiteralPath (Join-Path $migCtx.DataRoot 'public-tunnels.json'))) 'public-tunnels.json absent before first Get-PublicTunnelsPool'
    $migratedPool = Get-PublicTunnelsPool -Context $migCtx
    Assert (Test-Path -LiteralPath (Join-Path $migCtx.DataRoot 'public-tunnels.json')) 'Get-PublicTunnelsPool creates public-tunnels.json automatically'
    Assert ($migratedPool.Items.Count -eq 2) "Shared BaseUrl across gemini & claude deduplicates into 1 custom item + 1 builtin (count=$($migratedPool.Items.Count))"
    Assert ($migratedPool.Items[0].Id -eq 'pub_builtin_quick' -and $migratedPool.Items[0].Name -eq '免费临时隧道' -and $migratedPool.Items[0].IsBuiltin) 'First item is always built-in pub_builtin_quick (免费临时隧道)'
    $sharedCustom = $migratedPool.Items[1]
    Assert ($sharedCustom.Id -like 'pub_*' -and (-not $sharedCustom.IsBuiltin) -and $sharedCustom.Name -eq 'yuanyang' -and $sharedCustom.BaseUrl -eq 'https://thinkbook16pl.tail29988f.ts.net/mcp' -and $sharedCustom.Mode -eq 'tailscale') 'Migrated custom item preserves first custom Name and normalized /mcp BaseUrl'
    Assert ($migratedPool.SelectedByPlatform['gemini'] -eq $sharedCustom.Id -and $migratedPool.SelectedByPlatform['claude'] -eq $sharedCustom.Id) 'Both gemini and claude point to deduplicated shared tunnel id'

    # Partial migration: gemini has custom URL+Key, claude has none -> claude defaults to pub_builtin_quick
    $migCtx2 = New-ConnectionContext -DataRoot (Join-Path $SuiteRoot 'pool-mig2') -Isolated
    [void](Add-CapsulePlatform -Context $migCtx2 -Platform 'gemini')
    [void](Add-CapsulePlatform -Context $migCtx2 -Platform 'claude')
    $migProfs2 = Get-ConnectionProfiles $migCtx2
    $gemProfId2 = ($migProfs2.Profiles | Where-Object { $_.Platform -eq 'gemini' } | Select-Object -First 1).Id
    [void](Save-ConnectionProfile -Context $migCtx2 -ProfileId $gemProfId2 -Name 'CF专线A' -Platform 'gemini' -Kind 'public_tunnel' -BaseUrl 'https://cf-edge.example.com' -ApiKey 'eyJhTokenMigrated123456' -SetActive)
    $migratedPool2 = Get-PublicTunnelsPool -Context $migCtx2
    $cfMigItem = $migratedPool2.Items | Where-Object { -not $_.IsBuiltin } | Select-Object -First 1
    Assert ($null -ne $cfMigItem -and $cfMigItem.HasKey -and $cfMigItem.Mode -eq 'cloudflare_key' -and (Get-PublicTunnelItemSecret -Context $migCtx2 -TunnelId $cfMigItem.Id) -eq 'eyJhTokenMigrated123456') 'Migration encrypts PlainKey into public-tunnel-key-<id>.dpapi'
    Assert ($migratedPool2.SelectedByPlatform['gemini'] -eq $cfMigItem.Id -and $migratedPool2.SelectedByPlatform['claude'] -eq 'pub_builtin_quick') 'Platform without custom URL defaults to pub_builtin_quick'

    # E. CRUD, Builtin Protection, Rebinding on Delete & 4 Automatic Modes + Simultaneous Independent Runtime
    $poolCtx = New-ConnectionContext -DataRoot (Join-Path $SuiteRoot 'pool-rt') -Isolated
    Assert-Throws { Remove-PublicTunnelItem -Context $poolCtx -TunnelId 'pub_builtin_quick' } 'Built-in pub_builtin_quick cannot be deleted'
    Assert-Throws { Save-PublicTunnelItem -Context $poolCtx -TunnelId 'pub_builtin_quick' -Name 'Hack' } 'Built-in pub_builtin_quick cannot be modified'

    $savedNoUrlCf = Save-PublicTunnelItem -Context $poolCtx -Name '缺网址专线' -BaseUrl '' -StartupKey 'eyJhKeyWithoutUrl999'
    $noUrlCfId = $savedNoUrlCf.LastSavedTunnelId
    $noUrlRt = Start-PublicTunnelItem -Context $poolCtx -TunnelId $noUrlCfId
    Assert ((-not $noUrlRt.Running) -and $noUrlRt.Status -eq '连接失败' -and $noUrlRt.HealthPhase -eq 'Fault' -and $noUrlRt.ErrorReason -eq '请先在编辑中填写该隧道对应的公网网址，以便生成连接地址') 'cloudflare_key without BaseUrl fails immediately with exact guidance'

    # Compile fake-cloudflared-multi.exe supporting both quick (--url) and named (run --token) + bad-token exit
    $multiCfExe = Join-Path $SuiteRoot 'fake-cloudflared-multi.exe'
    $multiCfSrc = @'
using System;
using System.IO;
using System.Threading;
class FakeMultiCloudflared {
    static int Main(string[] args) {
        string logFile = "";
        string token = "";
        for (int i = 0; i < args.Length; i++) {
            if (args[i] == "--logfile" && i + 1 < args.Length) logFile = args[i + 1];
            if (args[i] == "--token" && i + 1 < args.Length) token = args[i + 1];
        }
        if (token == "BAD_TOKEN_EXIT") {
            if (!string.IsNullOrEmpty(logFile)) File.AppendAllText(logFile, "ERR invalid tunnel token\n");
            return 1;
        }
        if (!string.IsNullOrEmpty(logFile)) {
            if (string.IsNullOrEmpty(token)) {
                File.AppendAllText(logFile, "2026-11-12T00:00:00Z INF https://multi-quick-box.trycloudflare.com\n2026-11-12T00:00:01Z INF Registered tunnel connection connIndex=0\n");
            } else {
                File.AppendAllText(logFile, "2026-11-12T00:00:01Z INF Registered tunnel connection connIndex=0\n");
            }
        }
        Thread.Sleep(60000);
        return 0;
    }
}
'@
    $cscBin = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if ($PSVersionTable.PSEdition -eq 'Core' -and (Test-Path -LiteralPath $cscBin)) {
        $multiCsFile = Join-Path $SuiteRoot 'FakeMultiCloudflared.cs'
        [IO.File]::WriteAllText($multiCsFile, $multiCfSrc, [Text.Encoding]::UTF8)
        & $cscBin /nologo /target:exe /out:$multiCfExe $multiCsFile | Out-Null
    } else {
        Add-Type -TypeDefinition $multiCfSrc -OutputAssembly $multiCfExe -OutputType ConsoleApplication
    }

    $savedNamed = Save-PublicTunnelItem -Context $poolCtx -Name '主力CF专线' -BaseUrl 'https://named-tunnel.example.com' -StartupKey 'eyJhValidNamedToken888'
    $namedId = $savedNamed.LastSavedTunnelId
    $savedBadCf = Save-PublicTunnelItem -Context $poolCtx -Name '坏凭证专线' -BaseUrl 'https://bad-token.example.com' -StartupKey 'BAD_TOKEN_EXIT'
    $badCfId = $savedBadCf.LastSavedTunnelId

    try {
        # Simultaneous independent runtime: start pub_builtin_quick AND namedId concurrently!
        $rtQuick1 = Start-PublicTunnelItem -Context $poolCtx -TunnelId 'pub_builtin_quick' -ClientPath $multiCfExe
        $rtNamed1 = Start-PublicTunnelItem -Context $poolCtx -TunnelId $namedId -ClientPath $multiCfExe
        Assert ($rtQuick1.Running -and $rtQuick1.ProcessId -gt 0 -and $rtQuick1.EffectiveUrl -eq 'https://multi-quick-box.trycloudflare.com/mcp') 'pub_builtin_quick running with live PID and discovered trycloudflare /mcp URL'
        Assert ($rtNamed1.Running -and $rtNamed1.ProcessId -gt 0 -and $rtNamed1.EffectiveUrl -eq 'https://named-tunnel.example.com/mcp') 'Custom cloudflare_key tunnel running simultaneously with live PID'
        Assert ($rtQuick1.ProcessId -ne $rtNamed1.ProcessId) 'Simultaneous public tunnels run as distinct independent cloudflared processes'
        Assert ($null -ne (Get-Process -Id $rtQuick1.ProcessId -ErrorAction SilentlyContinue)) 'pub_builtin_quick process stayed alive when second tunnel started'

        # Restarting pub_builtin_quick ONLY restarts pub_builtin_quick, leaving namedId untouched!
        $origQuickPid = $rtQuick1.ProcessId
        $origNamedPid = $rtNamed1.ProcessId
        $rtQuick2 = Start-PublicTunnelItem -Context $poolCtx -TunnelId 'pub_builtin_quick' -ClientPath $multiCfExe
        $rtNamedCheck = Get-PublicTunnelItemRuntimeState -Context $poolCtx -Item ((Get-PublicTunnelsPool -Context $poolCtx).Items | Where-Object Id -eq $namedId)
        Assert ($rtQuick2.Running -and $rtQuick2.ProcessId -gt 0 -and $rtQuick2.ProcessId -ne $origQuickPid) 'Restarting item X spawns a fresh PID for item X'
        Assert ($rtNamedCheck.Running -and $rtNamedCheck.ProcessId -eq $origNamedPid -and ($null -ne (Get-Process -Id $origNamedPid -ErrorAction SilentlyContinue))) 'Restarting item X NEVER stops running item Y'

        # Bad token exits early -> exact Chinese ErrorReason without harming running tunnels
        $rtBad = Start-PublicTunnelItem -Context $poolCtx -TunnelId $badCfId -ClientPath $multiCfExe
        Assert ((-not $rtBad.Running) -and $rtBad.Status -eq '连接失败' -and $rtBad.HealthPhase -eq 'Fault' -and $rtBad.ErrorReason -eq '隧道启动凭证 Key 无效，或无法连接 Cloudflare 服务器') 'Invalid Cloudflare token reports exact ErrorReason'
        Assert ($null -ne (Get-Process -Id $origNamedPid -ErrorAction SilentlyContinue)) 'Failed start on item Z leaves item Y running'

        # Stopping pub_builtin_quick leaves namedId running
        Stop-PublicTunnelItem -Context $poolCtx -TunnelId 'pub_builtin_quick'
        $afterQuickStop = Get-PublicTunnelItemRuntimeState -Context $poolCtx -Item ((Get-PublicTunnelsPool -Context $poolCtx).Items | Where-Object Id -eq 'pub_builtin_quick')
        $afterQuickStopNamed = Get-PublicTunnelItemRuntimeState -Context $poolCtx -Item ((Get-PublicTunnelsPool -Context $poolCtx).Items | Where-Object Id -eq $namedId)
        Assert ((-not $afterQuickStop.Running) -and $afterQuickStopNamed.Running -and $afterQuickStopNamed.ProcessId -eq $origNamedPid) 'Stop-PublicTunnelItem stops only target item and keeps other tunnel alive'

        # Bind gemini to namedId, then remove namedId -> stops process and rebinds gemini back to pub_builtin_quick
        [void](Set-PlatformPublicTunnelBinding -Context $poolCtx -Platform 'gemini' -TunnelId $namedId)
        Assert ((Get-PublicTunnelsPool -Context $poolCtx).SelectedByPlatform['gemini'] -eq $namedId) 'Set-PlatformPublicTunnelBinding binds gemini to custom tunnel'
        $afterRemovePool = Remove-PublicTunnelItem -Context $poolCtx -TunnelId $namedId
        Assert ($afterRemovePool.SelectedByPlatform['gemini'] -eq 'pub_builtin_quick') 'Removing bound tunnel automatically rebinds platform back to pub_builtin_quick'
        Start-Sleep -Milliseconds 60
        Assert ($null -eq (Get-Process -Id $origNamedPid -ErrorAction SilentlyContinue)) 'Remove-PublicTunnelItem stops running process of deleted tunnel'
    } finally {
        Stop-AllPublicTunnelItems -Context $poolCtx
    }

    # F. Tailscale fast 3-step diagnostics (<50ms missing client, Fake-IP 198.18.*, LoggedOut, Funnel off) & External URL mode
    $tsSave = Save-PublicTunnelItem -Context $poolCtx -Name 'TS节点' -BaseUrl 'https://my-laptop.tail12345.ts.net'
    $tsId = $tsSave.LastSavedTunnelId
    $extSave = Save-PublicTunnelItem -Context $poolCtx -Name '外部FRP' -BaseUrl 'https://frp.custom-gateway.example.com'
    $extId = $extSave.LastSavedTunnelId

    try {
        # 1. Missing tailscale.exe (<50ms)
        Set-TailscaleTestOverrides -ClientPathOverride ''
        Set-PublicMcpEdgeProbeOverride { return [pscustomobject]@{ Reachable = $false; Phase = 'Offline'; PublicRttMs = 0; IngressIp = '' } }
        $swMissingTs = [Diagnostics.Stopwatch]::StartNew()
        $rtTsMissing = Start-PublicTunnelItem -Context $poolCtx -TunnelId $tsId
        $swMissingTs.Stop()
        Assert ((-not $rtTsMissing.Running) -and $rtTsMissing.ErrorReason -eq '本机未安装 Tailscale 客户端' -and $swMissingTs.ElapsedMilliseconds -lt 250) "Missing tailscale.exe returns fast with exact ErrorReason (Elapsed=$($swMissingTs.ElapsedMilliseconds)ms)"

        # 2. Fake-IP 198.18.* collision when BackendState != Running
        $fakeTsStoppedCmd = Join-Path $SuiteRoot 'fake-ts-stopped.cmd'
        [IO.File]::WriteAllText($fakeTsStoppedCmd, "@echo off`r`nif `"%1`"==`"status`" (`r`n  echo {`"BackendState`":`"NoState`"}`r`n  exit /b 0`r`n)`r`nif `"%1`"==`"debug`" (`r`n  echo {`"LoggedOut`":true}`r`n  exit /b 0`r`n)`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
        Set-TailscaleTestOverrides -ControlPlaneIpsOverride @('198.18.0.88')
        $rtTsFakeIp = Start-PublicTunnelItem -Context $poolCtx -TunnelId $tsId -TailscalePath $fakeTsStoppedCmd
        Assert ((-not $rtTsFakeIp.Running) -and $rtTsFakeIp.ErrorReason -eq 'Tailscale 被本机代理虚拟网卡 (Fake-IP) 拦截，请将 +.tailscale.com 与 +.ts.net 加入代理 Fake-IP 绕过列表') 'Tailscale Fake-IP 198.18.* collision detected and reported accurately'

        # 3. LoggedOut = true when DNS is normal
        Set-TailscaleTestOverrides -ControlPlaneIpsOverride @('52.10.20.30')
        $rtTsLoggedOut = Start-PublicTunnelItem -Context $poolCtx -TunnelId $tsId -TailscalePath $fakeTsStoppedCmd
        Assert ((-not $rtTsLoggedOut.Running) -and $rtTsLoggedOut.ErrorReason -eq '本机 Tailscale 尚未登录，请在右下角托盘打开 Tailscale 登录') 'Tailscale LoggedOut state detected via debug prefs'

        # 4. Funnel permission off (funnel --bg returns non-zero)
        $fakeTsNoFunnelCmd = Join-Path $SuiteRoot 'fake-ts-nofunnel.cmd'
        [IO.File]::WriteAllText($fakeTsNoFunnelCmd, "@echo off`r`nif `"%1`"==`"status`" (`r`n  echo {`"BackendState`":`"Running`",`"Self`":{`"DNSName`":`"my-laptop.tail12345.ts.net.`"}}`r`n  exit /b 0`r`n)`r`nif `"%1`"==`"funnel`" exit /b 1`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
        $rtTsNoFunnel = Start-PublicTunnelItem -Context $poolCtx -TunnelId $tsId -TailscalePath $fakeTsNoFunnelCmd
        Assert ((-not $rtTsNoFunnel.Running) -and $rtTsNoFunnel.ErrorReason -eq 'Tailscale 尚未开启公网 Funnel 权限，请在 Tailscale 网页后台 DNS 页面开启 HTTPS 与 Funnel') 'Tailscale Funnel non-zero exit reports exact permission guidance'

        # 5. External URL mode offline vs online
        $rtExtOff = Start-PublicTunnelItem -Context $poolCtx -TunnelId $extId
        Assert ((-not $rtExtOff.Running) -and $rtExtOff.Mode -eq 'external_url' -and $rtExtOff.ModeLabel -eq '外部公网隧道' -and $rtExtOff.ErrorReason -eq '该公网网址当前无法连通本机工作台，请确认外部隧道工具已开启并指向 127.0.0.1:8766') 'External URL offline reports exact guidance'
        Set-PublicMcpEdgeProbeOverride { return [pscustomobject]@{ Reachable = $true; Phase = 'Online'; PublicRttMs = 38; IngressIp = '104.21.8.8' } }
        $rtExtOn = Start-PublicTunnelItem -Context $poolCtx -TunnelId $extId
        Assert ($rtExtOn.Running -and $rtExtOn.EffectiveUrl -eq 'https://frp.custom-gateway.example.com/mcp' -and $rtExtOn.Status -eq '运行中' -and $rtExtOn.HealthPhase -eq 'Online' -and $rtExtOn.PublicRttMs -eq 38 -and $rtExtOn.ErrorReason -eq '') 'External URL online transitions to Running=true, Online'
    } finally {
        Set-TailscaleTestOverrides -ClientPathOverride $null -ControlPlaneIpsOverride $null
        Set-PublicMcpEdgeProbeOverride $null
        Stop-AllPublicTunnelItems -Context $poolCtx
    }
}

Assert ((Get-WebRoomUrl -Record ([pscustomobject]@{provider='gemini'}) -Room 'abc123') -eq 'https://gemini.google.com/app/abc123') 'Gemini native room route'
Assert ((Get-WebRoomUrl -Record ([pscustomobject]@{provider='claude'}) -Room 'aaa-bbb') -eq 'https://claude.ai/chat/aaa-bbb') 'Claude room route'
Assert ((Get-WebRoomUrl -Record ([pscustomobject]@{provider='claude'})) -eq 'https://claude.ai/new') 'Claude new conversation route'

if ($ModelCatalogOnly) {
    $ctx = New-ConnectionContext -DataRoot (Join-Path $testRoot 'catalog') -Isolated
    Set-TaskComposerConfig -Context $ctx -SessionKey 'switch_test' -Provider 'chatgpt' -ConvUuid 'old-room' -TabId 'old-tab' -ProjectPrefix 'https://chatgpt.com/g/old' | Out-Null
    $result = Set-TaskComposerConfig -Context $ctx -SessionKey 'switch_test' -Provider 'gemini' -TargetModel 'inherit'
    Assert ($result.binding.provider -eq 'gemini') 'offline provider selection persists'
    Assert (-not $result.binding.conv_uuid -and -not $result.binding.tab_id -and -not $result.binding.project_prefix) 'offline platform switch clears previous room tab and project'
    Write-Output "PASS model catalog: $script:passed"
    return
}

if ($PublicTunnelOnly) {
    $ctx = New-ConnectionContext -DataRoot (Join-Path $testRoot 'public') -Isolated
    Assert ((Resolve-CanonicalPlatform 'openai') -eq 'chatgpt' -and (Resolve-CanonicalPlatform 'OpenAI') -eq 'chatgpt' -and (Resolve-CanonicalPlatform 'ChatGPT') -eq 'chatgpt' -and (Resolve-CanonicalPlatform 'Gemini') -eq 'gemini' -and (Resolve-CanonicalPlatform 'Claude') -eq 'claude') 'Resolve-CanonicalPlatform normalizes openai/OpenAI/ChatGPT/Gemini/Claude to canonical lowercase identifiers'
    Assert ((Get-DefaultPlatformBaseUrl -Platform 'ChatGPT') -eq 'https://api.openai.com' -and (Get-DefaultPlatformBaseUrl -Platform 'openai') -eq 'https://api.openai.com') 'Get-DefaultPlatformBaseUrl maps ChatGPT and legacy openai to https://api.openai.com'
    $coldProfState = Get-ConnectionProfiles $ctx
    $primProf = $coldProfState.Profiles | Where-Object { $_.Id -eq 'prof_primary' } | Select-Object -First 1
    Assert ($coldProfState.EnabledPlatforms.Count -eq 1 -and $coldProfState.EnabledPlatforms[0] -eq 'chatgpt' -and $primProf.Platform -eq 'chatgpt' -and $primProf.KeyFile -eq 'openai-key-prof_primary.dpapi' -and $coldProfState.ActiveProfileByPlatform['chatgpt'] -eq 'prof_primary') 'Cold-start Get-ConnectionProfiles uses canonical chatgpt platform while preserving openai-key-prof_primary.dpapi filename contract'
    Assert-Throws { Add-CapsulePlatform $ctx 'deepseek' } 'deprecated platform rejected'
    Assert-Throws { Add-CapsulePlatform $ctx 'opencode' } 'opencode platform rejected'
    Assert-Throws { Save-ConnectionProfile -Context $ctx -ProfileId 'new' -Name 'Bad' -Platform 'deepseek' } 'Save-ConnectionProfile rejects unsupported platform deepseek'
    $state = Add-CapsulePlatform $ctx 'gemini'
    Assert (($state.Profiles | Where-Object Platform -eq 'gemini').Kind -eq 'public_tunnel') 'Gemini is a public tunnel'
    Assert ((ConvertTo-PublicMcpUrl 'https://example.com/') -eq 'https://example.com/mcp') 'fixed URL normalized'
    Assert-Throws { ConvertTo-PublicMcpUrl 'http://example.com' } 'HTTPS required'
    Assert (-not (Get-PublicMcpTunnelState $ctx).Running) 'cold start offline'
    $exe = Join-Path $testRoot 'fake-cloudflared.exe'
    $csSrc = 'using System; class FakeTunnel { static void Main(string[] args) { var i = Array.IndexOf(args, "--logfile"); if (i >= 0 && i + 1 < args.Length) { System.IO.File.AppendAllText(args[i+1], "https://fixture.trycloudflare.com\nRegistered tunnel connection"); } System.Threading.Thread.Sleep(60000); } }'
    $cscPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if ($PSVersionTable.PSEdition -eq 'Core' -and (Test-Path -LiteralPath $cscPath)) {
        $csFile = Join-Path $testRoot 'FakeTunnel.cs'
        [IO.File]::WriteAllText($csFile, $csSrc, [Text.Encoding]::UTF8)
        & $cscPath /nologo /target:exe /out:$exe $csFile | Out-Null
    } else {
        Add-Type -TypeDefinition $csSrc -OutputAssembly $exe -OutputType ConsoleApplication
    }
    try {
        $first = Start-PublicMcpTunnel -Context $ctx -ClientPath $exe
        $second = Start-PublicMcpTunnel -Context $ctx -ClientPath $exe
        Assert ($first.Running -and $first.Url -eq 'https://fixture.trycloudflare.com/mcp') 'quick tunnel yields MCP URL'
        Assert ($first.ProcessId -eq $second.ProcessId) 'second platform reuses same process'
        # Real cloudflared keeps the logfile open for writes while state is polled.
        $heldLog = [IO.File]::Open((Join-Path $ctx.DataRoot 'public-mcp-tunnel.log'), [IO.FileMode]::Open, [IO.FileAccess]::Write, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $whileWriting = Get-PublicMcpTunnelState $ctx
            Assert ($whileWriting.Running -and $whileWriting.Status -eq '在线' -and $whileWriting.Url -eq 'https://fixture.trycloudflare.com/mcp') 'registered tunnel stays online while client holds logfile open for writes'
            Clear-PublicMcpTunnelLogCache
            $tMiss1 = Get-PublicMcpTunnelState $ctx
            $tHit1 = Get-PublicMcpTunnelState $ctx
            $tHit2 = Get-PublicMcpTunnelState $ctx
            $tStats1 = Get-PublicMcpTunnelLogCacheStats
            Assert ($tMiss1.Running -and $tHit1.Running -and $tHit2.Running -and $tStats1.Misses -eq 1 -and $tStats1.Hits -ge 2) "Get-PublicMcpTunnelState caches unchanged logfile state without re-opening file (Misses=$($tStats1.Misses), Hits=$($tStats1.Hits))"
            $paddingBytes = [Text.Encoding]::UTF8.GetBytes(("`n2026-11-06T00:00:00Z INF ping " + ('x' * 90)) * 240 + "`nRegistered tunnel connection`n")
            $heldLog.Seek(0, [IO.SeekOrigin]::End) | Out-Null
            $heldLog.Write($paddingBytes, 0, $paddingBytes.Length)
            $heldLog.Flush()
            $tTail = Get-PublicMcpTunnelState $ctx
            $tStats2 = Get-PublicMcpTunnelLogCacheStats
            $tHitAfterTail = Get-PublicMcpTunnelState $ctx
            $tStats3 = Get-PublicMcpTunnelLogCacheStats
            Assert ($tTail.Running -and $tTail.Url -eq 'https://fixture.trycloudflare.com/mcp' -and $tStats2.Misses -eq 2 -and $tStats2.LastBytesRead -le 8192 -and $tHitAfterTail.Running -and $tStats3.Hits -gt $tStats2.Hits) "Get-PublicMcpTunnelState tail-reads <=8KB on >24KB logfile and caches subsequent unchanged polls (LastBytesRead=$($tStats2.LastBytesRead))"
        } finally { $heldLog.Dispose() }
    } finally { Stop-PublicMcpTunnel $ctx }
    Assert (-not (Get-PublicMcpTunnelState $ctx).Running) 'stop clears shared tunnel'
    try {
        $fixed = Start-PublicMcpTunnel -Context $ctx -ClientPath $exe -FixedDomain 'https://fixed.example/' -Token 'fixture-token'
        Assert ($fixed.Running -and $fixed.Url -eq 'https://fixed.example/mcp') 'fixed domain is used instead of temporary URL'
    } finally { Stop-PublicMcpTunnel $ctx }
    $fakeTsCmd = Join-Path $testRoot 'fake-tailscale.cmd'
    $fakeTsLog = Join-Path $testRoot 'fake-tailscale-args.log'
    [IO.File]::WriteAllText($fakeTsCmd, "@echo off`r`necho %*>> `"$fakeTsLog`"`r`nif `"%1`"==`"status`" (`r`n  echo {`"BackendState`":`"Running`",`"Self`":{`"DNSName`":`"auto-box.tail9999.ts.net.`"}}`r`n  exit /b 0`r`n)`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
    try {
        $tsAuto = Start-PublicMcpTunnel -Context $ctx -TailscalePath $fakeTsCmd
        $tsAutoHit = Get-PublicMcpTunnelState $ctx
        $tsStats = Get-PublicMcpTunnelLogCacheStats
        Assert ($tsAuto.Running -and $tsAuto.Url -eq 'https://auto-box.tail9999.ts.net/mcp' -and $tsAutoHit.Running -and $tsStats.Hits -ge 1) 'Tailscale Funnel auto-discovers permanent *.ts.net/mcp URL and caches online state'
    } finally { Stop-PublicMcpTunnel $ctx }
    Assert (-not (Get-PublicMcpTunnelState $ctx).Running -and ([IO.File]::ReadAllText($fakeTsLog) -match 'funnel --https=443 off')) 'Stop-PublicMcpTunnel turns off Tailscale Funnel and clears state'
    try {
        $extFixed = Start-PublicMcpTunnel -Context $ctx -FixedDomain 'https://static-box.tail1234.ts.net' -TailscalePath $fakeTsCmd
        Assert ($extFixed.Running -and $extFixed.Url -eq 'https://static-box.tail1234.ts.net/mcp') 'Tokenless fixed HTTPS domain activates persistent tunnel without requiring Cloudflare token'
    } finally { Stop-PublicMcpTunnel $ctx }
    $before = Get-ConnectionProfiles $ctx
    $storePath = Join-Path $ctx.DataRoot 'credential-profiles.json'
    $store = [IO.File]::ReadAllText($storePath) | ConvertFrom-Json
    $store.enabled_platforms = @('openai', 'gemini', 'deepseek', 'opencode')
    foreach ($pItem in @($store.profiles)) {
        if ($pItem.id -eq 'prof_primary') { $pItem.platform = 'openai' }
    }
    $store.profiles += [pscustomobject]@{ id='obsolete'; platform='deepseek'; kind='apikey' }
    $store.profiles += [pscustomobject]@{ id='obsolete_oc'; platform='opencode'; kind='apikey' }
    [IO.File]::WriteAllText($storePath, ($store | ConvertTo-Json -Depth 8))
    $clean = Get-ConnectionProfiles $ctx
    Assert ($clean.EnabledPlatforms -contains 'chatgpt' -and $clean.EnabledPlatforms -notcontains 'openai' -and $clean.EnabledPlatforms -notcontains 'deepseek' -and $clean.EnabledPlatforms -notcontains 'opencode' -and @($clean.Profiles | Where-Object Platform -in @('deepseek','opencode')).Count -eq 0 -and ($clean.Profiles | Where-Object Id -eq 'prof_primary').Platform -eq 'chatgpt') 'legacy openai normalized to chatgpt and deepseek/opencode filtered'
    $persistedStore = [IO.File]::ReadAllText($storePath) | ConvertFrom-Json
    Assert ($persistedStore.enabled_platforms -contains 'chatgpt' -and $persistedStore.enabled_platforms -notcontains 'openai' -and $persistedStore.enabled_platforms -notcontains 'deepseek' -and $persistedStore.enabled_platforms -notcontains 'opencode') 'legacy cleanup and openai->chatgpt normalization persisted'
    $remChatGpt = Remove-CapsulePlatform -Context $ctx -Platform 'ChatGPT'
    $remOpenAI = Remove-CapsulePlatform -Context $ctx -Platform 'OpenAI'
    Assert ($remChatGpt.EnabledPlatforms -contains 'chatgpt' -and $remOpenAI.EnabledPlatforms -contains 'chatgpt') 'Remove-CapsulePlatform normalizes ChatGPT/OpenAI and never removes primary chatgpt platform'
    $savedLegacyPlat = Save-ConnectionProfile -Context $ctx -ProfileId 'new' -Name 'LegacyOpenAI' -TunnelId 'tunnel_0123456789abcdef0123456789abcdef' -ApiKey 'sk-live1234567890' -Platform 'OpenAI' -SetActive:$false
    $legacyCreated = $savedLegacyPlat.Profiles | Where-Object { $_.Id -eq $savedLegacyPlat.LastSavedProfileId } | Select-Object -First 1
    Assert ($null -ne $legacyCreated -and $legacyCreated.Platform -eq 'chatgpt' -and $legacyCreated.KeyFile -eq "openai-key-$($legacyCreated.Id).dpapi") 'Save-ConnectionProfile normalizes OpenAI input to chatgpt while keeping openai-key-<id>.dpapi filename'
    $store = [IO.File]::ReadAllText($storePath) | ConvertFrom-Json
    $old = $store.profiles | Where-Object platform -eq 'gemini'
    $old.kind = 'apikey'; $old.base_url = 'https://generativelanguage.googleapis.com'
    [IO.File]::WriteAllText($storePath, ($store | ConvertTo-Json -Depth 8))
    $migrated = (Get-ConnectionProfiles $ctx).Profiles | Where-Object Platform -eq 'gemini'
    Assert ($migrated.Kind -eq 'public_tunnel' -and $migrated.BaseUrl -eq '' -and -not $migrated.HasKey) 'old API profile migrates to quick mode without API credential reuse'
    $again = (Get-ConnectionProfiles $ctx).Profiles | Where-Object Platform -eq 'gemini'
    Assert ($again.BaseUrl -eq '' -and -not $again.HasKey) 'quick-mode migration survives reload'

    # Slice 2: Get-ConnectionProfiles Cold Slate Cache (0 disk/DPAPI reads on 2s polls, cloned isolation, immediate write invalidation)
    Clear-ConnectionProfilesCache
    $cpMiss = Get-ConnectionProfiles $ctx
    $cpHit1 = Get-ConnectionProfiles $ctx
    $cpHit2 = Get-ConnectionProfiles $ctx
    $cpStats1 = Get-ConnectionProfilesCacheStats
    Assert ($cpStats1.Misses -eq 1 -and $cpStats1.Hits -eq 2) "Get-ConnectionProfiles hits Cold Slate Cache on repeated 2s polls (Misses=$($cpStats1.Misses), Hits=$($cpStats1.Hits))"
    $origFirstName = $cpHit1.Profiles[0].Name
    $cpHit1.Profiles[0].Name = 'MUTATED_IN_CALLER'
    $cpHit3 = Get-ConnectionProfiles $ctx
    Assert ($cpHit3.Profiles[0].Name -eq $origFirstName) 'Get-ConnectionProfiles returns cloned PSObjects so caller mutation never corrupts cached slate'
    [void](Add-CapsulePlatform -Context $ctx -Platform 'claude')
    $cpStatsAfterWrite = Get-ConnectionProfilesCacheStats
    Assert ($cpStatsAfterWrite.Misses -ge 2) 'Write operations immediately invalidate Get-ConnectionProfiles Cold Slate Cache'

    # Slice 3: Get-AvailableBrowserProfiles Cold Slate Cache (0 settings.json reads on 2s polls, file-stat invalidation)
    Clear-BrowserProfilesCache
    $bpMiss = @(Get-AvailableBrowserProfiles -Context $ctx)
    $swBp = [Diagnostics.Stopwatch]::StartNew()
    $bpHit1 = @(Get-AvailableBrowserProfiles -Context $ctx)
    $bpHit2 = @(Get-AvailableBrowserProfiles -Context $ctx)
    $swBp.Stop()
    $bpStats1 = Get-BrowserProfilesCacheStats
    Assert ($bpStats1.Misses -eq 1 -and $bpStats1.Hits -eq 2 -and $swBp.ElapsedMilliseconds -lt 25) "Get-AvailableBrowserProfiles hits Cold Slate Cache in O(1) memory without reading settings.json (Misses=$($bpStats1.Misses), Hits=$($bpStats1.Hits), Elapsed=$($swBp.ElapsedMilliseconds)ms)"
    [IO.File]::WriteAllText($ctx.SettingsPath, (@{ schema_version = 1; default_browser_profile = 'Edge:Default' } | ConvertTo-Json), [Text.Encoding]::UTF8)
    $bpAfterSettingsEdit = @(Get-AvailableBrowserProfiles -Context $ctx)
    $bpStats2 = Get-BrowserProfilesCacheStats
    Assert ($bpStats2.Misses -eq 2 -and $bpAfterSettingsEdit[0].Id -eq 'Edge:Default') 'Get-AvailableBrowserProfiles detects settings.json mtime/size change and refreshes default carrier order without -ForceRefresh'

    # Seam 1 (Resolve-EffectiveOutboundProxyEnv), Seam 2 (Get-StudioHubBaseUrl), and Option B Auto-Fallback (Tailscale -> Cloudflare HTTP/2)
    $deadProxyEnv = @{ HTTPS_PROXY = 'http://127.0.0.1:59997'; HTTP_PROXY = 'http://127.0.0.1:59997' }
    $resolvedDead = Resolve-EffectiveOutboundProxyEnv -Context $ctx -BaseEnv $deadProxyEnv -SystemProxyOverride ''
    Assert ($resolvedDead.Mode -eq 'direct_fallback' -and $resolvedDead.ProxyUrl -eq '' -and $resolvedDead.Env['HTTPS_PROXY'] -eq '' -and $resolvedDead.NoProxy -match '\*\.ts\.net' -and $resolvedDead.NoProxy -match '100\.64\.0\.0/10') 'Resolve-EffectiveOutboundProxyEnv strips dead local proxy port and falls back to direct/TUN mode with *.ts.net and 100.64.0.0/10 in NO_PROXY'
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $liveProxyPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    try {
        $resolvedLive = Resolve-EffectiveOutboundProxyEnv -Context $ctx -BaseEnv $deadProxyEnv -SystemProxyOverride "127.0.0.1:$liveProxyPort"
        Assert ($resolvedLive.Mode -eq 'proxy' -and $resolvedLive.ProxyUrl -eq "http://127.0.0.1:$liveProxyPort" -and $resolvedLive.Env['HTTPS_PROXY'] -eq "http://127.0.0.1:$liveProxyPort") "Resolve-EffectiveOutboundProxyEnv dynamically adopts live SystemProxyOverride port ($liveProxyPort)"
    } finally { $listener.Stop() }
    $directSettings = [pscustomobject]@{ outbound_proxy = 'direct'; shield_port = 18766 }
    $resolvedDirect = Resolve-EffectiveOutboundProxyEnv -Context $ctx -Settings $directSettings -BaseEnv $deadProxyEnv -SystemProxyOverride "127.0.0.1:$liveProxyPort"
    Assert ($resolvedDirect.Mode -eq 'direct' -and $resolvedDirect.ProxyUrl -eq '') 'Resolve-EffectiveOutboundProxyEnv honors explicit outbound_proxy=direct setting'
    Assert ((Get-StudioHubBaseUrl -Context $ctx -Settings $directSettings) -eq 'http://127.0.0.1:18766') 'Get-StudioHubBaseUrl resolves custom shield_port seam instead of hardcoded 8766'

    $fakeFailTsCmd = Join-Path $testRoot 'fake-tailscale-fail.cmd'
    [IO.File]::WriteAllText($fakeFailTsCmd, "@echo off`r`nexit /b 1`r`n", [Text.Encoding]::ASCII)
    try {
        $fbTunnel = Start-PublicMcpTunnel -Context $ctx -FixedDomain 'https://dead-funnel.tail9999.ts.net' -TailscalePath $fakeFailTsCmd -ClientPath $exe
        Assert ((-not $fbTunnel.Running) -and $fbTunnel.Mode -eq 'tailscale' -and $fbTunnel.Url -eq 'https://dead-funnel.tail9999.ts.net/mcp' -and $fbTunnel.HealthPhase -eq 'Offline' -and $fbTunnel.Status -eq '离线' -and $fbTunnel.FallbackFrom -eq '') "URL Stability Invariant: Start-PublicMcpTunnel preserves fixed *.ts.net URL in Offline state and NEVER downgrades to cloudflared_quick (Mode=$($fbTunnel.Mode), Url=$($fbTunnel.Url), Phase=$($fbTunnel.HealthPhase))"
    } finally { Stop-PublicMcpTunnel $ctx }

    # Edge Health Seam (8000ms default timeout, Degraded 3.6s-5.6s cellular RTT, zero-network Get-PublicMcpTunnelState cache, IPv4 filter, and lock retry)
    $modRef = Get-Module ConnectionManager
    $ipFilterOk = & $modRef {
        (-not (Test-IsPublicRoutableIpv4 '127.0.0.1')) -and
        (-not (Test-IsPublicRoutableIpv4 '10.1.2.3')) -and
        (-not (Test-IsPublicRoutableIpv4 '192.168.1.5')) -and
        (-not (Test-IsPublicRoutableIpv4 '172.16.0.1')) -and
        (-not (Test-IsPublicRoutableIpv4 '172.31.255.254')) -and
        (-not (Test-IsPublicRoutableIpv4 '100.64.0.1')) -and
        (-not (Test-IsPublicRoutableIpv4 '100.100.100.100')) -and
        (-not (Test-IsPublicRoutableIpv4 '100.127.255.254')) -and
        (-not (Test-IsPublicRoutableIpv4 '198.18.0.2')) -and
        (-not (Test-IsPublicRoutableIpv4 '198.19.254.1')) -and
        (Test-IsPublicRoutableIpv4 '100.63.255.1') -and
        (Test-IsPublicRoutableIpv4 '100.128.0.1') -and
        (Test-IsPublicRoutableIpv4 '103.84.155.153') -and
        (Test-IsPublicRoutableIpv4 '8.8.8.8')
    }
    Assert $ipFilterOk 'Test-IsPublicRoutableIpv4 rejects loopback, RFC1918, Tailscale CGNAT (100.64/10), and Mihomo Fake-IP (198.18/15) while accepting public IPv4'

    $observedTimeoutMs = 0
    $observedSlowMs = 0
    try {
        Set-PublicMcpEdgeProbeOverride {
            param($Url, $ProbeCtx, $TimeoutMs, $SlowThresholdMs)
            return [pscustomobject]@{ Reachable = $false; Phase = 'Offline'; PublicRttMs = 0; IngressIp = '' }
        }
        $extOffline = Start-PublicMcpTunnel -Context $ctx -FixedDomain 'https://mcp.custom-fixed.example' -ClientPath $exe
        Assert ((-not $extOffline.Running) -and $extOffline.Mode -eq 'external_fixed' -and $extOffline.Url -eq 'https://mcp.custom-fixed.example/mcp' -and $extOffline.HealthPhase -eq 'Offline' -and $extOffline.Status -eq '离线') 'Start-PublicMcpTunnel never downgrades custom FixedDomain to cloudflared_quick when edge health probe reports Offline'
        Stop-PublicMcpTunnel $ctx

        $probeRecordFile = Join-Path $testRoot 'edge-probe-args.txt'
        Set-PublicMcpEdgeProbeOverride ([scriptblock]::Create(@"
            param(`$Url, `$ProbeCtx, `$TimeoutMs, `$SlowThresholdMs)
            [IO.File]::WriteAllText('$($probeRecordFile.Replace("'", "''"))', "`$TimeoutMs|`$SlowThresholdMs")
            return [pscustomobject]@{ Reachable = `$true; Phase = 'Degraded'; PublicRttMs = 4200; IngressIp = '103.84.155.153' }
"@))
        $degState = Start-PublicMcpTunnel -Context $ctx -FixedDomain 'https://cell-box.tail9999.ts.net' -TailscalePath $fakeTsCmd -ClientPath $exe
        $recordedArgs = ([IO.File]::ReadAllText($probeRecordFile) -split '\|')
        $observedTimeoutMs = [int]$recordedArgs[0]
        $observedSlowMs = [int]$recordedArgs[1]
        Assert ($observedTimeoutMs -eq 8000 -and $observedSlowMs -eq 2500) "Start-PublicMcpTunnel invokes Test-PublicMcpEdgeHealth with calibrated 8000ms timeout and 2500ms slow threshold (actual=$observedTimeoutMs/$observedSlowMs)"
        Assert ($degState.Running -and $degState.Mode -eq 'tailscale' -and $degState.Url -eq 'https://cell-box.tail9999.ts.net/mcp' -and $degState.HealthPhase -eq 'Degraded' -and $degState.Status -eq '偏慢' -and $degState.PublicRttMs -eq 4200 -and $degState.VerifiedIngressIp -eq '103.84.155.153') 'Cellular 4200ms Tailscale Funnel RTT is recorded as Running=true, HealthPhase=Degraded, Status=偏慢, PublicRttMs=4200'

        # Verify Get-PublicMcpTunnelState performs ZERO network calls (<10ms) and preserves HealthPhase + PublicRttMs across cache misses and hits
        Set-PublicMcpEdgeProbeOverride { throw 'Get-PublicMcpTunnelState MUST NOT invoke network edge probe!' }
        Clear-PublicMcpTunnelLogCache
        $swState = [Diagnostics.Stopwatch]::StartNew()
        $sMiss = Get-PublicMcpTunnelState $ctx
        $sHit1 = Get-PublicMcpTunnelState $ctx
        $sHit2 = Get-PublicMcpTunnelState $ctx
        $swState.Stop()
        $sCacheStats = Get-PublicMcpTunnelLogCacheStats
        Assert ($sMiss.HealthPhase -eq 'Degraded' -and $sMiss.PublicRttMs -eq 4200 -and $sHit1.HealthPhase -eq 'Degraded' -and $sHit1.PublicRttMs -eq 4200 -and $sHit2.Status -eq '偏慢' -and $sCacheStats.Misses -eq 1 -and $sCacheStats.Hits -ge 2 -and $swState.ElapsedMilliseconds -lt 50) "Get-PublicMcpTunnelState reads local state with zero network I/O and preserves HealthPhase=Degraded & PublicRttMs=4200 across cache hits (Elapsed=$($swState.ElapsedMilliseconds)ms)"

        # Verify Stop-PublicMcpTunnel waits cleanly on a briefly-held public-mcp-tunnel.lock instead of failing with IOException
        $lockFile = Join-Path $ctx.DataRoot 'public-mcp-tunnel.lock'
        $readyFlag = Join-Path $testRoot 'lock-held.flag'
        if (Test-Path -LiteralPath $readyFlag) { Remove-Item -LiteralPath $readyFlag -Force }
        $holderPs = [powershell]::Create()
        try {
            [void]$holderPs.AddScript({
                param($LockPath, $FlagPath)
                $fs = [IO.File]::Open($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                try {
                    [IO.File]::WriteAllText($FlagPath, 'held')
                    Start-Sleep -Milliseconds 320
                } finally {
                    $fs.Dispose()
                }
            }).AddArgument($lockFile).AddArgument($readyFlag)
            $holderHandle = $holderPs.BeginInvoke()
            $waitDeadline = [DateTime]::UtcNow.AddSeconds(3)
            while (-not (Test-Path -LiteralPath $readyFlag) -and [DateTime]::UtcNow -lt $waitDeadline) {
                Start-Sleep -Milliseconds 15
            }
            Assert (Test-Path -LiteralPath $readyFlag) 'Background test holder acquired public-mcp-tunnel.lock'
            Stop-PublicMcpTunnel $ctx
            [void]$holderPs.EndInvoke($holderHandle)
            Assert (-not (Get-PublicMcpTunnelState $ctx).Running -and -not (Test-Path -LiteralPath (Join-Path $ctx.DataRoot 'public-mcp-tunnel.json'))) 'Stop-PublicMcpTunnel waits cleanly for briefly-held public-mcp-tunnel.lock and removes state without IOException'
        } finally {
            $holderPs.Dispose()
        }
    } finally {
        Set-PublicMcpEdgeProbeOverride $null
        Stop-PublicMcpTunnel $ctx
    }

    Invoke-UnifiedPublicTunnelPoolAndEnvTests -SuiteRoot (Join-Path $testRoot 'unified-pub') -RepoRoot $managerRoot

    # Verify UTF-8 BOM preservation and PowerShell AST clean parse on all 3 PowerShell files
    foreach ($psFile in @(
        (Join-Path $managerRoot 'ConnectionManager.psm1'),
        (Join-Path $managerRoot '连接管理.ps1'),
        (Join-Path $managerRoot 'tests\Test-ConnectionManager.ps1')
    )) {
        $rawBytes = [IO.File]::ReadAllBytes($psFile)
        $hasUtf8Bom = ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF)
        $astTokens = $null
        $astErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($psFile, [ref]$astTokens, [ref]$astErrors)
        $leafName = Split-Path $psFile -Leaf
        Assert ($hasUtf8Bom -and @($astErrors).Count -eq 0) "File $leafName preserves UTF-8 BOM ($hasUtf8Bom) and parses with 0 PowerShell AST errors (errors=$(@($astErrors).Count))"
    }

    Write-Output "PASS public tunnel: $script:passed"
    return
}

try {

    $id='tunnel_0123456789abcdef0123456789abcdef'

    Assert ((ConvertTo-TunnelId $id) -eq $id) 'raw tunnel ID'

    Assert ((ConvertTo-TunnelId ('https://platform.openai.com/settings/organization/tunnels/' + $id)) -eq $id) 'ID extracted from URL'

    Assert-Throws { ConvertTo-TunnelId 'https://platform.openai.com/settings/organization/tunnels' } 'list URL rejected'

    Assert-Throws { ConvertTo-TunnelId ($id + ' tunnel_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') } 'ambiguous IDs rejected'

    $context=New-ConnectionContext -DataRoot (Join-Path $testRoot 'data') -Isolated

    $settings=Get-DefaultConnectionSettings $context

    $settings.tunnel_id=$id

    $fixture=Join-Path $testRoot 'official'

    [IO.Directory]::CreateDirectory($fixture) | Out-Null

    [IO.File]::WriteAllText((Join-Path $fixture 'runtime.json'),' {"port":8765} ')

    [IO.File]::WriteAllText((Join-Path $fixture 'control-panel-settings.json'),' {"port":9123} ')

    $settings.runtime_root=$fixture

    Assert ((Get-OfficialCoreEndpoint $settings) -eq 'http://127.0.0.1:9123/mcp') 'effective official port follows settings'

    $fakeKey='sk-offline-test-not-a-real-api-key'

    $fakeToken='offline-test-not-a-real-relay-token'

    Save-ConnectionSettings $context $settings $fakeKey $fakeToken

    $reloaded=Read-ConnectionSettings $context

    Assert ($reloaded.tunnel_id -eq $id) 'saved settings reload'

    Assert ((Read-ConnectionSecret $context.KeyPath) -eq $fakeKey) 'Windows encrypted key round-trip'

    Assert ((Read-ConnectionSecret $context.TokenPath) -eq $fakeToken) 'separate encrypted RelayStudio token round-trip'

    foreach($path in @($context.KeyPath,$context.TokenPath,$context.SettingsPath)) {

        $text=[IO.File]::ReadAllText($path)

        Assert (-not $text.Contains($fakeKey) -and -not $text.Contains($fakeToken)) 'no plaintext secrets on disk'

    }

    $keyBefore=[IO.File]::ReadAllText($context.KeyPath)

    Save-ConnectionSettings $context $reloaded '' ''

    Assert ([IO.File]::ReadAllText($context.KeyPath) -eq $keyBefore) 'blank key preserves existing secret'

    $before=[IO.File]::ReadAllText($context.SettingsPath)

    Assert-Throws { Save-ConnectionSettings $context $reloaded 'https://platform.openai.com/key' } 'URL rejected as API key'

    Assert ([IO.File]::ReadAllText($context.SettingsPath) -eq $before) 'failed validation preserves saved settings'

    Assert-Throws { Save-ConnectionSettings $context $reloaded 'sk-another-offline-test-key' '' { throw 'simulated save failure' } } 'save failure reported'

    Assert ([IO.File]::ReadAllText($context.SettingsPath) -eq $before -and [IO.File]::ReadAllText($context.KeyPath) -eq $keyBefore) 'save failure preserves config and credential'

    Assert (@(Get-ChildItem -LiteralPath $context.DataRoot -Filter '*.tmp' -Recurse).Count -eq 0) 'no temporary writes left behind'

    $profile=New-TunnelProfileText $reloaded 'http://127.0.0.1:9123/mcp'

    Assert ($profile.Contains('http://127.0.0.1:9123/mcp') -and $profile.Contains('env:CONTROL_PLANE_API_KEY') -and -not $profile.Contains($fakeKey)) 'profile uses secret reference and actual endpoint'

    Assert ($reloaded.readonly_shield -eq $true -and $reloaded.shield_port -eq 8766) 'readonly shield enabled by default'

    Assert ((Get-EffectiveTunnelEndpoint $reloaded 'http://127.0.0.1:9123/mcp') -eq 'http://127.0.0.1:8766/mcp') 'effective endpoint routes through shield when enabled'

    $reloaded.readonly_shield = $false

    Assert ((Get-EffectiveTunnelEndpoint $reloaded 'http://127.0.0.1:9123/mcp') -eq 'http://127.0.0.1:9123/mcp') 'effective endpoint routes direct when shield disabled'

    Assert-Throws { Start-ConnectionTunnel $context $reloaded } 'isolated test cannot start a real tunnel'

    Assert-Throws { Start-ReadOnlyShield $context $reloaded 'http://127.0.0.1:9123/mcp' } 'isolated test cannot start a real shield'

    Assert (@(Get-RelatedTunnelProcesses $context $reloaded).Count -eq 0) 'isolated test cannot target live processes'

    Assert (@(Get-RelatedShieldProcesses $context).Count -eq 0) 'isolated test cannot target live shield processes'

    $pulseContext = [pscustomobject]@{

        Isolated = $false

        DataRoot = (Join-Path $testRoot 'pulse-data')

        SessionAliasesPath = (Join-Path (Join-Path $testRoot 'pulse-data') 'session-aliases.json')

        TasksRoot = (Join-Path $testRoot 'pulse-tasks')

    }

    [IO.Directory]::CreateDirectory((Join-Path $pulseContext.DataRoot 'logs')) | Out-Null

    [IO.Directory]::CreateDirectory($pulseContext.TasksRoot) | Out-Null

    $nowIso = [DateTimeOffset]::Now.AddSeconds(-8).ToString('o')

    [IO.File]::WriteAllText((Join-Path (Join-Path $pulseContext.DataRoot 'logs') 'tunnel.out.log'), ('{"time":"' + $nowIso + '","level":"INFO","msg":"dispatcher forwarded command to MCP server","cmd_request_id":"wfr_01a1735d3994733c87ad836e7898a160"}' + "`r`n"))

    $activePulse = Get-TunnelActivityPulse $pulseContext $true

    Assert ($activePulse.Session -match '已累计转发 1 次工具调用' -and $activePulse.CommandCount -eq 1) 'pulse respects Task-Only Contract (0 tasks -> 0 cards) while tracking tunnel command count'

    Assert ($activePulse.IsFault -eq $false -and $activePulse.RecentMinuteCount -eq 1) 'normal pulse has IsFault=false and tracks RecentMinuteCount'

    Assert ($activePulse.Sessions.Count -eq 0) 'Task-Only Contract: un-tasked wfr_id does not spawn a standalone card'



    $utcDt = [DateTime]::SpecifyKind([DateTime]::UtcNow, [DateTimeKind]::Utc)

    $localDto = ConvertTo-LocalDateTimeOffset $utcDt $null

    Assert ($null -ne $localDto -and [Math]::Abs(($localDto - [DateTimeOffset]::Now).TotalSeconds) -lt 5) 'ConvertTo-LocalDateTimeOffset preserves UTC offset when PowerShell 7 ConvertFrom-Json returns DateTime'

    $oldIso = [DateTimeOffset]::Now.AddMinutes(-25).ToString('o')

    $taskStartIso = [DateTimeOffset]::Now.AddMinutes(-10).ToString('o')

    $subIso = [DateTimeOffset]::Now.AddSeconds(-4).ToString('o')

    $taskJson = @{

        schema_version = 1

        id = 'tsk_19283093310b828b'

        title = 'ProjectAlpha C4 三层重构：工单 06–21'

        status = 'active'

        created_at = $taskStartIso

        updated_at = $nowIso

        steps = @(

            @{ id = '20'; title = '拆旧清理'; status = 'in_progress'; updated_at = $nowIso }

        )

        summary = '正在执行拆旧清理'

    } | ConvertTo-Json -Depth 5

    [IO.File]::WriteAllText((Join-Path $pulseContext.TasksRoot 'tsk_19283093310b828b.json'), $taskJson, (New-Object Text.UTF8Encoding($false)))



    $multiLog = @(

        ('{"time":"' + $oldIso + '","level":"INFO","msg":"dispatcher forwarded command to MCP server","cmd_request_id":"wfr_01a17000000000000000000000old111","rpc_request_id":"aaaaaaaa-1111-4111-8111-111111111111"}'),

        ('{"time":"' + $nowIso + '","level":"INFO","msg":"dispatcher forwarded command to MCP server","cmd_request_id":"wfr_01a1735d3994733c87ad836e7898a160","rpc_request_id":"bbbbbbbb-2222-4222-8222-222222222222"}'),

        ('{"time":"' + $subIso + '","level":"INFO","msg":"dispatcher forwarded command to MCP server","cmd_request_id":"e9eae4ce-4aaa-45a4-aa9d-587970c158fc","rpc_request_id":"cccccccc-3333-4333-8333-333333333333"}'),

        ('{"time":"' + $subIso + '","level":"INFO","msg":"dispatcher forwarded command to MCP server","cmd_request_id":"b2814367-818e-4036-ade5-60407da247f7/ltuz","rpc_request_id":0}')

    ) -join "`r`n"

    [IO.File]::WriteAllText((Join-Path (Join-Path $pulseContext.DataRoot 'logs') 'tunnel.out.log'), ($multiLog + "`r`n"), (New-Object Text.UTF8Encoding($false)))

    $multiPulse = Get-TunnelActivityPulse $pulseContext $true

    Assert ($multiPulse.Sessions.Count -eq 1) 'subagent and >15m old session do not clutter active main session list'

    Assert ($multiPulse.HiddenIdleCount -eq 1) 'session idle >15m is auto-hidden'

    Assert ($multiPulse.SubagentCallCount -eq 1) 'subagent call count is tracked and rolled up'

    Assert ($multiPulse.Sessions[0].Title -eq 'ProjectAlpha C4 三层重构：工单 06–21') 'main session automatically matches RelayStudio Chinese task title'

    Assert ($multiPulse.Sessions[0].ActionText -match '步骤 20：拆旧清理' -and $multiPulse.Sessions[0].CommandCount -eq 2) 'main session rolls up subagent tool count and shows active step'

    Assert ($multiPulse.Sessions[0].MetaText -eq '会话尾号 wfr_…98a160 · 已自动合并 1 次子代理调用' -and $multiPulse.Sessions[0].MetaText -notmatch 'tsk_') 'card MetaText keeps short session tail and subagent count while dropping internal tsk_ ID'



    Set-SessionAlias -Context $pulseContext -SessionKey $multiPulse.Sessions[0].SessionKey -Title '网页左栏自定义对话名'

    $renamedPulse = Get-TunnelActivityPulse $pulseContext $true

    Assert ($renamedPulse.Sessions[0].Title -eq '网页左栏自定义对话名' -and $renamedPulse.Sessions[0].IsCustomTitle -eq $true) 'user custom rename overrides conversation title'

    Set-SessionAlias -Context $pulseContext -SessionKey $multiPulse.Sessions[0].SessionKey -Title ''

    $resetPulse = Get-TunnelActivityPulse $pulseContext $true

    Assert ($resetPulse.Sessions[0].Title -eq 'ProjectAlpha C4 三层重构：工单 06–21' -and $resetPulse.Sessions[0].IsCustomTitle -eq $false) 'blank rename restores auto-detected title'



    [IO.File]::AppendAllText((Join-Path (Join-Path $pulseContext.DataRoot 'logs') 'tunnel.out.log'), ('{"time":"' + $nowIso + '","level":"WARN","msg":"poll failed; backing off","error":"proxyconnect tcp: dial tcp 127.0.0.1:7897: connectex: No connection could be made because the target machine actively refused it."}' + "`r`n"))

    $errPulse = Get-TunnelActivityPulse $pulseContext $true

    Assert ($errPulse.Session -match '网络代理中断' -and $errPulse.Session -match '7897' -and $errPulse.IsFault -eq $true) 'pulse detects local proxy refusal and sets IsFault=true'



    # Verify <uuid>/<4char> cloud fresh subagents roll up into C4 card by default, and only become a 2nd card when shield-activity.json confirms a non-C4 workspace

    $twoConvLog = @(

        ('{"time":"' + $nowIso + '","level":"INFO","msg":"dispatcher forwarded command to MCP server","cmd_request_id":"wfr_01a1735d3994733c87ad836e7898a160","rpc_request_id":"bbbbbbbb-2222-4222-8222-222222222222"}'),

        ('{"time":"' + $subIso + '","level":"INFO","msg":"dispatcher forwarded command to MCP server","cmd_request_id":"b5d0b5ea-bff5-484d-a17c-adc217006efa/ctvt","rpc_request_id":0}'),

        ('{"time":"' + $subIso + '","level":"INFO","msg":"dispatcher forwarded command to MCP server","cmd_request_id":"b5d0b5ea-bff5-484d-a17c-adc217006efa/1nal","rpc_request_id":0}'),

        ('{"time":"' + $subIso + '","level":"INFO","msg":"dispatcher forwarded command to MCP server","cmd_request_id":"b2814367-818e-4036-ade5-60407da247f7/ltuz","rpc_request_id":0}')

    ) -join "`r`n"

    [IO.File]::WriteAllText((Join-Path (Join-Path $pulseContext.DataRoot 'logs') 'tunnel.out.log'), ($twoConvLog + "`r`n"), (New-Object Text.UTF8Encoding($false)))

    $c4MergedPulse = Get-TunnelActivityPulse $pulseContext $true

    Assert ($c4MergedPulse.Sessions.Count -eq 1 -and $c4MergedPulse.Sessions[0].CommandCount -eq 3 -and $c4MergedPulse.Sessions[0].SubagentCount -eq 2) 'cloud fresh subagent (<uuid>/<4char>) rolls up into C4 card without splitting into a 2nd card'



    $shieldActivityJson = @{

        schema_version = 1

        calls = @{}

        zero_rpc_events = @(

            @{ rpc_id = '0'; tool = 'read_file'; action = '读取文件 (AGENTS.md)'; workspace_hint = 'Obsidian Vault'; time = $subIso }

        )

    } | ConvertTo-Json -Depth 5

    [IO.File]::WriteAllText((Join-Path (Join-Path $pulseContext.DataRoot 'logs') 'shield-activity.json'), $shieldActivityJson, (New-Object Text.UTF8Encoding($false)))

    $twoConvPulse = Get-TunnelActivityPulse $pulseContext $true

    Assert ($twoConvPulse.Sessions.Count -eq 1 -and $twoConvPulse.Sessions[0].SessionKey -eq 'tsk_19283093310b828b') 'Task-Only Contract: un-tasked <uuid>/<4char> in another workspace does not spawn a synthetic card without task_manage'

    Assert ($twoConvPulse.RecentMinuteCount -eq 3) 'top firepower gauge still tracks combined per-minute tool call rate'



    # Verify 3-minute stall alert text ("已停顿3分钟，请检查网页端") and >24h auto-archive + manual archive/restore

    $stallIso = [DateTimeOffset]::Now.AddMinutes(-4).ToString('o')

    $ancientIso = [DateTimeOffset]::Now.AddHours(-30).ToString('o')

    $ancientTaskJson = @{

        schema_version = 1

        id = 'tsk_ancient24h0001'

        title = '旧版日志清理与归档测试任务'

        status = 'active'

        created_at = $ancientIso

        updated_at = $ancientIso

        steps = @(

            @{ id = '1'; title = '检查旧日志'; status = 'completed'; updated_at = $ancientIso }

        )

        summary = '已完成旧日志检查'

    } | ConvertTo-Json -Depth 5

    [IO.File]::WriteAllText((Join-Path $pulseContext.TasksRoot 'tsk_ancient24h0001.json'), $ancientTaskJson, (New-Object Text.UTF8Encoding($false)))

    $stallLog = ('{"time":"' + $stallIso + '","level":"INFO","msg":"dispatcher forwarded command to MCP server","cmd_request_id":"wfr_01a1735d3994733c87ad836e7898a160","rpc_request_id":"bbbbbbbb-2222-4222-8222-222222222222"}' + "`r`n")

    [IO.File]::WriteAllText((Join-Path (Join-Path $pulseContext.DataRoot 'logs') 'tunnel.out.log'), $stallLog, (New-Object Text.UTF8Encoding($false)))

    $stallPulse = Get-TunnelActivityPulse $pulseContext $true

    $stalledMainSess = $stallPulse.Sessions | Where-Object { $_.SessionKey -ne 'tsk_ancient24h0001' } | Select-Object -First 1
    Assert ($stallPulse.Sessions.Count -eq 2 -and $null -ne $stalledMainSess -and $stalledMainSess.IsStalled -eq $true -and $stalledMainSess.StallAlertText -eq '已停顿3分钟，请检查网页端') '3-minute stall sets IsStalled=true and exact text 已停顿3分钟，请检查网页端'

    Assert ($stallPulse.ArchivedSessions.Count -eq 0 -and @($stallPulse.Sessions | Where-Object { $_.SessionKey -eq 'tsk_ancient24h0001' }).Count -eq 1) 'Unfinished task idle >24h is NEVER auto-archived and stays in active Sessions'



    # Verify manual archive and manual restore (plus Ledger 1 task-registry.json consistency)

    Set-TaskArchiveState -Context $pulseContext -TaskId 'tsk_ancient24h0001' -State 'archived'

    Set-TaskArchiveState -Context $pulseContext -TaskId $stalledMainSess.SessionKey -State 'archived'

    $manualArchPulse = Get-TunnelActivityPulse $pulseContext $true

    $regAfterArch = Get-Content -LiteralPath (Join-Path $pulseContext.DataRoot 'task-registry.json') -Raw -Encoding UTF8 | ConvertFrom-Json

    Assert ($manualArchPulse.Sessions.Count -eq 0 -and $manualArchPulse.ArchivedSessions.Count -eq 2 -and $regAfterArch.tasks.tsk_ancient24h0001.lifecycle -eq 'archived') 'manual archive moves active sessions to ArchivedSessions and syncs Ledger 1 (task-registry.json)'

    Set-TaskArchiveState -Context $pulseContext -TaskId 'tsk_ancient24h0001' -State 'active'

    Set-TaskArchiveState -Context $pulseContext -TaskId $stalledMainSess.SessionKey -State 'active'

    $restoredPulse = Get-TunnelActivityPulse $pulseContext $true

    $regAfterRestore = Get-Content -LiteralPath (Join-Path $pulseContext.DataRoot 'task-registry.json') -Raw -Encoding UTF8 | ConvertFrom-Json

    Assert ($restoredPulse.Sessions.Count -eq 2 -and $restoredPulse.ArchivedSessions.Count -eq 0 -and $regAfterRestore.tasks.tsk_ancient24h0001.lifecycle -eq 'active') 'manual restore moves archived task back to active Sessions and updates task-registry.json'

    Set-TaskArchiveState -Context $pulseContext -TaskId 'tsk_ancient24h0001' -State 'archived'
    $stallPulse = Get-TunnelActivityPulse $pulseContext $true



    # Verify Milestone Distillation & CleanGoal

    $distilledMs = ConvertTo-ReadableMilestone -RawSummary '切换到只读诊断与测试策略设计模式；已确认目标与红线，下一步派发只读诊断子代理复核 T21 测试耗时与根因。' -Timestamp '2026-04-20T03:00:21Z' -LatestAction '正在调用 Codex 子代理'

    Assert ($distilledMs.Title -eq '切换为只读诊断模式并重排验证计划' -and $distilledMs.Prose.Length -le 98 -and $distilledMs.TraceText -eq '') 'ConvertTo-ReadableMilestone distills raw checkpoint into concise Title, Prose, and empty TraceText'

    $cleanSub = ConvertTo-CleanGoalSubtitle -Goal '候选397ad4648ebad29be8c179f7736e2fd4eb26a734干净，按设计规范完成集成开发' -LatestSummary $distilledMs.RawText

    Assert ($cleanSub -eq '按设计规范完成集成开发') 'ConvertTo-CleanGoalSubtitle strips hex SHAs and returns calm 1-line goal'
    $c4Ms = ConvertTo-ReadableMilestone -RawSummary '21=in_progress: pass: 同一版本的完整后端验收已全部通过，现按顺序检查全部前端测试。 || SHA5e6e40b' -Timestamp '2026-10-28T19:21:13Z'
    Assert ($c4Ms.Title -notmatch '21=in_progress|pass:|\|\|' -and $c4Ms.Prose -notmatch '21=in_progress|pass:|\|\|' -and $c4Ms.Prose -match '同一版本的完整后端验收已全部通过' -and $c4Ms.RawText -eq 'SHA5e6e40b') 'ConvertTo-ReadableMilestone splits || first and strips 21=in_progress: and pass: prefixes'



    # Verify API key head/tail mask and window layout persistence

    $maskedKey = Format-MaskedApiKey 'sk-proj-4x9A1234567890abcdefG7QA'

    Assert ($maskedKey -eq 'sk-proj-4x9A••••••••••••••••••••••••••••••••G7QA') 'Format-MaskedApiKey masks middle and keeps head/tail'

    $layoutCtx = New-ConnectionContext -DataRoot (Join-Path $testRoot 'layout-data') -Isolated

    $customLayout = [pscustomobject]@{

        WinWidth = 1240

        WinHeight = 740

        RailWidth = 240

        RailCollapsed = $true

        ShowArchived = $true

        HiddenRightPane = [pscustomobject]@{ id = 104; session_key = 'tsk_19283093310b828b'; width_weight = 38; show_summary = $false }

        Panes = @(

            [pscustomobject]@{ id = 101; session_key = 'tsk_19283093310b828b'; width_weight = 60; show_summary = $true },

            [pscustomobject]@{ id = 102; session_key = 'b5d0b5ea-bff5-484d-a17c-adc217006efa'; width_weight = 40; show_summary = $false }

        )

    }

    Save-WindowLayoutMemory $layoutCtx $customLayout

    $reloadedLayout = Get-WindowLayoutMemory $layoutCtx

    Assert ($reloadedLayout.WinWidth -eq 1240 -and $reloadedLayout.RailCollapsed -eq $true -and $reloadedLayout.Panes.Count -eq 2 -and $null -ne $reloadedLayout.HiddenRightPane) 'Window layout memory persists dimensions, rail collapse state, panes, and hidden right pane'

    $sameSessionDupIdLayout = [pscustomobject]@{

        WinWidth = 1240; WinHeight = 740; RailWidth = 240; RailCollapsed = $false; ShowArchived = $false; HiddenRightPane = $null

        Panes = @(

            [pscustomobject]@{ id = 110; session_key = 'tsk_19283093310b828b'; width_weight = 50; show_summary = $false },

            [pscustomobject]@{ id = 110; session_key = 'tsk_19283093310b828b'; width_weight = 50; show_summary = $true }

        )

    }

    Save-WindowLayoutMemory $layoutCtx $sameSessionDupIdLayout

    $reloadedSameSession = Get-WindowLayoutMemory $layoutCtx

    Assert ($reloadedSameSession.Panes.Count -eq 2 -and $reloadedSameSession.Panes[0].session_key -eq 'tsk_19283093310b828b' -and $reloadedSameSession.Panes[1].session_key -eq 'tsk_19283093310b828b' -and $reloadedSameSession.Panes[0].id -ne $reloadedSameSession.Panes[1].id) 'Get-WindowLayoutMemory preserves same-session dual-pane layout and repairs duplicate pane IDs'

    $resetLayout = Reset-WindowLayoutMemory $layoutCtx

    Assert ($resetLayout.WinWidth -eq 1320 -and $resetLayout.WinHeight -eq 840 -and $resetLayout.RailCollapsed -eq $false -and $resetLayout.Panes.Count -eq 1) 'Reset-WindowLayoutMemory restores default 1320x840 layout'

    Save-WindowLayoutMemory $layoutCtx ([pscustomobject]@{ WinWidth = 4200; WinHeight = 2800; RailWidth = 260; RailCollapsed = $false; ShowArchived = $true; ThemeMode = 'system'; HiddenRightPane = $null; Panes = $resetLayout.Panes })
    $clampedHiLayout = Get-WindowLayoutMemory $layoutCtx
    Assert ($clampedHiLayout.WinWidth -eq 3840 -and $clampedHiLayout.WinHeight -eq 2400) 'Window layout memory clamps upper bounds to 3840x2400'

    # ---- Spec Module 1 (Hazards 1-5): ConnectionManager.psm1 Guards & Multi-Platform Capsule CRUD ----
    $guardBinDir = Join-Path $testRoot 'guard-cli-bin'
    [IO.Directory]::CreateDirectory($guardBinDir) | Out-Null
    $fakeCodexExe = Join-Path $guardBinDir 'codex.exe'
    $fakeClaudeCmd = Join-Path $guardBinDir 'claude.cmd'
    [IO.File]::WriteAllText($fakeCodexExe, 'fake', [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($fakeClaudeCmd, '@echo off', [Text.Encoding]::ASCII)
    $addCodexRes = Add-CustomCliAgent -Context $context -CommandPath $fakeCodexExe -DisplayName 'Custom Codex'
    $addClaudeRes = Add-CustomCliAgent -Context $context -CommandPath $fakeClaudeCmd -DisplayName 'Custom Claude'
    Assert ($addCodexRes.AddedAgent.id -eq 'custom-codex' -and $addCodexRes.AddedAgent.kind -eq 'custom') 'Hazard 1: Add-CustomCliAgent prefixes reserved codex id to custom-codex with kind=custom'
    Assert ($addClaudeRes.AddedAgent.id -eq 'custom-claude' -and $addClaudeRes.AddedAgent.kind -eq 'custom') 'Hazard 1: Add-CustomCliAgent prefixes reserved claude id to custom-claude with kind=custom'

    $safeAcpCfg = Resolve-SafeAcpCoreConfig -DetectedAgents $addClaudeRes.Agents -Settings ([pscustomobject]@{ acp_default_profile = 'nonexistent-agent'; acp_max_concurrent_prompts = 99 })
    $safeAcpZero = Resolve-SafeAcpCoreConfig -DetectedAgents $addClaudeRes.Agents -Settings ([pscustomobject]@{ acp_default_profile = 'codex'; acp_max_concurrent_prompts = 0 })
    $safeAcpNeg = Resolve-SafeAcpCoreConfig -DetectedAgents $addClaudeRes.Agents -Settings ([pscustomobject]@{ acp_default_profile = 'codex'; acp_max_concurrent_prompts = -2 })
    Assert ($safeAcpCfg.AcpMaxConcurrentPrompts -eq 8 -and $safeAcpCfg.AcpDefaultProfile -eq $addClaudeRes.Agents[0].id -and $safeAcpCfg.AcpEnabled -eq 'true' -and $safeAcpZero.AcpEnabled -eq 'false' -and $safeAcpNeg.AcpEnabled -eq 'false') 'Hazard 1 & 2: Resolve-SafeAcpCoreConfig behaviorally clamps ACP concurrency to 1..8, falls back invalid default profile, and disables ACP when limit is <= 0'

    # Hazard 4: Non-destructive merge in Save-ConnectionSettings
    $diskPreMerge = [IO.File]::ReadAllText($context.SettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $diskPreMerge | Add-Member -NotePropertyName 'workspace_roots' -NotePropertyValue @('D:\ws_keep') -Force
    $diskPreMerge | Add-Member -NotePropertyName 'enabled_platforms' -NotePropertyValue @('openai', 'claude') -Force
    $diskPreMerge | Add-Member -NotePropertyName 'custom_extension_field' -NotePropertyValue 'keep_value_123' -Force
    [IO.File]::WriteAllText($context.SettingsPath, ($diskPreMerge | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    $bareSettings = Get-DefaultConnectionSettings $context
    $bareSettings.tunnel_id = $id
    $bareSettings.runtime_root = $fixture
    Save-ConnectionSettings $context $bareSettings '' ''
    $diskPostMerge = [IO.File]::ReadAllText($context.SettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert ($diskPostMerge.custom_extension_field -eq 'keep_value_123' -and @($diskPostMerge.workspace_roots)[0] -eq 'D:\ws_keep' -and (@($diskPostMerge.enabled_platforms) -contains 'claude')) 'Hazard 4: Save-ConnectionSettings performs non-destructive merge preserving extension fields in settings.json'

    # Hazard 3: Multi-Platform Capsule CRUD & tunnel/apikey isolation
    $capCtx = New-ConnectionContext -DataRoot (Join-Path $testRoot 'capsule-data') -Isolated
    $capSettings = Get-DefaultConnectionSettings $capCtx
    $capSettings.tunnel_id = $id
    $capSettings.runtime_root = $fixture
    Save-ConnectionSettings $capCtx $capSettings $fakeKey $fakeToken
    $openaiKeyBytesBefore = [IO.File]::ReadAllText($capCtx.KeyPath)
    $capState1 = Add-CapsulePlatform -Context $capCtx -Platform 'claude'
    $claudeDefProf = $capState1.Profiles | Where-Object { $_.Platform -eq 'claude' } | Select-Object -First 1
    Assert (($capState1.EnabledPlatforms -contains 'chatgpt') -and ($capState1.EnabledPlatforms -contains 'claude') -and $null -ne $claudeDefProf -and $claudeDefProf.Name -eq '默认' -and $claudeDefProf.Kind -eq 'public_tunnel' -and $claudeDefProf.TunnelId -eq '' -and $claudeDefProf.HasKey -eq $false -and $claudeDefProf.Enabled -eq $false) 'Hazard 3: Add-CapsulePlatform adds claude to EnabledPlatforms with a clean disabled default apikey profile'
    $claudeKey = 'sk-ant-api03-offline-test-key-123456'
    $probeTcp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probeTcp.Start()
    $probePort = ([System.Net.IPEndPoint]$probeTcp.LocalEndpoint).Port
    $psBg = [powershell]::Create().AddScript({
        param($listener)
        try {
            $client = $listener.AcceptTcpClient()
            $stream = $client.GetStream()
            $buf = New-Object byte[] 1024
            [void]$stream.Read($buf, 0, $buf.Length)
            $bodyBytes = [Text.Encoding]::UTF8.GetBytes('{"data":[]}')
            $hdrBytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n")
            $stream.Write($hdrBytes, 0, $hdrBytes.Length)
            $stream.Write($bodyBytes, 0, $bodyBytes.Length)
            $stream.Flush()
            $client.Close()
        } catch {}
    }).AddArgument($probeTcp)
    $probeAsync = $psBg.BeginInvoke()
    try {
        $capState2 = Save-ConnectionProfile -Context $capCtx -Settings $capSettings -ProfileId $claudeDefProf.Id -Name 'Claude 个人 Pro' -TunnelId '' -ApiKey $claudeKey -Platform 'claude' -Kind 'apikey' -BaseUrl "http://127.0.0.1:$probePort" -Enabled $false
        $probeOkRes = Test-PlatformConnectionProfile -Context $capCtx -Settings $capSettings -ProfileId $claudeDefProf.Id
        $afterProbeState = Get-ConnectionProfiles $capCtx $capSettings
        $afterProbeClaude = $afterProbeState.Profiles | Where-Object { $_.Id -eq $claudeDefProf.Id } | Select-Object -First 1
        Assert ($probeOkRes.Ok -eq $true -and $probeOkRes.StatusCode -eq 200 -and $afterProbeClaude.Enabled -eq $false) 'F1 & F2: Test-PlatformConnectionProfile performs real HTTP probe (HTTP 200) without mutating Enabled state'
    } finally {
        try { $probeTcp.Stop(); $psBg.Dispose() } catch {}
    }
    Assert-Throws { Test-PlatformConnectionProfile -Context $capCtx -Settings $capSettings -ProfileId $claudeDefProf.Id } 'F1: Test-PlatformConnectionProfile throws when endpoint is unreachable'
    $enClaudeState = Set-ConnectionProfileEnabled -Context $capCtx -Settings $capSettings -ProfileId $claudeDefProf.Id -Enabled $true
    $enClaudeProf = $enClaudeState.Profiles | Where-Object { $_.Id -eq $claudeDefProf.Id } | Select-Object -First 1
    Assert ($enClaudeProf.Enabled -eq $true -and $enClaudeState.ActiveProfileByPlatform['claude'] -eq $claudeDefProf.Id) 'Set-ConnectionProfileEnabled resolves target profile, enables it, and updates active_profile_by_platform'
    $selClaudeRes = Select-ConnectionProfile -Context $capCtx -Settings $capSettings -ProfileId $claudeDefProf.Id
    $capSettingsAfter = Read-ConnectionSettings $capCtx
    $openaiKeyBytesAfter = [IO.File]::ReadAllText($capCtx.KeyPath)
    Assert ($capState2.ActiveProfileId -eq 'prof_primary' -and $selClaudeRes.ProfilesState.ActiveProfileByPlatform['claude'] -eq $claudeDefProf.Id -and $capSettingsAfter.tunnel_id -eq $id -and $openaiKeyBytesAfter -eq $openaiKeyBytesBefore) 'Hazard 3: Saving and selecting an apikey profile never overwrites OpenAI tunnel_id or openai-key.dpapi'
    $capState3 = Remove-CapsulePlatform -Context $capCtx -Platform 'claude'
    Assert ($capState3.EnabledPlatforms -notcontains 'claude' -and ($capState3.EnabledPlatforms -contains 'chatgpt')) 'Hazard 3: Remove-CapsulePlatform removes claude from EnabledPlatforms while keeping chatgpt'

    # Hazard 5: Get-WebBridgeState cold start never borrows ~/.codex models
    $wbColdState = Get-WebBridgeState $capCtx
    Assert (@($wbColdState.available_models).Count -eq 0 -and $null -ne (Get-Command Get-CodexCachedAvailableModels -ErrorAction SilentlyContinue)) 'Hazard 5: Get-WebBridgeState returns empty available_models on cold start while preserving Get-CodexCachedAvailableModels helper'

    # Cold Slate Cache verification in main suite (Get-ConnectionProfiles + Get-AvailableBrowserProfiles)
    Clear-ConnectionProfilesCache
    [void](Get-ConnectionProfiles $capCtx $capSettings)
    [void](Get-ConnectionProfiles $capCtx $capSettings)
    $mainCpStats = Get-ConnectionProfilesCacheStats
    Assert ($mainCpStats.Misses -eq 1 -and $mainCpStats.Hits -eq 1) 'Main suite: Get-ConnectionProfiles Cold Slate Cache hits on unchanged poll'
    Clear-BrowserProfilesCache
    [void](Get-AvailableBrowserProfiles -Context $capCtx)
    [void](Get-AvailableBrowserProfiles -Context $capCtx)
    $mainBpStats = Get-BrowserProfilesCacheStats
    Assert ($mainBpStats.Misses -eq 1 -and $mainBpStats.Hits -eq 1) 'Main suite: Get-AvailableBrowserProfiles Cold Slate Cache hits on unchanged poll'



    # Load the actual WPF form in an isolated context and exercise its real P3 UI handlers.

    $uiData=Join-Path $testRoot 'ui'

    . (Join-Path $managerRoot '连接管理.ps1') -DataRoot $uiData -Preview -NoShow

    Assert ($script:controls.ShieldCheck.IsChecked -eq $true) 'GUI defaults ShieldCheck to checked'

    Assert ($script:controls.SessionStatus.Text -match '等待连接后显示实时脉搏') 'GUI renders SessionStatus pulse row'

    Assert ($script:controls.LiveTabPanel.Visibility -eq 'Visible' -and $script:controls.FormScroll.Visibility -eq 'Collapsed') 'Variant C defaults to Live Conversations tab'



    # Verify SessionListPanel and P3 Workspace Panes when Sessions & ArchivedSessions are present

    $script:display.Sessions = @($restoredPulse.Sessions)

    $script:display.ArchivedSessions = @($stallPulse.ArchivedSessions)

    $script:display.SubagentCallCount = 2

    $script:display.HiddenIdleCount = 1

    Update-SessionCards

    Assert ($script:controls.SessionListPanel.Children.Count -eq 2 -and $script:controls.EmptySessionBox.Visibility -eq 'Collapsed') 'SessionListPanel renders active main conversation items in LeftTaskRail'

    $firstCardActRow = $script:controls.SessionListPanel.Children[0].Tag.ActRow
    Assert ($null -eq $script:controls.ArchivedListPanel -and $firstCardActRow.Children.Count -eq 2) 'LeftTaskRail removes dead ArchivedListPanel and active cards expose only Open-Web and Archive buttons (no direct Delete button)'



    # Verify P3 Outer Window Stability when collapsing/expanding LeftTaskRail

    $initialWinWidth = $script:window.Width

    $initialWinHeight = $script:window.Height

    Toggle-LeftRail

    Assert ($script:layout.RailCollapsed -eq $true -and $script:controls.LeftTaskRail.Visibility -eq 'Collapsed' -and $script:window.Width -eq $initialWinWidth -and $script:window.Height -eq $initialWinHeight) 'Collapsing LeftTaskRail never alters outer window Width or Height'

    Toggle-LeftRail

    Assert ($script:layout.RailCollapsed -eq $false -and $script:controls.LeftTaskRail.Visibility -eq 'Visible' -and $script:window.Width -eq $initialWinWidth) 'Expanding LeftTaskRail restores rail without changing outer window Width'



    # Verify P3 Multi-Pane Horizontal Split (up to 4 panes) & Codex Floating Summary Card

    Assert ($script:layout.Panes.Count -eq 1) 'Workspace starts with 1 conversation pane'

    Assign-TaskToPane $script:layout.Panes[0].id $restoredPulse.Sessions[1].SessionKey

    Split-PaneAfter 101

    Assert ($script:layout.Panes.Count -eq 2 -and $script:controls.PanesHostGrid.Children.Count -eq 3 -and $script:window.Width -eq $initialWinWidth) 'Split-PaneAfter creates 2nd horizontal pane + draggable splitter without changing outer window Width'

    Assign-TaskToPane $script:layout.Panes[1].id $twoConvPulse.Sessions[0].SessionKey

    Assert ($script:layout.Panes[1].session_key -eq $twoConvPulse.Sessions[0].SessionKey) 'Assign-TaskToPane assigns 2nd conversation to right pane'

    Toggle-PaneSummary $script:layout.Panes[1].id

    Assert ($script:layout.Panes[1].show_summary -eq $true) 'Toggle-PaneSummary toggles Codex floating summary card'

    # Verify unified split-pane opening (always opens Task Picker regardless of whether 0, 1, or N active tasks exist)

    Close-PaneById $script:layout.Panes[1].id

    $script:display.Sessions = @($multiPulse.Sessions[0])

    Assign-TaskToPane $script:layout.Panes[0].id $multiPulse.Sessions[0].SessionKey

    Split-PaneAfter $script:layout.Panes[0].id

    $splitPickerElem = Build-PaneTaskPicker $script:layout.Panes[1]

    Assert ($script:layout.Panes.Count -eq 2 -and $script:layout.Panes[1].session_key -eq '' -and $script:pickerPaneIds.ContainsKey([int]$script:layout.Panes[1].id) -and $splitPickerElem -is [Windows.Controls.ScrollViewer] -and $script:layout.Panes[0].id -ne $script:layout.Panes[1].id) 'Split-PaneAfter uniformly opens Task Picker even when only 1 active task exists'
    Assign-TaskToPane $script:layout.Panes[1].id $multiPulse.Sessions[0].SessionKey

    Assert ($script:window.FontFamily.Source -match 'Source Han Serif SC VF' -and $script:controls.DismissUndoDeleteButton -is [Windows.Controls.Button]) 'Window uses Antigravity Source Han Serif SC VF font pack and exposes DismissUndoDeleteButton on UndoDeleteBorder'

    $script:controls.UndoDeleteBorder.Visibility = 'Visible'
    $script:controls.DismissUndoDeleteButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert ($script:controls.UndoDeleteBorder.Visibility -eq 'Collapsed') 'Clicking DismissUndoDeleteButton actively closes UndoDeleteBorder red notification'

    $script:display.Sessions = @($restoredPulse.Sessions)



    # Verify Key Mask Toggle in Connection Popover

    $script:controls.TabConfigButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))

    Assert ($script:controls.FormScroll.Visibility -eq 'Visible') 'TabConfigButton opens Connection & Key Popover'

    $script:controls.TabLiveButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))

    Assert ($script:controls.FormScroll.Visibility -eq 'Collapsed') 'TabLiveButton closes Connection & Key Popover'

    $script:display.IsFault = $true

    $script:display.Session = $errPulse.Session

    $script:display.SessionColor = $errPulse.SessionColor

    Update-PulseBanner

    Assert ($script:controls.PulsePrefixLabel.Text -eq '⚠ 通道故障告警：' -and $script:controls.PulseBannerBorder.Visibility -eq 'Visible') 'Pulse banner switches to Red Fault Alert Bar when IsFault is true'

    $script:display.IsFault = $false

    $script:display.Session = $twoConvPulse.Session

    $script:display.SessionColor = $twoConvPulse.SessionColor

    Update-PulseBanner

    Assert ($script:controls.PulsePrefixLabel.Text -eq '通道总览：' -and $script:controls.PulseBannerBorder.Visibility -eq 'Collapsed') 'Pulse banner collapses when IsFault is false'

    Open-SessionDetail $multiPulse.Sessions[0].SessionKey

    Assert ($script:controls.SessionDetailOverlay.Visibility -eq 'Visible') 'Open-SessionDetail shows modal detail popup'

    Assert ($script:controls.DetailModalTitle.Text -eq 'ProjectAlpha C4 三层重构：工单 06–21') 'Detail modal shows conversation title'

    Assert ($script:controls.DetailDiagnosisText.Text -match '结论：' -and $script:controls.DetailDiagnosisText.Text -match '步骤 20：拆旧清理') 'Detail modal shows plain-language AI diagnosis'

    Assert ($script:controls.DetailStepsPanel.Children.Count -eq 1) 'Detail modal populates step checklist'

    Assert ($script:controls.DetailLatestSummaryText.Text -eq '正在执行拆旧清理') 'Detail modal shows latest checkpoint summary'

    $script:controls.CloseDetailButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))

    Assert ($script:controls.SessionDetailOverlay.Visibility -eq 'Collapsed') 'CloseDetailButton hides modal detail popup'



    # Verify Q1 (Open-SessionWebPage), Q2 (Independent Archive Drawer), Q3 (Tag parameter + Clear All + Undo)

    $testBtnTag = New-QuietIconButton -Kind 'trash' -ToolTip '删除测试' -Tag 'tsk_test_tag' -IsDanger $true

    Assert ($testBtnTag.Tag -eq 'tsk_test_tag' -and $testBtnTag.ToolTip -eq '删除测试') 'New-QuietIconButton preserves -Tag and -ToolTip parameters'

    Open-ArchiveDrawer

    Assert ($script:controls.ArchiveDrawerOverlay.Visibility -eq 'Visible') 'Open-ArchiveDrawer displays independent Archive Drawer modal'

    Close-ArchiveDrawer

    Assert ($script:controls.ArchiveDrawerOverlay.Visibility -eq 'Collapsed') 'Close-ArchiveDrawer hides independent Archive Drawer modal'

    $openWebRes = Open-SessionWebPage -Context $pulseContext -Session $multiPulse.Sessions[0] -NoLaunchBrowser

    Assert ($openWebRes.Action -in @('FocusedExistingTab','OpenedBrowserUrl') -and $openWebRes.Url -match '^https://chatgpt\.com/') 'Open-SessionWebPage resolves ChatGPT URL or focuses active tab'

    # ---- Spec v4.3 Q4: "打开网页 ↗" must verify the window is really on screen (zero real window actions in tests) ----
    # (2) pure toast router: success copy only for verified windows, honest warning otherwise
    $warnText = '⚠ 已请求打开窗口，但屏幕上未检测到可见窗口（可能仍在后台托盘），请从任务栏/托盘手动恢复'
    Assert ((Get-OpenWebPageToastText -Result ([pscustomobject]@{ Action = 'FocusedDesktopApp'; ConvUuid = 'c1'; Browser = 'Desktop'; Url = ''; WindowVerifiedVisible = $true })) -eq '↗ 已激活并切到 ChatGPT 桌面端对应对话') 'Toast: verified desktop window with bound room says activated and switched'
    Assert ((Get-OpenWebPageToastText -Result ([pscustomobject]@{ Action = 'FocusedDesktopApp'; ConvUuid = ''; Browser = 'Desktop'; Url = ''; WindowVerifiedVisible = $true })) -eq '↗ 已为您打开 ChatGPT 窗口') 'Toast: verified desktop window without a bound room says window opened'
    Assert ((Get-OpenWebPageToastText -Result ([pscustomobject]@{ Action = 'FocusedExistingTab'; ConvUuid = 'c1'; Browser = 'Chrome'; Url = 'u'; WindowVerifiedVisible = $true })) -eq '↗ 已激活并切到 Chrome 中对应的 ChatGPT 网页标签页') 'Toast: verified browser tab keeps the existing copy'
    Assert ((Get-OpenWebPageToastText -Result ([pscustomobject]@{ Action = 'OpenedBrowserUrl'; ConvUuid = 'c1'; Browser = 'Chrome:P'; Url = 'https://chatgpt.com/c/c1'; WindowVerifiedVisible = $true })) -eq '↗ 已在 Chrome:P 打开对应的 ChatGPT 网页（https://chatgpt.com/c/c1）') 'Toast: verified browser launch keeps the existing copy'
    foreach ($badAction in @('FocusedDesktopApp', 'FocusedExistingTab', 'OpenedBrowserUrl')) {
        Assert ((Get-OpenWebPageToastText -Result ([pscustomobject]@{ Action = $badAction; ConvUuid = 'c1'; Browser = 'X'; Url = 'u'; WindowVerifiedVisible = $false })) -eq $warnText) "Toast: unverified $badAction never claims success"
    }
    Assert ((Get-OpenWebPageToastText -Result ([pscustomobject]@{ Action = 'FocusedDesktopApp'; ConvUuid = 'c1' })) -eq $warnText) 'Toast: a result without WindowVerifiedVisible is treated as unverified'
    Assert ((Get-OpenWebPageToastText -Result ([pscustomobject]@{ Action = 'UnboundConversation'; ConvUuid = ''; WindowVerifiedVisible = $true })) -eq '该任务尚未关联网页对话') 'Toast: unbound conversation keeps its own message'

    # (3) new helpers with no ChatGPT process: return $false / never throw, never touch a window
    $noProc = 'RelayNoSuchProcess_zz'
    Assert ((Initialize-RelayWindowWake) -eq $true -and ('Win32.RelayWindowWake' -as [type])) 'Initialize-RelayWindowWake loads the helper type (idempotent)'
    Assert ((Show-RelayProcessMainWindow -ProcessName @($noProc) -TimeoutMs 300 -Focus) -eq $false) 'Show-RelayProcessMainWindow returns $false when no matching process exists'
    Assert ((Show-RelayProcessMainWindow -ProcessName @() -TimeoutMs 100) -eq $false) 'Show-RelayProcessMainWindow returns $false for an empty process list'
    Assert ((Wait-RelayWindowShown -Handle ([IntPtr]::Zero) -TimeoutMs 100) -eq $false) 'Wait-RelayWindowShown rejects a null window handle'
    Assert ([Win32.RelayWindowWake]::Wake([IntPtr]::Zero) -eq $false -and [Win32.RelayWindowWake]::IsShown([IntPtr]::Zero) -eq $false) 'Win32 helper treats a null HWND as not shown (no window action)'
    Assert ([Win32.RelayWindowWake]::FindMainWindow([int[]]@(-12345), 'Chrome_WidgetWin_1') -eq [IntPtr]::Zero) 'FindMainWindow returns Zero for an unknown PID'
    Assert ((Invoke-ForegroundBrowserWindowActivate -BrowserExeName $noProc) -eq $false) 'Invoke-ForegroundBrowserWindowActivate returns $false when the browser is not running'
    $desktopAppAst = (Get-Command Start-ChatGptDesktopApp).ScriptBlock.Ast
    Assert ((Get-Command Start-ChatGptDesktopApp).Parameters.ContainsKey('Context') -and (Get-Command Start-ChatGptDesktopApp).Parameters.ContainsKey('Minimized')) 'Start-ChatGptDesktopApp takes -Context and keeps -Minimized'
    Assert (@($desktopAppAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Stop-Process', 'taskkill') }, $true)).Count -eq 0 -and $desktopAppAst.Extent.Text -match 'desktop_wake_main_window') 'Start-ChatGptDesktopApp wakes via the hub and never kills ChatGPT'

    # (1) Open-SessionWebPage: window actions are replaced by spies; isolated/no-launch runs never reach them
    $wakeMod = Get-Module ConnectionManager
    $spyNames = @('Start-ChatGptDesktopApp', 'Open-BridgeHandoverWindow', 'Invoke-ForegroundBrowserWindowActivate', 'Show-RelayProcessMainWindow', 'Wait-RelayWindowShown')
    $spyOrig = @{}
    foreach ($spyName in $spyNames) { $spyOrig[$spyName] = (Get-Command $spyName).ScriptBlock }
    $global:RelayWakeSpyLog = New-Object System.Collections.ArrayList
    try {
        & $wakeMod {
            param($names)
            foreach ($n in $names) { Set-Item -Path "function:script:$n" -Value ([scriptblock]::Create("[void]`$global:RelayWakeSpyLog.Add('$n'); return `$false")) }
            Set-Item -Path 'function:script:Start-Process' -Value ([scriptblock]::Create("[void]`$global:RelayWakeSpyLog.Add('Start-Process')"))
        } $spyNames
        [void](& $wakeMod { Open-BridgeHandoverWindow -Url 'https://chatgpt.com/' -BrowserProfile 'Chrome:Profile 1' })
        Assert ($global:RelayWakeSpyLog.Count -eq 1 -and $global:RelayWakeSpyLog[0] -eq 'Open-BridgeHandoverWindow') 'Spies are active inside the module (sanity check)'
        $global:RelayWakeSpyLog.Clear()

        $wakeSessions = @(
            [pscustomobject]@{ SessionKey = 'tsk_wake_web'; Title = 'wake web' },
            [pscustomobject]@{ SessionKey = 'tsk_wake_desktop'; Title = 'wake desktop'; BrowserProfile = 'Desktop:ChatGPT' }
        )
        foreach ($wakeSession in $wakeSessions) {
            $isoRes = Open-SessionWebPage -Context $context -Session $wakeSession
            Assert ($isoRes.PSObject.Properties['WindowVerifiedVisible'] -and $isoRes.WindowVerifiedVisible -eq $true) "Isolated context reports WindowVerifiedVisible=true ($($wakeSession.SessionKey))"
            $nlRes = Open-SessionWebPage -Context $context -Session $wakeSession -NoLaunchBrowser
            Assert ($nlRes.WindowVerifiedVisible -eq $true) "-NoLaunchBrowser reports WindowVerifiedVisible=true ($($wakeSession.SessionKey))"
        }
        Assert ($global:RelayWakeSpyLog.Count -eq 0) 'Isolated / -NoLaunchBrowser runs perform zero real window actions'

        # A real foreground launch (hub unreachable) with an unbound room still opens the window and reports the verified result honestly
        $fgCtx = $context | Select-Object *
        $fgCtx.Isolated = $false
        $fgCtx | Add-Member -NotePropertyName HubUrl -NotePropertyValue 'http://127.0.0.1:1' -Force
        $fgRes = Open-SessionWebPage -Context $fgCtx -Session $wakeSessions[1]
        Assert ($fgRes.Action -eq 'FocusedDesktopApp' -and -not $fgRes.ConvUuid -and $fgRes.WindowVerifiedVisible -eq $false -and $global:RelayWakeSpyLog -contains 'Open-BridgeHandoverWindow') 'Foreground launch with an unbound room still opens the window and reports an unverified window as false'
        Assert ((Get-OpenWebPageToastText -Result $fgRes) -eq $warnText) 'Unverified foreground launch yields the honest warning toast'
    } finally {
        & $wakeMod {
            param($orig, $names)
            foreach ($n in $names) { Set-Item -Path "function:script:$n" -Value $orig[$n] }
            Remove-Item -Path 'function:Start-Process' -ErrorAction SilentlyContinue
        } $spyOrig $spyNames
        Remove-Variable -Name RelayWakeSpyLog -Scope Global -ErrorAction SilentlyContinue
    }
    Assert ((Get-Command Open-BridgeHandoverWindow).ScriptBlock.ToString() -eq $spyOrig['Open-BridgeHandoverWindow'].ToString() -and -not (& $wakeMod { (Get-Command Start-Process).CommandType -eq 'Function' })) 'Window-action spies are removed after the test'


    # Verify Open-SessionWebPage discovers conv_uuid from tabs with last_seen_at even when bound to a blank homepage tab

    $wbTest = Get-WebBridgeState $pulseContext

    $wbTest.tabs | Add-Member -NotePropertyName 'tab_blank' -NotePropertyValue ([pscustomobject]@{ tab_id = 'tab_blank'; conv_uuid = ''; url = 'https://chatgpt.com/'; title = 'ChatGPT'; page_hints = @(); last_seen_at = [DateTimeOffset]::UtcNow.AddMinutes(-20).ToString('o') }) -Force

    $wbTest.tabs | Add-Member -NotePropertyName 'tab_real' -NotePropertyValue ([pscustomobject]@{ tab_id = 'tab_real'; conv_uuid = '69de6111-1610-83e7-810e-7054f34db096'; url = 'https://chatgpt.com/c/69de6111-1610-83e7-810e-7054f34db096'; title = 'ProjectAlpha C4 三层重构'; page_hints = @($multiPulse.Sessions[0].SessionKey); last_seen_at = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o') }) -Force

    Save-WebBridgeState $pulseContext $wbTest

    [void](Set-SessionBridgeBinding -Context $pulseContext -SessionKey $multiPulse.Sessions[0].SessionKey -ConvUuid '' -TabId 'tab_blank' -Title 'ChatGPT')

    $openArchivedRes = Open-SessionWebPage -Context $pulseContext -Session $multiPulse.Sessions[0] -NoLaunchBrowser

    Assert ($openArchivedRes.ConvUuid -eq '69de6111-1610-83e7-810e-7054f34db096' -and $openArchivedRes.Url -eq 'https://chatgpt.com/c/69de6111-1610-83e7-810e-7054f34db096') 'Open-SessionWebPage recovers exact /c/<uuid> URL from matching tab even when closed or bound to blank tab'



    # Verify Style C3 Pre-configurable Auto-Resend Config & Variant A Multi-Profile CRUD

    $defaultAutoCfg = Get-AutoResendConfig $pulseContext

    Assert ($defaultAutoCfg.Enabled -eq $true -and $defaultAutoCfg.StallMinutes -eq 3 -and $defaultAutoCfg.MaxRetries -eq 1) 'Get-AutoResendConfig returns default C3 auto-resend configuration'

    $updatedAutoCfg = Set-AutoResendConfig -Context $pulseContext -Enabled $true -StallMinutes 5 -MaxRetries 3

    Assert ($updatedAutoCfg.StallMinutes -eq 5 -and $updatedAutoCfg.MaxRetries -eq 3) 'Set-AutoResendConfig persists pre-configured stall minutes and max retries'

    $progressPrompt = New-StallWakeupPrompt -Session $multiPulse.Sessions[0]

    Assert ($progressPrompt -match '【本机进度同步与续跑指令】' -and $progressPrompt -match 'tsk_19283093310b828b') 'New-StallWakeupPrompt always carries task progress ledger for tsk_xxx tasks'



    $addedProfState = Save-ConnectionProfile -Context $script:context -Settings $script:settings -ProfileId 'new' -Name 'Team B 备用隧道' -TunnelId $id -ApiKey $fakeKey

    Assert (@($addedProfState.Profiles).Count -ge 2) 'Save-ConnectionProfile creates extensible multi-profile entry'

    Refresh-ProfilePopoverState

    Assert ($script:controls.ProfilesListPanel.Children.Count -ge 2) 'ProfilesListPanel renders all saved tunnel profiles in Variant A popover'

    $newProfObj = $addedProfState.Profiles | Where-Object { $_.Name -eq 'Team B 备用隧道' } | Select-Object -First 1

    $afterDelState = Remove-ConnectionProfile -Context $script:context -Settings $script:settings -ProfileId $newProfObj.Id

    Assert (@($afterDelState.Profiles | Where-Object { $_.Id -eq $newProfObj.Id }).Count -eq 0) 'Remove-ConnectionProfile deletes selected profile cleanly'



    # Verify Q1-Q4 Style 1 UI Polish (Custom Flat Templates, Unified Composer Pod, Smooth Micro-Animations, WindowChrome)

    $wc = [Windows.Shell.WindowChrome]::GetWindowChrome($window)

    Assert ($null -ne $wc -and $wc.CaptionHeight -eq 0) 'WindowChrome is attached for modern borderless white window'

    Assert ($null -ne $window.Resources[[Windows.Controls.ComboBox]] -and $null -ne $window.Resources[[Windows.Controls.CheckBox]]) 'Custom flat ComboBox and CheckBox styles are registered in Window.Resources'

    $minIcon = New-VectorIcon -Kind 'minimize' -Size 10 -ColorHex '#71717A'

    $maxIcon = New-VectorIcon -Kind 'maximize' -Size 10 -ColorHex '#71717A'

    Assert ($null -ne $minIcon -and $null -ne $maxIcon) 'New-VectorIcon supports minimize and maximize window control icons'

    $dummyBorder = [Windows.Controls.Border]::new()

    Start-SmoothEnterAnimation -Element $dummyBorder -FromY -6 -DurationMs 160

    Assert ($dummyBorder.Opacity -eq 1.0 -and $dummyBorder.RenderTransform -is [Windows.Media.TranslateTransform]) 'Start-SmoothEnterAnimation initializes Opacity and TranslateTransform cleanly'

    $dummyBtn = [Windows.Controls.Button]::new()

    Set-SmoothButtonAppearance -Button $dummyBtn -BgHex '#2563EB' -BorderHex '#1D4ED8'

    Assert ($dummyBtn.Background.ToString() -match '2563EB') 'Set-SmoothButtonAppearance updates button background and border cleanly'

    Assert ($null -ne $script:controls.AppTitleBarBorder -and $null -ne $script:controls.WorkspaceOuterBorder) 'Antigravity L-shaped outer frame (AppTitleBarBorder + WorkspaceOuterBorder) is present'

    $script:dirty = $false

    Refresh-FormState

    Assert (-not $script:dirty -and -not (Test-HasUnsavedFormEdits)) 'Refresh-FormState and Refresh-ProfilePopoverState never falsely mark form as dirty'

    Select-WindowTab 'Config'

    Assert (-not (Test-HasUnsavedFormEdits)) 'Opening Config tab without modifying inputs does not trigger unsaved edits warning'

    $origProfName = $script:controls.ProfileNameInput.Text

    $script:controls.ProfileNameInput.Text = '临时修改未保存名称'

    Assert (Test-HasUnsavedFormEdits) 'Modifying ProfileNameInput while Config form is open is detected by Test-HasUnsavedFormEdits'

    $script:controls.ProfileNameInput.Text = $origProfName

    Select-WindowTab 'Live'

    Assert (-not (Test-HasUnsavedFormEdits)) 'Returning to Live tab clears unsaved edit prompt guard'

    $narrowStream = Build-PaneStreamContent $script:layout.Panes[0] $multiPulse.Sessions[0] $true

    Assert ($null -ne $narrowStream) 'Build-PaneStreamContent supports responsive narrow split-pane layout (-IsNarrow)'

    $script:layout.RailCollapsed = $false

    $script:layout.RailWidth = 120

    Apply-LeftRailGeometry

    Assert ($script:layout.RailWidth -eq 200 -and $script:controls.LeftRailColumn.Width.Value -eq 200 -and $script:controls.LeftTaskRail.ClipToBounds -eq $true) 'LeftTaskRail enforces 200px minimum readable width and ClipToBounds for drawer slide'

    $script:layout.RailWidth = 260

    Apply-LeftRailGeometry

    Assert ($script:PANE_MIN_COMFORT_PX -eq 340.0) 'PANE_MIN_COMFORT_PX enforces 340px comfortable minimum width per split pane'



    # Verify RelayStudio Absorbed Core Config (ACP Default Profile, Browser CDP, 3-Tier Startup Mode, Official Panel Removal)

    $coreCfg0 = Get-CoreEngineConfig $script:context

    Assert ($coreCfg0.AcpDefaultProfile -eq 'codex' -and $coreCfg0.BrowserEnabled -eq $true -and $coreCfg0.StartupMode -eq 'tray') 'Get-CoreEngineConfig returns default RelayStudio core engine and startup settings'

    $coreCfg1 = Set-CoreEngineConfig -Context $script:context -AcpDefaultProfile 'claude' -BrowserEnabled $false -StartupMode 'popup'

    Assert ($coreCfg1.AcpDefaultProfile -eq 'claude' -and $coreCfg1.BrowserEnabled -eq $false -and $coreCfg1.StartupMode -eq 'popup') 'Set-CoreEngineConfig persists ACP default profile, browser CDP toggle, and startup mode'

    $coreCfg2 = Set-CoreEngineConfig -Context $script:context -AcpDefaultProfile 'codex' -BrowserEnabled $true -StartupMode 'off'

    Assert ($coreCfg2.AcpDefaultProfile -eq 'codex' -and $coreCfg2.BrowserEnabled -eq $true -and $coreCfg2.StartupMode -eq 'off') 'Set-CoreEngineConfig restores codex, browser CDP, and off startup mode'

    Assert ($script:controls.OfficialButton.Visibility -eq 'Collapsed') 'OfficialButton is permanently collapsed in RelayStudio standalone UI'

    Assert ($null -ne $script:controls.RestartCoreButton -and $null -ne $script:controls.AcpProfileCodexButton -and $null -ne $script:controls.BrowserCdpToggleButton -and $null -ne $script:controls.StartupTrayButton) 'Popover exposes absorbed core restart, ACP profile selector, browser CDP toggle, and 3-tier startup mode controls'

    # Verify Popover Two-Line Tunnel Strip (with inline masked tunnel/key + copy) & Right-Caret Inline Accordion Edit & Always-Visible Delete & Footer Links
    Assert ($null -ne $script:controls.AcpLimit0Button -and $script:controls.Advanced.Visibility -eq 'Collapsed' -and $script:controls.ClosePopoverButton.Visibility -eq 'Collapsed') 'Popover exposes AcpLimit0Button (关闭), hides Advanced expander, and removes ClosePopoverButton'
    $acpZeroRes = Set-AcpConcurrencyLimit -Context $script:context -Limit 0
    Refresh-ProfilePopoverState
    Assert ($acpZeroRes.Limit -eq 0 -and (Get-AcpConcurrencyLimit $script:context) -eq 0 -and $script:controls.AcpConcurrencyLabel.Text -match '^CLI 智能体并发上限：' -and [string]$script:controls.AcpLimit0Button.Content -eq '关闭') 'Set-AcpConcurrencyLimit supports 0 (关闭) concurrency option with CLI 智能体并发上限 terminology'
    [void](Set-AcpConcurrencyLimit -Context $script:context -Limit 4)
    Refresh-ProfilePopoverState

    # Verify Slice 2: Top-Left ChatGPT/OpenAI Tunnel Popover vs. Top-Right ⚙ Global Settings Popover + Fast CLI Discovery + Auto-Archive Completed Timer + Default Carrier
    Assert ($script:controls.PopoverHeaderTitle.Text -match '^(ChatGPT|OpenAI) 隧道配置 \(\d+\)$') "Top-Left KeyPopoverBorder header shows ChatGPT/OpenAI 隧道配置 (N) (actual=$($script:controls.PopoverHeaderTitle.Text))"
    Assert ($null -ne $script:controls.GlobalSettingsButton -and $null -ne $script:controls.GlobalSettingsPopoverBorder -and $script:controls.GlobalSettingsPopoverBorder.Width -eq 460 -and [string]$script:controls.GlobalSettingsPopoverBorder.HorizontalAlignment -eq 'Left') 'Top-Left ⚙ GlobalSettingsButton and GlobalSettingsPopoverBorder (Width=460, Left-anchored beneath clicked icon) are present'
    Toggle-GlobalSettingsPopover
    Assert ($script:controls.GlobalSettingsPopoverBorder.Visibility -eq 'Visible' -and $script:controls.KeyPopoverBorder.Visibility -eq 'Collapsed') 'Toggle-GlobalSettingsPopover opens GlobalSettingsPopoverBorder and keeps KeyPopoverBorder closed'
    Toggle-GlobalSettingsPopover
    Assert ($script:controls.GlobalSettingsPopoverBorder.Visibility -eq 'Collapsed') 'Toggle-GlobalSettingsPopover closes GlobalSettingsPopoverBorder on second click'

    # Fast <30ms Local CLI Agent Discovery (Get-DetectedCliAgents / Discover-LocalCliAgents) & Zero npx -y fallback
    $coreAstText = (Get-Command Start-OfficialCoreIfNeeded).ScriptBlock.Ast.Extent.Text
    Assert ($coreAstText -notmatch '@agentclientprotocol' -and $coreAstText -notmatch 'npx\.cmd') 'Start-OfficialCoreIfNeeded removes npx -y @agentclientprotocol fallback completely'
    $fakeCliDir = Join-Path $testRoot 'fake-cli-bin'
    [IO.Directory]::CreateDirectory($fakeCliDir) | Out-Null
    foreach ($fakeBin in @('codex-acp.cmd', 'claude-agent-acp.cmd', 'codebuddy.cmd', 'agy.exe', 'my-custom-agent.cmd')) {
        [IO.File]::WriteAllText((Join-Path $fakeCliDir $fakeBin), "@echo off`r`n", [Text.Encoding]::ASCII)
    }
    $cliTestSettings = Read-ConnectionSettings $script:context
    $cliTestSettings | Add-Member -NotePropertyName 'extra_bin_dirs' -NotePropertyValue @($fakeCliDir) -Force
    Write-AtomicConnectionText $script:context.SettingsPath ($cliTestSettings | ConvertTo-Json -Depth 6)
    $script:settings = Read-ConnectionSettings $script:context
    $detectedCli1 = @(Discover-LocalCliAgents -ForceRescan -Settings $script:settings -Context $script:context)
    $swCliCache = [Diagnostics.Stopwatch]::StartNew()
    $detectedCli2 = @(Get-DetectedCliAgents -Settings $script:settings -Context $script:context)
    $swCliCache.Stop()
    $detectedIds = @($detectedCli2 | ForEach-Object { [string]$_.id })
    $wbAgent = $detectedCli2 | Where-Object { $_.id -eq 'workbuddy' } | Select-Object -First 1
    $agyAgent = $detectedCli2 | Where-Object { $_.id -eq 'agy' } | Select-Object -First 1
    Assert ($swCliCache.ElapsedMilliseconds -lt 30 -and ($detectedIds -contains 'codex') -and ($detectedIds -contains 'claude') -and ($detectedIds -contains 'workbuddy') -and ($detectedIds -contains 'agy') -and ($wbAgent.args -contains '--acp') -and ($wbAgent.kind -eq 'custom') -and ($agyAgent.kind -eq 'custom')) "Get-DetectedCliAgents / Discover-LocalCliAgents detects codex, claude, workbuddy (--acp), agy in <30ms (actual=$($swCliCache.ElapsedMilliseconds)ms)"

    $script:CustomCliPathOverride = Join-Path $fakeCliDir 'my-custom-agent.cmd'
    $script:controls.AddCustomCliAgentButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    $script:CustomCliPathOverride = $null
    $detectedAfterAdd = @(Get-DetectedCliAgents -Settings $script:settings -Context $script:context | ForEach-Object { [string]$_.id })
    Assert ($detectedAfterAdd -contains 'my-custom-agent') 'AddCustomCliAgentButton adds custom CLI executable to custom_cli_agents and refreshes detected CLI buttons'

    # Auto-Archive Completed Timer (immediate, 1d, 3d, 7d, off)
    Assert ($null -ne $script:controls.AutoArchiveImmediateButton -and $null -ne $script:controls.AutoArchive1dButton -and $null -ne $script:controls.AutoArchive3dButton -and $null -ne $script:controls.AutoArchive7dButton -and $null -ne $script:controls.AutoArchiveOffButton) 'GlobalSettingsPopoverBorder exposes 5 completed-task auto-archive timer buttons'
    $script:controls.AutoArchive1dButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    $cfgAfter1d = Get-CoreEngineConfig $script:context
    Assert ($cfgAfter1d.AutoArchiveCompletedMode -eq '1d') "Clicking AutoArchive1dButton persists auto_archive_completed_mode=1d (actual=$($cfgAfter1d.AutoArchiveCompletedMode))"
    $script:controls.AutoArchive3dButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Assert ((Get-CoreEngineConfig $script:context).AutoArchiveCompletedMode -eq '3d') 'Clicking AutoArchive3dButton restores default 3d auto-archive mode'
    Assert ($null -ne $script:controls.DefaultCarrierCombo -and $script:controls.DefaultCarrierCombo.Items.Count -ge 1) 'GlobalSettingsPopoverBorder exposes DefaultCarrierCombo populated from Get-AvailableBrowserProfiles'
    Assert ([string]$script:controls.BrowserCdpToggleButton.Content -match '^(● 已开启|○ 已关闭)$') "BrowserCdpToggleButton uses [● 已开启] / [○ 已关闭] copy (actual=$($script:controls.BrowserCdpToggleButton.Content))"

    $script:popoverOpen = $false
    Toggle-KeyPopover
    Assert ($script:controls.FormScroll.Visibility -eq 'Collapsed' -and $script:controls.DeleteProfileButton.Visibility -eq 'Visible') 'Opening popover defaults to collapsed inline edit form and keeps DeleteProfileButton always visible'
    Select-ProfileCard 'prof_primary'
    Assert ($script:viewingProfileId -eq 'prof_primary' -and $script:controls.FormScroll.Visibility -eq 'Collapsed') 'Clicking tunnel strip body only selects the profile without opening edit form'
    Toggle-ProfileInlineEdit 'prof_primary'
    Assert ($script:controls.FormScroll.Visibility -eq 'Visible' -and $script:controls.DeleteProfileButton.Visibility -eq 'Visible' -and $script:controls.SaveButton.Content -eq '保存') 'Clicking right caret icon expands inline edit form directly inside the tunnel strip with Delete and Save'
    Toggle-ProfileInlineEdit 'prof_primary'
    Assert ($script:controls.FormScroll.Visibility -eq 'Collapsed') 'Clicking right caret icon again collapses the inline edit form'
    Start-NewProfileForm
    Assert ($script:controls.FormScroll.Visibility -eq 'Visible' -and @($script:profilesState.Profiles).Count -eq 2) 'Clicking + 新增配置 creates a new profile strip and expands its inline edit box'
    Invoke-DeleteCurrentProfile
    Assert (@($script:profilesState.Profiles).Count -eq 1 -and $script:controls.FormScroll.Visibility -eq 'Collapsed') 'Clicking 删除此配置 removes the profile cleanly'
    Select-WindowTab 'Live'

    # ---- Spec Module 2 (Slice C): Top Bar 2-Group Pure Icons, Segmented Capsule, Popover Footer Order & + Platform Panel ----
    Assert ($script:controls.TunnelCapsuleBorder -is [Windows.Controls.Border] -and $script:controls.CapsuleSegmentsPanel -is [Windows.Controls.StackPanel] -and $script:controls.AddPlatformCellButton -is [Windows.Controls.Button]) 'Top bar renders segmented TunnelCapsuleBorder with CapsuleSegmentsPanel and AddPlatformCellButton'
    Assert ([Windows.Controls.Grid]::GetColumn($script:controls.ThemeToggleButton.Parent) -eq 0 -and [Windows.Controls.Grid]::GetColumn($script:controls.GlobalSettingsButton.Parent) -eq 0) 'ThemeToggleButton and GlobalSettingsButton are placed in the top-left 2-group icon bar'
    $footerLinksStack = $script:controls.ApiKeysButton.Parent
    Assert ($footerLinksStack.Children.IndexOf($script:controls.ApiKeysButton) -eq 0 -and $footerLinksStack.Children.IndexOf($script:controls.PlatformButton) -eq 1) 'KeyPopoverBorder footer places ApiKeysButton on the left and PlatformButton on the right'
    $script:controls.AddPlatformCellButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Assert ($script:controls.KeyPopoverBorder.Visibility -eq 'Visible' -and $script:controls.AddPlatformPanelBorder.Visibility -eq 'Visible' -and $script:controls.AddPlatformListPanel.Children.Count -eq 3 -and $script:controls.PopoverHeaderTitle.Text -eq '添加平台通道' -and $script:controls.ProfilesListScroll.Visibility -eq 'Collapsed' -and $script:controls.PopoverFooterBorder.Visibility -eq 'Collapsed' -and $script:controls.AddProfileButton.Visibility -eq 'Collapsed') 'Clicking AddPlatformCellButton (+) opens standalone 添加平台通道 panel and hides OpenAI profile list, + 新增配置, and footer bar'
    Invoke-SelectOrAddCapsulePlatform 'claude'
    Assert ($script:activeCapsulePlatform -eq 'claude' -and $script:controls.PopoverHeaderTitle.Text -match '^Claude 隧道配置' -and [string]$script:controls.PlatformButton.Content -eq '网页端 Connectors ↗' -and [string]$script:controls.QuickConnectButton.Content -eq '▶ 启动隧道' -and [string]$script:controls.DisconnectButton.Content -eq '断开隧道' -and $script:controls.CapsuleExtraSegmentsPanel.Children.Count -ge 2) 'Selecting Claude from + panel grows capsule segment and switches KeyPopoverBorder to normalized multi-tunnel popover with ▶ 启动隧道 and 断开隧道'
    Assert ($script:controls.TunnelInputLabel.Text -eq '隧道' -and $script:controls.KeyInputLabel.Text -eq 'Key') 'Expanded edit form normalizes field labels to 隧道 and Key across all platforms'
    $segBtnBeforeExpand = $script:capsuleSegmentButtons['claude']
    $script:window.Content.Measure([Windows.Size]::new(1180, 740))
    $script:window.Content.Arrange([Windows.Rect]::new(0, 0, 1180, 740))
    $script:window.Content.UpdateLayout()
    $collapsedPopH = [double]$script:controls.KeyPopoverBorder.ActualHeight
    Toggle-ProfileInlineEdit 'prof_claude_default'
    $script:window.Content.Measure([Windows.Size]::new(1180, 740))
    $script:window.Content.Arrange([Windows.Rect]::new(0, 0, 1180, 740))
    $script:window.Content.UpdateLayout()
    $expandedPopH = [double]$script:controls.KeyPopoverBorder.ActualHeight
    $segBtnAfterExpand = $script:capsuleSegmentButtons['claude']
    Assert ([object]::ReferenceEquals($segBtnBeforeExpand, $segBtnAfterExpand) -and $expandedPopH -gt ($collapsedPopH + 100) -and $script:controls.PopoverFooterBorder.ActualHeight -gt 20) "Expanding card on Claude/Gemini reuses capsule button instance and expands KeyPopoverBorder height without clipping footer (collapsed=$collapsedPopH, expanded=$expandedPopH)"
    Assert ($script:controls.TunnelInputPlaceholder.Visibility -eq 'Visible' -and $script:controls.KeyInputPlaceholder.Visibility -eq 'Visible' -and $script:controls.KeyInputPlaceholder.Text -match 'relaystudio') 'Empty TunnelInput and KeyInput display muted watermark placeholders with default OAuth Key (relaystudio) hint'
    $firstCardBorder = $script:controls.ProfilesListPanel.Children[0]
    $firstCardSubRow = $firstCardBorder.Child.Children[1]
    $keySepText = ($firstCardSubRow.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] -and $_.Text -match 'Key:' } | Select-Object -First 1).Text
    $copyKeyBtnOnCard = ($firstCardSubRow.Children | Where-Object { $_ -is [Windows.Controls.Button] } | Select-Object -Last 1)
    Assert ($keySepText -match 'Key:\s*relaystudio' -and $copyKeyBtnOnCard.Tag.Val -eq 'relaystudio' -and $copyKeyBtnOnCard.Tag.IsDefaultOAuth -eq $true) "Unconfigured Claude/Gemini card displays default Key: relaystudio and binds one-click copy (actual=$keySepText)"
    $script:controls.TunnelInput.Text = 'https://claude-box.tail9999.ts.net'
    $script:controls.KeyInput.Text = 'cf-token-123456'
    Assert ($script:controls.TunnelInputPlaceholder.Visibility -eq 'Collapsed' -and $script:controls.KeyInputPlaceholder.Visibility -eq 'Collapsed') 'Typing into TunnelInput and KeyInput automatically hides watermark placeholders'
    $script:controls.TunnelInput.Text = ''
    $script:controls.KeyInput.Text = ''
    Assert ($script:controls.TunnelInputPlaceholder.Visibility -eq 'Visible' -and $script:controls.KeyInputPlaceholder.Visibility -eq 'Visible') 'Clearing TunnelInput and KeyInput restores watermark placeholders'
    Toggle-ProfileInlineEdit 'prof_claude_default'
    Start-NewProfileForm
    $secondClaudeProfId = $script:viewingProfileId
    Assert ($script:controls.ProfileNameInput.Text -match '^新隧道配置 #\d+$') "Start-NewProfileForm uses unified 新隧道配置 #N default name across all platforms (actual=$($script:controls.ProfileNameInput.Text))"
    $script:controls.ProfileNameInput.Text = 'Claude备用号'
    $script:controls.TunnelInput.Text = 'https://claude-alt.tail9999.ts.net'
    Save-Form
    Toggle-ProfileInlineEdit 'prof_claude_default'
    Assert ($script:popoverEditMode -and $script:popoverExpandedProfileId -eq 'prof_claude_default') 'Card 1 inline edit form is expanded'
    Select-ProfileCard $secondClaudeProfId
    Assert ((-not $script:popoverEditMode) -and $script:controls.FormScroll.Visibility -eq 'Collapsed' -and $script:controls.ProfileNameInput.Text -eq 'Claude备用号') 'Clicking Card 2 body while Card 1 is expanded automatically collapses Card 1 edit form and syncs Card 2 form fields'
    Select-ProfileCard 'prof_claude_default'
    Assert ([string]$script:controls.QuickConnectButton.Content -eq '▶ 启动隧道') 'Selecting active profile shows ▶ 启动隧道 when tunnel is offline'
    Select-ProfileCard $secondClaudeProfId
    Assert ([string]$script:controls.QuickConnectButton.Content -eq '▶ 启动此隧道') 'Selecting non-active profile on Claude/Gemini shows ▶ 启动此隧道'
    try { [Windows.Clipboard]::SetText('sentinel-clipboard-keep') } catch { }
    Invoke-PopoverQuickConnect
    $claudeSegBtn = $script:capsuleSegmentButtons['claude']
    $claudeSegTxt = ($claudeSegBtn.Content.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] } | Select-Object -First 1).Text
    $clipAfterStart = try { [Windows.Clipboard]::GetText() } catch { 'sentinel-clipboard-keep' }
    Assert ($script:profilesState.ActiveProfileByPlatform['claude'] -eq $secondClaudeProfId -and $claudeSegTxt -eq 'Claude · Claude备用号 ▾' -and [string]$script:controls.QuickConnectButton.Content -eq '↻ 重新连接' -and $clipAfterStart -eq 'sentinel-clipboard-keep') "Clicking ▶ 启动此隧道 on Claude switches active profile, updates top capsule text ($claudeSegTxt), starts tunnel without overwriting clipboard"
    Stop-PublicMcpTunnel $script:context
    Refresh-ProfilePopoverState
    $script:controls.DismissKeyPopoverButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Assert ($script:controls.KeyPopoverBorder.Visibility -eq 'Collapsed' -and (-not $script:popoverOpen)) 'Clicking top-right × DismissKeyPopoverButton closes non-OpenAI popover'
    Select-CapsulePlatform 'claude'
    Assert ($script:controls.KeyPopoverBorder.Visibility -eq 'Visible') 'Clicking Claude segment opens Claude popover'
    Select-CapsulePlatform 'claude'
    Assert ($script:controls.KeyPopoverBorder.Visibility -eq 'Collapsed' -and (-not $script:popoverOpen)) 'Clicking active Claude segment a second time toggles popover closed'
    Select-CapsulePlatform 'claude'
    Invoke-RemoveCurrentCapsulePlatform
    Assert ($script:activeCapsulePlatform -in @('chatgpt', 'openai') -and $script:controls.PopoverHeaderTitle.Text -match '^(ChatGPT|OpenAI) 隧道配置 \(\d+\)$' -and [string]$script:controls.PlatformButton.Content -eq '打开 OpenAI 隧道设置 ↗') 'Removing non-ChatGPT capsule platform restores ChatGPT/OpenAI tunnel config card'
    Close-AllTopPopovers



    $clearRes = Invoke-PurgeAllArchivedSessions -Context $pulseContext -ArchivedSessions @('tsk_arch_1', 'tsk_arch_2')

    Assert ($clearRes.ClearedCount -ge 2) 'Invoke-PurgeAllArchivedSessions purges all archived items without soft deleted state'



    # Verify Architecture Redesign Slice 3:

    # 1. Manual Archive stays archived without timestamp-based auto-revive when updated_at > archived_at

    $reviveTaskId = 'tsk_revive_test01'

    $reviveOldIso = [DateTimeOffset]::UtcNow.AddMinutes(-15).ToString('o')

    [IO.File]::WriteAllText((Join-Path $pulseContext.TasksRoot "$reviveTaskId.json"), (@{

        schema_version = 1; id = $reviveTaskId; title = '归档不自动复活验证任务'; status = 'active'

        created_at = $reviveOldIso; updated_at = $reviveOldIso

        steps = @(@{ id = '1'; title = '步骤一'; status = 'in_progress'; updated_at = $reviveOldIso })

        summary = '等待唤醒'

    } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

    Set-TaskArchiveState -Context $pulseContext -TaskId $reviveTaskId -State 'archived'

    $archPulse1 = Get-TunnelActivityPulse $pulseContext $true

    Assert (@($archPulse1.ArchivedSessions | Where-Object { $_.SessionKey -eq $reviveTaskId }).Count -eq 1) 'Archived task appears in ArchivedSessions before new activity'

    Start-Sleep -Milliseconds 30

    $reviveNewIso = [DateTimeOffset]::UtcNow.AddSeconds(2).ToString('o')

    [IO.File]::WriteAllText((Join-Path $pulseContext.TasksRoot "$reviveTaskId.json"), (@{

        schema_version = 1; id = $reviveTaskId; title = '归档不自动复活验证任务'; status = 'active'

        created_at = $reviveOldIso; updated_at = $reviveNewIso

        steps = @(@{ id = '1'; title = '步骤一'; status = 'in_progress'; updated_at = $reviveNewIso })

        summary = '收到新进展不自动复活'

    } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

    $revivedPulse = Get-TunnelActivityPulse $pulseContext $true

    Assert (@($revivedPulse.ArchivedSessions | Where-Object { $_.SessionKey -eq $reviveTaskId }).Count -eq 1 -and @($revivedPulse.Sessions | Where-Object { $_.SessionKey -eq $reviveTaskId }).Count -eq 0) 'Archived task stays in ArchivedSessions without timestamp-based auto-revive when updated_at > archived_at'



    # 2. Physical Purge (Invoke-PurgeArchivedSession / Remove-ArchivedTaskSession) deletes tsk_*.json, updates task-registry.json, enqueues cloud delete, and Confirm-PurgeArchivedDialog guards UI deletion without UndoDeleteBorder

    [void](Set-SessionBridgeBinding -Context $pulseContext -SessionKey $reviveTaskId -ConvUuid 'dddd4444-4444-4444-8444-444444444444' -BrowserProfile 'Chrome:Profile 1')

    $purgeRes = Invoke-PurgeArchivedSession -Context $pulseContext -SessionKey $reviveTaskId

    $wbAfterPurge = Get-WebBridgeState $pulseContext

    $cloudDelAct = @($wbAfterPurge.retire_actions | Where-Object { $_.conv_uuid -eq 'dddd4444-4444-4444-8444-444444444444' -and $_.operation -eq 'delete' }) | Select-Object -Last 1

    $regAfterPurge = Get-Content -LiteralPath (Join-Path $pulseContext.DataRoot 'task-registry.json') -Raw -Encoding UTF8 | ConvertFrom-Json

    $archStateAfterPurge = Get-TaskArchiveOverrides $pulseContext

    Assert ($purgeRes.PurgedTaskFile -eq $true -and -not (Test-Path -LiteralPath (Join-Path $pulseContext.TasksRoot "$reviveTaskId.json")) -and ($null -eq $regAfterPurge.tasks.PSObject.Properties[$reviveTaskId]) -and (-not $archStateAfterPurge.ContainsKey($reviveTaskId)) -and $null -ne $cloudDelAct) 'Invoke-PurgeArchivedSession physically deletes tsk_*.json, removes from task-registry.json and task-archives.json (zero soft deleted state), and enqueues cloud delete'

    Assert ($xaml.OuterXml -match '展示手动归档与已完工自动归档的任务（还原将同步恢复主会话，彻底删除将同时清除本机账本与云端对话）') 'ArchiveDrawerOverlay displays updated subtitle/footer text for manual and completed-auto archive and cloud+local purge'

    $uiArchTaskId = 'tsk_ui_purge_confirm_01'
    $script:context.TasksRoot = Join-Path $script:context.DataRoot 'tasks'
    [IO.Directory]::CreateDirectory($script:context.TasksRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:context.TasksRoot "$uiArchTaskId.json"), (@{
        schema_version = 1; id = $uiArchTaskId; title = 'UI确认弹窗删除测试'; status = 'active'
        created_at = $reviveOldIso; updated_at = $reviveOldIso; steps = @(); summary = ''
    } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    Invoke-ArchiveSession $uiArchTaskId
    Assert ($script:controls.UndoDeleteBorder.Visibility -eq 'Collapsed' -and $script:controls.QuickToastText.Text -match '已归档.*并同步归档云端会话') 'Invoke-ArchiveSession keeps UndoDeleteBorder collapsed and shows clean archive toast'
    $script:PurgeConfirmOverride = { param($t, $b, $c) return $false }
    [void](Invoke-DeleteSession $uiArchTaskId 'UI确认弹窗删除测试' -PhysicalPurge)
    Assert ((Test-Path -LiteralPath (Join-Path $script:context.TasksRoot "$uiArchTaskId.json"))) 'Cancelling Confirm-PurgeArchivedDialog preserves tsk_*.json file'
    $script:PurgeConfirmOverride = { param($t, $b, $c) return $true }
    [void](Invoke-DeleteSession $uiArchTaskId 'UI确认弹窗删除测试' -PhysicalPurge)
    $script:PurgeConfirmOverride = $null
    Assert ((-not (Test-Path -LiteralPath (Join-Path $script:context.TasksRoot "$uiArchTaskId.json"))) -and $script:controls.UndoDeleteBorder.Visibility -eq 'Collapsed') 'Confirming Confirm-PurgeArchivedDialog physically deletes tsk_*.json without showing UndoDeleteBorder'



    # 3. Session Binding Equivalence: project_prefix + retired_uuids anti-ping-pong + browser switch (M3)

    $bindRes1 = Set-SessionBridgeBinding -Context $pulseContext -SessionKey 'tsk_19283093310b828b' -ConvUuid 'aaaa1111-1111-4111-8111-111111111111' -ProjectPrefix 'https://chatgpt.com/g/g-p-69be4f3b62d881919c8fb3cd3eb0fb36' -BrowserProfile 'Chrome:Profile 1'

    Assert ($bindRes1.conv_uuid -eq 'aaaa1111-1111-4111-8111-111111111111' -and $bindRes1.project_prefix -eq 'https://chatgpt.com/g/g-p-69be4f3b62d881919c8fb3cd3eb0fb36') 'Set-SessionBridgeBinding persists conv_uuid and project_prefix'

    $openProjRes = Open-SessionWebPage -Context $pulseContext -Session $multiPulse.Sessions[0] -NoLaunchBrowser

    Assert ($openProjRes.Url -eq 'https://chatgpt.com/g/g-p-69be4f3b62d881919c8fb3cd3eb0fb36/c/aaaa1111-1111-4111-8111-111111111111') 'Open-SessionWebPage preserves ChatGPT Project Folder prefix (/g/g-p-...)'

    $bindRes2 = Set-SessionBridgeBinding -Context $pulseContext -SessionKey 'tsk_19283093310b828b' -BrowserProfile 'Edge:Profile 1'

    Assert ($bindRes2.conv_uuid -eq '' -and $bindRes2.browser_profile -eq 'Edge:Profile 1' -and ($bindRes2.retired_uuids -contains 'aaaa1111-1111-4111-8111-111111111111')) 'Switching BrowserProfile retires old conv_uuid and clears active conv_uuid for new browser handover'



    # 4. Same-Workspace Un-tasked Session Isolation when existing task is bound to another conv_uuid (M2)

    [void](Set-SessionBridgeBinding -Context $pulseContext -SessionKey 'tsk_19283093310b828b' -ConvUuid '11111111-1111-4111-8111-111111111111' -BrowserProfile 'Chrome:Profile 1')

    $isoNow = [DateTimeOffset]::UtcNow.ToString('o')

    $sameWsShield = @{

        schema_version = 1

        calls = @{

            'rpc-new-ws-1' = @{ rpc_id = 'rpc-new-ws-1'; tool = 'fs_read'; action = '读取文件 (README.md)'; workspace_hint = 'project_alpha'; time = $isoNow }

        }

        zero_rpc_events = @()

    } | ConvertTo-Json -Depth 5

    [IO.File]::WriteAllText((Join-Path (Join-Path $pulseContext.DataRoot 'logs') 'shield-activity.json'), $sameWsShield, (New-Object Text.UTF8Encoding($false)))

    $sameWsLog = @(

        ('{"time":"' + $isoNow + '","level":"INFO","msg":"dispatcher forwarded command to MCP server","cmd_request_id":"wfr_01a1735d3994733c87ad836e7898a160","rpc_request_id":"bbbbbbbb-2222-4222-8222-222222222222"}'),

        ('{"time":"' + $isoNow + '","level":"INFO","msg":"dispatcher forwarded command to MCP server","cmd_request_id":"22222222-2222-4222-8222-222222222222/abcd","rpc_request_id":"rpc-new-ws-1"}'),

        ('{"time":"' + $isoNow + '","level":"INFO","msg":"dispatcher forwarded command to MCP server","cmd_request_id":"22222222-2222-4222-8222-222222222222/efgh","rpc_request_id":"rpc-new-ws-1"}')

    ) -join "`r`n"

    [IO.File]::WriteAllText((Join-Path (Join-Path $pulseContext.DataRoot 'logs') 'tunnel.out.log'), ($sameWsLog + "`r`n"), (New-Object Text.UTF8Encoding($false)))

    $sameWsPulse = Get-TunnelActivityPulse $pulseContext $true

    Assert (@($sameWsPulse.Sessions | Where-Object { $_.SessionKey -eq '22222222-2222-4222-8222-222222222222' }).Count -eq 0 -and $sameWsPulse.Sessions.Count -eq 1) 'Task-Only Contract: un-tasked conversation in same workspace does not spawn an un-tasked card'



    # 5. Split-screen Unfocused Live Refresh check (U1/U2)

    Assert ((Test-ShouldRunUiRefreshTimer -IsVisible $true -WindowState ([Windows.WindowState]::Normal) -IsActive $false) -eq $true) 'UI refresh timer stays active in split-screen mode even when window is unfocused (IsActive=false)'

    Assert ((Test-ShouldRunUiRefreshTimer -IsVisible $true -WindowState ([Windows.WindowState]::Minimized) -IsActive $false) -eq $false) 'UI refresh timer stops when window is minimized'



    # 5b. Verify Spec v3.0/v3.1/v3.2: Per-Task Independent Composer Config, Dynamic AvailableModels & Effort Linkage, 3-Tier Anti-Disturbance Guards, Cross-Browser Auto-Handover, 4-State Payload, Single Latest Blue Box + SentHistoryModal, Top Bar Pill, and 0-Task Ready Hub
    $cfgTaskA = Set-TaskComposerConfig -Context $pulseContext -SessionKey 'tsk_19283093310b828b' -TargetMode 'follow_window' -BrowserProfile 'Chrome:Profile 1' -TargetModel 'gpt-6-pro' -ReasoningEffort '深度' -AutoResendEnabled $true -StallMinutes 3 -MaxRetries 1
    $cfgTaskB = Set-TaskComposerConfig -Context $pulseContext -SessionKey 'tsk_other_task_02' -TargetMode 'new_window' -BrowserProfile 'Edge:Profile 1' -TargetModel 'gpt-6-thinking' -ReasoningEffort '最高' -AutoResendEnabled $false -StallMinutes 5 -MaxRetries 2
    Assert ($cfgTaskA.binding.browser_profile -eq 'Chrome:Profile 1' -and $cfgTaskA.binding.user_locked_browser -eq $true -and $cfgTaskA.binding.target_model -eq 'gpt-6-pro' -and $cfgTaskA.binding.reasoning_effort -eq '深度') 'Set-TaskComposerConfig persists Task A independent browser, model, effort, and user_locked_browser=true'
    $wbAfterAB = Get-WebBridgeState $pulseContext
    $reboundA = $wbAfterAB.session_bindings.'tsk_19283093310b828b'
    $reboundB = $wbAfterAB.session_bindings.'tsk_other_task_02'
    Assert ($reboundA.browser_profile -eq 'Chrome:Profile 1' -and $reboundB.browser_profile -eq 'Edge:Profile 1' -and $reboundA.target_mode -eq 'follow_window' -and $reboundB.target_mode -eq 'new_window') 'Task A and Task B configurations are stored independently in session_bindings without cross-task mutation'

    # Bind a conv_uuid to Task A in Chrome, then switch Task A to Edge via Set-TaskComposerConfig -> verify retired_uuids and auto-upgrade on next send
    [void](Set-SessionBridgeBinding -Context $pulseContext -SessionKey 'tsk_19283093310b828b' -ConvUuid 'cccc3333-3333-4333-8333-333333333333' -BrowserProfile 'Chrome:Profile 1')
    $switchEdgeRes = Set-TaskComposerConfig -Context $pulseContext -SessionKey 'tsk_19283093310b828b' -BrowserProfile 'Edge:Profile 1'
    Assert ($switchEdgeRes.binding.conv_uuid -eq '' -and ($switchEdgeRes.binding.retired_uuids -contains 'cccc3333-3333-4333-8333-333333333333')) 'Switching Task A from Chrome to Edge via Set-TaskComposerConfig retires old conv_uuid and clears conv_uuid without immediate popup'
    $autoUpgradeSend = Send-WebBridgeMessage -Context $pulseContext -Session $multiPulse.Sessions[0] -Mode 'follow_window' -CustomUserText ''
    Assert ($autoUpgradeSend.Mode -eq 'new_window_handover' -and $autoUpgradeSend.Prompt -match 'tsk_19283093310b828b' -and $autoUpgradeSend.HandoverUrl -match 'model=gpt-6-pro') 'First send after Chrome->Edge switch automatically upgrades follow_window to new_window_handover with progress ledger and dynamic model slug'

    # Re-bind conv_uuid in Edge and test 4-state payload matrix
    [void](Set-SessionBridgeBinding -Context $pulseContext -SessionKey 'tsk_19283093310b828b' -ConvUuid 'eeee5555-5555-4555-8555-555555555555' -BrowserProfile 'Edge:Profile 1' -TargetMode 'follow_window')
    $wbVerifyTab = Get-WebBridgeState $pulseContext
    $wbVerifyTab.tabs | Add-Member -NotePropertyName 'tab_edge_5555' -NotePropertyValue ([pscustomobject]@{ tab_id = 'tab_edge_5555'; conv_uuid = 'eeee5555-5555-4555-8555-555555555555'; url = 'https://chatgpt.com/c/eeee5555-5555-4555-8555-555555555555'; title = 'Alma'; current_model = 'GPT-6 Pro'; current_effort = '深度'; page_hints = @('tsk_19283093310b828b'); last_seen_at = [DateTimeOffset]::UtcNow.ToString('o') }) -Force
    Save-WebBridgeState $pulseContext $wbVerifyTab
    $sendFollowEmpty = Send-WebBridgeMessage -Context $pulseContext -Session $multiPulse.Sessions[0] -Mode 'follow_window' -CustomUserText ''
    Assert ($sendFollowEmpty.Mode -eq 'follow_window' -and $sendFollowEmpty.Prompt -eq '请继续') 'follow_window + empty text sends exact 请继续'
    $sendFollowCustom = Send-WebBridgeMessage -Context $pulseContext -Session $multiPulse.Sessions[0] -Mode 'follow_window' -CustomUserText '请优先检查第 4 步边界条件'
    Assert ($sendFollowCustom.Mode -eq 'follow_window' -and $sendFollowCustom.Prompt -eq '请优先检查第 4 步边界条件') 'follow_window + custom text sends raw custom text'
    $sendHandoverCustom = Send-WebBridgeMessage -Context $pulseContext -Session $multiPulse.Sessions[0] -Mode 'new_window_handover' -CustomUserText '请用 GPT-6 Pro 完成收尾'
    Assert ($sendHandoverCustom.Mode -eq 'new_window_handover' -and $sendHandoverCustom.Prompt -match '【用户追加指令】' -and $sendHandoverCustom.Prompt -match '请用 GPT-6 Pro 完成收尾') 'new_window_handover + custom text appends user instruction to handover ledger'

    # Verify UI components: TopHeartbeatPillBorder (no AppTopBreadcrumbText), SentHistoryOverlay, Plan B Composer Pod, Draft Persistence, and 0-Task Ready Hub
    Assert ($null -ne $script:controls.TopHeartbeatPillBorder -and $null -ne $script:controls.TopHeartbeatText -and $null -eq $script:controls.AppTopBreadcrumbText) 'Top title bar retains only RelayStudio + two pills and removes Chinese subtitle'
    $uiScriptRaw = [IO.File]::ReadAllText((Join-Path $managerRoot '连接管理.ps1'), [Text.Encoding]::UTF8)
    $psm1ScriptRaw = [IO.File]::ReadAllText((Join-Path $managerRoot 'ConnectionManager.psm1'), [Text.Encoding]::UTF8)
    $shieldPyRaw = [IO.File]::ReadAllText((Join-Path $managerRoot 'McpReadOnlyShield.py'), [Text.Encoding]::UTF8)
    Assert ($uiScriptRaw -notmatch 'payload_mode' -and $psm1ScriptRaw -notmatch 'payload_mode' -and $shieldPyRaw -notmatch 'payload_mode') 'payload_mode is completely removed across UI, PowerShell module, and Python Hub'
    Assert ($uiScriptRaw -notmatch '携带进度发“继续”' -and $uiScriptRaw -notmatch '/ 智能体接力与多栏工作台') 'Obsolete payload dropdown and Chinese subtitle text are completely removed from 连接管理.ps1'
    Assert ($uiScriptRaw -notmatch 'GPT-5\.4' -and $psm1ScriptRaw -notmatch 'GPT-5\.4' -and $shieldPyRaw -notmatch 'GPT-5\.4' -and $psm1ScriptRaw -notmatch 'Step-SessionCircuitBreaker') 'Spec v3.2: Zero hardcoded GPT-5.4 strings or dead Step-SessionCircuitBreaker across PowerShell and Python production files'

    # Verify Dynamic Model Catalog & Effort Linkage + CatalogSig Anti-Disturbance Guard (Spec v3.2 Mechanism 1 & 3)
    $dynModelsTest = @(
        [pscustomobject]@{ slug = 'gpt-6-thinking'; title = 'GPT-6 Thinking'; efforts = @('light', 'standard', 'extended', 'max') },
        [pscustomobject]@{ slug = 'gpt-6-pro'; title = 'GPT-6 Pro'; efforts = @('standard', 'max') },
        [pscustomobject]@{ slug = 'gpt-6-fast'; title = 'GPT-6 Fast'; efforts = @() }
    )
    $multiPulse.Sessions[0] | Add-Member -NotePropertyName 'AvailableModels' -NotePropertyValue $dynModelsTest -Force
    $multiPulse.Sessions[0] | Add-Member -NotePropertyName 'WebCurrentModel' -NotePropertyValue 'GPT-6 Thinking' -Force
    $multiPulse.Sessions[0] | Add-Member -NotePropertyName 'WebCurrentEffort' -NotePropertyValue 'extended' -Force
    $multiPulse.Sessions[0] | Add-Member -NotePropertyName 'TargetModel' -NotePropertyValue 'gpt-6-pro' -Force
    $multiPulse.Sessions[0] | Add-Member -NotePropertyName 'ReasoningEffort' -NotePropertyValue 'max' -Force
    $multiPulse.Sessions[0] | Add-Member -NotePropertyName 'StallMinutes' -NotePropertyValue 5 -Force
    $multiPulse.Sessions[0] | Add-Member -NotePropertyName 'MaxRetries' -NotePropertyValue 2 -Force
    $multiPulse.Sessions[0] | Add-Member -NotePropertyName 'AutoResendEnabled' -NotePropertyValue $true -Force
    $multiPulse.Sessions[0] | Add-Member -NotePropertyName 'AutoWakeupEnabled' -NotePropertyValue $true -Force
    $script:composerPodCache = @{}

    $podA = Build-PlanBComposerPod -SessionObj $multiPulse.Sessions[0] -IsNarrow $false -IsZeroTask $false
    $modelTagsA = @($podA.Tag.ModelCombo.Items | ForEach-Object { [string]$_.Tag })
    $effortTagsA = @($podA.Tag.EffortCombo.Items | ForEach-Object { [string]$_.Tag })
    Assert (($modelTagsA -contains 'inherit') -and ($modelTagsA -contains 'gpt-6-thinking') -and ($modelTagsA -contains 'gpt-6-pro') -and ($modelTagsA -contains 'gpt-6-fast') -and $podA.Tag.ModelCombo.Items[0].Content -eq '🤖 默认 (GPT-6 Thinking)') 'Build-PlanBComposerPod dynamically populates ModelCombo from AvailableModels and shows WebCurrentModel in inherit option'
    Assert (($effortTagsA -contains 'standard') -and ($effortTagsA -contains 'max') -and ($effortTagsA -notcontains 'light') -and ($effortTagsA -notcontains 'min')) 'EffortCombo options dynamically link to selected model in raw English IDs (gpt-6-pro -> standard/max only)'
    $firstModelItemRef = $podA.Tag.ModelCombo.Items[0]

    # Changing to a model that does not support the old effort must reset to inherit.
    $effortLinkageProbe = [pscustomobject]@{
        ModelCombo = [Windows.Controls.ComboBox]::new()
        EffortCombo = [Windows.Controls.ComboBox]::new()
        LastCatalogSig = ''
        AvailableModels = @()
    }
    Sync-ComposerModelAndEffortCombos -StateInfo $effortLinkageProbe -AvailModels $dynModelsTest -CurModel 'gpt-6-thinking' -WebModel 'GPT-6 Thinking' -CurEffort '轻度' -WebEffort '轻度'
    Sync-ComposerModelAndEffortCombos -StateInfo $effortLinkageProbe -AvailModels $dynModelsTest -CurModel 'gpt-6-pro' -WebModel 'GPT-6 Thinking' -CurEffort '轻度' -WebEffort '轻度'
    $linkedEfforts = @($effortLinkageProbe.EffortCombo.Items | ForEach-Object { [string]$_.Tag })
    Assert (($linkedEfforts -notcontains 'light') -and ($linkedEfforts -notcontains 'min') -and ([string]$effortLinkageProbe.EffortCombo.SelectedItem.Tag -eq 'inherit')) 'Model switch removes unsupported effort instead of keeping an invalid selected option'

    # Verify empty efforts model (gpt-6-fast -> efforts: []) renders only '🧠 默认 (当前模型固定)'
    Sync-ComposerModelAndEffortCombos -StateInfo $podA.Tag -AvailModels $dynModelsTest -CurModel 'gpt-6-fast' -WebModel 'GPT-6 Thinking' -CurEffort '标准' -WebEffort '深度'
    Assert ($podA.Tag.EffortCombo.Items.Count -eq 1 -and [string]$podA.Tag.EffortCombo.Items[0].Content -eq '🧠 默认 (当前模型固定)') 'Model with empty efforts array (gpt-6-fast) renders single fixed EffortCombo item (🧠 默认 (当前模型固定))'

    # Regression Bug 2: When /backend-api/models returns reasoning models (gpt-6, gpt-6-thinking) with empty efforts=@() and duplicate titles ('GPT-6'), disambiguate titles and populate 4 reasoning efforts
    $openAiRealCatalog = @(
        [pscustomobject]@{ slug = 'gpt-6'; title = 'GPT-6'; efforts = @() },
        [pscustomobject]@{ slug = 'gpt-6-thinking'; title = 'GPT-6'; efforts = @() },
        [pscustomobject]@{ slug = 'gpt-6-instant'; title = 'GPT-6'; efforts = @() }
    )
    Sync-ComposerModelAndEffortCombos -StateInfo $podA.Tag -AvailModels $openAiRealCatalog -CurModel 'gpt-6' -WebModel 'GPT-6' -CurEffort '深度' -WebEffort '思考强度 标准'
    $realModelLabels = @($podA.Tag.ModelCombo.Items | ForEach-Object { [string]$_.Content })
    $realEffortTags = @($podA.Tag.EffortCombo.Items | ForEach-Object { [string]$_.Tag })
    Assert (($realModelLabels -contains '🤖 GPT-6 (gpt-6-thinking)') -and ($realEffortTags -contains 'min') -and ($realEffortTags -contains 'standard') -and ($realEffortTags -contains 'extended') -and ($realEffortTags -contains 'max') -and ([string]$podA.Tag.EffortCombo.Items[0].Content -eq '🧠 默认 (standard)')) 'Reasoning models with empty efforts array in /backend-api/models still populate 4 raw English effort IDs, normalize WebEffort, and disambiguate duplicate model titles'

    # Spec v4.0: Verify Desktop:ChatGPT target in Get-AvailableBrowserProfiles, model labels with English slug, 未开启思考 initial display, and model<->effort auto-switching
    $availProfilesV4 = @(Get-AvailableBrowserProfiles)
    Assert (@($availProfilesV4 | Where-Object { $_.Id -eq 'Desktop:ChatGPT' -and $_.Label -eq 'ChatGPT 桌面端' }).Count -eq 1) 'Spec v4.0: Get-AvailableBrowserProfiles includes Desktop:ChatGPT with clean label ChatGPT 桌面端'
    Sync-ComposerModelAndEffortCombos -StateInfo $podA.Tag -AvailModels $dynModelsTest -CurModel 'inherit' -WebModel 'gpt-6' -CurEffort 'inherit' -WebEffort 'none'
    $v4ModelLabels = @($podA.Tag.ModelCombo.Items | ForEach-Object { [string]$_.Content })
    Assert (($v4ModelLabels -contains '🤖 GPT-6 Pro (gpt-6-pro)') -and ([string]$podA.Tag.EffortCombo.Items[0].Content -eq '🧠 默认 (none)')) 'Spec v4.0 + Scheme A: ModelCombo always includes English slug in parens and EffortCombo shows raw English none when WebEffort is none'
    $v4LinkRes = Set-TaskComposerConfig -Context $pulseContext -SessionKey 'tsk_19283093310b828b' -TargetModel 'gpt-6' -ReasoningEffort 'extended'
    Assert ($v4LinkRes.binding.target_model -eq 'gpt-6-thinking' -and $v4LinkRes.binding.reasoning_effort -eq 'extended') 'Spec v4.0 + Scheme A: Selecting a raw English thinking effort on gpt-6 auto-switches target_model to gpt-6-thinking'
    $v4InstantRes = Set-TaskComposerConfig -Context $pulseContext -SessionKey 'tsk_19283093310b828b' -ReasoningEffort 'none'
    Assert ($v4InstantRes.binding.target_model -eq 'gpt-6-instant' -and $v4InstantRes.binding.reasoning_effort -eq 'none') 'Spec v4.0 + Scheme A: Selecting none effort on gpt-6-thinking auto-switches target_model to gpt-6-instant'

    # Regression Bug 1: Clicking AutoResendCheck on a PSCustomObject session lacking AutoResendEnabled property never throws PropertyAssignmentException
    $legacySnapSess = [pscustomobject]@{
        SessionKey = 'tsk_legacy_prop_test'
        Title = '缺少AutoResendEnabled属性测试'
        AutoWakeupEnabled = $false
        StallMinutes = 3
        MaxRetries = 1
        TargetMode = 'follow_window'
        TargetModel = 'inherit'
        ReasoningEffort = 'inherit'
        BrowserProfile = 'Chrome:Profile 1'
    }
    $podLegacy = Build-PlanBComposerPod -SessionObj $legacySnapSess -IsNarrow $false -IsZeroTask $false
    $podLegacy.Tag.AutoResendChk.IsChecked = $true
    Assert ($legacySnapSess.AutoResendEnabled -eq $true -and $legacySnapSess.AutoWakeupEnabled -eq $true) 'Clicking AutoResendCheck safely attaches AutoResendEnabled via Set-SessionPropSafe without crashing'

    # Restore gpt-6-pro selection for subsequent cache identity check
    Sync-ComposerModelAndEffortCombos -StateInfo $podA.Tag -AvailModels $dynModelsTest -CurModel 'gpt-6-pro' -WebModel 'GPT-6 Thinking' -CurEffort 'max' -WebEffort 'extended'
    $firstModelItemRef = $podA.Tag.ModelCombo.Items[0]

    $podA.Tag.InputBox.Text = '任务 A 真实输入草稿'
    $podB = Build-PlanBComposerPod -SessionObj ([pscustomobject]@{ SessionKey = 'tsk_other_task_02'; Title = '任务 B' }) -IsNarrow $false -IsZeroTask $false
    $podB.Tag.InputBox.Text = '任务 B 独立的草稿文字'
    $podA2 = Build-PlanBComposerPod -SessionObj $multiPulse.Sessions[0] -IsNarrow $false -IsZeroTask $false
    Assert ([object]::ReferenceEquals($podA, $podA2) -and [object]::ReferenceEquals($firstModelItemRef, $podA2.Tag.ModelCombo.Items[0]) -and $podA2.Name -eq 'ComposerPodHost' -and $podA2.Tag.InputBox.Text -eq '任务 A 真实输入草稿' -and (Get-TaskDraftState 'tsk_other_task_02').DraftText -eq '任务 B 独立的草稿文字') 'Build-PlanBComposerPod reuses cached ComposerPodHost AND LastCatalogSig guard prevents rebuilding ComboBox.Items on 2s heartbeat'
    $podA.Tag.InputBox.Text = ''; $podB.Tag.InputBox.Text = ''

    # Verify Cleanup 3: Build-PaneStreamContent top status capsule reads per-task StallMinutes=5 instead of global autoCfg
    $streamContainerTest = Build-PaneStreamContent -PaneObj $script:layout.Panes[0] -SessionObj $multiPulse.Sessions[0] -IsNarrow $false
    $statusPillTxtObj = $streamContainerTest.Children[0].Children[0].Content.Children[1].Children[1].Child.Children[1]
    Assert ($statusPillTxtObj.Text -match '>5分钟静默触发') "Top status capsule in Build-PaneStreamContent displays per-task StallMinutes (5m) instead of global autoCfg (actual: $($statusPillTxtObj.Text))"

    $mockSessionWithMsgs = $multiPulse.Sessions[0]
    $mockSessionWithMsgs | Add-Member -NotePropertyName 'SentWebMessages' -NotePropertyValue @(
        [pscustomobject]@{ TimeText = '10-29 14:20:00'; Text = '最新一条发送记录'; Prompt = '最新一条完整内容'; Status = 'delivered'; Mode = 'follow_window' },
        [pscustomobject]@{ TimeText = '10-29 14:10:00'; Text = '历史第一条发送记录'; Prompt = '历史第一条完整内容'; Status = 'delivered'; Mode = 'new_window_handover' }
    ) -Force
    Open-SentHistoryModal $mockSessionWithMsgs
    Assert ($script:controls.SentHistoryOverlay.Visibility -eq 'Visible' -and $script:controls.SentHistoryListPanel.Children.Count -eq 2) 'Open-SentHistoryModal displays all historical sent messages in modal overlay'
    Close-SentHistoryModal
    Assert ($script:controls.SentHistoryOverlay.Visibility -eq 'Collapsed') 'Close-SentHistoryModal hides sent history modal overlay'

    $prevSessionsBackup = $script:display.Sessions
    $script:display.Sessions = @()
    $zeroHubElem = Build-PaneTaskPicker $script:layout.Panes[0]
    $zeroPodElem = $zeroHubElem.Children[1]
    $zeroSendRes = Send-WebBridgeMessage -Context $pulseContext -Session $null -Mode 'new_window_handover' -CustomUserText '请初始化新工单并创建 task_manage'
    Assert ($zeroHubElem -is [Windows.Controls.Grid] -and $zeroHubElem.RowDefinitions.Count -eq 2 -and $zeroHubElem.Children[0].Name -eq 'StreamScrollHost' -and $zeroPodElem.Name -eq 'ComposerPodHost' -and $zeroPodElem.Tag.SendLabel.Text -eq '🚀 在网页发起新任务 ↗' -and $zeroSendRes.SessionKey -eq '__new_task__') 'Build-PaneTaskPicker renders 2-row 0-Task Ready Hub with StreamScrollHost + ComposerPodHost (🚀 在网页发起新任务 ↗) and queues __new_task__'
    Assert ($zeroPodElem.Tag.SegGroup.Visibility -eq 'Collapsed' -and $zeroPodElem.Tag.ZeroFooterHost.Visibility -eq 'Collapsed') 'New Task screen hides the [跟随原窗口 | 新建网页交接] segmented toggle and collapses ZeroFooterHost when archived count is 0'
    $script:display.Sessions = $prevSessionsBackup

    # 5b. Spec v4.1 NewTaskLaunchpadUI: compact ＋ button replaces "每 2 秒同步"; launchpad reachable at any time
    Assert ($script:controls.NewTaskRailButton -is [Windows.Controls.Button] -and $xaml.OuterXml -notmatch '每 2 秒同步') 'Left rail header replaces the 每 2 秒同步 hint with the compact ＋ NewTaskRailButton'
    $script:display.Sessions = @($multiPulse.Sessions)
    Assert (@($script:display.Sessions).Count -ge 1) 'precondition: at least one active task exists for launchpad checks'
    $lpPaneId = [int]$script:layout.Panes[0].id
    $script:controls.NewTaskRailButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    $lpHub = Build-PaneTaskPicker $script:layout.Panes[0]
    Assert ($script:launchpadPaneIds.ContainsKey($lpPaneId) -and [string]$script:layout.Panes[0].session_key -eq '' -and $lpHub -is [Windows.Controls.Grid] -and $lpHub.Children[1].Name -eq 'ComposerPodHost' -and $lpHub.Children[1].Tag.IsZeroTask -eq $true) 'Clicking the rail ＋ button turns the pane into the new-task launchpad even when tasks exist'
    Render-PanesWorkspace
    Assert ([string]$script:layout.Panes[0].session_key -eq '' -and $script:launchpadPaneIds.ContainsKey($lpPaneId)) 'Render-PanesWorkspace keeps the launchpad pane instead of auto-assigning the first active task'
    Switch-PaneToPicker $lpPaneId
    $pickerList = Build-PaneTaskPicker $script:layout.Panes[0]
    $newTaskPickerBtn = @($pickerList.Content.Children | Where-Object { $_ -is [Windows.Controls.Button] -and [string]$_.Content -like '*新建任务*' }) | Select-Object -First 1
    Assert (-not $script:launchpadPaneIds.ContainsKey($lpPaneId) -and $pickerList -is [Windows.Controls.ScrollViewer] -and $newTaskPickerBtn) 'Task picker offers a 在此分栏发起新任务 shortcut when tasks exist'
    $newTaskPickerBtn.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Assert ($script:launchpadPaneIds.ContainsKey($lpPaneId)) 'Picker shortcut enters the launchpad for that pane'
    Assign-TaskToPane $lpPaneId $script:display.Sessions[0].SessionKey
    Assert (-not $script:launchpadPaneIds.ContainsKey($lpPaneId) -and $script:layout.Panes[0].session_key -eq $script:display.Sessions[0].SessionKey) 'Assigning a task to the pane leaves launchpad mode'
    $script:display.Sessions = $prevSessionsBackup
    Assert ((Get-Command Send-WebBridgeMessage).Parameters.ContainsKey('IsSinglePaneReplace')) 'Send-WebBridgeMessage forwards the single-pane replace policy (Q4)'
    $handoverAst = (Get-Command Open-BridgeHandoverWindow).ScriptBlock.Ast
    $desktopIf = $handoverAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match "\^Desktop:" }, $true) | Select-Object -First 1
    $desktopCalls = @($desktopIf.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-ChatGptDesktopApp' }, $true))
    Assert ($desktopCalls.Count -eq 1 -and $desktopIf.Extent.Text -notmatch 'chrome\.exe') 'A closed ChatGPT Desktop is cold-started by Open-BridgeHandoverWindow and never replaced by Chrome'

    # 5c. Spec v4.2 WPF & ConnectionManager Seam Tests (30s tier, full param passthrough, FIFO pending queue controls, 4-stage status, LIVE handover guard)
    $sendCmdParams = (Get-Command Send-WebBridgeMessage).Parameters
    Assert ($sendCmdParams.ContainsKey('BrowserProfile') -and $sendCmdParams.ContainsKey('TargetModel') -and $sendCmdParams.ContainsKey('ReasoningEffort') -and $sendCmdParams.ContainsKey('DeferUntilStopped') -and $sendCmdParams.ContainsKey('StopAndRetire')) 'Spec v4.2: Send-WebBridgeMessage exposes BrowserProfile, TargetModel, ReasoningEffort, DeferUntilStopped, and StopAndRetire parameters'

    $v42StallRes = Set-TaskComposerConfig -Context $pulseContext -SessionKey 'tsk_19283093310b828b' -StallSeconds 30 -MaxRetries 1
    Assert ($v42StallRes.binding.stall_seconds -eq 30) 'Spec v4.2: Set-TaskComposerConfig persists 30-second stall_seconds tier'

    $v42Sess = [pscustomobject]@{
        SessionKey = 'tsk_v42_ui_test'
        WfrId = 'tsk_v42_ui_test'
        Title = 'Spec v4.2 队列与守护交互测试'
        ShortTitle = '队列与守护测试'
        StepCountText = '1 / 3 步已完成'
        ProgressPercent = 33
        CommandCount = 4
        Steps = @([pscustomobject]@{ Id = '1'; Title = '准备'; Status = 'completed' })
        ReadableCheckpoints = @()
        HumanDiagnosis = '正在执行阶段验证'
        LatestSummary = '正在执行阶段验证'
        IsStalled = $false
        IsArchived = $false
        AutoResendEnabled = $true
        AutoWakeupEnabled = $true
        StallSeconds = 30
        StallMinutes = 0.5
        MaxRetries = 1
        TargetMode = 'follow_window'
        TargetModel = 'gpt-6-thinking'
        ReasoningEffort = '最高'
        BrowserProfile = 'Edge:Profile 1'
        AvailableModels = $dynModelsTest
        VitalState = 'UNKNOWN'
        VitalHintText = '正在核实网页运行状态'
        PendingQueue = @()
        PendingQueueCount = 0
        SentWebMessages = @()
    }
    $script:composerPodCache = @{}
    $podV42 = Build-PlanBComposerPod -SessionObj $v42Sess -IsNarrow $false -IsZeroTask $false -PaneId 101
    $ruleTagsV42 = @($podV42.Tag.RuleCombo.Items | ForEach-Object { [string]$_.Tag })
    Assert ($ruleTagsV42[0] -eq '30s' -and [string]$podV42.Tag.RuleCombo.Items[0].Content -eq '停顿 30 秒 (测试)' -and [string]$podV42.Tag.RuleCombo.SelectedItem.Tag -eq '30s' -and [string]$podV42.Tag.RetryCombo.SelectedItem.Tag -eq '1') 'Spec v4.2: RuleCombo places 停顿 30 秒 (测试) at index 0 and selects it when StallSeconds=30, with decoupled RetryCombo=1'

    $streamUnknown = Build-PaneStreamContent -PaneObj $script:layout.Panes[0] -SessionObj $v42Sess -IsNarrow $false
    $unknownPillTxt = $streamUnknown.Children[0].Children[0].Content.Children[1].Children[1].Child.Children[1].Text
    Assert ($unknownPillTxt -match '正在核实网页运行状态' -and $unknownPillTxt -match '>30秒静默触发') "Spec v4.2: Build-PaneStreamContent shows UNKNOWN vital hint and >30秒静默触发 (actual: $unknownPillTxt)"

    # FIFO pending queue + Move/Remove-WebBridgeQueuedMessage + SentHistoryModal pending controls
    [void](Set-SessionBridgeBinding -Context $pulseContext -SessionKey 'tsk_v42_ui_test' -ConvUuid 'aaaa1111-1111-4111-8111-111111111111' -BrowserProfile 'Edge:Profile 1' -TargetMode 'follow_window')
    $qM1 = Send-WebBridgeMessage -Context $pulseContext -Session $v42Sess -Mode 'follow_window' -CustomUserText '待发消息 M1' -BrowserProfile 'Edge:Profile 1' -TargetModel 'gpt-6-thinking' -ReasoningEffort '最高'
    $qM2 = Send-WebBridgeMessage -Context $pulseContext -Session $v42Sess -Mode 'follow_window' -CustomUserText '待发消息 M2' -BrowserProfile 'Edge:Profile 1' -TargetModel 'gpt-6-thinking' -ReasoningEffort '最高'
    $qM3 = Send-WebBridgeMessage -Context $pulseContext -Session $v42Sess -Mode 'follow_window' -CustomUserText '待发消息 M3' -BrowserProfile 'Edge:Profile 1' -TargetModel 'gpt-6-thinking' -ReasoningEffort '最高'
    $wbAfter3 = Get-WebBridgeState $pulseContext
    $pendingBefore = @($wbAfter3.queue | Where-Object { $_.session_key -eq 'tsk_v42_ui_test' -and $_.status -eq 'pending' })
    Assert ($pendingBefore.Count -eq 3 -and $pendingBefore[0].browser_profile -eq 'Edge:Profile 1' -and $pendingBefore[0].target_model -eq 'gpt-6-thinking' -and $pendingBefore[0].reasoning_effort -eq '最高') 'Spec v4.2: Multiple manual follow_window sends remain FIFO pending (not superseded) and persist BrowserProfile/TargetModel/ReasoningEffort'

    $mvRes = Move-WebBridgeQueuedMessage -Context $pulseContext -SessionKey 'tsk_v42_ui_test' -MessageId $qM3.MessageId -Direction 'up'
    $rmRes = Remove-WebBridgeQueuedMessage -Context $pulseContext -SessionKey 'tsk_v42_ui_test' -MessageId $qM2.MessageId
    $wbAfterEdit = Get-WebBridgeState $pulseContext
    $pendingAfter = @($wbAfterEdit.queue | Where-Object { $_.session_key -eq 'tsk_v42_ui_test' -and $_.status -eq 'pending' })
    Assert ($mvRes.changed -and $rmRes.changed -and $pendingAfter.Count -eq 2 -and $pendingAfter[0].id -eq $qM1.MessageId -and $pendingAfter[1].id -eq $qM3.MessageId) 'Spec v4.2: Move-WebBridgeQueuedMessage and Remove-WebBridgeQueuedMessage reorder and cancel pending items cleanly'

    $v42Sess.VitalState = 'LIVE'
    $v42Sess.VitalHintText = '检测到网页输入框有未发草稿，待发队列暂缓'
    $v42Sess.PendingQueue = @(
        [pscustomobject]@{ Id = $qM1.MessageId; Text = '待发消息 M1'; Prompt = '待发消息 M1'; Status = 'pending'; TimeText = '10-30 14:30:01'; Mode = 'custom_message'; DeferUntilStopped = $false },
        [pscustomobject]@{ Id = $qM3.MessageId; Text = '待发消息 M3'; Prompt = '待发消息 M3'; Status = 'pending'; TimeText = '10-30 14:30:03'; Mode = 'custom_message'; DeferUntilStopped = $false }
    )
    $v42Sess.PendingQueueCount = 2
    $v42Sess.SentWebMessages = @(
        [pscustomobject]@{ Id = 'msg_sup_old'; Text = '旧自动唤醒'; Prompt = '请继续'; Status = 'superseded'; TimeText = '10-30 14:28:00'; Mode = 'in_place_wakeup' },
        [pscustomobject]@{ Id = 'msg_deliv_1'; Text = '上一条已送达指令'; Prompt = '上一条已送达指令'; Status = 'delivered'; TimeText = '10-30 14:25:00'; Mode = 'custom_message' }
    )
    $streamPending = Build-PaneStreamContent -PaneObj $script:layout.Panes[0] -SessionObj $v42Sess -IsNarrow $false
    $streamPendingStack = $streamPending.Children[0].Children[0].Content
    $blueBubbleElem = $streamPendingStack.Children[$streamPendingStack.Children.Count - 1]
    $bubbleHeaderLeftTxt = $blueBubbleElem.Child.Children[0].Children[0].Text
    $cancelPendingBtn = @($blueBubbleElem.Child.Children[0].Children | Where-Object { $_ -is [Windows.Controls.Button] -and [string]$_.Content -like '*撤回待发*' }) | Select-Object -First 1
    Assert ($bubbleHeaderLeftTxt -match '待发队列 \(2\)' -and $null -ne $cancelPendingBtn) "Spec v4.2: Blue message bubble renders ⏳ 待发队列 (2) and × 撤回待发 button (actual: $bubbleHeaderLeftTxt)"

    Open-SentHistoryModal $v42Sess
    Assert ($script:controls.SentHistoryTitle.Text -match '发送与待发队列' -and $script:controls.SentHistoryListPanel.Children.Count -eq 3) "Spec v4.2: Open-SentHistoryModal pins 2 pending items above 1 delivered item and omits superseded items (count: $($script:controls.SentHistoryListPanel.Children.Count))"
    Close-SentHistoryModal

    # Manual 新建网页交接 LIVE running-session protection (Cancel keeps draft, Defer sets defer_until_stopped, StopAndRetire enqueues stop_before_archive)
    try {
        $script:composerPodCache = @{}
        $v42Sess.TargetMode = 'new_window'
        $v42Sess.VitalState = 'LIVE'
        $podLive = Build-PlanBComposerPod -SessionObj $v42Sess -IsNarrow $false -IsZeroTask $false -PaneId 101
        $podLive.Tag.InputBox.Text = '本轮跑完后接力收尾指令'

        $script:LiveHandoverPromptOverride = { param($s) return 'cancel' }
        $podLive.Tag.SendButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Assert ($podLive.Tag.InputBox.Text -eq '本轮跑完后接力收尾指令') 'Spec v4.2: Cancelling LIVE new-window handover dialog preserves user draft text without sending'

        $script:LiveHandoverPromptOverride = { param($s) return 'defer' }
        $podLive.Tag.SendButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $wbDefer = Get-WebBridgeState $script:context
        $lastDeferMsg = @($wbDefer.queue | Where-Object { $_.session_key -eq 'tsk_v42_ui_test' -and $_.mode -eq 'new_window_handover' }) | Select-Object -Last 1
        Assert ($podLive.Tag.InputBox.Text -eq '' -and $null -ne $lastDeferMsg -and $lastDeferMsg.defer_until_stopped -eq $true) 'Spec v4.2: Selecting 等原网页本轮停稳后自动换新窗接力 queues handover with defer_until_stopped=true'

        [void](Set-SessionBridgeBinding -Context $script:context -SessionKey 'tsk_v42_ui_test' -ConvUuid 'bbbb2222-2222-4222-8222-222222222222' -BrowserProfile 'Edge:Profile 1' -TargetMode 'new_window')
        $podLive.Tag.InputBox.Text = '立即停止旧窗并开启新窗'
        $script:LiveHandoverPromptOverride = { param($s) return 'stop_and_retire' }
        $podLive.Tag.SendButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $wbStopRetire = Get-WebBridgeState $script:context
        $stopRetireAct = @($wbStopRetire.retire_actions | Where-Object { $_.conv_uuid -eq 'bbbb2222-2222-4222-8222-222222222222' -and $_.stop_before_archive -eq $true }) | Select-Object -Last 1
        Assert ($null -ne $stopRetireAct) 'Spec v4.2: Selecting 立即停止原网页并换新窗 enqueues retire_action with stop_before_archive=true'
    } finally {
        $script:LiveHandoverPromptOverride = $null
    }

    # Spec v4.2+ Queue Instant Partial Sync, Modal Delete 1->0 Resurrection Fix & Split-Frequency Polling Seams
    Assert ((Get-Command Invoke-StudioHubSnapshot).Parameters.ContainsKey('SinceRev')) 'Invoke-StudioHubSnapshot supports -SinceRev revision gate'
    Assert ($null -ne (Get-Command Invoke-StudioHubQueueDigest -ErrorAction SilentlyContinue)) 'Invoke-StudioHubQueueDigest lightweight queue fast-track helper is exported'
    Assert ((Get-Command Get-ConnectionDisplayState).Parameters.ContainsKey('ForceInfraProbe')) 'Get-ConnectionDisplayState supports -ForceInfraProbe with 6s infra probe cache'

    [void](Set-SessionBridgeBinding -Context $script:context -SessionKey 'tsk_queue_live_ui' -ConvUuid 'cccc3333-3333-4333-8333-333333333333' -BrowserProfile 'Chrome:Profile 1' -TargetMode 'follow_window')
    $qLiveSess = [pscustomobject]@{
        SessionKey = 'tsk_queue_live_ui'
        WfrId = 'tsk_queue_live_ui'
        ShortId = 'tsk_queue_li'
        Title = '连发与队列即时刷新回归任务'
        ShortTitle = '连发与队列即时刷新回归任务'
        StatusBadge = '● 执行中'
        StatusFg = '#1D4ED8'; StatusBg = '#DBEAFE'; StatusBorder = '#93C5FD'; DotColor = '#3B82F6'
        VitalState = 'LIVE'
        StoppedElapsedSeconds = 0
        StallSeconds = 180
        StallMinutes = 3
        MaxRetries = 1
        RetryCount = 0
        AutoWakeupEnabled = $true
        AutoResendEnabled = $true
        TargetMode = 'follow_window'
        BrowserProfile = 'Chrome:Profile 1'
        TargetModel = 'gpt-6-thinking'
        ReasoningEffort = '极高'
        StepCountText = '1 / 2 步已完成'
        ProgressPercent = 50
        CommandCount = 3
        Steps = @([pscustomobject]@{ Id = '1'; Title = '阶段1'; Status = 'completed' }, [pscustomobject]@{ Id = '2'; Title = '阶段2'; Status = 'in_progress' })
        Milestones = @()
        ReadableCheckpoints = @()
        PendingQueue = @()
        PendingQueueCount = 0
        SentWebMessages = @(
            [pscustomobject]@{ Id = 'msg_hist_ok'; Text = '历史已送达指令'; Prompt = '历史已送达指令'; Status = 'delivered'; TimeText = '10-30 19:00:00'; Mode = 'custom_message' }
        )
    }
    $streamLiveQ = Build-PaneStreamContent -PaneObj $script:layout.Panes[0] -SessionObj $qLiveSess -IsNarrow $false
    $streamLiveQStack = $streamLiveQ.Children[0].Children[0].Content
    $mountedBannerBorder = $streamLiveQStack.Children[$streamLiveQStack.Children.Count - 1]

    # Rapidly send 2 follow_window messages without rebuilding the pane: mounted banner border must update in-place immediately
    [void](Invoke-SendWebBridgeMessage -SessionObj $qLiveSess -Mode 'follow_window' -CustomText '连发第一条')
    $hdrAfter1 = $mountedBannerBorder.Child.Children[0].Children[0].Text
    [void](Invoke-SendWebBridgeMessage -SessionObj $qLiveSess -Mode 'follow_window' -CustomText '连发第二条')
    $hdrAfter2 = $mountedBannerBorder.Child.Children[0].Children[0].Text
    Assert ([object]::ReferenceEquals($mountedBannerBorder, $streamLiveQStack.Children[$streamLiveQStack.Children.Count - 1]) -and $hdrAfter1 -match '待发队列 \(1\)' -and $hdrAfter2 -match '待发队列 \(2\)') "Continuous sends update mounted queue banner in-place without pane teardown (after1='$hdrAfter1', after2='$hdrAfter2')"

    # Open queue modal (2 pending) and delete BOTH down to 0: deleted pending items must NOT resurrect from SentWebMessages!
    Open-SentHistoryModal $qLiveSess
    $firstDelId = [string]$qLiveSess.PendingQueue[0].Id
    $secondDelId = [string]$qLiveSess.PendingQueue[1].Id
    Invoke-CancelQueuedWebMessage 'tsk_queue_live_ui' $firstDelId $qLiveSess
    Assert ($qLiveSess.PendingQueue.Count -eq 1 -and $script:controls.SentHistoryTitle.Text -match '待发 1') "Deleting 1st pending item updates open modal to 待发 1 immediately (title: $($script:controls.SentHistoryTitle.Text))"
    Invoke-CancelQueuedWebMessage 'tsk_queue_live_ui' $secondDelId $qLiveSess
    $remainingPendingInModal = @($qLiveSess.SentWebMessages | Where-Object { $_.Status -eq 'pending' }).Count
    Assert ($qLiveSess.PendingQueue.Count -eq 0 -and $remainingPendingInModal -eq 0 -and $script:controls.SentHistoryTitle.Text -notmatch '待发\s+\d+' -and $script:controls.SentHistoryListPanel.Children.Count -eq 1) "Deleting last pending item (1->0) leaves 0 pending cards in open modal without SentWebMessages resurrection (title: $($script:controls.SentHistoryTitle.Text))"
    Close-SentHistoryModal

    # 5d. Startup Fast-Probe, Zero-Dark-Veil, Launchpad Browser Default/Persistence, and Unbound Open-Web Guard
    $swClosedPort = [Diagnostics.Stopwatch]::StartNew()
    $closedOpen = Test-LocalUrlPortOpen 'http://127.0.0.1:65499/healthz'
    $swClosedPort.Stop()
    Assert ((-not $closedOpen) -and ($swClosedPort.ElapsedMilliseconds -lt 150)) "Test-LocalUrlPortOpen fails fast on closed localhost port (<150ms, actual=$($swClosedPort.ElapsedMilliseconds)ms)"

    $uiSrcRaw = [IO.File]::ReadAllText((Join-Path $managerRoot '连接管理.ps1'), [Text.Encoding]::UTF8)
    Assert ($uiSrcRaw -notmatch 'DoubleAnimation\(0\.65') 'Startup ContentRendered no longer dims WindowChrome with 0.65 opacity dark veil'
    Assert ($uiSrcRaw -match '\[powershell\]::Create\(\)') 'Startup OfficialCore and Tunnel auto-boot runs asynchronously in background Runspace'

    [void](Set-CoreEngineConfig -Context $script:context -DefaultBrowserProfile 'Edge:Default')
    $script:settings = Read-ConnectionSettings $script:context
    $availProfsConfigured = @(Get-AvailableBrowserProfiles -ForceRefresh -Context $script:context)
    $defaultConfigured = $availProfsConfigured | Where-Object { $_.IsDefault } | Select-Object -First 1
    Assert ($null -ne $defaultConfigured -and $defaultConfigured.Id -eq 'Edge:Default' -and (Resolve-RelayBrowserProfile '' $script:context) -eq 'Edge:Default') 'Get-AvailableBrowserProfiles and Resolve-RelayBrowserProfile honor default_browser_profile in settings.json without hardcoding Desktop:ChatGPT'

    $script:composerPodCache.Clear()
    $selBeforeLock = Resolve-LaunchpadSelectedBrowserProfile
    Assert ($selBeforeLock.Id -eq 'Edge:Default') "Launchpad resolves configured default_browser_profile (Edge:Default) before user locks a per-task choice (actual=$($selBeforeLock.Id))"
    $availProfsInit = $availProfsConfigured

    $nonDesktopProf = [string](($availProfsInit | Where-Object { $_.Id -match '^Chrome:' } | Select-Object -First 1).Id)
    if (-not $nonDesktopProf) { $nonDesktopProf = 'Chrome:Default' }
    [void](Set-TaskComposerConfig -Context $script:context -SessionKey '__new_task__' -BrowserProfile $nonDesktopProf)
    $script:composerPodCache.Clear()
    $reopenedLpPod = Build-PlanBComposerPod -SessionObj $null -IsNarrow $false -IsZeroTask $true -PaneId 777
    $selAfterReopen = Resolve-LaunchpadSelectedBrowserProfile -PaneId 777
    Assert ($reopenedLpPod.Tag.ProfCombo.SelectedItem.Tag -eq $nonDesktopProf -and $selAfterReopen.Id -eq $nonDesktopProf) "Manual Launchpad browser choice ($nonDesktopProf) persists across reopening new Launchpad panes and app restarts"

    Invoke-OpenChatGptHome -PaneId 777
    Assert ($script:controls.QuickToastText.Text -match 'Chrome') "Invoke-OpenChatGptHome opens the user-selected Launchpad browser instead of hardcoded Desktop default (toast=$($script:controls.QuickToastText.Text))"

    $unboundLocalSess = [pscustomobject]@{
        SessionKey = 'tsk_unbound_local_only'
        WfrId = 'tsk_unbound_local_only'
        Title = '仅本地建卡未关联对话'
        ShortTitle = '未关联对话'
        BrowserProfile = 'Chrome:Profile 1'
    }
    $unboundRes = Open-SessionWebPage -Context $script:context -Session $unboundLocalSess -NoLaunchBrowser -RequireBoundConversation
    Assert ($unboundRes.Action -eq 'UnboundConversation' -and $unboundRes.Url -eq '') 'Open-SessionWebPage -RequireBoundConversation returns UnboundConversation without opening homepage when task has no bound chat'
    Invoke-OpenSessionWebPage $unboundLocalSess
    Assert ($script:controls.QuickToastText.Text -eq '该任务尚未关联网页对话') "Clicking Open Web Page on unbound task shows exact toast 该任务尚未关联网页对话 (actual=$($script:controls.QuickToastText.Text))"
    if ($script:toastTimer) { $script:toastTimer.Stop() }
    $script:controls.QuickToastBorder.Visibility = 'Collapsed'

    # 6. Run Python ShieldHub seam test suite (T1-T7)

    if (-not $SkipPythonSeams) {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $pyTestOut = & python (Join-Path $PSScriptRoot 'test_shield_hub.py') 2>&1 | Out-String
        $pyExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        Assert ($pyExit -eq 0) "Python ShieldHub seam tests (T1-T12) pass: $pyTestOut"

        $ErrorActionPreference = 'Continue'
        $pyV41Out = & python (Join-Path $PSScriptRoot 'test_spec_v41.py') 2>&1 | Out-String
        $pyV41Exit = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        Assert ($pyV41Exit -eq 0) "Python Spec v4.1 seam tests (T24-T28) pass: $pyV41Out"

        $ErrorActionPreference = 'Continue'
        $pyV44Out = & python (Join-Path $PSScriptRoot 'test_spec_v44.py') 2>&1 | Out-String
        $pyV44Exit = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        Assert ($pyV44Exit -eq 0) "Python Spec v4.4 seam tests (Issues 1-6) pass: $pyV44Out"
    }
    Assert ($uiScriptRaw -notmatch '\$pId\s*=' -and $uiScriptRaw -match '\$targetPaneId\s*=') 'Spec v4.4 Issue 1: openGptBtn never assigns to read-only automatic variable $PID'
    Assert ($psm1ScriptRaw -notmatch 'Invoke-CimMethod' -and $psm1ScriptRaw -match 'Start-InteractiveHiddenCmd') 'Spec v4.4 Issue 2: ConnectionManager.psm1 starts daemons via ProcessStartInfo in WinSta0\Default instead of Win32_Process'

    $script:controls.TunnelInput.Text='https://platform.openai.com/settings/organization/tunnels/' + $id

    $script:controls.KeyInput.Text=$fakeKey

    $script:controls.SaveButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))

    Assert (Test-Path -LiteralPath (Join-Path $uiData 'settings.json')) 'GUI save button writes settings'

    Assert ($script:controls.KeyInput.Text -eq $fakeKey) 'GUI displays full plaintext API key in KeyInput for easy editing'

    Assert ($script:controls.FeedbackText.Text -match '已保存') 'GUI reports save success'

    $script:controls.TunnelInput.Text='invalid tunnel'

    $script:controls.SaveButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))

    Assert ($script:controls.FeedbackText.Text -match '请粘贴完整') 'GUI shows validation error'

    Assert ($script:controls.TunnelInput.Text -eq 'invalid tunnel') 'GUI preserves input after failed save'

    Assert ($script:controls.ConnectButton.Content -eq '保存并连接') 'RelayStudio ConnectButton self-starts core and connects without requiring official panel'

    $script:controls.TunnelInput.Text=$id

    $script:controls.FeedbackBox.Visibility='Collapsed'

    Select-WindowTab 'Live'

    Refresh-ProfilePopoverState

    Assert ($script:controls.MaskedKeyText.Text -match '••••') 'MaskedKeyText defaults to head/tail masked key'

    $script:controls.ToggleKeyMaskButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))

    Assert ($script:controls.MaskedKeyText.Text -eq $fakeKey) 'ToggleKeyMaskButton reveals full plaintext key on demand'

    $script:controls.ToggleKeyMaskButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))

    Assert ($script:controls.MaskedKeyText.Text -match '••••') 'ToggleKeyMaskButton hides plaintext key back to mask'

    [IO.Directory]::CreateDirectory($EvidenceRoot) | Out-Null

    Export-WindowRender (Join-Path $EvidenceRoot 'RelayStudio连接管理-窗口.png')

    Toggle-LeftRail

    Export-WindowRender (Join-Path $EvidenceRoot 'RelayStudio连接管理-左栏折叠态.png')

    Toggle-LeftRail

    Toggle-KeyPopover

    Export-WindowRender (Join-Path $EvidenceRoot 'RelayStudio连接管理-连接与Key气泡面板.png')

    Select-WindowTab 'Config'

    $script:controls.Advanced.IsExpanded=$true

    Export-WindowRender (Join-Path $EvidenceRoot 'RelayStudio连接管理-高级设置.png')

    $script:controls.FormScroll.ScrollToEnd()

    Export-WindowRender (Join-Path $EvidenceRoot 'RelayStudio连接管理-高级设置下部.png')

    Select-WindowTab 'Live'

    # Verify Seam 1 (Resolve-EffectiveOutboundProxyEnv) & Seam 2 (Get-StudioHubBaseUrl) in main suite
    $mainDeadEnv = @{ HTTPS_PROXY = 'http://127.0.0.1:59998'; HTTP_PROXY = 'http://127.0.0.1:59998' }
    $mainProxyRes = Resolve-EffectiveOutboundProxyEnv -Context $script:context -BaseEnv $mainDeadEnv -SystemProxyOverride ''
    Assert ($mainProxyRes.Mode -eq 'direct_fallback' -and $mainProxyRes.ProxyUrl -eq '' -and $mainProxyRes.NoProxy -match '\*\.ts\.net') 'Main suite: Resolve-EffectiveOutboundProxyEnv strips dead local proxy port and preserves *.ts.net in NO_PROXY'
    Assert ((Get-StudioHubBaseUrl -Context $script:context -Settings ([pscustomobject]@{ shield_port = 18766 })) -eq 'http://127.0.0.1:18766') 'Main suite: Get-StudioHubBaseUrl seam resolves custom shield_port'

    # Main suite: URL Stability Invariant, Edge Health Seam (8000ms / Degraded), Lock Retry, UI Dirty-Checking & UTF-8 BOM + PS AST check
    $mainFakeTsOk = Join-Path $testRoot 'main-fake-ts-ok.cmd'
    [IO.File]::WriteAllText($mainFakeTsOk, "@echo off`r`nif `"%1`"==`"status`" (`r`n  echo {`"BackendState`":`"Running`",`"Self`":{`"DNSName`":`"main-box.tail9999.ts.net.`"}}`r`n  exit /b 0`r`n)`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
    $mainFakeCf = Join-Path $testRoot 'main-fake-cf.cmd'
    [IO.File]::WriteAllText($mainFakeCf, "@echo off`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
    try {
        Set-PublicMcpEdgeProbeOverride {
            param($Url, $ProbeCtx, $TimeoutMs, $SlowThresholdMs)
            return [pscustomobject]@{ Reachable = $false; Phase = 'Offline'; PublicRttMs = 0; IngressIp = '' }
        }
        $mainFixedOff = Start-PublicMcpTunnel -Context $script:context -FixedDomain 'https://main-box.tail9999.ts.net' -TailscalePath $mainFakeTsOk -ClientPath $mainFakeCf
        Assert ((-not $mainFixedOff.Running) -and $mainFixedOff.Mode -eq 'tailscale' -and $mainFixedOff.Url -eq 'https://main-box.tail9999.ts.net/mcp' -and $mainFixedOff.HealthPhase -eq 'Offline' -and $mainFixedOff.Status -eq '离线' -and $mainFixedOff.FallbackFrom -eq '') 'Main suite: Fixed *.ts.net domain never downgrades to cloudflared_quick when public edge is Offline'

        $mainProbeArgsFile = Join-Path $testRoot 'main-probe-args.txt'
        Set-PublicMcpEdgeProbeOverride ([scriptblock]::Create(@"
            param(`$Url, `$ProbeCtx, `$TimeoutMs, `$SlowThresholdMs)
            [IO.File]::WriteAllText('$($mainProbeArgsFile.Replace("'", "''"))', "`$TimeoutMs|`$SlowThresholdMs")
            return [pscustomobject]@{ Reachable = `$true; Phase = 'Degraded'; PublicRttMs = 4650; IngressIp = '103.84.155.153' }
"@))
        $mainDeg = Start-PublicMcpTunnel -Context $script:context -FixedDomain 'https://main-box.tail9999.ts.net' -TailscalePath $mainFakeTsOk -ClientPath $mainFakeCf -ForceReconnect
        $mainArgsParts = ([IO.File]::ReadAllText($mainProbeArgsFile) -split '\|')
        Assert ([int]$mainArgsParts[0] -eq 8000 -and [int]$mainArgsParts[1] -eq 2500 -and $mainDeg.Running -and $mainDeg.HealthPhase -eq 'Degraded' -and $mainDeg.Status -eq '偏慢' -and $mainDeg.PublicRttMs -eq 4650) 'Main suite: 4650ms cellular RTT with 8000ms default timeout lands in Degraded (偏慢) state'

        # Verify UI dirty-check guards: Apply-WindowTheme signature guard & Sync-TopBarTunnelCapsuleState Degraded amber dot + no-op repeat tick
        Apply-WindowTheme -Force
        $resRefBefore = $script:window.Resources
        Apply-WindowTheme
        Assert ([object]::ReferenceEquals($resRefBefore, $script:window.Resources)) 'Apply-WindowTheme signature guard skips replacing Window.Resources when theme/accent/platform is unchanged'

        [void](Add-CapsulePlatform -Context $script:context -Platform 'claude')
        Close-AllTopPopovers
        $script:lastTopBarCapsuleSig = ''
        $sentinelChild = New-Object Windows.Controls.Border
        [void]$script:controls.ProfilesListPanel.Children.Add($sentinelChild)
        Refresh-FormState
        $claudeCapBtn = $script:capsuleSegmentButtons['claude']
        $claudeCapDot = $claudeCapBtn.Content.Children[0]
        $sigAfterFirstTick = $script:lastTopBarCapsuleSig
        Refresh-FormState
        Assert ($claudeCapDot.Fill.ToString() -eq '#FFF59E0B' -and [string]$claudeCapBtn.ToolTip -match '公网响应偏慢 \(4650ms\)' -and $script:lastTopBarCapsuleSig -eq $sigAfterFirstTick -and $script:controls.ProfilesListPanel.Children.Contains($sentinelChild)) 'Refresh-FormState updates top capsule Degraded (#F59E0B / 4650ms) via Sync-TopBarTunnelCapsuleState without rebuilding hidden ProfilesListPanel on 2s ticks'
        [void](Remove-CapsulePlatform -Context $script:context -Settings $script:settings -Platform 'claude')
        $script:lastTopBarCapsuleSig = ''
        Refresh-FormState

        # Verify Stop-PublicMcpTunnel lock retry in main suite
        $mainLockFile = Join-Path $script:context.DataRoot 'public-mcp-tunnel.lock'
        $mainLockFlag = Join-Path $testRoot 'main-lock.flag'
        $mainHolder = [powershell]::Create()
        try {
            [void]$mainHolder.AddScript({
                param($Lp, $Fp)
                $fs = [IO.File]::Open($Lp, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                try {
                    [IO.File]::WriteAllText($Fp, '1')
                    Start-Sleep -Milliseconds 250
                } finally { $fs.Dispose() }
            }).AddArgument($mainLockFile).AddArgument($mainLockFlag)
            $mh = $mainHolder.BeginInvoke()
            $dl = [DateTime]::UtcNow.AddSeconds(3)
            while (-not (Test-Path -LiteralPath $mainLockFlag) -and [DateTime]::UtcNow -lt $dl) { Start-Sleep -Milliseconds 15 }
            Stop-PublicMcpTunnel $script:context
            [void]$mainHolder.EndInvoke($mh)
            Assert (-not (Get-PublicMcpTunnelState $script:context).Running) 'Main suite: Stop-PublicMcpTunnel retries public-mcp-tunnel.lock cleanly without IOException'
        } finally { $mainHolder.Dispose() }
    } finally {
        Set-PublicMcpEdgeProbeOverride $null
        Stop-PublicMcpTunnel $script:context
    }

    Invoke-UnifiedPublicTunnelPoolAndEnvTests -SuiteRoot (Join-Path $testRoot 'main-unified-pub') -RepoRoot $managerRoot

    # Verify UTF-8 BOM preservation and PowerShell AST clean parse on all 3 PowerShell files
    foreach ($psFile in @(
        (Join-Path $managerRoot 'ConnectionManager.psm1'),
        (Join-Path $managerRoot '连接管理.ps1'),
        (Join-Path $managerRoot 'tests\Test-ConnectionManager.ps1')
    )) {
        $rawBytes = [IO.File]::ReadAllBytes($psFile)
        $hasUtf8Bom = ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF)
        $astTokens = $null
        $astErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($psFile, [ref]$astTokens, [ref]$astErrors)
        $leafName = Split-Path $psFile -Leaf
        Assert ($hasUtf8Bom -and @($astErrors).Count -eq 0) "File $leafName preserves UTF-8 BOM ($hasUtf8Bom) and parses with 0 PowerShell AST errors (errors=$(@($astErrors).Count))"
    }

    [pscustomobject]@{Passed=$script:passed; LiveTunnelStarted=$false; ProductionFilesModified=$false; Result='PASS'} | ConvertTo-Json

} finally {

    $resolved=[IO.Path]::GetFullPath($testRoot)

    if (-not $resolved.StartsWith(($scratchParent + '\'),[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'connection-test-*') { throw 'Unsafe test cleanup path.' }

    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }

}

