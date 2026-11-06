# Offline WPF contract test for per-model reasoning effort selection & Ticket 06 multi-platform composer linkage.
# Usage: powershell.exe -NoProfile -Sta -File tests/Test-ReasoningEffort.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework

$root = Split-Path $PSScriptRoot -Parent
$source = [IO.File]::ReadAllText((Join-Path $root '连接管理.ps1'), [Text.Encoding]::UTF8)
$start = $source.IndexOf('function Set-SessionPropSafe(')
$end = $source.IndexOf('function Build-PlanBComposerPod(', $start)
if ($start -lt 0 -or $end -le $start) { throw 'Unable to find composer public UI synchronization seam' }
. ([scriptblock]::Create($source.Substring($start, $end - $start)))

$script:context = [pscustomobject]@{ TestOnly = $true; Isolated = $true }
$script:suppressComposerEvents = $false
$script:saved = [System.Collections.Generic.List[object]]::new()
$script:passed = 0

# Capture persistence at the public UI->config seam; never open production files.
function Set-TaskComposerConfig {
    param(
        $Context,
        [string]$SessionKey,
        [string]$TargetMode = '',
        [string]$BrowserProfile = '',
        [string]$TargetModel = '',
        [string]$ReasoningEffort = '',
        [string]$Provider = '',
        [hashtable]$CarrierByProvider = $null
    )
    $script:saved.Add([pscustomobject]@{
        session_key = $SessionKey
        target_mode = $TargetMode
        browser_profile = $BrowserProfile
        target_model = $TargetModel
        reasoning_effort = $ReasoningEffort
        provider = $Provider
        carrier_by_provider = $CarrierByProvider
    })
    return [pscustomobject]@{ ok = $true }
}
function Assert-Case([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw "FAIL: $Label" }
    $script:passed++
    Write-Output "PASS $Label"
}
function Make-State([string]$TaskKey = 'offline_reasoning_test') {
    return [pscustomobject]@{
        TaskKey = $TaskKey
        Session = [pscustomobject]@{ ReasoningEffort = 'inherit' }
        ModelCombo = [Windows.Controls.ComboBox]::new()
        EffortCombo = [Windows.Controls.ComboBox]::new()
        ProfCombo = [Windows.Controls.ComboBox]::new()
        LastCatalogSig = ''
        AvailableModels = @()
        Provider = 'chatgpt'
        ConnectedProviders = $null
        AvailableCarriers = @()
        CollapsedProviders = @{}
        CarrierByProvider = @{}
        MutationEpoch = [DateTime]::MinValue
    }
}
function Get-Tags($Combo) { return @($Combo.Items | ForEach-Object { [string]$_.Tag }) }
function Sync-Test($State, $Models, [string]$Model, [string]$Effort, [string]$WebEffort='标准') {
    Sync-ComposerModelAndEffortCombos -StateInfo $State -AvailModels $Models -CurModel $Model -WebModel 'gpt-6-thinking' -CurEffort $Effort -WebEffort $WebEffort -IsNarrow $false
}
$catalog = @(
    [pscustomobject]@{ slug='gpt-6-thinking'; title='GPT-6 Thinking'; efforts=@('light','standard','extended','max') },
    [pscustomobject]@{ slug='gpt-6-pro'; title='GPT-6 Pro'; efforts=@('standard','max') },
    [pscustomobject]@{ slug='gpt-6-fast'; title='GPT-6 Fast'; efforts=@() }
)
$state = Make-State
Sync-Test $state $catalog 'gpt-6-thinking' 'light' '思考强度 标准'
$tags = Get-Tags $state.EffortCombo
Assert-Case ($tags.Count -eq 5 -and ($tags -join ',') -eq 'inherit,light,standard,extended,max') 'Thinking model exposes precisely the four raw official English effort IDs plus inherit'
Assert-Case ([string]$state.EffortCombo.SelectedItem.Tag -eq 'light') 'Previously selected valid light effort remains selected'
Assert-Case ([string]$state.EffortCombo.Items[0].Content -eq '🧠 默认 (standard)') 'Inherit displays the normalized raw English web effort ID'

