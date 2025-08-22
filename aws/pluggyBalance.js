// index.mjs — AWS Lambda /balance (Node 18/22, ESM)
// - Auth: POST /auth (clientId/secret) → usa X-API-KEY nas chamadas subsequentes
// - Refresh opcional: ?refresh=1 (ou body {"refresh":true}) → PATCH /items/{id} + poll até 30s
// - Fetch de contas + enriquecimento de limite de cartão via detalhe
// - CORS + debug opcional

const PLUGGY_API_BASE = process.env.PLUGGY_API_BASE || 'https://api.pluggy.ai';
const PLUGGY_CLIENT_ID = process.env.PLUGGY_CLIENT_ID || '';
const PLUGGY_CLIENT_SECRET = process.env.PLUGGY_CLIENT_SECRET || '';
const CORS_ORIGINS = (process.env.CORS_ORIGINS || '').split(',').map(s => s.trim()).filter(Boolean);
const DEBUG_RAW = (process.env.DEBUG_RAW || '') === '1';
const LOG_BODY_LIMIT = Number(process.env.LOG_BODY_LIMIT || 600);

/* ===== CORS ===== */
const pickOrigin = (event) => {
  const o = event?.headers?.origin || event?.headers?.Origin;
  if (!o) return '*';
  if (CORS_ORIGINS.length === 0) return o;
  return CORS_ORIGINS.includes(o) ? o : CORS_ORIGINS[0];
};
const cors = (event) => ({
  'Access-Control-Allow-Origin': pickOrigin(event),
  'Access-Control-Allow-Headers': 'content-type',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  'Content-Type': 'application/json',
});

/* ===== Utils ===== */
const toDouble = (v) => {
  if (typeof v === 'number') return Number.isFinite(v) ? v : 0;
  if (typeof v === 'string') {
    const p = parseFloat(v.replace(',', '.'));
    return Number.isFinite(p) ? p : 0;
  }
  return 0;
};
const get = (obj, path) => path.reduce((o, k) => (o && o[k] != null ? o[k] : null), obj);
const mask = (s, keep = 4) => (!s ? '' : `${s.slice(0, keep)}…${s.slice(-keep)}`);
const headersToObject = (h) => {
  const out = {};
  try { for (const [k, v] of h.entries()) out[k.toLowerCase()] = v; } catch {}
  return out;
};
const isCreditLike = (a) => {
  const t = (a.type || a.accountType || '').toString().toUpperCase();
  return t.includes('CREDIT') || t.includes('CARD') || a.creditLimit != null || a.available != null;
};

/* ===== API Key cache (/auth) + logs ===== */
let _cachedApiKey = null;
let _apiKeyExpiresAt = 0; // epoch ms
let _lastAuthLog = null;

