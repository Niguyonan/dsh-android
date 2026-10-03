#!/usr/bin/env node
// guard.mjs — the §7 mitigation for dsh-android.
//
// The harness ships no authentication, binds loopback, and executes shell
// commands — as root, on this deployment. On Android, loopback is NOT an
// app-to-app boundary: any app holding INTERNET can connect to 127.0.0.1. So
// "reachable only on loopback" is not a control at all, and the plan requires
// one that is proven rather than assumed.
//
// This process is that control. It is the only port the app talks to:
//
//   app/WebView -> 127.0.0.1:3081 (here) -> 127.0.0.1:3080 (harness)
//
// Controls, all fail-closed:
//   1. A per-install token, read from a 0600 file that dshd owns. No token
//      file means the guard refuses to start — there is no "auth disabled"
//      mode to accidentally run.
//   2. Host allowlist. Upstream gates /api and upgrades on a loopback-derived
//      host-literal policy, so a co-resident app that sends
//      `Host: 127.0.0.1:3080` satisfies it; the guard's own check is what
//      rejects foreign Host values, and it rewrites Host/Origin to the
//      upstream authority so the upstream policy still passes for us.
//   3. Origin / Sec-Fetch-Site check, so a cross-origin page in another app's
//      WebView cannot use this endpoint even if it learns the port.
//   4. Loopback bind enforced in-process: a non-loopback --listen is a fatal
//      configuration error, not a warning.
//
// It proxies HTTP, streamed responses (SSE — the harness browser half is a
// fetch/SSE client) and WebSocket upgrades, because all three carry the UI.
//
// Zero dependencies: node: built-ins only, so it runs from the glibc rootfs
// with nothing to install. Tests: `node --test "guard/test/*.test.mjs"`.

import { createServer, request as httpRequest } from 'node:http'
import { connect as netConnect, isIP } from 'node:net'
import { readFileSync, realpathSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { timingSafeEqual, randomBytes } from 'node:crypto'

export const GUARD_VERSION = 1
export const DEFAULT_LISTEN = '127.0.0.1:3081'
export const DEFAULT_UPSTREAM = '127.0.0.1:3080'
export const COOKIE_NAME = 'dsh_guard'
export const TOKEN_HEADER = 'x-dsh-token'
export const LOGIN_PATH = '/__guard/login'
export const HEALTH_PATH = '/__guard/health'

const HOP_BY_HOP = new Set([
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
])

const LOOPBACK_HOSTS = new Set(['127.0.0.1', 'localhost', '::1', '[::1]'])

export function isLoopbackHost(host) {
  if (LOOPBACK_HOSTS.has(host)) return true
  if (isIP(host) === 4) return host.startsWith('127.')
  return false
}

// "127.0.0.1:3081" -> { host, port }. Rejects anything not on loopback: this is
// the check that keeps the guard from ever becoming a LAN-exposed root surface.
export function parseListen(spec) {
  const trimmed = String(spec).trim()
  const idx = trimmed.lastIndexOf(':')
  if (idx <= 0) throw new Error(`--listen must be host:port, got ${JSON.stringify(spec)}`)
  const host = trimmed.slice(0, idx).replace(/^\[|\]$/g, '')
  const port = Number(trimmed.slice(idx + 1))
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`--listen port out of range: ${JSON.stringify(spec)}`)
  }
  if (!isLoopbackHost(host)) {
    throw new Error(
      `--listen ${host} refused: the guard only binds loopback ` +
        `(127.0.0.1 or ::1). Binding anything else would expose a root shell ` +
        `to the network; see PORTING-PLAN.md §7.`,
    )
  }
  return { host, port }
}

export function readTokenFile(path) {
  let raw
  try {
    raw = readFileSync(path, 'utf8')
  } catch (err) {
    throw new Error(
      `cannot read token file ${path}: ${err.message}. ` +
        `The guard fails closed rather than run unauthenticated; ` +
        `run \`dshd start\` (or \`dshd token\`) to create it.`,
    )
  }
  const token = raw.trim()
  if (!token) throw new Error(`token file ${path} is empty`)
  return token
}

function safeEqual(a, b) {
  const ba = Buffer.from(String(a))
  const bb = Buffer.from(String(b))
  if (ba.length !== bb.length) return false
  return timingSafeEqual(ba, bb)
}

function parseCookies(header) {
  const out = new Map()
  if (!header) return out
  for (const part of String(header).split(';')) {
    const eq = part.indexOf('=')
    if (eq < 0) continue
    out.set(part.slice(0, eq).trim(), part.slice(eq + 1).trim())
  }
  return out
}

