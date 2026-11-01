-- User-triggered native library/annotation actions. No cloud writes.
local UI=require('ui/uimanager');local S=require('readinknative/selection');local M={}
function M.shelfSelect(app)
    local shelf=require('readinknative/shelfmodel');local first=shelf.page(app).first
    app.shelfEditing=not app.shelfEditing;app.shelfSelection={}
    app.shelfPage=shelf.pageForIndex(app,first);app:draw()
    if not app.shelfEditing then require('readinknative/shelfmodel').ensure(app)end
end
function M.toggle(app,field,id)
    app[field]=app[field]or{};id=tostring(id);app[field][id]=not app[field][id];app:draw()
end
function M.shelfAll(app)
    app.shelfSelection=S.toggleAll(require('readinknative/shelfmodel').books(app),app.shelfSelection,'bookId');app:draw()
end
function M.hideBooks(app)
    local rows=require('readinknative/shelfmodel').selected(app)
    if #rows==0 then return end
    local state=app.state;local ids={};for _,book in ipairs(rows)do ids[tostring(book.bookId)]=true end
    UI:show(require('ui/widget/confirmbox'):new{text='从本机书架移出 '..#rows..' 本书？\n原书和笔记会保留，可在设置中恢复。',ok_text='移出',ok_callback=function()
        if app.state~=state or app.closed then return end
        S.hideBooks(state,ids);state:flush();app.shelfSelection={};app.shelfEditing=false;app:draw()
    end})
end
function M.noteSelect(app)
    app.notesEditing=not app.notesEditing;app.noteSelection={};app:draw()
end
function M.noteAll(app)
    app.noteSelection=S.toggleAll(require('readinknative/collections').records(app),app.noteSelection,'id');app:draw()