async function obtainApiKeyWithLogs() {
  const now = Date.now();
  if (_cachedApiKey && now < _apiKeyExpiresAt - 60_000) {
    _lastAuthLog = { ok: true, cache: true, expiresAt: _apiKeyExpiresAt };
    return _cachedApiKey;
  }
  if (!PLUGGY_CLIENT_ID || !PLUGGY_CLIENT_SECRET) {
    const msg = 'PLUGGY_CLIENT_ID/PLUGGY_CLIENT_SECRET não configurados';
    console.log('[auth] FAIL:', msg);
    _lastAuthLog = { ok: false, reason: msg };
    throw new Error(msg);
  }

  const url = `${PLUGGY_API_BASE}/auth`;
  const shapes = [
    { shape: 'camel', body: { clientId: PLUGGY_CLIENT_ID, clientSecret: PLUGGY_CLIENT_SECRET } },
    { shape: 'snake', body: { client_id: PLUGGY_CLIENT_ID, client_secret: PLUGGY_CLIENT_SECRET } },
  ];
  const attempts = [];

  for (const s of shapes) {
    const entry = {
      url, shape: s.shape, bodyKeys: Object.keys(s.body),
      clientIdMasked: mask(PLUGGY_CLIENT_ID),
      status: null, statusText: null, respHeaders: null, respBodyFirst: null, ok: false,
    };
    attempts.push(entry);

    try {
      console.log('[auth] POST /auth', s.shape, 'cid=', entry.clientIdMasked);
      const r = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(s.body),
      });
      const txt = await r.text().catch(() => '');
      entry.status = r.status;
      entry.statusText = r.statusText;
      entry.respHeaders = headersToObject(r.headers);
      entry.respBodyFirst = txt.slice(0, LOG_BODY_LIMIT);

      console.log('[auth] attempt', s.shape, '=>', r.status, r.statusText);
      if (entry.respHeaders['www-authenticate']) {
        console.log('[auth] www-authenticate:', entry.respHeaders['www-authenticate']);
      }
      if (txt) console.log('[auth] body(first):', entry.respBodyFirst);

      if (!r.ok) continue;

      let data = {};
      try { data = JSON.parse(txt); } catch {}
      // Pluggy retorna normalmente "apiKey"
      const apiKey = data.apiKey || data.accessToken || data.access_token || data.token || data?.data?.apiKey;
      const expiresIn = Number(data.expiresIn || data.expires_in || data?.data?.expiresIn || 7200); // 2h default

      if (apiKey) {
        _cachedApiKey = apiKey;
        _apiKeyExpiresAt = Date.now() + expiresIn * 1000;
        entry.ok = true;
        _lastAuthLog = { ok: true, cache: false, attempts };
        return _cachedApiKey;
      }
    } catch (e) {
      entry.error = String(e);
      console.log('[auth] exception', s.shape, String(e));
    }
  }

  _lastAuthLog = { ok: false, attempts };
  throw new Error('Falha ao obter API Key (/auth); veja logs/_debug.auth');
}

async function apiKeyHeader() {
  const apiKey = await obtainApiKeyWithLogs();
  // Cabecalho correto para Pluggy
  return { 'X-API-KEY': apiKey, 'Content-Type': 'application/json' };
}

/* ===== Normalização de contas ===== */
function normalizeAccount(raw) {
  const type = (raw.type ?? raw.accountType ?? '').toString();

  const creditLimit =
    toDouble(raw.creditLimit) ||
    toDouble(raw.limit) ||
    toDouble(raw.creditLimitLocalCurrency) ||
    toDouble(get(raw, ['creditData', 'creditLimit'])) ||
    toDouble(get(raw, ['creditData', 'limit'])) ||
    toDouble(get(raw, ['credit_card', 'limit'])) ||
    toDouble(get(raw, ['card', 'creditLimit'])) ||
    toDouble(get(raw, ['card', 'limit'])) ||
    0;

  const available =
    toDouble(raw.available) ||
    toDouble(raw.availableBalance) ||
    toDouble(raw.availableCredit) ||
    toDouble(raw.available_amount) ||
    toDouble(raw.available_limit) ||
    toDouble(get(raw, ['creditData', 'available'])) ||
    toDouble(get(raw, ['card', 'available'])) ||
    0;

  return {
    id: String(raw.id ?? ''),
    name: String(raw.name ?? raw.marketingName ?? 'Conta'),
    currency: String(raw.currencyCode ?? 'BRL'),
    type,
    balance: toDouble(raw.balance), // cartões frequentemente reportam "usado" aqui
    creditLimit: creditLimit > 0 ? creditLimit : null,
    available:  available  > 0 ? available  : null,
    _originalType: type,
  };
}

const creditUsed = (acc) => {
  if (!isCreditLike(acc)) return 0;
  if (acc.creditLimit && acc.available != null) {
    const used = acc.creditLimit - acc.available;
    return used > 0 ? Math.min(used, acc.creditLimit) : 0;
  }
  const used = Math.abs(toDouble(acc.balance));
  return acc.creditLimit ? Math.min(used, acc.creditLimit) : used;
};
const availableCredit = (acc) => {
  if (!isCreditLike(acc)) return 0;
  if (acc.available != null) {
    return acc.creditLimit ? Math.max(0, Math.min(acc.available, acc.creditLimit)) : Math.max(0, acc.available);
  }
  if (!acc.creditLimit) return 0;
  const avail = acc.creditLimit - creditUsed(acc);
  return Math.max(0, avail);
};

