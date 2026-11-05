# Offline WPF contract test for per-model reasoning effort selection.
# Usage: pwsh -NoProfile -Sta -File tests/Test-ReasoningEffort.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework

$root = Split-Path $PSScriptRoot -Parent
$source = [IO.File]::ReadAllText((Join-Path $root '连接管理.ps1'), [Text.Encoding]::UTF8)
$start = $source.IndexOf('function Set-SessionPropSafe(')
$end = $source.IndexOf('function Build-PlanBComposerPod(', $start)
if ($start -lt 0 -or $end -le $start) { throw 'Unable to find composer public UI synchronization seam' }
. ([scriptblock]::Create($source.Substring($start, $end - $start)))

$script:context = [pscustomobject]@{ TestOnly = $true }
$script:suppressComposerEvents = $false
$script:saved = [System.Collections.Generic.List[object]]::new()
$script:passed = 0

# Capture persistence at the public UI->config seam; never open production files.
function Set-TaskComposerConfig {
    param($Context, [string]$SessionKey, [string]$ReasoningEffort)
    $script:saved.Add([pscustomobject]@{ session_key = $SessionKey; reasoning_effort = $ReasoningEffort })
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
        LastCatalogSig = ''
        AvailableModels = @()
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

# Multi-platform capsule grouping in ModelCombo
$script:profilesState = [pscustomobject]@{
    ActiveProfileId = 'prof_1'
    EnabledPlatforms = @('openai', 'claude')
    ActiveProfileByPlatform = @{ openai = 'prof_1'; claude = 'prof_claude_1' }
    Profiles = @(
        [pscustomobject]@{ Id = 'prof_1'; Name = '主力隧道'; Platform = 'openai'; Kind = 'tunnel'; TunnelId = 'ab12cd34'; HasKey = $true; Enabled = $true; IsActive = $true },
        [pscustomobject]@{ Id = 'prof_claude_1'; Name = '默认'; Platform = 'claude'; Kind = 'apikey'; TunnelId = ''; HasKey = $false; Enabled = $false; IsActive = $true }
    )
}
$multiPlatState = Make-State 'multi_platform_cold_start_test'
Sync-ComposerModelAndEffortCombos -StateInfo $multiPlatState -AvailModels @() -CurModel 'inherit' -WebModel '' -CurEffort 'inherit' -WebEffort '' -IsNarrow $false
$firstDefaultRef = $multiPlatState.ModelCombo.Items[0]
$multiContents = @($multiPlatState.ModelCombo.Items | ForEach-Object { [string]$_.Content })
$groupItems = @($multiPlatState.ModelCombo.Items | Where-Object { -not $_.IsEnabled })
Assert-Case ([string]$firstDefaultRef.Tag -eq 'inherit' -and [string]$firstDefaultRef.Content -eq '🤖 默认 (跟随网页)') 'Multi-platform ModelCombo keeps Items[0] as the primary inherit option'
Assert-Case ($groupItems.Count -eq 2 -and ($multiContents -join '|') -match '🟢 OpenAI · 主力隧道' -and ($multiContents -join '|') -match '⚪ Claude · 默认') 'Multi-platform ModelCombo renders breathing status headers (🟢/⚪) corresponding to enabled capsule platforms'
$selectableItems = @($multiPlatState.ModelCombo.Items | Where-Object { $_.IsEnabled })
Assert-Case ($selectableItems.Count -eq 2 -and (@($selectableItems | Where-Object { [string]$_.Content -ne '🤖 默认 (跟随网页)' -or [string]$_.Tag -ne 'inherit' }).Count -eq 0)) 'Cold start multi-platform ModelCombo contains only 🤖 默认 (跟随网页) (Tag=inherit) under each enabled platform without fake models'
$multiPlatState | Add-Member -NotePropertyName 'TunnelOnline' -NotePropertyValue $false -Force
Sync-ComposerModelAndEffortCombos -StateInfo $multiPlatState -AvailModels @() -CurModel 'inherit' -WebModel '' -CurEffort 'inherit' -WebEffort '' -IsNarrow $false
$offlineContents = @($multiPlatState.ModelCombo.Items | ForEach-Object { [string]$_.Content })
Assert-Case (($offlineContents -join '|') -match '⚪ OpenAI · 主力隧道') 'Multi-platform ModelCombo dynamically updates OpenAI group dot to ⚪ when tunnel goes offline'
$script:profilesState = $null

Write-Output ('{"result":"PASS","assertions":' + $script:passed + ',"network":"OFFLINE_FAKE_ONLY","production_config_written":false}')

$multi = Make-State 'multi'
$multi | Add-Member ProfilesState ([pscustomobject]@{EnabledPlatforms=@('openai','gemini','claude');Profiles=@()})
$multi | Add-Member AvailableModelsByProvider ([pscustomobject]@{chatgpt=$catalog;gemini=@([pscustomobject]@{slug='gemini-pro';title='Gemini Pro';efforts=@()});claude=@()})
Sync-Test $multi $catalog 'inherit' 'inherit'
Assert-Case (@(Get-Tags $multi.ModelCombo) -contains 'gemini-pro') 'Gemini group exposes its reported model'
Assert-Case (@($multi.ModelCombo.Items | Where-Object {$_.ToolTip -eq 'claude' -and $_.Tag -eq 'inherit'}).Count -eq 1) 'Disconnected Claude has exactly one default'

$multi | Add-Member ConnectedProviders @('chatgpt')
Sync-Test $multi $catalog 'inherit' 'inherit'
Assert-Case (@(Get-Tags $multi.ModelCombo) -notcontains 'gemini-pro') 'Disconnected Gemini does not expose historical cached model'

$multi.ConnectedProviders = @()
Sync-Test $multi $catalog 'inherit' 'inherit'
Assert-Case (@(Get-Tags $multi.ModelCombo) -notcontains 'gpt-6-thinking') 'All-disconnected platform set also hides cached OpenAI models'
