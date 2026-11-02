# 参与贡献指南（Contributing to RelayStudio）

感谢你关注并参与 **RelayStudio** 的开发！为保证跨进程状态机、WPF 界面与双宿主网桥的稳定性，在提交代码前请阅读并遵守以下工程规范。

---

## 一、开发环境准备

- **操作系统**：Windows 10 / 11（64 位）
- **必需工具**：
  - Windows PowerShell 5.1（系统内置）与 PowerShell 7（`pwsh`，可选）
  - Python 3.11 或更高版本
  - .NET Framework 4.8（用于编译 `RelayStudio.exe` 无黑框启动器与运行 WPF 界面）

---

## 二、铁律级编码与工程约束

1. **PowerShell 脚本编码铁律（UTF-8 with BOM + CRLF）**：
   - `RelayStudio.exe` 内部托管的是 Windows PowerShell 5.1 Runspace。
   - 仓库内所有 `.ps1` 与 `.psm1` 文件（包括 `连接管理.ps1`、`ConnectionManager.psm1`、`Launch-ConnectionManager.ps1`、`tests/Test-ConnectionManager.ps1`）**必须使用带 BOM 的 UTF-8（`0xEF, 0xBB, 0xBF`）与标准 CRLF（`\r\n`，严禁出现 `\r\r\n`）保存**，否则中文字符串在 PowerShell 5.1 下会发生解析报错或界面乱码。
2. **禁止硬编码个人路径或账号**：
   - 严禁在源码、扩展或测试脚本中写死任何个人邮箱、特定浏览器 Profile（如 `Profile 1`）或本机特定盘符路径。
   - 本机个性化配置（如自定义 Python 路径、优先浏览器列表、Obsidian 技能库软路由）必须统一存放在被 `.gitignore` 忽略的 `data/settings.json` 中。
3. **单一状态源契约（Hub-First Seam）**：
   - `:8766`（`McpReadOnlyShield.py`）是会话绑定、网桥队列与停顿断路器的唯一权威状态源。WPF 界面通过 `/studio/snapshot` 与 `/studio/action` 与之交互，禁止在 UI 轮询定时器中直接并发写盘篡改状态机。

---

## 三、提交前必跑测试门禁

在发起 Pull Request 前，请确保以下两套自动化测试 100% 通过：

```powershell
# 1. 运行 Python 桥接护盾与契约门禁测试（含 UTF-8 BOM 与静态接线检查）
python -m unittest discover -s tests -p "test_*.py"

# 2. 运行 PowerShell WPF 界面与连接管理隔离回归测试
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ConnectionManager.ps1
```

如需验证发行包构建，可运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release.ps1 -Version "1.1.0"
```
