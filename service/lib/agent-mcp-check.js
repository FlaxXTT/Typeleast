import { spawn } from "node:child_process";
import { constants } from "node:fs";
import { access } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const commands = { codex: "codex", claude: "claude", opencode: "opencode", hermes: "hermes" };
const protocol = "2025-11-25";
const authFailure = /(?:needs authentication|authentication (?:required|failed)|not logged in|unauthorized|\b40[13]\b)/iu;
const missingProgram = /(?:\bENOENT\b|command not found|no such file or directory|program not found)/iu;

function failure(text = "") {
  if (authFailure.test(text)) return { state: "login" };
  if (missingProgram.test(text)) return { state: "missing-program" };
  if (/pending approval|not approved|workspace (?:is )?not trusted/iu.test(text)) return { state: "approval" };
  return { state: "unavailable" };
}

function discovered(count) {
  return count > 0 ? { state: "ready", count } : { state: "no-tools" };
}

function executable(command, options) {
  const paths = !command.includes("/") ? options.env.PATH.split(":").filter(isAbsolute).map(path => join(path, command))
    : [isAbsolute(command) ? command : join(options.cwd, command)];
  return paths.reduce(async (found, path) => await found || await access(path, constants.X_OK).then(() => path, () => null),
    Promise.resolve(null));
}

function run(program, args, options, exchange, timeout = 11_000) {
  return new Promise(resolve => {
    const child = spawn(program, args, { ...options, stdio: [exchange ? "pipe" : "ignore", "pipe", "pipe"] });
    let out = "", err = "", finished = false;
    function finish(result) {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      if (child.exitCode == null && child.signalCode == null) child.kill();
      child.stdout.destroy();
      child.stderr.destroy();
      child.stdin?.destroy();
      resolve(result);
    }
    const timer = setTimeout(() => finish({ state: "timeout" }), timeout);
    child.on("error", error => finish(failure(error.code)));
    child.on("close", code => finish(exchange ? failure(out + err) : { code, out, err }));
    child.stderr.on("data", part => { if (err.length < 100_000) err += part; });
    child.stdout.setEncoding("utf8").on("data", part => {
      out += part;
      if (out.length > 2_000_000) { finish({ state: "unavailable" }); return; }
      if (!exchange) return;
      const lines = out.split("\n");
      out = lines.pop();
      for (const line of lines) {
        let message;
        try { message = JSON.parse(line); } catch { continue; }
        const result = exchange(message, send);
        if (result) { finish(result); return; }
      }
    });
    function send(message) { if (!finished) child.stdin.write(JSON.stringify(message) + "\n"); }
    if (exchange) {
      child.stdin.on("error", () => finish({ state: "unavailable" }));
      exchange(null, send);
    }
  });
}

const rpc = (method, id, params) => ({ jsonrpc: "2.0", method, id, params });
const clientInfo = { name: "typeleast-harness-eq", version: "1.0" };

function codexDiscovery(name) {
  return (message, send) => {
    if (!message) send(rpc("initialize", 1, { clientInfo }));
    else if (message.id === 1 && message.result) {
      send(rpc("initialized"));
      send(rpc("mcpServerStatus/list", 2, { serverName: name, detail: "toolsAndAuthOnly" }));
    } else if (message.id === 2) {
      const server = message.result?.data?.find(row => row.name === name);
      if (server?.authStatus === "notLoggedIn") return { state: "login" };
      if (server?.toolsError) return failure(server.toolsError);
      if (server?.tools && typeof server.tools === "object") return discovered(Object.keys(server.tools).length);
      return { state: "unavailable" };
    } else if (message.id === 1) return { state: "unavailable" };
  };
}

function stdioDiscovery(message, send) {
  if (!message) send(rpc("initialize", 1, { protocolVersion: protocol, capabilities: {}, clientInfo }));
  else if (message.id === 1 && message.result) {
    send(rpc("notifications/initialized"));
    send(rpc("tools/list", 2));
  } else if (message.id === 2 || message.id === 1) {
    return Array.isArray(message.result?.tools) ? discovered(message.result.tools.length) : failure(message.error?.message);
  }
}

