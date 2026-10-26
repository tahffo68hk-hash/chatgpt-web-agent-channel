---
name: chatgpt-web-agent-channel
description: Set up, repair, or verify a persistent per-Agent chatgpt-web-mcp channel on Windows with Codex. Use it when an Agent needs its own MCP server entry, Chrome profile/CDP port, state/log directories, or ChatGPT conversation binding, especially when another Agent already uses the shared ChatGPT web MCP. Also trigger for Chinese requests such as 给每个 Agent 配独立 ChatGPT MCP、解决会话串线、隔离 Chrome Profile 或固定 conversation_id. Do not use it for ordinary ChatGPT conversations.
---

# Per-Agent ChatGPT Web MCP channel

Use this skill when an Agent needs a durable ChatGPT web channel that cannot inherit another Agent's browser profile, CDP port, conversation binding, or message state.

## Compatibility

This package targets Windows and Codex Desktop. It reuses an installed `chatgpt-web-mcp` checkout and its existing `node_modules`; it does not install the MCP or its dependencies. The bundled runtime overlay matches upstream `chatgpt-web-mcp` version `0.2.1`, commit `d6c1909151d9d13b439af1f519513ebee2267893`. For another source version, use a known-compatible local Agent runtime template or inspect and adapt the overlay to that version before starting it. Do not assume a code patch is compatible just because the package version string matches.

## Keep the setup small

- Reuse the installed `chatgpt-web-mcp` source and `node_modules`. Do not reinstall packages or edit the shared source tree.
- Keep one stable `AGENT_ID` for this Agent. Reuse the ID in its `instance.json` on restarts; never generate a new ID each launch.
- Give the Agent its own named MCP server, Chrome Profile, dynamic CDP port, state, logs, binding file, and ChatGPT conversation.
- Do not stop or rewrite another Agent's MCP process, browser, profile, binding, or configuration entry. Do not copy cookies or credentials.
- Keep routing checks to the useful invariants: this Agent's ID, its own browser profile/CDP process, and the bound conversation ID on `chatgpt.com`. A separate full-URL string comparison after matching host and conversation ID is redundant.
- Do not choose a tab by order or active-window state. Once bound, select the page by the saved conversation ID. Serialize writes within this Agent's MCP instance.

## Set up an instance

1. Inspect only the relevant Codex MCP entry, `chatgpt-web-mcp` source/dependencies, matching Chrome process/CDP state, and existing Agent instance/binding files. Reuse an existing instance for this Agent if one is already recorded.
2. If this is a new Agent, make a unique ID once, such as `ag-codex-<uuid>`, and save it in the new `instance.json`. The helper uses the bundled overlay for its pinned upstream revision. If the local MCP checkout differs, use a healthy, compatible per-Agent runtime template or adapt the overlay to the installed source first. Never copy another Agent's `instance.json`, binding, state, logs, or Chrome Profile.
3. Scaffold the new directories and named Codex server entry with the helper. Supply the existing source, Node, Chrome, and Codex config paths found during inspection:

   ```powershell
   & '<path-to-skill>\scripts\new-agent-instance.ps1' `
     -AgentId 'ag-codex-<uuid>' `
     -SourceDir '<path-to-chatgpt-web-mcp>' `
     -NodeExecutable '<path-to-existing-node.exe>' `
     -ChromeExecutable '<path-to-chrome.exe>' `
     -CodexConfigPath '<path-to-Codex-config.toml>'
   ```

   `-TemplateAgentRoot` is optional when that instance contains a compatible runtime overlay. The helper creates only new Agent-specific paths, links to the existing dependencies, and adds an independently named MCP table under a short lock with atomic replacement. It refuses to overwrite an existing instance.
4. Start the dedicated MCP with `agent-call.mjs chatgpt_status`. The server starts its own Chrome using the new Profile and allocates a free loopback CDP port. Read `browser-state.json` and verify the Chrome command line contains this Agent's exact `--user-data-dir` and `--remote-debugging-port`; record the observed port in `instance.json`.
5. If the new Profile is signed out, ask the user to sign in normally in that Profile. Do not import cookies or tokens from any other browser.
6. Bind one new, ordinary ChatGPT conversation through the dedicated instance using a unique Agent marker. Save the real conversation ID and URL to `bindings/<AGENT_ID>.json` and `instance.json`. Before saving, check that no other binding file already has that conversation ID. If an MCP send times out, inspect that exact conversation and its latest response before considering a retry; never resend blindly.
7. Verify with the dedicated MCP that status and latest-response reads return the saved conversation ID, URL, and expected message. Start a fresh MCP client once to confirm it reconnects to the same Chrome process/Profile and binding.
8. If the Codex config is not hot-reloaded, keep using this Agent's `agent-call.mjs` wrapper until the named MCP server appears after a Codex MCP reload. Do not use the legacy shared server as a fallback.

## Message routing

- Send and read only through this Agent's named server/wrapper and bound conversation.
- Keep per-request IDs and send round IDs in this Agent's log. Record actual ChatGPT message IDs when the UI/API exposes them; leave them null when unavailable instead of substituting request IDs.
- Treat a timeout as an unknown delivery state. Read the latest response from the bound conversation first; retry only if the unique prompt is absent.
- Do not treat another Agent's reply cursor, last response, state file, or pending task as this Agent's input.
- Only claim dual-Agent concurrency after two known independent instances send unique prompts at the same time and each receives the reply from its own bound conversation. If the second Agent's independent route is not available, report that concurrency remains unverified.

## Report

Give the user the `AGENT_ID`, server name, CDP port, Profile path, conversation URL, instance/binding/config file links, and the exact startup/reconnect method. State which single-Agent and dual-Agent checks actually passed. Confirm which existing processes/config entries were left untouched. Mention if the current Codex session still needs an MCP reload.
