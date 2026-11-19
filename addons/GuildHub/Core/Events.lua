-- Internal publish/subscribe bus plus a single game-event frame.
-- Handlers are keyed by an owner string (normally the module name) and receive the event's arguments only.
local _, GH = ...

local Events = { handlers = {}, game = {}, unsupported = {} }
GH.Events = Events

local function dispatch(list, label, ...)
    if not list then return end
    -- Snapshot so handlers may subscribe or unsubscribe while dispatching.
    local snapshot = {}
    for owner, fn in pairs(list) do snapshot[#snapshot + 1] = { owner, fn } end
    for _, pair in ipairs(snapshot) do
        GH.SafeCall(label .. " -> " .. tostring(pair[1]), pair[2], ...)
    end
end

function Events:Subscribe(event, owner, fn)
    assert(type(owner) == "string", "Subscribe owner must be a string")
    self.handlers[event] = self.handlers[event] or {}
    self.handlers[event][owner] = fn
end

function Events:Unsubscribe(event, owner)
    local list = self.handlers[event]
    if list then list[owner] = nil end
end

function Events:Publish(event, ...)
    dispatch(self.handlers[event], event, ...)
end

---------------------------------------------------------------------------
-- Game events
---------------------------------------------------------------------------

local frame = CreateFrame("Frame")

-- Returns false (and records why) when the client does not know the event.
function Events:RegisterGameEvent(event, owner, fn)
    assert(type(owner) == "string", "RegisterGameEvent owner must be a string")
    local list = self.game[event]
    if not list then
        local ok, err = pcall(frame.RegisterEvent, frame, event)
        if not ok then
            self.unsupported[event] = tostring(err)
            GH.Log:Warn("game event %s is not supported by this client", event)
            return false
        end
        list = {}
        self.game[event] = list
    end
    list[owner] = fn
    return true
end

function Events:UnregisterGameEvent(event, owner)
    local list = self.game[event]
    if not list then return end
    list[owner] = nil
    if next(list) == nil then
        frame:UnregisterEvent(event)
        self.game[event] = nil
    end
end

frame:SetScript("OnEvent", function(_, event, ...)
    dispatch(Events.game[event], event, ...)
end)
