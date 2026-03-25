# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **MoneyMoney Web Banking Extension** for **Bangkok Bank (Bualuang iBanking)**, implementing account listing and transaction retrieval via a local Python proxy. MoneyMoney is a macOS personal finance application that uses Lua-based extensions.

The entire extension lives in two files:
- [BangkokBank.lua](BangkokBank.lua) — MoneyMoney Lua extension
- [bangkokbank_proxy.py](bangkokbank_proxy.py) — lokaler HTTP-Proxy (Port 8765), der Akamai-Bot-Schutz via Chrome-TLS-Fingerprint umgeht

## API-Dokumentation

Die offizielle MoneyMoney API Dokumentation liegt in [moneymoney-api.md](moneymoney-api.md) — nur lesen wenn nötig, z.B. bei API-Fragen, neuen Funktionen oder Bugs die mit der API zusammenhängen, nicht automatisch bei jeder Anfrage laden.

## Git Commits

Beim Erstellen von Commits immer selbst eine passende, beschreibende Commit-Nachricht wählen die erklärt was geändert wurde — kein Nachfragen.

## Versioning

Nach jeder Änderung an `BangkokBank.lua` die Versionsnummer im Datei-Header (`version = X.XX` in `WebBanking{}` und im Kommentar `-- Version: X.XX`) erhöhen und eine kurze Beschreibung der Änderung als Kommentarzeile hinzufügen.

## Development

No build system, test framework, or package manager exists. The extension is a standalone Lua script. To test, copy `BangkokBank.lua` into MoneyMoney's extensions folder and reload extensions in the app.

**Extensions-Ordner:**
```
~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/
```

Nach jeder Änderung an `BangkokBank.lua` die Datei automatisch in den Extensions-Ordner kopieren (wird per Claude Code Hook erledigt — siehe `.claude/settings.local.json`).

**Proxy starten:**
```
python3 ~/Library/Application\ Support/MoneyMoney/Extensions/bangkokbank_proxy.py
```

Der Proxy muss laufen, solange MoneyMoney Bangkok Bank abruft. Er benötigt `curl-cffi` (`pip3 install curl-cffi`).

## Architecture

The extension implements the MoneyMoney Web Banking API with these required entry points:

- `SupportsBank(protocol, bankCode)` — declares bank support
- `InitializeSession(protocol, bankCode, username, reserved, password)` — handles login (single-step)
- `ListAccounts(knownAccounts)` — returns account list
- `RefreshAccount(account, since)` — returns balance + transactions
- `EndSession()` — cleanup

### Authentication Flow

Login is a single-step form-based login via ASP.NET WebForms (`POST /SignOn.aspx`):

1. Proxy-Check via `GET /__status__` — Fehlermeldung wenn Proxy nicht läuft
2. Cookie-Reset via `GET /__reset__`
3. `GET /SignOn.aspx` — lädt Login-Seite und extrahiert ASP.NET Hidden Fields (`__VIEWSTATE`, `__EVENTVALIDATION`, etc.)
4. `POST /SignOn.aspx` — sendet Username + Password + Hidden Fields → Redirect zur Summary-Seite bei Erfolg

**Important:** Password is never persisted — kept only in RAM and cleared after use.

### API Communication

- Base URL: `http://127.0.0.1:8765` (lokaler Proxy)
- Upstream: `https://ibanking.bangkokbank.com`
- Auth: Form-based Login (ASP.NET WebForms, kein Bearer Token)
- Der Proxy verwendet `curl-cffi` mit Chrome-TLS-Fingerprint (`chrome124`) und HTTP/1.1, um Akamai-Bot-Erkennung zu umgehen
- Cookies werden in einer temporären Datei (`/tmp/bbl_session.txt`) persistiert

**Wichtige Pfade:**
- `/SignOn.aspx` — Login
- `/workspace/16AccountActivity/wsp_AccountSummary_AccountSummaryPage.aspx` — Kontoübersicht
- `/workspace/16AccountActivity/wsp_AccountActivity_Saving_Current.aspx` — Umsätze
- `/LogOut.aspx` — Logout
- `/__status__` — Proxy-Health-Check (custom endpoint)
- `/__reset__` — Cookies zurücksetzen (custom endpoint)

### ASP.NET Hidden Fields

Bangkok Bank verwendet ASP.NET WebForms. Jeder POST muss die Hidden Fields aus dem vorherigen GET mitschicken:
`__EVENTTARGET`, `__EVENTARGUMENT`, `__VIEWSTATE`, `__VIEWSTATEGENERATOR`, `__VIEWSTATEENCRYPTED`, `__PREVIOUSPAGE`, `__EVENTVALIDATION`, `__RequestVerificationToken`

Extraktion via XPath: `html:xpath("//input[@name='...']"):attr("value")`

### JSON Handling

Uses the built-in `JSON` object: `JSON(str):dictionary()` to parse and `JSON():set(t):json()` to serialize.

### LocalStorage

Use bracket notation only — `LocalStorage["key"]`, not `LocalStorage.set/get/remove()` (those don't exist in this MoneyMoney version).

```lua
LocalStorage["key"] = value   -- speichern
local v = LocalStorage["key"] -- lesen (nil wenn nicht vorhanden)
LocalStorage["key"] = nil     -- löschen
```

### Aktueller Stand

- Version 2.00: Proxy-basierte Implementierung mit curl-cffi Chrome-TLS-Fingerprint (Akamai-Bypass)
- Unterstützt: Savings, Current, Credit Card, Loan, Fixed Term Deposit Konten
- MAX_DAYS = 89 (maximaler Abrufzeitraum für Umsätze)
- Transaktionen: Datum, Betrag (Debit negativ, Credit positiv), Beschreibung + Channel
- Bekannte Einschränkungen: Proxy muss manuell gestartet werden
