#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { z } from "zod";

import { ChatGPTBrowser } from "./browser.js";
import {
  AGENT_ID,
  AGENT_LOG_FILE,
  BINDING_FILE,
  BINDING_MARKER,
  DEFAULT_ANSWER_TIER,
  CONVERSATION_CHANGE_INTERVAL_MS,
  CONTEXT_ARCHIVE_DIR,
  MAX_CONVERSATION_TURNS,
  MCP_SERVER_NAME,
  PROBE_ENABLED,
  PROBE_PROMPT,
  PRO_ANSWER_TIER,
  PRO_PROBE_RECHECK_AFTER_CLOSE_MS,
  POST_RESPONSE_CONVERSATION_COOLDOWN_MS,
  REFRESH_BEFORE_NEW_CHAT,
  RESPONSE_TIMEOUT_MS,
  SEND_INTERVAL_MS,
} from "./config.js";
import { assertAgentRoute } from "./agent-policy.js";
import { userFacingError } from "./errors.js";

const browser = new ChatGPTBrowser();
const probeInstructions = PROBE_ENABLED
  ? `实验性网络身份探针已显式启用：仅在用户要求身份核对时使用，非 mini 的 model_slug 不等于已经验证为 Pro。探针不会强制选择 Pro 档位。同一页面会话复用缓存，关闭后保留 ${Math.round(PRO_PROBE_RECHECK_AFTER_CLOSE_MS / 3_600_000)} 小时；forceProbe 仅用于用户明确要求重新验证。`
  : "临时 Pro 身份探针默认停用。不得调用 chatgpt_probe_pro_identity，也不得用 requestPro=true 调用 chatgpt_route_new_chat；这些调用会在新建临时对话或发送测试消息前停止。普通极高路由使用 requestPro=false。";
const server = new McpServer({
  name: MCP_SERVER_NAME,
  version: "0.2.1",
}, {
  instructions:
    `${AGENT_ID ? `Agent ${AGENT_ID} 专属实例：只允许使用绑定对话；请求/回复以 agent_id、request_id、conversation_id、round_id 记账。发送超时先核对投递状态，禁止盲目重复。` : ""}默认保持专用浏览器和 ChatGPT 页面常驻，除非用户明确要求，否则绝不调用 chatgpt_close_browser。发送最小间隔 ${SEND_INTERVAL_MS / 1_000} 秒，对话变更最小间隔 ${CONVERSATION_CHANGE_INTERVAL_MS / 1_000} 秒，回答完成后再等 ${POST_RESPONSE_CONVERSATION_COOLDOWN_MS / 1_000} 秒才切换；这些是下限，不保证免于限流。新建前的额外刷新当前${REFRESH_BEFORE_NEW_CHAT ? "开启" : "关闭"}，由 CHATGPT_WEB_REFRESH_BEFORE_NEW_CHAT 控制。每次发送前仍刷新当前对话，并校验 URL、草稿和附件；检测到变化则停止。对话达到 ${MAX_CONVERSATION_TURNS} 轮或出现 maximum-length 错误时，原子发送会先读取完整 transcript 并归档到 ${CONTEXT_ARCHIVE_DIR}，再新建普通对话；直接 submit_prompt 则拦截。新任务优先用 chatgpt_route_new_chat，普通请求使用页面可用档位“${DEFAULT_ANSWER_TIER}”。${probeInstructions}`,
});

function asResult(value, isError = false) {
  return {
    isError,
    content: [
      {
        type: "text",
        text: JSON.stringify(value, null, 2),
      },
    ],
  };
}

const sendTools = new Set([
  "chatgpt_route_new_chat",
  "chatgpt_send_message",
  "chatgpt_submit_prompt",
]);
const readRequiresBinding = new Set([
  "chatgpt_get_latest_response",
  "chatgpt_archive_conversation",
  "chatgpt_select_history",
  "chatgpt_list_history",
  "chatgpt_search_history",
]);

