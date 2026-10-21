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
    self.state.shelf_changes = self.state.shelf_changes or {}
    self.state.shelf_links = self.state.shelf_links or {}
    self.cache = require("km_cache").new(self.root .. "/chapters", self.config)
    self.state.cache_addresses = self.state.cache_addresses or {}
    self.cache.address_aliases = self.state.cache_addresses
    require("km_history").install(self.cache.root)
    local bytes = F.read(self.root .. "/shelf.proto")
    if bytes then
        local ok, shelf = pcall(Sync.decode, bytes, true)
        if ok then self.shelf = shelf end
    end
    local catalog = F.read(self.root .. "/catalog.proto")
    if catalog then
        local ok, value = pcall(Sync.decode, catalog)
        if ok then self.catalog = value end
    end
    self:reloadShelf()
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
    local pending = {}
    for k, p in pairs(self.state.pending) do pending[k] = p end
    for k, p in pairs(self.state.local_progress) do
        if not pending[k] or pending[k].version < p.version then pending[k] = p end
    end
    local shelf = self:reloadShelf()
    local result = worker(function()
        return require("km_bookshelf").exchange(function(method, url, body, headers)
            return Http.request(self.config, "webdav", method, url, body, headers)
        end, address, shelf, pending, self.state.shelf_changes or {}, self.config, function(remote)
            F.write(self.root .. "/remote-before-write.proto", remote)
        end)
    end)
    if not result then return false end
    local P = require("km_proto")
    local replacements, catalog_fields = {}, {}
    for _, link in pairs(result.links) do replacements[link.manga] = true end
    for _, m in ipairs(self.catalog and self.catalog.mangas or {}) do
        if not result.links[m.key] and not replacements[m.key] then
            catalog_fields[#catalog_fields+1] = {id=1,wire=2,value=P.encode(m.fields)}
        end
    end
    for _, m in ipairs(Sync.decode(result.bytes, true).mangas) do
        if replacements[m.key] then catalog_fields[#catalog_fields+1] = m.field end
    end
    local catalog_bytes = P.encode(catalog_fields)
    F.write(self.root .. "/catalog.proto", catalog_bytes)
    self.catalog = Sync.decode(catalog_bytes, true)
    self.state.catalog_origin = (self.config.komga_url or "") .. "\0" .. (self.config.komga_user or "")
    self.state.shelf_links = self.state.shelf_links or {}
    for k, link in pairs(result.links) do
        if k ~= link.manga then self.state.shelf_links[k] = link end
        for old_c, new_c in pairs(link.chapters) do
            if old_c ~= new_c then self.state.shelf_links[k] = link end
        end
    end
    -- Persist identity redirects before replacing the shelf, so old downloaded manifests still resolve after a restart.
    self:saveState()
    F.write(self.root .. "/shelf.proto", result.bytes)
    for k in pairs(result.settled) do
        for _, values in ipairs({self.state.pending, self.state.local_progress}) do
            if values[k] and values[k].version <= pending[k].version then values[k] = nil end
        end
    end
    self.state.shelf_changes = self.state.shelf_changes or {}
    for k in pairs(result.changes) do self.state.shelf_changes[k] = nil end
    self.state.cache_addresses = self.state.cache_addresses or {}
    for k, link in pairs(result.links) do
        for address, old in pairs(link.addresses) do
            local seen = {}
            while self.state.cache_addresses[old] and not seen[old] do
                seen[old] = true; old = self.state.cache_addresses[old]
            end
            if address ~= old then self.state.cache_addresses[address] = old end
        end
        for old_c, new_c in pairs(link.chapters) do
            local old = Sync.progressKey({key=k}, {key=old_c})
            local new = Sync.progressKey({key=link.manga}, {key=new_c})
            if old ~= new then
                self.state.positions[new] = self.state.positions[old] or self.state.positions[new]
                for _, values in ipairs({self.state.pending, self.state.local_progress}) do
                    if values[old] then
                        if not values[new] or values[new].version <= values[old].version then values[new] = values[old] end
                        values[old] = nil
                    end
                end
            end
        end
    end
    self.cache.address_aliases = self.state.cache_addresses
    self.state.last_sync = os.time()
    self:saveState()
    self:reloadShelf()
    return result.bytes
end

function A:reloadShelf()
    local bytes = F.read(self.root .. "/shelf.proto")
    self.shelf = bytes and Sync.decode(bytes, true) or self.shelf or Sync.decode("", true)
    local C = require("km_catalog")
    local mangas = {}
    for _, m in ipairs(self.shelf.mangas) do
        if C.isKomga(m) then mangas[#mangas+1] = m end
    end
    self.shelf.mangas = mangas
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
    local previous, local_p = self.state.pending[k], self.state.local_progress[k]
    if local_p and (not previous or local_p.version > previous.version) then previous = local_p end
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
            local link = (self.state.shelf_links or {})[m.key]
            if not seen[m.key] and (list == self.shelf or not link or link.manga == m.key) then
                result[#result + 1] = m; seen[m.key] = true
            end
        end
    end
    return result
end

function A:find(mkey, ckey)
    local visited = {}
    while (self.state.shelf_links or {})[mkey] and not visited[mkey] do
        visited[mkey] = true
        local link = self.state.shelf_links[mkey]
        mkey, ckey = link.manga, ckey and (link.chapters[ckey] or ckey)
    end
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
    local existing = self:find(manga.key)
    if existing and existing.favorite then
        local fields = manga.fields
        for _, id in ipairs({100,109,13,106,107}) do fields = P.setint(fields, id, P.int(existing.fields,id)) end
        for _, f in ipairs(existing.fields) do if f.id == 17 then fields[#fields+1] = f end end
        -- Keep synced chapter names and versions when refreshing the Komga chapter list.
        for i, f in ipairs(fields) do
            if f.id == 16 then
                local url = P.get(P.parse(f.value),1,nil,2)
                for _, c in ipairs(existing.chapters) do
                    if c.url == url then fields[i] = c.field; break end
                end
            end
        end
        self:storeManga(Sync.decode(P.encode({{id=1,wire=2,value=P.encode(fields)}})).mangas[1])
    end
end

function A:storeManga(manga)
    local P = require("km_proto")
    local shelf = self:reloadShelf()
    local fields, found = {}, false
    local old
    for _, m in ipairs(shelf.mangas) do if m.key == manga.key then old = m end end
    for _, f in ipairs(shelf.fields) do
        if old and f == old.field then
            fields[#fields+1] = {id=1,wire=2,value=P.encode(manga.fields)}; found = true
        else fields[#fields+1] = f end
    end
    if not found then fields[#fields+1] = {id=1,wire=2,value=P.encode(manga.fields)} end
    F.write(self.root .. "/shelf.proto", P.encode(fields))
    self:reloadShelf()
end

function A:setFavorite(manga, favorite, category)
    local P = require("km_proto")
    local existing = self:find(manga.key) or manga
    local fields = P.setint(existing.fields, 100, favorite and 1 or 0)
    fields = P.setint(fields, 109, P.int(existing.fields,109)+1)
    fields = P.setint(fields, 106, os.time())
    fields = P.setint(fields, 107, os.time())
    if favorite and not existing.favorite then fields = P.setint(fields, 13, os.time()*1000) end
    if category ~= nil then
        local valid = category == -1
        for _, c in ipairs(self:reloadShelf().categories) do if c.order == category then valid = true end end
        assert(valid, "分类不存在")
        local out = {}
        for _, f in ipairs(fields) do if f.id ~= 17 then out[#out+1] = f end end
        fields = out
        if category ~= -1 then fields[#fields+1] = {id=17,wire=0,value=P.varint(category)} end
    end
    self.state.shelf_changes = self.state.shelf_changes or {}
    self.state.shelf_changes[existing.key] = true
    self:saveState()
    local saved = Sync.decode(P.encode({{id=1,wire=2,value=P.encode(fields)}})).mangas[1]
    self:storeManga(saved)
    if not favorite then self:remember(saved) end
    return true
end

function A:addToShelf(manga, category)
    return self:setFavorite(manga, true, category)
end

function A:addCategory(name)
    local P = require("km_proto")
    name = name:match("^%s*(.-)%s*$")
    assert(name ~= "", "分类名称不能为空")
    local shelf, order = self:reloadShelf(), 0
    for _, c in ipairs(shelf.categories) do
        if c.name == name then return c.order end
        order = math.max(order, c.order+1)
    end
    shelf.fields[#shelf.fields+1] = {id=2,wire=2,value=P.encode({
        {id=1,wire=2,value=name},{id=2,wire=0,value=P.varint(order)}})}
    F.write(self.root .. "/shelf.proto", P.encode(shelf.fields))
    self:reloadShelf()
    return order
end

return A
