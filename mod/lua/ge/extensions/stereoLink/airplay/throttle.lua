-- Rate limits for things that come faster than they should go out: log lines about misbehaving
-- devices on the network, volume requests to the phone. Pure, the caller passes the time.

local M = {}

local INTERVAL = 60
local MAX_PEERS = 32

-- Returns allow(peer, now): true at most once per INTERVAL seconds for each peer. The table of
-- peers is reset rather than left to grow when many addresses misbehave.
local function perPeer()
  local lastAt, count = {}, 0
  return function(peer, now)
    local last = lastAt[peer]
    if last and now - last < INTERVAL then return false end
    if not last then
      if count >= MAX_PEERS then lastAt, count = {}, 0 end
      count = count + 1
    end
    lastAt[peer] = now
    return true
  end
end

M.INTERVAL = INTERVAL
M.MAX_PEERS = MAX_PEERS
M.perPeer = perPeer

return M
