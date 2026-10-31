--[[--
Adds a "Large covers with details" display mode to the file browser: large
cover images with the title, author and the other details the detailed list
shows, in one of four layouts.

The mode is built on the Cover browser plugin. It reuses its book information
database and background extraction, and joins its "Display mode" menu: picking
one of Cover browser's modes switches ours off, and picking ours puts Cover
browser in classic mode underneath so the two never patch the file browser at
the same time.

@module koplugin.betterlibrary
--]]--

local PluginLoader = require("pluginloader")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

-- Keep FileChooser's own methods, to put them back when switching to one of
-- Cover browser's modes (which expects to find them in place).
local FileChooser = require("ui/widget/filechooser")
local _FileChooser_updateItems_orig = FileChooser.updateItems
local _FileChooser_onCloseWidget_orig = FileChooser.onCloseWidget
local _FileChooser__recalculateDimen_orig = FileChooser._recalculateDimen

local ENABLED_SETTING = "betterlibrary_enabled"
local LAYOUT_SETTING = "betterlibrary_layout"
local INFO_BUTTON_SETTING = "betterlibrary_info_button"

local LAYOUT_NAMES = {
    { "A", _("Big list") },
    { "B", _("Two-up cards") },
    { "C", _("Captioned mosaic") },
    { "D", _("Feature list") },
}

local function isEnabled()
    return G_reader_settings:isTrue(ENABLED_SETTING)
end

local function getCoverBrowserClass()
    for _, plugin_module in ipairs(PluginLoader:loadPlugins()) do
        if plugin_module.name == "coverbrowser" then
            return plugin_module
        end
    end
end

-- Point the file browser at our layouts.
local function applyOverrides(CoverBrowser)
    local CoverMenu = require("covermenu")
    local LargeCoverMenu = require("largecovermenu")
    FileChooser.updateItems = CoverMenu.updateItems
    FileChooser.onCloseWidget = CoverMenu.onCloseWidget
    FileChooser._recalculateDimen = LargeCoverMenu._recalculateDimen
    FileChooser._updateItemsBuildUI = LargeCoverMenu._updateItemsBuildUI
    FileChooser._do_cover_images = true
    FileChooser._do_hint_opened = true
    -- "Ignore cover", "Refresh cached book information"... on long-press
    CoverBrowser.addFileDialogButtons("filemanager")
end

-- Hand the file browser back as FileChooser had it.
local function removeOverrides(CoverBrowser)
    FileChooser.updateItems = _FileChooser_updateItems_orig
    FileChooser.onCloseWidget = _FileChooser_onCloseWidget_orig
    FileChooser._recalculateDimen = _FileChooser__recalculateDimen_orig
    FileChooser._updateItemsBuildUI = nil
    FileChooser._do_cover_images = nil
    FileChooser._do_hint_opened = nil
    CoverBrowser.removeFileDialogButtons("filemanager")
end

local function refreshFileChooser(ui)
    local fc = ui and ui.file_chooser
    if fc then
        fc:_recalculateDimen()
        fc:switchItemTable(nil, nil, fc.prev_itemnumber, { dummy = "" }) -- dummy itemmatch to draw focus
    end
end

local BetterLibrary = WidgetContainer:extend{
    name = "betterlibrary",
    is_doc_only = false,
}

function BetterLibrary:init()
    local CoverBrowser = getCoverBrowserClass()
    if not CoverBrowser then
        logger.warn("BetterLibrary: the Cover browser plugin is disabled, large covers are unavailable")
        return
    end
    self:patchCoverBrowser(CoverBrowser)
end

function BetterLibrary:patchCoverBrowser(CoverBrowser)
    if CoverBrowser._betterlibrary_patched then
        return
    end
    CoverBrowser._betterlibrary_patched = true

    -- Cover browser sets up the file browser when the first FileManager
    -- starts: put our layouts on top when they are the chosen mode.
    local setupFileManagerDisplayMode_orig = CoverBrowser.setupFileManagerDisplayMode
    CoverBrowser.setupFileManagerDisplayMode = function(cb, display_mode)
        setupFileManagerDisplayMode_orig(cb, display_mode)
        if isEnabled() then
            applyOverrides(CoverBrowser)
        end
    end

    local addToMainMenu_orig = CoverBrowser.addToMainMenu
    CoverBrowser.addToMainMenu = function(cb, menu_items)
        addToMainMenu_orig(cb, menu_items)
        local display_mode = menu_items.filemanager_display_mode
        if display_mode and display_mode.sub_item_table then
            BetterLibrary.addMenuItems(cb, display_mode.sub_item_table)
        end
    end
end

-- Join our items to Cover browser's "Display mode" menu, right after its own
-- modes, and make its modes aware of ours.
function BetterLibrary.addMenuItems(cb, sub_item_table)
    local CoverBrowser = getCoverBrowserClass()
    local nb_modes = #cb.modes

    for i = 1, nb_modes do
        local item = sub_item_table[i]
        local checked_func_orig = item.checked_func
        local callback_orig = item.callback
        item.checked_func = function()
            return not isEnabled() and checked_func_orig()
        end
        item.callback = function(...)
            if isEnabled() then
                G_reader_settings:makeFalse(ENABLED_SETTING)
                removeOverrides(CoverBrowser)
                callback_orig(...)
                if FileChooser._updateItemsBuildUI == nil then
                    -- Cover browser was already in this (classic) mode, so it
                    -- didn't redraw anything
                    refreshFileChooser(cb.ui)
                end
            else
                callback_orig(...)
            end
        end
    end
    sub_item_table[nb_modes].separator = nil

    local layout_items = {}
    for _, v in ipairs(LAYOUT_NAMES) do
        local layout, text = v[1], v[2]
        table.insert(layout_items, {
            text = layout .. " · " .. text,
            checked_func = function()
                return (G_reader_settings:readSetting(LAYOUT_SETTING) or "A") == layout
            end,
            radio = true,
            callback = function()
                G_reader_settings:saveSetting(LAYOUT_SETTING, layout)
                if isEnabled() then
                    refreshFileChooser(cb.ui)
                end
            end,
        })
    end
    layout_items[#layout_items].separator = true
    table.insert(layout_items, {
        text = _("Show info button"),
        help_text = _("Show a small (i) button next to the title, which opens the book's description. Layout D always shows the description."),
        enabled_func = function()
            return (G_reader_settings:readSetting(LAYOUT_SETTING) or "A") ~= "D"
        end,
        checked_func = function()
            return G_reader_settings:nilOrTrue(INFO_BUTTON_SETTING)
        end,
        callback = function()
            G_reader_settings:flipNilOrTrue(INFO_BUTTON_SETTING)
            if isEnabled() then
                refreshFileChooser(cb.ui)
            end
        end,
    })

    table.insert(sub_item_table, nb_modes + 1, {
        text = _("Large covers with details"),
        checked_func = isEnabled,
        radio = true,
        callback = function()
            if isEnabled() then
                return
            end
            G_reader_settings:makeTrue(ENABLED_SETTING)
            -- Have Cover browser drop its own patches; our wrapper of this
            -- method then applies ours
            cb:setupFileManagerDisplayMode(nil)
            refreshFileChooser(cb.ui)
        end,
    })
    table.insert(sub_item_table, nb_modes + 2, {
        text = _("Large cover layout"),
        sub_item_table = layout_items,
        separator = true,
    })
end

return BetterLibrary
