# Shared ChatGPT Browser Host Implementation Plan

> **Execution:** Implemented inline as selected by the user. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reuse one persistent signed-in Chrome browser across Codex conversations while keeping each Agent MCP process, state, and ChatGPT conversation binding independent.

**Architecture:** A shared Browser Host owns one Chrome Profile, dynamic CDP port, browser state, and lifecycle lock. Each Agent's stdio MCP connects to that host, resolves its own page by exact bound conversation ID, and keeps its logs and message state in Agent-specific directories. Writes serialize by conversation ID, while a shared scheduler enforces the account-level send interval.

**Tech Stack:** Windows PowerShell, Node.js ES modules, Playwright Chromium CDP connection, Codex TOML MCP configuration, JSON state files.

## Global Constraints

- Reuse one long-lived Chrome process and Profile for the local user.
- Keep a distinct MCP stdio process, Agent ID, message state, logs, and ChatGPT conversation binding for each Codex conversation.
- This design shares the browser login session; it does not make multiple Codex conversations share one MCP process.
- Do not copy cookies or credentials between Profiles.
- Each Agent must route only to its unique `conversation_id` and canonical `https://chatgpt.com/c/<conversation_id>` URL.
- Only the Browser Host manager may launch or terminate Chrome; Agent MCP processes attach over CDP and disconnect their own controller.
- Use one shared browser lifecycle lock, per-conversation write locks, and a shared account-level send scheduler.
- Fail closed on missing or invalid host state, mismatched Profile, or ambiguous conversation route; never select a tab by order or active-window state.
- Report cross-Agent concurrency as verified only after two independent Agent MCP processes receive replies from their respective bound conversations.

---

## Files and Responsibilities

- `templates/runtime-src/browser-host.js` — read and validate the shared Chrome Host manifest for Agent runtimes.
- `scripts/browser-host.ps1` — provide explicit Windows Host `Ensure`, `Status`, and `Stop` operations; this is the only component that starts or terminates Chrome.
- `templates/runtime-src/config.js` — add shared Browser Host paths while keeping Agent runtime, log, and binding paths independent.
- `templates/runtime-src/browser.js` — attach to the shared CDP endpoint, select the exact Agent page, and disconnect without terminating shared Chrome.
- `templates/runtime-src/index.js` — route operations with the bound conversation ID, use conversation-level serialization, and prevent an Agent tool from closing the shared browser.
- `templates/launcher.mjs` — pass shared Host paths and Agent-specific paths into the runtime.
- `templates/agent-call.mjs` — validate and persist the shared Host endpoint without assuming it belongs to an Agent-specific Profile.
- `scripts/new-agent-instance.ps1` — create Agent-specific state/log/binding resources and point the instance at the common Browser Host.
- `scripts/migrate-agent-to-shared-browser.ps1` — explicitly adopt an existing Agent Profile as the shared Host without copying its data or killing an active Chrome process.
- `SKILL.md`, `README.md`, `README.zh-CN.md` — document first-time host setup, sign-in, joining, migration, recovery, and shared-login limitations.

## Task 1: Add Shared Browser Host State and Lifecycle

**Files:**
- Create: `templates/runtime-src/browser-host.js`
- Modify: `templates/runtime-src/config.js`
- Create: `scripts/browser-host.ps1`

**Interfaces:**
- `readBrowserHostState()` returns the persisted host manifest or `null`.
- `assertBrowserHostState(state)` validates `{ host_id, pid, profile, port, endpoint, started_at }` and returns the normalized state or throws a host-specific error.
- `browser-host.ps1 -Action Ensure -HostRoot <path> -ProfilePath <path> -ChromeExecutable <path>` validates or starts the shared Chrome process and prints the verified manifest as JSON.
- `browser-host.ps1 -Action Status -HostRoot <path>` prints the verified manifest as JSON.
- `browser-host.ps1 -Action Adopt -HostRoot <path> -SourceInstancePath <path>` validates an existing managed Profile/PID/CDP tuple and registers it as the shared Host without copying Profile files.
- `browser-host.ps1 -Action Stop -HostRoot <path>` terminates only the verified host process.
- The PowerShell Host manager serializes startup, repair, adoption, and shutdown with a named Windows mutex derived from the canonical Host root.
- The host manifest at `<HostRoot>\host.json` contains `schema_version`, `host_id`, `pid`, `profile`, `port`, `endpoint`, and `started_at`.

