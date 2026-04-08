#!/bin/bash
# Bangkok Bank MoneyMoney Extension – Uninstaller
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
step() { echo -e "\n${BLUE}▶ $*${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }

EXTENSIONS_DIR="$HOME/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_LABEL="com.bangkokbank.proxy"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$PLIST_LABEL.plist"

echo ""
echo -e "${BOLD}Bangkok Bank iBanking – MoneyMoney Extension Uninstaller${NC}"
echo "──────────────────────────────────────────────────────────"

read -rp "  Remove Bangkok Bank extension and proxy? [y/N] " yn
[[ "$yn" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }

# ── LaunchAgent ───────────────────────────────────────────────────────────────
step "Removing LaunchAgent..."
launchctl unload "$PLIST_PATH" 2>/dev/null || true
if rm -f "$PLIST_PATH"; then
    ok "LaunchAgent removed"
else
    warn "Plist not found (already removed?)"
fi

# ── Extension files ───────────────────────────────────────────────────────────
step "Removing extension files..."
rm -f "$EXTENSIONS_DIR/BangkokBank.lua"      && ok "BangkokBank.lua removed"   || warn "BangkokBank.lua not found"
rm -f "$EXTENSIONS_DIR/bangkokbank_proxy.py" && ok "bangkokbank_proxy.py removed" || warn "bangkokbank_proxy.py not found"

# ── TLS certificate and temp files ───────────────────────────────────────────
step "Removing TLS certificate and temp files..."
CERT_FILE="/tmp/bbl_cert.pem"
KEY_FILE="/tmp/bbl_key.pem"
if [ -f "$CERT_FILE" ]; then
    security delete-certificate -c "127.0.0.1" "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
        && ok "Certificate removed from Keychain" || warn "Could not remove certificate from Keychain (may not exist)"
    rm -f "$CERT_FILE" "$KEY_FILE"
    ok "Certificate files removed"
fi
rm -f /tmp/bbl_session.txt /tmp/bbl_proxy.log
ok "Temp files removed"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Bangkok Bank extension uninstalled.${NC}"
echo "  Reload extensions in MoneyMoney or restart the app."
echo ""
