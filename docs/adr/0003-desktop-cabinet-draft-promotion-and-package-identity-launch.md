# 3. 桌面端多抽屉文件柜全量转正、空白抽屉去污与商店容器通行证保活

Date: 2026-10-31

## Status

Accepted

## Context

在多任务并发开启深度思考档位（Thinking）且高频发起 **新建网页交接（New Window Handover Mode）** 或在桌面端与网页端之间切换的真实场景中，桌面联络员与后台大管家暴露了四项契约缺陷：

1. **误将临时排队号当作正式会话房间号且后台抽屉无法转正**：ChatGPT 桌面端在新消息刚发出、模型尚在思考时，侧边栏与组件树底层先生成带 `local-chatgpt:` 前缀的 **临时排队号（Client Draft ID）**（如 `local-chatgpt:ea5a01b0-...`）。桌面联络员此前未过滤该前缀，直接截取末尾 36 位作为正式 **会话房间（Conversation Room）** 号；而当画面切到空白抽屉或思考超过 60 秒后，对话退居 **多抽屉文件柜（Conversation Drawer Cabinet）** 的后台隐身抽屉，仅检查当前可见抽屉的 60 秒转正逻辑徹底失效，导致 **房产证绑定簿（Session Binding）** 永久卡在作废的临时排队号上，用户点击「打开网页 ↗」时因侧边栏查无此号而停留在初始空白抽屉。
2. **残留便利贴污染空白抽屉判定**：点击“新聊天”切到空白抽屉后，由于桌面端不刷新页面，根节点仍残留上一轮对话写下的 `dataset.relayActiveConvUuid`，导致 `script_state()` 误报旧房间号，等待 6 秒后报 `new_chat_not_ready`。
3. **带端口桌面端繁忙时被误杀重启**：当桌面端因挂载多个深度思考抽屉而繁忙、1.5 秒内未响应内部调试窗口探测时，后台大管家误判其“未挂载调试窗口”并执行强制关停重启，导致用户在切回网页端时看到桌面端窗口无故退出；同时直接裸跑 `WindowsApps` 下的 `.exe` 缺乏微软商店容器身份。
4. **网页端冷启动抢发请求触发 Cloudflare 拦截**：`bridge-page-hook.js` 在 `document_start` 阶段立即抢发 `/api/auth/session` 与 `/backend-api/models` 请求，撞上冷启动最初 1～2 秒的 Cloudflare 安检。

## Decision

1. **拒收临时排队号 + 全文件柜抽屉扫描转正（Full-Cabinet Draft Promotion）**：
   - 桌面联络员严格区分 `local-chatgpt:` 临时排队号（`draft_id`）与 36 位正式会话房间号（`conv_uuid`），绝不将 `local-chatgpt:` 编号放入正式 `conv_uuid`。
   - 每次巡检时扫描 **多抽屉文件柜** 中的全部云端对话抽屉（含 `0×0` 后台隐身抽屉），提取每个抽屉同时持有的 `{draft_id, conv_uuid, task_hints}` 映射表，由后台大管家凭 `draft_id` 或任务编号 `tsk_xxx` 随时完成正式过户（并对已误绑临时号的存量任务自动自愈过户）。
2. **空白抽屉判定去污**：
   - 在桌面端（`app:` 协议）下，`script_state()` 的 `conv_uuid` 仅采信当前可见抽屉的 `ctx.convId` 与侧边栏高亮项 `sb.uuid`，禁止回退读取 `dataset.relayActiveConvUuid`；点击“新聊天”时主动清除 `dataset.relayActiveConvUuid`。
3. **持商店容器通行证启动与带端口进程免杀保活**：
   - 借鉴 `Cockpit Tools`，通过 `Invoke-CommandInDesktopPackage -PackageFamilyName 'OpenAI.Codex_2p2nqsd0c76g0' -AppId 'App' -PreventBreakaway` 持 **商店容器通行证（Store Package Identity）** 启动桌面端并挂载调试端口（后台启动时注入 `CODEX_ELECTRON_START_IN_BACKGROUND=1`）。
   - 只要系统进程表显示运行中的 `ChatGPT.exe` 命令行已包含 `--remote-debugging-port=`，永远视为 `has_debug_port = True`，严禁因单次探测超时而关停或重启桌面端进程。
4. **网页探针安检退避**：
   - 移除 `bridge-page-hook.js` 在 `document_start` 阶段的主动网络请求，改为优先被动拦截网页自身请求或待聊天输入框挂载后再温和同步。

## Consequences

- 即使在深度思考期间切换画面、连续发起新建网页交接或思考超过 60 秒，任务卡片的房产证绑定簿也能 100% 准确过户至真正的 36 位云端会话房间，点击「打开网页 ↗」精准直达目标对话。
- 桌面端新建网页交接彻底消除 `new_chat_not_ready` 假超时，切换回网页端时桌面端进程稳定保活不再无故退出，网页端冷启动不再触发 `Cloudflare out` 拦截。
