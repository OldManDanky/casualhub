-- Locale table. Keys are the English strings; a missing translation falls back to the key itself.
-- Other locales (Locale/<locale>.lua) assign L["English"] = "Translated" when GetLocale() matches.
local _, CH = ...

CH.L = setmetatable({}, {
    __index = function(_, key) return key end,
})
