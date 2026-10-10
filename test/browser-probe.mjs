import assert from "node:assert/strict";
import http from "node:http";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const testDir = path.dirname(fileURLToPath(import.meta.url));
const probe = path.resolve(testDir, "..", "BrowserProbe.mjs");

function sseFrame(payload) {
  return "event: message\ndata: " + JSON.stringify(payload) + "\n\n";
}

async function startServer(handler) {
  const sockets = new Set();
  const server = http.createServer(handler);
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    port: server.address().port,
    async close() {
      for (const socket of sockets) socket.destroy();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

function runProbe(port, killAfterMs = 8_000) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [probe, "--port", String(port)], {
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill();
    }, killAfterMs);
    child.on("error", reject);
    child.on("exit", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr, timedOut });
    });
  });
}

async function readMessage(req) {
  let body = "";
  for await (const chunk of req) body += chunk;
  return body ? JSON.parse(body) : null;
}

function goodInit(id) {
  return {
    jsonrpc: "2.0",
    id,
    result: {
      protocolVersion: "2025-03-26",
      capabilities: { tools: {} },
      serverInfo: { name: "fixture", version: "1" },
    },
  };
}

function healthyStatus() {
  return {
    status: "ok",
    chromeSkill: "ok",
    nodeRepl: "ok",
    selectionRequired: true,
    connectedBrowsers: [{
      backendRef: "browser_backend_private_fixture",
      supported: true,
      capabilities: { listTabs: true, claimTabs: true },
    }],
  };
}

function goodTool(id) {
  return {
    jsonrpc: "2.0",
    id,
    result: {
      content: [],
      structuredContent: healthyStatus(),
      isError: false,
    },
  };
}

async function runMode(mode, extra = {}) {
  const sessionId = "fixture-session";
  const server = await startServer(async (req, res) => {
    if (req.method === "DELETE") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end("{}");
      return;
    }
    const message = await readMessage(req);
    if (message?.method === "initialize") {
      res.writeHead(200, {
        "content-type": "text/event-stream",
        "mcp-session-id": sessionId,
      });
      res.end(sseFrame(mode === "bad-init-id" ? goodInit(99) : goodInit(message.id)));
      return;
    }
    if (message?.method === "notifications/initialized") {
      if (mode === "notification-error") {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.end(sseFrame({ jsonrpc: "2.0", id: null, error: { code: -1, message: "private-notification-error" } }));
      } else {
        res.writeHead(202);
        res.end();
      }
      return;
    }
    if (message?.method === "tools/call") {
      if (mode === "delayed-headers") {
        await new Promise(resolve => setTimeout(resolve, 5_000));
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify(goodTool(message.id)));
        return;
      }
      if (mode === "delayed-stream" || mode === "stalled-stream") {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write(": waiting for cold Browser startup\n\n");
        if (mode === "stalled-stream") return;
        await new Promise(resolve => setTimeout(resolve, 5_000));
        res.end(sseFrame(goodTool(message.id)));
        return;
      }
      if (mode === "redirect") {
        res.writeHead(307, { location: extra.redirectUrl });
        res.end();
        return;
      }
      if (mode === "malformed-envelope") {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.end(sseFrame({
          jsonrpc: "1.0",
          id: 99,
          result: goodTool(message.id).result,
          error: { code: -1, message: "private-malformed-error" },
        }));
        return;
      }
      if (mode === "notification-first-open") {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write(sseFrame({ jsonrpc: "2.0", method: "notifications/message", params: { value: 1 } }));
        res.write(sseFrame(goodTool(message.id)));
        return;
      }
      if (mode === "oversized-open") {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write("data: " + "x".repeat(300_000));
        return;
      }
      if (mode === "malformed-open") {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write("event: message\ndata: {not-json}\n\n");
        return;
      }
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.end(sseFrame(goodTool(message.id)));
      return;
    }
    res.writeHead(404);
    res.end();
  });

  try {
    return await runProbe(server.port, mode === "stalled-stream" ? 35_000 : 8_000);
  } finally {
    await server.close();
  }
}

let passed = 0;

