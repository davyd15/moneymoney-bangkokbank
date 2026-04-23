#!/usr/bin/env python3
"""
Bangkok Bank iBanking Proxy for MoneyMoney  –  v14
===================================================
Hybrid architecture:
- Login  (POST /SignOn.aspx):  Camoufox headless Firefox (Akamai JS challenge)
                               Fallback: real Google Chrome via CDP
- All subsequent requests:     curl-cffi Chrome124 impersonation with session cookies

Socket Activation (normal operation as LaunchAgent):
  launchd holds port 8765 permanently. The proxy starts only when MoneyMoney
  opens a connection and shuts down after 120s of inactivity.
  launchd restarts it on the next request.

One-time installation:
    pip3 install curl-cffi camoufox --break-system-packages
    python3 -m camoufox fetch

Fallback (if Camoufox is not available):
    pip3 install playwright --break-system-packages
    Google Chrome must be installed: /Applications/Google Chrome.app/

Manual start (for testing):
    python3 bangkokbank_proxy.py
"""

# Suppress Dock icon immediately – before any other imports to avoid a flash
try:
    import AppKit
    AppKit.NSApplication.sharedApplication().setActivationPolicy_(
        AppKit.NSApplicationActivationPolicyProhibited)
except Exception:
    pass

import sys, ssl, shutil, ctypes, socket as _socket
import subprocess, urllib.parse, urllib.request, time

try:
    from curl_cffi import Curl, CurlOpt, CurlHttpVersion, CurlInfo
except ImportError:
    print("FEHLER: curl-cffi fehlt – bitte installieren:", flush=True)
    print("  pip3 install curl-cffi --break-system-packages", flush=True)
    sys.exit(1)

try:
    from camoufox.sync_api import Camoufox as _Camoufox
    from playwright.sync_api import sync_playwright
    PLAYWRIGHT_AVAILABLE = True
    USE_CAMOUFOX = True
    print("Camoufox available – using headless Firefox for login.", flush=True)
except ImportError:
    try:
        from playwright.sync_api import sync_playwright
        PLAYWRIGHT_AVAILABLE = True
        USE_CAMOUFOX = False
        print("Camoufox nicht gefunden – Fallback auf Chrome-CDP.", flush=True)
    except ImportError:
        PLAYWRIGHT_AVAILABLE = False
        USE_CAMOUFOX = False
        print("WARNING: neither camoufox nor playwright installed – login will fail.", flush=True)
        print("  pip3 install camoufox --break-system-packages && python3 -m camoufox fetch", flush=True)

import http.server, socketserver, threading, json, os, tempfile, gzip, zlib
from io import BytesIO

PORT         = 8765
CDP_PORT     = 9223   # Only for Chrome CDP fallback
IDLE_TIMEOUT = 120    # Seconds of inactivity before automatic shutdown

TARGET       = "https://ibanking.bangkokbank.com"
SUMMARY_PATH = "/workspace/16AccountActivity/wsp_AccountSummary_AccountSummaryPage.aspx"
_CERT_DIR    = os.path.expanduser("~/Library/Application Support/BangkokBankProxy")
CERT_FILE    = os.path.join(_CERT_DIR, "bbl_cert.pem")
KEY_FILE     = os.path.join(_CERT_DIR, "bbl_key.pem")
COOKIE_FILE  = os.path.join(tempfile.gettempdir(), "bbl_session.txt")

CHROME_PATHS = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
]

SOCKET_ACTIVATION = False  # Wird in main() gesetzt
_idle_timer       = None
_idle_lock        = threading.Lock()


def find_chrome():
    for p in CHROME_PATHS:
        if os.path.exists(p):
            return p
    return None


def _get_launchd_socket():
    """Acquire the socket pre-bound by launchd (Socket Activation)."""
    try:
        lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        fds  = ctypes.POINTER(ctypes.c_int)()
        cnt  = ctypes.c_size_t(0)
        ret  = lib.launch_activate_socket(
            b'Listeners', ctypes.byref(fds), ctypes.byref(cnt))
        if ret != 0 or cnt.value == 0:
            return None
        sock = _socket.socket(fileno=fds[0])
        lib.free(fds)
        return sock
    except Exception:
        return None


def _reset_idle_timer(server):
    """Reset the inactivity timer. After IDLE_TIMEOUT seconds without a request
    the proxy shuts down; launchd restarts it on the next request."""
    global _idle_timer
    with _idle_lock:
        if _idle_timer:
            _idle_timer.cancel()
        _idle_timer = threading.Timer(
            IDLE_TIMEOUT,
            lambda: threading.Thread(target=server.shutdown, daemon=True).start()
        )
        _idle_timer.daemon = True
        _idle_timer.start()


