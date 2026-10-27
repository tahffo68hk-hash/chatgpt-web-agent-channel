# ChatGPT Web MCP Agent Channel

[简体中文](README.zh-CN.md)

This Skill lets local Codex conversations use **one already-signed-in Chrome browser and Profile**. Every conversation keeps its own `chatgpt-web-mcp` process, MCP entry, Agent ID, state/log directories, and ChatGPT conversation binding. Starting a new Codex conversation does not create another Chrome Profile or prompt for another sign-in.

Agents share only the Browser Host and login session; each Agent must bind a different `conversation_id`. This does not provide browser-process or credential isolation. Do not claim cross-Agent concurrency is verified until the live two-Agent send/reply check has passed.

## Requirements

- Windows 10/11, Codex Desktop, and PowerShell
- An existing `chatgpt-web-mcp` checkout with its dependencies installed
- Node.js and Chrome or Edge
- An already-signed-in Chrome user data directory; the bundled runtime overlay targets `chatgpt-web-mcp` `0.2.1` at commit `d6c1909151d9d13b439af1f519513ebee2267893`

For a different source revision, use a compatible Agent runtime template or review and adapt the overlay first. The helper refuses a mismatched version or commit.

## Install the Skill

Clone this repository and copy its root to `%USERPROFILE%\.agents\skills\chatgpt-web-agent-channel`, or use the Codex Skill installer.

## Join the already-signed-in browser

When `%USERPROFILE%\.chatgpt-web-mcp\browser-host\host.json` exists and passes `Status`, new Agents reuse its exact Profile, Chrome process, and CDP port. Omit `-BrowserHostProfile` when joining that Host.

For the first Host setup, pass the path to an **existing signed-in Chrome user data directory**. It is the parent of `Default`, `Profile 1`, or another Chrome profile directory. Do not pass the `Default` child or a path that does not exist:

```powershell
& '.\scripts\new-agent-instance.ps1' `
  -AgentId 'ag-codex-<uuid>' `
  -SourceDir 'C:\path\to\chatgpt-web-mcp' `
  -NodeExecutable 'C:\path\to\node.exe' `
  -ChromeExecutable 'C:\Program Files\Google\Chrome\Application\chrome.exe' `
  -CodexConfigPath "$env:USERPROFILE\.codex\config.toml" `
  -BrowserHostProfile '<existing signed-in Chrome user data directory>'
```

If Chrome already uses that Profile with a verifiable CDP endpoint, the helper adopts it. If Chrome is running without CDP, setup stops; it will not launch another browser or create a Profile. A browser restart requires the user's approval and must reuse the same directory. Chrome 136 and later do not allow remote debugging against Chrome's default data directory. If the existing browser cannot provide the required endpoint, setup stops instead of creating a new per-Agent Profile. See [Chrome's remote-debugging change](https://developer.chrome.com/blog/remote-debugging-port).

Once the shared Host is valid, use the same command with a new stable Agent ID for each Codex conversation and omit `-BrowserHostProfile`. The helper creates only Agent-specific MCP, state, log, and binding resources. Every Agent's `browser_profile` points to the same Host Profile. It never copies cookies, tokens, or Profile data.

## Migrate an existing Agent

Disconnect the selected Agent's MCP normally, then run:

```powershell
& '.\scripts\migrate-agent-to-shared-browser.ps1' `
  -AgentId 'ag-codex-existing-id' `
  -Root "$env:USERPROFILE\.chatgpt-web-mcp"
```

If no shared Host exists, also pass `-BrowserHostProfile '<existing signed-in Chrome user data directory>'`. Migration changes only the selected Agent and preserves its ID, MCP name, bound conversation ID, message cursors, state, and logs. It does not copy, delete, or open the old Agent Profile. Review the backup created in `archives` before migration.

## Reconnect, inspect, and stop

- Restart the same named MCP entry to reconnect. Do not create a new Agent ID for each restart.
- Inspect the Host:

  ```powershell
  & '.\scripts\browser-host.ps1' -Action Status `
    -HostRoot "$env:USERPROFILE\.chatgpt-web-mcp\browser-host"
  ```

- Disconnecting one Agent leaves Chrome open. Stop the Host only after every Agent has disconnected and the user explicitly asks to close it.

Every send/read routes by the current Agent's bound `conversation_id`, never by tab order or active-tab state. Agent message logs and reply cursors remain separate. Writes to the same conversation are serialized, and the shared scheduler coordinates account-level send intervals. Report concurrency as unverified until two Agents pass the live simultaneous send/reply check.

## License

This Skill and its helpers are MIT licensed; see [`LICENSE`](LICENSE). The runtime overlay is based on upstream MIT-licensed `Goudu666/chatgpt-web-mcp`; see [`UPSTREAM-LICENSES/chatgpt-web-mcp-MIT.txt`](UPSTREAM-LICENSES/chatgpt-web-mcp-MIT.txt).
