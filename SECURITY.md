# 安全策略与隐私边界说明（Security Policy）

## 一、支持版本（Supported Versions）

| 版本分支 | 安全更新支持状态 |
| :--- | :--- |
| `v1.0.x` (最新发行版) | ✅ 持续支持 |
| `< v1.0.0` (早期内部预览草稿) | ❌ 不再支持 |

---

## 二、本机安全架构与隐私承诺

RelayStudio 专为开发者本机工程环境设计，严格遵循最小暴露面与本地凭据加密原则：

1. **DPAPI 系统级凭据加密**：
   - 用户填写的 OpenAI Control Plane API Key（`sk-proj-...`）通过 Windows 原生 `System.Security.Cryptography.ProtectedData`（`DataProtectionScope.CurrentUser`）加密后保存在 `data/*.dpapi`。
   - 任何明文 API Key 均不会写入 `data/settings.json`、`data/credential-profiles.json` 或 Git 版本历史。
2. **严格的环回地址绑定（Loopback-Only Binding）**：
   - 桥接护盾与状态中枢（`127.0.0.1:8766`）、本机执行核心（`127.0.0.1:8765`）、隧道健康检查（`127.0.0.1:8789`）以及桌面端 CDP 调试端口（`127.0.0.1:9222`）全部仅监听本机回环地址 `127.0.0.1`，不向局域网或公网开放任何监听端口。
3. **`.gitignore` 敏感目录强隔离**：
   - 运行时产生的凭据文件（`*.dpapi`）、隧道配置（`tunnel-profile.yaml`）、本地配置（`data/`）、任务账本（`engine-data/`）与工作区缓存（`workspace/`）默认被 `.gitignore` 严格忽略，防止误提交泄露。
4. **零第三方遥测**：
   - 本仓库代码与 `browser-bridge` 浏览器扩展不包含任何第三方统计、埋点或外发上报逻辑。

---

## 三、报告安全漏洞（Reporting a Vulnerability）

如发现任何潜在的本机权限绕过、跨站请求伪造或凭据泄露风险：

1. **请勿在公开 Issue 中直接披露未修复的漏洞利用细节**；
2. 请通过 GitHub 仓库的 **Private Vulnerability Reporting（私密安全报告）** 功能提交详细复现步骤与影响范围；
3. 维护者将在收到报告后的 **72 小时内** 予以响应，并在修复补丁发布后致谢。
