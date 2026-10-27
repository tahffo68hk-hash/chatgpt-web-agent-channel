# 面向各 Agent 的共享 ChatGPT 浏览器 Host

日期：2026-10-27

## 实施状态

仓库已加入共享 Browser Host 管理器、Agent 连接与路由改动、实例创建和显式 Profile 接管脚本，以及中英文使用说明。Node.js 与 PowerShell 静态语法检查已通过。本次改动没有执行真实 ChatGPT 登录/重连或双 Agent 同时发送与回复核对，因此跨 Agent 并发隔离尚未验证。

[English](2026-10-27-shared-chatgpt-browser-design.md)

## 问题

当前辅助脚本会为每个 Agent ID 创建独立的 Chrome Profile、CDP 状态文件和浏览器生命周期。因此，每个新的 Codex 对话都会启动一个全新的 Profile，并要求重新登录 ChatGPT。用户希望多个 Codex 对话复用同一个长期运行且已登录的浏览器，同时继续使用各自独立的 ChatGPT 对话 ID。

## 目标

本机复用一个长期运行的 Chrome 进程和 Profile。每个 Codex 对话仍保留独立的 MCP stdio 进程、Agent ID、消息状态、日志和 ChatGPT 对话绑定。Agent 只能访问自己绑定文件中记录的 ChatGPT 对话。

此设计共享浏览器登录态，不会让多个 Codex 对话共用同一个 MCP 进程，也不会在 Profile 之间复制 Cookie 或凭据。

## 架构

### 共享浏览器 Host

- 在共同的 `chatgpt-web-mcp` 根目录下新增一个长期运行的浏览器 Host。它负责一个 Chrome 进程、一个共享 Profile、一个动态分配的本机回环 CDP 端口、浏览器状态和生命周期锁。
- 首次设置时，将用户明确选择的、已经登录的 Chrome 用户数据目录登记为 Host。之后的 Agent 设置读取已持久化的状态并复用 Host。管理器使用以规范 Host 路径派生的 Windows 命名互斥锁，串行化并发启动、接管和关闭。设置流程永不创建新的 Chrome Profile。
- 共享 Profile 只能由一个 Chrome 进程打开。启动时，浏览器 Host 必须检查记录的 PID、Profile 路径和 CDP 端口，再决定是否复用当前端点。
- 只有浏览器 Host 管理器可以启动或终止 Chrome。Agent MCP 进程通过 CDP 连接，并在 MCP 调用结束时断开自己的控制器。Agent 生命周期工具不得终止共享 Chrome。
- Host 使用用户现有的登录会话，不会从其他 Profile 复制 Cookie。如果 Chrome 无法提供可验证的 CDP 端点，设置流程停止，不会启动 Agent 专属 Profile。

### Agent 专属 MCP 和对话路由

- 每个 Codex 对话保留稳定且唯一的 Agent ID，以及独立命名的 MCP Server 配置。MCP 进程继续使用自己的 Agent 状态、消息日志、绑定文件、请求 ID 和回复游标。
- 每个 Agent 绑定一个唯一的 `conversation_id` 和规范 URL：`https://chatgpt.com/c/<conversation_id>`。读取或发送前，MCP 按该 ID 定位标签页，并重新检查当前 URL。
- 如果绑定的标签页未打开，MCP 在共享浏览器中打开绑定文件里的确切对话 URL。禁止按标签页顺序、激活窗口或其他 Agent 的页面标记选择对话。
- 保存新绑定前，设置流程检查其他 Agent 是否已绑定该 `conversation_id`。新 Agent 创建或绑定一个独立的普通 ChatGPT 对话。
- 每个 Agent 的运行时文件和绑定仍保存在各自的 `state/<AGENT_ID>`、`logs/<AGENT_ID>` 和 `bindings/<AGENT_ID>.json` 中。只有浏览器 Host 文件由多个 Agent 共用。

### 并发和生命周期

- 所有 Agent 共用一个浏览器生命周期命名互斥锁，串行化 Host 创建、接管和关闭操作。
- 同一个 ChatGPT 对话的写入由以 `conversation_id` 为键的锁串行化。不同对话使用不同锁，并操作各自定位到的页面对象。
- 使用共享的账号级发送调度器，让多个 MCP 进程共同遵守配置的最小发送间隔，而不是分别按各自进程的计时器发送。
- 每次发送前重新检查绑定的对话 ID，并在同一个页面核对回复。发送超时后先检查对应对话，再决定是否重试。
- Host 端点缺失或无效、Profile 不匹配、对话路由不明确时，必须停止操作。Agent 不得用共享 Profile 再启动一个 Chrome，也不得静默退回原来的每 Agent 独立 Profile。
- 只有两个独立 Agent MCP 进程通过共享 Host 向不同的绑定对话发送消息，并分别收到正确回复后，才能报告并发隔离已验证。此方案会共享登录账号和浏览器进程，因此不宣称进程隔离或凭据隔离。

## 设置和兼容性

- 更新 PowerShell 辅助脚本、启动器、运行时覆盖文件及中英文 README，以便创建或加入共享浏览器 Host，同时保留每个 Agent 的专属资源。
- 新 Agent 设置必须加入经过验证的 Host，或显式指定用户现有的已登录 Chrome 用户数据目录。Host 不存在时，辅助脚本只登记或启动这一个既有目录，绝不创建 `browser-host\profile` 或 Agent 专属 Profile。
- 现有每 Agent Profile 保留原样，迁移后不再使用。现有安装通过显式迁移步骤加入已登记的共享 Host；共享 Profile 原样复用，不复制 Cookie。如果 Chrome 已打开该 Profile 但没有可验证的 CDP 端点，迁移会停止，并在重启浏览器前询问用户。
- Chrome 136 及更新版本会忽略对默认 Chrome 数据目录启用远程调试的开关。如果所选现有浏览器无法提供本 MCP 所需的 CDP 端点，Skill 停止，不创建替代 Profile。
- 运行时和启动错误应说明问题发生在 Host、Agent 绑定还是目标对话，并给出恢复方式，且保留其他 Agent 的文件和进程。

## 验收标准

1. 第一个 Agent 将现有已登录 Chrome 用户数据目录登记为 Browser Host；第二个 Agent 连接到相同的 Chrome PID、Profile 和 CDP 端口，不创建新 Profile。
2. 新配置的 Agent 和 MCP 进程重启后仍使用该既有登录态。
3. 两个 Agent 绑定不同的对话 ID。即使标签页顺序或焦点改变，各自仍只打开和读取自己的对话。
4. 同时向两个不同对话发送唯一消息时，消息进入正确页面；发送遵守共享调度器，回复也归属到对应的对话 ID。
5. 同一对话的写入会串行执行。发送超时后先核对是否已投递。
6. 断开或重启一个 Agent MCP 后，共享 Chrome 仍运行。只有显式关闭浏览器 Host 才会终止它。
7. Host 状态无效或绑定对话缺失时，操作安全停止，不创建 Agent 专属 Chrome Profile，也不选择其他对话。

## 风险和取舍

- 使用此 Host 的所有 Agent 会共用同一个已认证的 ChatGPT 账号会话。对话路由仍然分开，但浏览器登录态是共享的。
- 单个 Chrome 进程和账号级发送间隔可能限制吞吐量。不同对话可以使用独立写入锁，但仍须遵守 ChatGPT 账号实际施加的限制。
- Chrome 必须提供受支持的 CDP 端点。若普通浏览器不兼容，Skill 不会静默换成新 Profile，因为那会要求用户重新登录，也不再使用用户指定的浏览器会话。
