local Font = require("ui/font")
local ffiUtil = require("ffi/util")
local util = require("util")
local logger = require("logger")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Device = require("device")

local ChapterListing = require("Legado/ChapterListing")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local DocSettings = require("docsettings")
local Icons = require("Legado.res.icons")
local Backend = require("Legado/Backend")
local MessageBox = require("Legado/MessageBox")
local TaskProg = require("Legado.task.Progress")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local FS = require("Legado.Helper.FS")

local PlgState = require("Legado/PlgState")
local BookPreview = require("Legado/BookPreview")
local init_book_links = require("Legado/BookLinks")
local init_book_shelf = require("Legado/BookShelf")

local LibraryView = {
    book_toc = nil,
    book_shelf = nil,
    stream_view = nil,
    book_links = nil,
}

function LibraryView:init()
    if LibraryView.instance then
        return
    end
    self:getBrowserHomeDir(true)
    LibraryView.instance = self
end

function LibraryView:fetchAndShow()
    local is_first = not LibraryView.instance
    local library_obj = LibraryView.instance or self:getInstance()
    local use_browser = not self:isDisableBrowserMode() and is_first and self:browserViewHasLnk()
    local widget = use_browser and self:getBrowserWidget() or self:getMenuWidget()
    if widget then
        widget:show_view()
        widget:refreshItems()
    end
    return self
end

function LibraryView:isDisableBrowserMode()
    local settings = Backend:getSettings()
    return settings and settings.disable_browser == true
end

function LibraryView:browserViewHasLnk()
    local browser_homedir = self:getBrowserHomeDir(true)
    return browser_homedir and util.directoryExists(browser_homedir) and not util.isEmptyDir(browser_homedir)
end

function LibraryView:addBkShortcut(bookinfo, always_add)
    if not always_add and self:isDisableBrowserMode() then
        return
    end
    local browser = self:getBrowserWidget()
    if browser then
        browser:addBookShortcut(bookinfo)
    end
end

function LibraryView:onRefreshLibrary()
    if self.book_shelf then
        self.book_shelf:onRefreshLibrary()
    end
end

function LibraryView:clearMenuItems()
    if self.book_shelf then
        self.book_shelf.item_table = self.book_shelf:generateEmptyViewItemTable()
        self.book_shelf.multilines_show_more_text = true
        self.book_shelf.items_per_page = 1
        self.book_shelf:updateItems()
    end
end

function LibraryView:closeMenu()
    if self.book_shelf then
        self.book_shelf:onClose()
    end
end

