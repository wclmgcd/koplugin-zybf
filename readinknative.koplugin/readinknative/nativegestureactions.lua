-- Events from ReadInk's private native Dispatcher. Never pass a reader event
-- to the underlying ReaderUI: it may own an entirely different local book.
local M={}
local F=require('readinknative/format')
local unpack=table.unpack or unpack

local function finite(v)return type(v)=='number'and v==v and v~=math.huge and v~=-math.huge end
local function copy(v)
    if type(v)~='table'then return v end
    local t={};for k,x in pairs(v)do t[k]=copy(x)end;return t
end
local function native(context,name)
    return(context and context.require or require)(name)
end
local function ui(context)return context and context.UI or require('ui/uimanager')end
local function message(a,text)if a and a.message then a:message(text)end end
local function unsupported(a)message(a,'该手势动作暂不适用于阅墨。')end
local function live(a)return a and not a.closed and not a.suspended end
local function reading(a)return live(a)and a.mode=='reader'and a.book and a.state and a.document and a.document.doc end
local function owner(a)return{book=a.book,state=a.state,document=a.document,chapter=a.chapter}end
local function same(a,o)
    return reading(a)and a.book==o.book and a.state==o.state and a.document==o.document and a.chapter==o.chapter
end
local function changedPosition(a)
    a:savePosition();a:draw()
end
local function invalidate(a)
    local d=a.document
    if d and d.doc then
        if d.doc.resetBufferCache then d.doc:resetBufferCache()
        elseif d.doc.resetCallCache then d.doc:resetCallCache()end
        if d.clearPageImages then d:clearPageImages()end
    end
end

-- Only methods whose effects are device-wide and have no host book/menu
-- dependency are allowed. In particular, Exit/Restart, USB storage, temporary
-- sensor timers, fullscreen and chapter-specific refresh policies stay out.
local deviceActions={
    ToggleFrontlight='hasFrontlight',SetFlIntensity='hasFrontlight',
    IncreaseFlIntensity='hasFrontlight',DecreaseFlIntensity='hasFrontlight',
    SetFlWarmth='hasNaturalLight',IncreaseFlWarmth='hasNaturalLight',DecreaseFlWarmth='hasNaturalLight',
    ToggleNightMode=true,SetNightMode=true,
    SetBothRefreshRates='hasEinkScreen',SetDayRefreshRate='hasEinkScreen',SetNightRefreshRate='hasEinkScreen',
    SwapPageTurnButtons='hasKeys',SetPageTurnButtonDirection='hasKeys',ToggleKeyRepeat='canKeyRepeat',
    ToggleGSensor='hasGSensor',LockGSensor='hasGSensor',SetLockGSensor='hasGSensor',
    RequestSuspend='canSuspend',RequestReboot='canReboot',RequestPowerOff='canPowerOff',
}
local incremental={IncreaseFlIntensity=true,DecreaseFlIntensity=true,IncreaseFlWarmth=true,DecreaseFlWarmth=true}
local numericDevice={SetFlIntensity=true,SetFlWarmth=true,SetBothRefreshRates=true,SetDayRefreshRate=true,SetNightRefreshRate=true}
local booleanDevice={SetNightMode=true,SetPageTurnButtonDirection=true,SetLockGSensor=true}
local wifiActions={InfoWifiOn=true,InfoWifiOff=true,ToggleWifi=true,ShowNetworkInfo=true}
local function capable(device,cap)
    return cap==true or(type(device[cap])=='function'and device[cap](device))
end
local function gestureValue(value)
    if finite(value)then return value end
    if type(value)~='table'or(value.distance~=nil and(not finite(value.distance)or value.distance<0))then return nil end
    return copy(value)
