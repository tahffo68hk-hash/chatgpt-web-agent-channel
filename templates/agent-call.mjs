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

  const stateText = await fs.readFile(instance.browser_state_file, "utf8").catch(() => null);
  if (stateText) {
    const state = JSON.parse(stateText);
    if (path.resolve(state.profile || "").toLowerCase() !== path.resolve(instance.browser_profile).toLowerCase()) {
      throw new Error("Browser state does not belong to this Agent's Profile.");
    }
    instance.cdp_port = Number(state.port) || null;
    const temporaryPath = `${instancePath}.${process.pid}.tmp`;
    await fs.writeFile(temporaryPath, `${JSON.stringify(instance, null, 2)}\n`);
    await fs.rename(temporaryPath, instancePath);
  }

  console.log(JSON.stringify(result, null, 2));
  if (result?.isError) process.exitCode = 1;
} finally {
  await client.close();
}
