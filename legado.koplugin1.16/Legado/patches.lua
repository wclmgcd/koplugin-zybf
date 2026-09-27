
local util = require("util")
local logger = require("logger")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local ReadHistory = require("readhistory")
local Env = require("Legado.Helper.Env")
local PreviewTopBar = require("Legado/PreviewTopBar")

-- Do not use util.wrapMethod; may be overridden by other plugins
-- Minimal hook scope. Avoid restoring — may affect plugins that patch later
-- Before you: plugin A patches (you wrap it)
-- After you: plugin C patches (it wraps you)
-- ui.rolling, ui.paging, ReaderUI, ui.view.footer, etc. are frequently destroyed and recreated as books open/close

local M = {
    -- "soft unload" and "state penetration"
    is_enabled = false,
}

M.readui_runtime = function(read_ui)
    if not read_ui then return end
    local ui = read_ui.name == "ReaderUI" and read_ui or read_ui.ui
    if not ui or ui.name ~= "ReaderUI" then return end
    if ui._ref_legado_wrapped == true then return end

    ui._ref_legado_wrapped = true

    if ui.rolling then
        local orig_rolling_onGotoViewRel = ui.rolling.onGotoViewRel
        ui.rolling.onGotoViewRel = function(self, diff)
            if not M.is_enabled then return orig_rolling_onGotoViewRel(self, diff) end
            local scroll_mode = self.view.view_mode == "scroll"
            local old_pos = scroll_mode and self.current_pos or self.current_page
            orig_rolling_onGotoViewRel(self, diff)
            -- local beginning_page = self.ui.document:getNextPage(0)
            -- old_pos cannot be equal to 1, otherwise it won't work in scroll mode.
            local new_pos = scroll_mode and self.current_pos or self.current_page
            if diff < 0 and old_pos == new_pos and Env.is_legado_path(nil, self.ui) then
                self.ui:handleEvent(Event:new("StartOfBook"))
            end
            return true
        end
    end

    if ui.paging then
        -- In scroll mode, one screen may have multiple pages
        local orig_paging_onGotoViewRel = ui.paging.onGotoViewRel
        ui.paging.onGotoViewRel = function(self, diff)
            if not M.is_enabled then return orig_paging_onGotoViewRel(self, diff) end
            local old_pos = self:getTopPage()
            orig_paging_onGotoViewRel(self, diff)
            local new_pos = self:getTopPage()
            if diff < 0 and old_pos == 1 and old_pos == new_pos and Env.is_legado_path(nil, self.ui) then
                self.ui:handleEvent(Event:new("StartOfBook"))
            end
            return true
        end
    end

    -- hook footer (fix koreader .cbz next chapter crash)
    if ui.view and ui.view.footer then
        local orig_footer_getBookProgress = ui.view.footer.getBookProgress
        ui.view.footer.getBookProgress = function(self)
            if not M.is_enabled or (self.ui and self.ui.document) then
                return orig_footer_getBookProgress(self)
            else
                local pageno = self.pageno or 0
                local pages = self.pages or 1
                if pages == 0 then pages = 1 end
                return pageno / pages
            end
        end

        local orig_footer_updateFooterPage = ui.view.footer.updateFooterPage
        ui.view.footer.updateFooterPage = function(self, force_repaint, full_repaint)
            if not M.is_enabled or (self.ui and self.ui.document) then
                return orig_footer_updateFooterPage(self, force_repaint, full_repaint)
            end
        end
    end
    
    return true
end

