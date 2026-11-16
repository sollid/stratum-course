// Имитация сайта для проверки привязки устройства в тестах. В архив плагина не входит.
// Повторяет договор /api/plugin/* (pair/start, pair/poll, step, task) и умеет по команде отвечать 429, 503 (busy, preview), 404, 410, 401.
// Запуск отдельно: node <путь к этому файлу> [--port N]. Из тестов: import { startMock }.
// Управление (только с 127.0.0.1, не часть договора): POST /__mock/<команда> с JSON-телом.
//   set      {interval?, expires_in?}        подсказки в ответе pair/start
//   queue    {route:'start'|'poll'|'step'|'task', replies:[{status, body?, headers?, raw?, raw_b64?}, ...]}  разовые ответы вперёд обычной логики
//            (raw — текст как есть вместо JSON, raw_b64 — байты в base64; тип содержимого text/plain; charset=utf-8)
//   mode     {route, status, body?, headers?} постоянный ответ маршрута (null вместо status — снять)
//   confirm  {user_code?}                    «человек ввёл код на сайте»: последний (или названный) код становится подтверждённым
//   revoke   {}                              отозвать все токены (следующая отметка — 401)
//   expire   {}                              просрочить все ожидающие коды (опрос — 410)
//   reset    {}                              очистить всё
//   log      (GET)                           журнал запросов: [{route, method, auth, body, url, t, ct, origin}] (токен в журнале заменён на «Bearer *»)
import { createServer } from 'node:http';
import { randomBytes, randomInt } from 'node:crypto';

const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const STEPS = { m1: ['s1', 's2', 's3', 's4', 's5'], m2: ['s1', 's2', 's3', 's4', 's5'], m3: ['s1', 's2', 's3', 's4', 's5'] };
const TOKEN_SHAPE = /^mock_[A-Za-z0-9_-]{43}$/;