$script:saved.Clear()
Sync-Test $state $catalog 'gpt-6-pro' 'light' 'standard'
$tags = Get-Tags $state.EffortCombo
Assert-Case (($tags -join ',') -eq 'inherit,standard,max') 'Changing model removes unsupported light and extended choices'
Assert-Case ([string]$state.EffortCombo.SelectedItem.Tag -eq 'inherit') 'Changing model resets unsupported selected effort to inherit'
Assert-Case ($script:saved.Count -eq 1 -and $script:saved[0].reasoning_effort -eq 'inherit' -and $script:saved[0].session_key -eq 'offline_reasoning_test' -and $state.Session.ReasoningEffort -eq 'inherit') 'Invalid effort reset persists to task config and session snapshot'

# Background poll (-FromBackgroundPoll) must be strictly read-only and never write to Set-TaskComposerConfig
$script:saved.Clear()
Sync-ComposerModelAndEffortCombos -StateInfo $state -AvailModels $catalog -CurModel 'gpt-6-pro' -WebModel 'gpt-6-thinking' -CurEffort 'light' -WebEffort 'standard' -IsNarrow $false -FromBackgroundPoll
Assert-Case ([string]$state.EffortCombo.SelectedItem.Tag -eq 'inherit' -and $script:saved.Count -eq 0) 'Sync-ComposerModelAndEffortCombos -FromBackgroundPoll normalizes unsupported effort in memory without triggering Set-TaskComposerConfig disk/HTTP write'

$script:saved.Clear()
Sync-Test $state $catalog 'gpt-6-pro' 'max' 'standard'
Assert-Case ([string]$state.EffortCombo.SelectedItem.Tag -eq 'max' -and $script:saved.Count -eq 0) 'Valid raw max effort persists unchanged for selected model'
$firstItem = $state.EffortCombo.Items[0]
Sync-Test $state $catalog 'gpt-6-pro' 'standard' 'standard'
Assert-Case ([object]::ReferenceEquals($firstItem,$state.EffortCombo.Items[0]) -and [string]$state.EffortCombo.SelectedItem.Tag -eq 'standard') 'Same catalog does not rebuild options but can update selection'

$script:saved.Clear()
Sync-Test $state $catalog 'gpt-6-fast' 'max' 'standard'
Assert-Case ($state.EffortCombo.Items.Count -eq 1 -and [string]$state.EffortCombo.SelectedItem.Tag -eq 'inherit') 'Fixed effort model forbids manual reasoning effort override'
Assert-Case ($script:saved.Count -eq 1 -and $script:saved[0].reasoning_effort -eq 'inherit') 'Switching to fixed model removes previously saved explicit override'

$unknownCatalog = @(
    [pscustomobject]@{ slug='gpt-6'; title='GPT-6'; efforts=@() },
    [pscustomobject]@{ slug='gpt-6-thinking'; title='GPT-6'; efforts=@() },
    [pscustomobject]@{ slug='gpt-6-instant'; title='GPT-6'; efforts=@() }
)
Sync-Test $state $unknownCatalog 'gpt-6' '深度'
$unknownTags = Get-Tags $state.EffortCombo
Assert-Case ($unknownTags.Count -eq 5 -and ($unknownTags -join ',') -eq 'inherit,min,standard,extended,max' -and [string]$state.EffortCombo.SelectedItem.Tag -eq 'extended') 'Reasoning model with missing catalog metadata exposes raw English fallback and migrates legacy Chinese 深度 -> extended'
Sync-Test $state $catalog 'gpt-6-thinking' 'high'
Assert-Case ([string]$state.EffortCombo.SelectedItem.Tag -eq 'extended') 'Legacy high effort is normalized to raw official extended ID'

