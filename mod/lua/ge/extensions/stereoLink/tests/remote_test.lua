local t = require("stereoLink/testlib")
local remote = require("stereoLink/airplay/remote")

local cases = {}

function cases.statusCodeOfAnHttpReply()
  t.eq(remote.statusCode("HTTP/1.1 204 No Content\r\nDate: x\r\n\r\n"), 204)
  t.eq(remote.statusCode("HTTP/1.1 403 Forbidden\r\n\r\n"), 403)
  t.eq(remote.statusCode("HTTP/1.1 20"), nil, "the status line is not complete yet")
  t.eq(remote.statusCode(""), nil)
  t.eq(remote.statusCode("garbage"), nil)
end

function cases.remoteServiceNameKeepsTheLeadingZero()
  t.eq(remote.remoteServiceName("8EBBB305E5510E1"), "iTunes_Ctrl_08EBBB305E5510E1._dacp._tcp.local")
  t.eq(remote.remoteServiceName("18EBBB305E5510E1"), "iTunes_Ctrl_18EBBB305E5510E1._dacp._tcp.local")
end

function cases.targetFromAnIphoneIsValid()
  t.truthy(remote.isValidTarget("0123456789ABCDEF", "1234567890"))
end

function cases.targetRefusesLongDacpId()
  t.falsy(remote.isValidTarget(string.rep("A", 17), "1"))
  t.falsy(remote.isValidTarget(string.rep("A", 300), "1"), "would not fit a DNS label")
end

function cases.targetRefusesDacpIdThatIsNotHex()
  t.falsy(remote.isValidTarget("ABC.local", "1"))
  t.falsy(remote.isValidTarget("", "1"))
  t.falsy(remote.isValidTarget(nil, "1"))
end

function cases.targetRefusesActiveRemoteThatIsNotAShortNumber()
  t.falsy(remote.isValidTarget("AB", "1\r\nX-Injected: 1"), "header injection")
  t.falsy(remote.isValidTarget("AB", "12345678901"))
  t.falsy(remote.isValidTarget("AB", nil))
end

return cases
