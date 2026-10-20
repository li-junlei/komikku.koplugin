local M = {}
local lut

function M.apply(buffer)
    if buffer:getType() ~= require("ffi/blitbuffer").TYPE_BB8 then return end
    local ffi = require("ffi")
    if not lut then
        lut = ffi.new("uint8_t[256]")
        for i = 0, 255 do
            local x = math.max(0, math.min(1, (i - 18) / (238 - 18)))
            lut[i] = math.floor(255 * x ^ 1.35 + 0.5)
        end
    end
    local data = ffi.cast("uint8_t *", buffer.data)
    for y = 0, buffer.h - 1 do
        local row = data + y * buffer.stride
        for x = 0, buffer.w - 1 do row[x] = lut[row[x]] end
    end
end

return M
