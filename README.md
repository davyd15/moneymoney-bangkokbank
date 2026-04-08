# MoneyMoney Extension – Bangkok Bank

A [MoneyMoney](https://moneymoney-app.com) extension for **Bangkok Bank (BBL) Thailand** via the [Bualuang iBanking](https://ibanking.bangkokbank.com) web portal. Fetches account balances and transactions.

---

## Features

- Supports **Savings, Current, Fixed Deposit** accounts in THB
- Fetches up to **89 days** of transaction history per refresh
- Login via **headless Firefox** (Camoufox) — bypasses Akamai bot protection invisibly
- Proxy runs **on demand only** via macOS Socket Activation — no background process when idle

## How it works

Bangkok Bank's iBanking portal is protected by Akamai Bot Manager, which blocks standard HTTP clients. This extension uses a small local HTTPS proxy (`bangkokbank_proxy.py`) that:

1. Handles login via a headless Firefox browser (Camoufox) — this is the only way to pass the Akamai JS challenge
2. Forwards subsequent data requests using `curl-cffi` with a Chrome TLS fingerprint
3. Runs as a macOS LaunchAgent with Socket Activation — starts only when MoneyMoney connects, shuts down after 120s of inactivity

MoneyMoney connects to `https://127.0.0.1:8765` (local proxy) instead of the bank directly.

## Requirements

- [MoneyMoney](https://moneymoney-app.com) for macOS
- Python 3 (via [Homebrew](https://brew.sh): `brew install python`)
- A **Bualuang iBanking** account at Bangkok Bank

## Installation

```bash
git clone https://github.com/davyd15/moneymoney-bangkokbank.git
cd moneymoney-bangkokbank
./install.sh
```

The installer will:
1. Install Python packages (`curl-cffi`, `camoufox`)
2. Download the Camoufox headless Firefox browser (~100 MB, once)
3. Copy `BangkokBank.lua` and `bangkokbank_proxy.py` into the MoneyMoney Extensions folder
4. Generate and register the LaunchAgent with the correct paths for your system

### First run – TLS certificate

On the first refresh, the proxy creates a self-signed certificate for `127.0.0.1` and adds it to your login Keychain. macOS will prompt for your password once. This certificate lets MoneyMoney trust the local proxy.

## Setup in MoneyMoney

1. Reload extensions: right-click any account → **Reload Extensions** (or restart MoneyMoney)
2. Add a new account: **File → Add Account…**
3. Search for **"Bangkok Bank"**
4. Select **Bangkok Bank (Bualuang iBanking)**
5. Enter your **Bualuang iBanking username** and **password**
6. Click **Next** — MoneyMoney will connect and import your accounts

> **Note:** Use your Bualuang iBanking credentials, not the Bangkok Bank mobile app credentials.

## Supported Account Types

| Type | Description |
|------|-------------|
| Savings (SA) | Standard savings accounts |
| Current (CA) | Current / checking accounts |
| Fixed Deposit (FD) | Fixed term deposit accounts |

## Limitations

- **THB only** — foreign currency accounts are not supported
- **Max 89 days** of history per refresh (portal limitation)
- Requires Python 3 and a one-time setup (no pure-Lua solution possible due to Akamai)

## Troubleshooting

**"Proxy not running" error in MoneyMoney**
- Check the log: `tail -f /tmp/bbl_proxy.log`
- Verify the LaunchAgent is loaded: `launchctl list | grep bangkokbank`
- Reload it manually: `launchctl load ~/Library/LaunchAgents/com.bangkokbank.proxy.plist`

**Login fails / credentials rejected**
- Make sure you are using your **Bualuang iBanking** credentials, not Bangkok Bank mobile app credentials
- Verify at [https://ibanking.bangkokbank.com](https://ibanking.bangkokbank.com) in your browser

**"Certificate not trusted" error**
- The proxy self-signs a certificate on first run and adds it to Keychain automatically
- If this fails, run manually:
  ```bash
  security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db /tmp/bbl_cert.pem
  ```

**Camoufox download fails**
- Run manually: `python3 -m camoufox fetch`
- Alternatively, install Google Chrome — the proxy will fall back to Chrome CDP

**Extension not appearing in MoneyMoney**
- Confirm `BangkokBank.lua` is in:
  `~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/`
- Reload extensions or restart MoneyMoney

## Uninstall

```bash
./uninstall.sh
```

Removes the extension, LaunchAgent, Keychain certificate, and temp files.

## Changelog

| Version | Changes |
|---------|---------|
| 2.17 | Code cleanup |
| 2.16 | Socket Activation – proxy starts on demand, shuts down after idle |
| 2.15 | Camoufox headless Firefox replaces Chrome CDP (no Dock icon) |
| 2.00 | Initial release – proxy architecture with Akamai bypass |

## Contributing

Bug reports and pull requests are welcome. If Bangkok Bank changes its login flow, please open an issue and include the proxy log (`/tmp/bbl_proxy.log`) — that makes diagnosis much easier.

## Disclaimer

This is an independent community project and is **not affiliated with, endorsed by, or supported by Bangkok Bank** or the MoneyMoney developers. Use at your own risk. Credentials are handled solely by MoneyMoney's built-in secure storage and are never transmitted to any third party.

## License

MIT — see [LICENSE](LICENSE)
