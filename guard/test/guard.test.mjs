// Tests for the §7 guard. Run with: node --test "guard/test/*.test.mjs"
//
// These prove the controls rather than assert them, which is the point §7 makes:
// "a control that is assumed rather than tested is not a control". The one
// thing this file cannot prove is that a second app on the device is blocked —
// that needs the device, and docs/security.md holds the procedure.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { createHash } from 'node:crypto'
import { connect as netConnect } from 'node:net'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, symlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  createGuard,
  parseListen,
  parseArgs,
  checkAuth,
  checkHostAndOrigin,
  extractToken,
  redact,
  upstreamHeaders,
  isUpgradeRequest,
  pathOf,
  readTokenFile,
  isLoopbackHost,
  COOKIE_NAME,
  TOKEN_HEADER,
} from '../guard.mjs'

const TOKEN = 'test-token-0123456789abcdef'
const UPSTREAM_TOKEN = 'launch-token-abcdef0123456789'
const HARNESS_COOKIE = 'dsh-auth-test'

// --- unit: bind enforcement -------------------------------------------------

test('parseListen refuses every non-loopback bind', () => {
  for (const bad of ['0.0.0.0:3081', '192.168.1.5:3081', '10.0.0.1:3081', '::', '[::]:3081', 'example.com:3081']) {
    assert.throws(() => parseListen(bad), /refused|out of range|must be host:port/, `expected ${bad} to be refused`)
  }
})

test('parseListen accepts loopback and rejects malformed specs', () => {
  assert.deepEqual(parseListen('127.0.0.1:3081'), { host: '127.0.0.1', port: 3081 })
  assert.deepEqual(parseListen('[::1]:3081'), { host: '::1', port: 3081 })
  assert.deepEqual(parseListen('localhost:9'), { host: 'localhost', port: 9 })
  assert.throws(() => parseListen('3081'), /host:port/)
  assert.throws(() => parseListen('127.0.0.1:70000'), /out of range/)
  assert.throws(() => parseListen('127.0.0.1:0'), /out of range/)
})

test('isLoopbackHost classifies 127/8 as loopback', () => {
  assert.equal(isLoopbackHost('127.0.0.1'), true)
  assert.equal(isLoopbackHost('127.5.5.5'), true)
  assert.equal(isLoopbackHost('::1'), true)
  assert.equal(isLoopbackHost('128.0.0.1'), false)
  assert.equal(isLoopbackHost('0.0.0.0'), false)
})

test('createGuard fails closed without a token', () => {
  assert.throws(() => createGuard({ token: '' }), /token is required/)
})

test('readTokenFile rejects a missing or empty token file', () => {
  assert.throws(() => readTokenFile('/nonexistent/guard.token'), /cannot read token file/)
})

test('parseArgs requires --token-file and rejects unknown flags', () => {
  assert.deepEqual(parseArgs([]).tokenFile, '')
  assert.equal(parseArgs(['--token-file', 'x', '--listen', '127.0.0.1:1']).tokenFile, 'x')
  assert.throws(() => parseArgs(['--nope']), /unknown argument/)
  assert.throws(() => parseArgs(['--listen']), /requires a value/)
})

// --- unit: token carriers and host policy -----------------------------------

test('extractToken reads cookie, bearer, and custom header', () => {
  assert.deepEqual(extractToken({ cookie: `${COOKIE_NAME}=abc; other=1` }), { token: 'abc', via: 'cookie' })
  assert.deepEqual(extractToken({ authorization: 'Bearer abc' }), { token: 'abc', via: 'authorization' })
  assert.deepEqual(extractToken({ [TOKEN_HEADER]: 'abc' }), { token: 'abc', via: 'header' })
  assert.deepEqual(extractToken({}), { token: '', via: 'none' })
})

test('checkAuth compares in constant time and rejects wrong/absent tokens', () => {
  assert.equal(checkAuth({ cookie: `${COOKIE_NAME}=${TOKEN}` }, TOKEN).ok, true)
  assert.equal(checkAuth({ cookie: `${COOKIE_NAME}=wrong` }, TOKEN).status, 401)
  assert.equal(checkAuth({ cookie: `${COOKIE_NAME}=wrong-token-same-length` }, TOKEN).status, 401)
  assert.equal(checkAuth({}, TOKEN).status, 401)
})