# Scheme A: Pure official raw English effort IDs even when OpenAI backend short_label contains 深入
$realOpenAiCatalog = @(
    [pscustomobject]@{
        slug = 'gpt-6-thinking'
        title = 'GPT-6'
        default_effort = 'min'
        configurable_effort = $true
        efforts = @('min', 'standard', 'extended', 'max')
        effort_items = @(
            [pscustomobject]@{ id = 'min'; label = '轻度'; full_label = '快速思考' },
            [pscustomobject]@{ id = 'standard'; label = '标准'; full_label = '思考中' },
            [pscustomobject]@{ id = 'extended'; label = '深度'; full_label = '进阶思考' },
            [pscustomobject]@{ id = 'max'; label = '深入'; full_label = '深度思考' }
        )
    },
    [pscustomobject]@{
        slug = 'gpt-6-instant'
        title = 'GPT-6 Instant'
        configurable_effort = $false
        efforts = @()
        effort_items = @()
    },
    [pscustomobject]@{
        slug = 'gpt-6-mini'
        title = 'GPT-6 Mini'
        configurable_effort = $false
        efforts = @()
        effort_items = @()
    }
)
$realState = Make-State 'real_openai_effort_test'
Sync-Test $realState $realOpenAiCatalog 'gpt-6-thinking' '最高' 'min'
$realTags = Get-Tags $realState.EffortCombo
$realContents = @($realState.EffortCombo.Items | ForEach-Object { [string]$_.Content })
Assert-Case (($realTags -join ',') -eq 'inherit,min,standard,extended,max' -and ($realContents -join '|') -notmatch '深入|轻度|最高') 'Scheme A renders pure raw English IDs (min,standard,extended,max) and never leaks backend short_label 深入'
Assert-Case ([string]$realState.EffortCombo.Items[0].Content -eq '🧠 默认 (min)') 'Inherit renders pure raw English ID 🧠 默认 (min)'
Assert-Case ([string]$realState.EffortCombo.SelectedItem.Tag -eq 'max') 'Legacy saved 最高 smoothly migrates to raw official max ID'

Sync-Test $realState $realOpenAiCatalog 'gpt-6-thinking' 'inherit' '极高 ⌄'
Assert-Case ([string]$realState.EffortCombo.Items[0].Content -eq '🧠 默认 (max)') 'Live webpage composer pill text 极高 ⌄ resolves to raw official max ID'

Sync-Test $realState $realOpenAiCatalog 'gpt-6-mini' 'max' ''
Assert-Case ($realState.EffortCombo.Items.Count -eq 1 -and [string]$realState.EffortCombo.SelectedItem.Tag -eq 'inherit') 'Model with configurable_effort=false and no thinking sibling locks to fixed effort without inventing fake tiers'

Sync-Test $realState $realOpenAiCatalog 'gpt-6-instant' 'inherit' '未开启思考'
$instantTags = Get-Tags $realState.EffortCombo
Assert-Case (($instantTags -join ',') -eq 'inherit,none,min,standard,extended,max' -and [string]$realState.EffortCombo.Items[0].Content -eq '🧠 默认 (none)') 'Instant model borrows sibling gpt-6-thinking raw English effort IDs plus none'

# Hazard 5: Cold-start with zero web models must render ONLY "默认 (跟随网页)" in both ModelCombo and EffortCombo
$coldState = Make-State 'cold_start_pure_default_test'
Sync-ComposerModelAndEffortCombos -StateInfo $coldState -AvailModels @() -CurModel 'inherit' -WebModel '' -CurEffort 'inherit' -WebEffort '' -IsNarrow $false
Assert-Case ($coldState.ModelCombo.Items.Count -eq 1 -and [string]$coldState.ModelCombo.Items[0].Content -eq '🤖 默认 (跟随网页)' -and [string]$coldState.ModelCombo.Items[0].Tag -eq 'inherit') 'Cold start with no web models renders only a single 🤖 默认 (跟随网页) item in ModelCombo'
Assert-Case ($coldState.EffortCombo.Items.Count -eq 1 -and [string]$coldState.EffortCombo.Items[0].Content -eq '🧠 默认 (跟随网页)' -and [string]$coldState.EffortCombo.Items[0].Tag -eq 'inherit') 'Cold start with no web models renders only a single 🧠 默认 (跟随网页) item in EffortCombo without fallback min/standard/extended/max tiers'