function LibraryView:openBrowserMenu(file)
    self:getInstance()
    self:getBrowserWidget()

    local book_cache_id
    local ui = FileManager.instance or ReaderUI.instance
    if file and ui and ui.bookinfo then
        local doc_settings = DocSettings:open(file)
        book_cache_id = doc_settings:readSetting("book_cache_id")

        if not book_cache_id then
            local ok, lnk_conf = pcall(Backend.getLuaConfig, Backend, file)
            if ok and lnk_conf then
                book_cache_id = lnk_conf:readSetting("book_cache_id")
                if book_cache_id then
                    doc_settings:saveSetting("book_cache_id", book_cache_id):flush()
                end
            end
        end
    else
        return MessageBox:error("获取书籍信息出错")
    end

    local dialog
    local buttons = { {{
        text = "更多设置 >>",
        callback = function()
            UIManager:close(dialog)
            UIManager:nextTick(function() self:openMenu() end)
        end
    }, {
        text = "书籍详情 >>",
        callback = function()
            if book_cache_id then
                local bookinfo = Backend:getBookInfoCache(book_cache_id)
                if not (H.is_tbl(bookinfo) and H.is_num(bookinfo.durChapterIndex)) then
                    MessageBox:error('书籍不存在于当前激活书架或已被删除')
                    return
                end
                UIManager:close(dialog)
                UIManager:nextTick(function()
                    UIManager:show(require("Legado/BookDetailsDialog"):new{
                        bookinfo = bookinfo,
                        has_reload_btn = true,
                        lnk_file = file,
                    })
                end)
            end
        end
    }}, {{
        text = "清空云端书籍链接",
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm("是否清除所有云端书籍链接?", function(result)
                if result then
                    local browser_homedir = self:getBrowserHomeDir(true)
                    if self:deleteFile(browser_homedir) then
                        MessageBox:notice("已清除")
                    end
                end
            end, { ok_text = "清除", cancel_text = "取消" })
        end
    }, {
        text = "修复云端书籍链接",
        callback = function()
            UIManager:close(dialog)
            self.book_links:verifyBooksMetadata()
        end
    }},}

    dialog = require("ui/widget/buttondialog"):new{
        title = "Legado 设置",
        title_align = "center",
        title_face = Font:getFace("x_smalltfont"),
        info_face = Font:getFace("tfont"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- 拉取远端排序：手动点是「确认 + 报结果」，换源/加书/删书之后自动跑是 quiet
-- （不弹确认也不报成功，只把书架按新顺序刷出来，失败照样要说话）
function LibraryView:syncRemoteOrder(quiet)
    TaskProg.loading(quiet and "同步远端排序 " or "同步中...", function()
        return Backend:syncAndResortBooks()
    end, function(state, response)
        if state ~= true then
            if not quiet then MessageBox:error('操作失败', '未知错误') end
            return
        end
        Backend:HandleResponse(response, function(_)
            if not quiet then MessageBox:notice("同步并排序成功") end
            if self.book_shelf then
                self.book_shelf:refreshItems(true)
            end
        end, function(err_msg)
            if not quiet then MessageBox:error('操作失败: ', tostring(err_msg)) end
        end)
    end)
end

-- 书架界面还没打开过时不硬把它建出来
function LibraryView.autoSyncRemoteOrder()
    local obj = LibraryView.instance
    if obj then
        obj:syncRemoteOrder(true)
    end
end

function LibraryView:openMenu(dimen)
    local dialog
    self:getInstance()
    local unified_align = dimen and "left" or "center"
    local buttons = {{},{{
        text = Icons.FA_SEARCH .. " 添加书籍",
        callback = function()
            UIManager:close(dialog)
            self:openSearchBooksDialog()
        end,
        align = unified_align,
    }}, {{
        text = Icons.FA_GLOBE .. " 切换书架",
        callback = function()
            UIManager:close(dialog)
            require("Legado/WebConfigDialog"):openWebConfigManager(function()
                self:invalidateBookShelf()
                self:fetchAndShow()
                self:onRefreshLibrary()
            end)
        end,
        align = unified_align,
    }}, {{
        text = Icons.FA_REFRESH .. " 拉取远端排序",
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm("即将同步远端书架，按最后阅读时间排序。此操作将覆盖本地书架排序（手动置顶的书籍不受影响)\n是否继续？", function(result)
                if result then
                    self:syncRemoteOrder(false)
                end
            end, { ok_text = "确定", cancel_text = "取消" })
        end,
        align = unified_align,
    }}}

    if not Device:isTouchDevice() then
        table.insert(buttons, #buttons, {{
            text = Icons.FA_REFRESH .. ' ' .. " 同步书架",
            callback = function()
                UIManager:close(dialog)
                self:onRefreshLibrary()
            end,
            align = unified_align,
        }})
    end

    dialog = require("ui/widget/buttondialog"):new{
        title = "书架操作",
        title_align = unified_align,
        buttons = buttons,
        shrink_unneeded_width = dimen and true,
        anchor = dimen and function() return dimen end or nil,
    }
    UIManager:show(dialog)
end

function LibraryView:openSearchBooksDialog(def_search_input)
    require("Legado/BookSourceResults"):searchBookDialog(function()
        self:onRefreshLibrary()
    end, def_search_input)
end

function LibraryView:openLegadoFolder(path, focused_file, selected_files, done_callback)
    UIManager:nextTick(function()
        if ReaderUI and ReaderUI.instance then
            ReaderUI.instance:onClose()
            PlgState:readerUiVisible(false)
            -- 人是自己退出阅读器进书架/文件管理器的，这一轮的「切章进行中」要跟着作废：
            -- 不清的话，8 秒内再从文件管理器点开同一本书会被当成重复请求丢掉。
            PlgState:switchPending(false)
        end
        if FileManager.instance then
            FileManager.instance:reinit(path, focused_file, selected_files)
        else
            FileManager:showFiles(path, focused_file, selected_files)
        end
        if FileManager.instance and path then
            FileManager.instance:updateTitleBarPath(path)
        end
        if H.is_func(done_callback) then
            done_callback()
        end
    end)
end

function LibraryView:afterCloseReaderUi(callback)
    self:openLegadoFolder(nil, nil, nil, callback)
end

