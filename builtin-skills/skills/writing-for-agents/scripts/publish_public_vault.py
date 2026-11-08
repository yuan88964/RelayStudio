#!/usr/bin/env python3
"""Export a clean-room public edition of the Obsidian Agent Vault (AgentVault)
without any math lesson-prep, textbooks, student records, personal profiles, or git history leakage.
"""
from __future__ import annotations

import pathlib
import shutil

VAULT_ROOT = pathlib.Path(r"D:\docmonts\Obsidian Vault")
STAGE_ROOT = pathlib.Path(r"D:\tool\AgentVault-public")

PUBLIC_SKILLS = [
    "develop",
    "mermaid-diagrams",
    "writing-for-agents",
    "research",
    "module-design",
    "tdd",
    "code-review",
    "diagnosing-bugs",
    "to-spec",
    "to-tickets",
    "grilling",
    "domain-modeling",
    "resolving-merge-conflicts",
    "pr",
    "prototype",
]

PUBLIC_GLOBAL_RULES = """# 全局协作规则

## 一、汇报与语体

面向我用简明直观的中文汇报，聚焦方案决策与架构契约；后台子代理通信与技术档案用紧凑英文：

- **结论先行**：先给核心结论，再交代整体运作（解决什么问题、由哪几部分组成、怎么配合），最后展开细节。
- **概念就地解释，一词一义**：陌生概念首次出现保留原名，紧跟一句话说明；同一概念全程只用一个词。
- **讲职责与契约**：开发与排障先讲整体架构；模块（`Module`）只讲对外职责、接缝（`Seam`，模块间可替换、可测试的交互边界）位置与输入输出/异常退路契约；将底层函数名、变量名与行号转化为业务动作描述，源码定位收进括号直链 `[模块/动作名](file:///...)` 或文末对照表（必需命令、路径、文件名原样保留）。
- **形式随内容**：因果推导用连贯段落；5 步以内单线操作用列表；3 项以上并列对比用表格；跨模块接缝、多分支、状态回环或等价变换画图（**先读 [[Agent全局配置/Skills/mermaid-diagrams/SKILL.md|mermaid-diagrams]] 将图写入独立文件，正文中仅以 `[图解标题](file:///...)` 直链交付**）。
- **开放话题**（哲学、情感、人生）：放下汇报结构，自然交谈，可以反问我。

## 二、查证与子代理隔离

- **一手查证**：事实核查自主完成，方向分歧由我拍板。本地状态以源码、本机实测、官方文档为准；选型、排障、机制设计先检索论文、开源仓库（含 Issues/PR）和可靠社区的成熟方案，交叉核实后再建议。
- **子代理隔离**：为防上下文污染，单点查证直接读；多文件源码、长日志、多源检索并行派发只读子代理（保持宿主默认配置，省略模型与推理强度参数），只向主窗口回传精炼摘要和直链。

## 三、协作节奏（先对齐、后执行）

- **开工前（只读调研）**：日常讨论、回答提问与探讨方案均属调研阶段；在我明确下达**“开工 / 执行”**（或亲手输入执行类命令）前，不修改文件或运行有副作用的命令——**仅做只读查证，并在列出待改方案后停下**。
- **需拍板（攒齐提问）**：查清全部可查事实后，若仍有方向分歧，调用 [[Agent全局配置/Skills/grilling/SKILL.md|grilling]] 把当前互不依赖的问题攒齐在对话正文中一次问完（取代宿主自带的提问弹窗）。
- **开工后（一气呵成）**：收到“开工 / 执行”后，按第四节路由进入对应领域模块一气呵成推进到底；内部实现与测试适配自行拍板，仅在涉及用户可见行为变更或连续受阻时先挂起，待其余工作跑完后在收尾一并列出。

## 四、全库版图与顶层路由

仓库划分为**指令系统区**（`Agent全局配置/`，含规则与技能）与**参考资料区**（`参考资料/`）。**命中以下场景（含对话中途衍生的子需求），先加载对应入口原文再按其内部契约执行**：

- **软件架构、排障与开发执行**：开工前模块与接口设计 → [[Agent全局配置/Skills/module-design/SKILL.md|module-design]]；只读故障诊断 → [[Agent全局配置/Skills/diagnosing-bugs/SKILL.md|diagnosing-bugs]]；收到“开工”后执行开发、重构与测试编排 → [[Agent全局配置/Skills/develop/SKILL.md|develop]]
- **写提示词、改 Agent 规则与技能、整理指令体系（`Agent全局配置/`）** → [[Agent全局配置/Skills/writing-for-agents/SKILL.md|writing-for-agents]]
- **专题调研与历史档案（`参考资料/`）**：新专题调研与沉淀报告 → [[Agent全局配置/Skills/research/SKILL.md|research]]；查阅已有调研总表 → [[参考资料/00 参考资料导览|参考资料导览]]

## 五、交付核对

交付前逐条核对任务目标，如实说明未完成或未验证项；时效性事实末尾附“参考资料（来源 + 网址）”。
"""

