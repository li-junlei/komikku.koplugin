local F = require("km_files")
local Sync = require("km_sync")
local A = {}

function A:init()
    if self.root then return end
    self.root = require("datastorage"):getFullDataDir() .. "/komikku"
    require("util").makePath(self.root)
    self.settings = require("luasettings"):open(require("datastorage"):getSettingsDir() .. "/komikku.lua")
    self.config = self.settings.data
    self.state = require("luasettings"):open(self.root .. "/progress.lua").data
    self.state.pending = self.state.pending or {}
    self.state.local_progress = self.state.local_progress or {}
    self.state.positions = self.state.positions or {}
    self.cache = require("km_cache").new(self.root .. "/chapters", self.config)
    require("km_history").install(self.cache.root)
    local bytes = F.read(self.root .. "/shelf.proto")
    if bytes then
        local ok, shelf = pcall(Sync.decode, bytes)
        if ok then self.shelf = shelf end
    end
    local catalog = F.read(self.root .. "/catalog.proto")
    if catalog then
        local ok, value = pcall(Sync.decode, catalog)
        if ok then self.catalog = value end
    end
end

function A:saveState()
    local dump = require("dump")
    F.write(self.root .. "/progress.lua", "return " .. dump(self.state, nil, true) .. "\n")
end

function A:saveConfig()
    F.write(self.settings.file, "return " .. require("dump")(self.config, nil, true) .. "\n")
end

function A:sync(worker)
    self.cache:stopPrefetch()
    local Http = require("km_http")
    local address = Http.webdavUrl(self.config)
    local pending = self.state.pending
    local result = worker(function()
        local bytes, settled = Sync.run(function(method, url, body, headers)
            return Http.request(self.config, "webdav", method, url, body, headers)
        end, address, pending, function(remote)
            F.write(self.root .. "/remote-before-write.proto", remote)
            -- A readable remote shelf is useful even when a write is refused or fails.
            F.write(self.root .. "/shelf.proto", remote)
        end)
        return { bytes = bytes, settled = settled }
    end)
    if not result then self:reloadShelf(); return false end
    local bytes, settled = result.bytes, result.settled
    F.write(self.root .. "/shelf.proto", bytes)
    for k in pairs(settled) do self.state.pending[k] = nil end
    self.state.last_sync = os.time()
    self:saveState()
    self:reloadShelf()
    return bytes
end

function A:reloadShelf()
    local bytes = F.read(self.root .. "/shelf.proto")
    if bytes then self.shelf = Sync.decode(bytes) end
    return self.shelf
end

function A:current(m, c)
    local k = Sync.progressKey(m, c)
    local p = self.state.pending[k]
    local local_p = self.state.local_progress and self.state.local_progress[k]
    if local_p and (not p or local_p.version > p.version) then p = local_p end
    return p and p.version >= c.version and p or c
end

function A:record(m, c, page, total, dir)
    if not self.cache:hasPage(dir, page) then return end
    local fresh_m, fresh_c = self:find(m.key, c.key)
    if fresh_c then m, c = fresh_m, fresh_c end
    local k = Sync.progressKey(m, c)
    self.state.local_progress = self.state.local_progress or {}
    local target = m.favorite and self.state.pending or self.state.local_progress
    local previous = target[k] or self.state.local_progress[k]
    if previous and previous.version < c.version then previous = nil end
    local p = Sync.progress(c, page, total, previous)
    if p then target[k] = p end
    self.state.positions[k] = { page = page, time = os.time() }
    self.state.last = { manga = m.key, chapter = c.key }
    self:saveState()
end

function A:allMangas()
    local origin = (self.config and self.config.komga_url or "") .. "\0" .. (self.config and self.config.komga_user or "")
    local result, seen = {}, {}
    for _, list in ipairs({ self.shelf or {}, self.state.catalog_origin == origin and self.catalog or {} }) do
        for _, m in ipairs(list.mangas or {}) do
            if not seen[m.key] then result[#result + 1] = m; seen[m.key] = true end
        end
    end
    return result
end

function A:find(mkey, ckey)
    local origin = (self.config and self.config.komga_url or "") .. "\0" .. (self.config and self.config.komga_user or "")
    for _, list in ipairs({ self.shelf or {}, self.state.catalog_origin == origin and self.catalog or {} }) do
        for _, m in ipairs(list.mangas or {}) do
            if m.key == mkey then
                if not ckey then return m end
                for _, c in ipairs(m.chapters) do if c.key == ckey then return m, c end end
            end
        end
    end
end

function A:remember(manga)
    local P = require("km_proto")
    local origin = (self.config.komga_url or "") .. "\0" .. (self.config.komga_user or "")
    local fields = {}
    if self.state.catalog_origin == origin then
        for _, m in ipairs(self.catalog and self.catalog.mangas or {}) do
            if m.key ~= manga.key then fields[#fields + 1] = {id=1,wire=2,value=P.encode(m.fields)} end
        end
    end
    fields[#fields + 1] = {id=1,wire=2,value=P.encode(manga.fields)}
    local bytes = P.encode(fields)
    F.write(self.root .. "/catalog.proto", bytes)
    self.catalog = Sync.decode(bytes)
    self.state.catalog_origin = origin
    self:saveState()
end

function A:addToShelf(manga, category, worker)
    local H = require("km_http")
    local url = H.webdavUrl(self.config)
    local pending = {}
    for k, p in pairs(self.state.pending) do pending[k] = p end
    for k, p in pairs(self.state.local_progress or {}) do
        if not pending[k] or pending[k].version < p.version then pending[k] = p end
    end
    local result = worker(function()
        return Sync.add(function(method, address, body, headers)
            return H.request(self.config, "webdav", method, address, body, headers)
        end, url, manga, category, pending, function(bytes)
            F.write(self.root .. "/remote-before-write.proto", bytes)
        end)
    end)
    if not result then return false end
    F.write(self.root .. "/shelf.proto", result)
    self:reloadShelf()
    return true
end

return A
