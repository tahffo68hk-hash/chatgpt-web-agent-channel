import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const agentRoot = path.dirname(fileURLToPath(import.meta.url));
const instance = JSON.parse(await fs.readFile(path.join(agentRoot, "instance.json"), "utf8"));
const configPath = instance.codex_config_file || path.join(os.homedir(), ".codex", "config.toml");
const lockPath = `${configPath}.chatgpt-web-agent.lock`;
const serverHeader = `[mcp_servers."${instance.mcp_server_name}"]`;
const block = [
  serverHeader,
  `command = ${JSON.stringify(instance.node_executable)}`,
  `args = [${JSON.stringify(instance.launch_script)}]`,
  "startup_timeout_sec = 30",
  "",
].join("\n");

let lock;
const deadline = Date.now() + 30_000;
while (!lock && Date.now() < deadline) {
  try {
    lock = await fs.open(lockPath, "wx");
    await lock.writeFile(JSON.stringify({ agent_id: instance.agent_id, pid: process.pid, at: new Date().toISOString() }));
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}
if (!lock) throw new Error("Timed out waiting for the Codex MCP config lock.");

let temporaryPath;
try {
  const original = await fs.readFile(configPath, "utf8");
  if (original.includes(serverHeader)) {
    if (!original.includes(`args = [${JSON.stringify(instance.launch_script)}]`)) {
      throw new Error("This MCP server name already points to a different launcher.");
    }
    console.log("Server entry already exists.");
  } else {
    const updated = original + (original.endsWith("\n") ? "" : "\n") + "\n" + block;
    temporaryPath = `${configPath}.${process.pid}.tmp`;
    await fs.writeFile(temporaryPath, updated, "utf8");
    if (await fs.readFile(configPath, "utf8") !== original) {
      throw new Error("Codex MCP config changed during the update; no update was written.");
    }
    await fs.rename(temporaryPath, configPath);
    temporaryPath = null;
    console.log(`Added ${instance.mcp_server_name}`);
  }
} finally {
  if (temporaryPath) await fs.unlink(temporaryPath).catch(() => {});
  await lock.close();
  await fs.unlink(lockPath).catch(() => {});
}
