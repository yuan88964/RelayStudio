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

    Write-Host (@{ result = 'PASS'; assertions = $script:assertions } | ConvertTo-Json -Compress)
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
