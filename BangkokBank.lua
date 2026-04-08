-- Bangkok Bank (Bualuang iBanking) Web Banking Extension for MoneyMoney
--
-- Changelog:
--   2.00  Proxy architecture with curl-cffi (Chrome TLS fingerprint, Akamai bypass)
--   2.01  Attempted proxy auto-start (os.execute/io.popen – both blocked in sandbox)
--   2.04  Removed auto-start; proxy runs as a macOS LaunchAgent
--         ~/Library/LaunchAgents/com.bangkokbank.proxy.plist
--   2.05  Proxy speaks HTTPS (MoneyMoney enforces HTTPS for all connections)
--   2.06  Proxy v10: Playwright login (Akamai JS challenge), curl-cffi for data requests
--   2.07  Fix: tonumber(gsub()) – gsub returns 2 values, causing base-out-of-range error
--   2.08  Debug prints for RefreshAccount (balance, date format, XPath matches)
--   2.09  Fix: ddlAccount value with correct separator \194\151 (U+0097, char 151)
--   2.10  Fix: navBody POST already returns transactions; removed second search POST
--   2.11  Fix: corrected search POST (DES_Group empty, missing fields, no radDownload);
--         fall back to actPage if search POST fails
--   2.12  Increased MAX_DAYS from 89 to 365 for full initial import
--   2.13  Fix: XPath lblLedgerBal → lblLedgerBalVal (was reading label instead of value → nil → fallback)
--   2.14  Fix: nil check for finalUrl (getBaseURL() may return nil); removed debug prints
--   2.15  Proxy v12: Camoufox headless Firefox replaces Chrome CDP (no Dock icon)
--   2.16  Proxy v13: Socket Activation – proxy only runs on demand, not permanently
--   2.17  Code cleanup: removed redundant debug prints
--
-- Dependency: bangkokbank_proxy.py (v13) via LaunchAgent on port 8765
--   Login: Camoufox headless Firefox (Akamai bypass, invisible)
--   Start: automatically by launchd on demand (Socket Activation)
--   Log:   /tmp/bbl_proxy.log

WebBanking {
  version     = 2.17,
  url         = "https://127.0.0.1:8765",
  services    = {"Bangkok Bank"},
  description = "Bangkok Bank – Bualuang iBanking (via local proxy)"
}

-- Proxy address and key paths on the Bangkok Bank server
local PROXY        = "https://127.0.0.1:8765"
local SIGNON       = PROXY .. "/SignOn.aspx"
local SUMMARY_PATH = "/workspace/16AccountActivity/wsp_AccountSummary_AccountSummaryPage.aspx"
local ACTIVITY_PATH= "/workspace/16AccountActivity/wsp_AccountActivity_Saving_Current.aspx"
local LOGOUT       = PROXY .. "/LogOut.aspx"
local MAX_DAYS     = 365  -- maximaler Abrufzeitraum in Tagen

local connection    -- MoneyMoney Connection object, set in InitializeSession
local cachedSummary -- AccountSummaryPage cached after login, saves one request in ListAccounts

local ACCEPT = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8"

local function doGet(path, referer)
  local url = PROXY .. path
  print("GET " .. url)
  return connection:request("GET", url, nil, nil, {
    ["Accept"]                    = ACCEPT,
    ["Accept-Language"]           = "en-US,en;q=0.9",
    ["Cache-Control"]             = "no-cache",
    ["Pragma"]                    = "no-cache",
    ["Upgrade-Insecure-Requests"] = "1",
    ["Referer"]                   = referer or PROXY,
  })
end

local function doPost(path, body, referer)
  local url = PROXY .. path
  print("POST " .. url)
  return connection:request("POST", url, body,
    "application/x-www-form-urlencoded", {
      ["Accept"]                    = ACCEPT,
      ["Accept-Language"]           = "en-US,en;q=0.9",
      ["Cache-Control"]             = "no-cache",
      ["Pragma"]                    = "no-cache",
      ["Origin"]                    = "https://ibanking.bangkokbank.com",
      ["Upgrade-Insecure-Requests"] = "1",
      ["Referer"]                   = referer or SIGNON,
    })
end