PUBLIC_README = """# AgentVault — 面向 RelayStudio 与多宿主 Agent 的 Obsidian 深模块规则与技能库

[![LINUX DO](https://img.shields.io/badge/Community-LINUX%20DO-0F172A?style=flat-square)](https://linux.do/)

**AgentVault** 是基于信息隐藏（Parnas）与深模块原则（Ousterhout *A Philosophy of Software Design*）构建的 **Obsidian 工程规则与技能母本仓库**。它可以作为独立 Obsidian 仓库直接打开，也可以通过仓库自带的 **`Setup-ObsidianRelay.ps1`** 一键合并进你现有的本地 Obsidian 仓库，并将 [**RelayStudio**](https://github.com/yuan88964/RelayStudio)（以及本机的 Codex / Claude / Antigravity）通过 NTFS 软/硬链接统一路由到你的 Obsidian 仓库，实现**“在 Obsidian 中修改一处规则或技能，全平台 Agent 实时同步生效”**。

---

## 一、全局版图与深模块内部白盒机制

### 1.1 全局深模块分层与多宿主软路由架构

<p align="center">
  <img src="assets/diagram-agentvault-architecture.png" width="98%" alt="AgentVault 深模块分层架构与多宿主软路由拓扑图" />
</p>

### 1.2 深模块内部白盒机制：以 `Skills/develop/` 为例看如何“消化旧技能、按接缝调子零件”

<p align="center">
  <img src="assets/diagram-deep-module-internals.png" width="96%" alt="Skills/develop 深模块内部白盒机制：吸收旧技能与 Caller Override 接缝注入" />
</p>

### 1.3 深模块三态接口契约与结构化转接（`Standard / Normalize / Bailout`）

<p align="center">
  <img src="assets/diagram-three-state-contract.png" width="92%" alt="深模块三态接口契约与结构化转接流转图" />
</p>

| 目录 / 入口文件 | 角色定位 | 说明 |
| :--- | :--- | :--- |
| **[`Agent全局配置/Global_Agent_Rules.md`](Agent全局配置/Global_Agent_Rules.md)** | 全库唯一顶层路由器 | 统一汇报语体契约、求真溯源与高噪隔离、先对齐后执行节奏以及核心深模块一步直达路由 |
| **[`Agent全局配置/Skills/develop/SKILL.md`](Agent全局配置/Skills/develop/SKILL.md)** | 软件开发与长程编排器 | 唯一软件开发入口：按规模自动分流单切片流与多工单 DAG 流，内部按分支渐进加载测试节奏（[`testing.md`](Agent全局配置/Skills/develop/testing.md)）、6 行交接与修订协议（[`protocol.md`](Agent全局配置/Skills/develop/protocol.md)）及多宿主适配（[`hosts.md`](Agent全局配置/Skills/develop/hosts.md)） |
| **[`Agent全局配置/Skills/module-design/SKILL.md`](Agent全局配置/Skills/module-design/SKILL.md)** | 深模块设计共享子程序 | `1. Gather → 2. Split → 3. Polish` 深模块构造决策树、跨域分支路由与 5 行蓝图返回契约 |
| **[`Agent全局配置/Skills/writing-for-agents/SKILL.md`](Agent全局配置/Skills/writing-for-agents/SKILL.md)** | 提示词、技能与知识库编排器 | 全量上下文即样本、双重负载权衡、四象限引导，以及联动 `module-design` 构造与打磨四类模块角色 |
| **[`Agent全局配置/Skills/mermaid-diagrams/SKILL.md`](Agent全局配置/Skills/mermaid-diagrams/SKILL.md)** | 系统架构与图解通用子程序 | 画图判定、5～15 节点规模契约、内聚拓扑布局算法、`.md`/`.png` 单轨交付与六大标准模板 |
| **[`Agent全局配置/Skills/`](Agent全局配置/Skills/) 其余 10 个工程模块** | 专职执行器与共享子程序 | 包含 `tdd`、`code-review`、`diagnosing-bugs`、`to-spec`、`to-tickets`、`grilling`、`domain-modeling`、`research`、`resolving-merge-conflicts`、`pr`、`prototype` |
| **[`参考资料/00 参考资料导览.md`](参考资料/00%20参考资料导览.md)** | 软件设计调研参考资料 | 收录面向过程/面向对象/信息隐藏演进调研，以及复杂度控制、深模块构造与多工单并发设计深度调研 |
| **[`Setup-ObsidianRelay.ps1`](Setup-ObsidianRelay.ps1)** | 一键迁入与软路由配置器 | 支持将本库合并进你已有的本地 Obsidian 仓库，并自动将 RelayStudio 软路由挂载至该 Obsidian 仓库 |

---

## 二、两种一键配置方式（配合 RelayStudio 纯净路由版或完整版）

你可以下载 [**RelayStudio 纯净路由版（`RelayStudio-v1.3.0-win-x64-pure-portable.zip`）**](https://github.com/yuan88964/RelayStudio/releases/latest)（不内置任何预设规则与技能），再通过本仓库的 `Setup-ObsidianRelay.ps1` 完成一键挂载：

### 方式 A：把本仓库的内容直接配置到你**已有的本地 Obsidian 仓库**中，并将 RelayStudio 软路由过去（推荐）

如果你本地已经有日常使用的 Obsidian 知识库（例如 `D:\\MyObsidianVault`），只需克隆本仓库并运行：

```powershell
git clone https://github.com/yuan88964/AgentVault.git
cd AgentVault

# 将 Agent全局配置/ 与 参考资料/ 合并至你现有的 Obsidian 库，并自动将 RelayStudio 软路由指向你的 Obsidian 库：
powershell -ExecutionPolicy Bypass -File .\\Setup-ObsidianRelay.ps1 `
  -TargetObsidianVault "D:\\MyObsidianVault" `
  -RelayStudioDir "D:\\RelayStudio"
```

### 方式 B：直接把克隆下来的 `AgentVault` 作为独立 Obsidian 仓库打开并挂载 RelayStudio

```powershell
git clone https://github.com/yuan88964/AgentVault.git
cd AgentVault

# 直接将当前 AgentVault 软路由挂载至 RelayStudio：
powershell -ExecutionPolicy Bypass -File .\\Setup-ObsidianRelay.ps1 `
  -RelayStudioDir "D:\\RelayStudio"
```

> **底层做了什么？**
> `Setup-ObsidianRelay.ps1` 会自动在 `RelayStudio\\data\\settings.json` 中写入 `"agents_md_target"` 与 `"skills_junction_target"`，并将 `RelayStudio\\engine-data\\skills` 建立为指向你 Obsidian 仓库 `Agent全局配置/Skills/` 的 **NTFS Junction 软链接**，将 `RelayStudio\\engine-data\\AGENTS.md` 建立为指向 `Agent全局配置/Global_Agent_Rules.md` 的**硬链接**。如果加上 `-LinkLocalCliAgents` 参数，还会一并挂载到本机的 `~/.codex/skills` 与 `~/.claude/skills`。

---

## 友链与致谢

本项目积极参与并认可 **[LINUX DO 社区](https://linux.do)**（友链：https://linux.do ）。
"""