const sumDeposits    = (accounts) => accounts.filter(a => !isCreditLike(a)).reduce((s, a) => s + toDouble(a.balance), 0);
const sumAvailCredit = (accounts) => accounts.filter(a =>  isCreditLike(a)).reduce((s, a) => s + availableCredit(a), 0);

/* ===== HTTP helpers ===== */
async function httpJson(url, { method = 'GET', body = null, label = '' } = {}) {
  console.log('[DEBUG] httpJson iniciado para URL:', url, 'método:', method, 'label:', label);
  
  try {
    const headers = await apiKeyHeader();
    console.log('[DEBUG] Headers preparados:', Object.keys(headers).join(', '));
    
    const init = { method, headers };
    if (body != null) {
      init.body = typeof body === 'string' ? body : JSON.stringify(body);
      console.log('[DEBUG] Body preparado, tamanho:', init.body.length);
    }

    console.log('[fetch]', method, label || '', url);
    const startTime = Date.now();
    const r = await fetch(url, init);
    const timeElapsed = Date.now() - startTime;
    console.log('[DEBUG] Fetch concluído em', timeElapsed, 'ms, status:', r.status, r.statusText);
    
    const txt = await r.text().catch(() => '');
    console.log('[fetch]', label || '', 'status', r.status, r.statusText, 'len', txt.length);

    let data = {};
    try { 
      data = JSON.parse(txt); 
      console.log('[DEBUG] Resposta JSON válida recebida');
    } catch (e) {
      console.log('[DEBUG] ERRO ao fazer parse do JSON:', e.message);
      console.log('[fetch]', label || '', 'WARN corpo não-JSON (200 chars):', txt.slice(0, 200));
    }
    
    if (!r.ok) {
      console.log('[DEBUG] Resposta não-OK:', r.status, r.statusText);
      console.log('[DEBUG] Corpo da resposta de erro (200 chars):', txt.slice(0, 200));
      throw new Error(`${label || url} -> ${r.status} ${r.statusText} ${txt}`);
    }
    
    return data;
  } catch (e) {
    console.log('[DEBUG] ERRO em httpJson:', e.message);
    console.log('[DEBUG] Stack trace:', e.stack || 'Não disponível');
    throw e; // Re-throw para tratamento adequado no chamador
  }
}

async function fetchAccountsRaw(itemId) {
  console.log('[DEBUG] fetchAccountsRaw iniciado para itemId:', itemId);
  const urls = [
    { url: `${PLUGGY_API_BASE}/accounts?itemId=${encodeURIComponent(itemId)}`, label: 'accounts by itemId' },
    { url: `${PLUGGY_API_BASE}/items/${encodeURIComponent(itemId)}/accounts`, label: 'accounts under item' },
  ];
  
  console.log('[DEBUG] URLs a serem tentadas:', urls.map(u => u.url));
  
  for (const u of urls) {
    try {
      console.log('[DEBUG] Tentando buscar contas de:', u.url);
      const data = await httpJson(u.url, { label: u.label });
      console.log('[DEBUG] Resposta recebida para', u.label, 'tipo:', typeof data, 'é array?', Array.isArray(data));
      
      const list = Array.isArray(data) ? data : (Array.isArray(data.results) ? data.results : []);
      console.log('[accounts] fonte=', u.label, 'qty=', list.length, 'formato=', Array.isArray(data) ? 'array' : Object.keys(data));
      
      if (list.length === 0) {
        console.log('[DEBUG] Lista de contas vazia para', u.label);
      }
      
      if ((DEBUG_RAW || true) && list.length) {
        console.log('[accounts][raw][sample0]', JSON.stringify(list[0], null, 2));
      }
      
      if (list.length) {
        console.log('[DEBUG] Retornando', list.length, 'contas de', u.label);
        return { rawList: list, source: u.label };
      }
    } catch (e) {
      console.log('[DEBUG] ERRO ao buscar contas de', u.label, ':', String(e));
      console.log('[DEBUG] Stack trace (se disponível):', e.stack || 'Não disponível');
      console.log('[accounts] tentativa falhou', u.label, String(e));
    }
  }
  
  console.log('[DEBUG] ALERTA: Nenhuma conta encontrada após tentar todas as URLs');
  return { rawList: [], source: 'none' };
}

