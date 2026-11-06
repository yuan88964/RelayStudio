$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $PSScriptRoot '..\ConnectionManager.psm1') -Force

$script:assertions = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw "FAIL: $Message"
    }
    $script:assertions++
    Write-Host "PASS $Message"
}

$scratchParent = Join-Path ([IO.Path]::GetTempPath()) 'RelayStudioTests'
[IO.Directory]::CreateDirectory($scratchParent) | Out-Null
$testRoot = Join-Path $scratchParent ('connection-test-theme-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

try {
    $ctx = New-ConnectionContext -DataRoot $testRoot -Isolated

    # 1. Default ThemeMode is 'system' on fresh layout memory (Q6=A)
    $layout0 = Get-WindowLayoutMemory $ctx
    Assert ($layout0.PSObject.Properties.Name -contains 'ThemeMode' -and $layout0.ThemeMode -eq 'system') 'Default ThemeMode in Get-WindowLayoutMemory is system'

    # 2. Save-WindowLayoutMemory persists theme_mode and Get-WindowLayoutMemory reloads it (Q2=B)
    $layout0.ThemeMode = 'dark'
    Save-WindowLayoutMemory -Context $ctx -Layout $layout0
    $layoutReload = Get-WindowLayoutMemory $ctx
    Assert ($layoutReload.ThemeMode -eq 'dark') 'Save-WindowLayoutMemory persists theme_mode=dark and reloads cleanly'

    $layoutReload.ThemeMode = 'system'
    Save-WindowLayoutMemory -Context $ctx -Layout $layoutReload
    Assert ((Get-WindowLayoutMemory $ctx).ThemeMode -eq 'system') 'Save-WindowLayoutMemory persists theme_mode=system'

    # 3. Get-SystemThemePreference & Resolve-EffectiveTheme resolve system/light/dark
    Assert ((Get-SystemThemePreference -RegistryValue 0) -eq 'dark') 'AppsUseLightTheme=0 resolves to dark system preference'
    Assert ((Get-SystemThemePreference -RegistryValue 1) -eq 'light') 'AppsUseLightTheme=1 resolves to light system preference'
    Assert ((Resolve-EffectiveTheme -ThemeMode 'system' -SystemTheme 'dark') -eq 'dark') 'Resolve-EffectiveTheme in system mode follows dark system theme'
    Assert ((Resolve-EffectiveTheme -ThemeMode 'system' -SystemTheme 'light') -eq 'light') 'Resolve-EffectiveTheme in system mode follows light system theme'
    Assert ((Resolve-EffectiveTheme -ThemeMode 'dark' -SystemTheme 'light') -eq 'dark') 'Resolve-EffectiveTheme in explicit dark mode overrides light system theme'
    Assert ((Resolve-EffectiveTheme -ThemeMode 'light' -SystemTheme 'dark') -eq 'light') 'Resolve-EffectiveTheme in explicit light mode overrides dark system theme'

    # 4. Step-QuickThemeToggle implements one-click invert and right-click system restore (Q5=A)
    Assert ((Step-QuickThemeToggle -CurrentThemeMode 'system' -EffectiveTheme 'light' -Action 'invert') -eq 'dark') 'Invert from effective light switches directly to dark in 1 click'
    Assert ((Step-QuickThemeToggle -CurrentThemeMode 'system' -EffectiveTheme 'dark' -Action 'invert') -eq 'light') 'Invert from effective dark switches directly to light in 1 click'
    Assert ((Step-QuickThemeToggle -CurrentThemeMode 'dark' -EffectiveTheme 'dark' -Action 'system') -eq 'system') 'Right-click action=system restores system mode'

    # 5. Resolve-ThemeColorHex maps Zinc hierarchy and status pills cleanly (Q3=A)
    Assert ((Resolve-ThemeColorHex -Hex '#F3F4F6' -Theme 'dark') -eq '#111114') 'Outer shell #F3F4F6 maps to deep carbon #111114 in dark mode'
    Assert ((Resolve-ThemeColorHex -Hex '#FFFFFF' -Theme 'dark') -eq '#18181B') 'Workspace/card surface #FFFFFF maps to elevated zinc #18181B in dark mode'
    Assert ((Resolve-ThemeColorHex -Hex '#18181B' -Theme 'dark') -eq '#F4F4F5') 'Primary text #18181B maps to soft crisp white #F4F4F5 in dark mode'
    Assert ((Resolve-ThemeColorHex -Hex '#FEFEFF' -Theme 'dark') -eq '#FFFFFF') 'Dedicated white-on-badge foreground #FEFEFF stays #FFFFFF in dark mode'
    Assert ((Resolve-ThemeColorHex -Hex '#18181F' -Theme 'dark') -eq '#27272A') 'Dedicated dark badge background #18181F maps to #27272A in dark mode'
    Assert ((Resolve-ThemeColorHex -Hex '#DCFCE7' -Theme 'dark') -eq '#052E16') 'Green status pill background #DCFCE7 maps to dark emerald #052E16 in dark mode'
    Assert ((Resolve-ThemeColorHex -Hex '#EFF6FF' -Theme 'dark') -eq '#172554') 'Blue status pill background #EFF6FF maps to dark navy #172554 in dark mode'
    Assert ((Resolve-ThemeColorHex -Hex '#FEF2F2' -Theme 'dark') -eq '#3B1219') 'Red status pill background #FEF2F2 maps to dark crimson #3B1219 in dark mode'
    Assert ((Resolve-ThemeColorHex -Hex '#FEF3C7' -Theme 'dark') -eq '#3B2106') 'Amber status pill background #FEF3C7 maps to dark bronze #3B2106 in dark mode'
    Assert ((Resolve-ThemeColorHex -Hex '#F3F4F6' -Theme 'light') -eq '#F3F4F6') 'Light mode preserves canonical #F3F4F6'


    # === Slice 2: Live WPF Workbench & Controls Hot-Switching in 连接管理.ps1 ===
    $uiScript = Join-Path $PSScriptRoot '..\连接管理.ps1'
    . $uiScript -DataRoot $testRoot -Preview -NoShow

    # 6. Top bar ThemeToggleButton and Config Center 3-tier buttons exist (Q1=A, Q2=B)
    Assert ($script:controls.ThemeToggleButton -is [Windows.Controls.Button]) 'Top title bar contains ThemeToggleButton'
    Assert ($script:controls.ThemeSystemButton -is [Windows.Controls.Button] -and $script:controls.ThemeLightButton -is [Windows.Controls.Button] -and $script:controls.ThemeDarkButton -is [Windows.Controls.Button]) 'Config popover contains ThemeSystemButton, ThemeLightButton, and ThemeDarkButton'

    # 7. Clicking ThemeLightButton switches to explicit Light Mode and updates surfaces
    $script:controls.ThemeLightButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert ($script:layout.ThemeMode -eq 'light' -and $script:effectiveTheme -eq 'light') 'Clicking ThemeLightButton sets ThemeMode=light and effectiveTheme=light'
    Assert ($script:controls.AppTitleBarBorder.Background.Color.ToString() -eq '#FFF3F4F6') 'Light mode AppTitleBarBorder background is #FFF3F4F6'
    Assert ($script:controls.WorkspaceOuterBorder.Background.Color.ToString() -eq '#FFFFFFFF') 'Light mode WorkspaceOuterBorder background is #FFFFFFFF'

    # 8. Enter a draft in ComposerPodHost and click top-bar ThemeToggleButton (1-click invert to Dark Mode, preserving draft!) (Q4=A, Q5=A)
    $testPod = Build-PlanBComposerPod -SessionObj $null -IsNarrow $false -IsZeroTask $true
    $testPod.Tag.InputBox.Text = '深色模式切换不丢失草稿测试'
    $script:controls.ThemeToggleButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert ($script:layout.ThemeMode -eq 'dark' -and $script:effectiveTheme -eq 'dark') 'Left-clicking ThemeToggleButton inverts from light to dark in 1 click'
    Assert ((Get-WindowLayoutMemory $script:context).ThemeMode -eq 'dark') 'ThemeToggleButton click persists theme_mode=dark to window-layout.json'
    Assert ($script:controls.AppTitleBarBorder.Background.Color.ToString() -eq '#FF111114') 'Dark mode AppTitleBarBorder background hot-switches to #FF111114'
    Assert ($script:controls.LeftTaskRail.Background.Color.ToString() -eq '#FF111114') 'Dark mode LeftTaskRail background hot-switches to #FF111114'
    Assert ($script:controls.WorkspaceOuterBorder.Background.Color.ToString() -eq '#FF18181B') 'Dark mode WorkspaceOuterBorder background hot-switches to #FF18181B'
    Assert ($script:controls.KeyPopoverBorder.Background.Color.ToString() -eq '#FF18181B') 'Dark mode KeyPopoverBorder background hot-switches to #FF18181B'
    Assert ($script:controls.TopHeartbeatPillBorder.Background.Color.ToString() -eq '#FF3B1219') 'Dark mode TopHeartbeatPillBorder uses dark crimson #FF3B1219 instead of light pastel'
    Assert ($testPod.Tag.InputBox.Text -eq '深色模式切换不丢失草稿测试') 'Hot-switching theme preserves live ComposerPodHost draft text'
    Assert ($testPod.Tag.InputBox.Foreground.Color.ToString() -eq '#FFF4F4F5') 'Dark mode ComposerPodHost InputBox foreground hot-switches to #FFF4F4F5'

    # 9. Right-click UI event on ThemeToggleButton restores ThemeMode=system and shows QuickToast (Q5=A)
    $rightClickArgs = New-Object Windows.Input.MouseButtonEventArgs([Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Right)
    $rightClickArgs.RoutedEvent = [Windows.UIElement]::MouseRightButtonUpEvent
    $script:controls.ThemeToggleButton.RaiseEvent($rightClickArgs)
    Assert ($script:layout.ThemeMode -eq 'system' -and (Get-WindowLayoutMemory $script:context).ThemeMode -eq 'system') 'Right-clicking ThemeToggleButton restores system mode and persists it'
    Assert ($script:controls.QuickToastBorder.Visibility -eq 'Visible' -and $script:controls.QuickToastText.Text -match '跟随系统') 'Right-clicking ThemeToggleButton pops up QuickToast confirming system theme restore'

    # 10. Clicking ThemeDarkButton & ThemeSystemButton in Config Center Popover (Q1=A, Q2=B)
    $script:controls.ThemeDarkButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert ($script:layout.ThemeMode -eq 'dark' -and $script:effectiveTheme -eq 'dark') 'Clicking ThemeDarkButton sets ThemeMode=dark'
    Assert ($script:controls.QuickToastText.Text -match '深色模式') 'Clicking ThemeDarkButton shows dark mode QuickToast'

    # 11. Tray menu (including last Exit item) receives dark background/foreground & Reset-DefaultWindowLayout preserves ThemeMode
    $tray = Initialize-TrayContextMenu
    $lastTrayItem = $tray.Items[$tray.Items.Count - 1]
    Assert ($tray.BackColor.R -eq 24 -and $lastTrayItem.BackColor.R -eq 24 -and $lastTrayItem.ForeColor.R -eq 244 -and $script:trayItemThemeToggle.Text -match '浅色模式') 'All tray menu items including the final Exit item are styled in Dark Mode'

    Reset-DefaultWindowLayout
    Assert ($script:layout.ThemeMode -eq 'dark' -and (Get-WindowLayoutMemory $script:context).ThemeMode -eq 'dark' -and $script:effectiveTheme -eq 'dark') 'Reset-DefaultWindowLayout preserves saved ThemeMode=dark and keeps dark theme active'

    $script:controls.ThemeSystemButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert ($script:layout.ThemeMode -eq 'system' -and $script:trayItemThemeSystem.Checked -eq $true) 'Clicking ThemeSystemButton sets ThemeMode=system and checks tray system item'


    # 12. Decoupled Stall Time (30s test / 3m / 5m) and Retry Count (1 / 2 / 3) dropdowns with default 3m + 1 retry
    $defaultCfgCheck = Get-AutoResendConfig $script:context
    Assert ($defaultCfgCheck.StallMinutes -eq 3 -and $defaultCfgCheck.StallSeconds -eq 180 -and $defaultCfgCheck.MaxRetries -eq 1) 'Default Get-AutoResendConfig is StallMinutes=3 (180s) and MaxRetries=1'

    $freshSess = [pscustomobject]@{ SessionKey = 'tsk_decoupled_rule_test'; Title = '独立停顿与重试配置测试' }
    $podDecoupled = Build-PlanBComposerPod -SessionObj $freshSess -IsNarrow $false -IsZeroTask $false -PaneId 109
    $stallTags = @($podDecoupled.Tag.RuleCombo.Items | ForEach-Object { [string]$_.Tag })
    $stallLabels = @($podDecoupled.Tag.RuleCombo.Items | ForEach-Object { [string]$_.Content })
    $retryTags = @($podDecoupled.Tag.RetryCombo.Items | ForEach-Object { [string]$_.Tag })
    $retryLabels = @($podDecoupled.Tag.RetryCombo.Items | ForEach-Object { [string]$_.Content })

    Assert (($stallTags -join ',') -eq '30s,3,5' -and $stallLabels[0] -eq '停顿 30 秒 (测试)' -and $stallLabels[1] -eq '停顿 3 分钟' -and $stallLabels[2] -eq '停顿 5 分钟') 'Stall time dropdown offers exactly 3 tiers: 停顿 30 秒 (测试), 停顿 3 分钟, 停顿 5 分钟'
    Assert (($retryTags -join ',') -eq '1,2,3' -and $retryLabels[0] -eq '重试 1 次' -and $retryLabels[1] -eq '重试 2 次' -and $retryLabels[2] -eq '重试 3 次') 'Retry count dropdown offers exactly 3 tiers: 重试 1 次, 重试 2 次, 重试 3 次'
    Assert ([string]$podDecoupled.Tag.RuleCombo.SelectedItem.Tag -eq '3' -and [string]$podDecoupled.Tag.RetryCombo.SelectedItem.Tag -eq '1') 'Default selection is 停顿 3 分钟 and 重试 1 次'

    # Change Stall to 5m and Retry to 3 independently and verify persistence in session_bindings
    $podDecoupled.Tag.RuleCombo.SelectedIndex = 2
    $podDecoupled.Tag.RetryCombo.SelectedIndex = 2
    $savedBind = (Get-WebBridgeState $script:context).session_bindings.'tsk_decoupled_rule_test'
    Assert ($savedBind.stall_seconds -eq 300 -and $savedBind.stall_minutes -eq 5 -and $savedBind.max_retries -eq 3 -and $freshSess.StallSeconds -eq 300 -and $freshSess.MaxRetries -eq 3) 'Selecting 停顿 5 分钟 and 重试 3 次 independently persists stall_seconds=300 and max_retries=3'

    # 13. Smooth GPU Transition Animations, Cross-Narrow ComposerPod In-Place Reuse, and BitmapCache
    $podDecoupledNarrow = Build-PlanBComposerPod -SessionObj $freshSess -IsNarrow $true -IsZeroTask $false -PaneId 109
    Assert ([object]::ReferenceEquals($podDecoupled, $podDecoupledNarrow)) 'Build-PlanBComposerPod reuses the same ComposerPod instance across wide/narrow transitions without rebuilding'
    Assert ([string]$podDecoupledNarrow.Tag.RuleCombo.Items[0].Content -eq '30秒(测)' -and [string]$podDecoupledNarrow.Tag.RetryCombo.Items[0].Content -eq '1次' -and [string]$podDecoupledNarrow.Tag.BtnFollowSeg.Content -eq '原窗') 'In-place narrow mode sync updates RuleCombo, RetryCombo, and SegGroup labels cleanly'

    $podDecoupledWideAgain = Build-PlanBComposerPod -SessionObj $freshSess -IsNarrow $false -IsZeroTask $false -PaneId 109
    Assert ([object]::ReferenceEquals($podDecoupled, $podDecoupledWideAgain) -and [string]$podDecoupledWideAgain.Tag.RuleCombo.Items[0].Content -eq '停顿 30 秒 (测试)' -and [string]$podDecoupledWideAgain.Tag.RetryCombo.Items[0].Content -eq '重试 1 次' -and [string]$podDecoupledWideAgain.Tag.BtnFollowSeg.Content -eq '跟随原窗口') 'In-place wide mode sync restores full labels on the same ComposerPod instance'

    Toggle-KeyPopover
    Assert ($script:controls.KeyPopoverBorder.CacheMode -is [Windows.Media.BitmapCache]) 'Shadowed KeyPopoverBorder enables GPU BitmapCache for smooth entrance animation'
    Toggle-KeyPopover

    Split-PaneAfter ([int]$script:layout.Panes[0].id)
    $col0W = [double]$script:controls.PanesHostGrid.ColumnDefinitions[0].Width.Value
    $col2W = [double]$script:controls.PanesHostGrid.ColumnDefinitions[2].Width.Value
    Assert ($col0W -ge 30.0 -and $col2W -ge 30.0 -and $null -eq $script:paneAnimCtx) 'Split-PaneAfter sets target Star column widths in one shot without multi-frame GridLength timer thrashing'

    $script:controls.ThemeDarkButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert ($script:controls.QuickToastText.Text -eq '已切换为「深色模式」') 'Theme toggle QuickToast uses concise text without parenthetical hint'

    # 14. Ticket 06: 10-second Get-SystemThemePreference TTL cache (450ms IPC timer reads registry at most once per 10s)
    $script:regProbeCount = 0
    $probeSb = { $script:regProbeCount++; return 0 }
    $pref1 = Get-SystemThemePreference -RegistryProbe $probeSb -ResetCache
    for ($ti = 0; $ti -lt 9; $ti++) {
        $prefLoop = Get-SystemThemePreference -RegistryProbe $probeSb
        if ($prefLoop -ne 'dark') { throw "Unexpected cached theme pref: $prefLoop" }
    }
    Assert ($pref1 -eq 'dark' -and $script:regProbeCount -eq 1) "Get-SystemThemePreference 10s TTL cache executes registry probe only once across 10 rapid 450ms ticks (actual probes=$($script:regProbeCount))"

    # 15. Ticket 06: Platform naming unification (ChatGPT UI vs 4 official OpenAI contracts) & URL routing
    $gptMeta = Get-CapsulePlatformMeta 'openai'
    Assert ($gptMeta.Code -eq 'chatgpt' -and $gptMeta.Title -eq 'ChatGPT' -and $gptMeta.KeyLabel -eq 'OpenAI API Key (仅用于拉起本地 MCP 隧道)' -and $gptMeta.PlatText -eq '打开 OpenAI 隧道设置 ↗') 'Get-CapsulePlatformMeta normalizes openai->chatgpt with Title=ChatGPT while preserving official OpenAI API Key and OpenAI tunnel settings contracts'
    Assert ((Format-RelayLandingUrl -Provider 'chatgpt') -eq 'https://chatgpt.com/' -and (Format-RelayLandingUrl -Provider 'gemini') -eq 'https://gemini.google.com/app' -and (Format-RelayLandingUrl -Provider 'claude') -eq 'https://claude.ai/new') 'Format-RelayLandingUrl resolves exact platform landing URLs without trailing slash on /app or /new'
    $gemHoUrl = Format-RelayHandoverUrl -Provider 'gemini' -SessionKey 'tsk_t06'
    $cldHoUrl = Format-RelayHandoverUrl -Provider 'claude' -SessionKey 'tsk_t06'
    $gptHoUrl = Format-RelayHandoverUrl -Provider 'chatgpt' -SessionKey 'tsk_t06' -TargetModel 'gpt-6-thinking'
    Assert ($gemHoUrl -eq 'https://gemini.google.com/app?relay_handover=1&session_key=tsk_t06' -and $cldHoUrl -eq 'https://claude.ai/new?relay_handover=1&session_key=tsk_t06' -and $gptHoUrl -match '^https://chatgpt\.com/\?model=gpt-6-thinking&relay_handover=1') 'Format-RelayHandoverUrl avoids /app/? and /new/? while keeping root slash on chatgpt.com/?'

    # 16. Ticket 06: Retained-mode Render-PanesWorkspace & in-place Toggle-PaneSummary (zero PanesHostGrid.Children.Clear() on 2s polls)
    Close-PaneById ([int]$script:layout.Panes[1].id)
    $retainedSess = [pscustomobject]@{
        SessionKey = 'tsk_retained_ui_06'
        WfrId = 'tsk_retained_ui_06'
        ShortId = 'tsk_retained'
        Title = 'Retained UI 增量刷新验证'
        ShortTitle = 'Retained UI 验证'
        DotColor = '#16A34A'
        StatusBadge = '● 执行中'
        StatusFg = '#15803D'; StatusBg = '#F0FDF4'; StatusBorder = '#BBF7D0'
        VitalState = 'LIVE'
        VitalSubstate = 'THINKING'
        StepCountText = '1 / 3 步已完成'
        ProgressPercent = 33
        CommandCount = 2
        Steps = @(
            [pscustomobject]@{ Id = '1'; Title = '第一步'; Status = 'completed' },
            [pscustomobject]@{ Id = '2'; Title = '第二步'; Status = 'in_progress' },
            [pscustomobject]@{ Id = '3'; Title = '第三步'; Status = 'pending' }
        )
        ReadableCheckpoints = @()
        HumanDiagnosis = '正在执行第二步'
        LatestSummary = '正在执行第二步'
        IsStalled = $false
        IsArchived = $false
        AutoResendEnabled = $true
        AutoWakeupEnabled = $true
        StallMinutes = 3
        StallSeconds = 180
        MaxRetries = 1
        PendingQueue = @()
        PendingQueueCount = 0
        SentWebMessages = @()
    }
    $script:display.Sessions = @($retainedSess)
    $script:layout.Panes[0].session_key = 'tsk_retained_ui_06'
    $script:layout.Panes[0].show_summary = $false
    $script:lastCardsSig = ''
    $script:lastWorkspaceTopologySig = ''
    Update-SessionCards

    $pane0Before = $script:controls.PanesHostGrid.Children[0]
    $summaryCardRef = $pane0Before.Tag.SummaryCard
    Assert ($null -ne $summaryCardRef -and $summaryCardRef.Visibility -eq [Windows.Visibility]::Collapsed) 'Session pane pre-mounts CodexSummaryCard in Collapsed state'

    Toggle-PaneSummary ([int]$script:layout.Panes[0].id)
    Assert ($script:layout.Panes[0].show_summary -eq $true -and $summaryCardRef.Visibility -eq [Windows.Visibility]::Visible -and [object]::ReferenceEquals($pane0Before, $script:controls.PanesHostGrid.Children[0])) 'Toggle-PaneSummary flips SummaryCard.Visibility to Visible in-place without rebuilding PanesHostGrid'

    Toggle-PaneSummary ([int]$script:layout.Panes[0].id)
    Assert ($script:layout.Panes[0].show_summary -eq $false -and $summaryCardRef.Visibility -eq [Windows.Visibility]::Collapsed -and [object]::ReferenceEquals($pane0Before, $script:controls.PanesHostGrid.Children[0])) 'Toggle-PaneSummary flips SummaryCard.Visibility back to Collapsed in-place'

    # Mutate session fields and run Update-SessionCards (simulating 2s poll): PanesHostGrid.Children[0] must remain the exact same reference
    $retainedSess.ProgressPercent = 67
    $retainedSess.StepCountText = '2 / 3 步已完成'
    $retainedSess.CommandCount = 5
    $retainedSess.VitalSubstate = 'DUAL_STREAM'
    $retainedSess.HumanDiagnosis = '进入双流并发验证'
    Update-SessionCards
    $pane0AfterPoll = $script:controls.PanesHostGrid.Children[0]
    $streamRefsAfter = $pane0AfterPoll.Tag.StreamHost.Tag
    Assert ([object]::ReferenceEquals($pane0Before, $pane0AfterPoll) -and $streamRefsAfter.StepPillText.Text -match '2 / 3 步' -and $streamRefsAfter.StatusLabel.Text -match '双流' -and $streamRefsAfter.DiagTextBlock.Text -eq '进入双流并发验证') '2s background poll updates pane step progress, status pill, and diagnosis text in-place without clearing PanesHostGrid.Children'

    # 17. Ticket 06: Open Popover & Global Settings freeze during Refresh-FormState
    Toggle-KeyPopover
    Assert ($script:popoverOpen -eq $true) 'KeyPopover is open before background Refresh-FormState'
    $profChild0Before = $script:controls.ProfilesListPanel.Children[0]
    Refresh-FormState
    Assert ([object]::ReferenceEquals($profChild0Before, $script:controls.ProfilesListPanel.Children[0])) 'Refresh-FormState skips Refresh-ProfilePopoverState when KeyPopover is open, preserving ProfilesListPanel child references'
    Close-AllTopPopovers

    Toggle-GlobalSettingsPopover
    Assert ($script:globalSettingsOpen -eq $true) 'GlobalSettingsPopover is open before background Refresh-FormState'
    $carrierItem0Before = $script:controls.DefaultCarrierCombo.Items[0]
    Refresh-FormState
    Assert ([object]::ReferenceEquals($carrierItem0Before, $script:controls.DefaultCarrierCombo.Items[0])) 'Refresh-FormState skips Refresh-ProfilePopoverState when GlobalSettingsPopover is open, preserving DefaultCarrierCombo item references'
    Close-AllTopPopovers

    # 18. Ticket 06: End-to-end 3-dropdown atomic linkage & carrier_by_provider persistence in Build-PlanBComposerPod
    [void](Invoke-SelectOrAddCapsulePlatform 'gemini')
    [void](Invoke-SelectOrAddCapsulePlatform 'claude')
    Close-AllTopPopovers
    $script:composerPodCache.Clear()
    $retainedSess | Add-Member -NotePropertyName 'CarrierByProvider' -NotePropertyValue @{ chatgpt = 'Desktop:ChatGPT'; gemini = 'Edge:Default' } -Force
    $podMulti = Build-PlanBComposerPod -SessionObj $retainedSess -IsNarrow $false -IsZeroTask $false -PaneId 101
    $geminiDefaultItem = @($podMulti.Tag.ModelCombo.Items | Where-Object { [string]$_.ToolTip -eq 'gemini' -and [string]$_.Tag -eq 'inherit' }) | Select-Object -First 1
    $geminiGroupHeader = @($podMulti.Tag.ModelCombo.Items | Where-Object { [string]$_.Tag -eq '__group_gemini' }) | Select-Object -First 1
    Assert ($null -ne $geminiDefaultItem -and [string]$geminiDefaultItem.Content -eq '🤖 Gemini · 默认 (跟随网页)' -and $null -ne $geminiGroupHeader -and [string]$geminiGroupHeader.Content -eq '▾ Gemini') 'Multi-platform ComposerPod exposes clean ▾ Gemini group header and 🤖 Gemini · 默认 (跟随网页) default item'
    $podMulti.Tag.ModelCombo.SelectedItem = $geminiDefaultItem
    $wbAfterGemSwitch = Get-WebBridgeState $script:context
    $gemBind = $wbAfterGemSwitch.session_bindings.'tsk_retained_ui_06'
    $profComboTagsAfterGem = @($podMulti.Tag.ProfCombo.Items | ForEach-Object { [string]$_.Tag })
    Assert ($podMulti.Tag.Provider -eq 'gemini' -and $podMulti.Tag.EffortCombo.IsEnabled -eq $false -and [string]$podMulti.Tag.EffortCombo.Items[0].Content -eq '🧠 跟随网页设置' -and ($profComboTagsAfterGem -notcontains 'Desktop:ChatGPT') -and $gemBind.provider -eq 'gemini' -and $null -ne $gemBind.carrier_by_provider) 'Selecting Gemini model in ModelCombo atomically updates Provider, disables EffortCombo, excludes Desktop:ChatGPT from ProfCombo, and persists provider + carrier_by_provider'
    $podMulti.Tag.ModelCombo.SelectedItem = $geminiGroupHeader
    Assert ([string]$podMulti.Tag.ModelCombo.SelectedItem.Tag -notlike '__group_*' -and [object]::ReferenceEquals($podMulti.Tag.ModelCombo.SelectedItem, $geminiDefaultItem)) 'Group header item (__group_gemini) is non-selectable and immediately snaps back to the active selectable item'

    Write-Host (@{ result = 'PASS'; assertions = $script:assertions } | ConvertTo-Json -Compress)
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
