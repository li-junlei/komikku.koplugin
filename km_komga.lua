local H = require("km_http")
local K = {}

function K.id(address, kind)
    local id = address:match("/api/v1/" .. kind .. "/([%w_-]+)")
    assert(id, "无法识别 Komga 地址；请检查手机使用的 Komga 扩展")
    return id
end

function K.bookUrl(config, address)
    return H.validateBase(config.komga_url) .. "/api/v1/books/" .. K.id(address, "books")
end

function K.json(config, path)
    local bytes, code = H.request(config, "komga", "GET", H.validateBase(config.komga_url) .. path)
    assert(code == 200, "Komga 请求失败（HTTP " .. tostring(code) .. "）")
    local ok, value = pcall(require("json").decode, bytes)
    assert(ok and type(value) == "table", "Komga 返回了无效 JSON")
    return value
end

function K.pages(config, address)
    local id = K.id(address, "books")
    local result = K.json(config, "/api/v1/books/" .. id .. "/pages")
    assert(#result > 0, "章节没有可读页面")
    assert(#result <= 10000, "章节页数过多")
    local pages = {}
    for i, page in ipairs(result) do
        assert(type(page.number) == "number" and page.number >= 1 and page.number == math.floor(page.number), "Komga 页码无效")
        pages[i] = { number = page.number, mediaType = page.mediaType }
    end
    return pages
end

function K.downloadPage(config, address, page, path)
    local bytes, code = H.request(config, "komga", "GET", K.bookUrl(config, address)
        .. "/pages/" .. page.number .. "?convert=png", nil, nil, path)
    assert(code == 200 and bytes > 0, "页面下载失败（HTTP " .. tostring(code) .. "）")
end

function K.coverUrl(config, manga)
    for _, kind in ipairs({ "series", "books", "readlists" }) do
        if manga.url:find("/api/v1/" .. kind .. "/", 1, true) then
            return H.validateBase(config.komga_url) .. "/api/v1/" .. kind .. "/" .. K.id(manga.url, kind) .. "/thumbnail"
        end
    end
    if manga.chapters[1] then return K.bookUrl(config, manga.chapters[1].url) .. "/thumbnail" end
end

function K.downloadCover(config, manga, path)
    local url = K.coverUrl(config, manga)
    if not url then return false end
    local bytes, code = H.request(config, "komga", "GET", url, nil, nil, path)
    return code == 200 and bytes > 0
end

return K
