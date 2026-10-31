--[[--
The large-cover layouts of the file browser.

Like coverbrowser's ListMenu and MosaicMenu, this is a holder of the two
methods that coverbrowser's CoverMenu expects to find on the menu:

    :_recalculateDimen()
    :_updateItemsBuildUI()

CoverMenu does the rest (paging, background extraction of book information,
refreshing the items that were not yet known), so our items follow the same
contract as ListMenuItem: they have an update() that can be called again
once their book information has been extracted, and set bookinfo_found,
filepath, cover_specs and _has_cover_image.

There are four layouts, picked with the "betterlibrary_layout" setting:

* A: a list of 3 big covers per page, details on the right
* B: a 2×2 grid of cards, the cover above a short caption
* C: a 3×2 grid, with a longer caption
* D: a list of 2 even bigger covers per page, with the start of the description

@module koplugin.betterlibrary.largecovermenu
--]]--

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Math = require("optmath")
local ProgressWidget = require("ui/widget/progresswidget")
local ReadHistory = require("readhistory")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local datetime = require("datetime")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local Screen = Device.screen
local T = require("ffi/util").template
local getMenuText = require("ui/widget/menu").getMenuText

local BookInfoManager = require("bookinfomanager")
local DescriptionPopup = require("descriptionpopup")

local LAYOUT_SETTING = "betterlibrary_layout"
local INFO_BUTTON_SETTING = "betterlibrary_info_button"

local COLOR_INK = Blitbuffer.COLOR_BLACK
local COLOR_SECONDARY = Blitbuffer.Color8(0x40)
local COLOR_MUTED = Blitbuffer.Color8(0x55)
local COLOR_SEPARATOR = Blitbuffer.Color8(0xC8)

local function px(n)
    return Screen:scaleBySize(n)
end

-- Grid shape and sizes of each layout. Sizes are those of the mockups, which
-- were drawn on a 600×800 screen, and are scaled like the rest of KOReader.
local LAYOUTS = {
    A = {
        kind = "list",
        cols = 1, rows = 3,
        cols_landscape = 1, rows_landscape = 2,
        padding = 10, gap = 16,
        title_size = 22, title_lines = 2,
        author_size = 17,
        info_size = 14,
        status_size = 14, bar_height = 8,
        info_button = true,
        last_read = true,
    },
    B = {
        kind = "grid",
        cols = 2, rows = 2,
        cols_landscape = 4, rows_landscape = 1,
        margin = 14,
        title_size = 16, title_lines = 1,
        author_size = 14,
        status_size = 13, bar_height = 7,
        info_button = true,
    },
    C = {
        kind = "grid",
        cols = 3, rows = 2,
        cols_landscape = 5, rows_landscape = 1,
        margin = 10,
        title_size = 14, title_lines = 2,
        author_size = 13,
        pages_size = 12,
        status_size = 12, bar_height = 6,
        info_button = true,
    },
    D = {
        kind = "list",
        cols = 1, rows = 2,
        cols_landscape = 1, rows_landscape = 1,
        padding = 12, gap = 22,
        title_size = 24, title_lines = 2,
        author_size = 18,
        info_size = 13,
        description_size = 15, description_lines = 4,
        status_size = 14, bar_height = 10,
        info_button = false,
        last_read = true,
        pages_left = true,
    },
}

local function getLayoutName()
    local name = G_reader_settings:readSetting(LAYOUT_SETTING)
    return LAYOUTS[name] and name or "A"
end

local function getFace(size, serif)
    if serif then
        return Font:getFace("NotoSerif-Regular.ttf", size) or Font:getFace("cfont", size)
    end
    return Font:getFace("cfont", size)
end

-- A TextBoxWidget showing at most max_lines lines, with an ellipsis if the
-- text is longer, and only as tall as the text when it is shorter.
local function clampedTextBox(args, max_lines)
    local widget = TextBoxWidget:new(args)
    if max_lines and widget:getSize().h > max_lines * widget.line_height_px then
        widget:free(true)
        args.height = max_lines * widget.line_height_px
        args.height_adjust = true
        args.height_overflow_show_ellipsis = true
        widget = TextBoxWidget:new(args)
    end
    return widget
end

