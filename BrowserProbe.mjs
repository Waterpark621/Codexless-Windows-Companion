const PROTOCOL_VERSION = "2025-03-26";
const MAX_RESPONSE_BYTES = 256 * 1024;
const MAX_SSE_EVENTS = 64;
const REQUEST_TIMEOUT_MS = 4_000;
// Browser status lazily starts App Server, verifies the snapshot and starts
// Node REPL. A healthy cold Windows launch can exceed the transport budget.
const BROWSER_STATUS_TIMEOUT_MS = 30_000;
const OVERALL_TIMEOUT_MS = 40_000;
const CLEANUP_TIMEOUT_MS = 1_000;

function emit(payload, code = 0) {
  process.stdout.write(JSON.stringify(payload));
  process.exitCode = code;
}

function fail(errorCode) {
  emit({ ok: false, errorCode }, 1);
}

function parsePort(argv) {
  if (argv.length !== 2 || argv[0] !== "--port" || !/^[0-9]+$/.test(argv[1])) return null;
  const port = Number.parseInt(argv[1], 10);
  return Number.isInteger(port) && port >= 1 && port <= 65535 ? port : null;
}

function remainingMs(deadline, cap) {
  const remaining = deadline - Date.now();
  if (remaining <= 0) throw new Error("deadline");
  return Math.max(1, Math.min(cap, remaining));
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasOwn(value, key) {
  return Object.prototype.hasOwnProperty.call(value, key);
}

function classifyJsonRpc(message) {
  if (!isObject(message) || message.jsonrpc !== "2.0") return "invalid";
  const hasMethod = typeof message.method === "string" && message.method.length > 0;
  const hasResult = hasOwn(message, "result");
  const hasError = hasOwn(message, "error");
  const hasId = hasOwn(message, "id");
  if (hasMethod && !hasResult && !hasError) return hasId ? "request" : "notification";
  if (!hasMethod && hasId && (hasResult !== hasError)) return "response";
  return "invalid";
}

function requireResponse(message, expectedId) {
  if (classifyJsonRpc(message) !== "response" || message.id !== expectedId) {
    throw new Error("response_envelope");
  }
  if (hasOwn(message, "error")) throw new Error("response_error");
  return message.result;
}

async function cancelBody(response) {
  try {
    await response?.body?.cancel();
  } catch {}
}

async function fetchStrict(endpoint, options, deadline, cap = REQUEST_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), remainingMs(deadline, cap));
  try {
    return await fetch(endpoint, {
      ...options,
      redirect: "error",
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
  }
}

async function readJsonResponse(response, expectedId, deadline, cap) {
  const reader = response.body?.getReader();
  if (!reader) throw new Error("missing_body");
  const chunks = [];
  let total = 0;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), remainingMs(deadline, cap));
  const onAbort = () => { void reader.cancel().catch(() => {}); };
  controller.signal.addEventListener("abort", onAbort, { once: true });
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > MAX_RESPONSE_BYTES) {
        await reader.cancel().catch(() => {});
        throw new Error("response_too_large");
      }
      chunks.push(value);
    }
  } finally {
    clearTimeout(timer);
    controller.signal.removeEventListener("abort", onAbort);
    reader.releaseLock();
  }
  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let message;
  try {
    message = JSON.parse(new TextDecoder().decode(merged));
  } catch {
    throw new Error("invalid_json");
  }
  return requireResponse(message, expectedId);
}

function parseSseEvent(frame) {
  const data = [];
  for (const rawLine of frame.split("\n")) {
    const line = rawLine.endsWith("\r") ? rawLine.slice(0, -1) : rawLine;
    if (!line || line.startsWith(":")) continue;
    const colon = line.indexOf(":");
    const field = colon < 0 ? line : line.slice(0, colon);
    let value = colon < 0 ? "" : line.slice(colon + 1);
    if (value.startsWith(" ")) value = value.slice(1);
    if (field === "data") data.push(value);
  }
  if (data.length === 0) return null;
  let message;
  try {
    message = JSON.parse(data.join("\n"));
  } catch {
    throw new Error("invalid_sse_json");
  }
  if (classifyJsonRpc(message) === "invalid") throw new Error("invalid_jsonrpc");
  return message;
}

async function readSseResponse(response, expectedId, deadline, cap) {
  const reader = response.body?.getReader();
  if (!reader) throw new Error("missing_body");
  const decoder = new TextDecoder();
  let buffer = "";
  let total = 0;
  let events = 0;
  const timerController = new AbortController();
  const timer = setTimeout(() => timerController.abort(), remainingMs(deadline, cap));
  const onAbort = () => { void reader.cancel().catch(() => {}); };
  timerController.signal.addEventListener("abort", onAbort, { once: true });
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > MAX_RESPONSE_BYTES) {
        await reader.cancel().catch(() => {});
        throw new Error("response_too_large");
      }
      buffer += decoder.decode(value, { stream: true });
      buffer = buffer.replace(/\r\n/g, "\n");
      while (true) {
        const boundary = buffer.indexOf("\n\n");
        if (boundary < 0) break;
        const frame = buffer.slice(0, boundary);
        buffer = buffer.slice(boundary + 2);
        if (!frame.trim()) continue;
        events += 1;
        if (events > MAX_SSE_EVENTS) {
          await reader.cancel().catch(() => {});
          throw new Error("too_many_events");
        }
        const message = parseSseEvent(frame);
        if (message === null) continue;
        if (classifyJsonRpc(message) === "response" && message.id === expectedId) {
          const result = requireResponse(message, expectedId);
          await reader.cancel().catch(() => {});
          return result;
        }
      }
    }
    buffer += decoder.decode();
    buffer = buffer.replace(/\r\n/g, "\n");
    if (buffer.trim()) {
      events += 1;
      if (events > MAX_SSE_EVENTS) throw new Error("too_many_events");
      const message = parseSseEvent(buffer);
      if (message !== null && classifyJsonRpc(message) === "response" && message.id === expectedId) {
        return requireResponse(message, expectedId);
      }
    }
    throw new Error("matching_response_missing");
  } catch (error) {
    try { await reader.cancel(); } catch {}
    throw error;
  } finally {
    clearTimeout(timer);
    timerController.signal.removeEventListener("abort", onAbort);
    try { reader.releaseLock(); } catch {}
  }
}

