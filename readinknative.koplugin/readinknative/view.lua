-- Entire scene, painting and hit testing authored for the independent branch.
local UI=require('ui/uimanager');local Geom=require('ui/geometry')
local BB=require('ffi/blitbuffer');local Font=require('ui/font')
local Text=require('ui/widget/textwidget');local Box=require('ui/widget/textboxwidget')
local Layout=require('readinknative/layout')
local InputContainer=require('ui/widget/container/inputcontainer')
local View=InputContainer:extend{covers_fullscreen=true,stop_events_propagation=true}
function View:init()
    local screen=require('device').screen
    self.dimen=Geom:new{x=0,y=0,w=screen:getWidth(),h=screen:getHeight()}
    local scale=screen:scaleBySize(100)/100
    self.layout=Layout.build(self.dimen.w,self.dimen.h,scale,require('readinknative/preferences').shelfDensity())
    self.fontScale=scale
    local sliderRate=screen.low_pan_rate and 5 or 12
    local function activeSlider()return self.sliderDrag and self.dimen end
    local function bodyDrag()return not self.sliderDrag and self.dimen end
    self.ges_events={RawTouch={require('ui/gesturerange'):new{ges='touch',range=self.dimen}},
        SliderPan={require('ui/gesturerange'):new{ges='pan',range=self.dimen,rate=sliderRate}},
        SliderRelease={require('ui/gesturerange'):new{ges='pan_release',range=self.dimen},require('ui/gesturerange'):new{ges='multiswipe',range=activeSlider},require('ui/gesturerange'):new{ges='double_tap',range=activeSlider}},
        SliderHoldDrag={require('ui/gesturerange'):new{ges='hold_pan',range=activeSlider,rate=sliderRate}},
        SliderCancel={require('ui/gesturerange'):new{ges='two_finger_pan',range=activeSlider},require('ui/gesturerange'):new{ges='two_finger_tap',range=activeSlider},require('ui/gesturerange'):new{ges='two_finger_swipe',range=activeSlider},require('ui/gesturerange'):new{ges='pinch',range=activeSlider},require('ui/gesturerange'):new{ges='spread',range=activeSlider},require('ui/gesturerange'):new{ges='rotate',range=activeSlider},require('ui/gesturerange'):new{ges='two_finger_hold',range=activeSlider},require('ui/gesturerange'):new{ges='two_finger_hold_pan',range=activeSlider},require('ui/gesturerange'):new{ges='two_finger_pan_release',range=activeSlider},require('ui/gesturerange'):new{ges='two_finger_hold_pan_release',range=activeSlider}},
        Touch={require('ui/gesturerange'):new{ges='tap',range=self.dimen}},
        Swipe={require('ui/gesturerange'):new{ges='swipe',range=self.dimen}},
        TextHold={require('ui/gesturerange'):new{ges='hold',range=self.dimen}},
        TextDrag={require('ui/gesturerange'):new{ges='hold_pan',range=bodyDrag,rate=5}},
        TextRelease={require('ui/gesturerange'):new{ges='hold_release',range=self.dimen}}}
    self.key_events={AppBack={{'Back'}},Next={{'Right'},{'PgFwd'},{'LPgFwd'},{'RPgFwd'}},Previous={{'Left'},{'PgBack'},{'LPgBack'},{'RPgBack'}}}
    self.objects={};self.hits={};self.sliderHits={};self.coverObjects={};self.coverOrder={};self.badCovers={}
    self.iconObjects={};self.iconOrder={};self.iconBytes=0
    self:syncGestureSettings()
end
function View:clearObjects()
    for _,obj in ipairs(self.objects)do if obj.free then obj:free()end end
    self.objects={}
end
function View:clearReaderText()
    for _,entry in ipairs(self.readerText or{})do entry.object:free()end;self.readerText={}
end
function View:syncGestureSettings()
    local P=require('readinknative/preferences')
    local enabled=self.app and self.app.mode=='reader'and P.gestureMode and P.gestureMode()=='koreader'
    local disabled=true
    if enabled and G_reader_settings and G_reader_settings.nilOrTrue then
        disabled=G_reader_settings:nilOrTrue('disable_double_tap')
    end
    self.disable_double_tap=disabled
    local input=require('device').input
    if input and UI.getTopmostVisibleWidget and UI:getTopmostVisibleWidget()==self then
        input.disable_double_tap=disabled
    end
    self:onUpdateHoldPanRate(enabled)
    return enabled or false
end
function View:onUpdateHoldPanRate(nativeMode)
    if nativeMode==nil then
        local P=require('readinknative/preferences')
        nativeMode=self.app and self.app.mode=='reader'and P.gestureMode and P.gestureMode()=='koreader'
    end
    local rate=5
    if nativeMode then
        local default=require('device').screen.low_pan_rate and 5 or 30
        rate=G_reader_settings and tonumber(G_reader_settings:readSetting('hold_pan_rate',default))or default
        if not rate or rate~=rate or rate<=0 or rate==math.huge then rate=default end
    end
    for _,range in ipairs(self.ges_events and self.ges_events.TextDrag or{})do
        if range.rate~=rate then range.rate=rate;range.last_time=nil end
    end
    return true
end
function View:onShow()self:syncGestureSettings();UI:setDirty(self,'full',self.dimen)end
function View:refresh()
    require('readinknative/avatarpaint').invalidate(self)
    self:syncGestureSettings()
    if require('readinknative/readersliders').redraw(self)then return end
    local requested
    if self.scrollFinishRefresh then self.scrollFinishRefresh=nil;requested='partial'
    elseif self.scrollDrag then requested='fast'end
    -- The engine only knows image coverage after painting. Resolve the waveform
    -- and unchanged header region in that repaint. Scroll completion uses the
    -- same region and periodic-cleanup policy as ordinary page turns.
    local before=self.readerPaintSerial or 0
    UI:setDirty(self,function()
        -- A fullscreen modal may prevent this View from being painted while
        -- UIManager still drains deferred refresh callbacks.
        if (self.readerPaintSerial or 0)<=before then return end
        return require('readinknative/refresh').take(self,requested)
    end)
