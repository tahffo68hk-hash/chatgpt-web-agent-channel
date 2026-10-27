---
name: chatgpt-web-agent-channel
description: Use when a Codex conversation needs ChatGPT Web through chatgpt-web-mcp, especially when new conversations keep creating Chrome profiles or asking for repeated sign-ins, or when Agents need separate ChatGPT conversations in one already-signed-in browser.
---

# Reuse one signed-in ChatGPT browser

Connect every Agent to one persistent, already-signed-in Chrome Browser Host. Give each Codex conversation its own MCP process, stable Agent ID, state, logs, and ChatGPT `conversation_id`. Never create a Chrome Profile per Agent.

## Required behavior

- Reuse a verified Browser Host from `%USERPROFILE%\.chatgpt-web-mcp\browser-host\host.json` when present. Check its PID, existing Profile, and loopback CDP port before connecting.
- If no Host exists, initialize it only from an existing Chrome user-data directory selected by the user. Use `-BrowserHostProfile` to name that exact directory. The manager may adopt the running browser if CDP is already enabled, or start the same existing directory after it is closed normally. It must never create an empty Profile, copy cookies, or silently choose another browser.
- If Chrome is running without a verifiable CDP endpoint, stop. Explain that this MCP cannot attach to that process as launched. Ask before any browser restart, and reuse the same on-disk directory if the user approves. Never terminate Chrome automatically.
- If the existing browser cannot expose a supported CDP endpoint, stop and explain the limitation. Do not work around it by making a new Profile or asking the user to sign in again in a per-Agent browser.
- Every Agent keeps its own named stdio MCP entry, stable `AGENT_ID`, state/log directories, binding file, and unique ChatGPT conversation. Agents share only the Browser Host and login session.
- Select a bound tab only by the saved `conversation_id`; never use tab order, active-window state, or another Agent's reply cursor. Serialize writes to the same conversation.
- Do not alter another Agent's MCP process, binding, Profile, state, logs, or Codex configuration entry.

## Create or join an Agent

1. Inspect only the relevant MCP entry, existing Browser Host manifest, Chrome process/CDP endpoint, and this Agent's instance/binding files. Reuse this conversation's existing `AGENT_ID` on restarts.
2. If `host.json` exists, run `scripts/browser-host.ps1 -Action Status` and confirm it is live. New Agent setup then reuses its exact Profile and port; it does not create or launch an Agent-specific Profile.
3. If there is no Host, select the already-signed-in Chrome **user-data directory** (the parent of `Default`, not the `Default` folder) and initialize through the Agent helper:

   ```powershell
   & '<path-to-skill>\scripts\new-agent-instance.ps1' `
     -AgentId 'ag-codex-<uuid>' `
     -SourceDir '<existing-chatgpt-web-mcp-checkout>' `
     -NodeExecutable '<existing-node.exe>' `
     -ChromeExecutable '<chrome.exe>' `
     -CodexConfigPath "$env:USERPROFILE\.codex\config.toml" `
     -BrowserHostProfile '<existing-signed-in-Chrome-user-data-directory>'
   ```

   Omit `-BrowserHostProfile` only when joining a verified Host. If the profile is open without CDP, the helper refuses without creating an Agent. Do not close or restart it unless the user approves. If the same existing profile is signed out, ask the user to sign in there once; never create a replacement Profile.

4. The helper creates only Agent-specific MCP/state/log/binding resources and records the shared Host Profile. Bind one distinct `conversation_id` for this Agent after checking that no other binding claims it.
5. Restart the named MCP entry or run that Agent's `agent-call.mjs chatgpt_status` after the prior MCP process has disconnected. Do not run a second wrapper process under the same Agent ID while its MCP is still active.

## Existing Agent migration

Use `scripts/migrate-agent-to-shared-browser.ps1` for one selected, disconnected Agent. It preserves that Agent's ID, MCP name, conversation binding, message cursors, state, and logs while switching it to the already-verified shared Host. It does not copy, delete, or open the old Agent Profile. If no Host exists, pass `-BrowserHostProfile` for the already-signed-in directory; the same no-new-Profile rules apply.

## Routing and recovery

- Before a send, verify this Agent ID and its saved conversation ID. Read replies only from that conversation. A timeout is an unknown delivery state: inspect that exact conversation before retrying.
- A missing Host or missing bound page is not permission to create a new Profile or select another tab. Reconnect to the saved Host; if the bound page is closed, open the exact saved conversation URL in the shared browser.
- Chrome 136 and later ignores remote-debugging switches for the default Chrome data directory. If the existing signed-in browser cannot provide the CDP endpoint this MCP requires, stop and explain the incompatibility. Do not create a per-Agent Profile to bypass it. See [Chrome's remote-debugging change](https://developer.chrome.com/blog/remote-debugging-port).
- An Agent MCP disconnect leaves the shared Chrome open. Stop the Browser Host only after every Agent has disconnected and the user explicitly asks to close it.
- Claim cross-Agent concurrency only after two independent MCP processes send unique messages to different bound conversations and each receives the reply from its own conversation. Otherwise report it as unverified.

## Report

Report the stable Agent ID, named MCP server, shared Host ID/CDP port/Profile, conversation URL, instance/binding/config paths, startup/reconnect method, checks actually completed, whether two-Agent concurrency was tested, and which existing processes/configurations were left untouched. State clearly that all joined Agents share the authenticated Chrome session.
