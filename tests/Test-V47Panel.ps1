param([string]$EvidenceRoot = (Join-Path ([IO.Path]::GetTempPath()) 'relaystudio-test-outputs'))

# Spec v4.7 Module 3: Studio Panel (ConnectionManager.psm1 + 连接管理.ps1) seam tests.
#   3.1 Get-WorkspaceRecentCommits attributes commits to the session's real business workspace
#   3.2 Drawer / modal header buttons are vertically centered with fixed Height=28; DetailModalGoal is folded
#   3.3 Detail modal $panelSig refreshes on step status / newest checkpoint changes
#   3.4 VitalSubstate capsule / task card colors with safe fallback when the field is missing

$ErrorActionPreference = 'Stop'
$managerRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $managerRoot 'ConnectionManager.psm1') -Force

$scratchParent = (Join-Path ([IO.Path]::GetTempPath()) 'relaystudio-test-work')
$testRoot = Join-Path $scratchParent ('connection-test-v47-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

$script:passed = 0
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:passed++ }

function New-FakeReflog([string]$RepoRoot, [string]$Message, [string]$ShaSeed) {
    $logDir = Join-Path $RepoRoot '.git\logs'
    [IO.Directory]::CreateDirectory($logDir) | Out-Null
    $oldSha = '0' * 40
    $newSha = ($ShaSeed * 40).Substring(0, 40)
    $epoch = [DateTimeOffset]::Now.AddMinutes(-3).ToUnixTimeSeconds()
    $line = "$oldSha $newSha Tester <t@example.com> $epoch +0800`tcommit: $Message"
    [IO.File]::WriteAllText((Join-Path $logDir 'HEAD'), $line + "`n")
    return $newSha.Substring(0, 7)
}