```json
{
  "schema_version": 1,
  "host_id": "browser-host-<uuid>",
  "pid": 1234,
  "profile": "<existing signed-in Chrome user-data directory>",
  "port": 1940,
  "endpoint": "http://127.0.0.1:1940",
  "started_at": "2026-10-27T12:00:00.000Z"
}
```

- [x] Add config values for the shared host root, manifest, Profile, conversation-lock directory, and send-scheduler file. Keep `RUNTIME_STATE_FILE`, `AGENT_LOG_FILE`, and `BINDING_FILE` Agent-specific.
- [x] Define the default Host root and manifest under `<Root>\browser-host`; the Profile path is always adopted from an existing signed-in Chrome user-data directory and has no new-Profile default.
- [x] Implement atomic JSON writers for the host manifest and shared send schedule.
- [x] Serialize Host lifecycle operations with a named Windows mutex keyed by the canonical Host root; the OS releases it if its owner exits.
- [x] In `browser-host.ps1`, validate the Profile, live PID, CDP `/json/version`, process command line, recorded port, and listening socket owner before reuse.
- [x] If no valid Host exists, require an explicitly selected existing Chrome user-data directory with saved profile data. Acquire the lifecycle mutex, recheck state, then adopt its verified live CDP process or start Chrome against that same existing directory. Never create a new Profile. Write the manifest only after the process owns the listener.
- [x] Make `-Action Stop` terminate only the PID whose command line and listening socket match the recorded Profile and CDP port.
- [x] If Chrome owns the selected Profile but its CDP endpoint cannot be verified, fail with recovery guidance; do not start another Chrome or terminate it.
- [x] In `browser-host.js`, read and validate the Host manifest and expose its endpoint; it cannot spawn or stop Chrome.
- [x] Review Host lifecycle and missing-state code paths. Live Host checks remain outstanding.

```powershell
& '.\scripts\browser-host.ps1' -Action Status `
  -HostRoot "$env:USERPROFILE\.chatgpt-web-mcp\browser-host"
