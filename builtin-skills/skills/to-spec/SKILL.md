---
name: to-spec
description: "将当前对话收敛为规格文档（spec）并发布到项目议题追踪器：不再开展访谈，仅综合已讨论确定的内容。"
disable-model-invocation: true
---

本技能利用当前会话上下文与对代码库的理解直接产出规格文档（spec）。**不要**再向用户发起访谈，仅综合整理双方已经讨论确定的内容。

议题追踪器（issue tracker）与分诊标签（triage label）配置通常已在上下文中提供；若尚未配置，请提示用户先运行 `/setup-matt-pocock-skills`。

## 流程

1. 若尚未探索代码仓库，先扫描仓库以摸清代码库当前状态。在规格文档中全程严格使用项目领域术语表（`GLOSSARY.md`）中的标准词汇，并遵守相关架构决策记录（ADR）。

2. 拟定你计划在哪些**可替换接缝**上测试该功能。优先复用现有的**可替换接缝**，而非凭空新增。尽量选用最高层级的**可替换接缝**；若确需新增**可替换接缝**，也应在尽可能高的架构层级上提出。

   所涉**可替换接缝**越少越好，最理想的数量是仅用 1 个。向用户确认拟定的这些**可替换接缝**是否符合预期。

3. 按照下方模板撰写规格文档，并发布到项目议题追踪器中。为其打上 `ready-for-agent` 分诊标签，无需再走额外的分诊流程。

<spec-template>

## Problem Statement

从用户视角描述用户当前面临的痛点与问题。

## Solution

从用户视角描述解决该问题的整体方案。

## User Stories

一份详尽的编号用户故事列表。每条用户故事采用如下格式：

1. As an <actor>, I want a <feature>, so that <benefit>

<user-story-example>
1. As a mobile bank customer, I want to see balance on my accounts, so that I can make better informed decisions about my spending
</user-story-example>

这份用户故事列表应当全面覆盖该功能的所有业务场景与边界行为。

## Implementation Decisions

已敲定的实现决策列表，可涵盖：

- 待新建或修改的**模块**
- 待调整的模块**接口契约**
- 开发者给出的技术澄清与约束
- 架构设计决策
- 数据模型与表结构（schema）变更
- 对外或跨模块 API 契约
- 关键交互时序与状态流转

切勿写入具体的文件路径或大段业务代码片段——它们极易随代码演进而迅速过时。

例外情况：若原型验证（prototype）产出的一小段代码比纯文字更精确地刻画了某项核心决策（如状态机、状态归约器 reducer、数据结构 schema 或类型签名），可将其内联到对应决策条目中，并简短注明其源自原型验证。仅保留浓缩了决策信息的最小片段，切勿粘贴完整的可运行演示代码。

## Testing Decisions

已敲定的测试决策列表，涵盖：

- 好测试的判定标准（仅通过对外**接口契约**验证外部可观测行为，绝不绑定**内部实现**细节）
- 计划对哪些**模块**编写测试
- 代码库中可供参照的既有测试样板（prior art，即仓库内同类型的现有测试）

## Out of Scope

明确说明不在本份规格文档覆盖范围内的事项。

## Accepted Amendments & Internal Adaptations

这是一个**只追加（append-only）**的修订记录簿，用于登记实施期间经用户批准的需求变更，以及不破坏外部行为的**内部实现**与**变更波及面**适配调整（例如提取内部辅助函数，或在保持用户可观测行为与既有验收判据不变的前提下调整受波及调用方的函数签名）。实施子代理与 `code-review` 必须严格以**生效规格（Effective Spec）= 原始规格（Original Spec）⊕ 已接受修订（Accepted Amendments）**（`Original Spec ⊕ Accepted Amendments`）为唯一依据开展代码实施与审查。

## Further Notes

关于该功能的其他补充说明。

</spec-template>