export function pathOf(url) {
  try {
    return new URL(url ?? '/', 'http://127.0.0.1').pathname
  } catch {
    return '/'
  }
}

function queryParam(url, name) {
  try {
    return new URL(url ?? '/', 'http://127.0.0.1').searchParams.get(name) ?? ''
  } catch {
    return ''
  }
}

// Pull the presented token out of the three carriers we accept.
export function extractToken(headers) {
  const cookie = parseCookies(headers.cookie).get(COOKIE_NAME)
  if (cookie) return { token: cookie, via: 'cookie' }
  const auth = headers.authorization
  if (auth && /^Bearer\s+/i.test(auth)) {
    return { token: String(auth).replace(/^Bearer\s+/i, '').trim(), via: 'authorization' }
  }
  const custom = headers[TOKEN_HEADER]
  if (custom) return { token: String(custom).trim(), via: 'header' }
  return { token: '', via: 'none' }
}

export function checkAuth(headers, token) {
  const { token: presented, via } = extractToken(headers)
  if (!presented) return { ok: false, status: 401, reason: 'no token presented', via }
  if (!safeEqual(presented, token)) return { ok: false, status: 401, reason: 'token mismatch', via }
  return { ok: true, via }
}

// Host allowlist plus cross-origin defence.
export function checkHostAndOrigin(headers, config) {
  const host = String(headers.host ?? '')
  if (!host) return { ok: false, status: 403, reason: 'missing Host header' }
  if (!config.allowedHosts.has(host.toLowerCase())) {
    return { ok: false, status: 403, reason: `Host ${host} not allowed` }
  }
  const origin = headers.origin
  if (origin && !config.allowedOrigins.has(String(origin).toLowerCase())) {
    return { ok: false, status: 403, reason: `Origin ${origin} not allowed` }
  }
  // Browsers send this; when present it must not be a cross-site request.
  const site = String(headers['sec-fetch-site'] ?? '').toLowerCase()
  if (site === 'cross-site') {
    return { ok: false, status: 403, reason: 'Sec-Fetch-Site: cross-site' }
  }
  return { ok: true }
}

