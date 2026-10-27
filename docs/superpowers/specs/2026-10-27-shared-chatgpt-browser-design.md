# Shared ChatGPT Browser Host for Per-Agent Channels

Date: 2026-10-27

## Implementation status

The repository now contains the shared Browser Host manager, per-Agent attach/routing changes, provisioning and explicit Profile adoption helpers, and bilingual usage documentation. Static Node and PowerShell syntax checks have passed. No live ChatGPT sign-in/reconnect or two-Agent simultaneous send/reply test has been run in this change, so cross-Agent concurrency is not yet verified.

[简体中文](2026-10-27-shared-chatgpt-browser-design-zh-CN.md)

## Problem

The current helper creates a Chrome Profile, CDP state file, and browser lifecycle for every Agent ID. A new Codex conversation therefore starts a fresh Profile and requires another ChatGPT sign-in. The user wants one persistent, signed-in browser reused by multiple Codex conversations while each conversation continues to use its own ChatGPT conversation ID.

## Goal

Reuse one long-lived Chrome process and Profile for the local user. Keep a distinct MCP stdio process, Agent ID, message state, logs, and ChatGPT conversation binding for each Codex conversation. An Agent must address only the exact ChatGPT conversation recorded in its own binding.

This design shares the browser login session; it does not make multiple Codex conversations share one MCP process. It does not copy cookies or credentials between Profiles.

## Architecture

### Shared Browser Host

- Add one persistent Browser Host under the common `chatgpt-web-mcp` root. It owns one Chrome process, one shared Profile, one dynamically allocated loopback CDP port, browser state, and lifecycle lock.
- The first setup registers an explicitly selected, existing signed-in Chrome user-data directory as the Host. Later Agent setups discover and reuse its persisted state. A named Windows mutex derived from the canonical Host root serializes concurrent startup, adoption, and shutdown. Setup never creates a new Chrome Profile.
- Chrome is the only process allowed to open the shared Profile. Browser Host startup validates the recorded PID, Profile path, and CDP port before reusing the endpoint.
- Only the Browser Host manager may launch or terminate Chrome. Agent MCP processes attach over CDP and disconnect their own controller when an MCP call ends. An Agent lifecycle call must not terminate the shared Chrome process.
- The chosen Host Profile is the user's existing login session. Existing cookies are never copied from another Profile. If Chrome cannot expose a verifiable CDP endpoint, setup stops instead of launching a per-Agent Profile.

### Per-Agent MCP and Conversation Routing

- Each Codex conversation retains a stable, unique Agent ID and independently named MCP server entry. The MCP process continues to use its own Agent state, message log, binding file, request IDs, and response cursors.
- Each Agent binding stores one unique `conversation_id` and its canonical `https://chatgpt.com/c/<conversation_id>` URL. Before reading or sending, the MCP resolves a live page by that exact conversation ID and rechecks the observed URL.
- If the bound page is not open, the MCP opens the exact saved conversation URL in a new tab in the shared browser. It never selects by tab order, active window, or another Agent's page marker.
- Before a new binding is saved, setup checks that no other Agent binding already owns that conversation ID. It creates or binds a distinct ordinary ChatGPT conversation for the new Agent.
- Each Agent's runtime and binding files remain in its own `state/<AGENT_ID>`, `logs/<AGENT_ID>`, and `bindings/<AGENT_ID>.json` locations. Only Browser Host files are shared.

### Concurrency and Lifecycle

- Keep one named browser lifecycle mutex shared across all Agent instances to serialize host creation, adoption, and shutdown.
- Keep writes to one ChatGPT conversation serialized by a lock keyed to that conversation ID. Different conversations use different locks and target different page objects.
- Use a shared account-level send scheduler so multiple MCP processes honor the configured minimum send interval together, instead of independently applying a per-process interval.
- Recheck the bound conversation ID immediately before a send and verify the reply on the same page. On timeout, inspect that conversation before retrying.
- A missing or invalid host endpoint, mismatched Profile, or ambiguous conversation route stops the operation. An Agent must not start a second Chrome against the shared Profile or silently fall back to its old per-Agent Profile.
- Concurrency isolation is reported as verified only after two independent Agent MCP processes use different bound conversations through the shared host and receive the correct replies. The single-browser design shares the logged-in account and browser process, so it does not claim process or credential isolation.

## Setup and Compatibility

- Update the PowerShell helper, launcher, runtime overlay, and English/Chinese READMEs to provision or join the shared Browser Host while retaining per-Agent resources.
- New Agent setup requires a verified Host or an explicit path to the user's existing signed-in Chrome user-data directory. If the Host is absent, the helper registers or starts only that same existing directory; it never provisions `browser-host\profile` or an Agent-specific Profile.
- Existing per-Agent Profiles are left untouched and unused after migration. An existing installation joins the already-registered shared Host through an explicit migration step. The selected Host Profile is reused in place without copying cookies. If Chrome already owns that Profile without a verifiable CDP endpoint, migration stops and asks the user before any restart.
- Chrome 136 and later ignores remote-debugging switches for the default Chrome data directory. If the selected existing browser cannot expose the CDP endpoint this MCP requires, the Skill stops and does not create a replacement Profile.
- Runtime and startup errors must identify whether the issue is the host, Agent binding, or target conversation, and must give a recovery step that preserves the other Agents' files and processes.

## Acceptance Checks

1. The first Agent registers one existing signed-in Chrome user-data directory as Browser Host; a second Agent attaches to the same Chrome PID, Profile, and CDP port. No new Profile is created.
2. The existing login remains effective for newly configured Agents and after an MCP process restart.
3. Two Agent bindings point to distinct conversation IDs. Each Agent opens and reads only its own conversation even when the tabs are reordered and focus changes.
4. Concurrent sends to those distinct conversations are routed to the correct pages, respect the shared send scheduler, and produce replies attributed to the matching conversation IDs.
5. Same-conversation writes serialize. A timed-out send is checked before a retry.
6. Disconnecting or restarting an Agent MCP leaves the shared Chrome process running. Only explicit Browser Host shutdown terminates it.
7. Invalid host state or a missing bound conversation fails closed without creating a per-Agent Chrome Profile or selecting another conversation.

## Risks and Trade-offs

- All Agents using the host share the same authenticated ChatGPT account session. Conversation routing remains separate, but the browser login is intentionally shared.
- One Chrome process and account-wide send pacing can limit throughput. Different conversations may have separate write locks, but observed ChatGPT account limits still apply.
- Chrome must expose a supported CDP endpoint. The Skill does not silently replace an incompatible normal browser with a new Profile, because doing so would require another sign-in and change the user's requested session.