local function lineHeight(face)
    -- TextBoxWidget's default line height is 1.3em
    return Math.round(1.3 * face.size)
end

local function getLastReadTime(filepath)
    local index = ReadHistory:getIndexByFile(filepath)
    return index and ReadHistory.hist[index].time
end

local function startOfDay(time)
    local t = os.date("*t", time)
    t.hour, t.min, t.sec = 0, 0, 0
    return os.time(t)
end

local function formatLastRead(time)
    local days = Math.round((startOfDay(os.time()) - startOfDay(time)) / 86400)
    if days <= 0 then
        return _("today")
    elseif days == 1 then
        return _("yesterday")
    elseif days < 7 then
        return T(N_("1 day ago", "%1 days ago", days), days)
    end
    return datetime.secondsToDate(time, true)
end

-- The small "i" in a circle that opens the description popup.
-- crengine separates multiple authors with "\n": show the first one, and
-- "et al." when there are more.
local function formatAuthors(authors)
    local list = util.splitToArray(authors, "\n")
    if #list == 0 then
        return nil
    end
    if #list > 1 then
        return T(_("%1 et al."), BD.auto(list[1]))
    end
    return BD.auto(list[1])
end

local function buildInfoButton(size)
    local diameter = px(size)
    return FrameContainer:new{
        width = diameter,
        height = diameter,
        radius = math.floor(diameter / 2),
        bordersize = Size.border.thick,
        color = COLOR_INK,
        margin = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = diameter - 2 * Size.border.thick, h = diameter - 2 * Size.border.thick },
            TextWidget:new{
                text = "i",
                face = getFace(math.floor(size * 0.6), true),
                bold = true,
                fgcolor = COLOR_INK,
            },
        },
    }
end

-- The bordered small caps "NEW" tag shown on books that were never opened.
local function buildNewTag(font_size)
    return FrameContainer:new{
        bordersize = Size.border.thin,
        color = COLOR_INK,
        margin = 0,
        padding = 0,
        padding_left = px(4),
        padding_right = px(4),
        TextWidget:new{
            text = _("NEW"),
            face = getFace(math.max(8, font_size - 3)),
            bold = true,
            fgcolor = COLOR_INK,
        },
    }
end


local LargeCoverItem = InputContainer:extend{
    entry = nil, -- hash, mandatory
    text = nil,
    show_parent = nil,
    dimen = nil,
    menu = nil,
    layout = nil, -- one of LAYOUTS
    show_info_button = true,
    init_done = false,
    bookinfo_found = false,
    cover_specs = nil,
    _underline_container = nil,
}

function LargeCoverItem:init()
    -- filepath may be provided as 'file' (history, collection) or 'path' (filechooser)
    self.filepath = self.entry.file or self.entry.path

    self.ges_events = {
        TapSelect = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
        HoldSelect = {
            GestureRange:new{
                ges = "hold",
                range = self.dimen,
            },
        },
    }

    self.underline_h = 1
    self._underline_container = UnderlineContainer:new{
        vertical_align = "top",
        padding = 0,
        dimen = Geom:new{
            w = self.width,
            h = self.height
        },
        linesize = self.underline_h,
        background = Blitbuffer.COLOR_WHITE,
        -- widget : will be filled in self:update()
    }
    self[1] = self._underline_container

    -- As with ListMenuItem, the rest is done in update(), which may be called
    -- again once the book information has been extracted
    self:update()
    self.init_done = true
end

-- The size of the box the cover is fitted into, for this layout.
function LargeCoverItem:getCoverBox()
    local layout = self.layout
    local border = Size.border.thin
    if layout.kind == "list" then
        local h = self.content_h - 2 * px(layout.padding)
        return math.floor(h * 2 / 3) - 2 * border, h - 2 * border
    end
    return self.width - 2 * border, self.content_h - self:getCaptionHeight() - px(6) - 2 * border
end

-- Height of the caption under the cover, in the grid layouts: as tall as the
-- longest caption could be, so that covers in a row line up.
function LargeCoverItem:getCaptionHeight()
    local layout = self.layout
    local h = layout.title_lines * lineHeight(getFace(layout.title_size))
        + lineHeight(getFace(layout.author_size))
        + px(4) + math.max(lineHeight(getFace(layout.status_size)), px(layout.bar_height))
    if layout.pages_size then
        h = h + lineHeight(getFace(layout.pages_size))
    end
    return h
