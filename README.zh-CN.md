# ChatGPT Web MCP Agent 专属通道

[English](README.md)

这是一个 Codex Skill 和 PowerShell 辅助脚本，用于让 Windows 上的每个 Agent 使用独立的 `chatgpt-web-mcp` 进程、Chrome Profile、CDP 端口、状态与日志目录，以及 ChatGPT 对话绑定。

## 环境要求

- Windows 10/11 和 Codex Desktop
- 已检出的 `chatgpt-web-mcp` 源码及其已安装依赖
- 已安装 Node.js，以及 Chrome 或 Edge
- 内置运行时覆盖文件对应 `chatgpt-web-mcp` `0.2.1`，上游提交为 `d6c1909151d9d13b439af1f519513ebee2267893`

如果本地源码版本不同，请提供兼容的 Agent 运行时模板，或先检查并适配内置覆盖文件。使用内置文件时，辅助脚本会拒绝不匹配的包版本或 Git 提交。

## 安装 Skill

克隆本仓库，并将仓库根目录复制到 `%USERPROFILE%\.agents\skills\chatgpt-web-agent-channel`；也可以使用你常用的 Codex Skill 安装方式。仓库根目录包含 `SKILL.md`。

## 创建 Agent 实例

为 Agent 选择一个稳定且唯一的 ID，然后在 PowerShell 中运行辅助脚本：

```powershell
& '.\scripts\new-agent-instance.ps1' `
  -AgentId 'ag-codex-<uuid>' `
  -SourceDir 'C:\path\to\chatgpt-web-mcp' `
  -NodeExecutable 'C:\path\to\node.exe' `
  -ChromeExecutable 'C:\Program Files\Google\Chrome\Application\chrome.exe' `
  -CodexConfigPath "$env:USERPROFILE\.codex\config.toml"
```

如果本地源码与内置版本不匹配，可添加 `-TemplateAgentRoot`，指向一个使用同一源码检出且运行正常的 Agent 实例。脚本只创建当前 Agent 专属目录和独立命名的 Codex MCP 配置项；它复用现有 `node_modules`，不会改动其他 Agent。

首次运行 `agent-call.mjs chatgpt_status` 时，会使用新的空 Profile 启动 Chrome。请在该 Profile 中正常登录，然后按 `SKILL.md` 的步骤绑定一个新对话。

## 隔离方式

每个具名 stdio Server 都会启动自己的 Node 进程。启动器为该 Agent 指定独立 Chrome Profile 和浏览器/运行时状态路径；源码会分配并持久记录一个可用的本机 CDP 端口。绑定文件记录真实的对话 ID 和 URL，路由会校验 Agent ID 与对话 ID。

Skill 不会复制 Cookie、Token 或其他 Agent 的状态。只有两个独立 Agent 同时发送不同的唯一消息，并分别从各自绑定的对话收到回复，才会报告跨 Agent 并发隔离已验证。

## 许可证

本 Skill 和辅助脚本采用 MIT 许可证，详见 [`LICENSE`](LICENSE)。内置运行时覆盖文件基于上游 `Goudu666/chatgpt-web-mcp`，该项目也采用 MIT 许可证，详见 [`UPSTREAM-LICENSES/chatgpt-web-mcp-MIT.txt`](UPSTREAM-LICENSES/chatgpt-web-mcp-MIT.txt)。
