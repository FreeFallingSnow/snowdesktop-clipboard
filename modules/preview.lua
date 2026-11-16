-- modules/preview.lua - small native-watch image tiles.
-- The native channel cannot transport a host image handle. It can transport a
-- bounded RGB mosaic, which is enough for a recognizable in-session thumbnail.

local preview = {}

local B64 = {}
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
for index = 1, #alphabet do B64[alphabet:sub(index, index)] = index - 1 end

local function byte(value)
    if not value then return nil end
    return value
end

local function base64Bytes(encoded)
    if #encoded == 0 or #encoded % 4 ~= 0 then return nil end
    local bytes = {}
    for offset = 1, #encoded, 4 do
        local last = offset + 4 > #encoded
        local c, d = encoded:sub(offset + 2, offset + 2),
            encoded:sub(offset + 3, offset + 3)
        if not last and (c == "=" or d == "=") then return nil end
        if c == "=" and d ~= "=" then return nil end
        local a, b = byte(B64[encoded:sub(offset, offset)]),
            byte(B64[encoded:sub(offset + 1, offset + 1)])
        local cValue = c == "=" and 0 or byte(B64[c])
        local dValue = d == "=" and 0 or byte(B64[d])
        if not a or not b or not cValue or not dValue then return nil end
        if c == "=" and b % 16 ~= 0 then return nil end
        if d == "=" and c ~= "=" and cValue % 4 ~= 0 then return nil end
        local value = a * 262144 + b * 4096 + cValue * 64 + dValue
        bytes[#bytes + 1] = math.floor(value / 65536) % 256
        if c ~= "=" then bytes[#bytes + 1] = math.floor(value / 256) % 256 end
        if d ~= "=" then bytes[#bytes + 1] = value % 256 end
    end
    return bytes
end

-- Decode exactly width*height RGB triples. Invalid or incomplete payloads never
-- produce a partial thumbnail or throw during an event/render callback.
function preview.decode(encoded, width, height)
    if type(encoded) ~= "string" or type(width) ~= "number"
        or type(height) ~= "number" or width < 1 or height < 1
        or width > 32 or height > 32 or width % 1 ~= 0 or height % 1 ~= 0 then
        return nil
    end
    local bytes = base64Bytes(encoded)
    if not bytes or #bytes ~= width * height * 3 then return nil end

    -- Coalesce adjacent equal pixels so flat screenshots cost only a few draw
    -- commands. Each run is {x, y, width, color}, in 0-based source cells.
    local rows, offset = {}, 1
    for y = 0, height - 1 do
        local runs = {}
        local x = 0
        while x < width do
            local r, g, b = bytes[offset], bytes[offset + 1], bytes[offset + 2]
            local color = r * 65536 + g * 256 + b
            local finish = x + 1
            while finish < width and bytes[offset + (finish - x) * 3] == r
                and bytes[offset + (finish - x) * 3 + 1] == g
                and bytes[offset + (finish - x) * 3 + 2] == b do
                finish = finish + 1
            end
            runs[#runs + 1] = { x = x, y = y, width = finish - x, color = color }
            offset = offset + (finish - x) * 3
            x = finish
        end
        rows[#rows + 1] = runs
    end
    return { width = width, height = height, rows = rows }
end

return preview