async function readAgentBinding() {
  if (!AGENT_ID) return null;
  try {
    const binding = JSON.parse(await fs.readFile(BINDING_FILE, "utf8"));
    if (binding.agent_id !== AGENT_ID) {
      throw new Error("Agent ID mismatch in persistent conversation binding.");
    }
    return binding;
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

async function writeAgentBinding(binding) {
  await fs.mkdir(path.dirname(BINDING_FILE), { recursive: true });
  const temporaryPath = `${BINDING_FILE}.${process.pid}.${randomUUID()}.tmp`;
  await fs.writeFile(temporaryPath, `${JSON.stringify(binding, null, 2)}\n`, {
    mode: 0o600,
  });
  await fs.rename(temporaryPath, BINDING_FILE);
}

async function appendAgentLog(record) {
  if (!AGENT_ID) return;
  await fs.mkdir(path.dirname(AGENT_LOG_FILE), { recursive: true });
  await fs.appendFile(AGENT_LOG_FILE, `${JSON.stringify(record)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
}

function requestedConversationId(name, input) {
  if (name !== "chatgpt_select_history") return null;
  if (input.conversationId) return input.conversationId;
  if (input.url) {
    try {
      const parts = new URL(input.url).pathname.split("/").filter(Boolean);
      return parts[0] === "c" ? parts[1] || null : null;
    } catch {
      return null;
    }
  }
  return null;
}

async function guardAgentRoute(name, input) {
  if (!AGENT_ID) return null;
  const binding = await readAgentBinding();
  if (!binding?.conversation_id) {
    const isInitialNewChat =
      name === "chatgpt_route_new_chat" ||
      (name === "chatgpt_send_message" && input.newChat && !input.temporary);
    if (sendTools.has(name) && !isInitialNewChat) {
      throw new Error("This Agent has no bound conversation; only one marked new-chat bootstrap is allowed.");
    }
    if (isInitialNewChat && (!BINDING_MARKER || !input.prompt?.includes(BINDING_MARKER))) {
      throw new Error("Initial send must include this Agent's unique binding marker.");
    }
    if (readRequiresBinding.has(name)) {
      throw new Error("This Agent has no bound conversation; refusing to read shared ChatGPT history.");
    }
    if (!new Set([
      "chatgpt_status",
      "chatgpt_browser_lifecycle",
      "chatgpt_circuit_breaker_status",
      "chatgpt_route_new_chat",
      "chatgpt_send_message",
    ]).has(name)) {
      throw new Error("Only status and initial binding operations are allowed before this Agent has a conversation.");
    }
    if (name === "chatgpt_status") {
      const route = await browser.agentRouteSnapshot();
      if (route.conversationId) {
        throw new Error("The unbound Agent browser is on an existing conversation; refusing to read it.");
      }
    }
    return null;
  }

  if (name === "chatgpt_list_history" || name === "chatgpt_search_history") {
    throw new Error("History listing is disabled for this Agent; use its bound conversation only.");
  }
  if (name === "chatgpt_new_chat" || name === "chatgpt_route_new_chat") {
    throw new Error("This Agent is already bound; opening another conversation is refused.");
  }
  if (name === "chatgpt_send_message" && (input.newChat || input.temporary)) {
    throw new Error("This Agent is already bound; new or temporary conversations are refused.");
  }
  const requestedId = requestedConversationId(name, input);
  if (name === "chatgpt_select_history" && (!requestedId || input.title)) {
    throw new Error("Select this Agent's bound conversation by exact ID or URL only.");
  }
  const route = await browser.agentRouteSnapshot();
  assertAgentRoute({
    agentId: AGENT_ID,
    binding,
    requestedConversationId: requestedId,
    observedUrl: route.url,
  });
  return binding;
}

async function finishAgentRoute(name, input, binding, result, requestId, roundId) {
  if (!AGENT_ID) return result;
  const route = await browser.agentRouteSnapshot();
  const ids = sendTools.has(name)
    ? await browser.agentMessageIds()
    : {
        lastSentMessageId: result?.lastSentMessageId || null,
        lastReceivedMessageId: result?.lastReceivedMessageId || null,
      };
  let currentBinding = binding;
  const initialConversation =
    name === "chatgpt_route_new_chat" ||
    (name === "chatgpt_send_message" && input.newChat && !input.temporary);
  if (!currentBinding?.conversation_id && initialConversation) {
    if (!route.conversationId || !route.url.includes(`/c/${route.conversationId}`)) {
      throw new Error("New conversation did not return a real /c/<conversation_id> route.");
    }
    currentBinding = {
      agent_id: AGENT_ID,
      mcp_server_name: MCP_SERVER_NAME,
      mcp_instance_id: AGENT_ID,
      cdp_port: route.port,
      browser_profile: route.profile,
      conversation_id: route.conversationId,
      conversation_url: route.url,
      binding_marker: BINDING_MARKER,
      last_sent_message_id: ids.lastSentMessageId || null,
      last_received_message_id: ids.lastReceivedMessageId || null,
      last_request_id: requestId,
      last_round_id: roundId,
    };
    await writeAgentBinding(currentBinding);
  } else if (currentBinding) {
    assertAgentRoute({
      agentId: AGENT_ID,
      binding: currentBinding,
      requestedConversationId: null,
      observedUrl: route.url,
    });
    if (sendTools.has(name) || ids.lastSentMessageId || ids.lastReceivedMessageId) {
      currentBinding = {
        ...currentBinding,
        cdp_port: route.port,
        last_sent_message_id: ids.lastSentMessageId || currentBinding.last_sent_message_id || null,
        last_received_message_id:
          ids.lastReceivedMessageId || currentBinding.last_received_message_id || null,
        last_request_id: requestId,
        last_round_id: roundId,
      };
      await writeAgentBinding(currentBinding);
    }
  }
  await appendAgentLog({
    timestamp: new Date().toISOString(),
    status: "completed",
    agent_id: AGENT_ID,
    request_id: requestId,
    conversation_id: currentBinding?.conversation_id || route.conversationId || null,
    round_id: roundId,
    tool: name,
    request: input,
    last_sent_message_id: ids.lastSentMessageId || currentBinding?.last_sent_message_id || null,
    last_received_message_id: ids.lastReceivedMessageId || currentBinding?.last_received_message_id || null,
    reply: result,
  });
  return {
    ...result,
    agent_id: AGENT_ID,
    request_id: requestId,
    conversation_id: currentBinding?.conversation_id || route.conversationId || null,
    round_id: roundId,
  };
}

function tool(name, description, schema, handler, { allowDuringPause = false } = {}) {
  server.tool(name, description, schema, async (input, extra) => {
    const requestId = AGENT_ID ? randomUUID() : null;
    const roundId = AGENT_ID && sendTools.has(name) ? `round-${randomUUID()}` : null;
    let binding = null;
    try {
      const result = await browser.runExclusive(
        async () => {
          binding = await guardAgentRoute(name, input);
          if (!allowDuringPause) await browser.assertActionsAllowed(name);
          const value = await handler(input);
          return finishAgentRoute(name, input, binding, value, requestId, roundId);
        },
        { signal: extra.signal, name },
      );
      return asResult(result);
    } catch (error) {
      if (AGENT_ID) {
        await appendAgentLog({
          timestamp: new Date().toISOString(),
          status: sendTools.has(name) ? "delivery-uncertain" : "failed",
          agent_id: AGENT_ID,
          request_id: requestId,
          conversation_id: binding?.conversation_id || null,
          round_id: roundId,
          tool: name,
          request: input,
          error: error instanceof Error ? error.message : String(error),
        }).catch(() => {});
      }
      return asResult(userFacingError(error), true);
    }
  });
}

  tool(
  "chatgpt_status",
  `检查专用浏览器、登录、当前对话、模式、临时对话和轮次状态（阈值 ${MAX_CONVERSATION_TURNS}）。仅在诊断或确需状态时调用；正常发送无需预先调用。默认不展开高级菜单。`,
  {
    includeSettings: z
      .boolean()
      .default(false)
      .describe("是否额外展开高级菜单读取模型和思考强度；默认 false。"),
  },
  ({ includeSettings }) => browser.status({ includeSettings }),
);

tool(
  "chatgpt_browser_lifecycle",
  "读取专用 ChatGPT 浏览器的常驻状态。MCP 调用结束后浏览器会继续保持打开，后续调用直接接管，不重复进站。",
  {},
  () => browser.browserLifecycle(),
  { allowDuringPause: true },
);

tool(
  "chatgpt_close_browser",
  "明确关闭 ChatGPT MCP 的专用常驻浏览器。仅在用户明确要求关闭时调用。",
  {},
  () => browser.terminateBrowser(),
  { allowDuringPause: true },
);

tool(
  "chatgpt_capabilities",
  "一次读取当前模式、模型、思考强度、临时状态和少量可见历史摘要；用于确需综合预检时，避免连续调用多个状态工具。不会展开模型或思考强度子菜单。",
  {
    historyLimit: z.number().int().min(0).max(20).default(5),
  },
  ({ historyLimit }) => browser.capabilities({ historyLimit }),
);

tool(
  "chatgpt_list_modes",
  "列出 ChatGPT 新版页面顶部当前可用的模式，例如“聊天”和“工作”。",
  {},
  () => browser.listModes(),
);

tool(
  "chatgpt_select_mode",
  "选择 ChatGPT 新版页面顶部模式，例如“聊天”或“工作”，并校验选中状态。",
  {
    mode: z.string().min(1).describe("页面显示的模式名称；建议先调用 chatgpt_list_modes。"),
  },
  ({ mode }) => browser.selectMode(mode),
);

tool(
  "chatgpt_list_models",
  "按“当前档位→高级→模型”的页面层级，动态列出当前 ChatGPT 账号实际可用的模型。不要猜测模型名称。",
  {},
  () => browser.listModels(),
);

tool(
  "chatgpt_select_model",
  "按“当前档位→高级→模型”选择当前对话使用的模型，并校验结果。",
  {
    model: z.string().min(1).describe("模型菜单显示的完整或唯一名称；建议先调用 chatgpt_list_models。"),
  },
  ({ model }) => browser.selectModel(model),
);

tool(
  "chatgpt_list_thinking_levels",
  "按“当前档位→高级→思考强度”的页面层级，列出账号实际可用的思考强度。",
  {},
  () => browser.listThinkingLevels(),
);

tool(
  "chatgpt_select_thinking_level",
  "选择 ChatGPT 网页当前对话的思考强度，并校验页面显示的结果。",
  {
    thinkingLevel: z
      .string()
      .min(1)
      .describe(
        "页面显示的完整思考强度名称；若列表表明控件仅为滑块，也可传其 min..max 范围内的数值字符串。建议先调用 chatgpt_list_thinking_levels。",
      ),
  },
  ({ thinkingLevel }) => browser.selectThinkingLevel(thinkingLevel),
);

tool(
  "chatgpt_answer_tier_status",
  "读取输入框右侧能力滑杆的当前档位和可访问值域，例如“极高，第 4 项，共 5 项”。不会发送提示词。",
  {},
  () => browser.answerTierStatus(),
);

tool(
  "chatgpt_select_answer_tier",
  `选择输入框右侧当前可用的能力档位，并校验页面显示结果；不假设 Pro 档位存在。`,
  {
    answerTier: z.string().min(1).describe("页面当前可用的能力档位名称。"),
  },
  ({ answerTier }) => browser.selectAnswerTier(answerTier),
);

tool(
  "chatgpt_new_chat",
  "创建新的普通或临时对话，并可选择模式、模型、思考强度和能力档位。新建前额外刷新由 CHATGPT_WEB_REFRESH_BEFORE_NEW_CHAT 控制，默认关闭；刷新失败或有草稿/附件时停止。",
  {
    temporary: z.boolean().default(false).describe("true 表示临时对话，不进入历史记录。"),
    mode: z.string().min(1).optional().describe("可选模式，例如“聊天”或“工作”。"),
    model: z.string().min(1).optional().describe("可选模型名称。"),
    thinkingLevel: z.string().min(1).optional().describe("可选思考强度。"),
    answerTier: z.string().min(1).optional().describe("可选能力档位；必须是页面当前可用值。"),
  },
  ({ temporary, mode, model, thinkingLevel, answerTier }) =>
    browser.newChat({ temporary, mode, model, thinkingLevel, answerTier }),
);

tool(
  "chatgpt_set_temporary",
  "开启或关闭新对话的临时对话模式，并通过页面状态进行校验。切换可能会打开一个新对话。",
  {
    enabled: z.boolean(),
  },
  ({ enabled }) => browser.setTemporary(enabled),
);

tool(
  "chatgpt_write_prompt",
  "把提示词准确写入 ChatGPT 网页输入框但不发送；为保护用户草稿，输入框非空时默认拒绝覆盖，需明确使用 append=true 追加。",
  {
    prompt: z.string().min(1),
    append: z.boolean().default(false).describe("是否追加到已有草稿；默认保护并拒绝覆盖非空草稿。"),
  },
  ({ prompt, append }) => browser.writePrompt(prompt, { append }),
);

tool(
  "chatgpt_enable_web_search",
  "在当前输入框中启用 ChatGPT 网页原生“网页搜索”，并校验选中标记。应在写入提示词和上传文件后、发送前调用。",
  {},
  () => browser.enableWebSearch(),
);

tool(
  "chatgpt_upload_files",
  "向当前 ChatGPT 对话上传用户明确授权的本地文件。路径必须是绝对路径。不会自动发送提示词。",
  {
    files: z.array(z.string().min(1)).min(1).describe("待上传文件的绝对路径列表。"),
  },
  ({ files }) => browser.uploadFiles(files),
);

tool(
  "chatgpt_submit_prompt",
  `发送当前输入框中的提示词，并可等待 ChatGPT 网页回答完成。发送前会强制刷新当前对话、校验轮次上限（${MAX_CONVERSATION_TURNS}）以及 URL、草稿和附件状态；达到上限时直接拦截，避免触发网页 maximum-length 错误。当前能力档位为“${PRO_ANSWER_TIER}”或模型名称带 Pro 时自动无限等待，timeoutMs 仅用于普通档位。`,
  {
    wait: z.boolean().default(true),
    timeoutMs: z.number().int().min(5_000).max(900_000).default(RESPONSE_TIMEOUT_MS),
  },
  ({ wait, timeoutMs }) => browser.submitPrompt({ wait, timeoutMs }),
);

tool(
  "chatgpt_send_message",
  `组合工具：可新建或继续对话、选择模式/模型/思考强度/能力档位、切换临时对话、上传文件、写入提示词、发送并取得回答。继续已有对话时，发送前会强制刷新并检查 ${MAX_CONVERSATION_TURNS} 轮上限；达到上限或检测到网页 maximum-length 错误会先加载并归档完整 transcript（包括较早的懒加载历史）到 ${CONTEXT_ARCHIVE_DIR}，再自动新建普通对话，结果返回 conversationRotation/archivePath。刷新发生在上传和写入之前，避免旧页面状态覆盖用户消息。为保护用户草稿，若输入框已有不同内容会拒绝写入，不会覆盖；新建/切换对话前也会保护非空草稿。能力档位为“${PRO_ANSWER_TIER}”或模型名称带 Pro 时自动无限等待；普通档位仍使用 timeoutMs。只有用户明确要求上传时才传 files。`,
  {
    prompt: z.string().min(1),
    files: z.array(z.string().min(1)).default([]),
    webSearch: z.boolean().default(false).describe("发送前启用并校验 ChatGPT 网页原生网页搜索。"),
    mode: z.string().min(1).optional(),
    model: z.string().min(1).optional(),
    thinkingLevel: z.string().min(1).optional(),
    answerTier: z.string().min(1).optional().describe(`可选能力档位；传“${PRO_ANSWER_TIER}”时无限等待。`),
    newChat: z.boolean().default(false),
    temporary: z.boolean().default(false),
    wait: z.boolean().default(true),
    timeoutMs: z.number().int().min(5_000).max(900_000).default(RESPONSE_TIMEOUT_MS),
  },
  (input) => browser.sendMessage(input),
);

tool(
  "chatgpt_probe_pro_identity",
  PROBE_ENABLED
    ? `执行已显式启用的实验性网络身份探针（兼容旧工具名）。临时对话使用当前档位发送“${PROBE_PROMPT}”；网络 model_slug 非 mini 不等于 Pro 身份证明。不自动选择 Pro，不创建正常对话。${probeInstructions}`
    : "临时 Pro 身份探针当前停用；调用将明确停止，不打开临时对话，也不发送消息。",
  {
    mode: z.string().min(1).optional(),
    force: z.boolean().default(false).describe("true 表示忽略缓存并重新执行探针；仅在用户明确要求时使用。"),
  },
  ({ mode, force }) => browser.probeProIdentity({ mode, force }),
);

tool(
  "chatgpt_route_new_chat",
  `普通请求新建非临时对话并使用页面可用档位“${DEFAULT_ANSWER_TIER}”。${probeInstructions} 浏览器始终常驻。`,
  {
    prompt: z.string().min(1).describe("最终正常对话要发送的实际提示词。"),
    files: z.array(z.string().min(1)).default([]),
    webSearch: z.boolean().default(false).describe("发送前启用并校验 ChatGPT 网页原生网页搜索。"),
    requestPro: z.boolean().default(false).describe("兼容旧参数：true 请求实验性身份探针，并不保证选择 Pro；探针默认停用，此时 true 会在新建临时对话或发送探针前拒绝。"),
    forceProbe: z.boolean().default(false).describe("是否忽略会话级 Pro 探针缓存；仅在用户明确要求时设为 true。"),
    mode: z.string().min(1).optional(),
    wait: z.boolean().default(true),
    timeoutMs: z.number().int().min(5_000).max(900_000).default(RESPONSE_TIMEOUT_MS),
  },
  (input) => browser.routeNewChat(input),
);

tool(
  "chatgpt_list_history",
  "列出 ChatGPT 侧栏当前加载的历史对话，可按标题筛选。返回 title、conversationId 和 URL。",
  {
    query: z.string().min(1).optional(),
    limit: z.number().int().min(1).max(50).default(20),
  },
  ({ query, limit }) => browser.listHistory({ query, limit }),
);

tool(
  "chatgpt_search_history",
  "使用 ChatGPT 网页自带的“搜索聊天”界面查找历史对话，因此不受侧栏当前加载数量限制。返回 title、conversationId 和 URL。",
  {
    query: z.string().min(1),
    limit: z.number().int().min(1).max(50).default(20),
  },
  ({ query, limit }) => browser.searchHistory({ query, limit }),
);

tool(
  "chatgpt_select_history",
  "通过 conversationId、ChatGPT /c/... URL 或唯一标题打开历史对话，并返回最近一条回答。优先使用 ID。",
  {
    conversationId: z.string().min(1).optional(),
    url: z.string().min(1).optional(),
    title: z.string().min(1).optional(),
  },
  (input) => browser.selectHistory(input),
);

tool(
  "chatgpt_get_latest_response",
  "读取当前 ChatGPT 对话最近一条完整回复和对话状态。默认不为状态展示额外展开高级菜单。",
  {
    includeSettings: z
      .boolean()
      .default(false)
      .describe("是否额外读取模型和思考强度；默认 false。"),
  },
  ({ includeSettings }) => browser.getLatestResponse({ includeSettings }),
  { allowDuringPause: true },
);

tool(
  "chatgpt_archive_conversation",
  `将当前对话完整 transcript（包含滚动加载的较早历史）以 Markdown 原子写入 ${CONTEXT_ARCHIVE_DIR}，用于跨会话持久化上下文；不会发送消息或切换对话。`,
  {
    reason: z.string().min(1).default("manual-archive"),
  },
  ({ reason }) => browser.archiveConversation({ reason }),
  { allowDuringPause: true },
);

tool(
  "chatgpt_circuit_breaker_status",
  "只读取本地安全熔断和未确认生成任务状态，不访问 ChatGPT 网页。",
  {},
  () => browser.circuitBreakerStatus(),
  { allowDuringPause: true },
);

tool(
  "chatgpt_clear_circuit_breaker",
  "仅在用户已经人工确认 ChatGPT 限流提示消失后，清除本地安全熔断。不会访问网页。",
  {
    confirmed: z.literal(true).describe("必须由用户人工确认限流提示已经消失。"),
  },
  ({ confirmed }) => browser.clearCircuitBreaker({ confirmed }),
  { allowDuringPause: true },
);

tool(
  "chatgpt_network_diagnostics",
  "读取本地脱敏网络异常记录。只包含时间、方法、脱敏路径、状态码和资源类型；不含查询参数、Cookie、请求体或响应体。",
  {
    limit: z.number().int().min(1).max(500).default(100),
  },
  ({ limit }) => browser.networkDiagnostics({ limit }),
  { allowDuringPause: true },
);

let shuttingDown = false;
const shutdown = async () => {
  if (shuttingDown) return;
  shuttingDown = true;
  // Disconnect Playwright only. The dedicated Chrome is intentionally kept
  // alive so the next MCP process can reuse its page and signed-in session.
  await browser.close();
  process.exit(0);
};

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
process.stdin.on("end", shutdown);
process.stdin.on("close", shutdown);

const transport = new StdioServerTransport();
await server.connect(transport);
server.server.onclose = shutdown;
console.error("chatgpt-web-mcp ready");