# Multi-platform capsule grouping in ModelCombo (ChatGPT naming unification + default item under each group header + pure ▾/▸ folding)
$script:profilesState = [pscustomobject]@{
    ActiveProfileId = 'prof_1'
    EnabledPlatforms = @('openai', 'claude')
    ActiveProfileByPlatform = @{ chatgpt = 'prof_1'; claude = 'prof_claude_1' }
    Profiles = @(
        [pscustomobject]@{ Id = 'prof_1'; Name = '主力隧道'; Platform = 'openai'; Kind = 'tunnel'; TunnelId = 'ab12cd34'; HasKey = $true; Enabled = $true; IsActive = $true },
        [pscustomobject]@{ Id = 'prof_claude_1'; Name = '默认'; Platform = 'claude'; Kind = 'public_tunnel'; TunnelId = ''; HasKey = $false; Enabled = $false; IsActive = $true }
    )
}
$multiPlatState = Make-State 'multi_platform_cold_start_test'
Sync-ComposerModelAndEffortCombos -StateInfo $multiPlatState -AvailModels @() -CurModel 'inherit' -WebModel '' -CurEffort 'inherit' -WebEffort '' -IsNarrow $false
$multiContents = @($multiPlatState.ModelCombo.Items | ForEach-Object { [string]$_.Content })
$groupItems = @($multiPlatState.ModelCombo.Items | Where-Object { [string]$_.Tag -like '__group_*' })
Assert-Case ([string]$multiPlatState.ModelCombo.Items[0].Tag -eq '__group_chatgpt' -and [string]$multiPlatState.ModelCombo.Items[1].Tag -eq 'inherit' -and [string]$multiPlatState.ModelCombo.Items[1].ToolTip -eq 'chatgpt' -and [string]$multiPlatState.ModelCombo.Items[2].Tag -eq '__group_claude' -and [string]$multiPlatState.ModelCombo.Items[3].Tag -eq 'inherit' -and [string]$multiPlatState.ModelCombo.Items[3].ToolTip -eq 'claude') 'Multi-platform ModelCombo places each platform default item directly under its respective platform group header'
Assert-Case ($groupItems.Count -eq 2 -and [string]$groupItems[0].Content -eq '▾ 🟢 ChatGPT · 主力隧道' -and [string]$groupItems[1].Content -eq '▾ ⚪ Claude · 默认') 'Multi-platform ModelCombo normalizes OpenAI -> ChatGPT and renders pure ▾ icon + breathing status headers (🟢/⚪)'
$selectableItems = @($multiPlatState.ModelCombo.Items | Where-Object { [string]$_.Tag -notlike '__group_*' })
Assert-Case ($selectableItems.Count -eq 2 -and (@($selectableItems | Where-Object { [string]$_.Content -ne '🤖 默认 (跟随网页)' -or [string]$_.Tag -ne 'inherit' }).Count -eq 0)) 'Cold start multi-platform ModelCombo contains only 🤖 默认 (跟随网页) (Tag=inherit) under each enabled platform without fake models'

# Pure arrow (▾ / ▸) in-place group folding without (已折叠) text
Toggle-ComposerModelGroupFold $multiPlatState 'chatgpt'
Assert-Case ([string]$multiPlatState.ModelCombo.Items[0].Content -eq '▸ 🟢 ChatGPT · 主力隧道' -and [string]$multiPlatState.ModelCombo.Items[0].Content -notmatch '折叠' -and $multiPlatState.ModelCombo.Items[1].Visibility -eq [Windows.Visibility]::Collapsed -and $multiPlatState.ModelCombo.Items[3].Visibility -eq [Windows.Visibility]::Visible) 'Toggle-ComposerModelGroupFold collapses ChatGPT group items in-place with pure ▸ icon and zero (已折叠) text'
Toggle-ComposerModelGroupFold $multiPlatState 'chatgpt'
Assert-Case ([string]$multiPlatState.ModelCombo.Items[0].Content -eq '▾ 🟢 ChatGPT · 主力隧道' -and $multiPlatState.ModelCombo.Items[1].Visibility -eq [Windows.Visibility]::Visible) 'Toggle-ComposerModelGroupFold expands ChatGPT group items back to Visible with ▾ icon'