end

function LargeCoverItem:update()
    local layout = self.layout
    self.content_h = self.height - 2 * self.underline_h

    local max_cover_w, max_cover_h = self:getCoverBox()
    self.cover_specs = {
        max_cover_w = max_cover_w,
        max_cover_h = max_cover_h,
    }
    -- Make it available to our menu, for batch extraction
    -- to know what size is needed for current view
    self.menu.cover_specs = self.cover_specs

    self.is_directory = not (self.entry.is_file or self.entry.file)
    local info
    if self.is_directory then
        info = {
            title = BD.directory(self.text),
            subtitle = self.mandatory,
            is_directory = true,
        }
    else
        self.file_deleted = self.entry.dim -- selected file in the file browser's select mode
        info = self:getBookDetails()
    end
    self.details = info

    local widget
    if layout.kind == "list" then
        widget = self:buildListItem(info)
    else
        widget = self:buildGridItem(info)
    end

    if self._underline_container[1] then
        -- There is a previous one, that we need to free()
        self._underline_container[1]:free()
    end
    self._underline_container[1] = VerticalGroup:new{
        VerticalSpan:new{ width = self.underline_h },
        widget,
    }
end

-- Everything we show about a book, from the book information database and
-- from its sidecar file. Also builds the cover.
function LargeCoverItem:getBookDetails()
    local bookinfo = BookInfoManager:getBookInfo(self.filepath, true)
    if bookinfo and not bookinfo.ignore_cover and not self.file_deleted then
        if bookinfo.cover_fetched then
            if bookinfo.has_cover and BookInfoManager.isCachedCoverInvalid(bookinfo, self.cover_specs) then
                -- there is a thumbnail, but it's smaller than is needed for
                -- our covers: do as if not found to force a new extraction
                if bookinfo.cover_bb then
                    bookinfo.cover_bb:free()
                end
                bookinfo = nil
            end
        else
            -- cover was not fetched previously, do as if not found
            -- to force a new extraction
            bookinfo = nil
        end
    end

    local filename = select(2, util.splitFilePathName(self.filepath))
    local filename_without_suffix, filetype = filemanagerutil.splitFileNameType(filename)
    local book_info = self.menu.getBookInfo(self.filepath)
    local info = {
        title = BD.filename(self.text),
        filetype = filetype and filetype:upper(),
        filesize = self.mandatory,
        been_opened = book_info.been_opened,
        percent_finished = book_info.percent_finished,
        status = book_info.status,
        pages = book_info.pages,
    }
    if book_info.been_opened then
        info.last_read = getLastReadTime(self.filepath)
    end
    if not bookinfo then
        -- not yet in the database: shown with the filename until it is
        info.title = BD.filename(self.text) .. " …"
        return info
    end

    self.bookinfo_found = true
    info.pages = info.pages or bookinfo.pages
    info.language = bookinfo.language
    info.description = bookinfo.description
    if bookinfo._no_provider then
        info.filetype = nil
        info.title = BD.filename(filename)
    elseif bookinfo.ignore_meta then
        info.title = BD.auto(filename_without_suffix)
    else
        info.title = BD.auto(bookinfo.title or filename_without_suffix)
        if bookinfo.authors then
            info.authors = formatAuthors(bookinfo.authors)
        end
        if bookinfo.series then
            info.series = bookinfo.series_index and bookinfo.series .. " #" .. bookinfo.series_index or bookinfo.series
        end
    end
    if bookinfo.unsupported then
        info.authors = T(_("(no book information: %1)"), _(bookinfo.unsupported))
    end

    if bookinfo.has_cover and not bookinfo.ignore_cover and not self.file_deleted then
        local scale_factor = select(3, BookInfoManager.getCachedCoverSize(bookinfo.cover_w, bookinfo.cover_h,
            self.cover_specs.max_cover_w, self.cover_specs.max_cover_h))
        info.cover = ImageWidget:new{
            image = bookinfo.cover_bb,
            scale_factor = scale_factor,
        }
        info.cover:_render()
        self.menu._has_cover_images = true
        self._has_cover_image = true
    elseif bookinfo.cover_bb then
        -- In case we got a blitbuffer and didn't use it (ignore_cover), free it
        bookinfo.cover_bb:free()
    end
    return info
