import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const launcherPath = fileURLToPath(import.meta.url);
const agentRoot = path.dirname(launcherPath);
const instancePath = path.join(agentRoot, "instance.json");
const instance = JSON.parse(await fs.readFile(instancePath, "utf8"));

if (path.basename(agentRoot) !== instance.agent_id) {
  throw new Error("AGENT_ID does not match this launcher directory.");
}
if (instance.mcp_server_name !== "chatgpt-web-" + instance.agent_id) {
  throw new Error("MCP server name does not match this Agent.");
}

const env = {
  CHATGPT_WEB_AGENT_ID: instance.agent_id,
  CHATGPT_WEB_MCP_SERVER_NAME: instance.mcp_server_name,
  CHATGPT_WEB_BINDING_FILE: instance.binding_file,
  CHATGPT_WEB_BINDING_MARKER: instance.binding_marker,
  CHATGPT_WEB_AGENT_LOG: instance.request_log_file,
  CHATGPT_WEB_PROFILE: instance.browser_profile,
  CHATGPT_WEB_BROWSER_STATE: instance.browser_state_file,
  CHATGPT_WEB_RUNTIME_STATE: instance.runtime_state_file,
  CHATGPT_WEB_OPERATION_LOCK: instance.operation_lock_file,
  CHATGPT_WEB_NETWORK_LOG: instance.network_log_file,
  CHATGPT_WEB_CONTEXT_ARCHIVE_DIR: instance.context_archive_dir,
  CHATGPT_WEB_CHROME: instance.chrome_executable,
  CHATGPT_WEB_HEADLESS: "false",
  CHATGPT_WEB_PROBE_ENABLED: "false",
};

for (const [key, value] of Object.entries(env)) process.env[key] = value;
await import(pathToFileURL(path.join(instance.runtime_source_dir, "index.js")).href);
