# Shared ChatGPT Browser Host for Per-Agent Channels

Date: 2026-10-27

[简体中文](2026-10-27-shared-chatgpt-browser-design-zh-CN.md)

## Problem

The current helper creates a Chrome Profile, CDP state file, and browser lifecycle for every Agent ID. A new Codex conversation therefore starts a fresh Profile and requires another ChatGPT sign-in. The user wants one persistent, signed-in browser reused by multiple Codex conversations while each conversation continues to use its own ChatGPT conversation ID.

## Goal

Reuse one long-lived Chrome process and Profile for the local user. Keep a distinct MCP stdio process, Agent ID, message state, logs, and ChatGPT conversation binding for each Codex conversation. An Agent must address only the exact ChatGPT conversation recorded in its own binding.

This design shares the browser login session; it does not make multiple Codex conversations share one MCP process. It does not copy cookies or credentials between Profiles.

## Architecture

### Shared Browser Host

- Add one persistent Browser Host under the common `chatgpt-web-mcp` root. It owns one Chrome process, one shared Profile, one dynamically allocated loopback CDP port, browser state, and lifecycle lock.
- The first setup creates the host if absent. Later Agent setups discover and reuse its persisted state. Concurrent startup must be protected by the host lifecycle lock so two setups cannot launch Chrome against the same Profile.
- Chrome is the only process allowed to open the shared Profile. Browser Host startup validates the recorded PID, Profile path, and CDP port before reusing the endpoint.
- Only the Browser Host manager may launch or terminate Chrome. Agent MCP processes attach over CDP and disconnect their own controller when an MCP call ends. An Agent lifecycle call must not terminate the shared Chrome process.
- The user signs in normally once in the Browser Host Profile. Existing cookies are never copied from another Profile.

### Per-Agent MCP and Conversation Routing

- Each Codex conversation retains a stable, unique Agent ID and independently named MCP server entry. The MCP process continues to use its own Agent state, message log, binding file, request IDs, and response cursors.
- Each Agent binding stores one unique `conversation_id` and its canonical `https://chatgpt.com/c/<conversation_id>` URL. Before reading or sending, the MCP resolves a live page by that exact conversation ID and rechecks the observed URL.
- If the bound page is not open, the MCP opens the exact saved conversation URL in a new tab in the shared browser. It never selects by tab order, active window, or another Agent's page marker.
- Before a new binding is saved, setup checks that no other Agent binding already owns that conversation ID. It creates or binds a distinct ordinary ChatGPT conversation for the new Agent.
- Each Agent's runtime and binding files remain in its own `state/<AGENT_ID>`, `logs/<AGENT_ID>`, and `bindings/<AGENT_ID>.json` locations. Only Browser Host files are shared.

### Concurrency and Lifecycle

- Keep one browser lifecycle lock shared across all Agent instances to serialize host creation, health checks that can mutate host state, and shutdown.
- Keep writes to one ChatGPT conversation serialized by a lock keyed to that conversation ID. Different conversations use different locks and target different page objects.
- Use a shared account-level send scheduler so multiple MCP processes honor the configured minimum send interval together, instead of independently applying a per-process interval.
- Recheck the bound conversation ID immediately before a send and verify the reply on the same page. On timeout, inspect that conversation before retrying.
- A missing or invalid host endpoint, mismatched Profile, or ambiguous conversation route stops the operation. An Agent must not start a second Chrome against the shared Profile or silently fall back to its old per-Agent Profile.
- Concurrency isolation is reported as verified only after two independent Agent MCP processes use different bound conversations through the shared host and receive the correct replies. The single-browser design shares the logged-in account and browser process, so it does not claim process or credential isolation.

## Setup and Compatibility

- Update the PowerShell helper, launcher, runtime overlay, and English/Chinese READMEs to provision or join the shared Browser Host while retaining per-Agent resources.
- New Agent setup reuses the existing host if its manifest and process checks pass; otherwise it bootstraps one host and asks the user to sign in in that Profile.
- Existing per-Agent Profiles are left untouched. An existing installation joins the shared host only through an explicit migration step after the user chooses the host Profile. The selected existing Profile may be adopted in place, preserving its current login without copying cookies. If Chrome already owns that Profile, migration must verify and adopt its live PID/CDP endpoint rather than launch another Chrome process against it.
- Runtime and startup errors must identify whether the issue is the host, Agent binding, or target conversation, and must give a recovery step that preserves the other Agents' files and processes.

## Acceptance Checks

1. The first Agent starts one Browser Host; a second Agent attaches to the same Chrome PID, Profile, and CDP port without launching another Chrome process.
2. Signing in once in the host Profile remains effective for a newly configured Agent and after an MCP process restart.
3. Two Agent bindings point to distinct conversation IDs. Each Agent opens and reads only its own conversation even when the tabs are reordered and focus changes.
4. Concurrent sends to those distinct conversations are routed to the correct pages, respect the shared send scheduler, and produce replies attributed to the matching conversation IDs.
5. Same-conversation writes serialize. A timed-out send is checked before a retry.
6. Disconnecting or restarting an Agent MCP leaves the shared Chrome process running. Only explicit Browser Host shutdown terminates it.
7. Invalid host state or a missing bound conversation fails closed without creating a per-Agent Chrome Profile or selecting another conversation.

## Risks and Trade-offs

- All Agents using the host share the same authenticated ChatGPT account session. Conversation routing remains separate, but the browser login is intentionally shared.
- One Chrome process and account-wide send pacing can limit throughput. Different conversations may have separate write locks, but observed ChatGPT account limits still apply.
- Existing per-Agent installations need an explicit migration decision; automatically copying Profile data would violate the no-cookie-copy requirement.
