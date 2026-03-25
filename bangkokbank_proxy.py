#!/usr/bin/env python3
"""
Bangkok Bank iBanking Proxy für MoneyMoney  –  v6
==================================================
Verwendet curl-cffi's Low-Level Curl-API mit explizitem HTTP/1.1
und Chrome-TLS-Fingerprint um Akamai zu umgehen.

Einmalige Installation:
    pip3 install curl-cffi

Start:
    python3 bangkokbank_proxy.py
Stop:
    CTRL+C
"""

import sys

try:
    import curl_cffi
    from curl_cffi import Curl, CurlOpt
    from curl_cffi import CurlHttpVersion
    print(f"curl-cffi Version: {curl_cffi.__version__}", flush=True)
except ImportError:
    print("FEHLER: pip3 install curl-cffi")
    sys.exit(1)

import http.server, threading, json
from io import BytesIO

PORT   = 8765
TARGET = "https://ibanking.bangkokbank.com"

# Cookie-Datei für Session-Persistenz zwischen Requests
import tempfile, os
COOKIE_FILE = os.path.join(tempfile.gettempdir(), "bbl_session.txt")


def reset_cookies():
    if os.path.exists(COOKIE_FILE):
        os.remove(COOKIE_FILE)


def do_request(method, url, extra_headers=None, body=None):
    """
    Führt einen HTTP-Request via curl-cffi Low-Level API aus.
    - impersonate("chrome124")  → Chrome TLS/JA3-Fingerprint
    - CURLOPT_HTTP_VERSION = CURL_HTTP_VERSION_1_1 → kein HTTP/2
    - CURLOPT_COOKIEFILE / CURLOPT_COOKIEJAR → persistente Cookies
    """
    c = Curl()
    buf_body   = BytesIO()
    buf_header = BytesIO()

    # TLS-Fingerprint: Chrome124
    c.impersonate("chrome124", default_headers=False)

    # HTTP/1.1 erzwingen (CURLOPT_HTTP_VERSION = 84, CURL_HTTP_VERSION_1_1 = 2)
    c.setopt(CurlOpt.HTTP_VERSION, CurlHttpVersion.V1_1)

    # Cookie-Persistenz
    c.setopt(CurlOpt.COOKIEFILE, COOKIE_FILE.encode())
    c.setopt(CurlOpt.COOKIEJAR,  COOKIE_FILE.encode())

    # Redirects folgen
    c.setopt(CurlOpt.FOLLOWLOCATION, 1)
    c.setopt(CurlOpt.MAXREDIRS, 5)

    # Timeout
    c.setopt(CurlOpt.CONNECTTIMEOUT, 15)
    c.setopt(CurlOpt.TIMEOUT, 30)

    # URL
    c.setopt(CurlOpt.URL, url.encode())

    # Headers zusammenbauen
    headers = [
        b"Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        b"Accept-Language: en-US,en;q=0.9",
        b"Cache-Control: no-cache",
        b"Pragma: no-cache",
        b"Upgrade-Insecure-Requests: 1",
        f"User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36".encode(),
    ]
    # Zusätzliche Headers (Referer, Origin, Content-Type etc.)
    if extra_headers:
        skip = {"host","content-length","transfer-encoding","connection",
                "keep-alive","user-agent","accept","accept-language",
                "accept-encoding","cache-control","pragma"}
        for k, v in extra_headers.items():
            if k.lower() not in skip:
                # localhost-Referenzen korrigieren
                if k.lower() in ("referer","origin") and "127.0.0.1" in v:
                    v = v.replace(f"http://127.0.0.1:{PORT}", TARGET)
                headers.append(f"{k}: {v}".encode())
    c.setopt(CurlOpt.HTTPHEADER, headers)

    # POST-Body
    if method == "POST" and body:
        if isinstance(body, str):
            body = body.encode()
        c.setopt(CurlOpt.POST, 1)
        c.setopt(CurlOpt.POSTFIELDS, body)
        c.setopt(CurlOpt.POSTFIELDSIZE, len(body))

    # Response-Body und Headers abfangen
    c.setopt(CurlOpt.WRITEFUNCTION,  lambda d: buf_body.write(d))
    c.setopt(CurlOpt.HEADERFUNCTION, lambda d: buf_header.write(d))

    c.perform()

    status = c.getinfo(CurlOpt.RESPONSE_CODE)   # type: ignore
    c.close()

    # Header parsen
    raw_headers = buf_header.getvalue().decode("utf-8", errors="replace")
    resp_headers = {}
    # Bei Redirects: letzten Header-Block nehmen
    blocks = [b for b in raw_headers.split("\r\n\r\n") if b.strip()]
    if blocks:
        for line in blocks[-1].split("\r\n")[1:]:
            if ":" in line:
                k, _, v = line.partition(":")
                resp_headers[k.strip().lower()] = v.strip()

    return int(status), resp_headers, buf_body.getvalue()


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
        if isinstance(body, str): body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self, method):
        if self.path == "/__status__":
            self._reply(200, "application/json",
                json.dumps({"status": "running", "target": TARGET}))
            return
        if self.path == "/__reset__":
            reset_cookies()
            self._reply(200, "text/plain", "Cookies zurückgesetzt.")
            return
        if self.path == "/__stop__":
            self._reply(200, "text/plain", "Stopping...")
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return

        body = None
        if method == "POST":
            n = int(self.headers.get("Content-Length", 0))
            if n > 0: body = self.rfile.read(n)

        status, resp_h, body_bytes = forward_request(
            method, self.path, dict(self.headers), body)

        self.send_response(status)
        skip_r = {"transfer-encoding","connection","keep-alive","content-encoding"}
        for k, v in resp_h.items():
            if k.lower() not in skip_r:
                try: self.send_header(k, v)
                except: pass
        self.send_header("Content-Length", str(len(body_bytes)))
        self.end_headers()
        self.wfile.write(body_bytes)

    def do_GET(self):  self._handle("GET")
    def do_POST(self): self._handle("POST")
    def do_HEAD(self): self._handle("HEAD")


if __name__ == "__main__":
    reset_cookies()  # frische Session beim Start
    print(f"\nBangkok Bank Proxy v6 (Low-Level Curl API)")
    print(f"Lauscht auf:  http://127.0.0.1:{PORT}/")
    print(f"Ziel:         {TARGET}")
    print( "Beenden:      CTRL+C\n")
    sys.stdout.flush()
    srv = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nProxy beendet.")
