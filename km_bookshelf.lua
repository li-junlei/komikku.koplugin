local P = require("km_proto")
local S = require("km_sync")
local C = require("km_catalog")
local B = {}

local function manga(fields)
    return S.decode(P.encode({{id=1, wire=2, value=P.encode(fields)}})).mangas[1]
end

local function address(url, base)
    local path = assert(url:match("(/api/v1/.*)$"), "无效的 Komga 地址")
    return base .. path
end

local function bind(m, template)
    local base = assert(template.url:match("^(.-)/api/v1/"))
    local fields = P.set(m.fields, 1, 0, template.source)
    fields = P.set(fields, 2, 2, address(m.url, base))
    fields = P.set(fields, 9, 2, address(m.url, base) .. "/thumbnail")
    local out = {}
    for _, f in ipairs(fields) do
        if f.id == 16 then
            local chapter = P.parse(f.value)
            chapter = P.set(chapter, 1, 2, address(P.get(chapter, 1, nil, 2), base))
            out[#out+1] = {id=16, wire=2, value=P.encode(chapter)}
        else out[#out+1] = f end
    end
    return manga(out)
end

function B.exchange(transport, url, local_shelf, pending, changes, config, save_backup)
    local bytes, code, headers = transport("GET", url)
    assert(code == 200 or code == 404, "读取 WebDAV 失败（HTTP " .. tostring(code) .. "）；设备书架已保留")
    if code == 404 then bytes = "" end
    local remote = S.decode(bytes, true)
    local template = C.template(config, remote) or C.template(config, local_shelf) or C.defaultTemplate(config)
    local local_template = C.template(config, local_shelf)
    local by_key, categories, max_order = {}, {}, -1
    for _, m in ipairs(remote.mangas) do by_key[m.key] = m end
    for _, c in ipairs(remote.categories) do categories[c.name] = c.order; max_order = math.max(max_order, c.order) end
    local local_categories = {}
    for _, c in ipairs(local_shelf.categories) do
        local_categories[c.order] = c.name
        if categories[c.name] == nil then
            max_order = max_order + 1; categories[c.name] = max_order
            remote.fields[#remote.fields+1] = {id=2,wire=2,value=P.encode({
                {id=1,wire=2,value=c.name},{id=2,wire=0,value=P.varint(max_order)}})}
        end
    end
    local links, translated, original_keys, acknowledged = {}, {}, {}, {}
    for _, old in ipairs(local_shelf.mangas) do
        local eligible = not local_template or old.source == local_template.source
            or (changes[old.key] and old.url:match("^(.-)/api/v1/") == config.komga_url)
        assert(not changes[old.key] or eligible, "有其他 Komga 来源的收藏待同步，请先选择对应的同步来源；设备书架已保留")
        if C.isKomga(old) and eligible then
            local candidate = bind(old, template)
            local existing = by_key[candidate.key]
            local fields = existing and existing.fields or candidate.fields
            local dirty = changes[old.key]
            if existing or (dirty and old.favorite) then
                if dirty and (not existing or P.int(old.fields, 109) >= P.int(existing.fields, 109)) then
                    for _, id in ipairs({100, 109, 13, 106, 107}) do
                        fields = P.setint(fields, id, P.int(old.fields, id))
                    end
                    local out = {}
                    for _, f in ipairs(fields) do if f.id ~= 17 then out[#out+1] = f end end
                    fields = out
                    for _, order in ipairs(old.categories) do
                        local name = assert(local_categories[order], "分类不存在；请重新选择")
                        fields[#fields+1] = {id=17,wire=0,value=P.varint(categories[name])}
                    end
                end
                local target = manga(fields)
                local chapters = {}
                for _, c in ipairs(target.chapters) do chapters[c.url] = c end
                local link = {manga=target.key, chapters={}, addresses={}}
                links[old.key] = link
                for i, c in ipairs(candidate.chapters) do
                    local dest = chapters[c.url]
                    if not dest then
                        fields[#fields+1] = {id=16,wire=2,value=P.encode(c.fields)}
                        dest = c; chapters[c.url] = c
                    end
                    local previous = old.chapters[i]
                    link.chapters[previous.key] = dest.key
                    link.addresses[dest.url] = previous.url
                    local old_key, new_key = S.progressKey(old, previous), S.progressKey(target, dest)
                    if pending[old_key] then
                        if not translated[new_key] or translated[new_key].version <= pending[old_key].version then
                            translated[new_key] = pending[old_key]
                        end
                        original_keys[new_key] = original_keys[new_key] or {}
                        original_keys[new_key][#original_keys[new_key]+1] = old_key
                    end
                end
                local replacement = {id=1,wire=2,value=P.encode(fields)}
                if existing then
                    for i, f in ipairs(remote.fields) do if f == existing.field then remote.fields[i] = replacement end end
                else remote.fields[#remote.fields+1] = replacement end
                local updated = manga(fields); updated.field = replacement
                by_key[updated.key] = updated
            end
            if dirty then acknowledged[old.key] = true end
        end
    end
    local merged, settled = S.merge(P.encode(remote.fields), translated, true)
    save_backup(bytes)
    if merged ~= bytes then
        local condition
        if code == 404 then condition = {["If-None-Match"]="*"}
        else
            local etag = headers and headers.etag
            assert(etag and etag ~= "" and not etag:match("^W/"), "WebDAV 未提供强 ETag；设备书架已保留，暂停回传")
            condition = {["If-Match"]=etag}
        end
        local _, status = transport("PUT", url, merged, condition)
        assert(status and status >= 200 and status < 300, "同步上传未确认（HTTP " .. tostring(status) .. "）；设备书架已保留，请重试")
    end
    local cleared = {}
    for k in pairs(settled) do
        for _, original in ipairs(original_keys[k]) do cleared[original] = true end
    end
    return {bytes=merged, settled=cleared, links=links, changes=acknowledged}
end

return B
