-- mDNS responder that advertises the AirPlay speaker, plus one-off SRV lookups.
--
-- The game's network sandbox refuses to send to multicast addresses, so every answer goes
-- straight to the asking device. Apple devices accept such answers for a couple of seconds
-- after a query with the "unicast response" bit, and every new browse (opening the AirPlay
-- picker) starts with one.

local M = {}

local socket = require('socket')
local dns = require('stereoLink/airplay/dns')
local throttle = require('stereoLink/airplay/throttle')
local net = require('stereoLink/net')

local MDNS_PORT = 5353
local MDNS_GROUP = '224.0.0.251'
local LOOKUP_TIMEOUT = 3
local LOOKUP_RESEND = 0.7
local ADDRESS_REFRESH = 15
local MAX_QUERIES_PER_FRAME = 64
local MAX_LOOKUP_REPLIES_PER_FRAME = 8

local responder, lookupSocket
local service
local localIps = {}
local addressesReadAt = 0
local mayReport = throttle.perPeer()
local lookups = {}
local sawAnyTraffic = false

local function isOwnAddress(ip)
  for _, mine in ipairs(localIps) do
    if mine == ip then return true end
  end
  return false
end

-- A broken sender cannot flood the log: see throttle.perPeer.
local function reportBadPacket(ip, err)
  if not mayReport(ip, socket.gettime()) then return end
  log('W', 'stereoLink.mdns', 'bad packet from ' .. tostring(ip) .. ': ' .. tostring(err))
end

local function answer(packet, fromIp, fromPort)
  local query = dns.parseQuery(packet)
  if not query then return end
  local ip = net.pickLocalIp(localIps, fromIp)
  if not ip then return end
  local reply = dns.buildAnswer(query, service, ip, fromPort ~= MDNS_PORT)
  if not reply then return end
  responder:sendto(reply, fromIp, fromPort)
end

-- Re-reads the PC's addresses (Wi-Fi may connect after the game started) and joins the
-- mDNS group on all of them: a Wi-Fi reconnect drops the membership even when the address
-- stays the same. Joining twice only fails, hence the pcall.
local function refreshAddresses(udp)
  localIps = net.localIpv4s()
  for _, ip in ipairs(localIps) do
    pcall(udp.setoption, udp, 'ip-add-membership', { multiaddr = MDNS_GROUP, interface = ip })
  end
  addressesReadAt = socket.gettime()
end

-- svc: see dns.buildAnswer.
local function start(svc)
  service = svc
  if responder then return true end
  localIps = {}

  local udp = socket.udp()
  udp:setoption('reuseaddr', true) -- Windows' own mDNS service already listens on 5353
  local ok, err = udp:setsockname('*', MDNS_PORT)
  if not ok then
    udp:close()
    return false, 'mDNS port ' .. MDNS_PORT .. ': ' .. tostring(err)
  end
  refreshAddresses(udp)
  udp:settimeout(0)
  responder = udp
  return true
end

local function stop()
  if responder then responder:close() end
  if lookupSocket then lookupSocket:close() end
  responder, lookupSocket = nil, nil
  lookups = {}
end

-- Asks one device for the port of `name` and calls cb(port) or cb(nil) after a timeout.
-- The query goes out from an ephemeral port ("legacy unicast"); iOS ignores direct
-- queries coming from port 5353 but always answers these.
local function lookupSrv(name, ip, cb)
  local packet = dns.buildSrvQuery(math.random(1, 65535), name)
  if not lookupSocket then
    lookupSocket = socket.udp()
    lookupSocket:setsockname('*', 0)
    lookupSocket:settimeout(0)
  end
  lookups[name:lower()] = {
    ip = ip,
    cb = cb,
    packet = packet,
    deadline = socket.gettime() + LOOKUP_TIMEOUT,
    sentAt = 0,
  }
end

local function readLookupReplies()
  for _ = 1, MAX_LOOKUP_REPLIES_PER_FRAME do
    local packet, fromIp = lookupSocket:receivefrom()
    if not packet then break end
    local ok, records = pcall(dns.parseSrvRecords, packet)
    for name, port in pairs(ok and records or {}) do
      local lookup = lookups[name]
      if lookup and lookup.ip == fromIp then
        lookups[name] = nil
        lookup.cb(port)
      end
    end
  end
end

local function updateLookups()
  readLookupReplies()
  local now = socket.gettime()
  for name, lookup in pairs(lookups) do
    if now > lookup.deadline then
      lookups[name] = nil
      lookup.cb(nil)
    elseif now - lookup.sentAt > LOOKUP_RESEND then
      lookup.sentAt = now
      lookupSocket:sendto(lookup.packet, lookup.ip, MDNS_PORT)
    end
  end
end

local function update()
  if not responder then return end
  if socket.gettime() - addressesReadAt > ADDRESS_REFRESH then refreshAddresses(responder) end
  for _ = 1, MAX_QUERIES_PER_FRAME do
    local packet, ip, port = responder:receivefrom()
    if not packet then break end
    if not isOwnAddress(ip) then
      sawAnyTraffic = true
      local ok, err = pcall(answer, packet, ip, port)
      if not ok then reportBadPacket(ip, err) end
    end
  end
  if next(lookups) then updateLookups() end
end

-- Whether any other device has sent mDNS since start: tells "no network" from "no phone".
local function sawTraffic() return sawAnyTraffic end

M.start = start
M.stop = stop
M.update = update
M.lookupSrv = lookupSrv
M.sawTraffic = sawTraffic

return M