$multiPlatState | Add-Member -NotePropertyName 'TunnelOnline' -NotePropertyValue $false -Force
Sync-ComposerModelAndEffortCombos -StateInfo $multiPlatState -AvailModels @() -CurModel 'inherit' -WebModel '' -CurEffort 'inherit' -WebEffort '' -IsNarrow $false
$offlineContents = @($multiPlatState.ModelCombo.Items | ForEach-Object { [string]$_.Content })
Assert-Case (($offlineContents -join '|') -match '▾ ⚪ ChatGPT · 主力隧道') 'Multi-platform ModelCombo dynamically updates ChatGPT group dot to ⚪ when tunnel goes offline'
$script:profilesState = $null

# Option A for Gemini/Claude model lists: strictly expose only 🤖 默认 (跟随网页) under Gemini/Claude groups
$multi = Make-State 'multi'
$multi | Add-Member ProfilesState ([pscustomobject]@{
    EnabledPlatforms = @('chatgpt', 'gemini', 'claude')
    Profiles = @(
        [pscustomobject]@{ Id = 'p_gpt'; Name = '主力隧道'; Platform = 'chatgpt'; Kind = 'tunnel'; TunnelId = 'ab12cd34'; HasKey = $true; Enabled = $true; IsActive = $true },
        [pscustomobject]@{ Id = 'p_gem'; Name = '默认'; Platform = 'gemini'; Kind = 'public_tunnel'; Enabled = $true; IsActive = $true },
        [pscustomobject]@{ Id = 'p_cld'; Name = '默认'; Platform = 'claude'; Kind = 'public_tunnel'; Enabled = $false; IsActive = $true }
    )
})
$multi | Add-Member PublicTunnelOnline $true
$multi | Add-Member AvailableModelsByProvider ([pscustomobject]@{
    chatgpt = $catalog
    gemini  = @([pscustomobject]@{ slug = 'gemini-pro'; title = 'Gemini Pro'; efforts = @() })
    claude  = @([pscustomobject]@{ slug = 'claude-sonnet-4'; title = 'Claude Sonnet 4'; efforts = @() })
})
Sync-Test $multi $catalog 'inherit' 'inherit'
$multiHdrs = @($multi.ModelCombo.Items | Where-Object { [string]$_.Tag -like '__group_*' } | ForEach-Object { [string]$_.Content })
Assert-Case (($multiHdrs -contains '▾ 🟢 Gemini · 默认') -and ($multiHdrs -contains '▾ ⚪ Claude · 默认')) 'Gemini and Claude group header dots reflect PublicTunnelOnline + profile Enabled state'
$geminiItems = @($multi.ModelCombo.Items | Where-Object { [string]$_.ToolTip -eq 'gemini' })
$claudeItems = @($multi.ModelCombo.Items | Where-Object { [string]$_.ToolTip -eq 'claude' })
Assert-Case ($geminiItems.Count -eq 1 -and [string]$geminiItems[0].Tag -eq 'inherit' -and [string]$geminiItems[0].Content -eq '🤖 默认 (跟随网页)') 'Option A: Gemini group strictly exposes only 🤖 默认 (跟随网页) without fragile DOM-scraped models'
Assert-Case ($claudeItems.Count -eq 1 -and [string]$claudeItems[0].Tag -eq 'inherit' -and [string]$claudeItems[0].Content -eq '🤖 默认 (跟随网页)') 'Option A: Claude group strictly exposes only 🤖 默认 (跟随网页) without fragile DOM-scraped models'