async function fetchAccountDetailRaw(accountId) {
  const url = `${PLUGGY_API_BASE}/accounts/${encodeURIComponent(accountId)}`;
  const det = await httpJson(url, { label: `account detail ${accountId}` });
  if (DEBUG_RAW) console.log('[accountDetail][raw]', accountId, JSON.stringify(det, null, 2));
  return det;
}

async function enrichCreditAccounts(accounts, rawSourceNote) {
  const need = accounts.filter(a => isCreditLike(a) && !a.creditLimit);
  console.log('[enrich] contas de crédito sem limit:', need.length, 'source=', rawSourceNote);

  await Promise.all(need.map(async (a) => {
    try {
      const det = await fetchAccountDetailRaw(a.id);
      const lim =
        toDouble(det.creditLimit) ||
        toDouble(det.limit) ||
        toDouble(det.creditLimitLocalCurrency) ||
        toDouble(get(det, ['creditData', 'creditLimit'])) ||
        toDouble(get(det, ['creditData', 'limit'])) ||
        toDouble(get(det, ['credit_card', 'limit'])) ||
        toDouble(get(det, ['card', 'creditLimit'])) ||
        toDouble(get(det, ['card', 'limit'])) ||
        0;
      const avail =
        toDouble(det.available) ||
        toDouble(det.availableBalance) ||
        toDouble(det.availableCredit) ||
        toDouble(get(det, ['creditData', 'available'])) ||
        toDouble(get(det, ['card', 'available'])) ||
        0;

      if (lim > 0) a.creditLimit = lim;
      if (avail > 0) a.available  = avail;

      console.log('[enrich] account', a.id, a.name, 'limit=', a.creditLimit, 'available=', a.available);
    } catch (e) {
      console.log('[enrich] detail fail', a.id, String(e));
    }
  }));
  return accounts;
}

/* ===== NOVO: Item update & poll ===== */
async function getItem(itemId) {
  const url = `${PLUGGY_API_BASE}/items/${encodeURIComponent(itemId)}`;
  return await httpJson(url, { label: 'item GET' });
}

async function updateItem(itemId) {
  const url = `${PLUGGY_API_BASE}/items/${encodeURIComponent(itemId)}`;
  return await httpJson(url, { method: 'PATCH', body: {}, label: 'item PATCH (trigger sync)' });
}

async function waitForItemSync(itemId, { timeoutMs = 30000, intervalMs = 3000 } = {}) {
  const t0 = Date.now();
  let last = null;
  while (Date.now() - t0 < timeoutMs) {
    last = await getItem(itemId);
    const status = String(last.status || '').toUpperCase();
    const exec = String(last.executionStatus || '').toUpperCase();
    console.log('[item] status=', status, 'execStatus=', exec);
    if (status !== 'UPDATING') return last; // terminou ou exigiu ação
    await new Promise(r => setTimeout(r, intervalMs));
  }
  return last; // ainda UPDATING; devolve snapshot
}