PUBLIC_REFERENCE_INDEX = """# 参考资料导览

本目录集中存放软件工程设计范式、深模块构造与多智能体并发架构的一手文献调研笔记。

## 软件设计范式与深模块构造

- [[参考资料/软件设计范式与模块化演进调研/2026-10-23 面向过程、面向对象与信息隐藏演进调研|2026-10-23 面向过程、面向对象与信息隐藏演进调研]]
- [[参考资料/软件设计范式与模块化演进调研/2026-11-06_复杂度控制、深模块构造与多工单并发设计|2026-11-06 复杂度控制、深模块构造与多工单并发设计]]
"""

SETUP_PS1 = r"""param(
    [Parameter(Mandatory = $false)]
    [string]$TargetObsidianVault = "",

    [Parameter(Mandatory = $false)]
    [string]$RelayStudioDir = "",

    [Parameter(Mandatory = $false)]
    [switch]$LinkLocalCliAgents
)

$ErrorActionPreference = 'Stop'
$sourceRoot = $PSScriptRoot

Write-Host "=== AgentVault × RelayStudio 软路由配置工具 ===" -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($TargetObsidianVault)) {
    $activeVault = $sourceRoot
    Write-Host "[1/3] 使用当前目录作为生效 Obsidian 仓库: $activeVault" -ForegroundColor Green
} else {
    $activeVault = [IO.Path]::GetFullPath($TargetObsidianVault)
    Write-Host "[1/3] 正在将 Agent全局配置/ 与 参考资料/ 迁入现有 Obsidian 仓库: $activeVault" -ForegroundColor Green
    [IO.Directory]::CreateDirectory($activeVault) | Out-Null

    foreach ($subDir in @('Agent全局配置', '参考资料')) {
        $srcPath = Join-Path $sourceRoot $subDir
        $dstPath = Join-Path $activeVault $subDir
        if (Test-Path -LiteralPath $srcPath) {
            [IO.Directory]::CreateDirectory($dstPath) | Out-Null
            Copy-Item -Path (Join-Path $srcPath '*') -Destination $dstPath -Recurse -Force
        }
    }
}

$rulesTarget = Join-Path $activeVault 'Agent全局配置\Global_Agent_Rules.md'
$skillsTarget = Join-Path $activeVault 'Agent全局配置\Skills'

if (-not (Test-Path -LiteralPath $rulesTarget)) {
    throw "未找到全局规则文件: $rulesTarget"
}
if (-not (Test-Path -LiteralPath $skillsTarget)) {
    throw "未找到技能目录: $skillsTarget"
}

if (-not [string]::IsNullOrWhiteSpace($RelayStudioDir)) {
    $relayRoot = [IO.Path]::GetFullPath($RelayStudioDir)
    Write-Host "[2/3] 正在将 RelayStudio ($relayRoot) 软路由指向 Obsidian 仓库..." -ForegroundColor Green

    $dataDir = Join-Path $relayRoot 'data'
    $engineDataDir = Join-Path $relayRoot 'engine-data'
    [IO.Directory]::CreateDirectory($dataDir) | Out-Null
    [IO.Directory]::CreateDirectory($engineDataDir) | Out-Null

    $settingsPath = Join-Path $dataDir 'settings.json'
    $settingsObj = @{}
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $raw = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
            $parsed = $raw | ConvertFrom-Json
            foreach ($prop in $parsed.PSObject.Properties) {
                $settingsObj[$prop.Name] = $prop.Value
            }
        } catch {}
    }
    $settingsObj['agents_md_target'] = $rulesTarget
    $settingsObj['skills_junction_target'] = $skillsTarget
    $jsonOut = $settingsObj | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($settingsPath, $jsonOut, (New-Object System.Text.UTF8Encoding($false)))

    $engineSkillsLink = Join-Path $engineDataDir 'skills'
    if (Test-Path -LiteralPath $engineSkillsLink) {
        $item = Get-Item -LiteralPath $engineSkillsLink -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            cmd /c rmdir "$engineSkillsLink" | Out-Null
        } else {
            Remove-Item -LiteralPath $engineSkillsLink -Recurse -Force
        }
    }
    New-Item -ItemType Junction -Path $engineSkillsLink -Target $skillsTarget | Out-Null

    $engineAgentsMd = Join-Path $engineDataDir 'AGENTS.md'
    if (Test-Path -LiteralPath $engineAgentsMd) {
        Remove-Item -LiteralPath $engineAgentsMd -Force
    }
    try {
        New-Item -ItemType HardLink -Path $engineAgentsMd -Target $rulesTarget -ErrorAction Stop | Out-Null
    } catch {
        Copy-Item -LiteralPath $rulesTarget -Destination $engineAgentsMd -Force
    }

    Write-Host "  [OK] engine-data\skills -> $skillsTarget" -ForegroundColor Green
    Write-Host "  [OK] engine-data\AGENTS.md -> $rulesTarget" -ForegroundColor Green
} else {
    Write-Host "[2/3] 未指定 -RelayStudioDir，跳过 RelayStudio 软路由绑定。" -ForegroundColor Yellow
}

if ($LinkLocalCliAgents) {
    Write-Host "[3/3] 正在将本机 ~/.codex 与 ~/.claude 软路由指向 Obsidian 仓库..." -ForegroundColor Green
    foreach ($cliHome in @(
        (Join-Path $env:USERPROFILE '.codex'),
        (Join-Path $env:USERPROFILE '.claude')
    )) {
        [IO.Directory]::CreateDirectory($cliHome) | Out-Null
        $cliSkills = Join-Path $cliHome 'skills'
        if (-not (Test-Path -LiteralPath $cliSkills)) {
            try { New-Item -ItemType Junction -Path $cliSkills -Target $skillsTarget | Out-Null } catch {}
        }
    }
} else {
    Write-Host "[3/3] 完成！（如需同时挂载至本机 ~/.codex 与 ~/.claude，可加 -LinkLocalCliAgents 参数）" -ForegroundColor Cyan
}
"""


