# ChatGPT Web MCP Agent 通道

[English](README.md)

本 Skill 让多条 Codex 对话共用**同一个已经登录的 Chrome 浏览器和 Profile**，每条对话仍有自己的 `chatgpt-web-mcp` 进程、MCP 配置项、Agent ID、状态/日志目录和 ChatGPT 对话绑定。新建 Codex 对话不会再创建新的 Chrome Profile，也不会要求重复登录。

各 Agent 只共用 Browser Host 和登录态；每个 Agent 仍绑定不同的 `conversation_id`。这不提供浏览器进程或凭据隔离。没有完成双 Agent 实际并发收发验证时，不要声称并发隔离已通过。

## 环境要求

- Windows 10/11、Codex Desktop、PowerShell
- 已检出的 `chatgpt-web-mcp` 源码及其现有 `node_modules`
- 已安装 Node.js 和 Chrome 或 Edge
- 一份已经登录的 Chrome 用户数据目录；内置运行时覆盖对应 `chatgpt-web-mcp` `0.2.1`、上游提交 `d6c1909151d9d13b439af1f519513ebee2267893`

如果本地 MCP 版本不同，请提供兼容的 Agent 运行时模板，或先检查并适配覆盖文件。辅助脚本会拒绝不匹配的版本或提交。

## 安装 Skill

克隆本仓库，并将仓库根目录复制到 `%USERPROFILE%\.agents\skills\chatgpt-web-agent-channel`；也可以使用 Codex Skill 安装器。

## 让第一个 Agent 接入已登录浏览器

如果 `%USERPROFILE%\.chatgpt-web-mcp\browser-host\host.json` 已存在且状态有效，跳过 `-BrowserHostProfile`，新 Agent 会复用其中记录的 Profile、Chrome 进程和 CDP 端口。

首次建立 Host 时，必须显式给出**现有且已登录**的 Chrome 用户数据目录。它是 `Default` 或 `Profile 1` 等目录的父目录；不要填写 `Default` 子目录，也不要填一个尚不存在的新目录：

```powershell
& '.\scripts\new-agent-instance.ps1' `
  -AgentId 'ag-codex-<uuid>' `
  -SourceDir 'C:\path\to\chatgpt-web-mcp' `
  -NodeExecutable 'C:\path\to\node.exe' `
  -ChromeExecutable 'C:\Program Files\Google\Chrome\Application\chrome.exe' `
  -CodexConfigPath "$env:USERPROFILE\.codex\config.toml" `
  -BrowserHostProfile '<现有已登录 Chrome 用户数据目录>'
```

如果现有 Chrome 已用该 Profile 开启 CDP，脚本会核验并接入它。如果 Chrome 正在运行但没有可验证的 CDP 端口，脚本会停止，不会另开浏览器或创建 Profile；如需重启浏览器，必须先由用户同意，随后仍使用同一目录。Chrome 136 及更新版本不允许对默认 Chrome 数据目录启用远程调试；不兼容时脚本会停止，不会用新的 Agent Profile 绕过限制。详见 [Chrome 远程调试变更](https://developer.chrome.com/blog/remote-debugging-port)。

共享 Host 有效后，后续每个 Codex 对话只需使用新的稳定 Agent ID 运行同一命令并省略 `-BrowserHostProfile`。辅助脚本只创建 Agent 专属 MCP、状态、日志和绑定文件；每个 Agent 的 `browser_profile` 都指向相同 Host Profile。它不复制 Cookie、Token 或 Profile 数据。

## 迁移已有 Agent

先正常断开要迁移的那个 Agent MCP，再执行：

```powershell
& '.\scripts\migrate-agent-to-shared-browser.ps1' `
  -AgentId 'ag-codex-existing-id' `
  -Root "$env:USERPROFILE\.chatgpt-web-mcp"
```

若共享 Host 尚未建立，再添加 `-BrowserHostProfile '<现有已登录 Chrome 用户数据目录>'`。迁移只修改选定 Agent，保留 Agent ID、MCP 名称、绑定的对话 ID、消息游标、状态和日志；原 Agent Profile 不会复制、删除或打开。迁移前在脚本创建的 `archives` 目录核对备份。

## 重连、检查和关闭

- 重启同一个具名 MCP Server 以重连；不要每次新建 Agent ID。
- 检查 Host：

  ```powershell
  & '.\scripts\browser-host.ps1' -Action Status `
    -HostRoot "$env:USERPROFILE\.chatgpt-web-mcp\browser-host"
  ```

- 单个 Agent MCP 断开不会关闭 Chrome。只有所有 Agent 都断开且用户明确要求关闭后，才执行 Host 的 `Stop` 操作。

发送和读取始终按当前 Agent 绑定的 `conversation_id` 路由，不按标签顺序或当前激活标签选择。每个 Agent 保留独立消息记录和回复游标；同一对话写入串行化，账号发送间隔由共享调度器协调。双 Agent 实际并发测试未通过前，应明确报告尚未验证。

## 许可证

本 Skill 和辅助脚本采用 MIT 许可证，详见 [`LICENSE`](LICENSE)。运行时覆盖基于上游 MIT 项目 `Goudu666/chatgpt-web-mcp`，详见 [`UPSTREAM-LICENSES/chatgpt-web-mcp-MIT.txt`](UPSTREAM-LICENSES/chatgpt-web-mcp-MIT.txt)。