local function enc(s)
  if s == nil then return "" end
  return (tostring(s):gsub("([^%w%-%.%_%~ ])", function(c)
    return ("%%%02X"):format(c:byte())
  end):gsub(" ", "+"))
end

local function form(params)
  local t = {}
  for _, p in ipairs(params) do t[#t+1] = enc(p[1]).."="..enc(p[2]) end
  return table.concat(t, "&")
end

local function tokens(html)
  local names = { "__EVENTTARGET","__EVENTARGUMENT","__VIEWSTATE",
    "__VIEWSTATEGENERATOR","__VIEWSTATEENCRYPTED","__PREVIOUSPAGE",
    "__EVENTVALIDATION","__RequestVerificationToken" }
  local t = {}
  for _, n in ipairs(names) do
    t[n] = html:xpath("//input[@name='"..n.."']"):attr("value") or ""
  end
  return t
end

local function amt(s)
  if not s or s=="" then return nil end
  return tonumber((s:gsub(",","")))
end

local MON  = {Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,
              Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
local MNAM = {"Jan","Feb","Mar","Apr","May","Jun",
              "Jul","Aug","Sep","Oct","Nov","Dec"}

local function parseDate(s)
  if not s or s=="" then return nil end
  local d,m,y,hh,mm = s:match("(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+)")
  if not d then d,m,y=s:match("(%d+)%s+(%a+)%s+(%d+)"); hh,mm=0,0 end
  if not d or not MON[m] then return nil end
  return os.time({year=tonumber(y),month=MON[m],day=tonumber(d),
                  hour=tonumber(hh) or 0,min=tonumber(mm) or 0,sec=0})
end

local function mdy(ts) return os.date("%m/%d/%Y",ts) end
local function dmy(ts)
  local t=os.date("*t",ts)
  return ("%02d %s %04d"):format(t.day,MNAM[t.month],t.year)
end

-- ============================================================
-- MoneyMoney API Entry Points

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "Bangkok Bank"
end

function InitializeSession(protocol, bankCode, username, reserved, password)
  print("=== InitializeSession ===")
  connection = Connection()
  connection.useragent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " ..
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
  connection.language = "en-US,en;q=0.9"

  -- Reset cookies
  pcall(function() connection:get(PROXY .. "/__reset__") end)

  -- SignOn-Seite laden
  local signonContent, signonCharset = doGet("/SignOn.aspx",
    "https://www.bangkokbank.com/")
  if not signonContent or #signonContent < 200 then
    return "Bangkok Bank login page could not be loaded."
  end

  local loginPage = HTML(signonContent, signonCharset)
  local tok = tokens(loginPage)
  if tok["__VIEWSTATE"] == "" then
    return "VIEWSTATE nicht gefunden – bitte erneut versuchen."
  end

  -- Login POST
  local body = form({
    {"__EVENTTARGET",""},{"__EVENTARGUMENT",""},
    {"DES_Group","GROUPMAIN"},
    {"__VIEWSTATE",tok["__VIEWSTATE"]},
    {"DES_JSE","1"},
    {"__VIEWSTATEGENERATOR",tok["__VIEWSTATEGENERATOR"]},
    {"__EVENTVALIDATION",tok["__EVENTVALIDATION"]},
    {"txiID",username},{"txiPwd",password},{"btnLogOn","Log On"},
  })

  local loginContent, loginCharset = doPost("/SignOn.aspx", body, SIGNON)
  local finalUrl = connection:getBaseURL()
  print("  finalUrl=" .. tostring(finalUrl))

  if not finalUrl or finalUrl:lower():find("signon") or finalUrl:lower():find("signin") then
    print("  -> LoginFailed")
    return LoginFailed
  end

  -- Cache summary page
  if loginContent and #loginContent > 500 then
    cachedSummary = HTML(loginContent, loginCharset)
    print("  Summary cached (len="..#loginContent..")")
  else
    local sc, sch = doGet(SUMMARY_PATH, SIGNON)
    cachedSummary = (sc and #sc > 500) and HTML(sc, sch) or nil
    print("  Summary ".. (cachedSummary and "loaded" or "ERROR"))
  end

  print("  -> OK")
  return nil
end

function ListAccounts(knownAccounts)
  print("=== ListAccounts ===")
  local summaryPage = cachedSummary
  if not summaryPage then
    local sc, sch = doGet(SUMMARY_PATH, SIGNON)
    if not sc or #sc < 200 then return "Account summary page not reachable." end
    summaryPage = HTML(sc, sch)
  else
    print("  Using cached summary")
  end

  local accounts = {}
  summaryPage:xpath(
    "//*[contains(@id,'gvDepositAccts') and contains(@id,'lnkDepositAccts')]"
  ):each(function(rowIdx, node)
    local accNo = (node:text() or ""):gsub("%s+","")
    if accNo == "" then return end
    local accId = accNo:gsub("-","")
    local base  = (node:attr("id") or ""):gsub("lnkDepositAccts$","")
    local function lbl(s)
      return summaryPage:xpath("//*[@id='"..base..s.."']"):text() or ""
    end
    local typeName = lbl("lblAcctTypeName")
    local accType  = AccountTypeSavings
    local tl = typeName:lower()
    if     tl:find("saving")  then accType = AccountTypeSavings
    elseif tl:find("current") or tl:find("giro") then accType = AccountTypeGiro
    elseif tl:find("credit")  then accType = AccountTypeCreditCard
    elseif tl:find("loan")    then accType = AccountTypeLoan
    elseif tl:find("fixed")   then accType = AccountTypeFixedTermDeposit
    end
    print("  Account: "..accNo.." ("..typeName..")")
    accounts[#accounts+1] = {
      name=((typeName~="" and typeName or "Account").." "..accNo),
      accountNumber=accNo, bankCode="BKKBTHBK", currency="THB",
      type=accType, subAccount=rowIdx..":"..accId,
    }
  end)

  if #accounts == 0 then
    local txt = summaryPage:xpath("//body"):text() or ""
    print("  No accounts found! Page: "..txt:sub(1,200))
    return "No accounts found."
  end
  print("  "..#accounts.." account(s)")
  return accounts
end

function RefreshAccount(account, since)
  print("=== RefreshAccount: "..account.accountNumber.." ===")
  local acctIndex, acctId = account.subAccount:match("^(%d+):(%d+)$")
  if not acctIndex then
    acctIndex="1"; acctId=account.accountNumber:gsub("[^%d]","")
  end

  local sc, sch = doGet(SUMMARY_PATH, SIGNON)
  if not sc or #sc<200 then return "Summary page not reachable." end
  local sumPage = HTML(sc, sch)
  local sumTok  = tokens(sumPage)

  local navBody = form({
    {"__RequestVerificationToken",sumTok["__RequestVerificationToken"]},
    {"__EVENTTARGET",""},{"__EVENTARGUMENT",""},
    {"__VIEWSTATE",sumTok["__VIEWSTATE"]},
    {"__VIEWSTATEGENERATOR",sumTok["__VIEWSTATEGENERATOR"]},
    {"__PREVIOUSPAGE",sumTok["__PREVIOUSPAGE"]},
    {"__EVENTVALIDATION",sumTok["__EVENTVALIDATION"]},
    {"AcctID",acctId},{"AcctIndex",acctIndex},
    {"ctl00$ctl00$C$CW$hidCollapseFlag","N"},
  })

  local ac, ach = doPost(ACTIVITY_PATH, navBody, PROXY..SUMMARY_PATH)
  if not ac or #ac<200 then return "Activity page not reachable." end
  local actPage = HTML(ac, ach)
  local balRaw = actPage:xpath("//*[contains(@id,'lblLedgerBalVal')]"):text()
  print("  balRaw='" .. tostring(balRaw) .. "'")
  local balance = amt(balRaw)

  local now    = os.time()
  local fromTs = since and math.max(since, now-MAX_DAYS*86400) or (now-MAX_DAYS*86400)

  -- Attempt a search POST with the desired date range.
  -- Correct fields per HTML form: DES_Group="", no radDownloadTextFormat,
  -- AcctID/AcctIndex/Be1stCardIndex/flagPost empty, SEP char in ddlAccount value.
  local resPage = actPage  -- Fallback: actPage (server default ~28 days)
  local actTok = tokens(actPage)
  local SEP = "\194\151"
  local ddlVal = acctIndex..SEP..acctId..SEP.."001"..SEP.."wsp_AccountActivity_Saving_Current.aspx"

  local searchBody = form({
    {"__RequestVerificationToken",actTok["__RequestVerificationToken"]},
    {"__EVENTTARGET",""},{"__EVENTARGUMENT",""},{"DES_Group",""},
    {"__VIEWSTATE",actTok["__VIEWSTATE"]},
    {"__VIEWSTATEGENERATOR",actTok["__VIEWSTATEGENERATOR"]},
    {"__VIEWSTATEENCRYPTED",""},
    {"__PREVIOUSPAGE",actTok["__PREVIOUSPAGE"]},
    {"__EVENTVALIDATION",actTok["__EVENTVALIDATION"]},
    {"ctl00$ctl00$C$CN$NavAcctActivity1$ddlAccount",ddlVal},
    {"ctl00$ctl00$C$CW$IBCalendarDateFrom$IBCalText",dmy(fromTs)},
    {"ctl00$ctl00$C$CW$IBCalendarDateFrom$hidDateDisplay",dmy(fromTs)},
    {"ctl00$ctl00$C$CW$IBCalendarDateFrom$hidDateValue",mdy(fromTs)},
    {"ctl00$ctl00$C$CW$IBCalendarDateTo$IBCalText",dmy(now)},
    {"ctl00$ctl00$C$CW$IBCalendarDateTo$hidDateDisplay",dmy(now)},
    {"ctl00$ctl00$C$CW$IBCalendarDateTo$hidDateValue",mdy(now)},
    {"ctl00$ctl00$C$CW$btnOK","OK"},
    {"AcctID",""},{"AcctIndex",""},{"Be1stCardIndex",""},{"flagPost",""},
    {"ctl00$ctl00$C$CW$hidErrorMsg","../images/ChequeImg_99_en.gif"},
  })

  local rc, rch = doPost(ACTIVITY_PATH, searchBody, PROXY..ACTIVITY_PATH)
  if rc and #rc>200 then
    local rp = HTML(rc, rch)
    local rb = amt(rp:xpath("//*[contains(@id,'lblLedgerBalVal')]"):text())
    if rb then
      resPage = rp
      balance = rb
      print("  Search-POST OK ("..dmy(fromTs).." – "..dmy(now)..")")
    else
      print("  Search POST failed, falling back to actPage (default date range)")
    end
  else
    print("  Search POST failed, falling back to actPage (default date range)")
  end

  local transactions = {}
  local txCount = 0
  resPage:xpath(
    "//*[contains(@id,'gvAccountTrans') and contains(@id,'lblItemDate')]"
  ):each(function(_, dn)
    txCount = txCount + 1
    local nid=dn:attr("id") or ""
    local prefix=nid:match("(.+_ctl%d+_)lblItemDate$")
    if not prefix then return end
    local function c(s)
      return resPage:xpath("//*[@id='"..prefix..s.."']"):text() or ""
    end
    local ds=(dn:text() or ""):match("^%s*(.-)%s*$")
    local bd=parseDate(ds)
    if not bd then
      print("  parseDate FAIL: '"..ds.."'")
      return
    end
    if since and bd<since then return end
    local deb=amt(c("lblItemDebit"))
    local cred=amt(c("lblItemCredit"))
    local a=(cred and cred~=0) and cred or (deb and deb~=0) and -deb or 0
    local desc=c("lblItemDescription")
    local chan=c("lblItemChannel")
    transactions[#transactions+1]={
      bookingDate=bd, valueDate=bd,
      purpose=(chan~="") and (desc.." ["..chan.."]") or desc,
      amount=a, currency="THB", booked=true,
    }
  end)

  table.sort(transactions,function(a,b) return a.bookingDate>b.bookingDate end)
  print("  txNodes="..txCount.." balance="..tostring(balance).." transactions="..#transactions)
  return {balance=balance or 0, transactions=transactions}
end

function EndSession()
  print("=== EndSession ===")
  cachedSummary = nil
  pcall(function()
    connection:get(LOGOUT)
    connection:get(PROXY.."/__reset__")
  end)
  return nil
end