def build_public_vault() -> None:
    STAGE_ROOT.mkdir(parents=True, exist_ok=True)
    for child in STAGE_ROOT.iterdir():
        if child.name in {".git", "assets"}:
            continue
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()

    (STAGE_ROOT / "README.md").write_text(PUBLIC_README, encoding="utf-8")
    (STAGE_ROOT / ".gitignore").write_text(".obsidian/\n__pycache__/\n*.pyc\n.trash/\n.scratch/\ntmp/\n", encoding="utf-8")
    ps1_bytes = b"\xef\xbb\xbf" + SETUP_PS1.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8")
    (STAGE_ROOT / "Setup-ObsidianRelay.ps1").write_bytes(ps1_bytes)

    cfg_dir = STAGE_ROOT / "Agent全局配置"
    cfg_dir.mkdir(parents=True, exist_ok=True)
    (cfg_dir / "Global_Agent_Rules.md").write_text(PUBLIC_GLOBAL_RULES, encoding="utf-8")

    skills_dst = cfg_dir / "Skills"
    skills_dst.mkdir(parents=True, exist_ok=True)
    for name in PUBLIC_SKILLS:
        src = VAULT_ROOT / "Agent全局配置" / "Skills" / name
        dst = skills_dst / name
        shutil.copytree(src, dst)

    mm_skill = skills_dst / "mermaid-diagrams" / "SKILL.md"
    mm_text = mm_skill.read_text(encoding="utf-8")
    mm_text = mm_text.replace("D:/Dev/mermaid-diagrams/render-batch.mjs", "scripts/render-batch.mjs")
    mm_skill.write_text(mm_text, encoding="utf-8")

    mm_render = skills_dst / "mermaid-diagrams" / "references" / "rendering.md"
    if mm_render.exists():
        mr_text = mm_render.read_text(encoding="utf-8")
        mr_text = mr_text.replace("D:/Dev/mermaid-diagrams/render-batch.mjs", "scripts/render-batch.mjs")
        mm_render.write_text(mr_text, encoding="utf-8")

    res_skill = skills_dst / "research" / "SKILL.md"
    res_text = res_skill.read_text(encoding="utf-8")
    res_text = res_text.replace(
        "D:/docmonts/Obsidian Vault/参考资料/<Topic>.md",
        "参考资料/<Topic>.md",
    ).replace(
        "D:/docmonts/Obsidian Vault/参考资料/00 参考资料导览.md",
        "参考资料/00 参考资料导览.md",
    )
    res_skill.write_text(res_text, encoding="utf-8")

    ref_dir = STAGE_ROOT / "参考资料"
    ref_dir.mkdir(parents=True, exist_ok=True)
    (ref_dir / "00 参考资料导览.md").write_text(PUBLIC_REFERENCE_INDEX, encoding="utf-8")
    se_notes_src = VAULT_ROOT / "参考资料" / "软件设计范式与模块化演进调研"
    se_notes_dst = ref_dir / "软件设计范式与模块化演进调研"
    shutil.copytree(se_notes_src, se_notes_dst)

    print(f"Successfully staged clean-room AgentVault at: {STAGE_ROOT}")


if __name__ == "__main__":
    build_public_vault()
