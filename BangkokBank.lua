-- Bangkok Bank (Bualuang iBanking) Web Banking Extension für MoneyMoney
-- Version: 2.00  –  benötigt bangkokbank_proxy.py auf localhost:8765

WebBanking {
  version     = 2.00,
  url         = "http://127.0.0.1:8765",
  services    = {"Bangkok Bank"},
  description = "Bangkok Bank – Bualuang iBanking (via lokalem Proxy)"
}

local PROXY        = "http://127.0.0.1:8765"
local SIGNON       = PROXY .. "/SignOn.aspx"
local SUMMARY_PATH = "/workspace/16AccountActivity/wsp_AccountSummary_AccountSummaryPage.aspx"
local ACTIVITY_PATH= "/workspace/16AccountActivity/wsp_AccountActivity_Saving_Current.aspx"
local LOGOUT       = PROXY .. "/LogOut.aspx"
local MAX_DAYS     = 89

local connection
local cachedSummary

local ACCEPT = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8"

local function doGet(path, referer)
  local url = PROXY .. path
  print("GET " .. url)
  local content, charset = connection:request("GET", url, nil, nil, {
    ["Accept"]                    = ACCEPT,
    ["Accept-Language"]           = "en-US,en;q=0.9",
    ["Cache-Control"]             = "no-cache",
    ["Pragma"]                    = "no-cache",
    ["Upgrade-Insecure-Requests"] = "1",
    ["Referer"]                   = referer or PROXY,
  })
  print("  len=" .. tostring(content and #content or 0))
  return content, charset
end

local function doPost(path, body, referer)
  local url = PROXY .. path
  print("POST " .. url)
  local content, charset = connection:request("POST", url, body,
    "application/x-www-form-urlencoded", {
      ["Accept"]                    = ACCEPT,
      ["Accept-Language"]           = "en-US,en;q=0.9",
      ["Cache-Control"]             = "no-cache",
      ["Pragma"]                    = "no-cache",
      ["Origin"]                    = "https://ibanking.bangkokbank.com",
      ["Upgrade-Insecure-Requests"] = "1",
      ["Referer"]                   = referer or SIGNON,
    })
  print("  len=" .. tostring(content and #content or 0))
  return content, charset
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
  print("  VIEWSTATE="..#t["__VIEWSTATE"].." EVENTVAL="..#t["__EVENTVALIDATION"])
  return t
end

local function amt(s)
  if not s or s=="" then return nil end
  return tonumber(s:gsub(",",""))
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

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "Bangkok Bank"
end

function InitializeSession(protocol, bankCode, username, reserved, password)
  print("=== InitializeSession ===")
  connection = Connection()
  connection.useragent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " ..
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
  connection.language = "en-US,en;q=0.9"

  -- Proxy-Check
  print("Proxy-Check: " .. PROXY .. "/__status__")
  local ok, statusContent = pcall(function()
    return connection:get(PROXY .. "/__status__")
  end)
  if not ok or not statusContent or statusContent == "" then
    return "Bangkok Bank Proxy läuft nicht!\n\n" ..
           "Bitte starte den Proxy zuerst in einem Terminal:\n\n" ..
           "    python3 ~/Library/Application\\ Support/MoneyMoney/Extensions/bangkokbank_proxy.py\n\n" ..
           "Der Proxy muss laufen, solange MoneyMoney Bangkok Bank abruft."
  end
  print("  Proxy OK")

  -- Cookies zurücksetzen
  pcall(function() connection:get(PROXY .. "/__reset__") end)

  -- SignOn-Seite laden
  local signonContent, signonCharset = doGet("/SignOn.aspx",
    "https://www.bangkokbank.com/")
  if not signonContent or #signonContent < 200 then
    return "Bangkok Bank Login-Seite konnte nicht geladen werden."
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

  if finalUrl:lower():find("signon") or finalUrl:lower():find("signin") then
    print("  -> LoginFailed")
    return LoginFailed
  end

  -- Summary cachen
  if loginContent and #loginContent > 500 then
    cachedSummary = HTML(loginContent, loginCharset)
    print("  Summary gecacht (len="..#loginContent..")")
  else
    local sc, sch = doGet(SUMMARY_PATH, SIGNON)
    cachedSummary = (sc and #sc > 500) and HTML(sc, sch) or nil
    print("  Summary ".. (cachedSummary and "geladen" or "FEHLER"))
  end

  print("  -> OK")
  return nil
end

function ListAccounts(knownAccounts)
  print("=== ListAccounts ===")
  local summaryPage = cachedSummary
  if not summaryPage then
    local sc, sch = doGet(SUMMARY_PATH, SIGNON)
    if not sc or #sc < 200 then return "Kontenübersicht nicht erreichbar." end
    summaryPage = HTML(sc, sch)
  else
    print("  Verwende gecachte Summary")
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
    print("  Konto: "..accNo.." ("..typeName..")")
    accounts[#accounts+1] = {
      name=((typeName~="" and typeName or "Account").." "..accNo),
      accountNumber=accNo, bankCode="BKKBTHBK", currency="THB",
      type=accType, subAccount=rowIdx..":"..accId,
    }
  end)

  if #accounts == 0 then
    local txt = summaryPage:xpath("//body"):text() or ""
    print("  Keine Konten! Seite: "..txt:sub(1,200))
    return "Keine Konten gefunden."
  end
  print("  "..#accounts.." Konto/Konten")
  return accounts
end

function RefreshAccount(account, since)
  print("=== RefreshAccount: "..account.accountNumber.." ===")
  local acctIndex, acctId = account.subAccount:match("^(%d+):(%d+)$")
  if not acctIndex then
    acctIndex="1"; acctId=account.accountNumber:gsub("[^%d]","")
  end

  local sc, sch = doGet(SUMMARY_PATH, SIGNON)
  if not sc or #sc<200 then return "Summary nicht erreichbar." end
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
  if not ac or #ac<200 then return "Activity-Seite nicht erreichbar." end
  local actPage = HTML(ac, ach)
  local balance = amt(actPage:xpath("//*[contains(@id,'lblLedgerBal')]"):text())

  local now    = os.time()
  local fromTs = since and math.max(since, now-MAX_DAYS*86400) or (now-MAX_DAYS*86400)
  local actTok = tokens(actPage)
  local ddlVal = acctIndex..acctId.."001wsp_AccountActivity_Saving_Current.aspx"

  local searchBody = form({
    {"__RequestVerificationToken",actTok["__RequestVerificationToken"]},
    {"DES_Group","MAINGROUP"},
    {"__VIEWSTATE",actTok["__VIEWSTATE"]},
    {"__VIEWSTATEGENERATOR",actTok["__VIEWSTATEGENERATOR"]},
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
    {"ctl00$ctl00$C$CW$hidErrorMsg","../images/ChequeImg_99_en.gif"},
    {"ctl00$ctl00$C$radDownloadTextFormat","radDownloadTextFormat"},
  })

  local rc, rch = doPost(ACTIVITY_PATH, searchBody, PROXY..ACTIVITY_PATH)
  if not rc or #rc<200 then return "Umsatzseite nicht erreichbar." end
  local resPage = HTML(rc, rch)

  local rb = amt(resPage:xpath("//*[contains(@id,'lblLedgerBal')]"):text())
  if rb then balance=rb end

  local transactions = {}
  resPage:xpath(
    "//*[contains(@id,'gvAccountTrans') and contains(@id,'lblItemDate')]"
  ):each(function(_, dn)
    local nid=dn:attr("id") or ""
    local prefix=nid:match("(.+_ctl%d+_)lblItemDate$")
    if not prefix then return end
    local function c(s)
      return resPage:xpath("//*[@id='"..prefix..s.."']"):text() or ""
    end
    local ds=(dn:text() or ""):match("^%s*(.-)%s*$")
    local bd=parseDate(ds)
    if not bd then return end
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
  print("  Saldo="..tostring(balance).." Umsätze="..#transactions)
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
