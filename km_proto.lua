-- Keep unedited fields byte-for-byte, including int64 source IDs and unknown fields.
local P = {}
local floor = math.floor

local function varend(s, pos)
    for i = pos, pos + 9 do
        local b = s:byte(i)
        assert(b, "截断的 Protobuf varint")
        assert(i < pos + 9 or b <= 1, "无效的 Protobuf varint")
        if b < 128 then return i + 1 end
    end
    error("过长的 Protobuf varint")
end

function P.number(s)
    local n, factor = 0, 1
    for i = 1, #s do
        n = n + (s:byte(i) % 128) * factor
        assert(n <= 9007199254740991, "数值超出精确整数范围")
        factor = factor * 128
    end
    return n
end

function P.varint(n)
    assert(type(n) == "number" and n >= 0 and n <= 9007199254740991 and n == floor(n), "无效整数")
    local out = {}
    repeat
        local b = n % 128
        n = floor(n / 128)
        out[#out + 1] = string.char(b + (n > 0 and 128 or 0))
    until n == 0
    return table.concat(out)
end

function P.parse(s)
    assert(type(s) == "string", "Protobuf 数据必须为字符串")
    local fields, pos = {}, 1
    while pos <= #s do
        local start, e = pos, varend(s, pos)
        local tag = P.number(s:sub(pos, e - 1))
        local id, wire = floor(tag / 8), tag % 8
        assert(id > 0 and id < 536870912, "无效的 Protobuf 字段")
        pos = e
        local value
        if wire == 0 then
            e = varend(s, pos)
            value, pos = s:sub(pos, e - 1), e
        elseif wire == 2 then
            e = varend(s, pos)
            local size = P.number(s:sub(pos, e - 1))
            assert(e + size - 1 <= #s, "截断的 Protobuf 数据")
            value, pos = s:sub(e, e + size - 1), e + size
        elseif wire == 1 or wire == 5 then
            local size = wire == 1 and 8 or 4
            assert(pos + size - 1 <= #s, "截断的 Protobuf 定长字段")
            value, pos = s:sub(pos, pos + size - 1), pos + size
        else
            error("不支持的 Protobuf wire type: " .. wire)
        end
        fields[#fields + 1] = { id = id, wire = wire, value = value, raw = s:sub(start, pos - 1) }
    end
    return fields
end

function P.encode(fields)
    local out = {}
    for _, f in ipairs(fields) do
        out[#out + 1] = f.raw or (P.varint(f.id * 8 + f.wire)
            .. (f.wire == 2 and P.varint(#f.value) or "") .. f.value)
    end
    return table.concat(out)
end

function P.get(fields, id, default, wire)
    for i = #fields, 1, -1 do
        local f = fields[i]
        if f.id == id then
            assert(not wire or f.wire == wire, "Protobuf 字段类型不兼容: " .. id)
            return f.value
        end
    end
    return default
end

function P.int(fields, id, default)
    local v = P.get(fields, id, nil, 0)
    return v and P.number(v) or (default or 0)
end

function P.set(fields, id, wire, value)
    local result = {}
    for _, f in ipairs(fields) do
        if f.id ~= id then result[#result + 1] = f end
    end
    result[#result + 1] = { id = id, wire = wire, value = value }
    return result
end

function P.setint(fields, id, value)
    return P.set(fields, id, 0, P.varint(value))
end

function P.float32(n)
    assert(type(n) == "number" and n == n and math.abs(n) < math.huge, "无效的章节号")
    local ffi = require("ffi")
    local value = ffi.new("float[1]", n)
    local bytes = ffi.string(ffi.cast("char*", value), 4)
    return ffi.abi("le") and bytes or bytes:reverse()
end

function P.ints(fields, id)
    local out = {}
    for _, f in ipairs(fields) do
        if f.id == id then
            assert(f.wire == 0 or f.wire == 2, "无效的 repeated 整数")
            local pos = 1
            while pos <= #f.value do
                local e = varend(f.value, pos)
                out[#out + 1] = P.number(f.value:sub(pos, e - 1))
                pos = e
            end
        end
    end
    return out
end

return P