try {
    # ---------- 3.1 Get-WorkspaceRecentCommits per-session business repo attribution ----------
    $ctx = [pscustomobject]@{
        Isolated = $false
        DataRoot = (Join-Path $testRoot 'data')
        SettingsPath = (Join-Path (Join-Path $testRoot 'data') 'settings.json')
    }
    [IO.Directory]::CreateDirectory($ctx.DataRoot) | Out-Null

    $bizRepo = Join-Path $testRoot 'AlmaLeyuFake'
    $bizSha = New-FakeReflog $bizRepo 'feat: business repo commit' 'a1'
    $bizCommits = @(Get-WorkspaceRecentCommits -Context $ctx -WorkspaceRoot $bizRepo)
    Assert ($bizCommits.Count -ge 1 -and $bizCommits[0].Sha -eq $bizSha -and $bizCommits[0].Message -eq 'feat: business repo commit') "Get-WorkspaceRecentCommits -WorkspaceRoot reads the business repo reflog first (actual: $($bizCommits | ForEach-Object { $_.Sha + ' ' + $_.Message }))"

    $subDir = Join-Path $bizRepo 'src'
    [IO.Directory]::CreateDirectory($subDir) | Out-Null
    $subCommits = @(Get-WorkspaceRecentCommits -Context $ctx -WorkspaceRoot $subDir)
    Assert ($subCommits.Count -ge 1 -and $subCommits[0].Sha -eq $bizSha) 'Get-WorkspaceRecentCommits -WorkspaceRoot also checks the parent directory .git'

    $wsRootsParent = Join-Path $testRoot 'roots'
    $namedSha = New-FakeReflog (Join-Path $wsRootsParent 'NamedProject') 'fix: named workspace commit' 'b2'
    [IO.File]::WriteAllText($ctx.SettingsPath, (@{ schema_version = 1; workspace_roots = @($wsRootsParent) } | ConvertTo-Json))
    $namedCommits = @(Get-WorkspaceRecentCommits -Context $ctx -WorkspaceName 'NamedProject')
    Assert ($namedCommits.Count -ge 1 -and $namedCommits[0].Sha -eq $namedSha) "Get-WorkspaceRecentCommits -WorkspaceName resolves <workspace_roots>\\<name>\\.git (actual: $($namedCommits | ForEach-Object { $_.Sha }))"

    $rootPriority = @(Get-WorkspaceRecentCommits -Context $ctx -WorkspaceRoot $bizRepo -WorkspaceName 'NamedProject')
    Assert ($rootPriority.Count -ge 1 -and $rootPriority[0].Sha -eq $bizSha) 'WorkspaceRoot takes priority over WorkspaceName'

    $isoCtx = [pscustomobject]@{ Isolated = $true; DataRoot = $ctx.DataRoot; SettingsPath = $ctx.SettingsPath }
    Assert (@(Get-WorkspaceRecentCommits -Context $isoCtx -WorkspaceRoot $bizRepo).Count -eq 0) 'Isolated contexts still never read any reflog'

    # Per-session attribution in the snapshot adapter (Get-TunnelActivityPulse seam)
    $otherRepo = Join-Path $testRoot 'OtherRepo'
    $otherSha = New-FakeReflog $otherRepo 'chore: other repo commit' 'c3'
    $preset = @([pscustomobject]@{ Sha = 'deadbee'; TimeText = '00:00:00'; AgoText = '刚刚'; Message = 'hub provided' })
    $hubSessions = @(
        [pscustomobject]@{ SessionKey = 'tsk_a'; WorkspaceRoot = $bizRepo; WorkspaceName = 'AlmaLeyuFake' },
        [pscustomobject]@{ SessionKey = 'tsk_b'; WorkspaceRoot = $otherRepo; WorkspaceName = 'OtherRepo' },
        [pscustomobject]@{ SessionKey = 'tsk_c'; WorkspaceName = 'NamedProject' },
        [pscustomobject]@{ SessionKey = 'tsk_d'; WorkspaceRoot = $otherRepo; RecentCommits = $preset }
    )
    Set-SessionRecentCommits -Context $ctx -Sessions $hubSessions
    Assert ($hubSessions[0].RecentCommits[0].Sha -eq $bizSha -and $hubSessions[1].RecentCommits[0].Sha -eq $otherSha -and $hubSessions[2].RecentCommits[0].Sha -eq $namedSha) 'Set-SessionRecentCommits fills RecentCommits per session WorkspaceRoot / WorkspaceName'
    Assert ($hubSessions[3].RecentCommits[0].Sha -eq 'deadbee') 'Set-SessionRecentCommits keeps hub-provided RecentCommits'

    # ---------- GUI seams ----------
    $uiData = Join-Path $testRoot 'ui'
    . (Join-Path $managerRoot '连接管理.ps1') -DataRoot $uiData -Preview -NoShow

    # 3.2 Header buttons
    foreach ($btnName in @('ClearAllArchivedButton', 'CloseArchiveDrawerButton', 'CloseSentHistoryButton', 'CloseDetailButton')) {
        $btn = $script:controls.$btnName
        Assert ($btn -is [Windows.Controls.Button] -and $btn.Height -eq 28 -and [string]$btn.VerticalAlignment -eq 'Center') "$btnName has Height=28 and VerticalAlignment=Center (actual: H=$($btn.Height) VA=$($btn.VerticalAlignment))"
    }
    $goalCtl = $script:controls.DetailModalGoal
    Assert ($goalCtl.MaxHeight -eq 36 -and [string]$goalCtl.TextTrimming -eq 'CharacterEllipsis') 'DetailModalGoal is folded with MaxHeight=36 and CharacterEllipsis'

    # 3.3 Detail modal signature refresh
    $ckpts = @(for ($k = 0; $k -lt 12; $k++) { [pscustomobject]@{ TimeText = "10:$('{0:D2}' -f $k):00"; Summary = "检查点 $k" } })
    $detailSess = [pscustomobject]@{
        SessionKey = 'tsk_v47_detail'
        Title = 'v4.7 详情刷新'
        Goal = "第一行目标`r`n第二行目标`n第三行目标"
        MetaText = 'meta'
        StatusBadge = '● 活跃运行中'; StatusBg = '#DCFCE7'; StatusBorder = '#BBF7D0'; StatusFg = '#166534'
        HumanDiagnosis = '诊断'; ActionText = '动作'
        ProgressPercent = 50; ProgressText = '1 / 2 步已完成'; LatestSummary = '最新'
        CommandCount = 10
        VitalState = 'LIVE'
        Steps = @(
            [pscustomobject]@{ Id = '1'; Title = '准备'; Status = 'completed'; StatusLabel = '已完成'; BadgeBg = '#DCFCE7'; BadgeFg = '#166534'; UpdatedText = '10:00' },
            [pscustomobject]@{ Id = '2'; Title = '实施'; Status = 'pending'; StatusLabel = '待开始'; BadgeBg = '#F4F4F5'; BadgeFg = '#71717A'; UpdatedText = '' }
        )
        Checkpoints = $ckpts
        RecentCommits = @()
    }
    $script:display.Sessions = @($detailSess)
    Open-SessionDetail 'tsk_v47_detail'
    Assert ($script:controls.DetailModalGoal.Text -notmatch "[`r`n]" -and $script:controls.DetailModalGoal.Text -match '第一行目标 第二行目标 第三行目标') "DetailModalGoal flattens newlines into spaces (actual: $($script:controls.DetailModalGoal.Text))"
    Assert ([string]$script:controls.DetailModalGoal.ToolTip -match "第一行目标`r?`n第二行目标") 'DetailModalGoal ToolTip carries the full multi-line goal'

    $detailSess.Steps[1].Status = 'in_progress'; $detailSess.Steps[1].StatusLabel = '进行中'
    Update-SessionDetailModal
    $step2Bg = $script:controls.DetailStepsPanel.Children[1].Background.Color.ToString()
    Assert ($step2Bg -eq '#FFEFF6FF') "Detail modal re-renders when a step turns in_progress with unchanged step count (actual bg: $step2Bg)"

    $detailSess.Checkpoints = @([pscustomobject]@{ TimeText = '11:00:00'; Summary = '最新检查点' }) + @($ckpts | Select-Object -First 11)
    Update-SessionDetailModal
    $firstCkTxt = $script:controls.DetailCheckpointsPanel.Children[0].Child.Text
    Assert ($firstCkTxt -match '最新检查点') "Detail modal re-renders when newest checkpoint changes while count stays 12 (actual: $firstCkTxt)"

    $detailSess | Add-Member -NotePropertyName 'VitalSubstate' -NotePropertyValue 'NETWORK_HOLD' -Force
    Update-SessionDetailModal
    Assert ($script:controls.DetailModalBadgeText.Text -match '断网' -and $script:controls.DetailModalBadgeText.Foreground.Color.ToString() -eq '#FFC2410C') "Detail modal badge renders NETWORK_HOLD substate (actual: $($script:controls.DetailModalBadgeText.Text))"
    Close-SessionDetail

    # 3.4 VitalSubstate capsule colors (visual tree path kept identical to Test-ConnectionManager.ps1)
    $paneObj = $script:layout.Panes[0]
    $expect = @{
        'PSEUDO_STOPPED'  = @('#FFEFF6FF', '#FF1D4ED8')
        'WAITING_CONFIRM' = @('#FFFFFBEB', '#FFB45309')
        'NETWORK_HOLD'    = @('#FFFFF7ED', '#FFC2410C')
        'DUAL_STREAM'     = @('#FFF5F3FF', '#FF6D28D9')
    }
    foreach ($sub in $expect.Keys) {
        $vs = [pscustomobject]@{
            SessionKey = "tsk_v47_$sub"; Title = "胶囊 $sub"; StepCountText = '1 / 2 步已完成'; ProgressPercent = 50
            Steps = @(); IsStalled = ($sub -in @('WAITING_CONFIRM', 'NETWORK_HOLD')); IsArchived = $false
            AutoResendEnabled = $true; StallMinutes = 5; MaxRetries = 1; RetryCount = 0
            VitalState = $(if ($sub -in @('WAITING_CONFIRM', 'NETWORK_HOLD')) { 'STOPPED' } else { 'LIVE' })
            VitalSubstate = $sub; SilenceCountdownSec = 42; LastToolAgeSec = 18
            SentWebMessages = @(); PendingQueue = @(); PendingQueueCount = 0
        }
        $sc = Build-PaneStreamContent -PaneObj $paneObj -SessionObj $vs -IsNarrow $false
        $pill = $sc.Children[0].Children[0].Content.Children[1].Children[1]
        $pillTxt = $pill.Child.Children[1]
        Assert ($pill.Background.Color.ToString() -eq $expect[$sub][0] -and $pillTxt.Foreground.Color.ToString() -eq $expect[$sub][1]) "$sub capsule colors (actual bg=$($pill.Background.Color) fg=$($pillTxt.Foreground.Color))"
        Assert ($pillTxt.Text -match '>5分钟静默触发') "$sub capsule keeps >X分钟静默触发 suffix (actual: $($pillTxt.Text))"
    }
    $waitSess = [pscustomobject]@{ SessionKey = 'tsk_v47_wait'; Title = 'w'; StepCountText = ''; Steps = @(); IsStalled = $true; IsArchived = $false; AutoResendEnabled = $true; StallSeconds = 30; MaxRetries = 1; VitalSubstate = 'WAITING_CONFIRM'; SilenceCountdownSec = 42 }
    $waitTxt = (Build-PaneStreamContent -PaneObj $paneObj -SessionObj $waitSess -IsNarrow $false).Children[0].Children[0].Content.Children[1].Children[1].Child.Children[1].Text
    Assert ($waitTxt -match '42' -and $waitTxt -match '>30秒静默触发') "WAITING_CONFIRM capsule shows countdown and >30秒静默触发 (actual: $waitTxt)"

    $legacySess = [pscustomobject]@{ SessionKey = 'tsk_v47_legacy'; Title = 'legacy'; StepCountText = ''; Steps = @(); IsStalled = $false; IsArchived = $false; AutoResendEnabled = $true; StallMinutes = 5; MaxRetries = 1; VitalState = 'LIVE' }
    $legacyPill = (Build-PaneStreamContent -PaneObj $paneObj -SessionObj $legacySess -IsNarrow $false).Children[0].Children[0].Content.Children[1].Children[1]
    Assert ($legacyPill.Background.Color.ToString() -eq '#FFF0FDF4') 'Missing VitalSubstate falls back to legacy green LIVE capsule'

    # Task card right status label follows the locally-derived StatusBadge
    $cardSess = [pscustomobject]@{ SessionKey = 'tsk_v47_card'; Title = '卡片'; ShortTitle = '卡片'; StepCountText = ''; Steps = @(); IsStalled = $false; IsArchived = $false; DotColor = '#16A34A'; ActionText = 'a'; VitalState = 'LIVE'; VitalSubstate = 'DUAL_STREAM' }
    $script:display.Sessions = @($cardSess)
    $script:lastCardsSig = ''
    Update-SessionCards
    $cardStatus = $script:controls.SessionListPanel.Children[0].Child.Children[1].Children[1]
    Assert ($cardStatus.Text -match '双流' -and $cardStatus.Foreground.Color.ToString() -eq '#FF6D28D9') "Task card status label shows DUAL_STREAM badge (actual: $($cardStatus.Text))"
    $cardSess.VitalSubstate = 'PSEUDO_STOPPED'
    Update-SessionCards
    $cardStatus2 = $script:controls.SessionListPanel.Children[0].Child.Children[1].Children[1]
    Assert ($cardStatus2.Foreground.Color.ToString() -eq '#FF1D4ED8') 'Task card refreshes when only VitalSubstate changes'

    [pscustomobject]@{ Passed = $script:passed; Result = 'PASS' } | ConvertTo-Json
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith(($scratchParent + '\'), [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'connection-test-*') { throw 'Unsafe test cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
