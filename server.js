// Mini · 虚拟宠物 —— 本地小服务
// 作用：1) 提供页面静态文件；2) 代理 DeepSeek 余额查询（浏览器直连会被 CORS 拦住）。
// 只用 Node 内置模块，不需要 npm install。

const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = __dirname;
const PORT = Number(process.env.MINI_PET_PORT || 8787);
const HOME = process.env.USERPROFILE || process.env.HOME || '';
const CONFIG_PATH = process.env.DEEPSEEK_CONFIG || path.join(HOME, '.codex', 'config.toml');
const BALANCE_TTL_MS = 60 * 1000;

let cache = { at: 0, payload: null };

function readProviderConfig() {
  const out = { baseUrl: 'https://api.deepseek.com/', token: '' };
  try {
    const text = fs.readFileSync(CONFIG_PATH, 'utf8');
    let inDeepseek = false;
    for (const rawLine of text.split(/\r?\n/)) {
      const line = rawLine.trim();
      const section = line.match(/^\[model_providers\.([^\]]+)\]\s*$/);
      if (section) {
        inDeepseek = section[1] === 'deepseek';
        continue;
      }
      if (line.startsWith('[')) {
        inDeepseek = false;
        continue;
      }
      if (!inDeepseek) continue;
      const kv = line.match(/^([A-Za-z_]+)\s*=\s*"([^"]*)"/);
      if (!kv) continue;
      if (kv[1] === 'base_url') out.baseUrl = kv[2];
      if (kv[1] === 'experimental_bearer_token') out.token = kv[2];
    }
  } catch (err) {
    out.error = 'read config.toml failed: ' + err.message;
  }
  if (process.env.DEEPSEEK_API_KEY) out.token = process.env.DEEPSEEK_API_KEY;
  out.baseUrl = out.baseUrl.replace(/\/+$/, '') + '/';
  return out;
}

function maskToken(token) {
  if (!token) return '';
  return token.slice(0, 5) + '****' + token.slice(-4);
}

function loadPricing() {
  const fallback = {
    offPeak: { utcStart: '16:30', utcEnd: '00:30', label: '优惠时段', labelStandard: '标准时段', note: '' },
    models: []
  };
  try {
    const parsed = JSON.parse(fs.readFileSync(path.join(ROOT, 'pricing.json'), 'utf8'));
    return Object.assign(fallback, parsed);
  } catch (err) {
    fallback.loadError = err.message;
    return fallback;
  }
}

async function fetchBalance() {
  const now = Date.now();
  if (cache.payload && now - cache.at < BALANCE_TTL_MS) return cache.payload;

  const cfg = readProviderConfig();
  if (!cfg.token) {
    return {
      ok: false,
      error: '没在 ' + CONFIG_PATH + ' 里找到 deepseek 的 experimental_bearer_token',
      checkedAt: now
    };
  }

  let payload;
  try {
    const res = await fetch(cfg.baseUrl + 'user/balance', {
      headers: { Authorization: 'Bearer ' + cfg.token, Accept: 'application/json' },
      signal: AbortSignal.timeout(12000)
    });
    const text = await res.text();
    let body = null;
    try {
      body = JSON.parse(text);
    } catch (parseErr) {
      body = null;
    }
    if (!res.ok) {
      const msg = (body && body.error && body.error.message) || text.slice(0, 200);
      payload = { ok: false, status: res.status, error: msg, checkedAt: now };
    } else if (!body || !Array.isArray(body.balance_infos)) {
      payload = { ok: false, error: '余额接口返回了意料之外的结构', checkedAt: now };
    } else {
      const wanted = body.balance_infos.find(function (b) { return b.currency === 'CNY'; }) || body.balance_infos[0];
      payload = {
        ok: true,
        isAvailable: Boolean(body.is_available),
        currency: wanted.currency,
        total: Number(wanted.total_balance),
        granted: Number(wanted.granted_balance),
        toppedUp: Number(wanted.topped_up_balance),
        all: body.balance_infos,
        checkedAt: now
      };
    }
  } catch (err) {
    payload = { ok: false, error: '请求 DeepSeek 失败：' + (err && err.message ? err.message : String(err)), checkedAt: now };
  }

  cache = { at: now, payload: payload };
  return payload;
}

function sendJson(res, code, body) {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(body));
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.webp': 'image/webp'
};

function serveStatic(res, pathname) {
  const rel = pathname === '/' ? 'index.html' : decodeURIComponent(pathname).replace(/^\/+/, '');
  const target = path.resolve(ROOT, rel);
  if (!target.startsWith(ROOT)) {
    res.writeHead(403);
    res.end('forbidden');
    return;
  }
  fs.readFile(target, function (err, buf) {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('not found');
      return;
    }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(target).toLowerCase()] || 'application/octet-stream' });
    res.end(buf);
  });
}

const server = http.createServer(function (req, res) {
  const pathname = new URL(req.url, 'http://127.0.0.1').pathname;

  if (pathname === '/api/status') {
    const cfg = readProviderConfig();
    fetchBalance().then(function (balance) {
      sendJson(res, 200, {
        now: Date.now(),
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        pricing: loadPricing(),
        balance: balance,
        provider: { baseUrl: cfg.baseUrl, token: maskToken(cfg.token), configPath: CONFIG_PATH }
      });
    });
    return;
  }

  if (pathname === '/api/refresh') {
    cache = { at: 0, payload: null };
    sendJson(res, 200, { ok: true });
    return;
  }

  serveStatic(res, pathname);
});

server.listen(PORT, '127.0.0.1', function () {
  console.log('Mini · 虚拟宠物 已启动：http://127.0.0.1:' + PORT + '/');
  console.log('余额来源：' + (process.env.DEEPSEEK_API_KEY ? '环境变量 DEEPSEEK_API_KEY' : CONFIG_PATH));
});