// Redact anything that could carry the token (cookie, bearer, query param).
export function redact(text, token) {
  let out = String(text)
  if (token) out = out.split(token).join('<redacted>')
  out = out.replace(/(cookie:\s*)[^\r\n]*/i, '$1<redacted>')
  out = out.replace(/(authorization:\s*)[^\r\n]*/i, '$1<redacted>')
  out = out.replace(/([?&](?:token|dsh_token|dsh_guard)=)[^&\s"']*/gi, '$1<redacted>')
  return out
}

function log(config, message) {
  process.stdout.write(`${new Date().toISOString()} guard ${redact(message, config.token)}\n`)
}

function sendPlain(res, status, body, extraHeaders = {}) {
  const payload = Buffer.from(body)
  res.writeHead(status, {
    'content-type': 'text/plain; charset=utf-8',
    'content-length': String(payload.length),
    'cache-control': 'no-store',
    ...extraHeaders,
  })
  res.end(payload)
}

// True when these request headers describe an upgrade. Needed because an
// upgrade is *made* of two hop-by-hop headers: stripping `connection` and
// `upgrade` on the way through turns a WebSocket handshake into an ordinary
// GET, which the harness answers with a plain 200 and no socket.
export function isUpgradeRequest(headers) {
  if (headers.upgrade) return true
  return /\bupgrade\b/i.test(String(headers.connection ?? ''))
}

// Headers for the upstream hop: hop-by-hop removed, Host/Origin rewritten to
// the upstream authority so the harness's own trusted-host policy still passes.
export function upstreamHeaders(headers, config) {
  const keepUpgrade = isUpgradeRequest(headers)
  const out = {}
  for (const [name, value] of Object.entries(headers)) {
    if (name.startsWith(':')) continue
    if (HOP_BY_HOP.has(name)) {
      // Preserve the two that carry an upgrade; drop them otherwise.
      if (keepUpgrade && (name === 'connection' || name === 'upgrade')) out[name] = value
      continue
    }
    out[name] = value
  }
  const authority = `${config.upstream.host}:${config.upstream.port}`
  out.host = authority
  delete out[TOKEN_HEADER]
  // Strip only the guard's own cookie. The harness sets its own cookies (the
  // session id among them) and the browser must still be able to send those.
  if (out.cookie) {
    const kept = []
    for (const part of String(out.cookie).split(';')) {
      const name = part.split('=')[0].trim()
      if (name && name !== COOKIE_NAME) kept.push(part.trim())
    }
    if (kept.length) out.cookie = kept.join('; ')
    else delete out.cookie
  }
  if (out.origin) out.origin = `http://${authority}`
  if (out.referer) out.referer = String(out.referer).replace(/^https?:\/\/[^/]+/, `http://${authority}`)
  return out
}

export function createGuard(options) {
  const token = options.token
  if (!token) throw new Error('createGuard: a token is required (fail closed)')
  const listen = parseListen(options.listen ?? DEFAULT_LISTEN)
  const upstream = parseUpstream(options.upstream ?? DEFAULT_UPSTREAM)
  const port = listen.port
  const allowedHosts = new Set(
    [
      `127.0.0.1:${port}`,
      `localhost:${port}`,
      `[::1]:${port}`,
      ...(options.extraHosts ?? []),
    ].map((h) => h.toLowerCase()),
  )
  const allowedOrigins = new Set(
    [
      `http://127.0.0.1:${port}`,
      `http://localhost:${port}`,
      `http://[::1]:${port}`,
      ...(options.extraOrigins ?? []),
    ].map((o) => o.toLowerCase()),
  )
  const config = { token, listen, upstream, allowedHosts, allowedOrigins }
  const startedAt = Date.now()
  const stats = { requests: 0, rejected: 0, upgrades: 0 }

  // Live upgrade pairs, tracked by hand. This is not bookkeeping nicety: Node
  // hands the socket to the 'upgrade' listener *detached* from the server's
  // connection tracking, so closeAllConnections() skips it and server.close()
  // waits on it forever. Without this set, a client that goes away — a WebView
  // reload, a killed app, a dropped Wi-Fi hop — leaves its upstream socket open
  // for the life of the process, and SIGTERM is answered only by dshd's SIGKILL.
  const upgrades = new Set()

  const server = createServer((req, res) => {
    const began = Date.now()
    stats.requests += 1

    const verdict = authorize(req, config, { isUpgrade: false })
    if (!verdict.ok) {
      stats.rejected += 1
      log(config, `reject ${req.method} ${req.url} (${verdict.reason}) -> ${verdict.status}`)
      sendPlain(res, verdict.status, `${verdict.status} ${verdict.reason}\n`, {
        ...(verdict.status === 401 ? { 'www-authenticate': 'Bearer' } : {}),
      })
      return
    }

    if (handleGuardRoute(req, res, config, stats, startedAt, verdict.via)) return

    const proxied = httpRequest(
      {
        host: upstream.host,
        port: upstream.port,
        method: req.method,
        path: req.url,
        headers: upstreamHeaders(req.headers, config),
      },
      (upRes) => {
        res.writeHead(upRes.statusCode ?? 502, upRes.headers)
        upRes.pipe(res)
      },
    )
    proxied.on('error', (err) => {
      stats.rejected += 1
      log(config, `upstream error for ${req.method} ${req.url}: ${err.message}`)
      if (!res.headersSent) sendPlain(res, 502, '502 upstream unavailable\n')
      else res.destroy()
    })
    // No request timeout: the UI holds long-lived SSE streams open.
    proxied.setTimeout(0)
    req.on('aborted', () => proxied.destroy())
    req.pipe(proxied)
    res.on('close', () => {
      log(config, `${req.method} ${req.url} -> ${res.statusCode} ${Date.now() - began}ms (via ${verdict.via})`)
    })
  })

  // WebSocket / any upgrade: authenticate on the raw headers, then splice the
  // sockets. Node's http.request cannot perform upgrades, so this is a manual
  // request-line rewrite over net.connect.
  server.on('upgrade', (req, socket, head) => {
    stats.requests += 1
    stats.upgrades += 1
    const verdict = authorize(req, config, { isUpgrade: true })
    if (!verdict.ok) {
      stats.rejected += 1
      log(config, `reject upgrade ${req.url} (${verdict.reason}) -> ${verdict.status}`)
      socket.write(
        `HTTP/1.1 ${verdict.status} ${verdict.reason}\r\nconnection: close\r\n` +
          `content-length: 0\r\n\r\n`,
      )
      socket.destroy()
      return
    }
    const upstreamSocket = netConnect(upstream.port, upstream.host, () => {
      const headers = upstreamHeaders(req.headers, config)
      const lines = [`${req.method} ${req.url} HTTP/1.1`]
      for (const [name, value] of Object.entries(headers)) lines.push(`${name}: ${value}`)
      upstreamSocket.write(lines.join('\r\n') + '\r\n\r\n')
      if (head && head.length) upstreamSocket.write(head)
      socket.pipe(upstreamSocket)
      upstreamSocket.pipe(socket)
    })

    const pair = { client: socket, upstream: upstreamSocket }
    upgrades.add(pair)
    // `close` covers a normal teardown; `end` covers a half-close, which for a
    // spliced WebSocket means the peer is finished, and `error` covers a reset.
    // Both ends are watched: a dead client must not strand its upstream socket,
    // and a dead upstream must not strand the client.
    const teardown = () => {
      if (!upgrades.delete(pair)) return
      socket.destroy()
      upstreamSocket.destroy()
    }
    socket.on('close', teardown)
    socket.on('end', teardown)
    socket.on('error', teardown)
    upstreamSocket.on('close', teardown)
    upstreamSocket.on('end', teardown)
    upstreamSocket.on('error', (err) => {
      log(config, `upgrade upstream error for ${req.url}: ${err.message}`)
      teardown()
    })
  })

  // Long-lived work must not be cut off by the default request timeout.
  server.requestTimeout = 0
  server.headersTimeout = 60_000
  server.keepAliveTimeout = 72_000

  return {
    server,
    config,
    stats,
    listen: () =>
      new Promise((resolve, reject) => {
        server.once('error', reject)
        server.listen(port, listen.host, () => resolve(server.address()))
      }),
    close: () =>
      new Promise((resolve) => {
        // Destroy live connections first: the UI holds keep-alive and SSE
        // sockets open, and server.close() alone would never call back, so a
        // SIGTERM would be answered only by dshd's SIGKILL. Upgraded sockets
        // need the explicit sweep below — closeAllConnections() skips them.
        for (const pair of [...upgrades]) {
          upgrades.delete(pair)
          pair.client.destroy()
          pair.upstream.destroy()
        }
        server.closeIdleConnections?.()
        server.closeAllConnections?.()
        server.close(() => resolve())
      }),
  }
}

export function authorize(req, config, { isUpgrade }) {
  const hostVerdict = checkHostAndOrigin(req.headers, config)
  if (!hostVerdict.ok) return { ...hostVerdict, via: 'none' }

  // /__guard/login is where a client that has no cookie yet exchanges a token
  // for one, so the token arrives in the query string. That is the only place a
  // query token is accepted, and it is scoped by path so a query token is not
  // generally usable as a credential.
  if (pathOf(req.url) === LOGIN_PATH) {
    const presented = queryParam(req.url, 'token')
    if (presented && safeEqual(presented, config.token)) return { ok: true, via: 'login-query' }
    return { ok: false, status: 401, reason: 'invalid login token', via: 'none' }
  }

  const authVerdict = checkAuth(req.headers, config.token)
  if (!authVerdict.ok) return authVerdict
  return { ok: true, via: `${isUpgrade ? 'upgrade/' : ''}${authVerdict.via}` }
}

// Guard-owned routes. They are authorized by the caller and never proxied.
function handleGuardRoute(req, res, config, stats, startedAt, via) {
  const pathname = pathOf(req.url)

  if (pathname === HEALTH_PATH) {
    sendPlain(
      res,
      200,
      `${JSON.stringify(
        {
          ok: true,
          version: GUARD_VERSION,
          upstream: `${config.upstream.host}:${config.upstream.port}`,
          uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000),
          requests: stats.requests,
          rejected: stats.rejected,
        },
        null,
        2,
      )}\n`,
      { 'content-type': 'application/json; charset=utf-8' },
    )
    return true
  }

  // Sets the cookie from a token the app already holds, so the app never has to
  // inject a header (EventSource cannot send custom headers) or keep a token in
  // a URL. The token is never logged: `log()` redacts the query and this
  // handler does not echo it.
  if (pathname === LOGIN_PATH) {
    sendPlain(res, 302, 'redirecting\n', {
      location: '/',
      'set-cookie': `${COOKIE_NAME}=${config.token}; Path=/; HttpOnly; SameSite=Strict`,
    })
    log(config, `session cookie issued (via ${via})`)
    return true
  }

  return false
}

function parseUpstream(spec) {
  const trimmed = String(spec).trim().replace(/^https?:\/\//, '').replace(/\/.*$/, '')
  const idx = trimmed.lastIndexOf(':')
  if (idx <= 0) throw new Error(`--upstream must be host:port, got ${JSON.stringify(spec)}`)
  const host = trimmed.slice(0, idx).replace(/^\[|\]$/g, '')
  const port = Number(trimmed.slice(idx + 1))
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`--upstream port out of range: ${JSON.stringify(spec)}`)
  }
  if (!isLoopbackHost(host)) {
    throw new Error(`--upstream ${host} refused: the harness must be on loopback`)
  }
  return { host, port }
}

export function parseArgs(argv) {
  const opts = {
    listen: process.env.DSH_GUARD_LISTEN ?? DEFAULT_LISTEN,
    upstream: process.env.DSH_GUARD_UPSTREAM ?? DEFAULT_UPSTREAM,
    tokenFile: process.env.DSH_GUARD_TOKEN_FILE ?? '',
  }
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]
    const next = () => {
      i += 1
      if (i >= argv.length) throw new Error(`${arg} requires a value`)
      return argv[i]
    }
    switch (arg) {
      case '--listen': opts.listen = next(); break
      case '--upstream': opts.upstream = next(); break
      case '--token-file': opts.tokenFile = next(); break
      case '--help':
      case '-h':
        opts.help = true
        break
      default:
        throw new Error(`unknown argument ${JSON.stringify(arg)}`)
    }
  }
  return opts
}

