param(
    [string]$Version = '1.3.0'
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$distRoot = Join-Path $repoRoot 'dist'

if (Test-Path -LiteralPath $distRoot) {
    Remove-Item -LiteralPath $distRoot -Recurse -Force
}
[IO.Directory]::CreateDirectory($distRoot) | Out-Null

$cleanVer = $Version.TrimStart('v', 'V')
$stageRoot = Join-Path $distRoot "stage-v$cleanVer"
$appStage = Join-Path $stageRoot 'RelayStudio'
[IO.Directory]::CreateDirectory($appStage) | Out-Null

try {
    # 1. Copy core root files
    $rootFiles = @(
        'RelayStudio.exe',
        'RelayStudio.ico',
        'HostBridge.ps1',
        'Launch-ConnectionManager.ps1',
        '连接管理.ps1',
        'ConnectionManager.psm1',
        'McpReadOnlyShield.py',
        'RelayCdp.py',
        'README.md',
        'LICENSE',
        'CHANGELOG.md',
        'SECURITY.md',
        'CONTRIBUTING.md',
        'SPEC.md',
        'GLOSSARY.md'
    )
    foreach ($f in $rootFiles) {
        $src = Join-Path $repoRoot $f
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $appStage $f) -Force
        }
    }

    # 2. Copy bin/ executables and WebView2 runtime loader/assemblies
    $binStage = Join-Path $appStage 'bin'
    [IO.Directory]::CreateDirectory($binStage) | Out-Null
    foreach ($binFile in @('relaystudio-core.exe', 'tunnel-client.exe')) {
        $bSrc = Join-Path (Join-Path $repoRoot 'bin') $binFile
        if (-not (Test-Path -LiteralPath $bSrc)) {
            throw "缺少核心二进制文件: $bSrc"
        }
        Copy-Item -LiteralPath $bSrc -Destination (Join-Path $binStage $binFile) -Force
    }
    $wvSrcDir = Join-Path $repoRoot 'bin\webview2'
    if (Test-Path -LiteralPath $wvSrcDir) {
        $wvStageDir = Join-Path $binStage 'webview2'
        [IO.Directory]::CreateDirectory($wvStageDir) | Out-Null
        Copy-Item -Path (Join-Path $wvSrcDir '*.dll') -Destination $wvStageDir -Force
    }

    # 3. Copy runtime directories without builtin-skills first (for Pure Routing Edition)
    foreach ($dirName in @('browser-bridge', 'docs', 'fonts', 'scripts', 'ui')) {
        $dSrc = Join-Path $repoRoot $dirName
        if (Test-Path -LiteralPath $dSrc) {
            Copy-Item -LiteralPath $dSrc -Destination (Join-Path $appStage $dirName) -Recurse -Force
        }
    }
    foreach ($emptyDir in @('data', 'data\logs', 'engine-data', 'engine-data\tasks', 'engine-data\skills', 'engine-data\mcp', 'workspace')) {
        [IO.Directory]::CreateDirectory((Join-Path $appStage $emptyDir)) | Out-Null
    }

    # 4. Create Pure Routing Portable ZIP (no builtin-skills or default AGENTS.md; ready for pure gateway or AgentVault soft-routing)
    $pureZip = Join-Path $distRoot "RelayStudio-v$cleanVer-win-x64-pure-portable.zip"
    Compress-Archive -Path $appStage -DestinationPath $pureZip -CompressionLevel Optimal -Force

    # 5. Mount builtin-skills + default AGENTS.md and create Full Portable ZIP + Browser Bridge ZIP
    $builtinSrc = Join-Path $repoRoot 'builtin-skills'
    if (Test-Path -LiteralPath $builtinSrc) {
        Copy-Item -LiteralPath $builtinSrc -Destination (Join-Path $appStage 'builtin-skills') -Recurse -Force
    }
    $builtinAgents = Join-Path $repoRoot 'builtin-skills\AGENTS.md'
    if (Test-Path -LiteralPath $builtinAgents) {
        Copy-Item -LiteralPath $builtinAgents -Destination (Join-Path $appStage 'engine-data\AGENTS.md') -Force
    }
    $builtinSkills = Join-Path $repoRoot 'builtin-skills\skills'
    if (Test-Path -LiteralPath $builtinSkills) {
        Copy-Item -Path (Join-Path $builtinSkills '*') -Destination (Join-Path $appStage 'engine-data\skills') -Recurse -Force
    }

    $portableZip = Join-Path $distRoot "RelayStudio-v$cleanVer-win-x64-portable.zip"
    $bridgeZip = Join-Path $distRoot "relaystudio-browser-bridge-v$cleanVer.zip"

    Compress-Archive -Path $appStage -DestinationPath $portableZip -CompressionLevel Optimal -Force
    Compress-Archive -Path (Join-Path $repoRoot 'browser-bridge\*') -DestinationPath $bridgeZip -CompressionLevel Optimal -Force

    # 6. Generate SHA256SUMS.txt
    $hashLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($target in @(
        $portableZip,
        $pureZip,
        $bridgeZip,
        (Join-Path $repoRoot 'RelayStudio.exe'),
        (Join-Path $repoRoot 'bin\relaystudio-core.exe'),
        (Join-Path $repoRoot 'bin\tunnel-client.exe')
    )) {
        if (Test-Path -LiteralPath $target) {
            $h = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
            $leaf = Split-Path $target -Leaf
            $hashLines.Add("$h  $leaf")
        }
    }
    $shaFile = Join-Path $distRoot 'SHA256SUMS.txt'
    [IO.File]::WriteAllLines($shaFile, $hashLines, (New-Object Text.UTF8Encoding($false)))

    [pscustomobject]@{
        Version = "v$cleanVer"
        PortableZip = $portableZip
        PortableSizeMB = [Math]::Round((Get-Item -LiteralPath $portableZip).Length / 1MB, 2)
        PureZip = $pureZip
        PureSizeMB = [Math]::Round((Get-Item -LiteralPath $pureZip).Length / 1MB, 2)
        BridgeZip = $bridgeZip
        BridgeSizeKB = [Math]::Round((Get-Item -LiteralPath $bridgeZip).Length / 1KB, 2)
        Sha256Sums = $shaFile
    } | ConvertTo-Json
} finally {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