// opts.steps — какие шаги принимает отметка (по умолчанию пять шагов трёх модулей); opts.taskSource — функция ({marks, body}) => {status?, headers?, raw}:
// opts.reasonOk(module, step, reason) — допустим ли код причины (без неё принимается любой); успешный ответ маршрута task (без неё маршрут task отвечает 404, как боевой сайт с выключенным плагином)
export async function startMock({ port = 0, host = '127.0.0.1', steps = STEPS, taskSource = null, reasonOk = null } = {}) {
  const state = {};
  const reset = () => {
    state.codes = new Map(); // device_code -> {userCode, confirmed, used, expired}
    state.tokens = new Map(); // token -> {revoked}
    state.marks = new Map(); // module/step -> passed
    state.detail = new Map(); // module/step -> {passed, reason}: что сайт знает для выбора текущего шага
    state.queues = { start: [], poll: [], step: [], task: [] };
    state.modes = { start: null, poll: null, step: null, task: null };
    state.opts = { interval: 5, expires_in: 600 };
    state.log = [];
  };
  reset();

  const send = (res, status, body, headers = {}, raw = undefined) => {
    if (raw !== undefined) {
      res.writeHead(status, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'private, no-store', ...headers });
      res.end(raw);
      return;
    }
    res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'private, no-store', ...headers });
    res.end(JSON.stringify(body));
  };
  const sendReply = (res, r) => send(res, r.status, r.body ?? {}, r.headers ?? {}, r.raw_b64 !== undefined ? Buffer.from(r.raw_b64, 'base64') : r.raw);
  const readBody = (req) => new Promise((resolve) => {
    const chunks = []; let size = 0;
    const cap = req.url.startsWith('/__mock/') ? 4 * 1024 * 1024 : 8192; // команды управления несут и большие ответы для проверки отказов
    req.on('data', (c) => { size += c.length; if (size <= cap) chunks.push(c); });
    req.on('end', () => resolve({ text: Buffer.concat(chunks).toString('utf8'), size }));
  });

  const server = createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const path = url.pathname;
    const { text, size } = await readBody(req);
    let json; try { json = JSON.parse(text); } catch { json = undefined; }

    if (path.startsWith('/__mock/')) {
      const cmd = path.slice(8);
      if (cmd === 'log') return send(res, 200, state.log);
      const b = json ?? {};
      if (cmd === 'reset') reset();
      else if (cmd === 'set') Object.assign(state.opts, b);
      else if (cmd === 'queue') state.queues[b.route].push(...b.replies);
      else if (cmd === 'mode') state.modes[b.route] = b.status == null ? null : b;
      else if (cmd === 'confirm') {
        const list = [...state.codes.values()].filter((c) => !c.used);
        const hit = b.user_code ? list.find((c) => c.userCode === b.user_code) : list[list.length - 1];
        if (!hit) return send(res, 404, { error: 'no_code' });
        hit.confirmed = true;
      } else if (cmd === 'revoke') for (const t of state.tokens.values()) t.revoked = true;
      else if (cmd === 'expire') for (const c of state.codes.values()) c.expired = true;
      else return send(res, 404, { error: 'no_command' });
      return send(res, 200, { ok: true });
    }

    const m = /^\/api\/plugin\/(pair\/start|pair\/poll|step|task)$/.exec(path);
    if (!m) return send(res, 404, { error: 'not_found' });
    const route = m[1] === 'pair/start' ? 'start' : m[1] === 'pair/poll' ? 'poll' : m[1];
    const auth = req.headers.authorization ? 'Bearer *' : '';
    state.log.push({ route, method: req.method, auth, body: json ?? text, url: req.url, t: Date.now(), ct: req.headers['content-type'] ?? '', origin: req.headers.origin ?? '' });

    const queued = state.queues[route].shift();
    if (queued) return sendReply(res, queued);
    const mode = state.modes[route];
    if (mode) return sendReply(res, mode);
    if (req.method !== 'POST') return send(res, 405, { error: 'method' }, { Allow: 'POST' });
    // Порядок проверок у step и task, как на сайте: ворота режима, токен, тело
    const hdr = req.headers.authorization ?? '';
    const bearer = /^Bearer (\S+)$/.exec(hdr)?.[1];
    const t = bearer && TOKEN_SHAPE.test(bearer) ? state.tokens.get(bearer) : undefined;
    if ((route === 'step' || route === 'task') && (!t || t.revoked)) return send(res, 401, { error: 'token', hint: 'reconnect' }, { 'WWW-Authenticate': 'Bearer' });
    if (!/^application\/json(\s*;|$)/i.test(req.headers['content-type'] ?? '')) return send(res, 415, { error: 'content_type' });
    if (size > 4096) return send(res, 413, { error: 'too_large' });
    if (json === undefined || typeof json !== 'object' || json === null) return send(res, 400, { error: 'bad_json' });

    if (route === 'start') {
      const okBody = ['windows', 'mac', 'linux'].includes(json.os) && typeof json.plugin_version === 'string' && json.plugin_version.length >= 1 && json.plugin_version.length <= 20
        && (json.label === undefined || (typeof json.label === 'string' && json.label.length <= 40));
      if (!okBody) return send(res, 422, { error: 'invalid' });
      const deviceCode = randomBytes(32).toString('base64url');
      let user = ''; for (let i = 0; i < 8; i++) user += ALPHABET[randomInt(ALPHABET.length)];
      state.codes.set(deviceCode, { userCode: user, confirmed: false, used: false, expired: false });
      return send(res, 200, { device_code: deviceCode, user_code: `${user.slice(0, 4)}-${user.slice(4)}`, expires_in: state.opts.expires_in, interval: state.opts.interval, verification_path: '/connect' });
    }
    if (route === 'poll') {
      const c = typeof json.device_code === 'string' ? state.codes.get(json.device_code) : undefined;
      if (!c || c.used || c.expired) return send(res, 410, { status: 'expired' });
      if (!c.confirmed) return send(res, 200, { status: 'pending' });
      c.used = true;
      const token = `mock_${randomBytes(32).toString('base64url')}`;
      state.tokens.set(token, { revoked: false });
      return send(res, 200, { status: 'ready', token, device_id: crypto.randomUUID(), expires_at: new Date(Date.now() + 30 * 86400000).toISOString() }, { Pragma: 'no-cache' });
    }
    if (route === 'task') {
      const okTask = typeof json.plugin_version === 'string' && json.plugin_version.length >= 1 && json.plugin_version.length <= 20 && ['windows', 'mac', 'linux'].includes(json.os)
        && Number.isInteger(json.engine) && json.engine >= 1 && json.engine <= 99;
      if (!okTask) return send(res, 422, { error: 'invalid' });
      if (!taskSource) return send(res, 404, { error: 'not_found' });
      const r = await taskSource({ marks: state.detail, body: json, accept: req.headers.accept ?? '' });
      return send(res, r.status ?? 200, {}, r.headers ?? {}, r.raw);
    }
    const ok = typeof json.module === 'string' && typeof json.step === 'string' && typeof json.passed === 'boolean' && typeof json.check_version === 'string'
      && typeof json.plugin_version === 'string' && ['windows', 'mac', 'linux'].includes(json.os) && (json.reason === undefined || (typeof json.reason === 'string' && /^[a-z0-9_]{1,40}$/.test(json.reason)))
      && json.module.length <= 20 && json.step.length <= 20 && json.check_version.length <= 20 && json.plugin_version.length <= 20;
    if (!ok) return send(res, 422, { error: 'invalid' });
    if (!steps[json.module]?.includes(json.step)) return send(res, 422, { error: 'unknown_step' });
    // как сайт: код причины должен быть из списка кодов этого шага или из общего списка движка, иначе 422 invalid
    if (json.reason !== undefined && reasonOk && !reasonOk(json.module, json.step, json.reason)) return send(res, 422, { error: 'invalid' });
    const key = `${json.module}/${json.step}`;
    // «Засчитано сейчас» — отметки не было или «не пройдено» сменилось на «пройдено»; точный повтор (и «не пройдено» после «пройдено») — repeated
    const prev = state.marks.get(key);
    const repeated = prev !== undefined && (prev === true || json.passed === false);
    state.marks.set(key, prev === true || json.passed);
    // Для выбора текущего шага: «пройдено» не снимается; «не пройдено» заменяет прежнее «не пройдено» вместе с кодом причины
    if (state.detail.get(key)?.passed !== true) state.detail.set(key, { passed: json.passed, reason: json.reason });
    return send(res, 200, { status: 'recorded', repeated });
  });

  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, host, resolve); });
  const actual = server.address().port;
  return {
    url: `http://127.0.0.1:${actual}`,
    port: actual,
    state,
    close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(() => r()); }),
  };
}

// Отдельный запуск: порт даёт система, либо --port
if (import.meta.url === `file:///${process.argv[1]?.replace(/\\/g, '/')}` || process.argv[1]?.endsWith('mock-site.mjs')) {
  const argPort = process.argv.indexOf('--port');
  const ports = argPort > 0 ? [Number(process.argv[argPort + 1])] : [0];
  let started = null;
  for (const p of ports) { try { started = await startMock({ port: p }); break; } catch { /* занят */ } }
  if (!started) { console.error('нет свободного порта'); process.exit(1); }
  console.log(`mock-site слушает ${started.url}`);
}