function LibraryView:loadAndRenderChapter(chapter)
    if not (H.is_tbl(chapter) and chapter.book_cache_id) then 
        logger.err("loadAndRenderChapter: chapter parameter is invalid")
        return 
    end
    if chapter.cacheExt == 'cbz' then
        local book_cache_id = chapter.book_cache_id
        local extras_settings = Backend:getBookExtras(book_cache_id)
        if H.is_tbl(extras_settings.data) and extras_settings.data.stream_image_view == true then
            MessageBox:notice("流式漫画开启")
            if not NetworkMgr:isConnected() then
                MessageBox:error("需要网络连接")
                return
            end
             self:afterCloseReaderUi(function()
                local ex_chapter = chapter
                self.stream_view = require("Legado/StreamImageView"):fetchAndShow({
                    chapter = ex_chapter,
                    on_return_callback = function()
                        local bookinfo = Backend:getBookInfoCache(ex_chapter.book_cache_id)
                        self:showBookTocDialog(bookinfo)
                    end,
                })   
            end)
            return 
        end
    end

    local cache_chapter = Backend:getCacheChapterFilePath(chapter)

    if (H.is_tbl(cache_chapter) and H.is_str(cache_chapter.cacheFilePath)) then
        self:showReaderUI(cache_chapter)
    else
        if PlgState:switchPending() then
            -- 上一轮还没落地（正在下载或正在换文档），这一轮直接丢掉：连着按会叠出好几个
            -- 下载弹窗，各自的回调再各自换一次文档，就是在拆到一半的阅读器上换两遍文档。
            logger.info("loadAndRenderChapter: 切章进行中，忽略本次请求")
            return
        end
        PlgState:switchPending(true)
        Backend:closeDbManager()
        return TaskProg.loading("正在下载正文 ", function()
            return Backend:downloadChapter(chapter)
        end, function(state, response)
            if state ~= true then
                -- 任务被取消/失败：标记不清掉的话，接下来几秒的翻页会全被当成重复请求
                PlgState:switchPending(false)
            else
                Backend:HandleResponse(response, function(data)
                    -- 同步下载, 图片章节打包 kind=="cbz"
                    if H.is_tbl(data) and data.kind == "cbz" then
                        local pending = data
                        if not H.is_tbl(pending.img_sources) or #pending.img_sources == 0 then
                            -- 服务端超时给半截响应时解析不出图片列表，这里不判空就是
                            -- attempt to get length of a nil value —— 没人接住就整个退到系统界面
                            PlgState:switchPending(false)
                            MessageBox:error("章节图片列表为空，请稍后重试")
                            return
                        end
                        local cbz_writer = require("Legado.task.QueueCbz"):new()
                        local total_imgs = #pending.img_sources
                        local progress_bar
                        if total_imgs > 2 then
                            progress_bar = TaskProg.showBar("正在下载章节图片...", {
                                title = "漫画章节下载",
                                max = total_imgs,
                            })
                        else
                            progress_bar = TaskProg.showSpinner("正在下载章节图片")
                        end
                        local started, start_err = cbz_writer:from_urls_async({
                            output = pending.filePath,
                            images = pending.img_sources,
                            opts = { comic_info = { name = pending.chapter.title or "" } },
                            on_progress = function(completed)
                                if progress_bar and progress_bar.reportProgress then
                                    progress_bar:reportProgress(completed)
                                end
                            end,
                            on_finish = function(aborted, result)
                                if result and result.success then
                                    pending.chapter.cacheFilePath = pending.filePath
                                    if progress_bar then progress_bar:close() end
                                    UIManager:nextTick(function()
                                            self:showReaderUI(pending.chapter)
                                    end)
                                else
                                    if progress_bar then progress_bar:close() end
                                    PlgState:switchPending(false)
                                    MessageBox:error('章节打包失败')
                                end
                            end,
                        })
                        if not started then
                            if progress_bar then progress_bar:close() end
                            PlgState:switchPending(false)
                            MessageBox:error('章节打包启动失败: ' .. tostring(start_err))
                        end
                        return
                    end
                    if not H.is_tbl(data) or not H.is_str(data.cacheFilePath) then
                        PlgState:switchPending(false)
                        MessageBox:error('下载失败')
                        return
                    end
                    self:showReaderUI(data)
                end, function(err_msg)
                    PlgState:switchPending(false)
                    MessageBox:notice("请检查并刷新书架")
                    MessageBox:error(err_msg or '错误')
                end)
            end
        end)
    end
end