const USAGE = `guard.mjs ${GUARD_VERSION} — token-auth loopback guard for dsh-android (§7)

usage: guard.mjs --token-file <path> [--listen 127.0.0.1:3081] [--upstream 127.0.0.1:3080]

  --listen     loopback bind address; a non-loopback value is fatal
  --upstream   the harness; loopback only
  --token-file 0600 file holding the shared token (required, fails closed)

Clients authenticate with any of: Cookie ${COOKIE_NAME}=<token>,
Authorization: Bearer <token>, or ${TOKEN_HEADER}: <token>.
GET ${HEALTH_PATH} reports liveness; GET ${LOGIN_PATH}?token=... sets the cookie.
`

async function main(argv) {
  let opts
  try {
    opts = parseArgs(argv)
  } catch (err) {
    process.stderr.write(`${err.message}\n`)
    process.exit(1)
  }
  if (opts.help) {
    process.stdout.write(USAGE)
    process.exit(0)
  }
  if (!opts.tokenFile) {
    process.stderr.write('guard: --token-file is required (there is no unauthenticated mode)\n')
    process.exit(1)
  }
  let guard
  try {
    guard = createGuard({
      listen: opts.listen,
      upstream: opts.upstream,
      token: readTokenFile(opts.tokenFile),
    })
  } catch (err) {
    process.stderr.write(`guard: ${err.message}\n`)
    process.exit(1)
  }

  try {
    await guard.listen()
  } catch (err) {
    process.stderr.write(`guard: cannot listen on ${opts.listen}: ${err.message}\n`)
    process.exit(1)
  }
  log(guard.config, `listening on ${opts.listen} -> ${opts.upstream} (token file ${opts.tokenFile})`)

  const shutdown = (signal) => {
    log(guard.config, `received ${signal}, shutting down`)
    const timer = setTimeout(() => process.exit(1), 5000)
    timer.unref?.()
    guard.close().then(() => process.exit(0))
  }
  process.on('SIGTERM', () => shutdown('SIGTERM'))
  process.on('SIGINT', () => shutdown('SIGINT'))
}

// Only run when executed, not when imported by the tests.
//
// Both sides are realpath'd. Node resolves symlinks when it loads a module, so
// import.meta.url is already canonical, while process.argv[1] is whatever the
// caller typed. Comparing them raw means that under any symlinked path — /tmp
// on macOS, a symlinked /data/local, an install reached through a link — the
// two differ, main() never runs, and the guard exits 0 with an empty log and no
// listening port. A silent success that is really a failure is the worst shape
// this can fail in, so the check is on the resolved path.
function invokedAsScript() {
  const entry = process.argv[1]
  if (!entry) return false
  try {
    return realpathSync(entry) === realpathSync(fileURLToPath(import.meta.url))
  } catch {
    return false
  }
}

if (invokedAsScript()) {
  main(process.argv.slice(2)).catch((err) => {
    process.stderr.write(`guard: ${err?.stack ?? err}\n`)
    process.exit(1)
  })
}

export { randomBytes }
