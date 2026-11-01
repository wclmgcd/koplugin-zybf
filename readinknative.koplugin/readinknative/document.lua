-- New adapter over KOReader's documented document provider. It does not use
-- ReaderUI, any WeReader reader/window, or the Android native renderer.
local D={};D.__index=D
-- Prepared, small chapters have explicitly closed their previous engine data.
-- Avoid two stop-the-world Lua sweeps at every boundary, while retaining the
-- exact provider/registry refcount contract and conservative memory fallbacks.
function D.provider(path,prepared)
    local registry=require('document/documentregistry');local provider=require('document/credocument')
    local bytes=prepared and require('libs/libkoreader-lfs').attributes(path,'size')
    local heap=collectgarbage('count');local memory=prepared and require('util').calcFreeMem()
    local fast=prepared and bytes and bytes<=2*1024*1024 and not next(registry.registry)
    if fast then
        -- Explicitly closed chapter data does not need two complete UI-thread
        -- sweeps. In particular, low free RAM must not select a *more*
        -- blocking collector while a shelf sync still inherits the old heap.
        local clock=require('socket');local started=clock.gettime()
        require('logger').info('ReadInk provider incremental begin freeKB/heapKB:',memory and math.floor(memory/1024)or -1,math.floor(heap))
        collectgarbage('step',16)
        require('logger').info('ReadInk provider incremental end ms:',math.floor((clock.gettime()-started)*1000))
        started=clock.gettime();require('logger').info('ReadInk provider construct begin')
        local ok,doc=pcall(provider.new,provider,{file=path})
        require('logger').info('ReadInk provider construct end ms/ok:',math.floor((clock.gettime()-started)*1000),ok)
        if ok then
            registry.registry[path]={doc=doc,refs=1}
            require('logger').info('ReadInk prepared chapter provider reused GC budget')
            return doc
        end
        require('logger').warn('ReadInk prepared chapter provider failed')
        return nil
    end
    if prepared then require('logger').info('ReadInk prepared provider GC freeKB/heapKB/bytes:',memory and math.floor(memory/1024)or -1,math.floor(heap),bytes or -1)end
    return registry:openDocument(path,provider)
