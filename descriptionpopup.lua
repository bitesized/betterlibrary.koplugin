--[[--
The popup opened by the info button of the large-cover layouts: a small
cover, the title and author, the reading status and the full description,
with a button to open the book.

@module koplugin.betterlibrary.descriptionpopup
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local MovableContainer = require("ui/widget/container/movablecontainer")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local Screen = Device.screen
local T = require("ffi/util").template

local BookInfoManager = require("bookinfomanager")

local COLOR_SECONDARY = Blitbuffer.Color8(0x40)
local COLOR_MUTED = Blitbuffer.Color8(0x55)
local COLOR_SEPARATOR = Blitbuffer.Color8(0xC8)

local DescriptionPopup = InputContainer:extend{
    filepath = nil,
    details = nil, -- what LargeCoverItem gathered about the book
    open_callback = nil,
}

function DescriptionPopup:init()
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{
                    x = 0, y = 0,
                    w = Screen:getWidth(),
                    h = Screen:getHeight(),
                }
            }
        }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    local details = self.details
    local width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.86)
    local padding = Screen:scaleBySize(14)
    local inner_w = width - 2 * padding

    -- Header: small cover, title, author, file info and reading status
    local cover_h = Screen:scaleBySize(104)
    local cover_w = Screen:scaleBySize(70)
    local cover
    local bookinfo = BookInfoManager:getBookInfo(self.filepath, true)
    if bookinfo and bookinfo.cover_bb and bookinfo.has_cover and not bookinfo.ignore_cover then
        local scale_factor = select(3, BookInfoManager.getCachedCoverSize(bookinfo.cover_w, bookinfo.cover_h, cover_w, cover_h))
        self.cover_image = ImageWidget:new{
            image = bookinfo.cover_bb,
            image_disposable = true, -- the blitbuffer is ours, free it with the widget
            scale_factor = scale_factor,
        }
        self.cover_image:_render()
        local size = self.cover_image:getSize()
        cover = FrameContainer:new{
            width = size.w + 2 * Size.border.thin,
            height = size.h + 2 * Size.border.thin,
            margin = 0,
            padding = 0,
            bordersize = Size.border.thin,
            self.cover_image,
        }
    elseif bookinfo and bookinfo.cover_bb then
        bookinfo.cover_bb:free()
    end

    local close_button = IconButton:new{
        icon = "close",
        width = Screen:scaleBySize(24),
        height = Screen:scaleBySize(24),
        padding = Screen:scaleBySize(4),
        callback = function() self:onClose() end,
        show_parent = self,
    }

    local text_w = inner_w - close_button:getSize().w - Screen:scaleBySize(8)
    if cover then
        text_w = text_w - cover:getSize().w - Screen:scaleBySize(12)
    end
    local header_text = VerticalGroup:new{
        align = "left",
        TextBoxWidget:new{
            text = details.title,
            lang = details.language,
            face = Font:getFace("cfont", 18),
            width = text_w,
            alignment = "left",
            bold = true,
        },
    }
    local function addLine(text, size, color, bold)
        table.insert(header_text, TextWidget:new{
            text = text,
            face = Font:getFace("cfont", size),
            bold = bold,
            max_width = text_w,
            fgcolor = color,
        })
    end
    if details.authors then
        addLine(details.authors, 15, COLOR_SECONDARY)
    end
    local info_parts = {}
    if details.filetype then
        table.insert(info_parts, details.filetype)
    end
    if details.pages then
        table.insert(info_parts, T(N_("1 page", "%1 pages", details.pages), details.pages))
    end
    if #info_parts > 0 then
        table.insert(header_text, VerticalSpan:new{ width = Screen:scaleBySize(4) })
        addLine(table.concat(info_parts, " · "), 13, COLOR_MUTED)
    end
    addLine(self:getStatusText(), 13, Blitbuffer.COLOR_BLACK, true)

    local header = HorizontalGroup:new{ align = "top" }
    if cover then
        table.insert(header, cover)
        table.insert(header, HorizontalSpan:new{ width = Screen:scaleBySize(12) })
    end
    table.insert(header, header_text)
    table.insert(header, HorizontalSpan:new{ width = Screen:scaleBySize(8) })
    table.insert(header, close_button)

    -- Description, scrollable when it is long
    local description = details.description and util.htmlToPlainTextIfHtml(details.description)
    local face = Font:getFace("NotoSerif-Regular.ttf", 16) or Font:getFace("cfont", 16)
    if not description or description:match("^%s*$") then
        description = _("No description available.")
    end
    local measure = TextBoxWidget:new{
        text = description,
        face = face,
        width = inner_w - Screen:scaleBySize(12), -- room for the scroll bar
        for_measurement_only = true,
    }
    local text_h = measure:getSize().h
    measure:free(true)
    local max_text_h = math.floor(Screen:getHeight() * 0.45)
    local description_widget = ScrollTextWidget:new{
        text = description,
        lang = details.language,
        face = face,
        width = inner_w,
        height = math.min(text_h, max_text_h),
        dialog = self,
    }

    local is_finished = details.status == "complete"
    local open_text
    if is_finished then
        open_text = _("Read again")
    elseif details.been_opened then
        open_text = _("Continue reading")
    else
        open_text = _("Start reading")
    end
    local button_table = ButtonTable:new{
        width = width,
        buttons = {{
            {
                text = _("Close"),
                callback = function() self:onClose() end,
            },
            {
                text = open_text,
                callback = function()
                    self:onClose()
                    if self.open_callback then
                        self.open_callback()
                    end
                end,
            },
        }},
        zero_sep = true,
        show_parent = self,
    }

    local separator = LineWidget:new{
        dimen = Geom:new{ w = inner_w, h = Size.line.thin },
        background = COLOR_SEPARATOR,
    }

    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            FrameContainer:new{
                bordersize = 0,
                padding = padding,
                padding_bottom = 0,
                VerticalGroup:new{
                    align = "left",
                    header,
                    VerticalSpan:new{ width = Screen:scaleBySize(12) },
                    separator,
                    VerticalSpan:new{ width = Screen:scaleBySize(12) },
                    description_widget,
                },
            },
            VerticalSpan:new{ width = padding },
            button_table,
        },
    }
    self.movable = MovableContainer:new{
        self.frame,
    }
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.movable,
    }
end

function DescriptionPopup:getStatusText()
    local details = self.details
    if details.status == "complete" then
        return _("Finished")
    elseif details.been_opened and details.percent_finished then
        local percent = math.floor(100 * details.percent_finished)
        if details.status == "abandoned" then
            return T(_("On hold · %1 % read"), percent)
        end
        return T(_("%1 % read"), percent)
    end
    return _("Not started")
end

function DescriptionPopup:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.movable.dimen
    end)
end

function DescriptionPopup:onCloseWidget()
    if self.cover_image then
        self.cover_image:free()
        self.cover_image = nil
    end
    UIManager:setDirty(nil, function()
        return "ui", self.movable.dimen
    end)
end

function DescriptionPopup:onClose()
    UIManager:close(self)
    return true
end

function DescriptionPopup:onTapClose(arg, ges)
    if ges.pos:notIntersectWith(self.movable.dimen) then
        self:onClose()
    end
    -- Don't let it propagate to underlying widgets
    return true
end

return DescriptionPopup