# 2nd Dropdown (EffortCombo) cross-platform linkage for Gemini & Claude
$multi.Provider = 'gemini'
Sync-Test $multi $catalog 'inherit' 'inherit'
Assert-Case ($multi.EffortCombo.IsEnabled -eq $false -and $multi.EffortCombo.Items.Count -eq 1 -and [string]$multi.EffortCombo.Items[0].Content -eq '🧠 跟随网页设置' -and [string]$multi.EffortCombo.SelectedItem.Tag -eq 'inherit' -and [string]$multi.ModelCombo.SelectedItem.ToolTip -eq 'gemini') 'Switching Provider to gemini locks EffortCombo to disabled 🧠 跟随网页设置 and selects Gemini default item'
$multi.Provider = 'claude'
Sync-Test $multi $catalog 'inherit' 'inherit'
Assert-Case ($multi.EffortCombo.IsEnabled -eq $false -and $multi.EffortCombo.Items.Count -eq 1 -and [string]$multi.EffortCombo.Items[0].Content -eq '🧠 跟随网页设置' -and [string]$multi.ModelCombo.SelectedItem.ToolTip -eq 'claude') 'Switching Provider to claude locks EffortCombo to disabled 🧠 跟随网页设置 and selects Claude default item'
$multi.Provider = 'chatgpt'
Sync-Test $multi $catalog 'gpt-6-thinking' 'extended'
Assert-Case ($multi.EffortCombo.IsEnabled -eq $true -and $multi.EffortCombo.Items.Count -eq 5 -and [string]$multi.EffortCombo.SelectedItem.Tag -eq 'extended') 'Switching Provider back to chatgpt re-enables EffortCombo and restores ChatGPT effort tiers'

# 3rd Dropdown (ProfCombo / Target Carrier) filtering & carrier_by_provider memory
$mockCarriers = @(
    [pscustomobject]@{ Id = 'Desktop:ChatGPT'; Label = '💻 ChatGPT 桌面端'; IsDefault = $true },
    [pscustomobject]@{ Id = 'Chrome:Default';  Label = '🌐 Chrome · 默认';   IsDefault = $false },
    [pscustomobject]@{ Id = 'Edge:Profile 1';  Label = '🌐 Edge · 工作配置'; IsDefault = $false }
)
$multi.AvailableCarriers = $mockCarriers
$multi.CarrierByProvider = @{
    chatgpt = 'Desktop:ChatGPT'
    gemini  = 'Edge:Profile 1'
    claude  = 'Chrome:Default'
}
$multi.Provider = 'chatgpt'
$resolvedC1 = Sync-ComposerCarrierCombo -StateInfo $multi -AvailCarriers $mockCarriers
$carrierTagsChatGpt = Get-Tags $multi.ProfCombo
Assert-Case ($resolvedC1 -eq 'Desktop:ChatGPT' -and ($carrierTagsChatGpt -contains 'Desktop:ChatGPT') -and [string]$multi.ProfCombo.SelectedItem.Tag -eq 'Desktop:ChatGPT') 'ChatGPT provider includes Desktop:ChatGPT carrier and selects remembered Desktop:ChatGPT'

$multi.Provider = 'gemini'
$resolvedC2 = Sync-ComposerCarrierCombo -StateInfo $multi -AvailCarriers $mockCarriers
$carrierTagsGemini = Get-Tags $multi.ProfCombo
Assert-Case ($resolvedC2 -eq 'Edge:Profile 1' -and ($carrierTagsGemini -notcontains 'Desktop:ChatGPT') -and [string]$multi.ProfCombo.SelectedItem.Tag -eq 'Edge:Profile 1') 'Gemini provider filters out Desktop:ChatGPT and restores remembered Edge:Profile 1 from carrier_by_provider'

$multi.Provider = 'claude'
$resolvedC3 = Sync-ComposerCarrierCombo -StateInfo $multi -AvailCarriers $mockCarriers
$carrierTagsClaude = Get-Tags $multi.ProfCombo
Assert-Case ($resolvedC3 -eq 'Chrome:Default' -and ($carrierTagsClaude -notcontains 'Desktop:ChatGPT') -and [string]$multi.ProfCombo.SelectedItem.Tag -eq 'Chrome:Default') 'Claude provider filters out Desktop:ChatGPT and restores remembered Chrome:Default from carrier_by_provider'