function LibraryView:ReaderUIEventCallback(chapter_direction, ui)
    if not H.is_str(chapter_direction) then return end

    -- 试读：章节序列在内存里，不查数据库
    if BookPreview.turn(chapter_direction) then return end

    local fullpath = ui and ui.document and ui.document.file
    local chapter = PlgState:readingChapter()
    
    if not (H.is_tbl(chapter) and chapter.book_cache_id) and fullpath then
        local doc_settings = DocSettings:open(fullpath)
        if doc_settings.data and doc_settings.data.doc_props then
            local chapters_index = doc_settings.data.doc_props.chapters_index
            local book_cache_id = doc_settings.data.doc_props.book_cache_id
            if book_cache_id and H.is_num(chapters_index) then
                chapter = Backend:getChapterInfoCache(book_cache_id, chapters_index)
                if H.is_tbl(chapter) and chapter.book_cache_id then
                    PlgState:readingChapter(chapter)
                end
            end
        end
    end

    if not (H.is_tbl(chapter) and chapter.book_cache_id) then return end

    PlgState:chapterDirection(chapter_direction)
    chapter.call_event = chapter_direction

    local nextChapter = Backend:findNextChapter({
        chapters_index = chapter.chapters_index,
        call_event = chapter.call_event,
        book_cache_id = chapter.book_cache_id,
        totalChapterNum = chapter.totalChapterNum
    })
 
    if H.is_tbl(nextChapter) then
        nextChapter.call_event = chapter.call_event
        self:loadAndRenderChapter(nextChapter)
    else
        local book_cache_id = self:getReadingBookId()
        if book_cache_id then
            local bookinfo = Backend:getBookInfoCache(book_cache_id)
            self:afterCloseReaderUi(function()
                self:showBookTocDialog(bookinfo)
            end)
        end
    end
end

function LibraryView:showReaderUI(chapter)
    if not (H.is_tbl(chapter) and H.is_str(chapter.cacheFilePath)) then return end
    local book_path = chapter.cacheFilePath
    if not util.fileExists(book_path) then
        PlgState:switchPending(false)
        return MessageBox:error(book_path, "不存在")
    end
    local pending_since, pending_target = PlgState:switchPending()
    if pending_since and pending_target and pending_target ~= book_path then
        -- 上一轮的文档还没换完。此时再 switchDocument 一次，就是在拆到一半的阅读器上
        -- 取它已经不存在的 document —— 未捕获的 Lua 错误会把 KOReader 整个带回系统界面。
        logger.info("showReaderUI: 上一次切章未完成，忽略", book_path)
        return
    end
    PlgState:switchPending(true, book_path)
    BookPreview.adopt(chapter)
    PlgState:readingChapter(chapter)

    local toc_obj = self:getBookTocWidget()
    if toc_obj and UIManager:isWidgetShown(toc_obj) then
        UIManager:close(toc_obj)
    end
    -- 换文档这条链子全在 KOReader 里，出错没人兜底就是闪退；这里接住它，
    -- 让 traceback 落到 crash.log，人还留在书页上。
    local ok, err = xpcall(function()
        if ReaderUI.instance then
            ReaderUI.instance:switchDocument(book_path, true)
        else
            UIManager:broadcastEvent(Event:new("SetupShowReader"))
            ReaderUI:showReader(book_path, nil, true)
        end
    end, function(e)
        logger.err("[Legado] 换文档出错: " .. tostring(e) .. "\n" .. debug.traceback("", 2))
    end)
    if not ok then
        PlgState:switchPending(false)
    end
end

function LibraryView:openLastReadChapter(bookinfo)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then return false end
    -- 从文件管理器/最近阅读进书是一次「重新开始」，上一轮切章留下的标记不能再来挡路
    PlgState:switchPending(false)

    local book_cache_id = bookinfo.cache_id
    local last_read_chapter_index = Backend:getLastReadChapter(book_cache_id)
    if H.is_num(last_read_chapter_index) then
        if last_read_chapter_index < 0 then last_read_chapter_index = 0 end
        local chapter = Backend:getChapterInfoCache(book_cache_id, last_read_chapter_index)
        if H.is_tbl(chapter) and H.is_num(chapter.chapters_index) then
            chapter.call_event = "next"
            self:loadAndRenderChapter(chapter)
        else
            self:showBookTocDialog(bookinfo)
            MessageBox:notice('请同步刷新目录数据')
        end
        return true
    end 
end

function LibraryView:getSharedMetaData(dir)
    local cached_meta = PlgState:sharedMetaData(dir)
    if cached_meta then return cached_meta end
    
    local new_meta = Backend:sharedChapterMetadata(dir)
    PlgState:sharedMetaData(dir, new_meta)
    return new_meta