test('checkHostAndOrigin rejects foreign Host and cross-origin requests', () => {
  const config = {
    allowedHosts: new Set(['127.0.0.1:3081', 'localhost:3081']),
    allowedOrigins: new Set(['http://127.0.0.1:3081']),
  }
  assert.equal(checkHostAndOrigin({ host: '127.0.0.1:3081' }, config).ok, true)
  assert.equal(checkHostAndOrigin({}, config).status, 403)
  assert.equal(checkHostAndOrigin({ host: 'evil.example' }, config).status, 403)
  assert.equal(checkHostAndOrigin({ host: '127.0.0.1:3081', origin: 'http://evil.example' }, config).status, 403)
  assert.equal(checkHostAndOrigin({ host: '127.0.0.1:3081', 'sec-fetch-site': 'cross-site' }, config).status, 403)
  assert.equal(
    checkHostAndOrigin({ host: '127.0.0.1:3081', origin: 'http://127.0.0.1:3081', 'sec-fetch-site': 'same-origin' }, config).ok,
    true,
  )
})

test('pathOf strips the query and tolerates junk', () => {
  assert.equal(pathOf('/api/x?token=abc'), '/api/x')
  assert.equal(pathOf('/__guard/login?token=abc'), '/__guard/login')
  assert.equal(pathOf(undefined), '/')
})

test('redact removes the token from any log line', () => {
  const line = `GET /?token=${TOKEN} cookie: ${COOKIE_NAME}=${TOKEN} authorization: Bearer ${TOKEN}`
  const out = redact(line, TOKEN)
  assert.equal(out.includes(TOKEN), false)
  assert.match(out, /<redacted>/)
})

test('isUpgradeRequest detects both halves of a handshake', () => {
  assert.equal(isUpgradeRequest({ upgrade: 'websocket', connection: 'Upgrade' }), true)
  assert.equal(isUpgradeRequest({ connection: 'keep-alive, Upgrade' }), true)
  assert.equal(isUpgradeRequest({ connection: 'keep-alive' }), false)
  assert.equal(isUpgradeRequest({}), false)
})

test('upstreamHeaders keeps an upgrade intact and strips hop-by-hop otherwise', () => {
  const config = { upstream: { host: '127.0.0.1', port: 3080 } }

  // The regression this guards: stripping `connection`/`upgrade` on the way
  // through turned a WebSocket handshake into a plain GET, so the harness
  // answered 200 with no socket and every live stream in the UI stopped working.
  const upgrade = upstreamHeaders(
    { host: '127.0.0.1:3081', upgrade: 'websocket', connection: 'Upgrade' },
    config,
  )
  assert.equal(upgrade.upgrade, 'websocket')
  assert.equal(upgrade.connection, 'Upgrade')

  const plain = upstreamHeaders(
    {
      host: '127.0.0.1:3081',
      origin: 'http://127.0.0.1:3081',
      cookie: `${COOKIE_NAME}=${TOKEN}; dsh_session=keepme`,
      [TOKEN_HEADER]: TOKEN,
      referer: 'http://127.0.0.1:3081/chat?x=1',
      connection: 'keep-alive',
      'content-type': 'application/json',
    },
    config,
  )
  assert.equal(plain.host, '127.0.0.1:3080')
  assert.equal(plain.origin, 'http://127.0.0.1:3080')
  assert.equal(plain.referer, 'http://127.0.0.1:3080/chat?x=1')
  assert.equal(plain.cookie, 'dsh_session=keepme')
  assert.equal(plain[TOKEN_HEADER], undefined)
  assert.equal(plain.connection, undefined)
  assert.equal(plain.upgrade, undefined)
  assert.equal(plain['content-type'], 'application/json')
})

// --- integration harness ----------------------------------------------------

