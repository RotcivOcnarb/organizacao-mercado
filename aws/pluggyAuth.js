// index.mjs — Node.js 20.x (ESM)
// Gera Pluggy Connect Token com logs estruturados para CloudWatch.
//
// Env vars obrigatórias:
//   PLUGGY_CLIENT_ID
//   PLUGGY_CLIENT_SECRET
// Opcionais:
//   CORS_ORIGIN (default "*")
//   LOG_LEVEL = "debug" | "info" (default "info")

const ORIGIN = process.env.CORS_ORIGIN || "*";
const LOG_LEVEL = (process.env.LOG_LEVEL || "info").toLowerCase();
const isDebug = LOG_LEVEL === "debug";

const now = () => new Date().toISOString();
const log = (level, msg, ctx = {}) => {
  // log JSON estruturado (facilita CloudWatch Logs Insights)
  const rec = { ts: now(), level, msg, ...ctx };
  if (level === "error") console.error(JSON.stringify(rec));
  else console.log(JSON.stringify(rec));
};

const json = (status, data) => ({
  statusCode: status,
  headers: {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": ORIGIN,
    "Access-Control-Allow-Headers": "content-type",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
  },
  body: typeof data === "string" ? data : JSON.stringify(data),
});

const getMethod = (event) =>
  (event?.httpMethod ||
   event?.requestContext?.http?.method ||
   event?.requestContext?.httpMethod ||
   "").toUpperCase();

const parseBody = (event) => {
  if (!event?.body) return {};
  const raw = event.isBase64Encoded
    ? Buffer.from(event.body, "base64").toString("utf8")
    : event.body;
  try { return JSON.parse(raw || "{}"); } catch { return {}; }
};

const header = (event, name) => {
  const h = event?.headers || {};
  const key = Object.keys(h).find(k => k.toLowerCase() === name.toLowerCase());
  return key ? h[key] : undefined;
};

export const handler = async (event) => {
  const requestId =
    event?.requestContext?.requestId ||
    event?.requestContext?.awsRequestId ||
    undefined;

  const method = getMethod(event);
  const path = event?.rawPath || event?.path || "/";
  const ctHeader = header(event, "content-type");
  const ua = header(event, "user-agent");

  log("info", "request.received", { requestId, method, path, ctHeader, ua, isBase64: !!event?.isBase64Encoded });

  if (isDebug) {
    // snapshot seguro (não loga body binário)
    log("debug", "request.snapshot", {
      headers: event?.headers,
      query: event?.queryStringParameters,
      hasBody: !!event?.body,
      bodyPreview: typeof event?.body === "string" ? String(event.body).slice(0, 200) : undefined
    });
  }

  try {
    // CORS preflight
    if (method === "OPTIONS") {
      log("info", "cors.preflight.ok", { requestId });
      return json(204, "");
    }

    if (method !== "POST") {
      log("info", "method.not.allowed", { requestId, method });
      return json(405, { error: "Method Not Allowed" });
    }

    const { PLUGGY_CLIENT_ID, PLUGGY_CLIENT_SECRET } = process.env;
    if (!PLUGGY_CLIENT_ID || !PLUGGY_CLIENT_SECRET) {
      log("error", "env.missing", {
        requestId,
        hasClientId: !!PLUGGY_CLIENT_ID,
        hasClientSecret: !!PLUGGY_CLIENT_SECRET
      });
      return json(500, { error: "Missing PLUGGY_CLIENT_ID/PLUGGY_CLIENT_SECRET" });
    }

    const body = parseBody(event);
    const clientUserId = body?.clientUserId ?? "anon";
    log("info", "parsed.body", { requestId, clientUserId });

    // 1) /auth → pega apiKey (~2h)
    const t0 = Date.now();
    log("info", "pluggy.auth.start", { requestId });
    const authRes = await fetch("https://api.pluggy.ai/auth", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        clientId: PLUGGY_CLIENT_ID,
        clientSecret: PLUGGY_CLIENT_SECRET,
      }),
    });
    const t1 = Date.now();

    if (!authRes.ok) {
      const errTxt = await authRes.text();
      log("error", "pluggy.auth.fail", {
        requestId, status: authRes.status, durationMs: t1 - t0, errTxt: errTxt?.slice(0, 400)
      });
      return json(authRes.status, { error: "Pluggy /auth failed", details: errTxt });
    }

    const authJson = await authRes.json();
    const apiKey = authJson?.apiKey;
    log("info", "pluggy.auth.ok", {
      requestId, status: authRes.status, durationMs: t1 - t0, hasApiKey: !!apiKey
    });
    if (!apiKey) {
      log("error", "pluggy.auth.invalid.response", { requestId, authJsonPreview: JSON.stringify(authJson).slice(0, 200) });
      return json(502, { error: "Invalid /auth response (no apiKey)" });
    }

    // 2) /connect_token → cria connectToken (~30 min)
    const t2 = Date.now();
    log("info", "pluggy.ct.start", { requestId, clientUserId });
    const ctRes = await fetch("https://api.pluggy.ai/connect_token", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-API-KEY": apiKey },
      body: JSON.stringify({ options: { clientUserId } }),
    });
    const t3 = Date.now();

    if (!ctRes.ok) {
      const errTxt = await ctRes.text();
      log("error", "pluggy.ct.fail", {
        requestId, status: ctRes.status, durationMs: t3 - t2, errTxt: errTxt?.slice(0, 400)
      });
      return json(ctRes.status, { error: "Pluggy /connect_token failed", details: errTxt });
    }

    const ctJson = await ctRes.json();
    const accessToken = ctJson?.accessToken;
    log("info", "pluggy.ct.ok", {
      requestId, status: ctRes.status, durationMs: t3 - t2, tokenLen: accessToken ? String(accessToken).length : 0
    });
    if (!accessToken) {
      log("error", "pluggy.ct.invalid.response", { requestId, ctJsonPreview: JSON.stringify(ctJson).slice(0, 200) });
      return json(502, { error: "Invalid /connect_token response (no accessToken)" });
    }

    const res = json(200, { connectToken: accessToken });
    log("info", "response.success", { requestId, statusCode: 200 });
    return res;
  } catch (e) {
    log("error", "response.exception", { requestId, error: String(e), stack: e?.stack });
    return json(500, { error: String(e) });
  }
};