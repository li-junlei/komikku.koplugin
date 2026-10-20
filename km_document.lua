local PdfDocument = require("document/pdfdocument")
local Document = require("document/document")
local D = PdfDocument:extend{
    provider = "komikku", provider_name = "Komga 漫画", is_pdf = false, is_komikku = true,
}

function D:init()
    local App = require("km_app")
    App:init()
    local bytes = assert(require("km_files").read(self.file), "章节清单不存在")
    local m = require("json").decode(bytes)
    local dir = self.file:match("^(.*)/[^/]+$")
    assert(dir == App.cache:directory(m.address), "章节清单不属于当前 Komga 配置")
    self.km_manifest, self.km_dir = m, dir
    self.koptinterface = require("document/koptinterface")
    self.koptinterface:setDefaultConfigurable(self.configurable)
    self.is_reflowable, self.is_writable = false, false
    self.reflowable_font_size = 22
    self.render_mode = 0
    local owner, color = self, false
    self._document = {
        getPages = function() return #m.pages end,
        getToc = function() return {} end,
        getMetadata = function() return { title = m.title or "Komga" } end,
        setColorRendering = function(_, value) color = value end,
        getCacheSize = function() return 0 end,
        cleanCache = function() end,
        close = function() end,
        openPage = function(_, number)
            assert(number >= 1 and number <= #m.pages, "页码越界")
            local pdf = require("ffi/mupdf")
            local ok, path = pcall(App.cache.ensure, App.cache, m, dir, number)
            local image
            if ok then
                local opened, result = pcall(pdf.openDocument, path)
                if opened then image = result else os.remove(path); ok = false end
            end
            if not ok then
                owner.km_error = "页面加载失败。请检查网络，在插件菜单中选择“重试当前章节”。"
                image = pdf.openDocumentFromText("<html><body><h2>Page unavailable</h2><p>Check Wi-Fi, then retry this chapter from the Komikku menu.</p></body></html>", "text/html")
                image:layoutDocument(758, 1024, 22)
            end
            image:setColorRendering(color)
            local page = image:openPage(1)
            -- Keep the single-image document alive until its native page has been released.
            return setmetatable({ close = function()
                page:close()
                image:close()
            end }, { __index = function(_, k)
                local value = page[k]
                if type(value) == "function" then return function(_, ...) return value(page, ...) end end
                return value
            end })
        end,
    }
    self:updateColorRendering()
    self.is_open = true
    self.info.has_pages, self.info.configurable = true, true
    self:_readMetadata()
    self.mod_time = tostring(self.mod_time or 0) .. ":" .. tostring(require("socket").gettime())
end

function D:getUsedBBox(pageno)
    local page = self._document:openPage(pageno)
    local w, h = page:getSize(self.dc_null)
    page:close()
    return { x0 = 0, y0 = 0, x1 = w, y1 = h }
end

function D:layoutDocument() end
function D:getEmbeddedAnnotations() return {} end
function D:writeDocument() end

function D:register(registry)
    registry:addProvider("kmk", "application/x-komikku-chapter", self, 100)
end

return D