end

-- The cover, framed, centered in a box of the given size. Books without a
-- cover, and folders, get a plain frame with their name in it.
function LargeCoverItem:buildCover(info, box_w, box_h, valign)
    local border = Size.border.thin
    local max_w, max_h = self.cover_specs.max_cover_w, self.cover_specs.max_cover_h
    local frame
    if info.cover then
        local size = info.cover:getSize()
        frame = FrameContainer:new{
            width = size.w + 2 * border,
            height = size.h + 2 * border,
            margin = 0,
            padding = 0,
            bordersize = border,
            info.cover,
        }
    else
        local w = math.floor(max_h * 2 / 3)
        if w > max_w then w = max_w end
        local text_w = w - 2 * px(8)
        frame = FrameContainer:new{
            width = w + 2 * border,
            height = max_h + 2 * border,
            margin = 0,
            padding = 0,
            bordersize = info.is_directory and Size.border.thick or border,
            dim = self.file_deleted,
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = max_h },
                clampedTextBox({
                    text = info.title,
                    face = getFace(math.max(12, math.floor(self.layout.title_size * 0.8))),
                    width = text_w,
                    alignment = "center",
                    bold = true,
                    fgcolor = COLOR_SECONDARY,
                }, math.max(1, math.floor(max_h * 0.8 / lineHeight(getFace(self.layout.title_size))))),
            },
        }
    end
    if self.file_deleted and info.cover then
        frame.dim = true
    end
    local frame_size = frame:getSize()
    local container = CenterContainer:new{
        dimen = Geom:new{ w = box_w, h = frame_size.h },
        frame,
    }
    if valign == "bottom" and frame_size.h < box_h then
        return VerticalGroup:new{
            VerticalSpan:new{ width = box_h - frame_size.h },
            container,
        }
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = box_w, h = box_h },
        container,
    }
end

-- The title, with the info button on its right when it is shown.
function LargeCoverItem:buildTitleRow(info, width)
    local layout = self.layout
    local face = getFace(layout.title_size)
    local button
    if layout.info_button and self.show_info_button and not info.is_directory and self.bookinfo_found then
        button = buildInfoButton(math.max(20, math.floor(layout.title_size * 1.15)))
    end
    local title_w = width
    if button then
        title_w = width - button:getSize().w - px(8)
    end
    local title
    if layout.title_lines == 1 then
        title = TextWidget:new{
            text = info.title,
            face = face,
            bold = true,
            max_width = title_w,
            fgcolor = COLOR_INK,
        }
    else
        title = clampedTextBox({
            text = info.title,
            lang = info.language,
            face = face,
            width = title_w,
            alignment = "left",
            bold = true,
            fgcolor = COLOR_INK,
        }, layout.title_lines)
    end
    self._info_button = button
    if not button then
        return title
    end
    return HorizontalGroup:new{
        align = "top",
        LeftContainer:new{
            dimen = Geom:new{ w = title_w, h = title:getSize().h },
            title,
        },
        HorizontalSpan:new{ width = width - title_w - button:getSize().w },
        button,
    }
end

function LargeCoverItem:buildLine(text, size, color, width, bold)
    return TextWidget:new{
        text = text,
        face = getFace(size),
        bold = bold,
        max_width = width,
        fgcolor = color,
    }
end

-- "EPUB · 412 pages · 1.2 MB"
function LargeCoverItem:getInfoLine(info)
    local parts = {}
    if info.filetype then
        table.insert(parts, info.filetype)
    end
    if info.pages then
        table.insert(parts, T(N_("1 page", "%1 pages", info.pages), info.pages))
    end
    if info.filesize then
        table.insert(parts, info.filesize)
    end
    return table.concat(parts, " · ")
end