for (const mode of ["delayed-headers", "delayed-stream"]) {
  const result = await runMode(mode);
  assert.equal(result.timedOut, false);
  assert.equal(result.code, 0);
  assert.equal(JSON.parse(result.stdout).ok, true);
  passed++;
  console.log(`PASS cold Browser startup accepts ${mode} beyond four seconds`);
}

{
  const started = Date.now();
  const result = await runMode("stalled-stream");
  assert.equal(result.timedOut, false);
  assert.equal(result.code, 1);
  assert.equal(JSON.parse(result.stdout).errorCode, "BROWSER_PROBE_UNAVAILABLE");
  assert.ok(Date.now() - started < 34_000);
  passed++;
  console.log("PASS a stalled Browser stream still fails within the bounded startup budget");
}

{
  const result = await runMode("baseline");
  assert.equal(result.timedOut, false);
  assert.equal(result.code, 0);
  assert.equal(result.stderr, "");
  const parsed = JSON.parse(result.stdout);
  assert.equal(parsed.ok, true);
  assert.equal(parsed.supportedBackendCount, 1);
  assert.equal(result.stdout.includes("browser_backend_private_fixture"), false);
  passed++;
  console.log("PASS baseline Browser status is sanitized");
}

{
  let redirectedHits = 0;
  let forwardedSession = false;
  const secondary = await startServer(async (req, res) => {
    redirectedHits++;
    if (req.headers["mcp-session-id"]) forwardedSession = true;
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.end(sseFrame(goodTool(2)));
  });
  try {
    const result = await runMode("redirect", { redirectUrl: "http://127.0.0.1:" + secondary.port + "/steal" });
    assert.equal(result.timedOut, false);
    assert.equal(result.code, 1);
    assert.equal(redirectedHits, 0);
    assert.equal(forwardedSession, false);
    passed++;
    console.log("PASS redirects are rejected and session header is not forwarded");
  } finally {
    await secondary.close();
  }
}

{
  const result = await runMode("malformed-envelope");
  assert.equal(result.timedOut, false);
  assert.equal(result.code, 1);
  assert.equal(result.stdout.includes("private-malformed-error"), false);
  passed++;
  console.log("PASS malformed JSON-RPC version/id/result-error envelope fails closed");
}

{
  const result = await runMode("bad-init-id");
  assert.equal(result.timedOut, false);
  assert.equal(result.code, 1);
  passed++;
  console.log("PASS mismatched initialize response id fails closed");
}

{
  const result = await runMode("notification-error");
  assert.equal(result.timedOut, false);
  assert.equal(result.code, 1);
  assert.equal(result.stdout.includes("private-notification-error"), false);
  passed++;
  console.log("PASS initialized notification error is rejected and sanitized");
}

{
  const result = await runMode("notification-first-open");
  assert.equal(result.timedOut, false);
  assert.equal(result.code, 0);
  assert.equal(JSON.parse(result.stdout).ok, true);
  passed++;
  console.log("PASS notification-first SSE returns on matching response without waiting for stream close");
}

{
  const started = Date.now();
  const result = await runMode("oversized-open");
  const elapsed = Date.now() - started;
  assert.equal(result.timedOut, false);
  assert.equal(result.code, 1);
  assert.ok(elapsed < 8_000);
  assert.equal(JSON.parse(result.stdout).errorCode, "BROWSER_PROBE_UNAVAILABLE");
  passed++;
  console.log("PASS oversized open response is cancelled and helper exits within bound");
}

{
  const started = Date.now();
  const result = await runMode("malformed-open");
  const elapsed = Date.now() - started;
  assert.equal(result.timedOut, false);
  assert.equal(result.code, 1);
  assert.ok(elapsed < 8_000);
  assert.equal(result.stderr, "");
  assert.equal(JSON.parse(result.stdout).errorCode, "BROWSER_PROBE_UNAVAILABLE");
  passed++;
  console.log("PASS malformed open SSE is cancelled and helper exits within bound");
}

console.log("RESULT: " + passed + "/" + passed + " PASS; adversarial loopback fixtures only");
