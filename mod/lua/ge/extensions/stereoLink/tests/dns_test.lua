local t = require("stereoLink/testlib")
local dns = require("stereoLink/airplay/dns")

local cases = {}

local SERVICE = {
  type = "_raop._tcp.local",
  instance = "0211223344AA@Car",
  host = "BeamNG-0211223344AA.local",
  port = 47000,
  txt = { "txtvers=1", "cn=0,1" },
}

local function bytes(...) return string.char(...) end

-- "_raop._tcp.local" as wire labels
local RAOP_NAME = "\5_raop\4_tcp\5local\0"

local function query(id, name, qtype, qclass)
  return id .. bytes(0, 0, 0, 1, 0, 0, 0, 0, 0, 0) .. name .. bytes(0, qtype, math.floor(qclass / 256), qclass % 256)
end

local function u16(s, i) return s:byte(i) * 256 + s:byte(i + 1) end

function cases.readNameFollowsCompressionPointers()
  -- "local" at offset 0, then "a" + pointer to offset 0
  local packet = "\5local\0" .. "\1a\192\0"
  local name, nextIndex = dns.readName(packet, 8)
  t.eq(name, "a.local")
  t.eq(nextIndex, 12)
end

function cases.readNameLowercases()
  t.eq((dns.readName("\3ABC\0", 1)), "abc")
end

function cases.readNameRejectsTruncatedPacket()
  t.eq(dns.readName("\5loc", 1), nil)
end

function cases.parseQueryIgnoresResponses()
  local response = bytes(0, 0, 0x84, 0, 0, 0, 0, 0, 0, 0, 0, 0)
  t.eq(dns.parseQuery(response), nil)
end

function cases.browseGetsPtrWithEverythingNeededToConnect()
  local q = dns.parseQuery(query("\0\0", RAOP_NAME, 12, 0x8001))
  local answer, wants = dns.buildAnswer(q, SERVICE, "192.168.1.20", false)
  t.truthy(answer)
  t.truthy(wants.ptr)
  t.eq(u16(answer, 3), 0x8400, "flags")
  t.eq(u16(answer, 5), 0, "multicast answers carry no questions")
  t.eq(u16(answer, 7), 1, "answers")
  t.eq(u16(answer, 11), 3, "additional records: SRV, TXT, A")
  t.truthy(answer:find(bytes(192, 168, 1, 20), 1, true), "A record has our address")
  t.eq(dns.parseSrvRecords(answer)["0211223344aa@car._raop._tcp.local"], 47000)
end

function cases.legacyQueryEchoesIdAndQuestion()
  local q = dns.parseQuery(query("\18\52", RAOP_NAME, 12, 1))
  local answer = dns.buildAnswer(q, SERVICE, "10.0.0.5", true)
  t.eq(answer:sub(1, 2), "\18\52")
  t.eq(u16(answer, 5), 1, "question echoed")
end

function cases.unrelatedQueryGetsNoAnswer()
  local q = dns.parseQuery(query("\0\0", "\8_printer\4_tcp\5local\0", 12, 1))
  t.eq(dns.buildAnswer(q, SERVICE, "10.0.0.5", false), nil)
end

