local util = require("util")

local Text = {}

function Text.characters(value)
    if type(value) ~= "string" then return nil end
    local ok, characters = pcall(util.splitToChars, value)
    if not ok or type(characters) ~= "table" then return nil end
    return characters
end

function Text.count(value)
    local characters = Text.characters(value)
    return characters and #characters or nil
end

function Text.truncate(value, maximum, keep_end)
    local characters = Text.characters(value)
    if not characters then return nil end
    if #characters <= maximum then return value end
    local result, first, last = {}, keep_end and (#characters - maximum + 1) or 1, keep_end and #characters or maximum
    for index = first, last do result[#result + 1] = characters[index] end
    return table.concat(result)
end

return Text