// A stand-in harness: echoes the headers it received, and answers upgrades with
// a real 101 handshake so the guard's socket splice can be exercised. Upgrade
// sockets are tracked so a test can watch which side of a splice lets go.
function startUpstream({ authToken = '' } = {}) {
  return new Promise((resolve) => {
    const sockets = new Set()
    const paths = []
    const server = createServer((req, res) => {
      paths.push(req.url ?? '')
      // With authToken set the stand-in behaves like the real harness, measured
      // against @deepseek-ai/dsh 0.2.0-rc.2: `/` answers 401 unless the request
      // carries the launch token printed at startup (which mints a signed
      // cookie) or that cookie already. The guard has to chain this, and a
      // version bump could change it — so it belongs in a test.
      if (authToken) {
        const url = new URL(req.url ?? '/', 'http://127.0.0.1')
        const presented = url.searchParams.getAll('token')
        const cookie = String(req.headers.cookie ?? '')
        if (
          req.method === 'GET' &&
          url.pathname === '/' &&
          presented.length === 1 &&
          presented[0] === authToken
        ) {
          res.writeHead(303, {
            'cache-control': 'no-store',
            location: './',
            'set-cookie': `${HARNESS_COOKIE}=v1.payload.signature; Max-Age=2592000; Path=/; HttpOnly; SameSite=Strict`,
          })
          res.end()
          return
        }
        if (req.method === 'GET' && url.pathname === '/' && cookie.includes(`${HARNESS_COOKIE}=`)) {
          res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
          res.end('<!doctype html><title>harness</title>')
          return
        }
        res.writeHead(401, { 'content-type': 'text/plain; charset=utf-8' })
        res.end('dsh web authentication required; reopen the URL printed by dsh web.\n')
        return
      }
      const body = JSON.stringify({ headers: req.headers, url: req.url, method: req.method })
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(body)
    })
    server.on('upgrade', (req, socket) => {
      sockets.add(socket)
      socket.on('close', () => sockets.delete(socket))
      // HTTP server sockets come with allowHalfOpen: true, so on FIN the socket
      // goes non-readable but stays writable and never closes. A real WebSocket
      // server (`ws`, which the harness uses) closes when the peer goes away;
      // this stand-in has to do the same, or a leak test would be measuring the
      // stand-in's policy rather than the guard's.
      socket.on('end', () => socket.end())
      const accept = createHash('sha1')
        .update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
        .digest('base64')
      socket.write(
        'HTTP/1.1 101 Switching Protocols\r\n' +
          'upgrade: websocket\r\nconnection: Upgrade\r\n' +
          `sec-websocket-accept: ${accept}\r\n\r\n`,
      )
      // Echo raw bytes back so the test can prove the pipe is bidirectional.
      socket.on('data', (chunk) => socket.write(chunk))
    })
    server.listen(0, '127.0.0.1', () => resolve({ server, port: server.address().port, sockets, paths }))
  })
}

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// Poll rather than sleep-and-hope: teardown is asynchronous on both ends.
async function waitFor(predicate, timeout = 3000, step = 10) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    if (predicate()) return true
    await delay(step)
  }
  return predicate()
}

const withTimeout = (promise, ms, fallback = 'timeout') =>
  Promise.race([promise, delay(ms).then(() => fallback)])

async function freePort() {
  return new Promise((resolve) => {
    const s = createServer()
    s.listen(0, '127.0.0.1', () => {
      const port = s.address().port
      s.close(() => resolve(port))
    })
  })
}

async function startGuard({ token = TOKEN, upstreamToken = '', upstreamOptions = {} } = {}) {
  const upstream = await startUpstream(upstreamOptions)
  const port = await freePort()
  const guard = createGuard({
    listen: `127.0.0.1:${port}`,
    upstream: `127.0.0.1:${upstream.port}`,
    token,
    ...(upstreamToken ? { upstreamToken } : {}),
  })
  await guard.listen()
  const base = `http://127.0.0.1:${port}`
  let closed = false
  return {
    guard,
    port,
    base,
    upstreamPort: upstream.port,
    upstreamSockets: upstream.sockets,
    upstreamPaths: upstream.paths,
    // Idempotent: a test may close explicitly to prove close() terminates, and
    // the t.after hook would otherwise close a second time.
    close: async () => {
      if (closed) return
      closed = true
      await guard.close()
      // The proxy keeps its upstream sockets alive, so the stand-in harness
      // needs the same treatment or its close() never calls back either.
      upstream.server.closeAllConnections?.()
      for (const socket of upstream.sockets) socket.destroy()
      await new Promise((r) => upstream.server.close(r))
    },
  }
}

