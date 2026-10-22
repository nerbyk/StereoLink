-- DNS wire format for the mDNS responder: just enough to answer AirPlay browse/resolve
-- queries and to look up one SRV record. Pure functions, no sockets.
--
-- Packets come from anyone on the network, so parsing has hard limits: compression pointers
-- only go backwards, and one packet gets a fixed budget of label steps.

local M = {}

local TYPE_A, TYPE_PTR, TYPE_TXT, TYPE_SRV, TYPE_ANY = 1, 12, 16, 33, 255
local CLASS_IN, CACHE_FLUSH = 1, 0x8000
local FLAG_RESPONSE = 0x8000
local FLAGS_AUTHORITATIVE_ANSWER = 0x8400
-- RFC 6762: records tied to the host's address live 2 minutes, the others 75 minutes
local TTL_HOST, TTL_SERVICE = 120, 4500
local SERVICES_META = '_services._dns-sd._udp.local'
local HEADER_BYTES = 12
local MAX_LABEL_BYTES, MAX_NAME_BYTES = 63, 255
local POINTER = 0xC0
local MAX_NAME_STEPS = 128
-- A Mac browsing several services can ask more than 16 questions in one query.
local MAX_QUESTIONS = 32
local MAX_PACKET_STEPS = MAX_QUESTIONS * 16 -- an iPhone browse query takes about 30

local function u16(s, i) return s:byte(i) * 256 + s:byte(i + 1) end
local function be16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function be32(n)
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

