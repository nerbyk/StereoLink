local t = require("stereoLink/testlib")
local net = require("stereoLink/net")

local cases = {}

function cases.parseIpv4ReadsDottedQuad()
  t.eq(net.parseIpv4("192.168.1.2"), 3232235778)
  t.eq(net.parseIpv4("fe80::1"), nil)
  t.eq(net.parseIpv4(nil), nil)
end

function cases.pickLocalIpPrefersThePhonesSubnet()
  local ips = { "26.72.2.127", "172.30.144.1", "192.168.88.253", "192.168.183.1" }
  t.eq(net.pickLocalIp(ips, "192.168.88.40"), "192.168.88.253")
  t.eq(net.pickLocalIp(ips, "172.30.150.9"), "172.30.144.1")
end

function cases.pickLocalIpFallsBackToFirstAddress()
  t.eq(net.pickLocalIp({ "10.0.0.2", "10.0.0.3" }, "not an ip"), "10.0.0.2")
  t.eq(net.pickLocalIp({}, "10.0.0.9"), nil)
end

function cases.ipv4OctetsSplitsADottedQuad()
  local octets = net.ipv4Octets("192.168.1.2")
  t.eq(#octets, 4)
  t.eq(octets[1], 192)
  t.eq(octets[4], 2)
  t.eq(net.ipv4Octets("256.1.1.1"), nil, "octet out of range")
  t.eq(net.ipv4Octets("1.2.3"), nil)
  t.eq(net.ipv4Octets(nil), nil)
end

function cases.parseIpv4RejectsOctetsOutOfRange()
  t.eq(net.parseIpv4("300.1.1.1"), nil)
end

return cases
