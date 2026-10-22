local t = require("stereoLink/testlib")
local rtsp = require("stereoLink/airplay/rtsp")

local cases = {}

local OPTIONS = "OPTIONS * RTSP/1.0\r\nCSeq: 3\r\nApple-Challenge: abc\r\n\r\n"

function cases.parseRequestReadsMethodAndLowercasedHeaders()
  local request, rest = rtsp.parseRequest(OPTIONS)
  t.eq(request.method, "OPTIONS")
  t.eq(request.uri, "*")
  t.eq(request.headers["cseq"], "3")
  t.eq(request.headers["apple-challenge"], "abc")
  t.eq(request.body, "")
  t.eq(rest, "")
end

function cases.parseRequestWaitsForTheWholeHead()
  local request, rest = rtsp.parseRequest("OPTIONS * RTSP/1.0\r\nCSeq: 3\r\n")
  t.eq(request, nil)
  t.eq(rest, "OPTIONS * RTSP/1.0\r\nCSeq: 3\r\n")
end

function cases.parseRequestWaitsForTheWholeBody()
  local partial = "SET_PARAMETER x RTSP/1.0\r\nContent-Length: 10\r\n\r\nvolume"
  t.eq((rtsp.parseRequest(partial)), nil)
end

function cases.parseRequestSplitsPipelinedRequests()
  local first = "SET_PARAMETER x RTSP/1.0\r\nContent-Length: 6\r\n\r\nvolume"
  local request, rest = rtsp.parseRequest(first .. OPTIONS)
  t.eq(request.body, "volume")
  t.eq(rest, OPTIONS)
end

function cases.parseRequestRejectsNegativeContentLength()
  local request, rest, err = rtsp.parseRequest("OPTIONS * RTSP/1.0\r\nCSeq: 1\r\nContent-Length: -99999\r\n\r\n")
  t.eq(request, nil)
  t.eq(rest, nil, "must not hand the same buffer back, the caller would loop forever")
  t.eq(err, "bad Content-Length")
end

function cases.parseRequestRejectsHugeBody()
  local _, _, err = rtsp.parseRequest("POST x RTSP/1.0\r\nContent-Length: 999999999\r\n\r\n")
  t.eq(err, "bad Content-Length")
end

function cases.parseRequestRejectsEndlessHead()
  local _, _, err = rtsp.parseRequest(string.rep("x", rtsp.MAX_HEAD_BYTES + 1))
  t.eq(err, "request head too large")
end

function cases.parseRequestRejectsGarbageRequestLine()
  local _, _, err = rtsp.parseRequest("\r\n\r\n")
  t.eq(err, "malformed request line")
end

function cases.formatResponseKeepsHeaderOrderAndAddsLength()
  local response = rtsp.formatResponse("7", 200, "OK", { { "A", "1" }, { "B", "2" } }, "xy")
  t.eq(response, "RTSP/1.0 200 OK\r\nCSeq: 7\r\nServer: AirTunes/105.1\r\nA: 1\r\nB: 2\r\nContent-Length: 2\r\n\r\nxy")
end

function cases.parseSdpReadsAttributes()
  local sdp = rtsp.parseSdp("v=0\r\nm=audio 0 RTP/AVP 96\r\na=rtpmap:96 AppleLossless\r\na=fmtp:96 352 0 16\r\na=aesiv:SVY=\r\n")
  t.eq(sdp.rtpmap, "96 AppleLossless")
  t.eq(sdp.fmtp, "96 352 0 16")
  t.eq(sdp.aesiv, "SVY=")
end

function cases.parseTransportReadsPorts()
  local transport = rtsp.parseTransport("RTP/AVP/UDP;unicast;mode=record;control_port=6001;timing_port=6002")
  t.eq(transport.controlPort, 6001)
  t.eq(transport.timingPort, 6002)
end

function cases.parseTransportToleratesMissingHeader()
  t.eq(rtsp.parseTransport(nil).controlPort, nil)
end

function cases.parseParametersReadsVolumeAndProgress()
  t.eq(rtsp.parseParameters("volume: -11.250000\r\n").volume, -11.25)
  local progress = rtsp.parseParameters("progress: 100/44200/441100\r\n").progress
  t.eq(progress[1], 100)
  t.eq(progress[2], 44200)
  t.eq(progress[3], 441100)
end

local function dmapItem(tag, value)
  local n = #value
  return tag .. string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256) .. value
end

function cases.trackInfoReadsNestedDmap()
  local body = dmapItem("mlit", dmapItem("minm", "Song") .. dmapItem("asar", "Artist") .. dmapItem("asal", "Album"))
  local info = rtsp.trackInfo(body)
  t.eq(info.title, "Song")
  t.eq(info.artist, "Artist")
  t.eq(info.album, "Album")
end

function cases.trackInfoSurvivesTruncatedData()
  local info = rtsp.trackInfo("minm\0\0\0\50Song")
  t.eq(info.title, "Song")