-- The reading progress: a bar and the percentage, a NEW tag, or a check
-- mark and "Finished". The list layouts add when the book was last read.
function LargeCoverItem:buildStatus(info, width)
    local layout = self.layout
    local size = layout.status_size
    local face = getFace(size)
    local last_read = layout.last_read and info.last_read and formatLastRead(info.last_read)

    if info.status == "complete" then
        local icon_size = lineHeight(face) - px(2)
        local text = _("Finished")
        if last_read then
            text = text .. " · " .. last_read
        end
        return HorizontalGroup:new{
            align = "center",
            IconWidget:new{
                icon = "check",
                width = icon_size,
                height = icon_size,
            },
            HorizontalSpan:new{ width = px(4) },
            self:buildLine(text, size, COLOR_INK, width - icon_size - px(4), true),
        }
    end

    if not info.been_opened or not info.percent_finished then
        return buildNewTag(size)
    end

    local percent = math.floor(100 * info.percent_finished)
    local label
    if info.status == "abandoned" then
        label = T(_("On hold · %1 %"), percent)
    elseif layout.kind == "list" then
        label = T(_("%1 % read"), percent)
    else
        label = T(_("%1 %"), percent)
    end
    local function buildBar(bar_width)
        return ProgressWidget:new{
            width = bar_width,
            height = px(layout.bar_height),
            percentage = info.percent_finished,
            margin_h = 0,
            margin_v = 0,
            radius = 0,
            bordersize = Size.border.thin,
            bordercolor = COLOR_INK,
            bgcolor = Blitbuffer.COLOR_WHITE,
            fillcolor = COLOR_INK,
        }
    end
    local bar_row, second_line
    if layout.pages_left and info.pages then
        -- the percentage goes on the line under the bar, with the pages left
        local left = info.pages - Math.round(info.percent_finished * info.pages)
        second_line = T(_("%1 % · %2"), percent, T(N_("1 page left", "%1 pages left", left), left))
        if info.status == "abandoned" then
            second_line = _("On hold") .. " · " .. second_line
        end
        bar_row = buildBar(width)
    else
        local wlabel = self:buildLine(label, size, COLOR_SECONDARY, math.floor(width / 2))
        local gap = px(8)
        bar_row = HorizontalGroup:new{
            align = "center",
            buildBar(width - wlabel:getSize().w - gap),
            HorizontalSpan:new{ width = gap },
            wlabel,
        }
    end
    if last_read then
        local text = T(_("Last read %1"), last_read)
        second_line = second_line and second_line .. " · " .. text or text
    end
    if not second_line then
        return bar_row
    end
    return VerticalGroup:new{
        align = "left",
        bar_row,
        VerticalSpan:new{ width = px(4) },
        self:buildLine(second_line, size - 1, COLOR_MUTED, width),
    }
end

-- Layouts A and D: the cover on the left, the details on the right, with the
-- reading progress at the bottom.
function LargeCoverItem:buildListItem(info)
    local layout = self.layout
    local pad = px(layout.padding)
    local cover_box_w = self.cover_specs.max_cover_w + 2 * Size.border.thin
    local cover_box_h = self.content_h - 2 * pad
    local text_w = self.width - 2 * pad - cover_box_w - px(layout.gap)
    local text_h = cover_box_h

    local top = VerticalGroup:new{ align = "left" }
    table.insert(top, self:buildTitleRow(info, text_w))
    local author = info.authors or info.subtitle
    if author then
        table.insert(top, VerticalSpan:new{ width = px(4) })
        table.insert(top, self:buildLine(author, layout.author_size, COLOR_SECONDARY, text_w))
    end
    if info.series then
        table.insert(top, self:buildLine(info.series, layout.info_size, COLOR_MUTED, text_w))
    end
    if not info.is_directory then
        local line = self:getInfoLine(info)
        if line ~= "" then
            table.insert(top, VerticalSpan:new{ width = px(6) })
            table.insert(top, self:buildLine(line, layout.info_size, COLOR_MUTED, text_w))
        end
    end

    local bottom
    if not info.is_directory then
        bottom = self:buildStatus(info, text_w)
    end
    local bottom_h = bottom and bottom:getSize().h or 0

    if layout.description_size and info.description then
        local face = getFace(layout.description_size, true)
        local available = text_h - top:getSize().h - bottom_h - 2 * px(10)
        local lines = math.min(layout.description_lines, math.floor(available / lineHeight(face)))
        if lines > 0 then
            local text = util.htmlToPlainTextIfHtml(info.description):gsub("%s+", " ")
            table.insert(top, VerticalSpan:new{ width = px(10) })
            table.insert(top, clampedTextBox({
                text = text,
                lang = info.language,
                face = face,
                width = text_w,
                alignment = "left",
                fgcolor = COLOR_INK,
            }, lines))
            -- top was measured above, before these were added
            top:resetLayout()
        end
    end

    local column = VerticalGroup:new{ align = "left", top }
    if bottom then
        local filler = text_h - top:getSize().h - bottom_h
        if filler > 0 then
            table.insert(column, VerticalSpan:new{ width = filler })
        else
            table.insert(column, VerticalSpan:new{ width = px(6) })
        end
        table.insert(column, bottom)
    end

    return FrameContainer:new{
        bordersize = 0,
        margin = 0,
        padding = pad,
        HorizontalGroup:new{
            align = "top",
            self:buildCover(info, cover_box_w, cover_box_h),
            HorizontalSpan:new{ width = px(layout.gap) },
            LeftContainer:new{
                dimen = Geom:new{ w = text_w, h = text_h },
                column,
            },
        },
    }
