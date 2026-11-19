-- Compact, deterministic serializer for addon messages.
--
-- Our own format instead of C_EncodingUtil keeps the wire format fully specified, testable offline, and
-- independent of client API changes. Grammar:
--   s<len>:<bytes>   string        i<digits>;  integer        f<number>;  float
--   T / F            boolean       t <key value>* e           table (keys: strings or numbers)
-- Decoding is defensive: bounded depth and item count, strict lengths, no trailing data.
local _, CH = ...

local Serializer = {}
CH.Serializer = Serializer

local MAX_DEPTH = 8
local MAX_ITEMS = 4000

local function keyLess(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta == "number" end
    return a < b
end

local function encode(v, out, depth)
    local t = type(v)
    if t == "string" then
        out[#out + 1] = "s" .. #v .. ":" .. v
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then error("cannot serialize NaN or infinity") end
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
            out[#out + 1] = "i" .. string.format("%.0f", v) .. ";"
        else
            out[#out + 1] = "f" .. string.format("%.17g", v) .. ";"
        end
    elseif t == "boolean" then
        out[#out + 1] = v and "T" or "F"
    elseif t == "table" then
        if depth >= MAX_DEPTH then error("table nested too deeply") end
        local keys = {}
        for k in pairs(v) do
            local kt = type(k)
            if kt ~= "string" and kt ~= "number" then error("unsupported key type " .. kt) end
            keys[#keys + 1] = k
        end
        table.sort(keys, keyLess)
        out[#out + 1] = "t"
        for _, k in ipairs(keys) do
            encode(k, out, depth + 1)
            encode(v[k], out, depth + 1)
        end
        out[#out + 1] = "e"
    else
        error("cannot serialize " .. t)
    end
end

function Serializer.Encode(value)
    local out = {}
    local ok, err = pcall(encode, value, out, 0)
    if not ok then return nil, err end
    return table.concat(out)
end

local function decode(s, pos, depth, budget)
    local tag = s:sub(pos, pos)
    if tag == "s" then
        local colon = s:find(":", pos + 1, true)
        if not colon or colon - pos > 7 then error("bad string header") end
        local len = tonumber(s:sub(pos + 1, colon - 1))
        if not len or len < 0 or len % 1 ~= 0 then error("bad string length") end
        local last = colon + len
        if last > #s then error("truncated string") end
        return s:sub(colon + 1, last), last + 1
    elseif tag == "i" or tag == "f" then
        local semi = s:find(";", pos + 1, true)
        if not semi or semi - pos > 26 then error("bad number") end
        local n = tonumber(s:sub(pos + 1, semi - 1))
        if not n or n ~= n or n == math.huge or n == -math.huge then error("bad number") end
        return n, semi + 1
    elseif tag == "T" then
        return true, pos + 1
    elseif tag == "F" then
        return false, pos + 1
    elseif tag == "t" then
        if depth >= MAX_DEPTH then error("table nested too deeply") end
        local t = {}
        pos = pos + 1
        while true do
            if pos > #s then error("truncated table") end
            if s:sub(pos, pos) == "e" then return t, pos + 1 end
            budget.n = budget.n + 1
            if budget.n > MAX_ITEMS then error("too many items") end
            local k, v
            k, pos = decode(s, pos, depth + 1, budget)
            if type(k) ~= "string" and type(k) ~= "number" then error("bad key") end
            v, pos = decode(s, pos, depth + 1, budget)
            t[k] = v
        end
    end
    error("bad tag at " .. pos)
end

-- Returns the value, or nil plus an error message. Never throws.
function Serializer.Decode(s)
    if type(s) ~= "string" or s == "" then return nil, "empty input" end
    local ok, value, nextPos = pcall(decode, s, 1, 0, { n = 0 })
    if not ok then return nil, tostring(value) end
    if nextPos ~= #s + 1 then return nil, "trailing data" end
    return value
end
