local P = require("km_proto")
local S = {}

local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function key(...)
    local out = {}
    for i = 1, select("#", ...) do
        local s = select(i, ...)
        out[#out + 1] = #s .. ":" .. s
    end
    return table.concat(out)
end

local function chapter(fields)
    local url = assert(P.get(fields, 1, nil, 2), "章节缺少 URL")
    local name = assert(P.get(fields, 2, nil, 2), "章节缺少名称")
    return {
        fields = fields, url = url, name = name,
        key = key(url, name, hex(P.get(fields, 9, "\0\0\0\0", 5))),
        read = P.int(fields, 4) ~= 0, page = P.int(fields, 6),
        version = P.int(fields, 12), order = P.int(fields, 10),
    }
end

function S.decode(bytes)
    local result = { fields = P.parse(bytes), mangas = {}, categories = {} }
    for _, f in ipairs(result.fields) do
        if f.id == 1 then
            assert(f.wire == 2, "无效的书架字段")
            local m = P.parse(f.value)
            local url = assert(P.get(m, 2, nil, 2), "漫画缺少 URL")
            local source = assert(P.get(m, 1, nil, 0), "漫画缺少 source")
            local title = P.get(m, 3, "", 2)
            local item = {
                fields = m, field = f, source = source, url = url, title = title,
                key = key(hex(source), url), favorite = P.int(m, 100, 1) ~= 0,
                categories = P.ints(m, 17), chapters = {},
            }
            for _, cf in ipairs(m) do
                if cf.id == 16 then
                    assert(cf.wire == 2, "无效的章节字段")
                    local c = chapter(P.parse(cf.value))
                    c.field = cf
                    item.chapters[#item.chapters + 1] = c
                end
            end
            result.mangas[#result.mangas + 1] = item
        elseif f.id == 2 then
            assert(f.wire == 2, "无效的分类字段")
            local c = P.parse(f.value)
            result.categories[#result.categories + 1] = {
                name = P.get(c, 1, "", 2), order = P.int(c, 2), hidden = P.int(c, 900) ~= 0,
            }
        end
    end
    assert(#result.mangas > 0, "同步文件没有漫画；请先在手机完整同步书架和章节")
    return result
end

function S.progressKey(m, c) return key(m.key, c.key) end

function S.progress(c, page, total, previous, now)
    assert(page >= 1 and page <= total and page == math.floor(page), "页码越界")
    local base = previous or c
    local read = base.read or page == total
    if base.page == page - 1 and base.read == read then return previous end
    return { page = page - 1, read = read, version = base.version + 1, modified = now or os.time() }
end

function S.merge(bytes, pending)
    local backup, settled, changed = S.decode(bytes), {}, false
    for _, m in ipairs(backup.mangas) do
        local mf, manga_changed = {}, false
        for _, f in ipairs(m.fields) do mf[#mf + 1] = f end
        for _, c in ipairs(m.chapters) do
            local k = S.progressKey(m, c)
            local local_c = pending[k]
            if local_c then
                settled[k] = true
                -- Komikku 1.14.1: higher chapter version wins; ties choose local.
                if local_c.version >= c.version then
                    local cf = P.setint(c.fields, 4, local_c.read and 1 or 0)
                    cf = P.setint(cf, 6, local_c.page)
                    cf = P.setint(cf, 11, local_c.modified)
                    cf = P.setint(cf, 12, local_c.version)
                    local encoded = P.encode(cf)
                    if encoded ~= c.field.value then
                        for i, f in ipairs(mf) do
                            if f == c.field then mf[i] = { id = 16, wire = 2, value = encoded } end
                        end
                        manga_changed = true
                    end
                end
            end
        end
        if manga_changed then
            for i, f in ipairs(backup.fields) do
                if f == m.field then backup.fields[i] = { id = 1, wire = 2, value = P.encode(mf) } end
            end
            changed = true
        end
    end
    return changed and P.encode(backup.fields) or bytes, settled, changed
end

local function publish(transport, url, headers, bytes)
    local etag = headers and headers.etag
    assert(etag and etag ~= "" and not etag:match("^W/"), "WebDAV 未提供强 ETag；已读取书架，暂停回传以防覆盖")
    local _, status = transport("PUT", url, bytes, { ["If-Match"] = etag })
    assert(status ~= 412, "WebDAV 发生并发冲突；本地数据已保留，请重新同步或重试加入")
    assert(status and status >= 200 and status < 300, "上传结果未确认（HTTP " .. tostring(status) .. "）；请重新同步确认")
end

function S.run(transport, url, pending, save_backup)
    -- Always re-read the complete remote document before writing. Never upload a stale shelf.
    local bytes, code, headers = transport("GET", url)
    assert(code == 200, "读取 WebDAV 失败（HTTP " .. tostring(code) .. "）；请先在手机同步")
    local merged, settled, changed = S.merge(bytes, pending)
    save_backup(bytes)
    if changed then publish(transport, url, headers, merged) end
    return merged, settled
end

function S.add(transport, url, candidate, category, pending, save_backup)
    local bytes, code, headers = transport("GET", url)
    assert(code == 200, "读取 WebDAV 失败；请先在手机同步")
    local backup = S.decode(bytes)
    local known_source, existing, category_exists = false, nil, category == -1
    for _, m in ipairs(backup.mangas) do
        if m.source == candidate.source then known_source = true end
        if m.key == candidate.key then existing = m end
    end
    for _, c in ipairs(backup.categories) do if c.order == category then category_exists = true end end
    assert(known_source, "远端已无此来源，请重新同步并选择手机的 Komga 来源")
    assert(category_exists, "所选分类已改变，请重新同步后选择")
    save_backup(bytes)
    if existing and existing.favorite then return bytes end
    local fields = (existing or candidate).fields
    local now = os.time()
    fields = P.setint(fields, 100, 1)
    fields = P.setint(fields, 109, P.int(fields, 109) + 1)
    fields = P.setint(fields, 13, now * 1000)
    fields = P.setint(fields, 106, now)
    fields = P.setint(fields, 107, now)
    local without_categories = {}
    for _, f in ipairs(fields) do if f.id ~= 17 then without_categories[#without_categories + 1] = f end end
    fields = without_categories
    if category ~= -1 then fields[#fields + 1] = {id=17,wire=0,value=P.varint(category)} end
    local manga_field = {id=1,wire=2,value=P.encode(fields)}
    if existing then
        for i, f in ipairs(backup.fields) do if f == existing.field then backup.fields[i] = manga_field end end
    else backup.fields[#backup.fields + 1] = manga_field end
    local merged = S.merge(P.encode(backup.fields), pending or {})
    publish(transport, url, headers, merged)
    return merged
end

return S
