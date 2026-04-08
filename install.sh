#!/bin/bash
# Bangkok Bank MoneyMoney Extension – Installer
# https://github.com/davyd15/moneymoney-bangkokbank
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
step()  { echo -e "\n${BLUE}▶ $*${NC}"; }
ok()    { echo -e "  ${GREEN}✓${NC}  $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; }
err()   { echo -e "  ${RED}✗${NC}  $*"; }
die()   { err "$*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXTENSIONS_DIR="$HOME/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_LABEL="com.bangkokbank.proxy"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$PLIST_LABEL.plist"

echo ""
echo -e "${BOLD}Bangkok Bank iBanking – MoneyMoney Extension Installer${NC}"
echo "────────────────────────────────────────────────────────"

# ── 1. Find Python 3 ──────────────────────────────────────────────────────────
step "Finding Python 3..."

PYTHON=""
for candidate in \
    "$(brew --prefix python 2>/dev/null)/bin/python3" \
    /opt/homebrew/bin/python3 \
    /opt/homebrew/opt/python3/bin/python3 \
    /usr/local/bin/python3 \
    /usr/bin/python3; do
    if [ -x "$candidate" ] 2>/dev/null; then
        PYTHON="$candidate"
        break
    fi
done
[ -n "$PYTHON" ] || die "Python 3 not found. Install it: brew install python"

PYTHON_VERSION=$("$PYTHON" --version 2>&1)
# Resolve to real binary path (needed for plist – shims/aliases won't work in launchd)
PYTHON_REAL=$("$PYTHON" -c "import sys; print(sys.executable)")
ok "Using $PYTHON_REAL ($PYTHON_VERSION)"

# ── 2. Install Python packages ────────────────────────────────────────────────
step "Installing Python packages (curl-cffi, camoufox)..."

pip_install() {
    local pkg="$1" import_name="${2:-$1}"
    if "$PYTHON" -c "import $import_name" 2>/dev/null; then
        ok "$pkg already installed"
        return
    fi
    echo "  Installing $pkg..."
    # Try without --break-system-packages first (works in venvs / Homebrew Python)
    if ! "$PYTHON" -m pip install "$pkg" --quiet 2>/dev/null; then
        "$PYTHON" -m pip install "$pkg" --break-system-packages --quiet \
            || die "Failed to install $pkg. Try: pip3 install $pkg --break-system-packages"
    fi
    ok "$pkg installed"
}

pip_install "curl-cffi"    "curl_cffi"
pip_install "camoufox"     "camoufox"

# ── 3. Download Camoufox browser (headless Firefox) ───────────────────────────
step "Downloading Camoufox browser data (headless Firefox for login)..."
echo "  This may take a moment on first install..."
if "$PYTHON" -m camoufox fetch; then
    ok "Camoufox browser ready"
else
    warn "Camoufox fetch failed – will fall back to Chrome CDP for login."
    warn "Make sure Google Chrome is installed: /Applications/Google Chrome.app/"
fi

# ── 4. Copy extension files ───────────────────────────────────────────────────
step "Installing extension files..."

if [ ! -d "$EXTENSIONS_DIR" ]; then
    warn "MoneyMoney Extensions folder not found."
    warn "Expected: $EXTENSIONS_DIR"
    warn "Make sure MoneyMoney is installed and has been launched at least once."
    read -rp "  Create folder and continue? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || die "Aborted."
    mkdir -p "$EXTENSIONS_DIR"
fi

cp "$SCRIPT_DIR/BangkokBank.lua"       "$EXTENSIONS_DIR/"
cp "$SCRIPT_DIR/bangkokbank_proxy.py"  "$EXTENSIONS_DIR/"
ok "BangkokBank.lua   → Extensions folder"
ok "bangkokbank_proxy.py → Extensions folder"

# ── 5. Generate and install LaunchAgent plist ─────────────────────────────────
step "Installing LaunchAgent (proxy auto-start)..."

mkdir -p "$LAUNCH_AGENTS_DIR"
PROXY_SCRIPT="$EXTENSIONS_DIR/bangkokbank_proxy.py"

cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON_REAL}</string>
        <string>${PROXY_SCRIPT}</string>
    </array>

    <!-- Background process – no Dock icon, no menu bar -->
    <key>ProcessType</key>
    <string>Background</string>

    <!-- Socket Activation: launchd holds port 8765 permanently.
         The proxy starts only when MoneyMoney opens a connection
         and shuts down after 120s of inactivity. launchd restarts
         it automatically on the next refresh. -->
    <key>Sockets</key>
    <dict>
        <key>Listeners</key>
        <dict>
            <key>SockServiceName</key>
            <string>8765</string>
            <key>SockNodeName</key>
            <string>127.0.0.1</string>
            <key>SockFamily</key>
            <string>IPv4</string>
        </dict>
    </dict>

    <key>StandardOutPath</key>
    <string>/tmp/bbl_proxy.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/bbl_proxy.log</string>
</dict>
</plist>
PLIST

ok "LaunchAgent plist created"

# Unload any existing version first
launchctl unload "$PLIST_PATH" 2>/dev/null || true

if launchctl load "$PLIST_PATH" 2>/dev/null; then
    ok "LaunchAgent loaded (proxy will start on next MoneyMoney refresh)"
else
    warn "Could not load LaunchAgent automatically."
    warn "Run manually: launchctl load \"$PLIST_PATH\""
fi

# ── 6. TLS certificate note ───────────────────────────────────────────────────
step "TLS certificate..."
echo "  The proxy creates a self-signed certificate for localhost on first run."
echo "  macOS will ask for your login password to add it to Keychain (once)."
echo "  This is required for MoneyMoney to trust the local HTTPS proxy."

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  Installation complete!${NC}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Next steps:"
echo "  1. Reload extensions in MoneyMoney (right-click any account → Reload Extensions)"
echo "     or restart MoneyMoney"
echo "  2. Add a new account: File → Add Account → search for 'Bangkok Bank'"
echo "  3. Enter your Bualuang iBanking username and password"
echo ""
echo "  The proxy starts automatically when MoneyMoney connects."
echo "  Proxy logs: tail -f /tmp/bbl_proxy.log"
echo ""