// Raw request helper: `fetch` refuses to set Host (it is a forbidden header),
// so proving the Host allowlist is wired into the request path needs a socket.
// Resolves with whatever arrived once the response head is complete, or when the
// peer closes — a refusal can arrive either way.
function rawRequest({ port, path = '/', method = 'GET', headers = {}, timeout = 5000 }) {
  return new Promise((resolve) => {
    let buf = Buffer.alloc(0)
    let settled = false
    const finish = () => {
      if (settled) return
      settled = true
      resolve(buf.toString())
    }
    const socket = netConnect(port, '127.0.0.1', () => {
      socket.write(
        [`${method} ${path} HTTP/1.1`, ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`), '', ''].join('\r\n'),
      )
    })
    socket.on('data', (chunk) => {
      buf = Buffer.concat([buf, chunk])
      const idx = buf.indexOf('\r\n\r\n')
      if (idx < 0) return
      const head = buf.subarray(0, idx).toString()
      const len = /content-length: (\d+)/i.exec(head)
      if (!len) socket.destroy()
      else if (buf.length - (idx + 4) >= Number(len[1])) socket.destroy()
    })
    socket.on('error', finish)
    socket.on('close', finish)
    socket.setTimeout(timeout, () => {
      socket.destroy()
      finish()
    })
  })
}

// Raw WebSocket handshake. Resolves once the head is complete, whether the guard
// spliced the socket (101) or refused it (401/403); with a payload it also
// proves the spliced pipe carries data both ways.
function rawUpgrade({ port, path, headers = {}, payload = null, timeout = 5000 }) {
  return new Promise((resolve) => {
    let buf = Buffer.alloc(0)
    let sentPayload = false
    let settled = false
    const finish = (extra = {}) => {
      if (settled) return
      settled = true
      const headerEnd = buf.indexOf('\r\n\r\n')
      const head = headerEnd < 0 ? buf.toString() : buf.subarray(0, headerEnd).toString()
      resolve({ head, statusLine: head.split('\r\n')[0], ...extra })
    }
    const socket = netConnect(port, '127.0.0.1', () => {
      socket.write(
        [
          `GET ${path} HTTP/1.1`,
          `host: 127.0.0.1:${port}`,
          'upgrade: websocket',
          'connection: Upgrade',
          'sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==',
          'sec-websocket-version: 13',
          ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`),
          '',
          '',
        ].join('\r\n'),
      )
    })
    socket.on('data', (chunk) => {
      buf = Buffer.concat([buf, chunk])
      const headerEnd = buf.indexOf('\r\n\r\n')
      if (headerEnd < 0) return
      const head = buf.subarray(0, headerEnd).toString()
      if (!/^HTTP\/1\.1 101/.test(head)) {
        socket.destroy()
        finish()
        return
      }
      if (payload && !sentPayload) {
        sentPayload = true
        socket.write(payload)
        return
      }
      if (payload && buf.includes(payload, headerEnd)) {
        socket.destroy()
        finish({ echoed: true })
      }
    })
    socket.on('error', () => finish())
    socket.on('close', () => finish())
    socket.setTimeout(timeout, () => {
      socket.destroy()
      finish()
    })
  })
}

