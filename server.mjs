import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import pty from 'node-pty';

const require = createRequire(import.meta.url);
const appDir = path.dirname(fileURLToPath(import.meta.url));
const xtermDir = path.dirname(require.resolve('@xterm/xterm/package.json'));
const fitDir = path.dirname(require.resolve('@xterm/addon-fit/package.json'));
const clipboardDir = path.dirname(require.resolve('@xterm/addon-clipboard/package.json'));

const PORT = Number(process.env.PORT) || 8080;
const WORKDIR = process.env.OPENCODE_CWD || '/workspace';
const AGENT_NAME = process.env.AGENT_NAME || 'agent';

const INDEX_PATH = path.join(appDir, 'index.html');
const STATIC = {
  '/xterm.js': { file: path.join(xtermDir, 'lib/xterm.js'), type: 'application/javascript; charset=utf-8' },
  '/xterm.css': { file: path.join(xtermDir, 'css/xterm.css'), type: 'text/css; charset=utf-8' },
  '/addon-fit.js': { file: path.join(fitDir, 'lib/addon-fit.js'), type: 'application/javascript; charset=utf-8' },
  '/addon-clipboard.js': { file: path.join(clipboardDir, 'lib/addon-clipboard.js'), type: 'application/javascript; charset=utf-8' },
};

// Templated once at startup. AGENT_NAME is the operator-injected agent name —
// RFC 1123 in practice (lowercase alphanumeric + hyphens), but we still HTML-escape
// it as defense-in-depth in case the constraint ever loosens.
const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
const htmlEscape = (s) => s.replace(/[&<>"']/g, (c) => ESC[c]);
const INDEX_HTML = fs.readFileSync(INDEX_PATH, 'utf8')
  .replaceAll('__AGENT_NAME__', htmlEscape(AGENT_NAME));

const server = http.createServer((req, res) => {
  if (req.url === '/') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }).end(INDEX_HTML);
    return;
  }
  const entry = STATIC[req.url];
  if (!entry) {
    res.writeHead(404, { 'content-type': 'text/plain' }).end('not found');
    return;
  }
  fs.readFile(entry.file, (err, buf) => {
    if (err) {
      console.error(`failed to read ${entry.file}: ${err.message}`);
      res.writeHead(500, { 'content-type': 'text/plain' }).end('internal error');
      return;
    }
    res.writeHead(200, { 'content-type': entry.type, 'cache-control': 'no-store' }).end(buf);
  });
});

const wss = new WebSocketServer({ server, path: '/ws' });

wss.on('connection', (ws, req) => {
  const remote = req.socket.remoteAddress;
  console.log(`ws connect from ${remote}`);

  // Spawn `tmux new-session -A` so reconnects attach to the existing session
  // instead of starting a fresh opencode. The pty/WS pair is the tmux client;
  // when the WS closes we kill the client only — the session (and the opencode
  // TUI inside it) keeps running, ready for the next reconnect. When opencode
  // itself exits, tmux's default `remain-on-exit off` destroys the session, so
  // the next reconnect starts a fresh opencode.
  //
  // `launch-opencode` is a thin wrapper that runs the opencode TUI bound to
  // /workspace; the agent's instructions, model, provider, and MCP servers all
  // come from $OPENCODE_CONFIG_DIR/opencode.jsonc (written by the init container).
  const sessionName = process.env.TMUX_SESSION || 'opencode';
  const term = pty.spawn('tmux', [
    '-f', '/etc/tmux.conf',
    'new-session', '-A',
    '-s', sessionName,
    'launch-opencode',
  ], {
    name: 'xterm-256color',
    cols: 80,
    rows: 24,
    cwd: WORKDIR,
    env: process.env,
  });

  term.onData((data) => {
    if (ws.readyState === ws.OPEN) ws.send(data);
  });
  term.onExit(({ exitCode, signal }) => {
    console.log(`pty exit code=${exitCode} signal=${signal}`);
    if (ws.readyState === ws.OPEN) ws.close();
  });

  ws.on('message', (data, isBinary) => {
    if (isBinary) {
      term.write(data);
      return;
    }
    const text = data.toString();
    if (text.length > 0 && text.charCodeAt(0) === 0x7b /* { */) {
      try {
        const msg = JSON.parse(text);
        if (msg && msg.type === 'resize' &&
            Number.isFinite(msg.cols) && Number.isFinite(msg.rows)) {
          term.resize(msg.cols, msg.rows);
          return;
        }
      } catch {
        // Not JSON — treat as raw input below.
      }
    }
    term.write(text);
  });

  ws.on('close', () => {
    console.log(`ws close from ${remote}`);
    try { term.kill(); } catch { /* already exited */ }
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`opencode-adapter listening on :${PORT} (cwd=${WORKDIR})`);
});