```

Expected: a JSON manifest whose PID command line contains the recorded `--user-data-dir` and `--remote-debugging-port` values.

## Task 2: Make Agent Runtimes Attach to the Shared Host

**Files:**
- Modify: `templates/runtime-src/browser.js`
- Modify: `templates/launcher.mjs`
- Modify: `templates/agent-call.mjs`

**Interfaces:**
- `ChatGPTBrowser.launch()` calls `readBrowserHostState()` and `assertBrowserHostState(state)`, then uses `chromium.connectOverCDP(state.endpoint)`; it never launches Chrome directly.
- `ChatGPTBrowser.close()` disconnects the local Playwright controller and leaves the shared Chrome process and pages running.
- `ChatGPTBrowser.agentRouteSnapshot()` reports the shared host's Profile/port/PID together with the current exact conversation URL and ID.

```js
const host = await readBrowserHostState();
assertBrowserHostState(host);
this.#browser = await chromium.connectOverCDP(host.endpoint);
this.#context = this.#browser.contexts()[0];
```

- [x] Import `readBrowserHostState()` and `assertBrowserHostState()` into `browser.js`; remove per-Agent port allocation and Chrome spawn logic.
- [x] Make `browser.js` use shared Host state while keeping its page reference per MCP Agent.
- [x] Change `launcher.mjs` to pass shared Host paths plus Agent-specific binding, state, and log paths.
- [x] Have `launcher.mjs` invoke the Host manager's `Ensure` before importing the runtime, and fail if the Host/Profile identity does not match.
- [x] Change `agent-call.mjs` to validate Host ID, Profile, PID, endpoint, and port, then atomically update the instance's observed port.
- [x] Ensure teardown disconnects the Playwright controller without closing the shared Chrome. Confirmed against official Playwright Browser API documentation.
- [x] Review startup paths: the Agent runtime no longer starts Chrome directly.

Expected: source review shows that setup references the shared Host paths; the per-Agent `state`, `logs`, and binding directories remain unique.

## Task 3: Preserve Per-Agent Conversation Routing and Safe Concurrency

**Files:**
- Modify: `templates/runtime-src/browser.js`
- Modify: `templates/runtime-src/index.js`
- Modify: `templates/runtime-src/agent-policy.js`
- Modify: `templates/runtime-src/config.js`

**Interfaces:**
- `operationLockPath({ agentId, conversationId })` returns a shared lock path keyed by the exact validated conversation ID, or by Agent ID during initial unbound conversation creation.
- `withOperationLock({ agentId, conversationId }, operation)` runs one operation while holding that cross-process lock.
- `ChatGPTBrowser.assertBoundPage(binding)` resolves the exact bound page and throws if its observed URL does not match the binding ID.
- `acquireSendSlot(signal)` enforces the configured send interval across all Agent processes and returns only after the shared slot is available.
- `assertAgentRoute({ agentId, binding, requestedConversationId, observedUrl })` continues to require the Agent binding ID and exact `chatgpt.com/c/<id>` URL.

```js
const binding = await readAgentBinding();
const lockKey = { agentId: AGENT_ID, conversationId: binding?.conversation_id || null };
return withOperationLock(lockKey, async () => {
  if (binding?.conversation_id) await browser.assertBoundPage(binding);
  if (sendTools.has(name)) await acquireSendSlot(extra.signal);
  if (binding?.conversation_id) await browser.assertBoundPage(binding);
  return handler(input);
});
```

- [x] Resolve bound pages by exact `conversation_id`; do not route bound operations by page order or window focus.
- [x] If a bound page is closed, create a page for the saved `conversation_url` and require the exact conversation path before using it.
- [x] Limit new binding creation to an unbound Agent and check all binding files before persisting a conversation ID.
- [x] Key cross-process operation locks by conversation ID so same-conversation writes serialize and different conversations use separate pages.
- [x] Add an account-level scheduler under the Host root. It holds the shared lock through the send click and records the next allowed time after that attempt.
- [x] Keep request IDs, round IDs, message IDs, logs, binding cursors, and timeout inspection under each Agent's files.
- [x] Refuse `chatgpt_close_browser` in Agent MCP instances; expose Host shutdown only through the explicit manager operation.
- [x] Review routing and lock code paths. Live two-Agent acceptance remains outstanding.

Expected: two different conversation IDs derive different write locks, while every send reserves its slot from the same Host scheduler file.

## Task 4: Update Provisioning and Existing-Profile Migration

**Files:**
- Modify: `scripts/new-agent-instance.ps1`
- Create: `scripts/migrate-agent-to-shared-browser.ps1`

**Interfaces:**
- New setup accepts `-BrowserHostRoot` (default `<Root>\browser-host`) and `-BrowserHostProfile` only when initializing the Host from an existing signed-in user-data directory. There is no new-Profile default.
- Migration accepts `-AgentId <existing-id>` and `-BrowserHostRoot <path>`; it preserves the selected Agent ID, server name, binding file, state directory, and log directory.
- New and migrated `instance.json` records `browser_host_root`, `browser_host_manifest`, shared `browser_profile`, shared `browser_state_file`, shared conversation-lock directory, and send-scheduler file. Host lifecycle serialization uses the manager's named mutex.
- Each instance also records `browser_host_manager_script`, pointing to the manager copied to `<BrowserHostRoot>\browser-host.ps1`.

```powershell
& '.\scripts\new-agent-instance.ps1' `
  -AgentId 'ag-codex-<uuid>' `
  -SourceDir 'C:\path\to\chatgpt-web-mcp' `
  -NodeExecutable 'C:\path\to\node.exe' `
  -ChromeExecutable 'C:\Program Files\Google\Chrome\Application\chrome.exe' `
  -CodexConfigPath "$env:USERPROFILE\.codex\config.toml"

& '.\scripts\migrate-agent-to-shared-browser.ps1' `
  -AgentId 'ag-codex-existing-id' `
  -Root "$env:USERPROFILE\.chatgpt-web-mcp"
```