end

function LibraryView:getBrowserHomeDir(skip_check)
    local home_dir = Env.getHomeDir()
    if not H.is_str(home_dir) then return nil end
    local expected_path, browser_dir_name = Env.getLinksDir()
    
    if not H.is_str(PlgState.book_links_homedir) or PlgState.book_links_homedir ~= expected_path then
        local clean_home_dir = home_dir:gsub("/+$", "")
        local last_folder = clean_home_dir:match("([^/]+)$")
        if last_folder and last_folder == browser_dir_name then
            PlgState.book_links_homedir = home_dir
        else
            PlgState.book_links_homedir = expected_path
        end
    end

    if not skip_check then
        local success, err = pcall(FS.checkAndCreateFolder, PlgState.book_links_homedir)
        if not (success and util.directoryExists(PlgState.book_links_homedir)) then
            return nil
        end
    end
    return PlgState.book_links_homedir
end

function LibraryView:deleteFile(file, is_file)
    local exists = is_file and util.fileExists(file) or util.directoryExists(file)
    if not exists then return false end

    if FileManager.instance and FileManager.instance.goHome then
        pcall(function() FileManager.instance:goHome() end)
        FileManager.instance:deleteFile(file, is_file)
        pcall(function() FileManager.instance:onRefresh() end)
        return true
    end
    if is_file then
        return util.removeFile(file)
    else
        return pcall(ffiUtil.purgeDir, file)
    end
end

function LibraryView:getBrowserCurrentDir()
    local file_manager = FileManager.instance
    if file_manager and file_manager.file_chooser then
        return file_manager.file_chooser.path
    end
    local readerui = ReaderUI.instance
    if readerui then
        return readerui:getLastDirFile()
    end
end

function LibraryView:getInstance()
    if not LibraryView.instance then
        self:init()
    end
    return self
end

function LibraryView:getBrowserWidget()
    return init_book_links(self)
end

function LibraryView:getMenuWidget()
    return init_book_shelf(self)
end

-- reset widget cache on value change
function LibraryView:invalidateBookShelf()
    if self.book_shelf then
        self.book_shelf:onClose()
        self.book_shelf = nil
    end
end

function LibraryView:getBookTocWidget()
    return self.book_toc
end

function LibraryView:refreshBookTocWidget(bookinfo, onReturnCallBack, visible)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then return self.book_toc end

    local book_cache_id = bookinfo.cache_id
    local toc_obj = self.book_toc
    
    if not (H.is_tbl(toc_obj) and H.is_tbl(toc_obj.bookinfo) and toc_obj.bookinfo.cache_id == book_cache_id) then
        self.book_toc = ChapterListing:fetchAndShow({
            cache_id = bookinfo.cache_id,
            bookUrl = bookinfo.bookUrl,
            durChapterIndex = bookinfo.durChapterIndex,
            name = bookinfo.name,
            author = bookinfo.author,
            cacheExt = bookinfo.cacheExt,
            origin = bookinfo.origin,
            originName = bookinfo.originName,
            originOrder = bookinfo.originOrder,
            coverUrl = bookinfo.coverUrl,
        }, onReturnCallBack, function(chapter)
            self:loadAndRenderChapter(chapter)
        end, true, visible)
    else
        self.book_toc:updateReturnCallback(onReturnCallBack)
        if visible == true then
            self.book_toc:refreshItems(nil, true)
            UIManager:show(self.book_toc)
        end
    end
    return self.book_toc
end

function LibraryView:showBookTocDialog(bookinfo, onReturnCallBack)
    PlgState:chapterDirection("nil")
    return self:refreshBookTocWidget(bookinfo, onReturnCallBack, true)
end

function LibraryView:getReadingBookId()
    local book_cache_id
    local current_reading_chapter = PlgState:readingChapter()
    local toc_obj = self:getBookTocWidget()
    local current_selected_book = PlgState:currentSelectedBook()

    if current_reading_chapter and current_reading_chapter.book_cache_id then
        book_cache_id = current_reading_chapter.book_cache_id
    elseif toc_obj and H.is_tbl(toc_obj.bookinfo) and toc_obj.bookinfo.cache_id then
        book_cache_id = toc_obj.bookinfo.cache_id
    elseif current_selected_book then
        book_cache_id = current_selected_book.cache_id
    end
    return book_cache_id
end

return LibraryView