end

-- Layouts B and C: the cover, with the caption under it.
function LargeCoverItem:buildGridItem(info)
    local layout = self.layout
    local width = self.width
    local caption_h = self:getCaptionHeight()
    local cover_h = self.content_h - caption_h - px(6)

    local caption = VerticalGroup:new{ align = "left" }
    table.insert(caption, self:buildTitleRow(info, width))
    local author = info.authors or info.subtitle
    if author then
        table.insert(caption, self:buildLine(author, layout.author_size, COLOR_SECONDARY, width))
    end
    if layout.pages_size and info.pages and not info.is_directory then
        table.insert(caption, self:buildLine(T(N_("1 page", "%1 pages", info.pages), info.pages),
            layout.pages_size, COLOR_MUTED, width))
    end
    if not info.is_directory then
        table.insert(caption, VerticalSpan:new{ width = px(4) })
        table.insert(caption, self:buildStatus(info, width))
    end

    return VerticalGroup:new{
        align = "left",
        self:buildCover(info, width, cover_h, "bottom"),
        VerticalSpan:new{ width = px(6) },
        LeftContainer:new{
            dimen = Geom:new{ w = width, h = caption_h },
            caption,
        },
    }
end

function LargeCoverItem:getFocusIndicatorRegion()
    return self._underline_container and self._underline_container:getFocusIndicatorRegion()
end

function LargeCoverItem:repaintFocusIndicator(bb)
    return self._underline_container and self._underline_container:repaintFocusIndicator(bb)
end

function LargeCoverItem:onFocus()
    self._underline_container.color = Blitbuffer.COLOR_BLACK
    self._underline_container.focused = true
    return true
end

function LargeCoverItem:onUnfocus()
    self._underline_container.color = Blitbuffer.COLOR_WHITE
    self._underline_container.focused = false
    return true
end

-- Is this tap on the info button? It is small, so be generous with the area.
function LargeCoverItem:isOnInfoButton(ges)
    local button = self._info_button
    if not (button and button.dimen and ges and ges.pos) then
        return false
    end
    local slack = px(10)
    local area = Geom:new{
        x = button.dimen.x - slack,
        y = button.dimen.y - slack,
        w = button.dimen.w + 2 * slack,
        h = button.dimen.h + 2 * slack,
    }
    return ges.pos:intersectWith(area)
end

function LargeCoverItem:onTapSelect(arg, ges)
    local fm = self.menu.ui
    if self:isOnInfoButton(ges) and not (fm and fm.selected_files) then
        self:showDescription()
        return true
    end
    self.menu:onMenuSelect(self.entry)
    return true
end

function LargeCoverItem:onHoldSelect(arg, ges)
    self.menu:onMenuHold(self.entry)
    return true
end

function LargeCoverItem:showDescription()
    local menu, entry = self.menu, self.entry
    UIManager:show(DescriptionPopup:new{
        filepath = self.filepath,
        details = self.details,
        open_callback = function()
            menu:onMenuSelect(entry)
        end,
    })
end


-- Simple holder of methods that will replace those
-- in the real Menu class or instance
local LargeCoverMenu = {}