async function httpDiscovery(url) {
  const signal = AbortSignal.timeout(9000);
  const headers = { "Content-Type": "application/json", Accept: "application/json, text/event-stream" };
  async function request(method, id, params) {
    const response = await fetch(url, { method: "POST", headers, signal, redirect: "error", body: JSON.stringify(rpc(method, id, params)) });
    const session = response.headers.get("mcp-session-id");
    if (session) headers["mcp-session-id"] = session;
    if (!response.ok || id == null) {
      await response.body?.cancel();
      if (!response.ok) throw new Error(String(response.status));
      return;
    }
    if (!response.headers.get("content-type")?.includes("text/event-stream")) return response.json();
    const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
    try {
      let pending = "";
      while (pending.length < 1_000_000) {
        const { value, done } = await reader.read();
        if (done) break;
        pending += value;
        const events = pending.split(/\r?\n\r?\n/u);
        pending = events.pop();
        for (const event of events) {
          const data = event.split(/\r?\n/u).filter(line => line.startsWith("data:")).map(line => line.slice(5)).join("\n");
          if (!data) continue;
          const message = JSON.parse(data);
          if (message.id === id) return message;
        }
      }
    } finally { void reader.cancel().catch(() => {}); }
  }
  try {
    const start = await request("initialize", 1, { protocolVersion: protocol, capabilities: {}, clientInfo });
    if (!start?.result?.protocolVersion) return failure(start?.error?.message);
    headers["MCP-Protocol-Version"] = start.result.protocolVersion;
    await request("notifications/initialized");
    const result = await request("tools/list", 2);
    return Array.isArray(result?.result?.tools) ? discovered(result.result.tools.length) : failure(result?.error?.message);
  } catch (error) {
    return signal.aborted ? { state: "timeout" } : failure(error.message);
  } finally {
    if (headers["mcp-session-id"]) {
      try {
        const response = await fetch(url, { method: "DELETE", headers, redirect: "error", signal: AbortSignal.timeout(1500) });
        await response.body?.cancel();
      } catch { /* Some servers do not expose session termination. */ }
    }
  }
}

function nativeStatus(agent, name, output) {
  const lines = output.replace(/\u001b\[[0-?]*[ -/]*[@-~]/gu, "").split("\n");
  if (agent === "claude") return lines.find(line => /^\s*Status:/iu.test(line));
  return lines.map(line => line.replace(/^[^\p{L}\p{N}]+/u, ""))
    .find(line => line.startsWith(name) && /^\s+(?:connected|disconnected|disabled|failed|pending|needs |not )/iu.test(line.slice(name.length)));
}

export async function checkAgentMcp({ agent, home, env, project, name, transport }) {
  const path = [env.PATH, join(home, ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].filter(Boolean).join(":");
  const options = { cwd: project ?? home, env: { ...env, PATH: path, NO_COLOR: "1", TERM: "dumb" } };
  const cli = await executable(commands[agent], options);
  if (!cli) return { state: "missing-agent" };
  if (transport?.command && !await executable(transport.command, options)) return { state: "missing-program" };
  if (agent === "codex") return run(cli, ["app-server"], options, codexDiscovery(name));
  if (agent === "hermes") {
    const result = await run(cli, ["mcp", "test", name], options);
    if (result.state) return result;
    const count = /Tools discovered:\s*(\d+)/iu.exec(result.out);
    return count && result.code === 0 ? discovered(Number(count[1])) : failure(result.out + result.err);
  }
  const args = agent === "claude" ? ["mcp", "get", name] : ["mcp", "list"];
  let result = await run(cli, args, options);
  let status = !result.state && nativeStatus(agent, name, result.out);
  if (agent === "opencode" && result.code === 0 && (!status || /\bpending\b/iu.test(status.slice(name.length)))) {
    // OpenCode's registry can briefly be empty while a new location loads.
    await delay(1200);
    result = await run(cli, args, options, undefined, 5000);
    status = !result.state && nativeStatus(agent, name, result.out);
  }
  if (result.state) return result;
  const stateText = status?.slice(agent === "claude" ? status.indexOf(":") + 1 : name.length);
  if (!stateText || /(?:disconnected|not connected)/iu.test(stateText) || !/\bconnected\b/iu.test(stateText)) {
    if (!status && /port .* in use|background service/iu.test(result.err)) return { state: "agent-service" };
    if (agent === "opencode" && result.code === 0 && !status) return { state: "agent-not-loaded" };
    if (/\bpending\b/iu.test(stateText ?? "") && agent === "opencode") return { state: "agent-loading" };
    return failure(stateText ?? (agent === "claude" ? result.out + result.err : ""));
  }
  if (!transport) return { state: "tools-unconfirmed" };
  if (transport.url) return httpDiscovery(transport.url);
  const executablePath = await executable(transport.command, options);
  return executablePath ? run(executablePath, transport.args, options, stdioDiscovery) : { state: "missing-program" };
}