# Optimistic 3s MutationEpoch lock verification
Register-ComposerOptimisticMutation $multi
Assert-Case ((Test-ComposerOptimisticLockActive $multi) -eq $true) 'Register-ComposerOptimisticMutation activates 3-second optimistic lock on composer state'
$multi.MutationEpoch = [DateTime]::UtcNow.AddSeconds(-4)
Assert-Case ((Test-ComposerOptimisticLockActive $multi) -eq $false) 'Test-ComposerOptimisticLockActive expires cleanly after 3 seconds'

$multi.ConnectedProviders = @()
Sync-Test $multi $catalog 'inherit' 'inherit'
Assert-Case (@(Get-Tags $multi.ModelCombo) -notcontains 'gpt-6-thinking') 'All-disconnected platform set hides cached ChatGPT models'

$helperStart = $source.IndexOf('function Resolve-ComposerCatalogState(')
$helperEnd = $source.IndexOf('function Build-PlanBComposerPod(', $helperStart)
. ([scriptblock]::Create($source.Substring($helperStart, $helperEnd - $helperStart)))
function Get-WebRoomProvider($Record) { if ($Record.provider) { Resolve-UiPlatformCode ([string]$Record.provider) } else { 'chatgpt' } }
$raw = [pscustomobject]@{available_models_by_provider=$multi.AvailableModelsByProvider;tabs=[pscustomobject]@{fresh=[pscustomobject]@{provider='gemini';last_seen_at=[DateTimeOffset]::UtcNow.ToString('o')};stale=[pscustomobject]@{provider='claude';last_seen_at=[DateTimeOffset]::UtcNow.AddSeconds(-30).ToString('o')}}}
$resolved = Resolve-ComposerCatalogState $null $raw
Assert-Case ($resolved.connected_providers -contains 'gemini' -and $resolved.connected_providers -notcontains 'claude') 'Launchpad production extraction derives fresh platform availability from raw tabs'
$session = [pscustomobject]@{AvailableModelsByProvider=$multi.AvailableModelsByProvider;ConnectedProviders=@('claude')}
$resolvedSession = Resolve-ComposerCatalogState $session $null
Assert-Case ($resolvedSession.connected_providers -contains 'claude' -and $resolvedSession.available_models_by_provider.gemini.Count -eq 1) 'Task production extraction uses snapshot session model and availability metadata'

$productionState = Make-State 'production-shaped'
$productionState | Add-Member ProfilesState ([pscustomobject]@{EnabledPlatforms=@('openai','gemini','claude');Profiles=@()})
$productionState | Add-Member AvailableModelsByProvider $resolved.available_models_by_provider
$productionState.ConnectedProviders = @($resolved.connected_providers)
$legacySession = [pscustomobject]@{AvailableModels=$catalog;AvailableModelsByProvider=$null}
$legacyCatalog = Resolve-ComposerCatalogState $legacySession $null
$productionState.AvailableModelsByProvider = $legacyCatalog.available_models_by_provider
$productionState.ConnectedProviders = $legacyCatalog.connected_providers
Sync-Test $productionState $catalog 'inherit' 'inherit'
Assert-Case ($null -eq $legacyCatalog.connected_providers -and @(Get-Tags $productionState.ModelCombo) -contains 'gpt-6-thinking') 'Legacy snapshots without availability metadata retain ChatGPT catalog compatibility'

$productionState.ConnectedProviders = @()
Sync-Test $productionState $catalog 'inherit' 'inherit'
Assert-Case (@(Get-Tags $productionState.ModelCombo) -notcontains 'gpt-6-thinking') 'Unknown to explicitly disconnected transition invalidates model display cache'

Write-Output ('{"result":"PASS","assertions":' + $script:passed + ',"network":"OFFLINE_FAKE_ONLY","production_config_written":false}')
