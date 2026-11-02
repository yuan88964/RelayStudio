# 基于可见边界框与工作区标识识别桌面端当前可见抽屉（Desktop Active Drawer Resolution & Interactive Desktop Spawning）

Status: accepted

ChatGPT 桌面端在同一窗口的多抽屉文件柜中同时挂载了当前对话、多个被第 14 层祖先容器设置 `display: none` 隐藏的历史对话（元素自身 `style.display` 为空但几何尺寸为 `0×0`）以及隐藏的编程工作区，且所有正常对话抽屉在组件树第 89 层均挂有代表迷你悬浮条收起状态的 `isHidden: true` 属性。因此我们决定：（1）桌面联络员在执行「认抽屉契约」时，必须要求输入框及表单的几何尺寸大于 `0×0` 且向上遍历祖先节点无 `display: none` / `visibility: hidden`，同时在遍历组件树时仅排除 `isWorkConversation === true` 的编程工作区（忽略外层迷你悬浮条的 `isHidden: true`），并优先提取第 119 层的 36 位正式云端房间号 `scrollStateConversationId`；（2）进程启动器在拉起后台大管家与桌面端时，必须直接在当前用户的可见交互桌面（`WinSta0\Default`）中以无控制台窗口方式创建进程，严禁通过 WMI `Win32_Process.Create` 在非交互式服务隔离区（`Service-0x0`）中派生进程。
