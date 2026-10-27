import fs from "node:fs/promises";
import path from "node:path";

import { BROWSER_HOST_FILE, USER_DATA_DIR } from "./config.js";

function processIsAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

export async function readBrowserHostState() {
  try {
    return JSON.parse(await fs.readFile(BROWSER_HOST_FILE, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw new Error(`无法读取共享浏览器 Host 状态：${BROWSER_HOST_FILE}`, {
      cause: error,
    });
  }
}

export async function assertBrowserHostState(state) {
  const pid = Number(state?.pid);
  const port = Number(state?.port);
  const expectedProfile = path.resolve(USER_DATA_DIR);
  const observedProfile = path.resolve(String(state?.profile || "."));

  if (
    state?.schema_version !== 1 ||
    !state?.host_id ||
    !Number.isInteger(pid) ||
    !Number.isInteger(port) ||
    port < 1 ||
    port > 65_535 ||
    !state?.endpoint
  ) {
    throw new Error("共享浏览器 Host 状态缺少有效的 ID、PID、Profile、端口或端点。");
  }

  if (observedProfile.toLowerCase() !== expectedProfile.toLowerCase()) {
    throw new Error("共享浏览器 Host 的 Profile 与当前 Agent 配置不匹配。", {
      cause: `expected=${expectedProfile}; observed=${observedProfile}`,
    });
  }

  if (!processIsAlive(pid)) {
    throw new Error(`共享浏览器 Host 进程已退出（PID ${pid}）。请重新运行 Browser Host Ensure。`);
  }

  let endpoint;
  try {
    endpoint = new URL(state.endpoint);
  } catch {
    throw new Error("共享浏览器 Host 的 CDP 端点格式无效。");
  }
  if (
    endpoint.protocol !== "http:" ||
    endpoint.hostname !== "127.0.0.1" ||
    Number(endpoint.port) !== port ||
    endpoint.username ||
    endpoint.password
  ) {
    throw new Error("共享浏览器 Host 的 CDP 端点必须指向其记录的本机回环端口。");
  }

  try {
    const response = await fetch(`${endpoint.origin}/json/version`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const details = await response.json();
    if (!details?.webSocketDebuggerUrl) throw new Error("CDP WebSocket URL 缺失");
  } catch (error) {
    throw new Error(`共享浏览器 Host 的 CDP 端点不可用：${endpoint.origin}`, {
      cause: error,
    });
  }

  return {
    ...state,
    pid,
    port,
    profile: expectedProfile,
    endpoint: endpoint.origin,
  };
}
