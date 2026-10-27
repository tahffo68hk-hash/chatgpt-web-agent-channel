import { spawnSync } from "node:child_process";
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
if (process.platform !== "win32") {
  throw new Error("The shared Browser Host launcher currently supports Windows only.");
}

const managerScript = instance.browser_host_manager_script;
if (!managerScript || !instance.browser_host_root || !instance.browser_profile) {
  throw new Error("Agent instance is missing its shared Browser Host configuration.");
}
const powershell = process.env.SystemRoot
  ? path.join(process.env.SystemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
  : "powershell.exe";
const ensureHost = spawnSync(
  powershell,
  [
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    managerScript,
    "-Action",
    "Ensure",
    "-HostRoot",
    instance.browser_host_root,
    "-ProfilePath",
    instance.browser_profile,
    "-ChromeExecutable",
    instance.chrome_executable,
    "-StartUrl",
    instance.chatgpt_url || "https://chatgpt.com/",
  ],
  { encoding: "utf8", windowsHide: true, timeout: 45_000 },
);
if (ensureHost.error || ensureHost.status !== 0) {
  throw new Error(
    `Browser Host Ensure failed: ${ensureHost.error?.message || ensureHost.stderr || ensureHost.stdout || "unknown error"}`,
  );
}

let host;
try {
  host = JSON.parse(String(ensureHost.stdout || "").trim());
} catch (error) {
  throw new Error("Browser Host Ensure did not return a valid JSON manifest.", { cause: error });
}
if (
  host.schema_version !== 1 ||
  !host.host_id ||
  !Number.isInteger(Number(host.pid)) ||
  !Number.isInteger(Number(host.port)) ||
  path.resolve(host.profile).toLowerCase() !== path.resolve(instance.browser_profile).toLowerCase()
) {
  throw new Error("Browser Host Ensure returned a manifest that does not match this Agent instance.");
}
if (instance.browser_host_id && instance.browser_host_id !== host.host_id) {
  throw new Error("Browser Host ID changed; refusing to attach this Agent to a different Host silently.");
}

if (Number(instance.cdp_port) !== Number(host.port) || instance.browser_host_id !== host.host_id) {
  instance.cdp_port = Number(host.port);
  instance.browser_host_id = host.host_id;
  const temporaryPath = `${instancePath}.${process.pid}.tmp`;
  await fs.writeFile(temporaryPath, `${JSON.stringify(instance, null, 2)}\n`, "utf8");
  await fs.rename(temporaryPath, instancePath);
}

const env = {
  CHATGPT_WEB_AGENT_ID: instance.agent_id,
  CHATGPT_WEB_MCP_SERVER_NAME: instance.mcp_server_name,
  CHATGPT_WEB_BINDING_FILE: instance.binding_file,
  CHATGPT_WEB_BINDING_MARKER: instance.binding_marker,
  CHATGPT_WEB_AGENT_LOG: instance.request_log_file,
  CHATGPT_WEB_PROFILE: instance.browser_profile,
  CHATGPT_WEB_BROWSER_HOST_ROOT: instance.browser_host_root,
  CHATGPT_WEB_BROWSER_HOST_FILE: instance.browser_host_manifest,
  CHATGPT_WEB_RUNTIME_STATE: instance.runtime_state_file,
  CHATGPT_WEB_OPERATION_LOCK_DIR: instance.browser_operation_lock_dir,
  CHATGPT_WEB_SEND_SCHEDULER_FILE: instance.send_scheduler_file,
  CHATGPT_WEB_NETWORK_LOG: instance.network_log_file,
  CHATGPT_WEB_CONTEXT_ARCHIVE_DIR: instance.context_archive_dir,
  CHATGPT_WEB_PROBE_ENABLED: "false",
};

for (const [key, value] of Object.entries(env)) process.env[key] = value;
await import(pathToFileURL(path.join(instance.runtime_source_dir, "index.js")).href);
