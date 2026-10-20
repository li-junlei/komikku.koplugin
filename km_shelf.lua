local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local ButtonTable = require("ui/widget/buttontable")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Grid = InputContainer:extend{ covers_fullscreen = true }
local Tile = InputContainer:extend{}

function Grid.page(mangas, page)
    local total = math.max(1, math.ceil(#mangas / 6))
    page = math.max(1, math.min(page or 1, total))
    local entries = {}
    for i = (page - 1) * 6 + 1, math.min(page * 6, #mangas) do entries[#entries + 1] = mangas[i] end
    return entries, page, total
end

function Tile:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local pad = Device.screen:scaleBySize(6)
    local w, h = self.width - 2 * pad - 2, self.height - 2 * pad - 2
    local title_h = Device.screen:scaleBySize(36)
    local status = TextWidget:new{ text = self.entry.status, face = Font:getFace("smallinfofont"), max_width = w }
    local image_h = math.max(16, h - title_h - status:getSize().h)
    local cover
    if self.entry.file then
        cover = require("ui/widget/imagewidget"):new{
            file = self.entry.file, width = w, height = image_h, scale_factor = 0, file_do_cache = false,
        }
        if not pcall(cover.getSize, cover) then cover:free(); os.remove(self.entry.file); cover = nil end
    end
    cover = cover or CenterContainer:new{
        dimen = Geom:new{ w = w, h = image_h },
        TextWidget:new{ text = "暂无封面", face = Font:getFace("smallinfofont") },
    }
    self[1] = FrameContainer:new{
        padding = pad, bordersize = 1,
        CenterContainer:new{ dimen = Geom:new{ w = w, h = h },
            VerticalGroup:new{ align = "center", cover,
                TextBoxWidget:new{
                    text = self.entry.manga.title, face = Font:getFace("smallinfofont"),
                    width = w, height = title_h, alignment = "center", height_overflow_show_ellipsis = true,
                }, status,
            },
        },
    }
    self.ges_events.Select = { require("ui/gesturerange"):new{ ges = "tap", range = self.dimen } }
end

function Tile:onSelect() self.callback(self.entry.manga); return true end

function Grid:init()
    local screen = Device.screen
    self.dimen = screen:getSize()
    local pad = screen:scaleBySize(6)
    local width = self.dimen.w - 2 * pad
    local title = TextWidget:new{
        text = self.title_text or (#self.entries > 0 and "Komikku 缩略图书架" or "此分类暂无漫画"),
        face = Font:getFace("smalltfont"), max_width = width,
    }
    local header = ButtonTable:new{ width = width, buttons = { self.header_buttons or {
        { text = "列表", callback = self.on_list },
        { text = "分类", callback = self.on_categories },
        { text = "同步", callback = self.on_sync },
        { text = "继续阅读", callback = self.on_resume },
        { text = "关闭", callback = function() self:onClose() end },
    } } }
    local footer = ButtonTable:new{ width = width, buttons = { {
        { text = "上一页", enabled = self.page_number > 1, callback = function() self:onPrevPage() end },
        { text = self.page_number .. " / " .. self.page_count, enabled = false },
        { text = "下一页", enabled = self.page_number < self.page_count, callback = function() self:onNextPage() end },
    } } }
    local cell_w = math.floor(width / 2)
    local cell_h = math.floor((self.dimen.h - 2 * pad - title:getSize().h - header:getSize().h - footer:getSize().h) / 3)
    local layout = VerticalGroup:new{ align = "center", title, header }
    for row = 0, 2 do
        local line = HorizontalGroup:new{}
        for col = 1, 2 do
            local entry = self.entries[row * 2 + col]
            line[#line + 1] = entry and Tile:new{
                entry = entry, width = cell_w, height = cell_h, callback = self.on_select,
            } or require("ui/widget/container/widgetcontainer"):new{ dimen = Geom:new{ w = cell_w, h = cell_h } }
        end
        layout[#layout + 1] = line
    end
    layout[#layout + 1] = footer
    self[1] = FrameContainer:new{
        background = require("ffi/blitbuffer").COLOR_WHITE, padding = 0, bordersize = 0,
        CenterContainer:new{ dimen = self.dimen:copy(), layout },
    }
    if Device:hasKeys() then
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PrevPage = { { Device.input.group.PgBack } }
        self.key_events.Close = { { Device.input.group.Back } }
    end
end

function Grid:onNextPage()
    if self.page_number < self.page_count then self.on_page(self.page_number + 1) end
    return true
end

function Grid:onPrevPage()
    if self.page_number > 1 then self.on_page(self.page_number - 1) end
    return true
end

function Grid:onClose() UIManager:close(self); return true end
function Grid:onShow() UIManager:setDirty(self, "ui"); return true end
function Grid:onCloseWidget()
    self.closed = true
    self:free()
    if self.on_closed then self.on_closed() end
    UIManager:setDirty(nil, "ui")
end

return Grid
