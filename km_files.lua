local F = {}

function F.read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

function F.write(path, bytes)
    local tmp = path .. ".tmp"
    local f = assert(io.open(tmp, "wb"), "无法写入文件，请检查存储空间")
    local ok = f:write(bytes)
    if ok then require("ffi/util").fsyncOpenedFile(f) end
    local closed = f:close()
    if not ok or not closed then os.remove(tmp); error("文件写入失败，原数据已保留") end
    local renamed = os.rename(tmp, path)
    assert(renamed, "无法替换文件，原数据已保留")
    require("ffi/util").fsyncDirectory(path)
end

return F