end
local function deviceAction(a,name,args,context)
    local device=require('device')
    if name=='ShowFlDialog'then
        if not capable(device,'hasFrontlight')then unsupported(a);return end
        -- Device:showLightDialog() opens an unowned global popup. Instantiate
        -- the exact same native widget through the private UI owner instead.
        ui(context):show(native(context,'ui/widget/frontlightwidget'):new{})
        return
    end
    if name=='FullRefresh'then
        invalidate(a)
        if a.draw then a:draw()end
        ui(context):setDirty(a.view,'full',a.view and a.view.dimen)
        return
    end
    local cap=wifiActions[name]and'hasWifiToggle'or deviceActions[name]
    if not capable(device,cap)then unsupported(a);return end
    local arg=args[1]
    if numericDevice[name]and not finite(arg)then unsupported(a);return end
    if booleanDevice[name]and type(arg)~='boolean'then unsupported(a);return end
    if incremental[name]then arg=gestureValue(arg);if arg==nil then unsupported(a);return end end
    local path=wifiActions[name]and'ui/network/networklistener'or'device/devicelistener'
    local class=native(context,path)
    local method=class['on'..name]
    if type(method)~='function'then unsupported(a);return end
    -- This is a temporary method receiver, not a registered host listener.
    -- Its only document is the current ReadInk CRe instance (night-mode cache).
    local receiver=setmetatable({ui={document=a.document and a.document.doc}},{__index=class})
    if name=='RequestSuspend'or name=='RequestReboot'or name=='RequestPowerOff'then a:savePosition(true)end
    method(receiver,arg,unpack(args,2,args.n or #args))
    if name=='ToggleNightMode'or name=='SetNightMode'then
        invalidate(a);if a.draw then a:draw()end
        ui(context):setDirty(a.view,'full',a.view and a.view.dimen)
    end
end

local formatEvents={SetFontSize='font_size',SetLineSpace='line_spacing',SetFontBaseWeight='font_base_weight',
    SetPageHorizMargins='h_page_margins',SetPageTopMargin='t_page_margin',SetPageBottomMargin='b_page_margin',
    SetVisiblePages='visible_pages',SetBlockRenderingMode='block_rendering_mode',SetRenderDPI='render_dpi',
    SetWordSpacing='word_spacing',SetWordExpansion='word_expansion',SetCJKWidthScaling='cjk_width_scaling',
    SetFontGamma='font_gamma',SetFontHinting='font_hinting',SetFontKerning='font_kerning',SetStatusLine='status_line'}
local booleanFormat={SyncPageTopBottomMargins='sync_t_b_page_margins',ToggleEmbeddedStyleSheet='embedded_css',
    ToggleEmbeddedFonts='embedded_fonts',ToggleImageScaling='smooth_scaling',ToggleNightmodeImages='nightmode_images'}
local rotationEvents={SetRotationMode=true,SwapRotation=true,InvertRotation=true,IterateRotation=true}
local function formatAction(a,name,arg,context)
    if rotationEvents[name]then
        local mode=require('device').screen:getRotationMode()
        if name=='SetRotationMode'then mode=arg
        elseif name=='InvertRotation'then mode=(mode+2)%4
        elseif name=='IterateRotation'then mode=(mode+(arg and -1 or 1))%4
        else mode=mode%2==0 and(mode+1)%4 or(mode-1)%4 end
        if not finite(mode)or mode%1~=0 or mode<0 or mode>3 then unsupported(a);return end
        a:setReaderRotation(mode);return
    end
    local patch
    if formatEvents[name]then
        patch=F.nativePatch(formatEvents[name],arg)
    elseif booleanFormat[name]then
        local key=booleanFormat[name]
        if arg==nil then arg=F.resolveEngineDefaults(a.document.doc,a.state:format(a.book))[key]~=1 end
        if type(arg)=='boolean'then patch=F.nativePatch(key,arg and 1 or 0)end
    elseif name=='SetViewMode'and(arg=='page'or arg=='scroll')then
        patch={view_mode=arg=='scroll'and 1 or 0}
    elseif name=='SetFont'and type(arg)=='string'and arg~=''then
        patch={face=arg} -- App/Document retain exact font source verification.
    elseif name=='SetPageTopAndBottomMargin'and type(arg)=='table'and finite(arg[1])and finite(arg[2])then
        patch={margin_top=arg[1],margin_bottom=arg[2]}
    elseif name=='ChangeSize'or name=='IncreaseFontSize'or name=='DecreaseFontSize'then
        local delta=arg
        if name~='ChangeSize'then
            delta=gestureValue(arg)
            if type(delta)=='table'then
                -- Native ReaderFont's scaling is read-only and independent of
                -- a ReaderUI instance. Keep the installed host's exact curve.
                local font=native(context,'apps/reader/modules/readerfont')
                delta=font.gesToFontSize(font,delta)
            end
            if name=='DecreaseFontSize'and finite(delta)then delta=-delta end
        end
        if finite(delta)then patch={size=a.state:format(a.book).size+delta}end
    end
    if patch then a:changeFormat(patch)else unsupported(a)end
end

local function pageIndex(a)
    local page,total=require('readinknative/pagination').position(a)
    if finite(page)and finite(total)and total>=1 then return page,total end
end
local function needIndex(a)
    require('readinknative/pagination').request(a)
    message(a,'全书页码尚未计算完成，请稍后重试。')
end
local function jumpPage(a,page)
    if not finite(page)then unsupported(a);return end
    local _,total=pageIndex(a)
    if not total then needIndex(a);return end
    a:clearTextSelection()
    require('readinknative/pagination').jump(a,math.max(1,math.min(total,math.floor(page))))
end
local function turn(a,delta)
    if not finite(delta)or delta==0 then return end
    local d=a.document
    if d:isScroll()then
        -- Scroll distances are screenfuls, not chapter indices. App:scrollBy
        -- clamps and crosses at most the immediately adjacent chapter edge.
        a:scrollBy(delta*d.h,{allowBoundary=true});return
    end
    delta=delta>0 and math.ceil(delta)or math.floor(delta)
    local count=F.visiblePages(d.format or a.state:format(a.book),d.w,d.h)
    if d.doc.getVisiblePageNumberCount then
        local n=d.doc:getVisiblePageNumberCount();if finite(n)and n>=1 then count=n end
    end
    local step=delta*count
    local target=d:page()+step
    if target>=1 and target<=d:count()then a:turn(step);return end
    -- App:turn(10) would use that same 10 as a chapter delta at an edge. Route
    -- larger jumps through whole-book pagination, never skip ten chapters.
    if math.abs(delta)==1 then a:turn(delta);return end
    local page,total=pageIndex(a)
    if total then jumpPage(a,page+step)else needIndex(a)end
end
local function relativePage(a,delta)
    if not finite(delta)or delta==0 then return end
    local page,total=pageIndex(a)
    if total then jumpPage(a,page+delta);return end
    local target=a.document:page()+delta
    if target>=1 and target<=a.document:count()then
        a:clearTextSelection();a.document:jump(target);changedPosition(a)
    else needIndex(a)end
end
local function chapter(a,delta)
    local chapters=a:catalogItems();local index
    if a.book.localFile then index=(require('readinknative/collections').current(a)or 1)+delta
    else index=require('readinknative/pagination').next(a,delta)end
    if chapters[index]then a:selectChapter(chapters[index],index,{origin='gesture'})
    else message(a,delta<0 and'已到第一章。'or'已到最后一章。')end
end
local function edge(a,which)
    if not a.book.localFile and a.chapters and #a.chapters>0 then
        local index=which=='end'and #a.chapters or 1
        a:selectChapter(a.chapters[index],index,{edge=which,origin='gesture'})
    else a:clearTextSelection();a.document:edge(which);changedPosition(a)end
end

local function bookmarks(a)
    local order={};for i,ch in ipairs(a:catalogItems())do if ch.chapterUid then order[tostring(ch.chapterUid)]=i end end
    local current=a.book.localFile and 1 or(a.chapter and order[tostring(a.chapter.chapterUid)])
    local result={}
    for _,row in ipairs(require('readinknative/annotations').list(a.state,a.book.bookId,'bookmark'))do
        local index=a.book.localFile and 1 or order[row.chapterUid]
        local pos=row.position
        if index and type(pos)=='table'and type(pos.xpointer)=='string'then
            local page=tonumber(pos.page)or 1
            if index==current then
                if a.document.doc:isXPointerInDocument(pos.xpointer)then page=a.document.doc:getPageFromXPointer(pos.xpointer)
                else page=nil end
            end
            if finite(page)then result[#result+1]={record=row,index=index,page=page}end
        end
    end
    table.sort(result,function(x,y)
        if x.index~=y.index then return x.index<y.index end
        if x.page~=y.page then return x.page<y.page end
        return tostring(x.record.id)<tostring(y.record.id)
    end)
    return result,current
end
local function bookmark(a,name)
    local rows,current=bookmarks(a);local selected
    if name=='GotoFirstBookmark'then selected=rows[1]
    elseif name=='GotoLastBookmark'then selected=rows[#rows]
    elseif name=='GoToLatestBookmark'then
        for _,row in ipairs(rows)do
            if not selected or(tonumber(row.record.updated)or 0)>(tonumber(selected.record.updated)or 0)then selected=row end
        end
    elseif current then
        local page=a.document:page()
        for _,row in ipairs(rows)do
            if name=='GotoPreviousBookmarkFromPage'and(row.index<current or row.index==current and row.page<page)then selected=row
            elseif name=='GotoNextBookmarkFromPage'and(row.index>current or row.index==current and row.page>page)then selected=row;break end
        end
    end
    if selected then a:jumpAnnotation(selected.record)else message(a,'当前位置没有可跳转的书签。')end
end
local bookmarkEvents={GotoFirstBookmark=true,GotoLastBookmark=true,GoToLatestBookmark=true,
    GotoPreviousBookmarkFromPage=true,GotoNextBookmarkFromPage=true}

local function input(a,kind,context)
    local current,total
    if kind=='page'then current,total=pageIndex(a);if not total then needIndex(a);return end end
    local o=owner(a);local dialog;local U=ui(context)
    dialog=native(context,'ui/widget/inputdialog'):new{
        title=kind=='page'and('跳转到全书页码（1–'..total..'）')or'搜索正文',
        input=kind=='page'and tostring(current)or(a.textQuery or''),
        input_type=kind=='page'and'number'or nil,
        buttons={{{text='取消',callback=function()U:close(dialog)end},
            {text=kind=='page'and'跳转'or'搜索',is_enter_default=true,callback=function()
                local value=dialog:getInputText();U:close(dialog)
                if not same(a,o)then return end
                if kind=='page'then jumpPage(a,tonumber(value))else a:searchDocument(value)end
            end}}}}
    U:show(dialog);dialog:onShowKeyboard()
end

local bookkeeping={ConfigChange=true,BatchedUpdate=true,BatchedUpdateDone=true,HandledAsSwipe=true}
local function dispatch(a,name,args,context)
    if not live(a)or bookkeeping[name]then return end
    if deviceActions[name]or wifiActions[name]or name=='ShowFlDialog'or name=='FullRefresh'then
        deviceAction(a,name,args,context);return
    end
    if name=='Back'then a:back();return end
    if name=='ShowMenu'then
        if reading(a)then a:clearTextSelection();a.panel=nil;a.toolbar=true;a:draw()
        else a:accountSettings()end
        return
    end
    if name=='FlushSettings'then a:savePosition(true);return end
    if not reading(a)then message(a,'请先在阅墨打开一本书。');return end
    local arg=args[1]
    if formatEvents[name]or booleanFormat[name]or rotationEvents[name]or name=='SetFont'or name=='SetViewMode'
        or name=='ChangeSize'or name=='IncreaseFontSize'or name=='DecreaseFontSize'or name=='SetPageTopAndBottomMargin'then
        formatAction(a,name,arg,context)
    elseif name=='ShowConfigMenu'then a:showFormatPanel()
    elseif name=='GotoViewRel'then turn(a,arg)
    elseif name=='GotoRelativePage'then relativePage(a,arg)
    elseif name=='GotoPage'then jumpPage(a,arg)
    elseif name=='GotoPercent'and finite(arg)then
        local _,total=pageIndex(a);if total then jumpPage(a,math.floor(total*arg/100+0.5))else needIndex(a)end
    elseif name=='GoToBeginning'then edge(a,'start')
    elseif name=='GoToEnd'then edge(a,'end')
    elseif name=='GoToRandomPage'then
        local _,total=pageIndex(a);if total then jumpPage(a,math.random(1,total))else needIndex(a)end
    elseif name=='GotoPrevChapter'then chapter(a,-1)
    elseif name=='GotoNextChapter'then chapter(a,1)
    elseif name=='ShowToc'then a:showCatalog()
    elseif name=='ShowBookmark'then a:notes();a.notesOnlyBookmarks=true;a:draw()
    elseif name=='ToggleBookmark'then a:bookmark()
    elseif bookmarkEvents[name]then bookmark(a,name)
    elseif name=='GoBackLink'then
        if not require('readinknative/readerlinks').back(a)and not require('readinknative/booksearch').back(a)then
            message(a,'没有可返回的阅读位置。')
        end
    elseif name=='ShowGotoDialog'then input(a,'page',context)
    elseif name=='ShowFulltextSearchInput'then input(a,'search',context)
    elseif name=='ShowFindAllResults'then
        local search=require('readinknative/booksearch')
        if a.searchResults and search.valid(a,a.searchOwner)then a.mode='search';a.panel=nil;a:draw()
        else message(a,'请先搜索当前阅墨图书。')end
    elseif name=='TogglePageChangeAnimation'then require('readinknative/libraryactions').preference(a,'pageTurnEffect')
    else unsupported(a)end
end

function M.handle(app,event,context)
    local name=type(event)=='table'and(event.handler or event.name)
    if type(name)~='string'then return true end
    if name:sub(1,2)=='on'then name=name:sub(3)end
    local args=type(event.args)=='table'and event.args or{}
    local ok,err=pcall(dispatch,app,name,args,context)
    if not ok then
        local loaded,logger=pcall(require,'logger')
        if loaded then logger.warn('ReadInk native gesture:',name,err)end
        if live(app)then message(app,'此手势动作未能执行，请重试。')end
    end
    -- Deliberately consume unsupported/failed events as well. Returning nil or
    -- forwarding them would give the background book a chance to act on them.
    return true
end
return M