-- Raises an error for names DNS cannot carry: a longer label would be read back as a pointer.
local function encodeName(name)
  local out = {}
  for label in name:gmatch('[^.]+') do
    if #label > MAX_LABEL_BYTES then error('DNS label over ' .. MAX_LABEL_BYTES .. ' bytes') end
    table.insert(out, string.char(#label) .. label)
  end
  table.insert(out, '\0')
  local encoded = table.concat(out)
  if #encoded > MAX_NAME_BYTES then error('DNS name over ' .. MAX_NAME_BYTES .. ' bytes') end
  return encoded
end

-- Returns the lowercased dotted name, the index right after it and what is left of `budget`
-- (label steps; one name spends MAX_NAME_STEPS at most), or nil for a malformed name or a
-- spent budget.
-- Each pointer must go further back than the previous one, which rules out loops.
local function readName(s, i, budget)
  budget = budget or MAX_NAME_STEPS
  local labels, resumeAt, limit = {}, nil, i
  for step = 1, math.min(budget, MAX_NAME_STEPS) do
    local len = s:byte(i)
    if not len then return nil end
    if len == 0 then
      return table.concat(labels, '.'):lower(), resumeAt or i + 1, budget - step
    elseif len >= POINTER then
      local low = s:byte(i + 1)
      if not low then return nil end
      local target = (len - POINTER) * 256 + low + 1
      if target >= limit then return nil end
      resumeAt = resumeAt or i + 2
      i, limit = target, target
    elseif len > MAX_LABEL_BYTES then
      return nil -- 0x40..0xBF are reserved label types
    else
      table.insert(labels, s:sub(i + 1, i + len))
      i = i + 1 + len
    end
  end
  return nil
end

local function record(name, rtype, ttl, rdata, cacheFlush)
  return encodeName(name) .. be16(rtype) .. be16(CLASS_IN + (cacheFlush and CACHE_FLUSH or 0))
    .. be32(ttl) .. be16(#rdata) .. rdata
end

local function ipv4Bytes(ip)
  local a, b, c, d = ip:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
  return string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(d))
end

-- service = {type = '_raop._tcp.local', instance = 'AABB@Name', host = 'x.local', port = 7000, txt = {'k=v', ...}}
local function serviceRecords(service, ip)
  local fullName = service.instance .. '.' .. service.type
  local txt = {}
  for _, kv in ipairs(service.txt) do table.insert(txt, string.char(#kv) .. kv) end
  return {
    meta = record(SERVICES_META, TYPE_PTR, TTL_SERVICE, encodeName(service.type)),
    ptr = record(service.type, TYPE_PTR, TTL_SERVICE, encodeName(fullName)),
    srv = record(fullName, TYPE_SRV, TTL_HOST, be16(0) .. be16(0) .. be16(service.port) .. encodeName(service.host), true),
    txt = record(fullName, TYPE_TXT, TTL_SERVICE, table.concat(txt), true),
    a = record(service.host, TYPE_A, TTL_HOST, ipv4Bytes(ip), true),
  }
end

-- Parses a query, its first MAX_QUESTIONS questions at most. Returns nil for responses,
-- malformed packets and packets over the parsing budget.
local function parseQuery(packet)
  if #packet < HEADER_BYTES or u16(packet, 3) >= FLAG_RESPONSE then return nil end
  local questions, i, budget = {}, HEADER_BYTES + 1, MAX_PACKET_STEPS
  for _ = 1, math.min(u16(packet, 5), MAX_QUESTIONS) do
    local name, nextI
    name, nextI, budget = readName(packet, i, budget)
    if not name or nextI + 3 > #packet then return nil end
    table.insert(questions, { name = name, type = u16(packet, nextI), raw = packet:sub(i, nextI + 3) })
    i = nextI + 4
  end
  return { id = packet:sub(1, 2), questions = questions }
end

-- Answers a parsed query for our service, or returns nil when it is about something else.
-- `legacy` is a query from a port other than 5353: it gets the id and questions echoed back.
local function buildAnswer(query, service, ip, legacy)
  local fullName, serviceType, host = (service.instance .. '.' .. service.type):lower(), service.type:lower(), service.host:lower()
  local wants = {}
  for _, q in ipairs(query.questions) do
    local any = q.type == TYPE_ANY
    if q.name == serviceType and (any or q.type == TYPE_PTR) then wants.ptr = true end
    if q.name == fullName and (any or q.type == TYPE_SRV) then wants.srv = true end
    if q.name == fullName and (any or q.type == TYPE_TXT) then wants.txt = true end
    if q.name == host and (any or q.type == TYPE_A) then wants.a = true end
    if q.name == SERVICES_META and q.type == TYPE_PTR then wants.meta = true end
  end
  if not next(wants) then return nil end

  local records = serviceRecords(service, ip)
  local answers, extra = {}, {}
  for _, key in ipairs({ 'meta', 'ptr', 'srv', 'txt', 'a' }) do
    if wants[key] then table.insert(answers, records[key]) end
  end
  -- ship everything needed to connect, so the phone does not have to ask again
  if wants.ptr or wants.srv or wants.txt then
    for _, key in ipairs({ 'srv', 'txt', 'a' }) do
      if not wants[key] then table.insert(extra, records[key]) end
    end
  end

  local questions = {}
  if legacy then
    for _, q in ipairs(query.questions) do table.insert(questions, q.raw) end
  end
  local header = (legacy and query.id or '\0\0') .. be16(FLAGS_AUTHORITATIVE_ANSWER)
    .. be16(#questions) .. be16(#answers) .. be16(0) .. be16(#extra)
  return header .. table.concat(questions) .. table.concat(answers) .. table.concat(extra), wants
end

local function buildSrvQuery(id, name)
  return be16(id) .. be16(0) .. be16(1) .. be16(0) .. be16(0) .. be16(0) .. encodeName(name) .. be16(TYPE_SRV) .. be16(CLASS_IN)
end

-- Returns {[lowercased name] = port} for every SRV record in a response.
local function parseSrvRecords(packet)
  local found = {}
  if #packet < HEADER_BYTES or u16(packet, 3) < FLAG_RESPONSE then return found end
  local questionCount = u16(packet, 5)
  if questionCount > MAX_QUESTIONS then return found end
  local i, budget = HEADER_BYTES + 1, MAX_PACKET_STEPS
  for _ = 1, questionCount do
    local _, nextI
    _, nextI, budget = readName(packet, i, budget)
    if not nextI then return found end
    i = nextI + 4
  end
  local recordCount = u16(packet, 7) + u16(packet, 9) + u16(packet, 11)
  for _ = 1, recordCount do
    local name, nextI
    name, nextI, budget = readName(packet, i, budget)
    if not name or nextI + 9 > #packet then return found end
    local rtype, rdLength = u16(packet, nextI), u16(packet, nextI + 8)
    local rdata = nextI + 10
    if rtype == TYPE_SRV and rdata + 5 <= #packet then found[name] = u16(packet, rdata + 4) end
    i = rdata + rdLength
  end
  return found
end

M.encodeName = encodeName
M.readName = readName
M.parseQuery = parseQuery
M.buildAnswer = buildAnswer
M.buildSrvQuery = buildSrvQuery
M.parseSrvRecords = parseSrvRecords

return M