function cases.servicesMetaQueryListsRaop()
  local meta = "\9_services\7_dns-sd\4_udp\5local\0"
  local q = dns.parseQuery(query("\0\0", meta, 12, 1))
  local answer = dns.buildAnswer(q, SERVICE, "10.0.0.5", false)
  t.eq(u16(answer, 7), 1, "one answer")
  t.eq(u16(answer, 11), 0, "nothing extra")
  t.eq(answer:sub(13, 12 + #meta), meta, "the answer is about the meta name")
  t.truthy(answer:find(RAOP_NAME, 13 + #meta, true), "pointing at _raop._tcp")
end

-- what an iPhone asks when its cache expired: the instance name keeps its case
function cases.resolveQueryAnswersSrvAndTxtForMixedCaseInstance()
  local instance = "\0160211223344AA@Car" .. RAOP_NAME
  local q = dns.parseQuery(query("\0\0", instance, 255, 0x8001))
  local answer, wants = dns.buildAnswer(q, SERVICE, "10.0.0.5", false)
  t.truthy(wants and wants.srv and wants.txt)
  t.eq(u16(answer, 7), 2, "SRV and TXT")
  t.eq(u16(answer, 11), 1, "plus the A record")
end

function cases.aQueryForOurHostGetsOnlyTheAddress()
  local q = dns.parseQuery(query("\0\0", "\19BeamNG-0211223344AA\5local\0", 1, 1))
  local answer = dns.buildAnswer(q, SERVICE, "10.0.0.5", false)
  t.eq(u16(answer, 7), 1)
  t.eq(u16(answer, 11), 0)
  t.eq(answer:sub(-4), bytes(10, 0, 0, 5))
end

function cases.readNameStopsOnPointerLoop()
  t.eq(dns.readName("\192\0", 1), nil)
end

function cases.readNameRefusesForwardPointer()
  -- a pointer at the start of the packet to "abc" right after it
  t.eq(dns.readName("\192\2\3abc\0", 1), nil)
end

function cases.readNameRefusesPointerThatDoesNotGoFurtherBack()
  -- "\1a" at 1, pointer at 3 back to 1: "a" then the same pointer again, forever
  t.eq(dns.readName("\1a\192\0", 3), nil)
end

function cases.readNameRefusesReservedLabelTypes()
  t.eq(dns.readName("\64" .. string.rep("a", 64) .. "\0", 1), nil)
end

local function manyQuestions(count, name)
  local packet = bytes(0, 0, 0, 0, math.floor(count / 256), count % 256, 0, 0, 0, 0, 0, 0)
  for _ = 1, count do packet = packet .. name .. bytes(0, 12, 0, 1) end
  return packet
end

function cases.parseQueryReadsAtMostThirtyTwoQuestions()
  local q = dns.parseQuery(manyQuestions(40, RAOP_NAME))
  t.truthy(q)
  t.eq(#q.questions, 32)
end

function cases.parseQueryGivesUpOnPacketOverItsBudget()
  -- 32 names of 19 one-letter labels each: 640 label steps, the budget is 512
  local name = string.rep("\1x", 19) .. "\0"
  t.eq(dns.parseQuery(manyQuestions(32, name)), nil)
end

function cases.parseQueryStillAnswersAFullIphoneQuery()
  local q = dns.parseQuery(manyQuestions(16, "\0160211223344AA@Car" .. RAOP_NAME))
  t.truthy(q)
  t.eq(#q.questions, 16)
end

-- a long query from a Mac must still reach the _raop question at the end
function cases.parseQueryReadsALongMacQuery()
  local packet = manyQuestions(31, "\0160211223344AA@Car" .. RAOP_NAME) .. RAOP_NAME .. bytes(0, 12, 0, 1)
  packet = packet:sub(1, 5) .. bytes(32) .. packet:sub(7) -- question count 31 -> 32
  local q = dns.parseQuery(packet)
  t.truthy(q)
  t.eq(#q.questions, 32)
  t.eq(q.questions[32].name, "_raop._tcp.local")
end

function cases.encodeNameRefusesLabelOverSixtyThreeBytes()
  t.eq(dns.encodeName(string.rep("a", 63) .. ".local"), "\63" .. string.rep("a", 63) .. "\5local\0")
  t.errors(function() dns.encodeName(string.rep("a", 64) .. ".local") end)
  t.errors(function() dns.encodeName("iTunes_Ctrl_" .. string.rep("F", 300) .. "._dacp._tcp.local") end)
end

function cases.encodeNameRefusesNameOverTwoHundredFiftyFiveBytes()
  local label = string.rep("a", 60)
  t.errors(function() dns.encodeName(table.concat({ label, label, label, label, label }, ".")) end)
end

-- iOS echoes the question in its answer to a legacy query
function cases.parseSrvRecordsSkipsEchoedQuestion()
  local name = "\13iTunes_Ctrl_X\5_dacp\4_tcp\5local\0"
  local packet = bytes(0, 1, 0x84, 0, 0, 1, 0, 1, 0, 0, 0, 0)
    .. name .. bytes(0, 33, 0, 1)
    .. bytes(192, 12) .. bytes(0, 33, 0, 1, 0, 0, 0, 10, 0, 8)
    .. bytes(0, 0, 0, 0, 0xFC, 0x70) .. bytes(192, 12)
  t.eq(dns.parseSrvRecords(packet)["itunes_ctrl_x._dacp._tcp.local"], 64624)
end

function cases.srvQueryAsksForSrvInClassIn()
  local packet = dns.buildSrvQuery(0x0102, "x.local")
  t.eq(packet, bytes(1, 2, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0) .. "\1x\5local\0" .. bytes(0, 33, 0, 1))
end

function cases.parseSrvRecordsReadsPortFromAnswer()
  local packet = bytes(0, 1, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0)
    .. "\3dev\5local\0" .. bytes(0, 33, 0, 1, 0, 0, 0, 10, 0, 9)
    .. bytes(0, 0, 0, 0, 0xFC, 0x70) .. "\1h\0"
  t.eq(dns.parseSrvRecords(packet)["dev.local"], 64624)
end

function cases.parseSrvRecordsSurvivesGarbage()
  t.eq(next(dns.parseSrvRecords(bytes(0, 0, 0x84, 0, 0, 0, 0, 5, 0, 0, 0, 0, 9))), nil)
end

return cases