async function readMatchingResponse(response, expectedId, deadline, cap) {
  const contentType = (response.headers.get("content-type") || "").toLowerCase();
  if (contentType.includes("text/event-stream")) {
    return await readSseResponse(response, expectedId, deadline, cap);
  }
  if (contentType.includes("application/json")) {
    return await readJsonResponse(response, expectedId, deadline, cap);
  }
  await cancelBody(response);
  throw new Error("unsupported_content_type");
}

async function postForResponse(endpoint, origin, body, expectedId, deadline, sessionId = null, cap = REQUEST_TIMEOUT_MS) {
  const headers = {
    "content-type": "application/json",
    "accept": "application/json, text/event-stream",
    "origin": origin,
    "mcp-protocol-version": PROTOCOL_VERSION,
  };
  if (sessionId) headers["mcp-session-id"] = sessionId;
  const response = await fetchStrict(endpoint, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  }, deadline, cap);
  if (response.status !== 200) {
    await cancelBody(response);
    throw new Error("http_status");
  }
  const result = await readMatchingResponse(response, expectedId, deadline, cap);
  return {
    result,
    sessionId: response.headers.get("mcp-session-id"),
  };
}

async function postInitializedNotification(endpoint, origin, sessionId, deadline) {
  const response = await fetchStrict(endpoint, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "accept": "application/json, text/event-stream",
      "origin": origin,
      "mcp-protocol-version": PROTOCOL_VERSION,
      "mcp-session-id": sessionId,
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "notifications/initialized",
      params: {},
    }),
  }, deadline);
  await cancelBody(response);
  // The qualified Codexless 2025-03-26 loopback endpoint acknowledges notifications with 202.
  if (response.status !== 202) throw new Error("initialized_notification");
}

async function closeSession(endpoint, origin, sessionId, deadline) {
  if (!sessionId || Date.now() >= deadline) return;
  try {
    const response = await fetchStrict(endpoint, {
      method: "DELETE",
      headers: {
        "accept": "application/json, text/event-stream",
        "origin": origin,
        "mcp-protocol-version": PROTOCOL_VERSION,
        "mcp-session-id": sessionId,
      },
    }, deadline, CLEANUP_TIMEOUT_MS);
    await cancelBody(response);
  } catch {}
}

const port = parsePort(process.argv.slice(2));
if (port === null) {
  fail("BROWSER_PROBE_ARGUMENT_INVALID");
} else {
  const origin = "http://127.0.0.1:" + String(port);
  const endpoint = origin + "/mcp";
  const deadline = Date.now() + OVERALL_TIMEOUT_MS;
  let sessionId = null;
  try {
    const initialized = await postForResponse(endpoint, origin, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: {},
        clientInfo: { name: "codexless-companion-doctor", version: "1" },
      },
    }, 1, deadline);
    sessionId = initialized.sessionId;
    if (!sessionId || initialized.result?.protocolVersion !== PROTOCOL_VERSION) {
      throw new Error("initialize");
    }

    await postInitializedNotification(endpoint, origin, sessionId, deadline);

    const called = await postForResponse(endpoint, origin, {
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: {
        name: "codex.browser_status",
        arguments: {},
      },
    }, 2, deadline, sessionId, BROWSER_STATUS_TIMEOUT_MS);

    const toolResult = called.result;
    const status = toolResult?.structuredContent;
    if (
      !isObject(toolResult) ||
      toolResult.isError === true ||
      !isObject(status)
    ) {
      throw new Error("browser_status_call");
    }

    const browsers = Array.isArray(status.connectedBrowsers) ? status.connectedBrowsers : [];
    const supported = browsers.filter((browser) =>
      browser?.supported === true &&
      browser?.capabilities?.listTabs === true &&
      browser?.capabilities?.claimTabs === true
    );

    const ok =
      status.status === "ok" &&
      status.chromeSkill === "ok" &&
      status.nodeRepl === "ok" &&
      supported.length > 0;

    emit({
      ok,
      browserStatus: status.status === "ok" ? "ok" : "unavailable",
      chromeSkill: status.chromeSkill === "ok" ? "ok" : "unavailable",
      nodeRepl: status.nodeRepl === "ok" ? "ok" : "unavailable",
      supportedBackendCount: supported.length,
      selectionRequired: status.selectionRequired === true,
    }, ok ? 0 : 1);
  } catch {
    fail("BROWSER_PROBE_UNAVAILABLE");
  } finally {
    await closeSession(endpoint, origin, sessionId, deadline);
  }
}