class _PreBoundHTTPServer(http.server.HTTPServer):
    """HTTPServer that uses a socket already bound by launchd
    (skips bind/listen since launchd has already done that)."""
    def __init__(self, sock, handler):
        socketserver.BaseServer.__init__(self, sock.getsockname(), handler)
        self.socket = sock


def ensure_tls_cert():
    """Create a self-signed certificate for localhost (one-time)."""
    os.makedirs(_CERT_DIR, exist_ok=True)
    if os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE):
        return
    print("Creating self-signed TLS certificate for localhost...", flush=True)
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048",
        "-keyout", KEY_FILE, "-out", CERT_FILE,
        "-days", "3650", "-nodes",
        "-subj", "/CN=127.0.0.1",
        "-addext", "subjectAltName=IP:127.0.0.1,DNS:localhost",
    ], check=True, capture_output=True)
    print(f"Certificate created: {CERT_FILE}", flush=True)
    keychain = os.path.expanduser("~/Library/Keychains/login.keychain-db")
    try:
        subprocess.run([
            "security", "add-trusted-cert", "-r", "trustRoot",
            "-k", keychain, CERT_FILE,
        ], check=True)
        print("Certificate added to Keychain.", flush=True)
    except subprocess.CalledProcessError:
        print(f"\n⚠️  Please trust the certificate manually (one-time):\n"
              f"  security add-trusted-cert -r trustRoot -k {keychain} {CERT_FILE}\n",
              flush=True)


# Headers set automatically by Chrome impersonation – do not pass from the Lua request,
# as curl-cffi sets these itself as part of the TLS fingerprint.
CHROME_DEFAULT_HEADERS = {
    "accept", "accept-encoding", "accept-language", "user-agent",
    "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform",
}

# Hop-by-hop headers that must not be forwarded
SKIP_REQUEST_HEADERS = {
    "host", "content-length", "transfer-encoding", "connection", "keep-alive",
}

# Transfer-Encoding und Content-Length werden nach Dekomprimierung neu gesetzt
SKIP_RESPONSE_HEADERS = {
    "transfer-encoding", "connection", "keep-alive", "content-encoding",
    "content-length",
}


def reset_cookies():
    if os.path.exists(COOKIE_FILE):
        os.remove(COOKIE_FILE)


def _save_cookies(playwright_cookies):
    """Save browser cookies in Netscape format for curl-cffi."""
    with open(COOKIE_FILE, 'w') as f:
        f.write("# Netscape HTTP Cookie File\n")
        for c in playwright_cookies:
            domain  = c.get('domain', '')
            include_subdomain = "TRUE" if domain.startswith('.') else "FALSE"
            if not domain.startswith('.'):
                domain = '.' + domain
            path    = c.get('path', '/')
            secure  = "TRUE" if c.get('secure', False) else "FALSE"
            expires = int(c.get('expires', 0))
            if expires < 0:
                expires = 2147483647
            name    = c.get('name', '')
            value   = c.get('value', '')
            prefix  = "#HttpOnly_" if c.get('httpOnly', False) else ""
            f.write(f"{prefix}{domain}\t{include_subdomain}\t{path}\t{secure}\t{expires}\t{name}\t{value}\n")
    print(f"  {len(playwright_cookies)} Cookies gespeichert", flush=True)


def _login_camoufox(username, password):
    """Login via Camoufox headless Firefox – kein sichtbares Fenster."""
    print(f"  Camoufox: Login als '{username}'...", flush=True)
    with _Camoufox(headless=True) as browser:
        page = browser.new_page()
        page.goto(TARGET + "/SignOn.aspx", wait_until="load", timeout=30000)
        page.fill('input[name="txiID"]', username)
        page.fill('input[name="txiPwd"]', password)
        page.click('input[name="btnLogOn"]')
        page.wait_for_load_state("load", timeout=30000)
        final_url = page.url
        _save_cookies(page.context.cookies())
    return final_url


