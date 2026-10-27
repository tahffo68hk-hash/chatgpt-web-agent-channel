import fs from "node:fs/promises";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const agentRoot = path.dirname(fileURLToPath(import.meta.url));
const instancePath = path.join(agentRoot, "instance.json");
const instance = JSON.parse(await fs.readFile(instancePath, "utf8"));
const require = createRequire(path.join(instance.shared_source_dir, "package.json"));
const { Client } = require("@modelcontextprotocol/sdk/client/index.js");
const { StdioClientTransport } = require("@modelcontextprotocol/sdk/client/stdio.js");

const toolName = process.argv[2] || "--list";
const input = JSON.parse(process.argv[3] || "{}");
const transport = new StdioClientTransport({
  command: instance.node_executable,
  args: [instance.launch_script],
  cwd: instance.shared_source_dir,
  stderr: "pipe",
});
transport.stderr?.on("data", (chunk) => process.stderr.write(chunk));
const client = new Client({ name: `agent-mcp-client-${instance.agent_id}`, version: "1.0.0" });

try {
  await client.connect(transport);
  const result = toolName === "--list"
    ? await client.listTools()
    : await client.callTool({ name: toolName, arguments: input });

  const hostStatePath = instance.browser_host_manifest || instance.browser_state_file;
  const stateText = await fs.readFile(hostStatePath, "utf8").catch(() => null);
  if (stateText) {
    const state = JSON.parse(stateText);
    if (path.resolve(state.profile || "").toLowerCase() !== path.resolve(instance.browser_profile).toLowerCase()) {
      throw new Error("Browser Host manifest Profile does not match this Agent's shared Host.");
    }
    if (instance.browser_host_id && state.host_id !== instance.browser_host_id) {
      throw new Error("Browser Host ID changed; refusing to switch this Agent to another Host silently.");
    }
    if (!Number.isInteger(Number(state.pid)) || !Number.isInteger(Number(state.port)) || !state.endpoint) {
      throw new Error("Browser Host manifest is missing its verified PID, CDP port, or endpoint.");
    }
    instance.cdp_port = Number(state.port) || null;
    instance.browser_host_id = state.host_id || null;
    const temporaryPath = `${instancePath}.${process.pid}.tmp`;
    try {
      await fs.writeFile(temporaryPath, `${JSON.stringify(instance, null, 2)}\n`, "utf8");
      await fs.rename(temporaryPath, instancePath);
    } finally {
      await fs.unlink(temporaryPath).catch(() => {});
    }
  }

  console.log(JSON.stringify(result, null, 2));
  if (result?.isError) process.exitCode = 1;
} finally {
  await client.close();
}
