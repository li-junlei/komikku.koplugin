local K = require("km_komga")
local H = require("km_http")
local P = require("km_proto")
local S = require("km_sync")
local C = {}

function C.path(filters, page, size)
    size = size or 6
    assert(type(size) == "number" and size >= 1 and size <= 50 and size == math.floor(size), "无效的分页数量")
    local kind = filters.kind or "series"
    assert(kind == "series" or kind == "books" or kind == "readlists", "无效的书库类型")
    local collection = filters.collection
    local path = collection and collection ~= "" and ("collections/" .. H.escape(collection) .. "/series") or kind
    local query = {}
    local function add(k, v) query[#query + 1] = H.escape(k) .. "=" .. H.escape(tostring(v)) end
    add("search", filters.search or ""); add("page", (page or 1) - 1); add("size", size); add("deleted", "false")
    if filters.unread then add("read_status", "UNREAD"); add("read_status", "IN_PROGRESS") end
    if filters.in_progress then add("read_status", "IN_PROGRESS") end
    if filters.read then add("read_status", "READ") end
    for _, name in ipairs({ "library_id", "status", "genre", "tag", "publisher" }) do
        local values = filters[name] or {}
        if #values > 0 then add(name, table.concat(values, ",")) end
    end
    for _, author in ipairs(filters.author or {}) do add("author", author.name .. "," .. author.role) end
    local sort = filters.sort or "relevance"
    if sort == "title" then sort = path == "series" and "metadata.titleSort" or "name" end
    assert(({relevance=true,["metadata.titleSort"]=true,name=true,createdDate=true,lastModifiedDate=true,random=true})[sort], "无效的排序")
    add("sort", sort .. (filters.descending and ",desc" or ",asc"))
    return "/api/v1/" .. path .. "?" .. table.concat(query, "&"), collection and collection ~= "" and "series" or kind
end

function C.browse(config, filters, page)
    local size = config.library_view == "covers" and 6 or 50
    local path, kind = C.path(filters, page, size)
    local result = K.json(config, path)
    assert(type(result.content) == "table" and type(result.totalPages) == "number"
        and result.totalPages >= 0 and result.totalPages == math.floor(result.totalPages), "Komga 分页响应无效")
    assert(#result.content <= size, "服务器没有遵守请求的分页数量")
    local items = {}
    for _, item in ipairs(result.content) do
        assert(type(item.id) == "string" and item.id:match("^[%w_-]+$"), "无效的 Komga ID")
        local url = H.validateBase(config.komga_url) .. "/api/v1/" .. kind .. "/" .. item.id
        items[#items + 1] = { title = (item.metadata and item.metadata.title) or item.name or "Komga",
            url = url, key = "catalog:" .. url, kind = kind, id = item.id, chapters = {}, categories = {} }
    end
    return { items = items, page = page or 1, pages = math.max(1, result.totalPages), page_size = size }
end

function C.options(config)
    local result = {
        libraries = K.json(config, "/api/v1/libraries"),
        collections = K.json(config, "/api/v1/collections?unpaged=true").content,
        genres = K.json(config, "/api/v1/genres"), tags = K.json(config, "/api/v1/tags"),
        publishers = K.json(config, "/api/v1/publishers"), authors = K.json(config, "/api/v1/authors"),
    }
    for _, key in ipairs({ "libraries", "collections", "genres", "tags", "publishers", "authors" }) do
        assert(type(result[key]) == "table", "Komga 筛选项格式无效: " .. key)
        for i, value in ipairs(result[key]) do
            if key == "authors" then
                assert(type(value) == "table" and type(value.name) == "string" and type(value.role) == "string", "Komga 作者格式无效")
                result[key][i] = { name = value.name, role = value.role }
            elseif key == "libraries" or key == "collections" then
                assert(type(value) == "table" and type(value.name) == "string" and type(value.id) == "string", "Komga 书库/合集格式无效")
                result[key][i] = { name = value.name, id = value.id }
            else assert(type(value) == "string", "Komga 筛选值格式无效") end
        end
    end
    return result
end

function C.template(config, shelf)
    if config.komga_source_id and config.komga_source_id ~= "" then
        for _, m in ipairs((shelf or {}).mangas or {}) do
            if C.sourceId(m.source) == config.komga_source_id then return m end
        end
        return nil
    end
    local sources = C.sources(shelf or { mangas = {} })
    local base = H.validateBase(config.komga_url)
    for _, source in ipairs(sources) do
        if source.manga.url:match("^(.-)/api/v1/") == base then return source.manga end
    end
    if #sources == 1 then return sources[1].manga end
end

function C.sourceId(raw)
    local ffi = require("ffi")
    local n, factor = ffi.new("uint64_t", 0), ffi.new("uint64_t", 1)
    for i = 1, #raw do
        n = n + factor * (raw:byte(i) % 128)
        factor = factor * 128
    end
    return tostring(ffi.cast("int64_t", n)):gsub("LL$", "")
end

function C.sources(shelf)
    local names, seen, result = {}, {}, {}
    for _, f in ipairs(shelf.fields or {}) do
        if f.id == 101 then
            local fields = P.parse(f.value)
            names[P.get(fields, 2, "", 0)] = P.get(fields, 1, "Komga", 2)
        end
    end
    for _, m in ipairs(shelf.mangas) do
        if m.url:find("/api/v1/", 1, true) and not seen[m.source] then
            seen[m.source] = true
            result[#result + 1] = { name = (names[m.source] or "Komga") .. " · " .. m.title, manga = m }
        end
    end
    return result
end

local function authorNames(authors, role)
    local out, seen = {}, {}
    for _, a in ipairs(authors or {}) do
        if (not role or a.role == role) and (not role or not seen[a.name]) then out[#out + 1] = a.name; seen[a.name] = true end
    end
    return #out > 0 and table.concat(out, ", ") or nil
end

function C.prepare(config, template, item)
    local dto = K.json(config, "/api/v1/" .. item.kind .. "/" .. item.id)
    local books
    if item.kind == "books" then books = { dto }
    else books = K.json(config, "/api/v1/" .. item.kind .. "/" .. item.id .. "/books?unpaged=true&media_status=READY&deleted=false").content end
    assert(type(books) == "table", "Komga 没有返回章节列表")
    return C.build(config, template, item, dto, books)
end

function C.build(config, template, item, dto, books)
    local base = template.url:match("^(.-)/api/v1/") or H.validateBase(config.komga_url)
    local url = base .. "/api/v1/" .. item.kind .. "/" .. item.id
    local meta, aggregate = dto.metadata or {}, dto.booksMetadata or {}
    local title = meta.title or dto.name or item.title
    local fields = {}
    local function put(id, value, wire)
        if value ~= nil then fields[#fields + 1] = { id = id, wire = wire or 2, value = value } end
    end
    local function int(id, n) put(id, P.varint(n), 0) end
    put(1, template.source, 0); put(2, url); put(3, title)
    local authors = item.kind == "series" and aggregate.authors or meta.authors
    put(4, authorNames(authors, item.kind == "series" and "penciller" or nil) or (item.kind == "books" and "" or nil))
    put(5, authorNames(authors, item.kind == "series" and "writer" or nil) or (item.kind == "books" and "" or nil))
    put(6, meta.summary and meta.summary ~= "" and meta.summary or aggregate.summary or dto.summary or "")
    local genres = {}
    for _, values in ipairs({ meta.genres or {}, meta.tags or {}, aggregate.tags or {} }) do
        for _, v in ipairs(values) do genres[v] = true end
    end
    local sorted = {}; for v in pairs(genres) do sorted[#sorted + 1] = v end; table.sort(sorted)
    for _, v in ipairs(sorted) do put(7, v) end
    local status = ({ ONGOING=1, ENDED=2, ABANDONED=5, HIATUS=6 })[meta.status] or 0
    if meta.status == "ENDED" and meta.totalBookCount and (dto.booksCount or 0) < meta.totalBookCount then status = 4 end
    int(8, status); put(9, url .. "/thumbnail"); int(100, 0); int(111, 1)
    local chapters = {}
    for i, book in ipairs(books) do
        local media, bm = book.media or {}, book.metadata or {}
        if media.mediaProfile ~= "EPUB" or media.epubDivinaCompatible then
            local number = item.kind == "books" and 1 or (item.kind == "readlists" and (#chapters + 1) or tonumber(bm.numberSort) or 0)
            local values = { title=bm.title or book.name or "", seriesTitle=book.seriesTitle or "",
                number=bm.number or tostring(number), createdDate=book.created, releaseDate=bm.releaseDate,
                size=book.size or "", sizeBytes=tostring(book.sizeBytes or 0) }
            local name = (config.komga_chapter_template or "{number} - {title} ({size})"):gsub("{([%w]+)}", function(k) return values[k] or ("{" .. k .. "}") end)
            if item.kind ~= "series" then name = (book.seriesTitle or "") .. " " .. name end
            if name == title then name = "\226\128\139" .. title end
            local translators = {}
            for _, a in ipairs(bm.authors or {}) do if a.role == "translator" then translators[#translators + 1] = a.name end end
            local sep = config.komga_scanlator_separator or ","
            sep = sep == "," and ", " or (" " .. sep .. " ")
            assert(type(book.id) == "string" and book.id:match("^[%w_-]+$"), "章节 ID 无效")
            chapters[#chapters + 1] = { url = base .. "/api/v1/books/" .. book.id, name = name,
                number = number, index = i, scanlator = table.concat(translators, sep) }
        end
    end
    table.sort(chapters, function(a, b) if a.number == b.number then return a.index < b.index end; return a.number > b.number end)
    for i, c in ipairs(chapters) do
        local cf = { {id=1,wire=2,value=c.url}, {id=2,wire=2,value=c.name}, {id=3,wire=2,value=c.scanlator},
            {id=9,wire=5,value=P.float32(c.number)}, {id=10,wire=0,value=P.varint(i - 1)} }
        put(16, P.encode(cf))
    end
    return S.decode(P.encode({ {id=1,wire=2,value=P.encode(fields)} })).mangas[1]
end

return C
