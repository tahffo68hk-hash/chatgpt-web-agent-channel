export function assertAgentRoute({ agentId, binding, requestedConversationId, observedUrl }) {
  if (!agentId || binding?.agent_id !== agentId) {
    throw new Error("Agent ID mismatch; refusing cross-Agent routing.");
  }

  const expected = String(binding?.conversation_id || "");
  if (!expected) throw new Error("No conversation is bound to this Agent.");
  if (requestedConversationId && requestedConversationId !== expected) {
    throw new Error("Conversation ID mismatch; refusing cross-conversation routing.");
  }

  let parsed;
  try {
    parsed = new URL(observedUrl);
  } catch {
    throw new Error("Observed conversation URL is invalid.");
  }
  const parts = parsed.pathname.split("/").filter(Boolean);
  if (parsed.hostname !== "chatgpt.com" || parts.length !== 2 || parts[0] !== "c" || parts[1] !== expected) {
    throw new Error("Conversation URL mismatch; refusing cross-conversation routing.");
  }

  return true;
}