end
function View:text(bb,text,x,y,w,size,bold,lines,bgcolor,fgcolor,fontName,alignment)
    local object
    local cache=self.app.mode=='reader'and not self.app.toolbar and #tostring(text or'')<=512
    local key=cache and table.concat({tostring(text or''),w,size,tostring(bold),tostring(lines),tostring(bgcolor),tostring(fgcolor),fontName or'',alignment or'',self.fontScale},'\0')
    if cache then
        self.readerText=self.readerText or{}
        for i,entry in ipairs(self.readerText)do if entry.key==key then object=entry.object;table.remove(self.readerText,i);self.readerText[#self.readerText+1]=entry;break end end
    end
    if fontName then
        self.fontFiles=self.fontFiles or{}
        if not self.fontFiles[fontName]then
            local fonts=require('fontlist'):getFontList();local found=false
            for _,path in ipairs(fonts)do if path==fontName then found=true;break end end
            if not found then fonts[#fonts+1]=fontName end
            self.fontFiles[fontName]=true
        end
    end
    if not object and lines then object=Box:new{text=tostring(text or ''),face=Font:getFace(fontName or'cfont',size/self.fontScale),width=w,
        height=math.floor(size*1.45*lines),alignment=alignment or'left',height_adjust=true,height_overflow_show_ellipsis=true,bold=bold or false,bgcolor=bgcolor or BB.COLOR_WHITE,fgcolor=fgcolor or BB.COLOR_BLACK}
    elseif not object then object=Text:new{text=tostring(text or ''),face=Font:getFace(fontName or'cfont',size/self.fontScale),max_width=w,bold=bold or false,fgcolor=fgcolor or BB.COLOR_BLACK}
    end
    if not lines and bgcolor then local z=object:getSize();bb:paintRect(math.floor(x),math.floor(y),z.w,z.h,bgcolor)end
    if cache then
        local found=false;for _,entry in ipairs(self.readerText)do if entry.object==object then found=true;break end end
        if not found then
            if #self.readerText>=16 then table.remove(self.readerText,1).object:free()end
            self.readerText[#self.readerText+1]={key=key,object=object}
        end
    else self.objects[#self.objects+1]=object end
    object:paintTo(bb,math.floor(x),math.floor(y));return object
end
-- Keep the full source in a real TextBox: font shaping decides page boundaries.
function View:pageText(bb,text,x,y,w,h,size,page,lineHeight)
    local box=Box:new{text=text,face=Font:getFace('cfont',size/self.fontScale),width=w,height=h,line_height=lineHeight,
        height_adjust=false,height_overflow_show_ellipsis=false}
    local lines=math.max(1,box:getVisLineCount());local pages=math.max(1,math.ceil(box:getAllLineCount()/lines))
    page=math.max(1,math.min(page,pages))
    if page>1 then
        if lineHeight then box:scrollToRatio((page-1)/(pages-1),true)else box:scrollLines((page-1)*lines)end
    end
    self.objects[#self.objects+1]=box;box:paintTo(bb,x,y)
    self.detailTextBox=box
    return page,pages
end
-- Official statistics use large numeric spans on a shared text baseline.
function View:richText(bb,spans,x,y,width)
    local function build(ratio)
        local objects={};local w,baseline,bottom=0,0,0
        for _,part in ipairs(spans)do
            local obj=Text:new{text=part.text,face=Font:getFace('cfont',self.layout.s(part.size)*ratio/self.fontScale),bold=true}
            local size=obj:getSize();local base=obj:getBaseline()
            objects[#objects+1]={object=obj,w=size.w,base=base};w=w+size.w;baseline=math.max(baseline,base);bottom=math.max(bottom,size.h-base)
        end
        return objects,w,baseline,bottom
    end
    local objects,w,baseline,bottom=build(1)
    if w>width then for _,v in ipairs(objects)do v.object:free()end;objects,w,baseline,bottom=build(width/w)end
    for _,v in ipairs(objects)do self.objects[#self.objects+1]=v.object;v.object:paintTo(bb,math.floor(x),math.floor(y+baseline-v.base));x=x+v.w end
    return baseline+bottom
end
function View:hit(rect,action,hold_passthrough,hold_action)
    self.hits[#self.hits+1]={rect=rect,action=action,hold_passthrough=hold_passthrough,hold_action=hold_action}
end
function View:button(bb,label,x,y,w,h,action,selected)
    if selected then bb:paintRect(x,y+h-3,w,3,BB.COLOR_BLACK)end
    local s=self.layout.s
    local object=Text:new{text=label,face=Font:getFace('cfont',17),max_width=w-s(12),bold=selected or false}
    self.objects[#self.objects+1]=object
    local size=object:getSize()
    object:paintTo(bb,math.floor(x+(w-size.w)/2),math.floor(y+(h-size.h)/2))
    self:hit({x=x,y=y,w=w,h=h},action)
end
-- Official Android vector paths are rendered by KOReader's SVG backend.
function View:icon(bb,name,x,y,w,h,action,selected,metrics,hold_action)
    local iw=metrics and metrics.pixel_w or self.layout.s(metrics and metrics.w or 28)
    local ih=self.layout.s(metrics and metrics.h or 28)
    local rotation=metrics and metrics.rotation or 0
    local key=name..':'..iw..'x'..ih..(rotation~=0 and(':'..rotation)or'')
    local entry=self.iconObjects[key]
    if not entry then
        local obj=require('ui/widget/imagewidget'):new{file=self.app.path..'/resources/official/'..name..'.svg',width=iw,height=ih,scale_factor=0,alpha=true,rotation_angle=rotation}
        local bytes=iw*ih*4
        while #self.iconOrder>0 and(#self.iconOrder>=48 or self.iconBytes+bytes>4*1024*1024)do
            local old=table.remove(self.iconOrder,1);local item=self.iconObjects[old]
            self.iconBytes=self.iconBytes-item.bytes;item.object:free();self.iconObjects[old]=nil
        end
        entry={object=obj,bytes=bytes};self.iconObjects[key]=entry;self.iconBytes=self.iconBytes+bytes
    else for i,k in ipairs(self.iconOrder)do if k==key then table.remove(self.iconOrder,i);break end end end
    self.iconOrder[#self.iconOrder+1]=key
    local obj=entry.object
    obj:paintTo(bb,math.floor(x+(w-iw)/2),math.floor(y+(h-ih)/2))
    if action then self:hit({x=x,y=y,w=w,h=h},action,nil,hold_action)end
end
-- Official DownloadingIcon: outlined circle with a clockwise filled sector
-- from twelve o'clock. The shelf places it immediately before the book title.
function View:downloadCircle(bb,percent,x,y,w,h,logicalSize)
    local sweep=math.max(0,math.min(99,percent))*3.6
    local angle=math.rad(sweep-90)
    local sector=sweep>0 and string.format('<path d="M5 5 L5 0 A5 5 0 %d 1 %.5f %.5f Z" fill="black"/>',sweep>180 and 1 or 0,5+5*math.cos(angle),5+5*math.sin(angle))or''
    local size=self.layout.s(logicalSize or 14)
    local svg='<svg xmlns="http://www.w3.org/2000/svg" width="'..size..'" height="'..size..'" viewBox="0 0 10 10"><circle cx="5" cy="5" r="4.5" fill="none" stroke="black" stroke-width="1"/>'..sector..'</svg>'
    local image=require('ui/renderimage'):renderSVGImageDataWithCRengine(svg,#svg,size,size)
    if not image then return end
    local object=require('ui/widget/imagewidget'):new{image=image,alpha=true}
    self.objects[#self.objects+1]=object
    object:paintTo(bb,math.floor(x+(w-size)/2),math.floor(y+(h-size)/2))
end
function View:settingRow(bb,key,label,lo,hi,step,y)
    local a=self.app;local l=self.layout;local s=l.s;local f=a.state:format(a.book)
    local x=l.side;local width=l.w-2*x;local height=s(32)
    local start=x+s(48);local finish=l.w-x-s(48)
    self:button(bb,'−',x,y,s(32),height,function()a:changeFormat{[key]=f[key]-step}end)
    self:button(bb,'+',l.w-x-s(32),y,s(32),height,function()a:changeFormat{[key]=f[key]+step}end)
    bb:paintRect(start,y+height/2,finish-start,s(1),BB.COLOR_LIGHT_GRAY)
    for tick=0,9 do
        local tx=start+(finish-start)*tick/9
        bb:paintRect(tx,y+height/2-s(3),s(1),s(6),BB.COLOR_DARK_GRAY)
        local value=lo+(hi-lo)*tick/9
        self:hit({x=tx-s(10),y=y,w=s(20),h=height},function()a:changeFormat{[key]=math.floor(value/step+0.5)*step}end)
    end
    local knob=start+(finish-start)*math.max(0,math.min(1,(f[key]-lo)/(hi-lo)))
    bb:paintRect(knob-s(3),y+height/2-s(7),s(6),s(14),BB.COLOR_BLACK)
    self:text(bb,label..'  '..tostring(f[key]),start,y-s(9),finish-start,s(10),false)
end
function View:fontPanel(bb)return require('readinknative/readerpanels').font(self,bb)end
function View:fontListPanel(bb)return require('readinknative/fontpicker').paint(self,bb)end
function View:progressPanel(bb)return require('readinknative/readerpanels').progress(self,bb)end
function View:header(bb,title,right,action)
    local l=self.layout;local s=l.s
    self:text(bb,title,l.side,s(13),l.w-l.side*2-s(100),s(22),true)
    if right then self:button(bb,right,l.w-l.side-s(90),0,s(90),l.top,action)end
end
function View:cover(bb,book,rect)
    local path=require('readinknative/covercache').find(self.app.client.data.vid,book.cover,book.coverSquare)
    if not path or self.badCovers[path]then return false end
    local key=path..':'..rect.w..'x'..rect.h
    local image=self.coverObjects[key]
    if not image then
        local ok,obj=pcall(require('readinknative/coverframe').load,path,rect.w,rect.h)
        if not ok then self.badCovers[path]=true;return false end
        image=obj;image.coverBytes=rect.w*rect.h;self.coverBytes=(self.coverBytes or 0)+image.coverBytes
        self.coverObjects[key]=image;self.coverOrder[#self.coverOrder+1]=key
        -- Compact pages/folders can contain more than 24 tiny covers. Bound
        -- decoded bytes as well as objects instead of thrashing that page.
        while #self.coverOrder>1 and(#self.coverOrder>96 or self.coverBytes>4*1024*1024)do
            local old=table.remove(self.coverOrder,1);local cached=self.coverObjects[old]
            if cached then self.coverBytes=self.coverBytes-cached.coverBytes;cached:free();self.coverObjects[old]=nil end
        end
    end
    local ok=pcall(function()image:paintTo(bb,rect.x,rect.y)end)
    if not ok then self.coverBytes=self.coverBytes-image.coverBytes;image:free();self.coverObjects[key]=nil;self.badCovers[path]=true end
    if not ok then return false end
    return true,rect
end
function View:groupCover(bb,group,c)
    local s=self.layout.s;local gap=s(5);local px,py=s(6),s(9)
    bb:paintRect(c.x,c.y,c.w,c.h,BB.COLOR_WHITE);bb:paintBorder(c.x,c.y,c.w,c.h,s(1),BB.COLOR_LIGHT_GRAY)
    local w=math.floor((c.w-2*px-gap)/2);local h=math.floor((c.h-2*py-gap)/2)
    for i=1,4 do
        local r={x=c.x+px+((i-1)%2)*(w+gap),y=c.y+py+math.floor((i-1)/2)*(h+gap),w=w,h=h}
        local b=group.books[i]
        if not b or not self:cover(bb,b,r)then
            if b then bb:paintRect(r.x,r.y,r.w,r.h,BB.COLOR_LIGHT_GRAY);self:text(bb,b.title,r.x+s(3),r.y+s(8),r.w-s(6),s(10),false,3)
            else self:icon(bb,'icon_bookshelf_archive_empty',r.x,r.y,r.w,r.h,nil,nil,{w=28,h=28})end
        end
    end
end
function View:shelf(bb)
    local a=self.app;local l=self.layout;local s=l.s
    local shelf=require('readinknative/shelfmodel');local books=shelf.items(a);local page=shelf.page(a,nil,books)
    local pages=page.pages;a.shelfPage=page.page;self.shelfWindow=page
    local y=s(6);local searchWidth=l.w-2*l.side-s(156)
    bb:paintBorder(l.side,y,searchWidth,l.search-s(14),s(1),BB.COLOR_BLACK,s(21))
    self:icon(bb,'abc_ic_search_api_material',l.side+s(6),y,s(34),l.search-s(14))
    self:text(bb,a.query~='' and a.query or '搜索',l.side+s(46),y+s(10),searchWidth-s(62),s(17))
    self:hit({x=l.side,y=y,w=searchWidth,h=l.search-s(14)},function()a:search()end)
    self:button(bb,require('readinknative/preferences').exitButtonLabel(),l.w-l.side-s(144),y,s(144),l.search-s(14),function()a:exit()end)
    if page.showHeader then
    if a.shelfEditing then
        local selected=require('readinknative/shelfmodel').selected(a)
        self:button(bb,'全选',l.side,l.search,s(76),s(48),function()a:shelfAll()end)
        self:text(bb,#selected==0 and'选择书籍'or'已选 '..#selected..' 本',l.side+s(80),l.search+s(16),l.w-2*l.side-s(160),s(19),true,1,nil,nil,nil,'center')
        self:button(bb,'取消',l.w-l.side-s(90),l.search,s(90),s(48),function()a:shelfSelect()end)
    else
    local title=require('readinknative/shelfmodel').title(a)
    self:text(bb,title,l.side,l.search+s(13),l.w-2*l.side-s(190),s(27),true)
    self:icon(bb,'icon_bookshelf_import',l.w-l.side-s(180),l.search,s(40),s(48),function()a:chooseFile()end)
    self:button(bb,'导入',l.w-l.side-s(142),l.search,s(56),s(48),function()a:chooseFile()end)
    self:icon(bb,'icon_bookshelf_select',l.w-l.side-s(76),l.search,s(28),s(48),function()a:shelfSelect()end)
    self:button(bb,'选择',l.w-l.side-s(48),l.search,s(48),s(48),function()a:shelfSelect()end)
    end
    end
    local screenBB=bb
    if bb.viewport then bb=bb:viewport(0,0,l.w,page.bottom)end
    for _,cell in ipairs(page.cells)do
        local book=books[cell.index]
        if book then
            local c=cell.cover
            local painted,coverBounds
            if book.isGroup then self:groupCover(bb,book,c)
            else painted,coverBounds=self:cover(bb,book,c)end
            coverBounds=coverBounds or c
            if not book.isGroup and not painted then
            bb:paintRect(c.x,c.y,c.w,c.h,BB.COLOR_LIGHT_GRAY)
            bb:paintRect(c.x,c.y,s(3),c.h,BB.COLOR_DARK_GRAY)
            bb:paintRect(c.x+s(10),c.y+s(12),c.w-s(20),s(2),BB.COLOR_BLACK)
            if c.y+s(30)+s(18)*1.45*3<=page.bottom then self:text(bb,book.title,c.x+s(12),c.y+s(30),c.w-s(24),s(18),true,3,BB.COLOR_LIGHT_GRAY)end
            if c.y+c.h-s(30)+s(12)*1.45<=page.bottom then self:text(bb,book.localFile and '本地' or '微信读书',c.x+s(12),c.y+c.h-s(30),c.w-s(24),s(12))end
            end
            if not book.isGroup and book.secret==1 then self:icon(bb,'icon_bookshelf_privacy',coverBounds.x,coverBounds.y+coverBounds.h-s(28),s(28),s(28),nil,nil,{w=28,h=28})end
            if cell.titleVisible then
            local t=cell.title
            local status=not book.isGroup and require('readinknative/offline').displayStatus(a,book)or 0
            local marked=status==1 or status==2 or status==3 or status==4 or status==5
            if marked then
                if status==2 then
                    self:downloadCircle(bb,require('readinknative/offline').progress(a,book).percent,t.x,t.y,s(16),s(20))
                else
                    local icon=status==1 and'icon_bookshelf_pre_download'or status==5 and'icon_bookshelf_error'or'icon_bookshelf_downloaded'
                    self:icon(bb,icon,t.x,t.y,s(16),s(20),nil,nil,{w=14,h=14})
                end
            end
            self:text(bb,book.title,t.x+(marked and s(20)or 0),t.y,t.w-(marked and s(20)or 0),l.shelfTitleSize,true)
            end
            if a.shelfEditing then local checked=book.isGroup and shelf.groupSelected(a,book)or not book.isGroup and(a.shelfSelection or {})[tostring(book.bookId)]
                self:icon(bb,checked and'icon_checkbox_big_checked'or'icon_checkbox_big',coverBounds.x+coverBounds.w-s(32),coverBounds.y+coverBounds.h-s(32),s(28),s(28),nil,nil,{w=28,h=28})
            end
            self:hit(cell.hit,function()if book.isGroup then if a.shelfEditing then shelf.toggleGroup(a,book)else shelf.enter(a,book)end elseif a.shelfEditing then a:toggleSelection('shelfSelection',book.bookId)else a:openBook(book)end end)
        end
    end
    if bb~=screenBB then bb:free();bb=screenBB end
    if #books==0 then
        self:text(bb,a.query~='' and '没有找到匹配的书籍' or '书架还是空的',l.side,l.top+l.search+s(105),l.w-2*l.side,s(23),true)
        self:text(bb,a.query~='' and '点击搜索栏修改关键词' or '在“我”中登录，或在设置中打开演示书。',l.side,l.top+l.search+s(153),l.w-2*l.side,s(16),false,2)
    end
    local y0=l.h-l.bottom;bb:paintRect(0,y0,l.w,l.bottom,BB.COLOR_WHITE);bb:paintRect(0,y0,l.w,1,BB.COLOR_BLACK)
    if a.shelfEditing then
        local O=require('readinknative/offline');local selected=require('readinknative/shelfmodel').selected(a)
        local selectedState=O.selectionState(a,selected)
        require('readinknative/homebar').draw(self,bb,nil,{page=a.shelfPage,pages=pages,turn=function(delta)a:listTurn(delta)end,
            actions={{icon=#selectedState.online==0 and'icon_toolbar_download_start'or selectedState.icon,action=function()O.shelfAction(a)end},
                {icon='icon_toolbar_bookshelf_remove',action=function()a:hideSelectedBooks()end},
                {icon='icon_toolbar_private',action=function()require('readinknative/shelfactions').privacy(a)end,metrics={w=26,h=27}}}})
        return
    end
    if a.shelfPage==pages and a.query==''then
        local public,secret,unknown=shelf.counts(a);local text
        if unknown>0 then text=unknown..' 本书籍的私密状态待同步'
        elseif secret==0 then text=public..'本公开阅读'
        elseif public==0 then text=secret..'本私密阅读'
        else text=public..'本公开阅读'..(l.w/s(1)<700 and'\n'or' · ')..secret..'本私密阅读'end
        self:text(bb,text,l.side,l.h-l.bottom-s(42),l.w-2*l.side,s(12),false,2,nil,nil,nil,'center')
        if unknown>0 then self:hit({x=l.side,y=l.h-l.bottom-s(42),w=l.w-2*l.side,h=s(40)},function()a:syncShelf()end)end
    end
    if a.shelfGroup then require('readinknative/homebar').draw(self,bb,nil,{page=a.shelfPage,pages=pages,back=function()shelf.back(a)end})
    else require('readinknative/collectionview').homeTabs(self,bb,'shelf',{page=a.shelfPage,pages=pages})end
end
function View:underlines(bb)
    local a,l=self.app,self.layout;local uid=a.chapter and tostring(a.chapter.chapterUid)or nil
    for _,row in ipairs(require('readinknative/annotations').list(a.state,a.book.bookId))do
        if row.chapterUid==uid and row.position.endXPointer then
            for _,box in ipairs(a.document:rangeBoxes(row.position))do
                -- CRengine coordinates are relative to our document viewport.
                local x=math.max(0,box.x);local y=box.y+box.h-l.s(1)
                local finish=math.min(l.body.w,box.x+box.w)
                if finish>x and y>=0 and y<l.body.h then
                    bb:paintRect(l.body.x+x,l.body.y+y,finish-x,math.max(1,l.s(1)),BB.COLOR_BLACK)
                    local top=math.max(0,box.y);local bottom=math.min(l.body.h,box.y+box.h)
                    if bottom>top then self:hit({x=l.body.x+x,y=l.body.y+top,w=finish-x,h=bottom-top},function()
                        if row.kind=='highlight'and require('readinknative/social').openAnnotation(a,row)then return end
                        require('readinknative/readingmenu').annotation(a,row)
                    end,true)end
                end
            end
        end
    end
end
function View:selectionPanel(bb)
    local a,l=self.app,self.layout;local s=l.s;local T=require('readinknative/textselection');local selected=T.current(a)
    if not selected or selected.dragging then return end
    local boxes=a.document:rangeBoxes(T.position(selected.range));if #boxes==0 then return end
    local first,last=boxes[1],boxes[#boxes];local width=math.min(l.w-2*l.side,s(240));local height=s(80)
    local x=math.max(l.side,math.min(l.w-l.side-width,l.body.x+first.x+first.w/2-width/2))
    local y=l.body.y+first.y-height-s(8)
    if y<l.body.y then y=l.body.y+last.y+last.h+s(8)end
    y=math.max(l.body.y,math.min(l.h-l.bottom-height,y))
    bb:paintRect(x,y,width,height,BB.COLOR_WHITE);bb:paintBorder(x,y,width,height,s(1),BB.COLOR_BLACK)
    self:hit({x=x,y=y,w=width,h=height},function()end)
    local actions={{'划线','icon_reading_menu_underline',T.highlight},{'查词','abc_ic_search_api_material',T.lookup},
        {'笔记','icon_style_add_note',T.note},{'复制','icon_reader_selection_menu_copy',T.copy}}
    for i,item in ipairs(actions)do
        local left=x+(i-1)*width/4
        self:icon(bb,item[2],left,y+s(6),width/4,s(40),nil,nil,{w=24,h=24})
        self:button(bb,item[1],left,y+s(46),width/4,s(28),function()item[3](a)end)
        self:hit({x=left,y=y,w=width/4,h=height},function()item[3](a)end)
    end
end
function View:reader(bb)
    local a=self.app;local l=self.layout;local s=l.s;local d=a.document
    if not d then return end
    d:paint(bb,l.body.x,l.body.y);require('readinknative/socialreader').paint(self,bb);self:underlines(bb)
    local deviceWidth=require('readinknative/readerstatus').paint(self,bb)
    local badge=require('readinknative/offline').readerBadge(self,bb)
    self:icon(bb,'icon_back_circled',l.side,s(4),s(18),s(28),function()if not require('readinknative/readerlinks').back(a)and not require('readinknative/booksearch').back(a)then a:leaveReading()end end,nil,{w=14,h=14})
    self:text(bb,a.chapter and a.chapter.title or a.book.title,l.side+s(20),s(7),l.w-2*l.side-s(20)-deviceWidth-(badge and s(100)or 0),s(12))
    local showTime=require('readinknative/preferences').normalize(a.state.preferences).showTime
    self:text(bb,require('readinknative/pagination').label(a)..(a.book.articlePreview and' · 试读'or a.preview and ' · 试读（点击核对权限）' or '')..(a.positionNotice and (' · '..a.positionNotice)or''),l.side,l.h-s(26),l.w-2*l.side-(showTime and s(64)or 0),s(12),false,1,nil,nil,nil,'right')
    if a.preview and a.chapter then self:hit({x=l.side,y=l.h-s(32),w=l.w-2*l.side-(showTime and s(64)or 0),h=s(32)},function()a.refreshContent=true;a:selectChapter(a.chapter,a.chapterIndex)end)end
    if showTime then self:text(bb,os.date('%H:%M'),l.w-l.side-s(56),l.h-s(26),s(56),s(12))end
    if require('readinknative/readerlinks').currentNote(a)then require('readinknative/readerlinks').paint(self,bb);return end
    if require('readinknative/textselection').current(a)then self:selectionPanel(bb);return end
    if not a.toolbar then return end
    -- The visible toolbar owns input. Underline/header hit targets painted
    -- below it must not intercept a tap intended to dismiss it and turn.
    self.hits={}
    bb:paintRect(0,0,l.w,l.top,BB.COLOR_WHITE)
    bb:paintRect(0,l.top-1,l.w,1,BB.COLOR_LIGHT_GRAY)
    require('readinknative/readertoolbar').paint(self,bb)
    if a.panel=='font'then self:fontPanel(bb)elseif a.panel=='faces'then self:fontListPanel(bb)elseif a.panel=='progress'then self:progressPanel(bb)elseif a.panel=='social'then require('readinknative/socialtop').paint(self,bb)end
    local y=l.h-l.bottom
    bb:paintRect(0,y,l.w,l.bottom,BB.COLOR_WHITE);bb:paintRect(0,y,l.w,1,BB.COLOR_LIGHT_GRAY)
    local back=s(76);local start=back+s(21);local width=(l.w-start)/4
    self:icon(bb,'icon_toolbar_back',0,y,back,l.bottom,function()a:leaveReading()end)
    bb:paintRect(back+s(10),y+(l.bottom-s(24))/2,s(1),s(24),BB.COLOR_LIGHT_GRAY)
    local actions={{'icon_reader_footer_chapter',function()a.panel=nil;a:showCatalog()end},
        {'icon_toolbar_note',function()a.panel=nil;a:notes()end},
        {a.panel=='progress' and 'icon_reader_footer_progress_selected' or 'icon_reader_footer_progress',function()a:progress()end},
        {(a.panel=='font' or a.panel=='faces' or a.nativeFormatPanel) and 'icon_reader_footer_font_selected' or 'icon_reader_footer_font',function()a:showFormatPanel()end,function()a:chooseFormatPanel()end}}
    for i,item in ipairs(actions)do self:icon(bb,item[1],start+(i-1)*width,y,width,l.bottom,item[2],nil,nil,item[3])end
end
function View:paintTo(bb,x,y,dirty)
    local AP=require('readinknative/avatarpaint')
    if AP.try(self,bb,dirty)then return end
    AP.begin(self,bb)
    local target=bb
    if self.app.mode=='account'or self.app.accountRefreshPending or self.accountRefreshFrame then
        bb=require('readinknative/accountrefresh').beforePaint(self,bb)or bb
    end
    bb=require('readinknative/socialpaint').begin(self,bb)
    if require('readinknative/readersliders').paint(self,bb)then return end
    local clock=require('ui/time');local started=clock.monotonic()
    local reused=bb~=target and self.app.mode=='account'and require('readinknative/accountrefresh').reuse(self)
    if not reused then
        self:clearObjects();self.hits={};self.sliderHits={}
        bb:paintRect(0,0,self.dimen.w,self.dimen.h,BB.COLOR_WHITE)
        local mode=self.app.mode
        if mode=='store'then require('readinknative/storeview').draw(self,bb)
        elseif mode=='articles'then require('readinknative/articleview').draw(self,bb)
        elseif mode=='social'then require('readinknative/socialview').draw(self,bb)
        elseif mode=='reader'then self:reader(bb)
        elseif mode=='catalog'then require('readinknative/collectionview').catalog(self,bb)
        elseif mode=='notes'then require('readinknative/collectionview').notes(self,bb)
        elseif mode=='account'then require('readinknative/collectionview').account(self,bb)
        elseif mode=='noteDetail' or mode=='cache' or mode=='sort'then require('readinknative/actionview')[mode](self,bb)
        elseif mode=='accountDetails'then require('readinknative/collectionview').accountDetails(self,bb)
        elseif mode=='settings'then require('readinknative/collectionview').settings(self,bb)
        elseif mode=='search'then require('readinknative/collectionview').search(self,bb)
        else self:shelf(bb)end
        require('readinknative/offline').paintNotice(self,bb)
    end
    local mode=self.app.mode
    if bb~=target then
        if mode=='social'or mode=='store'then require('readinknative/socialpaint').commit(self,bb,target)
        else require('readinknative/accountrefresh').commit(self,bb,target)end
        bb=target
    end
    self.presentedInput={mode=mode,state=self.app.state,book=self.app.book,document=self.app.document,panel=self.app.panel,toolbar=self.app.toolbar}
    local doc=mode=='reader'and self.app.document
    local key=doc and table.concat({tostring(doc),tostring(doc.format),doc.path,doc.frameKey and doc:frameKey()or doc:page(),doc.w,doc.h},':')or mode
    local coverage=doc and doc.doc._drawn_images_surface_ratio or 0
    require('readinknative/refresh').painted(self,mode,key,coverage,G_reader_settings:nilOrTrue('refresh_on_pages_with_images'),self.app.toolbar or self.app.panel or self.app.textSelection or self.app.footnote,bb)
    self.readerPaintSerial=(self.readerPaintSerial or 0)+1
    local elapsed=clock.to_ms(clock.monotonic()-started)
    if elapsed>=80 then require('logger').info('ReadInk view paint ms/mode:',math.floor(elapsed),mode)end
    if self.turnStarted then
        local total=clock.to_ms(clock.monotonic()-self.turnStarted);self.turnStarted=nil
        if total>=150 then require('logger').info('ReadInk page input-to-paint ms:',math.floor(total))end
    end
    AP.finish(self,target)
    if mode=='reader'then require('readinknative/pagepreload').request(self.app)end
end
local gestureEnds={tap=true,double_tap=true,swipe=true,multiswipe=true,pan_release=true,
    hold_release=true,two_finger_tap=true,two_finger_swipe=true,two_finger_pan_release=true,
    two_finger_hold_release=true,two_finger_hold_pan_release=true,pinch=true,spread=true,rotate=true}
local function multiGesture(g)
    local kind=g.ges or''
    return kind:sub(1,11)=='two_finger_'or kind=='pinch'or kind=='spread'or kind=='rotate'
        or kind=='inward_pan'or kind=='outward_pan'
end
local function inputOwner(a)
    return{state=a.state,book=a.book,document=a.document}
end
local function sameInputOwner(a,o)
    return not o or o.state==a.state and o.book==a.book and o.document==a.document
end
function View:onHandledAsSwipe()
    -- KOReader emits this before Dispatcher executes the action. A gesture
    -- recognized after an ordinary pan must act on the original viewport.
    require('readinknative/readerscroll').abortNative(self)
    self.nativeGestureReserved=nil;self.nativeGestureConsumed=true
    return true
end
function View:onGesture(g)
    if not g then return true end
    local nativeMode=self:syncGestureSettings()
    self.nativeGesturesActive=nativeMode or nil
    local function complete(result)
        if gestureEnds[g.ges]then self.nativeGestureTouch=nil;self.nativeGestureMulti=nil end
        return result
    end
    local function fallback()
        -- Resolve this dynamically: KOReader replaces this method when touch
        -- input is disabled, so retaining an earlier function would bypass it.
        return complete(InputContainer.onGesture(self,g))
    end
    -- A toolbar hold owns this entire contact, including a release delivered
    -- after its chooser closes. A fresh raw touch restores normal input.
    if self.formatPanelHoldConsumed and g.ges~='touch'then return complete(true)end
    if not nativeMode then
        self.nativeGestureTouch=nil;self.nativeGestureMulti=nil
        self.nativeGestureReserved=nil;self.nativeGestureConsumed=nil
        return fallback()
    end
    local a=self.app
    if a.closed or a.suspended or a.chapterLoading then return complete(true)end
    if UI.getTopmostVisibleWidget then
        local top=UI:getTopmostVisibleWidget()
        if top and top~=self then return complete(true)end
    end
    if a.activeInput or a.readerOverlay or a.quickMenu or a.nativeFormatPanel then return complete(true)end
    local N=require('readinknative/nativegestures')
    if N.isTouchDisabled(a)then
        require('readinknative/readerscroll').abortNative(self)
        self.nativeGestureTouch=nil
        -- The private native registry filters for "Always active" bindings.
        -- Never run ReadInk's fallback while either native context is locked.
        N.dispatch(a,g);return complete(true)
    end
    if g.ges=='touch'then
        if self.nativeGestureTouch and sameInputOwner(a,self.nativeGestureTouch)then
            -- Raw touch has no contact/slot identifier. This may be a second
            -- finger, or the second tap while the first tap's timer is pending.
            -- Only an explicit multi-touch event may claim the whole sequence.
            require('readinknative/readerscroll').abortNative(self)
            if self.sliderDrag then self:onSliderCancel();return true end
        end
        self.nativeGestureTouch=inputOwner(a)
        self.nativeGestureReserved=nil;self.nativeGestureConsumed=nil;self.nativeGestureMulti=nil
        return fallback()
    end
    if not sameInputOwner(a,self.nativeGestureTouch)then
        require('readinknative/readerscroll').abortNative(self)
        self.nativeGestureConsumed=true;return complete(true)
    end
    if self.formatGestureConsumed or self.scrollGestureConsumed or self.sliderConsumed then return complete(true)end
    if self.sliderDrag then
        if multiGesture(g)then self:onSliderCancel();return complete(true)end
        return fallback()
    end
    -- These controls are part of ReadInk's view, rather than separate widgets.
    -- Their local callbacks, selection handles and footnote paging own input.
    if a.toolbar or a.panel or a.textSelection or a.footnote then return fallback()end
    if self.nativeGestureConsumed then
        -- Rotate can be a stream of native events, unlike a released swipe.
        if g.ges=='rotate'then N.dispatch(a,g)end
        return complete(true)
    end
    if self.nativeGestureMulti and not multiGesture(g)then return complete(true)end
    local multiple=multiGesture(g)
    if multiple then
        self.nativeGestureMulti=true
        require('readinknative/readerscroll').abortNative(self)
    end
    -- Native corner actions must not steal annotation links or local buttons.
    if g.ges=='tap'or g.ges=='hold'then
        local p=g.pos
        for _,hit in ipairs(self.hits or{})do
            if p and(g.ges=='tap'or not hit.hold_passthrough)and Layout.contains(hit.rect,p.x,p.y)then return fallback()end
        end
        if g.ges=='tap'and N.claims(a,g)then
            local point=self:textPoint(g)
            if point and require('readinknative/readerlinks').tap(a,point)then
                require('readinknative/readerscroll').cancel(self,false)
                return complete(true)
            end
        end
    end
    if g.ges=='pan'and(self.nativeGestureReserved or N.claims(a,g))then
        -- Match the configured swipe's original start zone and direction before
        -- any speculative text scrolling or ReadInk edge panel can occur.
        require('readinknative/readerscroll').abortNative(self)
        self.nativeGestureReserved=true;return true
    end
    if N.dispatch(a,g)then
        self:onHandledAsSwipe();return complete(true)
    end
    if self.nativeGestureReserved and g.ges=='pan_release'then
        -- A slow pan did not become a native swipe. Do not synthesize an action
        -- (nor suddenly scroll the whole distance after the finger is lifted).
        self.nativeGestureReserved=nil;self.nativeGestureConsumed=true;return complete(true)
    end
    if multiple then return complete(true)end
    if g.ges=='multiswipe'and self.scrollContact then
        -- An unbound multiswipe is also a contact release. Commit only the
        -- position already reached by its pans, rather than replaying the
        -- straight-line distance of a gesture that changed direction.
        if require('readinknative/readerscroll').finish(self,{})then return complete(true)end
    end
    if gestureEnds[g.ges]then self.nativeGestureReserved=nil end
    return fallback()
end
function View:onRawTouch(_,gesture)
    self.formatGestureConsumed=nil;self.scrollGestureConsumed=nil;self.formatPanelHoldConsumed=nil
    require('readinknative/pagepreload').stop(self.app)
    if require('readinknative/readersliders').begin(self,gesture)then return true end
    return require('readinknative/readerscroll').begin(self,gesture)
end
function View:onSliderPan(_,gesture)
    if require('readinknative/quickcontrols').openGesture(self,gesture,true)then return true end
    if require('readinknative/readersliders').move(self,gesture)then return true end
    return require('readinknative/readerscroll').move(self,gesture)
end
function View:onSliderHoldDrag(_,gesture)return require('readinknative/readersliders').move(self,gesture)end
function View:onSliderRelease(_,gesture)
    if require('readinknative/readersliders').finish(self,gesture)then return true end
    return require('readinknative/readerscroll').finish(self,gesture)
end
function View:onSliderCancel()
    if require('readinknative/readersliders').cancel(self)then self:refresh();return true end
    if require('readinknative/readerscroll').cancel(self,true)then self.scrollGestureConsumed=true;self:refresh();return true end
end
-- Bind actions to the scene actually painted. A state transition invalidates
-- the old hit map until its next paint, without any timed input lock/debounce.
function View:inputCurrent()
    local a,p=self.app,self.presentedInput
    if a.closed or a.suspended then return false end
    if UI.getTopmostVisibleWidget then local top=UI:getTopmostVisibleWidget();if top and top~=self then return false end end
    return not p or(p.mode==a.mode and p.state==a.state and p.book==a.book and p.document==a.document and p.panel==a.panel
        and(a.mode~='reader'or p.toolbar==a.toolbar))
end
-- Keep the center menu zone narrow; both side zones dismiss any reader sheet
-- and turn in the same gesture, respecting the left-side-next preference.
function View:readerTap(x)
    local a=self.app;local menu=a.toolbar or a.panel
    if x<self.dimen.w*0.35 or x>self.dimen.w*0.65 then
        a.toolbar=false;a.panel=nil
        local delta=x<self.dimen.w*0.35 and(require('readinknative/preferences').normalize(a.state.preferences).tapLeftNext and 1 or -1)or 1
        a:turn(delta)
        -- Also remove the toolbar at a book boundary or while a cross-chapter
        -- turn is pending. Queue only; the final page paints as one frame.
        if menu then self:refresh()end
    else
        a.panel=nil;a.toolbar=not menu;self:refresh()
    end
    return true
end
function View:onTouch(_,gesture)
    if not self:inputCurrent()then self:refresh();return true end
    if require('readinknative/readersliders').finish(self,gesture)then return true end
    if self.formatGestureConsumed or self.scrollGestureConsumed or self.formatPanelHoldConsumed then return true end
    if self.sliderConsumed then self.sliderConsumed=nil;return true end
    require('readinknative/readerscroll').cancel(self,false)
    require('readinknative/offline').interact(self.app)
    require('readinknative/socialreader').input(self.app)
    local x,y=gesture.pos.x,gesture.pos.y
    for i=#self.hits,1,-1 do local hit=self.hits[i]
        if not (self.app.textSelection and hit.hold_passthrough) and Layout.contains(hit.rect,x,y)then hit.action(x,y);return true end
    end
    if self.app.mode=='reader'then
        if self.app.textSelection then self.app:clearTextSelection();self:refresh();return true end
        if self.app.toolbar or self.app.panel then return self:readerTap(x)end
        local point=self:textPoint(gesture)
        if point and require('readinknative/readerlinks').tap(self.app,point)then return true end
        return self:readerTap(x)
    end
    return true
end
function View:textPoint(gesture)
    local l=self.layout;local p=gesture and gesture.pos
    if not p or not Layout.contains(l.body,p.x,p.y)then return nil end
    return {x=p.x-l.body.x,y=p.y-l.body.y}
end
function View:onTextHold(_,gesture)
    if self.formatPanelHoldConsumed then return true end
    if require('readinknative/readersliders').move(self,gesture)then return true end
    if require('readinknative/readerscroll').cancel(self,true)then self.scrollGestureConsumed=true;return true end
    require('readinknative/offline').interact(self.app)
    if require('readinknative/readerlinks').currentNote(self.app)then return true end
    if self.app.mode~='reader'then return false end
    local p=gesture and gesture.pos
    if not p then return false end
    for i=#self.hits,1,-1 do local hit=self.hits[i]
        if not hit.hold_passthrough and Layout.contains(hit.rect,p.x,p.y)then
            if hit.hold_action and not self.app.textSelection then
                self.formatPanelHoldConsumed=true;hit.hold_action(p.x,p.y)
            end
            return true
        end
    end
    if self.app.panel then return false end
    local point=self:textPoint(gesture)
    if point then return require('readinknative/textselection').begin(self.app,point)end
    return true
end
function View:onTextDrag(_,gesture)
    if self.formatPanelHoldConsumed then return true end
    if require('readinknative/readersliders').move(self,gesture)then return true end
    local point=self:textPoint(gesture)
    if point then require('readinknative/textselection').move(self.app,point)end
    return self.app.textSelection~=nil
end
function View:onTextRelease(_,gesture)
    if self.formatPanelHoldConsumed then return true end
    if require('readinknative/readersliders').finish(self,gesture)then return true end
    return require('readinknative/textselection').finish(self.app)
end
function View:formatPanelSwipe(g)
    local a=self.app
    if not g or g.direction~='north'or self.sliderDrag or not a or a.closed or a.suspended
        or a.mode~='reader'or not a.document or not a.book or a.chapterLoading
        or a.panel or a.textSelection or a.activeInput or a.readerOverlay or a.footnote
        or a.quickMenu or a.nativeFormatPanel then return false end
    if UI.getTopmostVisibleWidget then
        local top=UI:getTopmostVisibleWidget()
        if top and top~=self then return false end
    end
    local p=g.start_pos or g.pos;local s=self.layout.s
    local edge=math.max(s(22),math.floor(self.dimen.h*0.15))
    if not p or type(p.x)~='number'or type(p.y)~='number'or p.x~=p.x or p.y~=p.y
        or p.x<0 or p.x>self.dimen.w or p.y<self.dimen.h-edge or p.y>self.dimen.h then return false end
    local finish=g.end_pos
    local distance=finish and type(finish.y)=='number'and p.y-finish.y or g.distance
    if type(distance)~='number'or distance~=distance or distance==math.huge or distance<s(40)then return false end
    -- Open only after the swipe completes. Consume any trailing tap from this
    -- contact; the next genuine touch clears the latch in onRawTouch().
    self.formatGestureConsumed=true
    a:showFormatPanel();return true
end
function View:onSwipe(_,g)
    if require('readinknative/readersliders').finish(self,g)then return true end
    if self.formatGestureConsumed or self.scrollGestureConsumed then return true end
    if self.sliderConsumed then self.sliderConsumed=nil;return true end
    if require('readinknative/quickcontrols').openGesture(self,g)then return true end
    require('readinknative/offline').interact(self.app)
    local note=require('readinknative/readerlinks').currentNote(self.app)
    if note then
        if g.direction=='north'then note.page=math.min(note.pages or 1,note.page+1)
        elseif g.direction=='south'then note.page=math.max(1,note.page-1)end
        self:refresh();return true
    end
    if self.app.panel=='faces'then
        if g.direction=='north'or g.direction=='west'then require('readinknative/fontpicker').turn(self.app,1)
        elseif g.direction=='south'or g.direction=='east'then require('readinknative/fontpicker').turn(self.app,-1)end
        return true
    end
    if self.app.panel then return true end
    if self.app.textSelection then self.app:clearTextSelection();self:refresh();return true end
    if self:formatPanelSwipe(g)then return true end
    if require('readinknative/readerscroll').swipe(self,g)then return true end
    if self.app.mode=='shelf'then
        if g.direction=='north'then self.app:turn(1)
        elseif g.direction=='south'then self.app:turn(-1)end
        return true
    end
    local route=self.app.mode=='store'and self.app.store and self.app.store.route
    if route and route.kind=='detail'and route.detailTab~='intro'and g.direction=='west'then
        require('readinknative/store').read(self.app);return true
    end
    if g.direction=='west' or (g.direction=='north' and self.app.mode~='reader')then self.app:turn(1)
    elseif g.direction=='east' or (g.direction=='south' and self.app.mode~='reader')then self.app:turn(-1)end
    return true
end
function View:onClose()return self:onAppBack()end
function View:onAppBack()if not self:inputCurrent()then self:refresh();return true end;require('readinknative/readerscroll').cancel(self,true);require('readinknative/offline').interact(self.app);self.app:back();return true end
function View:onNext()require('readinknative/readerscroll').cancel(self,true);if self.app.panel=='faces'then require('readinknative/fontpicker').turn(self.app,1);return true end;if require('readinknative/readersliders').cancel(self)then self:refresh();return true end;require('readinknative/offline').interact(self.app);self.app:turn(1);return true end
function View:onPrevious()require('readinknative/readerscroll').cancel(self,true);if self.app.panel=='faces'then require('readinknative/fontpicker').turn(self.app,-1);return true end;if require('readinknative/readersliders').cancel(self)then self:refresh();return true end;require('readinknative/offline').interact(self.app);self.app:turn(-1);return true end
function View:onSuspend()require('readinknative/readerscroll').cancel(self,true);self.app:suspend()end
function View:onResume()self.app:resume()end
function View:onOutOfScreenSaver()require('readinknative/wallpaper').out(self.app)end
function View:relayoutShelf()
    self.app.coverJobs:cancel();self:clearObjects()
    for _,obj in pairs(self.coverObjects)do obj:free()end
    self.coverObjects={};self.coverOrder={};self.coverBytes=0;self.badCovers={};self.hits={}
    self.layout=Layout.build(self.dimen.w,self.dimen.h,self.fontScale,require('readinknative/preferences').shelfDensity())
    -- Density changes only the shelf. Keep the CRengine document, viewport,
    -- reading position and pagination workers intact.
end
function View:onSetDimensions()
    require('readinknative/avatarqueue').stop(self.app)
    require('readinknative/avatarcache').free(self)
    require('readinknative/accountrefresh').free(self);self.presentedInput=nil
    if self.app.closeFormatPanel then self.app:closeFormatPanel()end
    require('readinknative/readerscroll').cancel(self,true)
    self.formatGestureConsumed=nil;self.scrollGestureConsumed=nil;self.formatPanelHoldConsumed=nil
    self.nativeGestureTouch=nil;self.nativeGestureMulti=nil;self.nativeGestureReserved=nil;self.nativeGestureConsumed=nil
    require('readinknative/readersliders').cancel(self)
    self.app:clearTextSelection()
    self.app.coverJobs:cancel();self:clearObjects();self:clearReaderText()
    for _,obj in pairs(self.coverObjects)do obj:free()end
    self.coverObjects={};self.coverOrder={};self.coverBytes=0;self.badCovers={}
    local screen=require('device').screen
    self.dimen=Geom:new{x=0,y=0,w=screen:getWidth(),h=screen:getHeight()}
    self.fontScale=screen:scaleBySize(100)/100
    self.layout=Layout.build(self.dimen.w,self.dimen.h,self.fontScale,require('readinknative/preferences').shelfDensity())
    for _,ranges in pairs(self.ges_events)do for _,range in ipairs(ranges)do if type(range.range)~='function'then range.range=self.dimen end end end
    if self.app.nativeGestures then require('readinknative/nativegestures').resize(self.app)end
    self:syncGestureSettings()
    if self.app.document then
        self.app.document:resize(self.layout.body.w,self.layout.body.h);self.app:savePosition()
        if not self.app.book.localFile then require('readinknative/pagination').request(self.app)end
    end
    self:refresh();return true
end
function View:onCloseWidget()
    require('readinknative/avatarqueue').stop(self.app,true)
    require('readinknative/avatarcache').free(self)
    require('readinknative/socialpaint').free(self)
    require('readinknative/accountrefresh').free(self);self.presentedInput=nil
    self:clearReaderText()
    require('readinknative/readersliders').cancel(self)
    for _,item in pairs(self.iconObjects)do item.object:free()end;self.iconObjects={};self.iconOrder={};self.iconBytes=0
    self:clearObjects();for _,obj in pairs(self.coverObjects)do obj:free()end;self.coverObjects={}
end
return View