M.install = function(parent_ref)
    -- In the plugin init, ReaderUI.instance == nil
    -- If the plugin is disabled, no functional patch is applied
    if G_reader_settings and G_reader_settings.readSetting then
        local plugins_disabled = G_reader_settings:readSetting("plugins_disabled")
        if plugins_disabled and plugins_disabled["legado"] == true then
            return
        end
    end
    if not parent_ref then return end

    M.is_enabled = true

    if FileManager._legado_wrapped == nil then
        FileManager._legado_wrapped = true

        local orig_FileManager_showOpenWithDialog = FileManager.showOpenWithDialog
        FileManager.showOpenWithDialog = function(self, file)
            if M.is_enabled and file and Env.is_legado_browser_book(file) then
                self:handleEvent(Event:new("ShowLegadoLibraryView"))
            else
                return orig_FileManager_showOpenWithDialog(self, file)
            end
        end
    end

    -- 阅读菜单是阅读器之外的一个独立顶层窗口，引用只放在 ReaderMenu.menu_container 这一个格子里。
    -- 格子被挤掉之后，旧窗口就再也关不掉了 —— 它继续留在栈里收点击，问的却是已经销毁的 document：
    -- crash.log 21:24:23 closing reader → 21:24:40 点一下菜单页签
    -- ./luajit: readertoc.lua:72 attempt to index field 'document'，
    -- 用户看到的就是「菜单缩不回去，点哪都报错」。
    local function close_stray_reader_menus()
        local stack = UIManager._window_stack
        if type(stack) ~= "table" then return end
        for i = #stack, 1, -1 do
            local win = stack[i]
            local w = win and win.widget
            -- 阅读菜单的容器就是 CenterContainer{ TouchMenu }，TouchMenu 认 tab_item_table
            local inner = type(w) == "table" and w[1] or nil
            if type(inner) == "table" and inner.tab_item_table ~= nil then
                UIManager:close(w)
            end
        end
    end

    if ReaderUI._legado_wrapped == nil then
        ReaderUI._legado_wrapped = true
        -- fix bookself.koplugin
        local orig_ReaderUI_showReader = ReaderUI.showReader
        ReaderUI.showReader = function(self, file, provider, seamless, is_provider_forced, after_open_callback)
            if M.is_enabled and file and Env.is_legado_browser_book(file) then
                if parent_ref.openFile then parent_ref:openFile(file) end
            else
                return orig_ReaderUI_showReader(self, file, provider, seamless, is_provider_forced, after_open_callback)
            end
        end

        -- 阅读菜单和底部设置面板是阅读器之外的顶层窗口。KOReader 自己退出阅读器时一定先收掉它们
        -- （ReaderMenu:exitOrRestart → onTapCloseMenu），而 Legado 是从外面直接 onClose 的
        -- （试读「返回」、FM 覆盖项），面板就留在窗口栈里了。设置面板还带 is_always_active，
        -- 之后每个事件都会先递给这个已经死了的阅读器：面板的 close_callback 去索引已被清掉的
        -- config_dialog（crash.log 20:29:50 readerconfig.lua:171），或者阅读器菜单去问
        -- document（同一份日志 20:18:43 readertoc.lua:72）—— 都是整个 KOReader 崩回系统界面。
        local orig_ReaderUI_onClose = ReaderUI.onClose
        ReaderUI.onClose = function(self, ...)
            self:handleEvent(Event:new("CloseConfigMenu"))
            self:handleEvent(Event:new("CloseReaderMenu"))
            close_stray_reader_menus()
            -- 试读那条顶栏也是阅读器之外的独立窗口，只有 BookPreview.exit 会收它；从别处
            -- 关阅读器（阅读菜单里的「文件浏览器」、KOReader 自己的返回）就没人管：
            -- crash.log 21:39:50 closing reader，顶栏一直挂到 21:41:04 退出 KOReader
            -- 才被收掉。hide 自己认栈上有没有，和 exit 撞一次是空操作。
            PreviewTopBar.hide()
            return orig_ReaderUI_onClose(self, ...)
        end
    end

    -- menu_container 只有一个格子，onShowMenu 每次又是无条件新建再盖上去（上面 21:24:40 那次
    -- readertoc 崩溃就是格子被挤掉后，旧窗口留在栈里没人认领）。开新菜单前先把上一个收掉；
    -- 已经不在栈上的（onShowMenu(nil, true) 只建不显示）只丢引用，别再二次 close。
    local ok_ReaderMenu, ReaderMenu = pcall(require, "apps/reader/modules/readermenu")
    if not ok_ReaderMenu then
        logger.warn("[Legado] 阅读菜单补丁 require 失败:", tostring(ReaderMenu))
    elseif ReaderMenu and ReaderMenu._legado_menu_v1 == nil then
        ReaderMenu._legado_menu_v1 = true

        local orig_onShowMenu = ReaderMenu.onShowMenu
        function ReaderMenu:onShowMenu(...)
            local stale = self.menu_container
            if stale then
                if UIManager:isWidgetShown(stale) then
                    -- 还挂在栈上：走正常收尾（onCloseReaderMenu 会把格子清空并存设置）
                    self:onCloseReaderMenu()
                else
                    -- onShowMenu(nil, true) 这种「只建不显示」的路径也会占格子，
                    -- 别去 close 一个没上屏的容器，只把引用丢掉
                    self.menu_container = nil
                end
            end
            return orig_onShowMenu(self, ...)
        end
    end

    -- 底部设置面板只有一个 config_dialog 格子，可它自己是独立顶层窗口：从屏幕顶边下滑一次会
    -- 开出「面板 + 阅读菜单」，连着滑两下（试读顶栏正好压在顶边下滑的热区上）就叠出两个面板，
    -- 第二个把第一个的引用挤掉，第一个就成了没人认领的孤儿。关掉一个之后 onCloseCallback 把
    -- config_dialog 置 nil，剩下那个孤儿（is_always_active）再收到一次点击 —— 它走的还是同一份
    -- onCloseCallback，而那里没判空，直接索引 nil 就整个 KOReader 崩回系统界面。
    -- crash.log 20:52:39 同一秒里两次 show widget: ConfigDialog、20:52:52 只关了一次、
    -- 20:52:58 ./luajit: readerconfig.lua:171 attempt to index field 'config_dialog'。
    local ok_ReaderConfig, ReaderConfig = pcall(require, "apps/reader/modules/readerconfig")
    if not ok_ReaderConfig then
        -- require 失败 = 补丁静默不生效，必须喊出来，别让它悄悄漏
        logger.warn("[Legado] 设置面板补丁 require 失败:", tostring(ReaderConfig))
    elseif ReaderConfig and ReaderConfig._legado_cfg_v1 == nil then
        ReaderConfig._legado_cfg_v1 = true

        local orig_onShowConfigMenu = ReaderConfig.onShowConfigMenu
        function ReaderConfig:onShowConfigMenu(...)
            local stale = self.config_dialog
            if stale then
                if UIManager:isWidgetShown(stale) then
                    -- 还挂在窗口栈上：走它自己的收尾，close_callback 顺手把格子清空
                    stale:closeDialog()
                else
                    -- 已经不在栈上就别二次 close（CloseWidget 会跑两遍，控件缓冲可能被释放两次），
                    -- 只把这个来历不明的引用丢掉
                    self.config_dialog = nil
                end
            end
            return orig_onShowConfigMenu(self, ...)
        end

        local orig_onCloseCallback = ReaderConfig.onCloseCallback
        function ReaderConfig:onCloseCallback(...)
            -- 孤儿面板的 close_callback：没东西可记，也不许去索引 nil
            if not self.config_dialog then return end
            return orig_onCloseCallback(self, ...)
        end
    end

    if ReadHistory._legado_wrapped == nil then
        ReadHistory._legado_wrapped = true

        local orig_ReadHistory_addItem = ReadHistory.addItem
        ReadHistory.addItem = function(self, file, ts, no_flush)
            -- chapter cache files stay out of history; browser-book link
            -- files are allowed in so homescreen plugins (simpleui) can
            -- show legado books
            if M.is_enabled and Env.is_legado_path(file) and not Env.is_legado_browser_book(file) then
                return
            end
            return orig_ReadHistory_addItem(self, file, ts, no_flush)
        end

        local orig_ReadHistory_updateLastBookTime = ReadHistory.updateLastBookTime
        ReadHistory.updateLastBookTime = function(self, no_flush)
            if not M.is_enabled or (self.hist and self.hist[1] ~= nil) then
                return orig_ReadHistory_updateLastBookTime(self, no_flush)
            end
        end
    end

    if filemanagerutil._legado_wrapped == nil then
        filemanagerutil._legado_wrapped = true

        local orig_filemanagerutil_genBookCoverButton = filemanagerutil.genBookCoverButton
        -- Note: genBookCoverButton does not take a `self` argument.
        filemanagerutil.genBookCoverButton = function(file, book_props, caller_callback, button_disabled)
            if M.is_enabled and file and Env.is_legado_browser_book(file) then
                return {
                    text = "legado 选项",
                    enabled = true,
                    callback = function()
                        if caller_callback then caller_callback() end
                        if parent_ref and parent_ref.openBrowserMenu then parent_ref:openBrowserMenu(file) end
                    end
                }
            else
                return orig_filemanagerutil_genBookCoverButton(file, book_props, caller_callback, button_disabled)
            end
        end
    end

    -- 段评气泡：crengine 把 <a href="legado-para:N"> 交给 ReaderLink，
    -- 原实现不认识这个协议，只能弹出"无效或外部链接"。showLinkBox / onGotoLink 都是
    -- 直接方法调用（不是事件广播），所以插件自己的 onGotoLink 永远收不到，必须猴补丁。
    -- 两处都包：报告可能出自 onGotoLink 之前的 showLinkBox，只包一处就会漏。
    -- 注意模块路径是 apps/reader/modules/readerlink，写成 ui/widget/... 会 require 失败，
    -- 而 pcall 会把这次失败吞掉——补丁静默不生效，症状就是点段评只报"无效或外部链接"。
    -- 标记带版本号：KOReader 重载模块或本补丁改动后，靠新键名强制重新安装。
    local pc_mod -- 懒加载：没点过段评就不 require
    local function para_comment()
        if pc_mod == nil then
            local ok, mod = pcall(require, "Legado/ParaComment")
            pc_mod = ok and mod or false
        end
        return pc_mod and pc_mod or nil
    end

    -- 命中就返回序号，没命中返回 nil。不检查 link 的字段名：crengine 放 uri 还是
    -- xpointer 取决于文档类型和是否分页模式，整个表扫一遍比猜哪个字段稳妥。
    local function pc_index(link)
        if type(link) ~= "table" then return nil end
        local PC = para_comment()
        if not PC then return nil end
        local prefix = PC.PROTO .. ":"
        for _, value in pairs(link) do
            if type(value) == "string" and value:find(prefix, 1, true) == 1 then
                -- 不能用 PROTO .. ":(%d+)" 去 match：协议名里的 "-" 在 Lua 模式里是量词
                return tonumber(value:sub(#prefix + 1):match("^%d+"))
            end
        end
    end

    local function pc_handle(caller, link)
        if not M.is_enabled then return false end
        local index = pc_index(link)
        if not index then return false end
        logger.info("[Legado] 段评气泡点击(", caller, ") 序号:", index)
        local PC = para_comment()
        local ok, shown = pcall(PC.show, PC, index)
        -- 是我们自己的协议，无论打开成败都不能回落给 KOReader：
        -- 否则它的"无效或外部链接"会盖掉插件给出的真实提示
        if not ok or not shown then
            logger.warn("[Legado] 第", index, "段未能打开:", tostring(shown))
        end
        return true
    end

    local ok_ReaderLink, ReaderLink = pcall(require, "apps/reader/modules/readerlink")
    logger.info("[Legado] ReaderLink 段评补丁:",
        ok_ReaderLink and "require 成功" or ("require 失败: " .. tostring(ReaderLink)))
    if ok_ReaderLink and ReaderLink then
        if ReaderLink._legado_goto_v2 == nil then
            ReaderLink._legado_goto_v2 = true
            local orig_ReaderLink_onGotoLink = ReaderLink.onGotoLink
            function ReaderLink:onGotoLink(link, ...)
                if pc_handle("onGotoLink", link) then return true end
                return orig_ReaderLink_onGotoLink(self, link, ...)
            end
        end
        if ReaderLink.showLinkBox and ReaderLink._legado_box_v2 == nil then
            ReaderLink._legado_box_v2 = true
            local orig_ReaderLink_showLinkBox = ReaderLink.showLinkBox
            function ReaderLink:showLinkBox(link, ...)
                if pc_handle("showLinkBox", link) then return true end
                return orig_ReaderLink_showLinkBox(self, link, ...)
            end
        end
    end
end

M.uninstall = function()
    M.is_enabled = false
    if ReaderUI then ReaderUI._legado_wrapped = nil end
    if FileManager then FileManager._legado_wrapped = nil end
    if filemanagerutil then filemanagerutil._legado_wrapped = nil end
    if ReadHistory then ReadHistory._legado_wrapped = nil end
    local ui = ReaderUI.instance or FileManager.instance
    if ui then ui._ref_legado_wrapped = nil end
end

return M