// Opens an upgrade and hands the live socket back, so a test can decide which
// side disappears and then watch whether the other side follows it down.
function openUpgrade({ port, path = '/api/stream', headers = {}, timeout = 5000 }) {
  return new Promise((resolve) => {
    let buf = Buffer.alloc(0)
    let settled = false
    const socket = netConnect(port, '127.0.0.1', () => {
      socket.write(
        [
          `GET ${path} HTTP/1.1`,
          `host: 127.0.0.1:${port}`,
          'upgrade: websocket',
          'connection: Upgrade',
          'sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==',
          'sec-websocket-version: 13',
          ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`),
          '',
          '',
        ].join('\r\n'),
      )
    })
    const finish = (statusLine) => {
      if (settled) return
      settled = true
      socket.off('data', onData)
      resolve({ socket, statusLine })
    }
    const onData = (chunk) => {
      buf = Buffer.concat([buf, chunk])
      const headerEnd = buf.indexOf('\r\n\r\n')
      if (headerEnd < 0) return
      finish(buf.subarray(0, headerEnd).toString().split('\r\n')[0])
    }
    socket.on('data', onData)
    socket.on('error', () => finish('ERROR'))
    socket.setTimeout(timeout, () => finish('TIMEOUT'))
  })
}

// --- integration: authentication --------------------------------------------

test('guard rejects requests without a token and never reaches upstream', async (t) => {
  const g = await startGuard()
  t.after(g.close)

  const res = await fetch(`${g.base}/api/whatever`, { headers: { host: `127.0.0.1:${g.port}` } })
  assert.equal(res.status, 401)
  assert.equal(res.headers.get('www-authenticate'), 'Bearer')
})

test('guard accepts cookie, bearer, and custom-header tokens', async (t) => {
  const g = await startGuard()
  t.after(g.close)

  const withCookie = await fetch(`${g.base}/api/x`, {
    headers: { host: `127.0.0.1:${g.port}`, cookie: `${COOKIE_NAME}=${TOKEN}` },
  })
  assert.equal(withCookie.status, 200)

  const withBearer = await fetch(`${g.base}/api/x`, {
    headers: { host: `127.0.0.1:${g.port}`, authorization: `Bearer ${TOKEN}` },
  })
  assert.equal(withBearer.status, 200)

  const withHeader = await fetch(`${g.base}/api/x`, {
    headers: { host: `127.0.0.1:${g.port}`, [TOKEN_HEADER]: TOKEN },
  })
  assert.equal(withHeader.status, 200)

  const wrong = await fetch(`${g.base}/api/x`, {
    headers: { host: `127.0.0.1:${g.port}`, cookie: `${COOKIE_NAME}=nope` },
  })
  assert.equal(wrong.status, 401)
})

test('guard rewrites Host/Origin for upstream and strips its own cookie', async (t) => {
  const g = await startGuard()
  t.after(g.close)

  const res = await fetch(`${g.base}/api/echo`, {
    headers: {
      host: `127.0.0.1:${g.port}`,
      origin: `http://127.0.0.1:${g.port}`,
      cookie: `${COOKIE_NAME}=${TOKEN}; dsh_session=keepme`,
      [TOKEN_HEADER]: TOKEN,
    },
  })
  assert.equal(res.status, 200)
  const echo = await res.json()
  assert.equal(echo.headers.host, `127.0.0.1:${g.upstreamPort}`)
  assert.equal(echo.headers.origin, `http://127.0.0.1:${g.upstreamPort}`)
  assert.equal(echo.headers.cookie, 'dsh_session=keepme')
  assert.equal(echo.headers[TOKEN_HEADER], undefined)
})

test('a foreign Host header is refused even with a valid token', async (t) => {
  const g = await startGuard()
  t.after(g.close)

  const response = await rawRequest({
    port: g.port,
    path: '/api/x',
    headers: { host: 'evil.example', cookie: `${COOKIE_NAME}=${TOKEN}` },
  })
  assert.match(response, /^HTTP\/1\.1 403/)
})

test('health requires a token; login exchanges a query token for a cookie', async (t) => {
  const g = await startGuard()
  t.after(g.close)

  const unauth = await fetch(`${g.base}/__guard/health`, { headers: { host: `127.0.0.1:${g.port}` } })
  assert.equal(unauth.status, 401)

  const health = await fetch(`${g.base}/__guard/health`, {
    headers: { host: `127.0.0.1:${g.port}`, cookie: `${COOKIE_NAME}=${TOKEN}` },
  })
  assert.equal(health.status, 200)
  const body = await health.json()
  assert.equal(body.ok, true)
  assert.equal(body.upstream, `127.0.0.1:${g.upstreamPort}`)

  // The regression this guards: the auth gate used to run before the login
  // route, so a client with no cookie yet could never obtain one.
  //
  // This guard has no upstream token file, so the login is answered 502 by
  // design: issuing a guard cookie alone would be a login that reports success
  // while the UI behind it answers "dsh web authentication required". The
  // two-cookie success path is covered by the bootstrap tests at the end.
  const login = await fetch(`${g.base}/__guard/login?token=${TOKEN}`, {
    headers: { host: `127.0.0.1:${g.port}` },
    redirect: 'manual',
  })
  assert.equal(login.status, 502, 'a login with no harness bootstrap available must fail closed')
  assert.equal(login.headers.getSetCookie().length, 0, 'no cookie may be issued when the bootstrap failed')

  const badLogin = await fetch(`${g.base}/__guard/login?token=wrong`, {
    headers: { host: `127.0.0.1:${g.port}` },
    redirect: 'manual',
  })
  assert.equal(badLogin.status, 401)
})

test('a query token is not a general credential', async (t) => {
  const g = await startGuard()
  t.after(g.close)
  const res = await fetch(`${g.base}/api/x?token=${TOKEN}`, { headers: { host: `127.0.0.1:${g.port}` } })
  assert.equal(res.status, 401)
})

test('the token never appears in the guard log', async (t) => {
  const g = await startGuard()
  t.after(g.close)

  const chunks = []
  const original = process.stdout.write.bind(process.stdout)
  process.stdout.write = (chunk, ...rest) => {
    chunks.push(String(chunk))
    return original(chunk, ...rest)
  }
  try {
    await fetch(`${g.base}/api/leak?token=${TOKEN}`, {
      headers: { host: `127.0.0.1:${g.port}`, cookie: `${COOKIE_NAME}=${TOKEN}`, authorization: `Bearer ${TOKEN}` },
    })
    await fetch(`${g.base}/api/bad?token=${TOKEN}`, {
      headers: { host: `127.0.0.1:${g.port}`, cookie: `${COOKIE_NAME}=wrong` },
    })
  } finally {
    process.stdout.write = original
  }
  const logged = chunks.join('')
  assert.ok(logged.includes('guard'), 'expected the guard to log something')
  assert.equal(logged.includes(TOKEN), false, `token leaked into logs:\n${logged}`)
})

// --- integration: websockets ------------------------------------------------

test('a WebSocket upgrade without a token is refused', async (t) => {
  const g = await startGuard()
  t.after(g.close)
  const out = await rawUpgrade({ port: g.port, path: '/api/stream' })
  assert.match(out.statusLine, /^HTTP\/1\.1 401/)
})

test('an authenticated upgrade is spliced and echoes both ways', async (t) => {
  const g = await startGuard()
  t.after(g.close)
  const out = await rawUpgrade({
    port: g.port,
    path: '/api/stream',
    headers: { cookie: `${COOKIE_NAME}=${TOKEN}`, origin: `http://127.0.0.1:${g.port}` },
    payload: Buffer.from('guard-splice-proof'),
  })
  assert.match(out.statusLine, /^HTTP\/1\.1 101/)
  assert.match(out.head, /sec-websocket-accept:/i)
  assert.equal(out.echoed, true)
})

test('a cross-origin upgrade is refused', async (t) => {
  const g = await startGuard()
  t.after(g.close)
  const out = await rawUpgrade({
    port: g.port,
    path: '/api/stream',
    headers: { cookie: `${COOKIE_NAME}=${TOKEN}`, origin: 'http://evil.example' },
  })
  assert.match(out.statusLine, /^HTTP\/1\.1 403/)
})

// --- integration: upgrade teardown ------------------------------------------
//
// Node hands an upgraded socket to the 'upgrade' listener detached from the
// server's connection tracking, so closeAllConnections() skips it and
// server.close() waits on it forever. These three tests are the regression:
// before the guard tracked its pairs, the first one hung the whole suite.

test('a client that goes away does not strand its upstream socket', async (t) => {
  const g = await startGuard()
  t.after(g.close)

  const { socket, statusLine } = await openUpgrade({
    port: g.port,
    headers: { cookie: `${COOKIE_NAME}=${TOKEN}` },
  })
  assert.match(statusLine, /^HTTP\/1\.1 101/)
  assert.equal(await waitFor(() => g.upstreamSockets.size === 1), true, 'expected the splice to reach upstream')
  const [upstreamSocket] = g.upstreamSockets
  // The direct observable of the guard doing its job: the harness side of the
  // splice receives FIN. Without it the pair sits half-open for the life of the
  // process, and every WebView reload adds one.
  const finished = new Promise((resolve) => upstreamSocket.on('end', () => resolve(true)))

  // Exactly what a WebView reload, a killed app, or a dropped Wi-Fi hop does.
  socket.destroy()

  assert.equal(await withTimeout(finished, 3000, false), true, 'the guard left its upstream socket open')
  assert.equal(
    await waitFor(() => g.upstreamSockets.size === 0),
    true,
    'upstream socket outlived the client that opened it',
  )
})

test('when the harness drops the stream, the client socket is closed too', async (t) => {
  const g = await startGuard()
  t.after(g.close)

  const { socket, statusLine } = await openUpgrade({
    port: g.port,
    headers: { cookie: `${COOKIE_NAME}=${TOKEN}` },
  })
  assert.match(statusLine, /^HTTP\/1\.1 101/)
  assert.equal(await waitFor(() => g.upstreamSockets.size === 1), true, 'expected the splice to reach upstream')

  const closed = new Promise((resolve) => socket.on('close', () => resolve(true)))
  for (const upstreamSocket of g.upstreamSockets) upstreamSocket.destroy()
  assert.equal(await withTimeout(closed, 3000, false), true, 'client socket survived the harness closing the stream')
})

test('close() terminates with a live upgrade still open', async (t) => {
  const g = await startGuard()
  t.after(g.close)

  const { statusLine } = await openUpgrade({
    port: g.port,
    headers: { cookie: `${COOKIE_NAME}=${TOKEN}` },
  })
  assert.match(statusLine, /^HTTP\/1\.1 101/)
  assert.equal(await waitFor(() => g.upstreamSockets.size === 1), true, 'expected the splice to reach upstream')

  // This is what dshd's SIGTERM does. If it times out, every stop is a SIGKILL.
  assert.equal(await withTimeout(g.close().then(() => 'closed'), 3000), 'closed')
  assert.equal(await waitFor(() => g.upstreamSockets.size === 0), true, 'close() left an upstream socket behind')
})

// --- integration: construction-time invariants ------------------------------

test('guard bind refusal is enforced at construction, not just by flag parsing', () => {
  assert.throws(() => createGuard({ token: TOKEN, listen: '0.0.0.0:3081' }), /refused/)
  assert.throws(() => createGuard({ token: TOKEN, upstream: '10.0.0.9:3080' }), /must be on loopback/)
})

// --- entry point ------------------------------------------------------------

test('the guard runs when executed through a symlinked path', () => {
  // The regression: comparing process.argv[1] to import.meta.url without
  // resolving symlinks made this exit 0 with an empty stdout — no log, no
  // listening port, and a supervisor restarting it forever. /tmp is a symlink
  // on macOS, so this is not a theoretical path.
  const guardDir = fileURLToPath(new URL('..', import.meta.url))
  const dir = mkdtempSync(join(tmpdir(), 'guard-main-'))
  const link = join(dir, 'linked-guard')
  symlinkSync(guardDir, link, 'dir')
  try {
    const child = spawnSync(process.execPath, [join(link, 'guard.mjs'), '--help'], { encoding: 'utf8' })
    assert.equal(child.status, 0, `expected exit 0, got ${child.status}: ${child.stderr}`)
    assert.match(child.stdout, /usage: guard\.mjs/, 'main() did not run for a symlinked invocation')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

// --- chaining the harness's own auth ----------------------------------------

// The harness authenticates its own UI (measured on @deepseek-ai/dsh
// 0.2.0-rc.2): `/` is 401 until it sees `?token=<launch token>`, which mints a
// signed cookie. A guard that only issues its own cookie therefore produces the
// worst shape available — a healthy-looking auth layer in front of a UI that
// answers "dsh web authentication required" to every request. These tests hold
// both halves of that contract.

test('login issues both cookies so the UI behind the guard is reachable', async (t) => {
  const g = await startGuard({ upstreamToken: UPSTREAM_TOKEN, upstreamOptions: { authToken: UPSTREAM_TOKEN } })
  t.after(g.close)

  const login = await fetch(`${g.base}/?token=${TOKEN}`, { redirect: 'manual' })
  assert.equal(login.status, 303)
  const cookies = login.headers.getSetCookie()
  assert.equal(cookies.length, 2, `expected two cookies, got ${JSON.stringify(cookies)}`)
  assert.ok(
    cookies.some((c) => c.startsWith(`${COOKIE_NAME}=`)),
    'the guard session cookie is missing',
  )
  assert.ok(
    cookies.some((c) => c.startsWith(`${HARNESS_COOKIE}=`)),
    'the harness session cookie is missing, so the UI behind the guard would 401',
  )

  const guardCookie = cookies.find((c) => c.startsWith(`${COOKIE_NAME}=`)).split(';')[0]
  const harnessCookie = cookies.find((c) => c.startsWith(`${HARNESS_COOKIE}=`)).split(';')[0]

  const both = await fetch(`${g.base}/`, { headers: { cookie: `${guardCookie}; ${harnessCookie}` } })
  assert.equal(both.status, 200, 'the index is unreachable even with both cookies')

  // The two layers are independent: the guard's cookie alone must not be enough,
  // because that would mean a bug in the guard silently became the only control.
  const guardOnly = await fetch(`${g.base}/`, { headers: { cookie: guardCookie } })
  assert.equal(guardOnly.status, 401, "the harness's own auth must still apply behind the guard")
})

test('an upstream that does not answer the bootstrap fails the login loudly', async (t) => {
  // The echo stand-in answers 200 to everything, which is what a harness whose
  // launch-token contract changed would look like from here.
  const g = await startGuard({ upstreamToken: UPSTREAM_TOKEN })
  t.after(g.close)

  const login = await fetch(`${g.base}/?token=${TOKEN}`, { redirect: 'manual' })
  assert.equal(login.status, 502, 'a failed bootstrap must not look like a successful login')
  assert.equal(login.headers.getSetCookie().length, 0, 'no session cookie may be issued when the bootstrap failed')
  assert.match(await login.text(), /bootstrap/i)
})

test('a guard with no upstream token refuses to pretend the login worked', async (t) => {
  const g = await startGuard()
  t.after(g.close)

  const login = await fetch(`${g.base}/?token=${TOKEN}`, { redirect: 'manual' })
  assert.equal(login.status, 502)
  assert.equal(login.headers.getSetCookie().length, 0)
  assert.match(await login.text(), /upstream token/)
})

test('health reports whether the harness bootstrap is configured', async (t) => {
  const withToken = await startGuard({ upstreamToken: UPSTREAM_TOKEN, upstreamOptions: { authToken: UPSTREAM_TOKEN } })
  t.after(withToken.close)
  // health is behind the same token check as everything else, so this needs one.
  const configured = await (
    await fetch(`${withToken.base}/__guard/health`, { headers: { cookie: `${COOKIE_NAME}=${TOKEN}` } })
  ).json()
  assert.equal(configured.upstreamBootstrap, 'configured')

  const without = await startGuard()
  t.after(without.close)
  const missing = await (
    await fetch(`${without.base}/__guard/health`, { headers: { cookie: `${COOKIE_NAME}=${TOKEN}` } })
  ).json()
  assert.equal(missing.upstreamBootstrap, 'missing')
})

test('the guard token never reaches the upstream in a query string', async (t) => {
  const g = await startGuard({ upstreamToken: UPSTREAM_TOKEN, upstreamOptions: { authToken: UPSTREAM_TOKEN } })
  t.after(g.close)

  await fetch(`${g.base}/?token=${TOKEN}`, { redirect: 'manual' })
  await fetch(`${g.base}/__guard/login?token=${TOKEN}`, { redirect: 'manual' })

  const leaked = g.upstreamPaths.filter((p) => p.includes(TOKEN))
  assert.deepEqual(leaked, [], 'the guard token was forwarded upstream')
  // ...while the bootstrap itself did happen, with the harness's own token.
  assert.ok(
    g.upstreamPaths.some((p) => p.includes(UPSTREAM_TOKEN)),
    'the guard never replayed the harness bootstrap',
  )
})

test('neither secret is written to the guard log', async (t) => {
  const g = await startGuard({ upstreamToken: UPSTREAM_TOKEN, upstreamOptions: { authToken: UPSTREAM_TOKEN } })
  t.after(g.close)

  const written = []
  const original = process.stdout.write.bind(process.stdout)
  process.stdout.write = (chunk, ...rest) => {
    written.push(String(chunk))
    return original(chunk, ...rest)
  }
  try {
    await fetch(`${g.base}/?token=${TOKEN}`, { redirect: 'manual' })
    await fetch(`${g.base}/__guard/health`)
  } finally {
    process.stdout.write = original
  }

  const text = written.join('')
  assert.ok(text.length > 0, 'the guard logged nothing, so this test proves nothing')
  assert.ok(!text.includes(TOKEN), `the guard token was logged: ${text}`)
  assert.ok(!text.includes(UPSTREAM_TOKEN), `the harness launch token was logged: ${text}`)
})