function LargeCoverMenu:_recalculateDimen()
    self.portrait_mode = Screen:getWidth() <= Screen:getHeight()
    self._betterlibrary_layout = LAYOUTS[getLayoutName()]
    local layout = self._betterlibrary_layout
    if self.portrait_mode then
        self.nb_cols, self.nb_rows = layout.cols, layout.rows
    else
        self.nb_cols, self.nb_rows = layout.cols_landscape, layout.rows_landscape
    end
    self.perpage = self.nb_rows * self.nb_cols
    self.page_num = math.ceil(#self.item_table / self.perpage)
    -- fix current page if out of range
    if self.page_num > 0 and self.page > self.page_num then self.page = self.page_num end

    -- Find out available height from other UI elements made in Menu
    self.others_height = 0
    if self.title_bar then -- init() has been done
        if not self.is_borderless then
            self.others_height = self.others_height + 2
        end
        if not self.no_title then
            self.others_height = self.others_height + self.title_bar.dimen.h
        end
        if self.page_info then
            self.others_height = self.others_height + self.page_info:getSize().h
        end
    end
    local available_height = self.inner_dimen.h - self.others_height

    if layout.kind == "list" then
        self.item_margin = 0
        -- add space for the separators
        self.item_height = math.floor(available_height / self.nb_rows) - Size.line.thin
        self.item_width = self.inner_dimen.w
    else
        self.item_margin = px(layout.margin)
        self.item_height = math.floor((available_height - (1 + self.nb_rows) * self.item_margin) / self.nb_rows)
        self.item_width = math.floor((self.inner_dimen.w - (1 + self.nb_cols) * self.item_margin) / self.nb_cols)
    end
    self.item_dimen = Geom:new{
        x = 0, y = 0,
        w = self.item_width,
        h = self.item_height
    }
end

function LargeCoverMenu:_updateItemsBuildUI()
    local layout = self._betterlibrary_layout
    local show_info_button = G_reader_settings:nilOrTrue(INFO_BUTTON_SETTING)
    local is_list = layout.kind == "list"
    local separator
    if is_list then
        separator = LineWidget:new{
            dimen = Geom:new{ w = self.width or self.screen_w, h = Size.line.thin },
            background = COLOR_SEPARATOR,
        }
        table.insert(self.item_group, separator)
    end

    local idx_offset = (self.page - 1) * self.perpage
    local select_number
    local cur_row, line_layout
    for idx = 1, self.perpage do
        local index = idx_offset + idx
        local entry = self.item_table[index]
        if entry == nil then break end
        entry.idx = index
        if index == self.itemnumber then -- focused item
            select_number = idx
        end

        if not is_list and (idx - 1) % self.nb_cols == 0 then -- new row
            if line_layout then
                table.insert(self.layout, line_layout)
            end
            line_layout = {}
            table.insert(self.item_group, VerticalSpan:new{ width = self.item_margin })
            cur_row = HorizontalGroup:new{}
            -- items on a partially filled last row are aligned to the left
            table.insert(self.item_group, LeftContainer:new{
                dimen = Geom:new{
                    w = self.inner_dimen.w,
                    h = self.item_height
                },
                cur_row
            })
            table.insert(cur_row, HorizontalSpan:new{ width = self.item_margin })
        end

        local item = LargeCoverItem:new{
            height = self.item_height,
            width = self.item_width,
            entry = entry,
            text = getMenuText(entry),
            show_parent = self.show_parent,
            mandatory = entry.mandatory,
            dimen = self.item_dimen:copy(),
            menu = self,
            layout = layout,
            show_info_button = show_info_button,
        }
        if is_list then
            table.insert(self.item_group, item)
            table.insert(self.item_group, separator)
            -- this is for focus manager
            table.insert(self.layout, {item})
        else
            table.insert(cur_row, item)
            table.insert(cur_row, HorizontalSpan:new{ width = self.item_margin })
            table.insert(line_layout, item)
        end

        if not item.bookinfo_found and not item.is_directory and not item.file_deleted then
            -- Register this item for update
            table.insert(self.items_to_update, item)
        end
    end
    if line_layout then
        table.insert(self.layout, line_layout)
        table.insert(self.item_group, VerticalSpan:new{ width = self.item_margin }) -- bottom padding
    end
    return select_number
end

LargeCoverMenu.LAYOUTS = LAYOUTS

return LargeCoverMenu