/* ===== Handler ===== */
export async function handler(event) {
  console.log('[DEBUG] Handler iniciado com evento:', JSON.stringify(event, null, 2));
  
  const method = (event?.httpMethod || event?.requestContext?.http?.method || 'GET').toUpperCase();
  console.log('[DEBUG] Método HTTP:', method);
  
  if (method === 'OPTIONS') {
    console.log('[DEBUG] Respondendo a requisição OPTIONS com CORS headers');
    return { statusCode: 204, headers: cors(event), body: '' };
  }

  try {
    console.log('[DEBUG] Processando requisição', method);
    const qs = event?.queryStringParameters || {};
    console.log('[DEBUG] Query params:', JSON.stringify(qs));
    
    const debugEcho = DEBUG_RAW || qs.debug === '1' || qs.debug === 'raw' || qs.debug === 'auth';
    console.log('[DEBUG] debugEcho:', debugEcho, 'DEBUG_RAW:', DEBUG_RAW);

    if (!PLUGGY_CLIENT_ID || !PLUGGY_CLIENT_SECRET) {
      console.log('[DEBUG] ERRO: Credenciais Pluggy não configuradas');
      return { statusCode: 500, headers: cors(event), body: JSON.stringify({ message: 'PLUGGY_CLIENT_ID/PLUGGY_CLIENT_SECRET não configurados' }) };
    }
    console.log('[DEBUG] Credenciais Pluggy configuradas corretamente');

    // Parse body (inclui base64, se vier)
    let bodyObj = {};
    if (event?.body) {
      try {
        console.log('[DEBUG] Processando body, isBase64Encoded:', event.isBase64Encoded);
        const raw = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf-8') : event.body;
        console.log('[DEBUG] Body raw (primeiros 100 chars):', raw.slice(0, 100));
        bodyObj = typeof raw === 'string' ? JSON.parse(raw || '{}') : (raw || {});
        console.log('[DEBUG] Body parseado:', JSON.stringify(bodyObj));
      } catch (e) {
        console.log('[DEBUG] ERRO ao parsear body:', e.message);
      }
    } else {
      console.log('[DEBUG] Nenhum body na requisição');
    }

    let itemId = qs.itemId || bodyObj.itemId;
    console.log('[DEBUG] itemId extraído:', itemId);
    
    if (!itemId) {
      console.log('[DEBUG] ERRO: itemId não fornecido');
      return { statusCode: 400, headers: cors(event), body: JSON.stringify({ message: 'itemId é obrigatório' }) };
    }

    const doRefresh = (qs.refresh === '1' || qs.refresh === 'true' || !!bodyObj.refresh);
    console.log('[DEBUG] doRefresh:', doRefresh, 'baseado em:', qs.refresh);

    console.log('[balance] base=', PLUGGY_API_BASE, 'itemId=', itemId, 'cid=', mask(PLUGGY_CLIENT_ID), 'refresh=', doRefresh);
    console.log('[DEBUG] Ambiente:', process.env.NODE_ENV || 'não definido');
    console.log('[DEBUG] Versão Node:', process.version);

    // 0) Obter API key (/auth)
    try {
      await obtainApiKeyWithLogs();
    } catch (e) {
      const payload = {
        message: 'Falha na autenticação com o Pluggy (/auth)',
        hint: 'Confirme client_id/secret e ambiente (sandbox/prod).',
        error: String(e),
      };
      if (debugEcho) payload._debug = { auth: _lastAuthLog };
      return { statusCode: 502, headers: cors(event), body: JSON.stringify(payload) };
    }

    // (Opcional) 1) Refresh: dispara sync e aguarda
    if (doRefresh) {
      try {
        await updateItem(itemId); // dispara a sincronização
      } catch (e) {
        console.log('[item] PATCH falhou, mas vamos tentar prosseguir:', String(e));
      }

      const item = await waitForItemSync(itemId, { timeoutMs: 30000, intervalMs: 3000 });
      const status = String(item?.status || '').toUpperCase();

      if (status === 'UPDATING') {
        // Ainda sincronizando → retorne 202 para app tentar novamente
        return {
          statusCode: 202,
          headers: cors(event),
          body: JSON.stringify({
            message: 'Sincronização em andamento',
            item: { id: itemId, status, nextAutoSyncAt: item?.nextAutoSyncAt || null },
          }),
        };
      }

      if (status === 'LOGIN_ERROR' || status === 'WAITING_USER_INPUT' || status === 'OUTDATED') {
        return {
          statusCode: 409,
          headers: cors(event),
          body: JSON.stringify({
            message: 'O item requer ação do usuário para atualizar',
            needsUserAction: true,
            status,
            hint: 'Abra o Pluggy Connect em modo Update passando o itemId.',
          }),
        };
      }
      // Se for FINISHED/SUCCEEDED/AVAILABLE/etc → continua fluxo normal
    }

    // 2) Contas cruas
    console.log('[DEBUG] Iniciando busca de contas para itemId:', itemId);
    const { rawList, source } = await fetchAccountsRaw(itemId);
    console.log('[DEBUG] Busca de contas concluída, encontradas:', rawList.length, 'fonte:', source);

    // 3) Normaliza e enriquece
    console.log('[DEBUG] Iniciando normalização de', rawList.length, 'contas');
    let accounts = rawList.map(normalizeAccount);
    console.log('[DEBUG] Normalização concluída, iniciando enriquecimento de contas de crédito');
    accounts = await enrichCreditAccounts(accounts, source);
    console.log('[DEBUG] Enriquecimento concluído, contas processadas:', accounts.length);

    // 4) Totais
    console.log('[DEBUG] Calculando totais');
    const deposits = sumDeposits(accounts);
    console.log('[DEBUG] Total de depósitos calculado:', deposits);
    const creditAvailable = sumAvailCredit(accounts);
    console.log('[DEBUG] Crédito disponível calculado:', creditAvailable);
    const allBalancesSum = accounts.reduce((s, a) => s + toDouble(a.balance), 0);
    console.log('[DEBUG] Soma de todos os saldos calculada:', allBalancesSum);
    console.log('[totals]', { deposits, creditAvailable, allBalancesSum });

    // 5) Resposta
    const resp = {
      totalBalance: Number(deposits.toFixed(2)), // só depósitos (débito)
      totals: {
        deposits: Number(deposits.toFixed(2)),
        creditAvailable: Number(creditAvailable.toFixed(2)),
        allAccountsBalanceSum: Number(allBalancesSum.toFixed(2)),
      },
      accounts,
    };
    if (debugEcho) {
      resp._debug = {
        auth: _lastAuthLog,
        source,
        rawCount: rawList.length,
        rawSampleFirst: rawList[0] || null,
      };
    }

    return { statusCode: 200, headers: cors(event), body: JSON.stringify(resp) };
  } catch (err) {
    console.error('balance error', err);
    console.log('[DEBUG] ERRO CRÍTICO no handler principal:', err.message);
    console.log('[DEBUG] Stack trace completo:', err.stack || 'Não disponível');
    console.log('[DEBUG] Tipo de erro:', err.constructor.name);
    
    // Verificar se é um erro de rede ou timeout
    const isNetworkError = err.message.includes('ECONNREFUSED') || 
                          err.message.includes('ETIMEDOUT') || 
                          err.message.includes('network') ||
                          err.message.includes('fetch');
    
    // Verificar se é um erro de API do Pluggy
    const isPluggyError = err.message.includes('Pluggy') || 
                         err.message.includes('apiKey') || 
                         err.message.includes('X-API-KEY');
    
    // Verificar se é um erro de parsing JSON
    const isJsonError = err.message.includes('JSON') || 
                       err.message.includes('Unexpected token') || 
                       err.message.includes('SyntaxError');
    
    let errorType = 'unknown';
    if (isNetworkError) errorType = 'network';
    else if (isPluggyError) errorType = 'pluggy_api';
    else if (isJsonError) errorType = 'json_parse';
    
    console.log('[DEBUG] Tipo de erro classificado como:', errorType);
    
    return {
      statusCode: 500,
      headers: cors(event),
      body: JSON.stringify({ 
        message: 'Erro ao obter saldo', 
        error: String(err),
        errorType,
        timestamp: new Date().toISOString(),
        requestId: event.requestContext?.requestId || 'unknown'
      }),
    };
  }
}