end
function D.open(path,w,h,font,position,format,context,article)
    local clock=require('ui/time');local started=clock.monotonic();local stages={}
    local checkpoint=started
    local function stage(name)local now=clock.monotonic();stages[#stages+1]=name..'='..math.floor(clock.to_ms(now-checkpoint));checkpoint=now end
    require('logger').info('ReadInk document opening:',context or 'reader')
    local providerPath=path
    local isolated,value=pcall(require('readinknative/readerfile').prepare,path)
    if isolated then providerPath=value else require('logger').warn('ReadInk reader file staging failed')end
    stage('readerfile')
    local doc=assert(D.provider(providerPath,context=='prepared-reader'or context=='single-reader'),'DOCUMENT_OPEN_FAILED')
    stage('registry')
    local self=setmetatable({doc=doc,path=path,providerPath=providerPath,w=w,h=h,font=font,article=article},D)
    local ok,err=pcall(function()
        doc:setupDefaultView()
        doc:setViewDimen{w=w,h=h}
        stage('defaults')
        self:applyOptions(require('readinknative/format').normalize(format,font))
        stage('options')
        local loadStarted=clock.monotonic();local streamStarted;local owned=true
        for _,entry in pairs(require('document/documentregistry').registry)do
            if entry.doc and entry.doc.provider=='crengine'and(entry.doc~=doc or(entry.refs or 1)>1)then owned=false end
        end
        local callback=owned and pcall(doc.setCallback,doc,function(event)if event=='OnLoadFileStart'and not streamStarted then streamStarted=clock.monotonic()end end)
        local loaded,value=pcall(doc.loadDocument,doc)
        if callback then pcall(doc.setCallback,doc,nil)end
        assert(loaded and value,'DOCUMENT_LOAD_FAILED');stage('load')
        if streamStarted then self.loadDirectoryMs=math.floor(clock.to_ms(streamStarted-loadStarted));self.loadContentMs=math.floor(clock.to_ms(clock.monotonic()-streamStarted))end
        self.cacheBefore=doc:hasCacheFile();self.staleBefore=doc:isCacheFileStale()
        doc:render();stage('render');self.staleAfter=doc:isCacheFileStale()
        if position then self:restorePosition(position)end
        self.toc=doc:getToc() or {}
        stage('position')
    end)
    if not ok then doc:close();self.doc=nil;error(err,0)end
    local elapsed=clock.to_ms(clock.monotonic()-started)
    if elapsed>=150 then require('logger').info('ReadInk document open/render ms/pages:',math.floor(elapsed),self:count())end
    if elapsed>=150 then require('logger').info('ReadInk document stages ms:',table.concat(stages,' '))end
    if elapsed>=150 and self.loadDirectoryMs then require('logger').info('ReadInk load before-stream/content ms:',self.loadDirectoryMs,self.loadContentMs)end
    if elapsed>=150 then require('logger').info('ReadInk cache restore flags:',context or'reader',self.cacheBefore,self.staleBefore,self.staleAfter)end
    return self
end
function D:reloadImages()
    local position=self:position();local path,w,h,font,format=self.path,self.w,self.h,self.font,self.format
    self:close()
    self.window=nil;self.readerCacheSpec=nil
    local fresh=D.open(path,w,h,font,position,format,'single-reader',self.article)
    for k,v in pairs(fresh)do self[k]=v end
end
function D:standalone(w,h,format)
    local position=self:position();local path,article=self.path,self.article
    self:close();self.window=nil;self.readerCacheSpec=nil
    local fresh=D.open(path,w,h,format.size,position,format,'single-reader',article)
    for k,v in pairs(fresh)do self[k]=v end
end
function D:page()return self.doc:getCurrentPage()end
function D:count()return math.max(1,self.doc:getPageCount())end
function D:isScroll()return self.format and self.format.view_mode==1 or false end
function D:scrollPos()return self.doc:getCurrentPos()end
function D:scrollMax()
    -- The engine's view is the body rectangle, with the plugin's header and
    -- footer already excluded. Match ReaderRolling's last-line boundary.
    return math.max(0,(self.doc.info and self.doc.info.doc_height or 0)-self.h)
end
function D:scrollTo(position)
    if not self:isScroll()or type(position)~='number'or position~=position
        or position==math.huge or position==-math.huge then return false,0 end
    local old=self:scrollPos();local maximum=self:scrollMax()
    local target=math.max(0,math.min(maximum,math.floor(position+0.5)))
    if target~=old then self.doc:gotoPos(target)end
    local current=self:scrollPos()
    local edge=current<=0 and -1 or current>=maximum and 1 or nil
    return current~=old,current-old,edge
end
function D:scrollBy(pixels)
    if not self:isScroll()or type(pixels)~='number'or pixels~=pixels or pixels==math.huge or pixels==-math.huge then return false,0 end
    return self:scrollTo(self:scrollPos()+pixels)
end
function D:turn(delta)
    if self:isScroll()then return self:scrollBy(delta*self.h)end
    local page=self:page()+delta
    if page<1 or page>self:count()then return false end
    self.doc:gotoPage(page);return true
end
function D:gotoPointer(pointer)
    if self.doc:isXPointerInDocument(pointer)then
        if self:isScroll()then self:scrollTo(self.doc:getPosFromXPointer(pointer))
        else self:jump(self.doc:getPageFromXPointer(pointer))end
        return true
    end
    return false
end
function D:jump(page)
    self.doc:gotoPage(math.min(self:count(),math.max(1,math.floor(page))))
    -- Page links and the progress slider still address native page numbers;
    -- clamp the resulting pixel position so a short final page is not blank.
    if self:isScroll()then self:scrollTo(self:scrollPos())end
end
function D:edge(which)
    if self:isScroll()then return self:scrollTo(which=='end'and self:scrollMax()or 0)end
    return self:jump(which=='end'and self:count()or 1)
end
function D:scrollLayout()
    return table.concat({require('readinknative/format').signature(self.format),self.w,self.h},'|')
end
function D:position()
    local value={xpointer=self.doc:getXPointer(),page=self:page(),pages=self:count(),updated=os.time()}
    if self:isScroll()then
        value.scroll_pos=self:scrollPos();value.scroll_layout=self:scrollLayout()
        if type(value.xpointer)=='string'and self.doc:isXPointerInDocument(value.xpointer)then
            value.scroll_anchor_y=self.doc:getPosFromXPointer(value.xpointer)
        end
    end
    return value
end
function D:restorePosition(position)
    if type(position)~='table'or type(position.xpointer)~='string'or not self:gotoPointer(position.xpointer)then return false end
    -- An XPointer may resolve to a line/word above or below the exact scroll
    -- offset. Preserve the pixels only when both layout and anchor geometry
    -- still match; a new font, viewport or revised source uses the anchor.
    if self:isScroll()and position.scroll_layout==self:scrollLayout()
        and type(position.scroll_anchor_y)=='number'
        and self.doc:getPosFromXPointer(position.xpointer)==position.scroll_anchor_y then
        self:scrollTo(position.scroll_pos)
    end
    return true
end
function D:applyOptions(options)
    local F=require('readinknative/format')
    local f=F.resolveEngineDefaults(self.doc,F.normalize(options,self.font))
    local face,err=require('readinknative/readerfonts').ensure(self,f.face)
    if err then error(err,0)end
    if f.face and face~=f.face then error('FONT_LOAD_FAILED',0)end
    local screen=require('device').screen
    self:clearPageImages()
    self.doc:setViewMode(f.view_mode==1 and'scroll'or'page')
    self.doc:setStatusLineProp(f.status_line)
    self.doc:setFontFace(f.face or self.doc.default_font)
    self.doc:setFontSize(screen:scaleBySize(f.size))
    self.doc:setFontBaseWeight(f.weight)
    self.doc:setFontHinting(f.font_hinting);self.doc:setFontKerning(f.font_kerning)
    self.doc:setWordSpacing(f.word_spacing);self.doc:setWordExpansion(f.word_expansion)
    self.doc:setCJKWidthScaling(f.cjk_width_scaling);self.doc:setInterlineSpacePercent(f.line)
    self.doc:setGammaIndex(f.font_gamma)
    -- Keep ReadInk's existing UA stylesheet and explicit indentation tweak.
    -- Embedded CSS/fonts are independent native switches, applied to the book.
    local css=self.article and require('readinknative/articlecontent').CSS or(f.indent and 'p { text-indent: 2em !important; }'or'p { text-indent: 0 !important; }')
    self.doc:setStyleSheet(self.doc.default_css,css)
    self.doc:setEmbeddedFonts(f.embedded_fonts);self.doc:setEmbeddedStyleSheet(f.embedded_css)
    self.doc:setBlockRenderingFlags(F.blockFlags(f));self.doc:setRenderDPI(f.render_dpi)
    local columns=F.visiblePages(f,self.w,self.h)
    -- CRe caps margins against the whole view. Also cap against each column
    -- so large native values cannot consume its entire text area. Keep the
    -- shared logical values intact for other orientations and view sizes.
    local maxX=math.max(0,math.floor(self.w/(columns*3)))
    local maxY=math.max(0,math.floor(self.h/3))
    local function margin(value,maximum)return math.min(maximum,screen:scaleBySize(value))end
    self.doc:setPageMargins(margin(f.margin_left,maxX),margin(f.margin_top,maxY),margin(f.margin_right,maxX),margin(f.margin_bottom,maxY))
    self.doc:setVisiblePageCount(columns)
    self.doc:setImageScaling(f.smooth_scaling==1);self.doc:setNightmodeImages(f.nightmode_images==1)
    self.format=f;self.font=f.size
    if self.readerCacheSpec then
        local old=self.readerCacheSpec
        self.readerCacheSpec=require('readinknative/chapterloader').spec(old.vid,old.book,self.path,self.w,self.h,self.font,self.format)
        self.readerCacheSpec.sourceStamp=old.sourceStamp
    end
end
function D:changeFormat(changes)
    local pointer=self.doc:getXPointer();local F=require('readinknative/format')
    local previous=F.resolveEngineDefaults(self.doc,self.format)
    local format=F.merge(self.format,changes,self.font)
    if F.signature(format)==F.signature(self.format,self.font)then
        self.format=format;self.font=format.size;return false
    end
    -- Check the font before standalone() closes the current document.
    local face,err=require('readinknative/readerfonts').ensure(self,format.face)
    if err then error(err,0)end
    if format.face and face~=format.face then error('FONT_LOAD_FAILED',0)end
    local position=self:position()
    local ok,result=pcall(function()
        if self.window and(format.view_mode==1 or F.visiblePages(format,self.w,self.h)>1)then
            self:standalone(self.w,self.h,format);return true
        end
        self:applyOptions(format);self.doc:render()
        if pointer then self:gotoPointer(pointer)end
        self.toc=self.doc:getToc()or{};return true
    end)
    if not ok then
        local restored,problem=pcall(function()
            if not self.doc then
                local fresh=D.open(self.path,self.w,self.h,previous.size,position,previous,'single-reader',self.article)
                for key,value in pairs(fresh)do self[key]=value end
            else
                self:applyOptions(previous);self.doc:render()
                self:restorePosition(position)
                self.toc=self.doc:getToc()or{}
            end
        end)
        if not restored then require('logger').warn('ReadInk format rollback failed:',problem)end
        error(result,0)
    end
    return result
end
function D:resize(w,h)
    if self.window and(self:isScroll()or require('readinknative/format').visiblePages(self.format,w,h)>1)then self:standalone(w,h,self.format);return end
    self:clearPageImages()
    local pointer=self.doc:getXPointer();self.w=w;self.h=h
    self.doc:setViewDimen{w=w,h=h};self:applyOptions(self.format);self.doc:render()
    if pointer then self:gotoPointer(pointer)end
    self.toc=self.doc:getToc()or{}
end
function D:resizeFont(size)self:changeFormat{size=size}end
function D:faces()
    local faces=self.doc:engineInit().getFontFaces();table.sort(faces);return faces
end
function D:linkAt(point)
    local target,source=self.doc:getLinkFromPosition(point)
    if type(target)~='string'or target==''then return end
    local L=require('readinknative/readerlinks')
    if target:sub(1,11)=='footnote://'then
        -- CRe already percent-decodes getLinkFromPosition's URI. Read the
        -- original attribute so literal %25/%2B are decoded exactly once.
        local raw=type(source)=='string'and self.doc:isXPointerInDocument(source)and self.doc:getHTMLFromXPointer(source,0x1001,false)
        local href
        if type(raw)=='string'then local quote;quote,href=raw:match('[hH][rR][eE][fF]%s*=%s*([\'"])(.-)%1')end
        if href then href=require('util').htmlEntitiesToUtf8(href)end
        local text;if href then text=L.inlineNote(href)else text=L.noteText(target:sub(12))end
        return text and{kind='footnote',text=text}or{kind='unavailable'}
    end
    if not self.doc:isXPointerInDocument(target)then return{kind='unavailable'}end
    local flags=0x0004+0x0008+0x0010+0x0020+0x0040+0x0100+0x0200+0x0400+0x0800+0x1000+0x4000+0x8000
    if type(source)=='string'and self.doc:isXPointerInDocument(source)then
        flags=flags+0x0002
        local yes,_,_,first,last=self.doc:isLinkToFootnote(source,target,flags,10000)
        if yes then
            local html=first and last and self.doc:getHTMLFromXPointers(first,last,0x1001)or self.doc:getHTMLFromXPointer(target,0x1001,true)
            local text=L.noteText(html)
            if text then return{kind='footnote',target=target,text=text}end
        end
    end
    return{kind='anchor',target=target}
end
function D:imageAt(point)
    return self.doc:getImageFromPosition(point,false,false)
end
function D:search(query)
    self:clearPageImages()
    local matches=self.doc:findAllText(query,true,5,200,false,0x00FF)or{}
    local rows={}
    for _,match in ipairs(matches)do
        if type(match.start)=='string' and self.doc:isXPointerInDocument(match.start)then
            rows[#rows+1]={xpointer=match.start,page=self.doc:getPageFromXPointer(match.start),
                match=match.matched_text,text=(match.prev_text or '')..' '..(match.matched_word_prefix or '')..(match.matched_text or '')..(match.matched_word_suffix or '')..' '..(match.next_text or '')}
        end
    end
    return rows
end
function D:clearSelection()
    if self.selectionActive then self:clearPageImages();self.selectionActive=nil end
    self.doc:clearSelection()
end
function D:selectRange(startPoint,endPoint)
    local range=self.doc:getTextFromPositions(startPoint,endPoint,true)
    if type(range)~='table' or type(range.text)~='string' or not range.text:find('%S') or #range.text>65536
        or type(range.pos0)~='string' or type(range.pos1)~='string'
        or not self.doc:isXPointerInDocument(range.pos0) or not self.doc:isXPointerInDocument(range.pos1)then return nil end
    self.doc:getTextFromXPointers(range.pos0,range.pos1,true)
    self:clearPageImages();self.selectionActive=true
    return {text=range.text,pos0=range.pos0,pos1=range.pos1,page=self.doc:getPageFromXPointer(range.pos0)}
end
function D:rangeBoxes(position)
    local start,finish=position.xpointer,position.endXPointer
    if type(start)~='string' or type(finish)~='string' or not self.doc:isXPointerInDocument(start)
        or not self.doc:isXPointerInDocument(finish)then return {}end
    if not self:isScroll()then
        local first,last=self.doc:getPageFromXPointer(start),self.doc:getPageFromXPointer(finish)
        local current=self:page();local visible=self.doc:getVisiblePageCount()
        if first>current+visible-1 or last<current then return {}end
    end
    return self.doc:getScreenBoxesFromPositions(start,finish,true)or{}
end
-- Retain a bounded clean body cache for text and illustration pages. CRe's last-page
-- buffer does not cover turning away and back. These frames contain body only;
-- notes, toolbar and status are drawn separately by the view.
function D:clearPageImages()
    self.frameGeneration=(self.frameGeneration or 0)+1
    for _,entry in ipairs(self.pageImages or{})do entry.buffer:free()end
    self.pageImages={};self.pageImageBytes=0
end
function D:frameKey(page)
    local screen=require('device').screen
    if self:isScroll()then page='scroll:'..self:scrollPos()
    else page=page or self:page();if self.window then page=self.window.row.firstPage+page-1 end end
    return table.concat({page,self.w,self.h,tostring(screen.night_mode),tostring(screen.sw_dithering),
        tostring(self.doc.render_color),tostring(self.doc._nightmode_images),tostring(self.doc._smooth_scaling)},':')
end
function D:hasFrame(key)
    for _,entry in ipairs(self.pageImages or{})do if entry.key==key then return true end end
end
function D:cacheFrame(key,buffer,images,surface)
    local bytes=tonumber(buffer.stride)*tonumber(buffer.h);local limit=8*1024*1024
    if bytes>limit then return end
    local frames=self.pageImages or{};self.pageImages=frames
    for i=#frames,1,-1 do if frames[i].key==key then local old=table.remove(frames,i);self.pageImageBytes=(self.pageImageBytes or 0)-old.bytes;old.buffer:free()end end
    while #frames>0 and(#frames>=3 or(self.pageImageBytes or 0)+bytes>limit)do
        local old=table.remove(frames,1);self.pageImageBytes=self.pageImageBytes-old.bytes;old.buffer:free()
    end
    frames[#frames+1]={key=key,buffer=buffer:copy(),bytes=bytes,images=images,surface=surface}
    self.pageImageBytes=(self.pageImageBytes or 0)+bytes;return true
end
function D:paint(bb,x,y)
    local key=self:frameKey()
    local frames=self.pageImages or{};self.pageImages=frames
    if not self.selectionActive then
        for i,entry in ipairs(frames)do if entry.key==key then
            bb:blitFrom(entry.buffer,x,y,0,0,self.w,self.h)
            table.remove(frames,i);table.insert(frames,entry)
            self.doc._drawn_images_count=entry.images;self.doc._drawn_images_surface_ratio=entry.surface
            return
        end end
    end
    local clock=require('ui/time');local started=clock.monotonic()
    self.doc:drawCurrentView(bb,x,y,require('ui/geometry'):new{w=self.w,h=self.h})
    local elapsed=clock.to_s(clock.monotonic()-started)
    if elapsed>=0.15 then require('logger').info('ReadInk slow body draw ms/page/images:',math.floor(elapsed*1000),self:page(),self.doc._drawn_images_count or 0)end
    local buffer=self.doc.buffer
    if not self.selectionActive and buffer then
        self:cacheFrame(key,buffer,self.doc._drawn_images_count,self.doc._drawn_images_surface_ratio)
    end
end
function D:close()
    self:clearPageImages()
    if self.doc then
        local cache=self.readerCacheSpec and self.doc:getCacheFilePath();local pages=self:count()
        self.doc:close();self.doc=nil
        if self.window then require('readinknative/chapterwindow').discard(self.window.spec,self.providerPath)end
        if cache then pcall(require('readinknative/chapterloader').save,self.readerCacheSpec,cache,pages)end
    end
end
return D