- [x] Change `new-agent-instance.ps1` to reference the common Browser Host Profile/manifest while creating Agent-specific state/log/binding directories.
- [x] Limit overwrite checks to Agent-specific resources; reuse an existing Host root/Profile.
- [x] Copy the Host manager only if absent; refuse to overwrite a different manager.
- [x] Validate and reuse an existing Host during setup. If none exists, require an explicit existing signed-in user-data directory; fail before creating Agent resources when it is absent or incompatible.
- [x] Add explicit migration that joins one disconnected Agent to the already-verified shared Host without copying or opening its former Agent Profile.
- [x] Use `browser-host.ps1 -Action Ensure` to register a live CDP browser or start Chrome on the same existing user-data directory after it is closed normally.
- [x] Update only the selected Agent's runtime and Host fields; preserve its ID, server name, conversation, marker, message IDs, state, and logs.
- [x] Refuse migration for a running Agent, missing route, invalid endpoint, conflicting Host Profile, or duplicate conversation binding; never stop Chrome automatically.
- [x] Review generated instance/binding fields in source. Fresh provisioning was not executed.

Expected: running setup for two IDs produces the same `browser_profile`, `browser_host_manifest`, and CDP port, with different `agent_id`, `state_dir`, `log_dir`, `binding_file`, and `conversation_id`.

## Task 5: Update Skill Instructions and User Documentation

**Files:**
- Modify: `SKILL.md`
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `docs/superpowers/specs/2026-10-27-shared-chatgpt-browser-design.md`
- Modify: `docs/superpowers/specs/2026-10-27-shared-chatgpt-browser-design-zh-CN.md`

- [x] Update the Skill flow for one signed-in Host and separate MCP entries/conversation bindings.
- [x] Document existing-Profile reuse, Agent joining, exact routing, recovery, migration, and explicit Host shutdown. The flow does not create a Profile per Agent.
- [x] State the shared authenticated account session and avoid claiming process/credential isolation or verified concurrency.
- [x] Keep English and Chinese README setup commands, migration options, and limitations aligned.
- [x] Mark code/documentation status while explicitly stating that live and two-Agent checks have not run.

## Task 6: Final Review and Acceptance

**Files:**
- Review all files listed above.

- [x] Inspect the final diff for per-Agent state paths accidentally changed to shared paths and for Agent tool paths that launch/terminate Chrome. Static review found no direct Agent Chrome launch; state/log/binding paths remain per Agent.
- [ ] Perform the two-Agent acceptance scenario from the spec: start both instances, confirm one Chrome PID/Profile/CDP endpoint, bind two distinct conversations, send distinct unique prompts, and confirm each reply's conversation ID.
- [ ] Restart one MCP client and confirm the same Host PID, Profile, CDP endpoint, and binding are reused without another sign-in.
- [ ] Confirm a same-conversation concurrent write is serialized and the shared send scheduler applies across both Agent processes.
- [ ] Confirm stopping one MCP process leaves Chrome and the other Agent operational; exercise explicit Host shutdown only after both clients disconnect.
- [ ] Confirm `scripts/browser-host.ps1 -Action Stop` refuses to terminate a process whose Profile or CDP port no longer matches the Host manifest.
- [x] Record the completed static syntax/whitespace checks and state that live and two-Agent acceptance have not run. Do not claim cross-Agent isolation as verified.

## Execution Order

1. Task 1 defines the shared Host state and lifecycle API.
2. Task 2 wires each MCP runtime to that API.
3. Task 3 makes page selection, message writes, and browser shutdown safe under sharing.
4. Task 4 changes setup and adds the explicit existing-Profile migration path.
5. Task 5 updates the Skill and both READMEs to match the shipped behavior.
6. Task 6 reviews the diff and records observed acceptance results.