end

function cases.trackInfoReadsContainerLyingAboutItsLength()
  local body = "mlit\255\255\255\255" .. dmapItem("minm", "Song") .. dmapItem("asar", "Artist")
  local info = rtsp.trackInfo(body)
  t.eq(info.title, "Song")
  t.eq(info.artist, "Artist")
end

function cases.trackInfoKeepsAnItemInsideItsContainer()
  -- minm claims 100 bytes but its container ends after "Song"; asar after the container is its own item
  local inner = "minm\0\0\0\100Song"
  local body = "mlit" .. string.char(0, 0, 0, #inner) .. inner .. dmapItem("asar", "Artist")
  local info = rtsp.trackInfo(body)
  t.eq(info.title, "Song")
  t.eq(info.artist, "Artist")
end

function cases.parseDmapIgnoresContainersNestedTooDeep()
  local body = dmapItem("minm", "Song")
  for _ = 1, 5 do body = dmapItem("mlit", body) end
  t.eq(rtsp.trackInfo(body).title, nil)
end

-- nested containers that all claim the rest of the body: copies per level used to eat gigabytes
function cases.parseDmapSurvivesNestingBomb()
  local body = string.rep("mlit\255\255\255\255", 4000) .. dmapItem("minm", "Song")
  t.eq(rtsp.trackInfo(body).title, nil)
end

function cases.parseDmapIgnoresOversizedBody()
  local body = dmapItem("minm", "Song") .. dmapItem("xxxx", string.rep("x", rtsp.MAX_DMAP_BYTES))
  t.eq(rtsp.trackInfo(body).title, nil)
end

local FMTP = "96 352 0 16 40 10 14 2 255 0 0 44100"

function cases.parseFmtpReadsWhatTheDecoderNeeds()
  local fmtp = rtsp.parseFmtp(FMTP)
  t.eq(fmtp.frameLength, 352)
  t.eq(fmtp.sampleSize, 16)
  t.eq(fmtp.channels, 2)
  t.eq(fmtp.sampleRate, 44100)
  t.eq(rtsp.parseFmtp("96 4096 0 16 40 10 14 2 255 0 0 48000").sampleRate, 48000)
end

function cases.parseFmtpRefusesHugeFrameLength()
  local fmtp, err = rtsp.parseFmtp("96 1000000000 0 16 40 10 14 2 255 0 0 44100")
  t.eq(fmtp, nil)
  t.truthy(err)
  t.eq((rtsp.parseFmtp("96 0 0 16 40 10 14 2 255 0 0 44100")), nil, "zero frame length")
  t.eq((rtsp.parseFmtp("96 4097 0 16 40 10 14 2 255 0 0 44100")), nil, "one over the limit")
end

function cases.parseFmtpRefusesFormatsThePlayerDoesNotHandle()
  t.eq((rtsp.parseFmtp("96 352 0 24 40 10 14 2 255 0 0 44100")), nil, "24 bit")
  t.eq((rtsp.parseFmtp("96 352 0 16 40 10 14 1 255 0 0 44100")), nil, "mono")
  t.eq((rtsp.parseFmtp("96 352 0 16 40 10 14 2 255 0 0 1")), nil, "1 Hz")
  t.eq((rtsp.parseFmtp("96 352 0 16 40 10 14 2 255 0 0 96000")), nil, "96 kHz")
end

function cases.parseFmtpRefusesMalformedValues()
  t.eq((rtsp.parseFmtp(nil)), nil, "missing")
  t.eq((rtsp.parseFmtp("")), nil, "empty")
  t.eq((rtsp.parseFmtp("96 352 0 16")), nil, "too few fields")
  t.eq((rtsp.parseFmtp(FMTP .. " 1")), nil, "too many fields")
  t.eq((rtsp.parseFmtp("96 -352 0 16 40 10 14 2 255 0 0 44100")), nil, "negative")
  t.eq((rtsp.parseFmtp("96 3.5e2 0 16 40 10 14 2 255 0 0 44100")), nil, "not an integer")
end

function cases.parseRtpInfoReadsTheNextSequence()
  t.eq(rtsp.parseRtpInfo("seq=1234;rtptime=5678"), 1234)
  t.eq(rtsp.parseRtpInfo(nil), nil)
  t.eq(rtsp.parseRtpInfo("seq=70000"), nil, "out of the 16 bit range")
end

function cases.coverTypeTakesOnlyPlainImages()
  t.eq(rtsp.coverType("image/jpeg"), "image/jpeg")
  t.eq(rtsp.coverType("Image/PNG"), "image/png")
  t.eq(rtsp.coverType("image/none"), nil)
  t.eq(rtsp.coverType("image/svg+xml"), nil)
  t.eq(rtsp.coverType("image/jpeg);background:url(http://x/"), "image/jpeg", "only the clean type is kept")
  t.eq(rtsp.coverType(nil), nil)
end

return cases
