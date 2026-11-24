-- Addon-message transport (design doc §8).
--
-- Wire format, one addon message per chunk (Forever silently truncates messages at 255 bytes):
--   "<protocol>:<messageId>:<index>:<count>:<data>"
-- The reassembled data is a serialized envelope { p = protocol, t = type, v = addon version, b = body }.
--
-- Safety: senders are normalized "First Last" names; our own echoes are ignored; per-sender rate limits,
-- bounded reassembly buffers and strict decoding protect against malformed or abusive input. Whispers go
-- only to guild members the roster shows online, and the "No player named ..." system error is hidden for
-- whispers we just sent (a failed whisper would otherwise print in the sender's chat).
local _, CH = ...

local Comm = {
    PREFIX = "CasualHub",
    PROTOCOL = 1,
    MAX_WIRE = 255,
    MAX_CHUNKS = 32,
    BURST = 8,              -- tokens; the client allows roughly 10 messages per prefix before throttling
    RATE = 1,               -- tokens regained per second
    handlers = {},
    queue = {},
    bulkQueue = {},          -- low priority (e.g. price packs): sent only when `queue` is empty
    buffers = {},
    bufferCount = {},
    peers = {},
    recentWhispers = {},
    senderWindow = {},
    stats = { sent = 0, sentChunks = 0, received = 0, receivedChunks = 0, malformed = 0, dropped = 0,
        throttled = 0, sendErrors = 0, skippedOffline = 0, rateLimited = 0, otherProtocol = 0, unknownType = 0 },
}
CH.Comm = Comm

local SENDER_CHUNKS_PER_MINUTE = 240
local MAX_BUFFERS_PER_SENDER = 6
local BUFFER_TIMEOUT = 60
local WHISPER_ERROR_WINDOW = 15

local Stats = Comm.stats

---------------------------------------------------------------------------
-- Message ids
---------------------------------------------------------------------------

local ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyz"
local function base36(n)
    local out = ""
    repeat
        local d = n % 36
        out = ALPHABET:sub(d + 1, d + 1) .. out
        n = math.floor(n / 36)
    until n == 0
    return out
end

local counter = math.random(0, 36 * 36 - 1) * 1000
function Comm:NextId()
    counter = (counter + 1) % (36 ^ 5)
    return base36(counter)
end

---------------------------------------------------------------------------
-- Encoding to wire chunks (also used by the offline tests to impersonate peers)
---------------------------------------------------------------------------

function Comm:EncodeWire(msgType, body)
    local data, err = CH.Serializer.Encode({ p = self.PROTOCOL, t = msgType, v = CH.version, b = body })
    if not data then return nil, err end
    local id = self:NextId()
    local headerMax = #(self.PROTOCOL .. ":" .. id .. ":" .. self.MAX_CHUNKS .. ":" .. self.MAX_CHUNKS .. ":")
    local per = self.MAX_WIRE - headerMax
    local count = math.max(1, math.ceil(#data / per))
    if count > self.MAX_CHUNKS then return nil, "message too large (" .. #data .. " bytes)" end
    local chunks = {}
    for i = 1, count do
        chunks[i] = self.PROTOCOL .. ":" .. id .. ":" .. i .. ":" .. count .. ":" .. data:sub((i - 1) * per + 1, i * per)
    end
    return chunks
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local function now() return GetTime() end

-- channel: "GUILD" or "WHISPER" (target = "First Last"). bulk = true queues behind everything else.
-- Returns true when queued.
function Comm:Send(msgType, body, channel, target, bulk)
    if not self.enabled then return false end
    if channel == "WHISPER" then
        target = CH.Identity:Normalize(target)
        if not target or not CH.Roster:IsOnline(target) then
            Stats.skippedOffline = Stats.skippedOffline + 1
            return false
        end
    elseif channel == "GUILD" then
        if not (IsInGuild and IsInGuild()) then return false end
    else
        return false
    end
    local chunks, err = self:EncodeWire(msgType, body)
    if not chunks then
        CH.Log:Error("could not send %s: %s", tostring(msgType), tostring(err))
        return false
    end
    local q = bulk and self.bulkQueue or self.queue
    for _, text in ipairs(chunks) do
        q[#q + 1] = { text = text, channel = channel, target = target }
    end
    Stats.sent = Stats.sent + 1
    CH.Log:Debug("send %s (%d chunk%s) %s%s", msgType, #chunks, #chunks == 1 and "" or "s", channel,
        target and (" " .. target) or "")
    self:Pump()
    return true
end

local function resultName(result)
    local enum = Enum and Enum.SendAddonMessageResult
    if type(enum) ~= "table" then return nil end
    for k, v in pairs(enum) do
        if v == result then return k end
    end
end

local function inLockdown()
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
        local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
        return ok and locked == true
    end
    return false
end

function Comm:SchedulePump(delay)
    if self.pumpScheduled then return end
    self.pumpScheduled = true
    C_Timer.After(delay, function()
        self.pumpScheduled = false
        self:Pump()
    end)
end

function Comm:Pump()
    local t = now()
    self.tokens = math.min(self.BURST, (self.tokens or self.BURST) + (t - (self.lastRefill or t)) * self.RATE)
    self.lastRefill = t
    if #self.queue == 0 and #self.bulkQueue == 0 then return end
    if inLockdown() then
        self:SchedulePump(5)
        return
    end
    while (#self.queue > 0 or #self.bulkQueue > 0) and self.tokens >= 1 do
        local q = #self.queue > 0 and self.queue or self.bulkQueue
        local m = table.remove(q, 1)
        if m.channel == "WHISPER" and not CH.Roster:IsOnline(m.target) then
            Stats.skippedOffline = Stats.skippedOffline + 1
        else
            if m.channel == "WHISPER" then self.recentWhispers[m.target] = t end
            local ok, result = pcall(C_ChatInfo.SendAddonMessage, self.PREFIX, m.text, m.channel, m.target)
            if not ok then
                Stats.sendErrors = Stats.sendErrors + 1
                CH.Log:Warn("SendAddonMessage failed: %s", tostring(result))
            elseif result ~= nil and result ~= 0 and result ~= true then
                local name = resultName(result) or tostring(result)
                if name:find("Throttle") then
                    Stats.throttled = Stats.throttled + 1
                    table.insert(q, 1, m)
                    self.tokens = 0
                    break
                end
                Stats.sendErrors = Stats.sendErrors + 1
                CH.Log:Warn("addon message not sent: %s", name)
            else
                self.tokens = self.tokens - 1
                Stats.sentChunks = Stats.sentChunks + 1
            end
        end
    end
    if #self.queue > 0 or #self.bulkQueue > 0 then self:SchedulePump(1 / self.RATE) end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

function Comm:RegisterHandler(msgType, fn)
    self.handlers[msgType] = fn
end

local function rateLimited(sender, t)
    local w = Comm.senderWindow[sender]
    if not w or t - w.start >= 60 then
        w = { start = t, n = 0 }
        Comm.senderWindow[sender] = w
    end
    w.n = w.n + 1
    return w.n > SENDER_CHUNKS_PER_MINUTE
end

function Comm:ExpireBuffers(t)
    for key, buf in pairs(self.buffers) do
        if t - buf.started > BUFFER_TIMEOUT then
            self.buffers[key] = nil
            self.bufferCount[buf.sender] = (self.bufferCount[buf.sender] or 1) - 1
            Stats.dropped = Stats.dropped + 1
        end
    end
end

function Comm:OnMessage(prefix, text, channel, sender)
    if prefix ~= self.PREFIX then return end
    if CH.Compat.IsSecret(text) or CH.Compat.IsSecret(sender) or type(text) ~= "string" then return end
    if channel ~= "GUILD" and channel ~= "WHISPER" then return end
    sender = CH.Identity:Normalize(sender)
    if not sender or CH.Identity:IsPlayer(sender) then return end  -- own GUILD echo
    local t = now()
    if rateLimited(sender, t) then
        Stats.rateLimited = Stats.rateLimited + 1
        return
    end
    Stats.receivedChunks = Stats.receivedChunks + 1

    local proto, id, index, count, data = text:match("^(%d+):(%w+):(%d+):(%d+):(.*)$")
    if not proto then
        Stats.malformed = Stats.malformed + 1
        return
    end
    proto, index, count = tonumber(proto), tonumber(index), tonumber(count)
    if proto ~= self.PROTOCOL then
        Stats.otherProtocol = Stats.otherProtocol + 1
        return
    end
    if count < 1 or count > self.MAX_CHUNKS or index < 1 or index > count or #id > 8 then
        Stats.malformed = Stats.malformed + 1
        return
    end
    if count == 1 then
        self:Deliver(sender, data, channel)
        return
    end

    self:ExpireBuffers(t)
    local key = sender .. "\n" .. id
    local buf = self.buffers[key]
    if not buf then
        if (self.bufferCount[sender] or 0) >= MAX_BUFFERS_PER_SENDER then
            Stats.dropped = Stats.dropped + 1
            return
        end
        buf = { sender = sender, count = count, got = 0, parts = {}, started = t }
        self.buffers[key] = buf
        self.bufferCount[sender] = (self.bufferCount[sender] or 0) + 1
    elseif buf.count ~= count then
        Stats.malformed = Stats.malformed + 1
        return
    end
    if not buf.parts[index] then
        buf.parts[index] = data
        buf.got = buf.got + 1
    end
    if buf.got == buf.count then
        self.buffers[key] = nil
        self.bufferCount[sender] = self.bufferCount[sender] - 1
        self:Deliver(sender, table.concat(buf.parts), channel)
    end
end

function Comm:Deliver(sender, data, channel)
    local env = CH.Serializer.Decode(data)
    if type(env) ~= "table" or env.p ~= self.PROTOCOL or type(env.t) ~= "string" then
        Stats.malformed = Stats.malformed + 1
        return
    end
    local peer = self.peers[sender]
    if not peer then
        peer = {}
        self.peers[sender] = peer
    end
    peer.version = CH.CleanText(tostring(env.v), 24)
    peer.lastSeen = time()
    local handler = self.handlers[env.t]
    if not handler then
        Stats.unknownType = Stats.unknownType + 1
        return
    end
    Stats.received = Stats.received + 1
    CH.Log:Debug("recv %s from %s via %s", env.t, sender, channel)
    CH.SafeCall("handle " .. env.t, handler, sender, env.b, channel)
end

-- Players seen running Casual Hub this session: name -> { version, lastSeen }.
function Comm:Peer(name)
    return self.peers[name]
end

function Comm:PeerCount(onlineOnly)
    local n = 0
    for name in pairs(self.peers) do
        if not onlineOnly or CH.Roster:IsOnline(name) then n = n + 1 end
    end
    return n
end

---------------------------------------------------------------------------
-- "No player named '%s' is currently playing." suppression for our own whispers
---------------------------------------------------------------------------

local function buildNotFoundPattern()
    local fmt = ERR_CHAT_PLAYER_NOT_FOUND_S
    if type(fmt) ~= "string" or not fmt:find("%s", 1, true) then return nil end
    local escaped = fmt:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0")
    return "^" .. escaped:gsub("%%s", "(.+)") .. "$"
end

function Comm:IsOwnWhisperError(msg)
    if not self.notFoundPattern or type(msg) ~= "string" or CH.Compat.IsSecret(msg) then return false end
    local name = msg:match(self.notFoundPattern)
    name = name and CH.Identity:Normalize(name)
    local sentAt = name and self.recentWhispers[name]
    return sentAt ~= nil and now() - sentAt <= WHISPER_ERROR_WINDOW
end

local function installChatFilter()
    Comm.notFoundPattern = buildNotFoundPattern()
    if not Comm.notFoundPattern then return end
    local filter = function(_, _, msg) return Comm:IsOwnWhisperError(msg) end
    if ChatFrame_AddMessageEventFilter then
        ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", filter)
    elseif ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter then
        ChatFrameUtil.AddMessageEventFilter("CHAT_MSG_SYSTEM", filter)
    else
        CH.Log:Warn("no chat filter API; failed-whisper errors may show in chat")
    end
end

---------------------------------------------------------------------------

function Comm:Init()
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage and C_ChatInfo.RegisterAddonMessagePrefix) then
        CH.Log:Warn("addon messaging unavailable; sync disabled")
        return
    end
    local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, self.PREFIX)
    if not ok or (result ~= nil and result ~= 0 and result ~= true) then
        CH.Log:Error("could not register addon prefix %s: %s", self.PREFIX, tostring(resultName(result) or result))
        return
    end
    self.enabled = true
    CH.Events:RegisterGameEvent("CHAT_MSG_ADDON", "Comm", function(...) Comm:OnMessage(...) end)
    CH.SafeCall("install chat filter", installChatFilter)
end