end
function M.copyNotes(app)
    local rows=S.notes(app);if #rows==0 then return end
    require('device').input.setClipboardText(S.noteText(rows))
    app:message('已复制 '..#rows..' 条记录到 KOReader 剪贴板。')
end
function M.deleteNotes(app)
    local rows=S.notes(app);if #rows==0 then return end
    local state,bookId=app.state,tostring(app.book.bookId);local ids={}
    for _,row in ipairs(rows)do ids[row.id]=true end
    UI:show(require('ui/widget/confirmbox'):new{text='删除选中的 '..#rows..' 条记录？已同步的划线也会从云端删除。',ok_text='删除',ok_callback=function()
        if app.closed or app.state~=state or not app.book or tostring(app.book.bookId)~=bookId then return end
        S.removeNotes(state,bookId,ids);state:flush();require('readinknative/annotationsync').changed(app);app.noteSelection={};app:draw()
    end})
end
function M.preference(app,key)
    if key=='defaultIndent'or key=='defaultColumns'then
        local f=app.state:format();local field=key=='defaultIndent'and'indent'or'columns'
        f[field]=not f[field];app.state:setGlobalFormat(f);app:draw();return
    end
    local p=require('readinknative/preferences').normalize(app.state.preferences)
    assert(p[key]~=nil,'UNKNOWN_PREFERENCE');p[key]=not p[key]
    app.state.preferences=p;app.state:flush();app:startClock();app:draw()
end
function M.shelfDensity(app)
    local P=require('readinknative/preferences');local shelf=require('readinknative/shelfmodel')
    local state,vid=app.state,app.client.data.vid;local dialog;local buttons={}
    for _,option in ipairs(P.shelfDensities)do
        local key=option.key
        buttons[#buttons+1]={{text=(P.shelfDensity()==key and'✓ 'or'')..option.label..' · 每行 '..option.columns..' 本',callback=function()
            UI:close(dialog)
            if app.closed or app.state~=state or app.client.data.vid~=vid then return end
            if P.shelfDensity()==key then return end
            local items=shelf.items(app);local first=shelf.page(app,nil,items).first
            P.setShelfDensity(key);app.view:relayoutShelf()
            app.shelfSelection={};app.shelfEditing=false
            app.shelfPage=shelf.pageForIndex(app,first,items);app:draw();app:loadCovers()
        end}}
    end
    buttons[#buttons+1]={{text='取消',callback=function()UI:close(dialog)end}}
    dialog=require('ui/widget/buttondialog'):new{title='书架显示密度',buttons=buttons};UI:show(dialog)
end
function M.exitTarget(app)
    local P=require('readinknative/preferences');local state,vid=app.state,app.client.data.vid
    local dialog;local buttons={}
    for _,option in ipairs{{'koreader','返回 KOReader'},{'kindle','退出 KOReader，返回 Kindle 系统'}}do
        local target=option[1]
        buttons[#buttons+1]={{text=(P.exitTarget()==target and'✓ 'or'')..option[2],callback=function()
            UI:close(dialog)
            if app.closed or app.state~=state or app.client.data.vid~=vid then return end
            P.setExitTarget(target);app:draw()
        end}}
    end
    buttons[#buttons+1]={{text='取消',callback=function()UI:close(dialog)end}}
    dialog=require('ui/widget/buttondialog'):new{title='退出阅墨后',buttons=buttons};UI:show(dialog)
end
function M.formatPanel(app)
    local P=require('readinknative/preferences');local state,vid=app.state,app.client.data.vid
    local dialog;local buttons={}
    for _,option in ipairs{{'readink','阅墨面板'},{'koreader','KOReader 面板'}}do
        local key=option[1]
        buttons[#buttons+1]={{text=(P.formatPanel()==key and'✓ 'or'')..option[2],callback=function()
            UI:close(dialog)
            if app.closed or app.state~=state or app.client.data.vid~=vid then return end
            if P.formatPanel()~=key then P.setFormatPanel(key)end
            app:draw()
        end}}
    end
    buttons[#buttons+1]={{text='取消',callback=function()UI:close(dialog)end}}
    dialog=require('ui/widget/buttondialog'):new{title='上滑排版面板',buttons=buttons};UI:show(dialog)
end
function M.gestureMode(app)
    local P=require('readinknative/preferences');local state,vid=app.state,app.client.data.vid
    local dialog;local buttons={}
    for _,option in ipairs{{'koreader','KOReader 手势'},{'readink','阅墨手势'}}do
        local key=option[1]
        buttons[#buttons+1]={{text=(P.gestureMode()==key and'✓ 'or'')..option[2],callback=function()
            UI:close(dialog)
            if app.closed or app.state~=state or app.client.data.vid~=vid then return end
            if P.gestureMode()~=key then
                require('readinknative/readersliders').cancel(app.view)
                require('readinknative/readerscroll').cancel(app.view,true)
                require('readinknative/nativegestures').close(app)
                P.setGestureMode(key)
                if key=='koreader'then
                    local ok,reason=require('readinknative/nativegestures').ensure(app)
                    if not ok then
                        local logok,logger=pcall(require,'logger')
                        if logok then logger.warn('ReadInk native gestures unavailable:',tostring(reason))end
                        app:message('当前 KOReader 未能加载手势功能，暂用阅墨手势。请确认已启用 KOReader 的手势插件。')
                    end
                end
            end
            app:draw()
        end}}
    end
    buttons[#buttons+1]={{text='取消',callback=function()UI:close(dialog)end}}
    dialog=require('ui/widget/buttondialog'):new{title='手势操作',buttons=buttons};UI:show(dialog)
end
function M.gestureSettings(app)
    local ok,opened,reason=pcall(function()return require('readinknative/nativegestures').openSettings(app)end)
    if ok and opened then return true end
    local logok,logger=pcall(require,'logger')
    if logok then logger.warn('ReadInk native gesture settings unavailable:',tostring(ok and reason or opened))end
    app:message('当前 KOReader 未能加载原生手势设置。请确认已启用 KOReader 的手势插件。')
    return false
end
function M.pageTurnMode(app)
    local supported=require('readinknative/pageeffects').supported()
    local state,vid=app.state,app.client.data.vid;local dialog
    local function select(effect)
        UI:close(dialog)
        if app.closed or app.state~=state or app.client.data.vid~=vid then return end
        local p=require('readinknative/preferences').normalize(state.preferences)
        p.pageTurnEffect=effect and require('readinknative/pageeffects').supported()or false
        state.preferences=p;state:flush();app.view.pageTurnEffect=nil;app:draw()
    end
    dialog=require('ui/widget/buttondialog'):new{title='翻页模式',buttons={
        {{text='普通翻页',callback=function()select(false)end}},
        {{text=supported and'翻页特效'or'翻页特效（本机不支持）',enabled=supported,callback=function()select(true)end}},
        {{text='取消',callback=function()UI:close(dialog)end}}}}
    UI:show(dialog)
end
function M.settings(app)
    local p=require('readinknative/preferences').normalize(app.state.preferences)
    local f=app.state:format()
    return {
        {'启动 KOReader 时打开阅墨','下次启动时自动进入阅墨书架',function()
            local prefs=require('readinknative/preferences');prefs.setOpenOnStart(not prefs.openOnStart());app:draw()
        end,require('readinknative/preferences').openOnStart()},
        {'锁屏壁纸',require('readinknative/wallpaper').label(),function()require('readinknative/wallpaperui').open(app)end},
        {'退出阅墨后',require('readinknative/preferences').exitTargetLabel(),function()M.exitTarget(app)end},
        {'翻页模式',require('readinknative/pageeffects').supported()and(p.pageTurnEffect and'翻页特效'or'普通翻页')or'普通翻页 · 本机不支持特效',function()M.pageTurnMode(app)end},
        {'上滑排版面板',require('readinknative/preferences').formatPanelLabel(),function()M.formatPanel(app)end},
        {'手势操作',require('readinknative/preferences').gestureModeLabel(),function()M.gestureMode(app)end},
        {'KOReader 手势设置','与 KOReader 阅读界面共用手势配置',function()M.gestureSettings(app)end},
        {'阅读',p.tapLeftNext and '点击左侧翻到下一页' or '点击左侧翻到上一页',function()M.preference(app,'tapLeftNext')end,p.tapLeftNext},
        {'首行缩进','所有书籍共用首行缩进设置',function()M.preference(app,'defaultIndent')end,f.indent},
        {'阅读时显示电池和 Wi-Fi','在阅读页右上角显示设备状态',function()M.preference(app,'showDeviceStatus')end,p.showDeviceStatus},
        {'阅读时显示时间','开启后显示当前系统时间',function()M.preference(app,'showTime')end,p.showTime},
        {'横屏双栏','所有书籍横屏时共用双栏设置',function()M.preference(app,'defaultColumns')end,f.columns},
        {'点开书中图片','关闭后不再点开放大图片，注释不受影响',function()M.preference(app,'tapImages')end,p.tapImages},
        {'同步阅读进度和时长',require('readinknative/readsync').status(app),function()M.preference(app,'syncReading');require('readinknative/readsync').start(app)end,p.syncReading},
        {'书架排序',({server='原顺序',recent='最近阅读',title='书名字序'})[app.state.sort],function()app:sortShelf()end},
        {'书架显示密度',require('readinknative/preferences').shelfDensityLabel(),function()M.shelfDensity(app)end},
        {'同步划线',require('readinknative/annotationsync').status(app),function()require('readinknative/annotationsync').request(app,true)end},
        {'导入本地书籍',nil,function()app:chooseFile()end},
        {'打开演示书',nil,function()app:demo()end},
        {'缓存管理',nil,function()app:cacheManager()end},
        {'恢复本机移出的书籍',nil,function()app.state.hiddenBooks={};app.state:flush();app:message('已恢复本机书架中的书籍。')end},
        {'关于 ReadInk',nil,function()app:about()end},
    }
end
return M
