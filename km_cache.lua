local F = require("km_files")
local K = require("km_komga")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local C = {}
C.__index = C

function C.new(root, config)
    util.makePath(root)
    return setmetatable({ root = root, config = config }, C)
end

function C:directory(address)
    local hash = require("ffi/sha2").md5((self.config.komga_url or "") .. "\0"
        .. (self.config.komga_user or "") .. "\0" .. address)
    return self.root .. "/" .. hash
end

function C:manifest(address)
    local dir = self:directory(address)
    local bytes = F.read(dir .. "/chapter.kmk")
    if bytes then
        local ok, m = pcall(require("json").decode, bytes)
        assert(ok and type(m) == "table" and m.address == address and type(m.pages) == "table"
            and #m.pages > 0, "本地章节清单损坏，请删除该章节下载后重试")
        return m, dir
    end
    util.makePath(dir)
    local m = { address = address, pages = K.pages(self.config, address) }
    F.write(dir .. "/chapter.kmk", require("json").encode(m))
    return m, dir
end

function C:pagePath(dir, page) return dir .. string.format("/%05d.png", page) end

function C:hasPage(dir, page)
    local n = lfs.attributes(self:pagePath(dir, page), "size")
    return n and n > 0
end

function C:ensure(m, dir, page)
    assert(m.pages[page], "页面索引越界")
    local path = self:pagePath(dir, page)
    if not self:hasPage(dir, page) then
        K.downloadPage(self.config, m.address, m.pages[page], path)
        if not F.read(dir .. "/offline") then self:evict(dir) end
    end
    lfs.touch(path)
    return path
end

function C:isOffline(dir, count)
    if not F.read(dir .. "/offline") then return false end
    for page = 1, count do if not self:hasPage(dir, page) then return false end end
    return true
end

function C:download(m, dir)
    -- Pin before downloading so cache eviction cannot remove a partly completed offline download.
    F.write(dir .. "/offline", "requested\n")
    for page = 1, #m.pages do self:ensure(m, dir, page) end
    F.write(dir .. "/offline", "complete\n")
end

function C:downloadProgress(m, dir)
    local done, current, bytes = 0, nil, 0
    for page = 1, #m.pages do
        if self:hasPage(dir, page) then
            done = done + 1
        elseif not current then
            current = page
            bytes = lfs.attributes(self:pagePath(dir, page) .. ".part", "size") or 0
        end
    end
    return done, #m.pages, current, bytes
end

function C:stopPrefetch()
    if self.pid then
        local ffiutil = require("ffi/util")
        local pid = self.pid
        local dir = self.prefetch_dir
        local function cleanup()
            if dir and lfs.attributes(dir, "mode") == "directory" then
                for name in lfs.dir(dir) do
                    local suffix = ".prefetch-" .. pid
                    if name:sub(-#suffix) == suffix or name:sub(-#(suffix .. ".part")) == suffix .. ".part" then
                        os.remove(dir .. "/" .. name)
                    end
                end
            end
        end
        if not ffiutil.isSubProcessDone(pid) then
            ffiutil.terminateSubProcess(pid)
            local reap
            reap = function()
                if not ffiutil.isSubProcessDone(pid) then require("ui/uimanager"):scheduleIn(1, reap) else cleanup() end
            end
            require("ui/uimanager"):scheduleIn(0.5, reap)
        else cleanup() end
        self.pid = nil
        require("ui/uimanager"):allowStandby()
    end
    if self.poll then require("ui/uimanager"):unschedule(self.poll); self.poll = nil end
end

function C:prefetch(m, dir, current)
    if not require("ui/network/manager"):isConnected() then return end
    if self.pid and not require("ffi/util").isSubProcessDone(self.pid) then return end
    self:stopPrefetch()
    local pages = {}
    for page = current + 1, math.min(current + 2, #m.pages) do
        if not self:hasPage(dir, page) then pages[#pages + 1] = page end
    end
    if #pages == 0 then return end
    local ffiutil = require("ffi/util")
    local ui = require("ui/uimanager")
    local pid = ffiutil.runInSubProcess(function(child_pid)
        for _, page in ipairs(pages) do
            local path = self:pagePath(dir, page)
            local tmp = path .. ".prefetch-" .. child_pid
            local ok = pcall(K.downloadPage, self.config, m.address, m.pages[page], tmp)
            if ok then os.rename(tmp, path) else os.remove(tmp .. ".part"); break end
        end
    end, false)
    if not pid then return end
    self.pid = pid
    self.prefetch_dir = dir
    ui:preventStandby()
    self.poll = function()
        if ffiutil.isSubProcessDone(pid) then
            self.pid, self.poll = nil, nil
            ui:allowStandby()
            self:evict(dir)
        else ui:scheduleIn(0.5, self.poll) end
    end
    ui:scheduleIn(0.5, self.poll)
end

function C:entries(metadata)
    local entries = {}
    for name in lfs.dir(self.root) do
        local dir = self.root .. "/" .. name
        if name:match("^%x+$") and lfs.attributes(dir, "mode") == "directory" then
            local entry = { dir = dir, bytes = 0, done = 0, time = 0, offline = F.read(dir .. "/offline") ~= nil }
            local bytes = metadata ~= false and F.read(dir .. "/chapter.kmk")
            if bytes then
                local ok, manifest = pcall(require("json").decode, bytes)
                if ok and type(manifest) == "table" then entry.manifest = manifest end
            end
            for file in lfs.dir(dir) do
                local a = lfs.attributes(dir .. "/" .. file)
                if a and a.mode == "file" then
                    entry.bytes = entry.bytes + a.size
                    if file:match("^%d+%.png$") and a.size > 0 then
                        entry.done = entry.done + 1
                        entry.time = math.max(entry.time, a.modification or 0)
                    end
                end
            end
            entry.time = tonumber(F.read(dir .. "/read-order")) or entry.time
            entries[#entries + 1] = entry
        end
    end
    table.sort(entries, function(a, b) if a.time == b.time then return a.dir < b.dir end; return a.time < b.time end)
    return entries
end

function C:markRead(dir)
    F.write(dir .. "/read-order", string.format("%.6f", require("socket").gettime()))
end

function C:evict(protected)
    local limit = tonumber(self.config.online_cache_limit_mb) or 128
    if limit <= 0 then return end
    local entries, size = self:entries(false), 0
    for _, e in ipairs(entries) do if not e.offline then size = size + e.bytes end end
    for _, e in ipairs(entries) do
        if size <= limit * 1024 * 1024 then break end
        if not e.offline and e.dir ~= protected and e.dir ~= self.active_dir then
            self:removeDir(e.dir); size = size - e.bytes
        end
    end
end

function C:remove(address)
    return self:removeDir(self:directory(address))
end

function C:removeDir(dir)
    assert(dir:sub(1, #self.root + 1) == self.root .. "/" and dir:sub(#self.root + 2):match("^%x+$"), "无效缓存目录")
    self:stopPrefetch()
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    for name in lfs.dir(dir) do
        if name:match("^%d+%.png") or name == "offline" or name == "chapter.kmk" or name == "read-order" then
            assert(os.remove(dir .. "/" .. name), "删除下载失败")
        end
    end
    os.remove(dir)
end

return C
