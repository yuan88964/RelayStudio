# RelayStudio 故障排查手册

> **快速定位入口**：遇到连接、唤醒或界面状态异常时，先点击顶栏左上角的 **`● 主工作台 ▾`** 打开配置面板，核对**隧道状态**与**本地内核状态（`:8765`）**；运行期详细日志统一位于 `data/logs/` 目录（`shield.err.log`、`tunnel.out.log`、`core.err.log`）。

---

## 一、常见问题速查表

| 现象描述 | 常见原因 | 排查与处理步骤 |
| :--- | :--- | :--- |
| **1. 启动隧道提示 `8766` 端口占用或未找到 Python** | 旧 `python.exe` 护盾进程未退出，或 Python 3.11+ 未加入系统 `PATH` | 1. 在顶栏配置面板点击 **「↻ 重启内核」** 自动回收残留进程；<br>2. 若 Python 安装在非标准路径，在 `data/settings.json` 中指定 `"python_path": "D:\\Python311\\python.exe"`。 |
| **2. 顶栏提示隧道连接告警或频繁重连** | API Key 失效、隧道 ID 不匹配，或本机网络代理阻断了 `api.openai.com` 长连接 | 1. 查看 `data/logs/tunnel.out.log` 末尾错误码；<br>2. 若报 `401 Unauthorized`，前往 [OpenAI API Keys](https://platform.openai.com/api-keys) 更新密钥并重新保存启动；<br>3. 若报连接被拒绝，检查系统代理端口是否正常监听。 |
| **3. 选择浏览器宿主发送后，打开了网页但未自动填入内容** | 目标浏览器 Profile 未启用 `browser-bridge` 扩展，或页面尚未完成登录与心跳同步 | 1. 打开 `chrome://extensions` 或 `edge://extensions`，确认 **RelayStudio Browser Bridge** 已启用且允许访问 `chatgpt.com`；<br>2. 刷新一次 ChatGPT 页面，等待约 2 秒心跳上报后重试。 |
| **4. 选择 `ChatGPT 桌面端` 时未能定位会话抽屉** | 桌面客户端此前由外部直接启动，未开启 `127.0.0.1:9222` 调试端口 | 退出系统托盘中的 ChatGPT 桌面端，随后在 RelayStudio 分栏点击 **「打开网页 / 打开宿主窗口 ↗」**，由工作台通过桌面包身份自动携带调试端口拉起客户端。 |
| **5. 日常聊天调用了工具，但左侧任务栏未出现卡片，或未自动连跑** | 按场景隔离契约，零散只读问答不强制建卡；且未开启自动重发时不注入免确认连跑尾注 | 1. 从右侧 **「新建任务」** 发射台直接立项，或在对话中让模型调用 `task_manage(action="create")`；<br>2. 如需夜间无人值守连续执行，勾选分栏底部的 **「自动重发」**（如 `停顿 3 分钟` · `重试 1 次`）。 |
| **6. 手工编辑 `.ps1` / `.psm1` 后启动报解析错误或中文乱码** | Windows PowerShell 5.1 要求含中文字符的脚本必须带 **UTF-8 with BOM** 文件头 | 将修改过的 `.ps1` / `.psm1` 文件保存为 **UTF-8 with BOM（`0xEF,0xBB,0xBF`）+ CRLF**，并运行下方编码与契约测试核验。 |

---

## 二、分层诊断步骤

### 1. 核对本地回环服务健康度

在 PowerShell 中依次执行以下命令，确认本地执行核心（`8765`）、回环桥接中枢（`8766`）与隧道健康检查端口（`8789`）均在线响应：

```powershell
Invoke-RestMethod http://127.0.0.1:8765/healthz
Invoke-RestMethod http://127.0.0.1:8766/shieldz
Invoke-RestMethod http://127.0.0.1:8789/healthz
```

- `:8765/healthz` 无响应：确认 `bin/relaystudio-core.exe` 未被安全软件误拦截，并检查 `data/logs/core.err.log`。
- `:8766/shieldz` 无响应：检查 `data/logs/shield.err.log`，确认 Python 3.11+ 可正常执行。

### 2. 检查本地 ACP 子代理命令路径（可选）

仅当你需要通过 `acp_prompt` 调度本地 Codex 或 Claude 子代理时（纯使用 ChatGPT 网页/桌面原生云端子代理无需此步）：

1. 确认已全局安装适配器：`npm install -g @agentclientprotocol/codex-acp @agentclientprotocol/claude-agent-acp`；
2. 若 npm 全局目录不在默认 `%APPDATA%\npm` 下，在 `data/settings.json` 中补充路径后点击「重启内核」：
   ```json
   {
     "extra_bin_dirs": ["D:\\CustomNpmGlobal"]
   }
   ```

### 3. 运行离线隔离自检套件

仓库自带的回归测试均在独立临时沙箱目录中执行，不会改动 `data/` 下的真实凭据或中断运行中的隧道：

```powershell
# 1. 运行 Python 桥接中枢、单步 task_manage 与守护状态机契约测试
python -m unittest discover -s tests -p "test_*.py"

# 2. 运行 PowerShell 连接管理与多栏工作台隔离回归测试
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ConnectionManager.ps1
```