def _login_chrome_cdp(username, password):
    """Login via real Google Chrome (CDP) – fallback when Camoufox is not available."""
    chrome = find_chrome()
    if not chrome:
        raise RuntimeError("Google Chrome not found at " + str(CHROME_PATHS))

    print(f"  Chrome-CDP: Login als '{username}'...", flush=True)
    user_data_dir = tempfile.mkdtemp(prefix="bbl_chrome_")
    proc = None
    try:
        proc = subprocess.Popen([
            chrome,
            f"--remote-debugging-port={CDP_PORT}",
            f"--user-data-dir={user_data_dir}",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-default-apps",
            "--disable-extensions",
            "--disable-background-networking",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        for _ in range(20):
            time.sleep(0.5)
            try:
                urllib.request.urlopen(f"http://localhost:{CDP_PORT}/json/version", timeout=1)
                break
            except Exception:
                pass

        with sync_playwright() as pw:
            browser = pw.chromium.connect_over_cdp(
                f"http://localhost:{CDP_PORT}", timeout=15000)
            ctx  = browser.contexts[0] if browser.contexts else browser.new_context()
            page = ctx.pages[0]        if ctx.pages        else ctx.new_page()
            page.goto(TARGET + "/SignOn.aspx", wait_until="load", timeout=30000)
            page.fill('input[name="txiID"]', username)
            page.fill('input[name="txiPwd"]', password)
            page.click('input[name="btnLogOn"]')
            # Use "load" instead of "networkidle" – Akamai background scripts prevent
            # networkidle from ever being reached (→ 30s timeout → 502)
            page.wait_for_load_state("load", timeout=30000)
            final_url = page.url
            _save_cookies(ctx.cookies())
            try:
                browser.close()
            except Exception:
                pass
        return final_url
    finally:
        if proc:
            try:
                proc.terminate()
                proc.wait(timeout=5)
            except Exception:
                pass
        shutil.rmtree(user_data_dir, ignore_errors=True)


def browser_login(post_body):
    """
    Login dispatcher: Camoufox headless (preferred) or Chrome CDP (fallback).
    Returns (success: bool, error: str|None).
    On success: cookies saved to COOKIE_FILE.
    """
    if not PLAYWRIGHT_AVAILABLE:
        return False, "camoufox/playwright not installed"

    params   = urllib.parse.parse_qs(
        post_body.decode('utf-8', errors='replace') if post_body else ""
    )
    username = params.get('txiID', [''])[0]
    password = params.get('txiPwd', [''])[0]

    if not username or not password:
        return False, "No credentials in POST body"

    label = "Camoufox" if USE_CAMOUFOX else "Chrome-CDP"
    try:
        final_url = _login_camoufox(username, password) if USE_CAMOUFOX \
                    else _login_chrome_cdp(username, password)

        if "signon" in final_url.lower() or "signin" in final_url.lower():
            print(f"  {label}: Login failed (url={final_url})", flush=True)
            return False, None

        print(f"  {label}: Login OK (url={final_url})", flush=True)
        return True, None

    except Exception as e:
        print(f"  {label}: Exception: {e}", flush=True)
        return False, str(e)


def do_request(method, url, extra_headers=None, body=None):
    """HTTP request via curl-cffi (Chrome124 fingerprint + session cookies)."""
    c = Curl()
    buf_body   = BytesIO()
    buf_header = BytesIO()

    c.impersonate("chrome124")
    c.setopt(CurlOpt.HTTP_VERSION, CurlHttpVersion.V1_1)
    c.setopt(CurlOpt.COOKIEFILE, COOKIE_FILE.encode())
    c.setopt(CurlOpt.COOKIEJAR,  COOKIE_FILE.encode())
    c.setopt(CurlOpt.FOLLOWLOCATION, 1)
    c.setopt(CurlOpt.MAXREDIRS, 5)
    c.setopt(CurlOpt.CONNECTTIMEOUT, 15)
    c.setopt(CurlOpt.TIMEOUT, 30)
    c.setopt(CurlOpt.URL, url.encode())

    extra = []
    if extra_headers:
        for k, v in extra_headers.items():
            kl = k.lower()
            if kl in SKIP_REQUEST_HEADERS or kl in CHROME_DEFAULT_HEADERS:
                continue
            if kl in ("referer", "origin") and "127.0.0.1" in v:
                v = v.replace(f"https://127.0.0.1:{PORT}", TARGET)
                v = v.replace(f"http://127.0.0.1:{PORT}", TARGET)
            extra.append(f"{k}: {v}".encode())
    if extra:
        c.setopt(CurlOpt.HTTPHEADER, extra)

    if method == "POST" and body:
        if isinstance(body, str):
            body = body.encode()
        c.setopt(CurlOpt.POST, 1)
        c.setopt(CurlOpt.POSTFIELDS, body)
        c.setopt(CurlOpt.POSTFIELDSIZE, len(body))

    c.setopt(CurlOpt.WRITEFUNCTION,  lambda d: buf_body.write(d))
    c.setopt(CurlOpt.HEADERFUNCTION, lambda d: buf_header.write(d))

    c.perform()

    status = c.getinfo(CurlInfo.RESPONSE_CODE)
    c.close()

    raw = buf_header.getvalue().decode("utf-8", errors="replace")
    resp_headers = {}
    blocks = [b for b in raw.split("\r\n\r\n") if b.strip()]
    if blocks:
        for line in blocks[-1].split("\r\n")[1:]:
            if ":" in line:
                k, _, v = line.partition(":")
                resp_headers[k.strip().lower()] = v.strip()

    body_bytes = buf_body.getvalue()

    ce = resp_headers.get("content-encoding", "").lower()
    if "gzip" in ce:
        try:
            body_bytes = gzip.decompress(body_bytes)
            del resp_headers["content-encoding"]
        except Exception as e:
            print(f"  gzip decompress failed: {e}", flush=True)
    elif "deflate" in ce:
        try:
            body_bytes = zlib.decompress(body_bytes)
            del resp_headers["content-encoding"]
        except Exception as e:
            print(f"  deflate decompress failed: {e}", flush=True)

    return int(status), resp_headers, body_bytes


def forward_request(method, path, in_headers, body=None):
    url = TARGET + path
    try:
        return do_request(method, url, in_headers, body)
    except Exception as e:
        err = str(e)
        print(f"  FEHLER: {err[:120]}", flush=True)
        return 502, {"content-type": "text/plain"}, f"Fehler: {err}".encode()


class Handler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        st = args[1] if len(args) > 1 else "?"
        print(f"  [{self.command:4}] {self.path[:65]:<65} → {st}", flush=True)

    def _reply(self, status, ctype, body):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self, method):
        # Reset inactivity timer on every request
        if SOCKET_ACTIVATION:
            _reset_idle_timer(self.server)

        if self.path == "/__status__":
            mode = "socket-activation" if SOCKET_ACTIVATION else "manual"
            self._reply(200, "application/json",
                json.dumps({"status": "running", "target": TARGET,
                            "version": 14, "mode": mode}))
            return
        if self.path == "/__reset__":
            reset_cookies()
            self._reply(200, "text/plain; charset=utf-8", "Cookies reset.")
            return
        if self.path == "/__stop__":
            self._reply(200, "text/plain", "Stopping...")
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return

        body = None
        if method == "POST":
            n = int(self.headers.get("Content-Length", 0))
            if n > 0:
                body = self.rfile.read(n)

        # Browser login for POST /SignOn.aspx (Akamai JS challenge requires a real browser)
        if method == "POST" and "/signon" in self.path.lower():
            ok, err = browser_login(body)
            if err:
                self._reply(502, "text/plain", f"Login error: {err}")
                return
            if not ok:
                # Falsche Zugangsdaten → SignOn-URL bleibt (→ LoginFailed im Lua)
                self._reply(200, "text/html",
                            b"<html><body>Login failed</body></html>")
                return
            # Erfolg: redirect zur AccountSummary via Proxy
            loc = f"https://127.0.0.1:{PORT}{SUMMARY_PATH}"
            self.send_response(302)
            self.send_header("Location", loc)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        status, resp_h, body_bytes = forward_request(
            method, self.path, dict(self.headers), body)

        self.send_response(status)
        for k, v in resp_h.items():
            if k.lower() not in SKIP_RESPONSE_HEADERS:
                try:
                    self.send_header(k, v)
                except Exception:
                    pass
        self.send_header("Content-Length", str(len(body_bytes)))
        self.end_headers()
        self.wfile.write(body_bytes)

    def do_GET(self):  self._handle("GET")
    def do_POST(self): self._handle("POST")
    def do_HEAD(self): self._handle("HEAD")


if __name__ == "__main__":
    ensure_tls_cert()
    reset_cookies()

    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(CERT_FILE, KEY_FILE)

    launchd_sock = _get_launchd_socket()
    if launchd_sock:
        SOCKET_ACTIVATION = True
        ssl_sock = tls.wrap_socket(launchd_sock, server_side=True)
        srv = _PreBoundHTTPServer(ssl_sock, Handler)
        mode_info = f"Socket Activation, Idle-Shutdown nach {IDLE_TIMEOUT}s"
        _reset_idle_timer(srv)  # Initialen Timer starten
    else:
        srv = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
        srv.socket = tls.wrap_socket(srv.socket, server_side=True)
        mode_info = "Manueller Start"

    login_method = "Camoufox headless" if USE_CAMOUFOX else "Chrome-CDP"
    print(f"\nBangkok Bank Proxy v14  –  {mode_info}", flush=True)
    print(f"  Login:   {login_method} + curl-cffi chrome124", flush=True)
    print(f"  Proxy:   https://127.0.0.1:{PORT}/  →  {TARGET}", flush=True)
    if not SOCKET_ACTIVATION:
        print("  Beenden: CTRL+C", flush=True)
    print()
    sys.stdout.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nProxy beendet.")
    print("Proxy heruntergefahren.", flush=True)
