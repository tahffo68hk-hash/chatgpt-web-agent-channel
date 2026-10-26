# ChatGPT Web MCP Agent Channel

A Codex Skill and PowerShell helper for giving each Windows Agent its own `chatgpt-web-mcp` process, Chrome Profile, CDP port, state/log paths, and conversation binding.

## Requirements

- Windows 10/11 and Codex Desktop
- An existing `chatgpt-web-mcp` checkout with its dependencies already installed
- Node.js and Chrome or Edge already installed
- The bundled runtime overlay matches `chatgpt-web-mcp` `0.2.1` at commit `d6c1909151d9d13b439af1f519513ebee2267893`

For a different source revision, use a compatible Agent runtime template or review and adapt the overlay. The helper refuses a different package version or Git revision when using the bundled files.

## Install the Skill

Clone this repository and copy the repository root into `%USERPROFILE%\.agents\skills\chatgpt-web-agent-channel`, or use your preferred Codex Skill installer. The repository root contains `SKILL.md`.

## Create an Agent instance

Choose one stable, unique ID for the Agent and run the helper from PowerShell:

```powershell
& '.\scripts\new-agent-instance.ps1' `
  -AgentId 'ag-codex-<uuid>' `
  -SourceDir 'C:\path\to\chatgpt-web-mcp' `
  -NodeExecutable 'C:\path\to\node.exe' `
  -ChromeExecutable 'C:\Program Files\Google\Chrome\Application\chrome.exe' `
  -CodexConfigPath "$env:USERPROFILE\.codex\config.toml"
```

If the checkout differs from the bundled revision, add `-TemplateAgentRoot` pointing at a healthy Agent instance that uses this same source checkout. The helper creates only new Agent-specific directories and an independently named Codex MCP entry; it reuses `node_modules` and leaves existing Agents untouched.

The first `agent-call.mjs chatgpt_status` launches Chrome with the new empty Profile. Sign in normally in that Profile, then bind a new conversation as described in `SKILL.md`.

## Isolation model

Each named stdio server starts its own Node process. The launcher gives it a unique Chrome Profile and per-Agent browser/runtime state paths. The source allocates and persists an available loopback CDP port. The binding records one real conversation ID and URL, and routing checks use the Agent ID and conversation ID.

The Skill never copies cookies, tokens, or another Agent's state. Cross-Agent concurrency is only reported as verified after two independent Agents complete a simultaneous unique-message test.

## License

This Skill and its helper scripts are MIT licensed; see `LICENSE`. The bundled runtime overlay is based on the upstream MIT-licensed `Goudu666/chatgpt-web-mcp`; see `UPSTREAM-LICENSES/chatgpt-web-mcp-MIT.txt`.
