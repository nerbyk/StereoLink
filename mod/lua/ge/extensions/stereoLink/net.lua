-- Local network helpers shared by the sources.

local M = {}

local socket = require('socket')

-- {a, b, c, d} for a dotted IPv4 address, nil for anything else.
local function ipv4Octets(ip)
  local octets = { tostring(ip):match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$') }
  if #octets ~= 4 then return nil end
  for i, text in ipairs(octets) do
    octets[i] = tonumber(text)
    if octets[i] > 255 then return nil end
  end
  return octets
end

-- The address as one 32 bit number.
local function parseIpv4(ip)
  local octets = ipv4Octets(ip)
  if not octets then return nil end
  return ((octets[1] * 256 + octets[2]) * 256 + octets[3]) * 256 + octets[4]
end

local function isUsableIpv4(ip)
  return parseIpv4(ip) ~= nil and not ip:match('^127%.') and not ip:match('^169%.254%.')
end

-- IPv4 addresses of this PC, without loopback and link-local ones.
local function localIpv4s()
  local ips = {}
  local ok, list = pcall(socket.dns.getaddrinfo, socket.dns.gethostname())
  if not ok or type(list) ~= 'table' then return ips end
  for _, entry in ipairs(list) do
    if entry.family == 'inet' and isUsableIpv4(entry.addr) then table.insert(ips, entry.addr) end
  end
  return ips
end

-- The address from `ips` that shares the longest prefix with `peer`, i.e. the adapter the phone
-- is on. Matters on PCs with VPN / virtual adapters.
local function pickLocalIp(ips, peer)
  local peerNum = parseIpv4(peer)
  local best, bestBits = ips[1], -1
  if not peerNum then return best end
  for _, ip in ipairs(ips) do
    local num, bits = parseIpv4(ip), 0
    for bit = 31, 0, -1 do
      local mask = 2 ^ bit
      if math.floor(num / mask) % 2 ~= math.floor(peerNum / mask) % 2 then break end
      bits = bits + 1
    end
    if bits > bestBits then best, bestBits = ip, bits end
  end
  return best
end

M.ipv4Octets = ipv4Octets
M.parseIpv4 = parseIpv4
M.localIpv4s = localIpv4s
M.pickLocalIp = pickLocalIp

return M
