-- Application/controller implemented for this independent branch.
local UI=require('ui/uimanager')
local App={};App.__index=App
local function formatPanelChoiceCurrent(app,owner)
    return owner and app.formatPanelChoice==owner and not owner.closed and not app.closed and not app.suspended and not app.chapterLoading
        and app.mode=='reader'and app.mode==owner.mode and app.state==owner.state and app.book==owner.book
        and app.document==owner.document and app.document.doc==owner.rawDocument
        and(app.client and app.client.data and app.client.data.vid)==owner.vid
end
function App.new(path,host)
    local client=require('readinknative/client'):new()
    local self=setmetatable({path=path,host=host,client=client,state=require('readinknative/state').new(client.data.vid),
        jobs=require('readinknative/jobs').new(),coverJobs=require('readinknative/jobs').new(),mode='shelf',query='',shelfPage=1,catalogPage=1,toolbar=false},App)
    self.view=require('readinknative/view'):new{app=self}
    self.flushTask=function()self:savePosition(true)end
    return self
end
function App:show()
    require('readinknative/rendercontext').capture(self)
    local screen=require('device').screen
    if self.view.dimen.w~=screen:getWidth()or self.view.dimen.h~=screen:getHeight()then require('readinknative/chapterloader').stop(self);self.view:onSetDimensions()end
    self.hasBeenShown=true;require('readinknative/wallpaper').attach(self);require('readinknative/hostreturn').attach(self);UI:show(self.view);self:loadCovers();require('readinknative/annotationsync').start(self,true);require('readinknative/readsync').start(self);require('readinknative/chapterloader').prime(self);require('readinknative/shelfmodel').ensure(self)
    if require('readinknative/preferences').gestureMode()=='koreader'then
        local ok,owner,reason=pcall(function()return require('readinknative/nativegestures').ensure(self)end)
        if not ok or not owner then
            local logok,logger=pcall(require,'logger')
            if logok then logger.warn('ReadInk native gestures unavailable:',tostring(ok and reason or owner))end
        end
    end
end
function App:raise()self.view:refresh()end
function App:message(text)UI:show(require('ui/widget/infomessage'):new{text=text})end
function App:failure(error)
    local E=require('readinknative/errors');local code=E.code(error)
    local ok,logger=pcall(require,'logger');if ok then logger.warn('ReadInk operation failed:',code)end
    self:message(E.message(error))
end
function App:draw()
    require('readinknative/avatarqueue').guard(self)
    require('readinknative/wallpaper').refresh(self)
    if self.mode~='store'then require('readinknative/store').stop(self)end
    if self.formatPanelChoice and not formatPanelChoiceCurrent(self,self.formatPanelChoice)then self:closeFormatPanelChoice()end
    local panel=self.nativeFormatPanel
    if panel and(self.closed or self.suspended or self.mode~='reader'or self.document~=panel.document)then self:closeFormatPanel()end
    if self.mode~='account'then require('readinknative/readprofile').cancel(self)end
    if self.mode~='shelf'or self.shelfEditing then require('readinknative/shelfmodel').cancel(self)end
    if self.cacheOwner and self.mode~='cache'then require('readinknative/actionpages').cancelCache(self)end
    if self.chapterLoading and self.mode~=self.chapterLoading.mode then require('readinknative/chapterloader').cancel(self)end
    if (self.chapterPreload or self.chapterFetch)and not self.chapterLoading and self.mode~='reader'and self.mode~='shelf'then require('readinknative/chapterloader').stop(self)end
    require('readinknative/imagereflow').request(self)
    require('readinknative/offline').images(self)
    local changed=require('readinknative/readingstats').update(self);require('readinknative/readingstats').schedule(self)
    if changed and self.mode~='reader'then UI:unschedule(self.flushTask);UI:scheduleIn(2,self.flushTask)end
    if not self.closed then
        if self.mode=='reader'then require('readinknative/nativeheader').refresh(self.document)end
        self.view:refresh()
    end
end
function App:startClock()
    if self.clockTask then UI:unschedule(self.clockTask)end
    local p=require('readinknative/preferences').normalize(self.state.preferences)
    local f=self.document and self.document.format
    local nativeHeader=f and f.status_line==0 and f.view_mode~=1
    if self.closed or self.suspended or self.mode~='reader'or not(p.showTime or p.showDeviceStatus or nativeHeader)then return end
    self.clockTask=self.clockTask or function()self:draw();self:startClock()end
    UI:scheduleIn(60-os.time()%60,self.clockTask)
end
function App:remote(label,operation,done,target,handlers)
    if self.closed or self.suspended then return end
    require('readinknative/readprofile').cancel(self)
    require('readinknative/shelfmodel').cancel(self)
    require('readinknative/offline').beforeForeground(self)
    self.coverJobs:cancel()
    local snapshot=self.client.data
    return self.jobs:run(label,function()
        local child=require('readinknative/client'):new(snapshot)
        local ok,value=pcall(operation,child)
        return {ok=ok,value=ok and value or nil,error=not ok and tostring(value)or nil},child.data
    end,function(ok,envelope,session)
        if self.closed then return end
        if handlers and handlers.valid and not handlers.valid()then return end
        if not ok then if handlers and handlers.failed then handlers.failed(envelope)else self:failure(envelope)end;return end
        if session then
            self.client.data=session;self.client.session.data=session;self.client:commit()
        end
        if not envelope.ok then
            if handlers and handlers.failed then handlers.failed(envelope.error)else self:failure(envelope.error);if target then self:cancelLogin()end end;return
        end
        done(envelope.value)
    end,target,handlers and handlers.cancelled)
end
function App:clearTextSelection()require('readinknative/textselection').clear(self)end
function App:home()
    require('readinknative/avatarqueue').stop(self,true)
    require('readinknative/chapterpreview').stop(self,true)
    require('readinknative/pdfbooks').cancel(self)
    if self.view then require('readinknative/readerscroll').cancel(self.view,false)end
    self:closeFormatPanel()
    require('readinknative/imagereflow').stop(self)
    require('readinknative/pagepreload').stop(self)
    require('readinknative/chapterwindow').stop(self,true)
    require('readinknative/underlinenext').stop(self)
    require('readinknative/articleimages').cancel(self)
    require('readinknative/chapterloader').stop(self)
    require('readinknative/chapterloader').cancel(self)
    require('readinknative/socialreader').cancel(self)
    require('readinknative/readerlinks').reset(self)
    self.autoDownloadWaiting=nil
    self.storeReturn=nil
    self.jobs:cancel()
    require('readinknative/input').close(self)
    self:clearTextSelection()
    self.panel=nil
    self.shelfEditing=false;self.shelfSelection={};self.notesEditing=false;self.noteSelection={}
    if self.clockTask then UI:unschedule(self.clockTask)end
    self:savePosition()
    require('readinknative/resident').park(self)
    self.articleReturn=nil
    self.mode='shelf';self:draw();self:loadCovers();require('readinknative/readsync').request(self,false,true);require('readinknative/shelfmodel').ensure(self,self.state.sort=='recent')
end
function App:account()require('readinknative/avatarqueue').stop(self,true);require('readinknative/underlinenext').stop(self);self.coverJobs:cancel();self.mode='account';self.accountPage=1;self:draw();require('readinknative/readprofile').refresh(self)end
function App:accountDetails()
    self.mode='accountDetails';self:draw()
    if self.client:ready()then require('readinknative/accountinfo').refresh(self)end
end
function App:accountSettings()
    self.mode='settings';self.settingsPage=1;self:draw()
end
function App:settingsItems()
    local items=require('readinknative/libraryactions').settings(self);local book=self.book
    if book and require('readinknative/pdftext').valid(book,self.client.data.vid)then
        local state,vid=self.state,self.client.data.vid
        table.insert(items,1,{'以原版 PDF 阅读','固定版式 · 保留原 PDF',function()
            if self.closed or self.state~=state or self.client.data.vid~=vid or self.book~=book then return end
            local original
            for _,b in ipairs(state.books or{})do if tostring(b.bookId)==tostring(book.bookId)and b.format=='pdf'then original=b;break end end
            if original then require('readinknative/pdfbooks').openOriginal(self,original)end
        end})
    end
    return items
end
function App:shelfSelect()return require('readinknative/libraryactions').shelfSelect(self)end
function App:shelfAll()return require('readinknative/libraryactions').shelfAll(self)end
function App:hideSelectedBooks()return require('readinknative/libraryactions').hideBooks(self)end
function App:toggleSelection(field,id)return require('readinknative/libraryactions').toggle(self,field,id)end
function App:notesSelect()return require('readinknative/libraryactions').noteSelect(self)end
function App:notesAll()return require('readinknative/libraryactions').noteAll(self)end
function App:copySelectedNotes()return require('readinknative/libraryactions').copyNotes(self)end
function App:deleteSelectedNotes()return require('readinknative/libraryactions').deleteNotes(self)end
function App:search()return require('readinknative/store').search(self,true)end
function App:syncShelf()
    if not self.client:ready()then self:account();return end
    local state,vid=self.state,self.client.data.vid
    local fence=require('readinknative/shelforder').fence(state)
    self:remote('同步书架',require('readinknative/api').shelfSnapshot,function(snapshot)
        require('readinknative/shelfmodel').apply(self,snapshot,fence)
        self.state:flush();self.shelfPage=1;self:draw();self:loadCovers()
    end,nil,{valid=function()return self.state==state and self.client.data.vid==vid end})
end
function App:loadCovers()
    if self.mode=='articles'then return require('readinknative/articles').covers(self)end
    if self.closed or self.suspended or (self.mode~='shelf'and self.mode~='store')then return end
    local isStore=self.mode=='store';local route=isStore and self.store and self.store.route
    local data=route and route.data;local items=data and data.items
    local previous=self.storeCoverOwner
    if isStore and route and previous and previous.epoch==self.coverJobs.epoch and previous.state==self.state and previous.vid==self.client.data.vid
        and previous.route==route and previous.page==route.page and previous.data==data and previous.items==items and self.coverJobs.widget then
        previous.refresh=true;return
    end
    self.coverJobs:cancel()
    local owner=isStore and route and{state=self.state,vid=self.client.data.vid,route=route,page=route.page,data=data,items=items}or nil
    self.storeCoverOwner=owner
    local media=require('readinknative/media');local thumbs=require('readinknative/covercache')
    local books=isStore and require('readinknative/store').visibleBooks(self)or require('readinknative/shelfmodel').visibleBooks(self)
    local count=#books;local first=1
    if isStore then for _,b in ipairs(require('readinknative/store').reserveBooks(self))do books[#books+1]=b end end
    local last=#books;local urls,seen,visible={},{},{}
    for i=first,last do
        local book=books[i];local url=book.cover
        if i<first+count then visible[#visible+1]=book end
        if url and not seen[url]and pcall(media.url,url)and not thumbs.find(self.client.data.vid,url)then
            urls[#urls+1]={url=url,fetch=true};seen[url]=true
        end
    end
    require('readinknative/offline').checkCompleted(self,visible)
    local vid,state,mode,page=self.client.data.vid,self.state,self.mode,self.shelfPage
    local function valid()
        return not self.closed and not self.suspended and self.state==state and self.mode==mode and self.shelfPage==page and self.client.data.vid==vid
            and(not owner or self.storeCoverOwner==owner and self.store and self.store.route==route and route.page==owner.page
                and route.data==data and data and data.items==items)
    end
    local cursor=1
    local function batch()
        if not valid()then return end
        if cursor>#urls then
            if owner and owner.refresh then owner.refresh=nil;self.storeCoverOwner=nil;self:loadCovers()end
            return
        end
        local start=cursor;cursor=cursor+3
        self.coverJobs:run('',function()
            local saved=0
            for i=start,math.min(#urls,start+2)do
                local row=urls[i];local ok,path=pcall(thumbs.prepare,vid,row.url,row.fetch);if ok and path then saved=saved+1 end
            end
            return saved
        end,function(ok,saved)
            if not valid()then return end
            if ok and saved>0 then self:draw()end
            batch()
        end,false)
        if owner then owner.epoch=self.coverJobs.epoch end
    end
    batch()
end
function App:ensureBookCover()
    local b=self.book;if not b or not b.cover or not require('readinknative/media').find(self.client.data.vid,b.cover)
        or require('readinknative/covercache').find(self.client.data.vid,b.cover)then return end
    local state,vid=self.state,self.client.data.vid
    self.coverJobs:run('',function()return require('readinknative/covercache').prepare(vid,b.cover,false)end,function(ok)
        if ok and not self.closed and not self.suspended and self.state==state and self.book==b and self.client.data.vid==vid and self.mode=='notes'then self:draw()end
    end,false)
end
function App:login()
    self.syncSigningOut=nil
    self:remote('获取微信登录二维码',function(c)return c:beginLogin()end,function(pending)
        self.pending=pending
        local ok,err=pcall(function()
            local path=require('readinknative/paths').account(nil)..'/login-qr.png'
            self.qrPath=path
            local f=assert(io.open(path,'wb'),'QR_FILE_FAILED')
            local written=f:write(pending.png);local closed=f:close();assert(written and closed,'QR_FILE_FAILED')
            pending.png=nil
            self.qrView=require('readinknative/qrview'):new{path=path,cancel=function()self:cancelLogin()end}
            UI:show(self.qrView)
        end)
        if not ok then self:cancelLogin();self:failure(err);return end
        self:pollLogin()
    end)
end
function App:pollLogin()
    local pending=self.pending;if not pending or not self.qrView then return end
    self:remote('等待微信授权',function(c)
        local accepted=c:pollLogin(pending)
        return {accepted=accepted,pending=pending}
    end,function(result)
        if result.accepted then
            self:cancelLogin();self.state=require('readinknative/state').new(self.client.data.vid)
            self.mode='shelf';self.query='';self:draw();self:syncShelf()
        else
            self.pending=result.pending
            self.pollTask=function()self.pollTask=nil;self:pollLogin()end
            UI:scheduleIn(0.5,self.pollTask)
        end
    end,self.qrView)
end
function App:cancelLogin(silent)
    require('readinknative/pdfbooks').cancel(self)
    self.jobs:cancel();self.coverJobs:cancel()
    if self.pollTask then UI:unschedule(self.pollTask);self.pollTask=nil end
    if self.qrView then UI:close(self.qrView);self.qrView=nil end
    if self.qrPath then os.remove(self.qrPath);self.qrPath=nil end
    self.pending=nil;if not silent then self:draw()end
end
function App:confirmLogout()
    local state,vid=self.state,self.client.data.vid
    UI:show(require('ui/widget/confirmbox'):new{text='退出微信读书账号？下次登录需要重新扫码。\n\n如果只是离开应用，请使用“退出阅墨”，它会保留登录。',ok_text='退出账号',ok_callback=function()
        if not self.closed and self.state==state and self.client.data.vid==vid then self:logout()end
    end})
end
function App:logout()
    if self.quickMenu then self.quickMenu:close()end
    require('readinknative/cacheindex').close(self)
    self.syncSigningOut=true
    require('readinknative/readsync').cancel(self);require('readinknative/annotationsync').stop(self)
    require('readinknative/offline').stopAll(self)
    self:cancelLogin();self:home()
    require('readinknative/resident').drop(self)
    self.client.data={deviceId=self.client.data.deviceId,installId=self.client.data.installId}
    self.client:commit();os.remove(require('readinknative/paths').settings('session')..'.old')
    self.state=require('readinknative/state').new(nil);self.query='';self:account()
end
function App:addLocal(path,title)
    assert(require('libs/libkoreader-lfs').attributes(path,'mode')=='file','LOCAL_FILE_MISSING')
    local id='local-'..require('ffi/sha2').sha256(path):sub(1,24)
    local book={bookId=id,title=title or path:match('([^/]+)$'),author='本地文件',localFile=path}
    local found=false
    for i,b in ipairs(self.state.books)do if b.bookId==id then self.state.books[i]=book;found=true;break end end
    if not found then table.insert(self.state.books,1,book)end
    self.state.hiddenBooks=self.state.hiddenBooks or {};self.state.hiddenBooks[id]=nil
    self.state:flush();self:openBook(book)
end
function App:demo()self:addLocal(self.path..'/fixtures/演示书.epub','ReadInk 阅读演示')end
function App:chooseFile()
    local ok,chooser=pcall(function()return require('ui/widget/pathchooser'):new{
        title='长按书名导入本地书籍',select_directory=false,select_file=true,
        path=require('apps/filemanager/filemanagerutil').getHomeFolder(),
        file_filter=function(path)return path:lower():match('%.pdf$')or path:lower():match('%.epub$')or path:lower():match('%.txt$')or path:lower():match('%.html?$')end,
        onConfirm=function(path)
            local ok,err=pcall(self.addLocal,self,path)
            if not ok then self:failure(err)end;return true
        end}end)
    if not ok then self:message('无法打开本地书籍选择器，请返回 KOReader 文件管理器后重试。');return end
    UI:show(chooser);return chooser
end
function App:openBook(book,storeOrigin,readContext)
    require('readinknative/avatarqueue').stop(self,true)
    require('readinknative/chapterpreview').stop(self,true)
    require('readinknative/pdfbooks').cancel(self)
    if require('readinknative/pdfbooks').isPdf(book)then return require('readinknative/pdfbooks').open(self,book)end
    self:closeFormatPanel()
    require('readinknative/imagereflow').stop(self)
    require('readinknative/pagepreload').stop(self)
    require('readinknative/chapterwindow').stop(self,true)
    require('readinknative/articleimages').cancel(self)
    if tonumber(book.type)==3 then return require('readinknative/articles').publisher(self,book)end
    local pending=self.chapterLoading
    if pending and pending.state==self.state and pending.vid==self.client.data.vid and tostring(pending.book.bookId)==tostring(book.bookId)then return end
    if self.chapterPreload and tostring(self.chapterPreload.book.bookId)~=tostring(book.bookId)or self.chapterFetch and self.chapterFetch.bookId~=tostring(book.bookId)then require('readinknative/chapterloader').stop(self)end
    require('readinknative/chapterloader').cancel(self)
    require('readinknative/readerlinks').reset(self)
    self.articleReturn=nil;self.storeReturn=storeOrigin
    require('readinknative/input').close(self);self.jobs:cancel()
    self:clearTextSelection()
    self.coverJobs:cancel();self:savePosition()
    require('readinknative/resident').park(self)
    self.readContext=readContext;self.readingDirection=1;self.book=book;self.autoDownloadBook=nil;self.autoDownloadWaiting=nil;self.pageIndex=nil;self.catalogPermission=nil;self.chapter=nil;self.chapters=nil;self.preview=false;self.refreshContent=false
    self.searchResults=nil;self.searchOwner=nil;self.shelfEditing=false;self.shelfSelection={};self.notesEditing=false;self.noteSelection={}
    self.catalogQuery='';self.notesPage=1;self.notesOnlyBookmarks=false
    if book._pdfText and readContext and readContext.catalog and readContext.pdfTextChapter then
        self.chapters=readContext.catalog;self.mode='catalog';self.catalogPage=1
        local index=1;for i,ch in ipairs(self.chapters)do if tostring(ch.chapterUid)==tostring(readContext.pdfTextChapter.chapterUid)then index=i;break end end
        self:selectChapter(self.chapters[index],index,readContext.pdfTextTarget)
    elseif book.localFile then self:openDocument(book.localFile)
    elseif not readContext and self.state.catalogs[tostring(book.bookId)]then
        self.chapters=self.state.catalogs[tostring(book.bookId)];self.catalogPage=1;self.mode='catalog'
        if not self:resumeReading()then self:draw()end
    else self:refreshCatalog(true)end
end
function App:resumeReading()
    local chapter,index=require('readinknative/readingstart').choose(self.state,self.book,self.chapters)
    if not chapter then return false end
    self:selectChapter(chapter,index);return true
end
function App:openCloudChapter()return require('readinknative/readsync').manual(self)end

function App:sortShelf()return require('readinknative/actionpages').sort(self)end
function App:updateBook(info,deferFlush)
    local current=self.book
    if tostring(current.version or 0)~=tostring(info.version or 0)and self.offlineVerified then self.offlineVerified[tostring(current.bookId)]=nil end
    require('readinknative/catalogrights').remember(self,info)
    self.catalogPermission={state=self.state,vid=self.client.data.vid,bookId=tostring(info.bookId),version=tostring(info.version or 0),proof=info._readPermission}
    for key,value in pairs(info)do if key~='localFile'and key~='_readPermission'and key~='_permissionError'then current[key]=value end end
    if not deferFlush then self.state:flush()end
end
function App:refreshCatalog(openReading)
    if not self.book or self.book.localFile then return end
    local book=self.book
    self:remote('更新图书与目录',function(c)
        local A=require('readinknative/api')
        local info=A.contextBook(c,book,self.readContext,false)or A.info(c,book)
        if info.format=='pdf'then return{book=info,pdf=true}end
        if tonumber(info.type)==3 then return {book=info,publisher=true}end
        local chapters=A.catalog(c,info)
        return {book=info,chapters=chapters,readContext=A.readContext(c,info,chapters)}
    end,function(result)
        self:updateBook(result.book,true);self.state:deferFlush()
        if result.pdf then require('readinknative/pdfbooks').open(self,self.book);return end
        if result.publisher then require('readinknative/articles').publisher(self,self.book);return end
        self.chapters=result.chapters;self.readContext=result.readContext
        self.state.catalogs[tostring(book.bookId)]=result.chapters
        self.catalogPage=1;self.refreshContent=not openReading;self.mode='catalog'
        if not openReading or not self:resumeReading()then self:draw()end
    end)
end
function App:openDocument(path,target)
    self:closeFormatPanel()
    require('readinknative/rendercontext').capture(self)
    require('readinknative/offline').beforeDocument(self)
    require('readinknative/socialreader').cancel(self)
    require('readinknative/readerlinks').reset(self)
    local requestedRotation=self.state:format(self.book).rotation_mode
    local screen=require('device').screen
    if requestedRotation~=nil and screen:getRotationMode()~=requestedRotation then
        local oldRotation=screen:getRotationMode()
        local rotated,reason=pcall(function()screen:setRotationMode(requestedRotation);self.view:onSetDimensions()end)
        if not rotated then
            pcall(screen.setRotationMode,screen,oldRotation);pcall(self.view.onSetDimensions,self.view)
            self:failure(reason);return
        end
    end
    local body=self.view.layout.body
    local previous=self.state:position(self.book,self.chapter);self.syncCaptureReady=false
    local single=self.singleReaderPath==path;self.singleReaderPath=nil
    local explicit=target and(target.xpointer or target.cloudOffset~=nil or target.edge or target.page or target.cloudChapter)
    local opened,notice,warning
    local ok,doc=pcall(function()
        local position=not explicit and self.state:position(self.book,self.chapter)or nil;local format=self.state:format(self.book)
        local doc=require('readinknative/chapterwindow').take(self,path,body.w,body.h,self.state.font,format,position)
            or require('readinknative/resident').take(self,path,body.w,body.h,self.state.font,format,position)
        if not doc and(self.book.article or(self.chapter and not self.book.localFile))then
            local loader=require('readinknative/chapterloader');loader.refresh(loader.spec(self.client.data.vid,self.book,path,body.w,body.h,self.state.font,format))
        end
        local context=single and'single-reader'or'reader'
        if self.book.article or(self.chapter and not self.book.localFile)then
            local loader=require('readinknative/chapterloader')
            if not single and loader.ready(loader.spec(self.client.data.vid,self.book,path,body.w,body.h,self.state.font,format))then context='prepared-reader'end
        end
        doc=doc or require('readinknative/document').open(path,body.w,body.h,self.state.font,position,format,context,self.book.article);opened=doc
        -- Apply navigation before publishing, saving or starting page work.
        if explicit then
            if target.xpointer then
                if not doc:gotoPointer(target.xpointer)then warning='记录位置已失效，图书内容可能已更新。'end
            elseif target.cloudOffset~=nil then
                local mapped=require('readinknative/readingposition').fromCloud(doc,path,self.book,self.chapter,target.cloudOffset)
                if mapped then doc:gotoPointer(mapped)else notice='云端章内位置未能精确匹配，已打开该章';warning=notice end
            elseif target.edge=='end'then doc:edge('end')
            elseif target.edge=='start'then doc:edge('start')
            elseif target.page then doc:jump(target.page)
            elseif target.cloudChapter then doc:jump(1);notice='云端章节开头'end
        end
        return doc
    end)
    if not ok then if opened and opened.doc then opened:close()end;self.syncCaptureReady=nil;self:failure(doc);self.mode=self.articleReturn and'articles'or(self.chapters and 'catalog'or'shelf');if self.articleReturn then local r=self.articleReturn.routes[self.articleReturn.kind];if r then r.loading=nil end;self.articleReturn=nil end;self:draw();return end
    self.document=doc;self.positionNotice=notice;self.mode='reader';self.toolbar=false;self.searchResults=nil;self.searchOwner=nil
    require('readinknative/chapterpreview').apply(self,doc)
    require('readinknative/readerformat').adoptEngineDefaults(doc.format)
    require('readinknative/shelforder').touch(self.state,self.book)
    if target and target.searchSession then require('readinknative/booksearch').restore(self,target.searchSession)end
    -- Publish text before cached underline mapping and background setup.
    -- Verified marks can repaint immediately after this first frame.
    self:savePosition();self:startClock();self:draw();UI:forceRePaint()
    local clock=require('ui/time')
    local function afterPaint(name,run)
        local started=clock.monotonic();run()
        local elapsed=clock.to_ms(clock.monotonic()-started)
        if elapsed>=80 then require('logger').info('ReadInk reader post-paint ms/stage:',math.floor(elapsed),name)end
    end
    afterPaint('underlines',function()require('readinknative/socialreader').start(self)end);if warning then self:message(warning)end
    if self.chapter and not self.book.localFile and not doc.window then
        local loader=require('readinknative/chapterloader');loader.track(doc,loader.spec(self.client.data.vid,self.book,path,body.w,body.h,self.state.font,self.state:format(self.book)))
    end
    self.syncCaptureReady=nil
    afterPaint('reading-sync',function()require('readinknative/readsync').open(self,previous,explicit and true or false)end)
    require('readinknative/annotationsync').changed(self)
    afterPaint('auto-download',function()require('readinknative/offline').autoStart(self)end)
    local indexed,reason=pcall(function()afterPaint('pagination',function()require('readinknative/pagination').request(self)end)end)
    if not indexed then require('logger').warn('ReadInk pagination:',require('readinknative/errors').code(reason))end
    afterPaint('book-cover',function()self:ensureBookCover()end)
    require('readinknative/chapterloader').next(self)
end
function App:catalogItems()return self.chapters or (self.document and self.document.toc)or{}end
function App:showCatalog()
    if self.articleReturn and self.articleReturn.publisher then return require('readinknative/articles').catalog(self)end
    self:clearTextSelection()
    local items=self:catalogItems()
    if #items==0 and not self.document then self:message('这本书没有目录。');return end
    self.panel=nil;self.catalogQuery='';self.mode='catalog'
    local index=require('readinknative/collections').current(self)or 1
    self.catalogPage=math.floor((index-1)/self.view.layout.catalogRows)+1;self:draw()
    require('readinknative/catalogrights').refresh(self)
end
function App:searchCatalog()
    return require('readinknative/input').show(self,function(draft)
    local dialog
    dialog=require('ui/widget/inputdialog'):new{title='搜索目录',input=draft or self.catalogQuery or '',buttons={{
        {text='取消',callback=function()UI:close(dialog)end},
        {text='搜索',is_enter_default=true,callback=function()
            self.catalogQuery=dialog:getInputText();self.catalogPage=1;UI:close(dialog);self:draw()
        end}},{{text='搜索正文',callback=function()
            local query=dialog:getInputText();UI:close(dialog);self:searchDocument(query)
        end}}}}
    return dialog
    end)
end
function App:searchDocument(query)return require('readinknative/booksearch').start(self,query)end
function App:jumpSearchResult(row)return require('readinknative/booksearch').jump(self,row)end
function App:selectChapter(chapter,index,target)
    self:closeFormatPanel()
    require('readinknative/imagereflow').stop(self)
    require('readinknative/pagepreload').stop(self)
    self.chapterNavigation=(self.chapterNavigation or 0)+1;local navigation=self.chapterNavigation
    self.jobs:cancel()
    local state,book,document,mode=self.state,self.book,self.document,self.mode
    if require('readinknative/offline').beforeDocument(self,function()
        if self.chapterNavigation==navigation and not self.closed and not self.suspended and self.state==state and self.book==book and self.document==document and self.mode==mode then self:selectChapter(chapter,index,target)end
    end)then return end
    require('readinknative/chapterloader').cancel(self)
    require('readinknative/socialreader').cancel(self)
    self:clearTextSelection()
    self.readingDirection=target and target.turnDelta==-1 and -1 or 1
    if self.book.localFile then
        if chapter.xpointer then self.document:gotoPointer(chapter.xpointer)else self.document:jump(tonumber(chapter.page)or 1)end
        if target and target.xpointer then self.document:gotoPointer(target.xpointer)end
        self.mode='reader';self.toolbar=false;self:savePosition();self:startClock();self:draw();return
    end
    local book=self.book
    local cached,mode=require('readinknative/cache').find(self.client.data.vid,book,chapter)
    if target and target.cacheOnly and not cached then self:message('搜索缓存已失效，请重新搜索。');return end
    local function open(path,kind,selected)
        self:savePosition();if self.document and not require('readinknative/chapterwindow').contains(self,path,selected or chapter)then self.document:close();self.document=nil end
        local incoming=target and target.cloudOffset~=nil;local applying=self.syncApplying;if incoming then self.syncApplying=true end
        self.chapter=selected or chapter;self.chapterIndex=index;self.preview=kind=='preview';self:openDocument(path,target)
        if self.document and target and target.turnDelta then require('readinknative/pageeffects').arm(self,target.turnDelta)end
        if self.document and target and(target.origin=='catalog'or target.turnDelta)then
            require('logger').info('ReadInk chapter navigation uid/index/page/pages:',self.chapter.chapterUid,self.chapterIndex,self.document:page(),self.document:count())
        end
        self.syncApplying=applying
        if incoming and self.document then require('readinknative/readsync').capture(self);self:savePosition(true)end
    end
    local function prepare(path,kind,selected)
        if not require('readinknative/images').ready(path)then self:failure('IMAGES_INCOMPLETE');return end
        require('readinknative/chapterloader').prepare(self,path,selected or chapter,function()open(path,kind,selected)end,target and target.turnDelta)
    end
    local ready=cached and require('readinknative/images').ready(cached)
    if target and target.cacheOnly and not ready then self:failure('IMAGES_INCOMPLETE');return end
    if ready and(not self.refreshContent or target and target.cacheOnly)then prepare(cached,mode);return end
    local function accepted(result)
        local reused=result.contextReused and self.state.catalogs[tostring(book.bookId)]and tostring(book.version or 0)==tostring(result.book.version or 0)
        self:updateBook(result.book,true);self.chapters=result.catalog
        self.state.catalogs[tostring(book.bookId)]=result.catalog;if not reused then self.state:deferFlush()end
        for i,item in ipairs(result.catalog)do if tostring(item.chapterUid)==tostring(chapter.chapterUid)then index=i;break end end
        self.refreshContent=false;prepare(result.path,result.mode,result.chapter)
        if result.images and not result.images.complete and not result.images.deferred then require('readinknative/offline').notice(self,'部分图片未下载，可点下载重试','icon_toolbar_download_error')end
    end
    local function fetch()
        self:remote('加载文字与图片',function(client)return require('readinknative/api').chapter(client,book,chapter,{buffer=true,context=self.readContext,direction=self.readingDirection})end,accepted)
    end
    if not ready and require('readinknative/readingahead').join(self,chapter,function(ok,result)if ok then accepted(result)else fetch()end end,target and target.turnDelta)then return end
    fetch()
end
function App:savePosition(flush,deferred)
    if self.document and self.document.doc and self.book then
        self.state:position(self.book,self.chapter,self.document:position())
        if self.syncCaptureReady~=false then local sync=require('readinknative/readsync');if deferred and not flush then sync.defer(self)else sync.capture(self)end end
        UI:unschedule(self.flushTask)
        if not flush then UI:scheduleIn(2,self.flushTask)end
    end
    if flush then (self.state.flushProgress or self.state.flush)(self.state)end
end
function App:leaveReading()if self.articleReturn then require('readinknative/articles').returnFromReader(self)elseif self.storeReturn then require('readinknative/store').returnFromReader(self)else self:home()end end
function App:listTurn(delta)
    if self.mode=='noteDetail'then
        self.detailPage=math.max(1,math.min(self.detailPages or 1,(self.detailPage or 1)+delta))
    elseif self.mode=='catalog'then
        local max=math.max(1,math.ceil(#require('readinknative/collections').catalog(self)/self.view.layout.catalogRows))
        self.catalogPage=math.max(1,math.min(max,self.catalogPage+delta))
    elseif self.mode=='notes'then
        local max=math.max(1,math.ceil(#require('readinknative/collections').records(self)/self.view.layout.noteRows))
        self.notesPage=math.max(1,math.min(max,(self.notesPage or 1)+delta))
    elseif self.mode=='settings'then
        local max=math.max(1,math.ceil(#self:settingsItems()/self.view.layout.settingsRows))
        self.settingsPage=math.max(1,math.min(max,(self.settingsPage or 1)+delta))
    elseif self.mode=='search'then
        local max=math.max(1,math.ceil(#(self.searchResults or {})/self.view.layout.searchRows))
        self.searchPage=math.max(1,math.min(max,(self.searchPage or 1)+delta))
    else
        local max=require('readinknative/shelfmodel').page(self).pages
        self.shelfPage=math.max(1,math.min(max,self.shelfPage+delta))
    end
    self:draw();if self.mode=='shelf'then self:loadCovers()end
end
function App:turn(delta)
    require('readinknative/imagereflow').stop(self)
    require('readinknative/pagepreload').stop(self)
    if self.chapterLoading then
        if not self.chapterLoading.turnDelta or self.chapterLoading.turnDelta==delta then return end
        require('readinknative/chapterloader').cancel(self)
    end
    local note=require('readinknative/readerlinks').currentNote(self)
    if note then note.page=math.max(1,math.min(note.pages or 1,note.page+delta));self:draw();return end
    if self.mode=='reader'then self.view.turnStarted=require('ui/time').monotonic()end
    self.positionNotice=nil
    if self.mode=='reader'then require('readinknative/chapterloader').pause(self);require('readinknative/offline').beforePageTurn(self)end
    self:clearTextSelection()
    if self.mode=='articles'then require('readinknative/articles').turn(self,delta);return end
    if self.mode=='store'then require('readinknative/store').turn(self,delta);return end
    if self.mode=='social'then require('readinknative/social').turn(self,delta);return end
    if self.mode~='reader'then if self.mode=='shelf' or self.mode=='catalog' or self.mode=='notes' or self.mode=='settings' or self.mode=='search' or self.mode=='noteDetail'then self:listTurn(delta)end;return end
    self.readingDirection=delta<0 and -1 or 1
    if self.document:turn(delta)then require('readinknative/pageeffects').arm(self,delta);require('readinknative/socialreader').moved(self);self:savePosition(false,true);self:draw();require('readinknative/chapterloader').next(self);return end
    if self.chapters then
        local nextIndex=require('readinknative/pagination').next(self,delta);local chapter=self.chapters[nextIndex]
        if chapter then self:selectChapter(chapter,nextIndex,{edge=delta<0 and'end'or'start',turnDelta=delta});return end
    end
    self:message(delta>0 and '已到当前内容末尾。'or'已到当前内容开头。')
end
function App:scrollBy(pixels,options)
    options=options or{}
    if self.closed or self.suspended or self.mode~='reader'or self.chapterLoading
        or not(self.document and self.document.doc and self.document:isScroll())then return false end
    if type(pixels)~='number'or pixels~=pixels or pixels==math.huge or pixels==-math.huge or pixels==0 then return false end
    require('readinknative/imagereflow').stop(self)
    require('readinknative/pagepreload').stop(self)
    require('readinknative/chapterloader').pause(self)
    require('readinknative/offline').beforePageTurn(self)
    self:clearTextSelection();self.positionNotice=nil;self.readingDirection=pixels<0 and -1 or 1
    local moved=self.document:scrollBy(pixels)
    if moved then
        if options.continuous then self.view:refresh()else self:finishScroll()end
        return true
    end
    if options.allowBoundary then
        self:turn(pixels<0 and -1 or 1)
    elseif not options.continuous then self:finishScroll()end
    return false
end
function App:finishScroll()
    if self.closed or self.suspended or self.mode~='reader'or self.chapterLoading
        or not(self.document and self.document.doc and self.document:isScroll())then return end
    require('readinknative/socialreader').moved(self)
    self:savePosition(false,true);self:draw();require('readinknative/chapterloader').next(self)
end
function App:back()
    if self.formatPanelChoice then self:closeFormatPanelChoice();return end
    if self.nativeFormatPanel then self:closeFormatPanel();self:draw();return end
    if self.mode=='shelf'and require('readinknative/shelfmodel').back(self)then return end
    require('readinknative/readersliders').cancel(self.view)
    if self.chapterLoading then
        require('readinknative/chapterloader').cancel(self)
        if self.articleReturn then require('readinknative/articles').returnFromReader(self)elseif self.document then self:draw()else self:home()end
        return
    end
    if self.mode=='reader'and require('readinknative/readerlinks').back(self)then return end
    if self.mode=='reader'and require('readinknative/booksearch').back(self)then return end
    if self.mode=='articles'then require('readinknative/articles').back(self);return end
    if self.mode=='store'then require('readinknative/store').back(self);return end
    if self.mode=='social'then require('readinknative/social').back(self);return end
    if self.textSelection then self:clearTextSelection();self:draw();return end
    if self.panel=='faces'then self:backFromFontFaces();return end
    if self.panel then self.panel=nil;self:draw();return end
    if self.mode=='shelf' and self.shelfEditing then self:shelfSelect();return end
    if self.mode=='notes' and self.notesEditing then self:notesSelect();return end
    if self.mode=='noteDetail'then
        local owner=self.noteDetail;self.noteDetail=nil;self.mode=owner and owner.returnMode or 'notes';self:startClock();self:draw();return
    end
    if self.mode=='sort'then self.mode=self.sortReturn or 'shelf';self:draw();return end
    if self.mode=='cache'then require('readinknative/actionpages').cancelCache(self);self:accountSettings();return end
    if self.mode=='settings' or self.mode=='accountDetails'then self:account();return end
    if self.mode=='search' and self.document then self.mode=self.searchReturnMode or 'reader';self:startClock();self:draw();return end
    if (self.mode=='catalog' or self.mode=='notes') and self.document then self.mode='reader';self:startClock();self:draw();require('readinknative/socialreader').start(self)
    elseif (self.mode=='reader'or self.mode=='catalog')and self.articleReturn then require('readinknative/articles').returnFromReader(self)
    elseif (self.mode=='reader'or self.mode=='catalog')and self.storeReturn then require('readinknative/store').returnFromReader(self)
    elseif self.mode=='reader'or self.mode=='catalog'or self.mode=='notes'or self.mode=='account'then self:home()
    else self:close()end
end
function App:currentMarks()
    local matches={};if not self.document then return matches end
    for _,row in ipairs(require('readinknative/annotations').list(self.state,self.book.bookId,'bookmark'))do
        local uid=self.chapter and tostring(self.chapter.chapterUid)or nil
        if row.chapterUid==uid and self.document.doc:isXPointerInDocument(row.position.xpointer)
            and self.document.doc:getPageFromXPointer(row.position.xpointer)==self.document:page()then matches[#matches+1]=row end
    end
    return matches
end
function App:bookmark()
    local A=require('readinknative/annotations');local marks=self:currentMarks()
    if #marks>0 then for _,row in ipairs(marks)do A.remove(self.state,row.id)end
    else A.add(self.state,self.book,self.chapter,'bookmark',self.document:position())end
    self.state:flush();self:draw()
end
function App:hasBookmark()return #self:currentMarks()>0 end
function App:jumpAnnotation(record)
    if not self.book or tostring(self.book.bookId)~=record.bookId then return end
    if self.book.localFile or record.chapterUid==(self.chapter and tostring(self.chapter.chapterUid)or nil)then
        if self.document:gotoPointer(record.position.xpointer)then
            self.mode='reader';self.panel=nil;self.toolbar=false;self:savePosition();self:startClock();self:draw()
        else self:message('记录位置已失效，图书内容可能已更新。')end
        return
    end
    for index,chapter in ipairs(self.chapters or {})do
        if tostring(chapter.chapterUid)==record.chapterUid then self:selectChapter(chapter,index,record.position);return end
    end
    self:message('当前目录中没有这条记录所属的章节。')
end
function App:progress()
    if not self.progressBaseline or self.progressBaseline.book~=self.book then local q=require('readinknative/readerpanels').summary(self);if q.percent then self.progressBaseline={book=self.book,percent=q.percent,seconds=q.localSeconds}end end
    if self.panel=='progress'then self.panel=nil else self.panel='progress'end
    self.toolbar=true;self:draw();if self.panel=='progress'then require('readinknative/readerpanels').refresh(self)end
end
function App:changeFormat(changes)
    if self.closed or self.suspended or not(self.book and self.document and self.document.doc)then return false,'READER_NOT_READY'end
    require('readinknative/pagepreload').stop(self)
    self:clearTextSelection()
    local previous=require('readinknative/format').normalize(self.document.format)
    local previousPosition=self.document:position()
    local ok,changed=pcall(self.document.changeFormat,self.document,changes)
    if not ok then self:failure(changed);return false,changed end
    local rotation=self.document.format.rotation_mode
    if rotation~=nil then
        local screen=require('device').screen;local oldRotation=screen:getRotationMode()
        if rotation~=oldRotation then
            local rotated,reason=pcall(function()
                require('readinknative/chapterloader').stop(self)
                screen:setRotationMode(rotation);self.view:onSetDimensions()
            end)
            if not rotated then
                pcall(screen.setRotationMode,screen,oldRotation)
                for _,key in ipairs{'rotation_mode','visible_pages','face','block_rendering_flags'}do
                    if previous[key]==nil then previous[key]=false end
                end
                pcall(self.document.changeFormat,self.document,previous)
                pcall(self.view.onSetDimensions,self.view)
                pcall(self.document.restorePosition,self.document,previousPosition)
                self:failure(reason);return false,reason
            end
            changed=true
        end
    end
    if not changed then self.state:setGlobalFormat(self.document.format);return true,false end
    self.state:setGlobalFormat(self.document.format)
    if not self.book.localFile then require('readinknative/pagination').request(self)end
    self:savePosition(true);self:startClock();require('readinknative/nativeheader').refresh(self.document)
    UI:setDirty(self.view,'full',self.view.dimen)
    return true,true
end
function App:setReaderRotation(mode)
    if type(mode)~='number'or mode~=math.floor(mode)or mode<0 or mode>3 then return false,'INVALID_ROTATION'end
    return self:changeFormat{rotation_mode=mode}
end
function App:resetFormat()
    return self:changeFormat(require('readinknative/readerformat').defaultFormat())
end
function App:closeFormatPanelChoice()
    local owner=self.formatPanelChoice;if not owner then return end
    self.formatPanelChoice=nil;owner.closed=true
    if owner.dialog then UI:close(owner.dialog)end
end
function App:chooseFormatPanel()
    self:closeFormatPanelChoice()
    if self.closed or self.suspended or self.chapterLoading or self.mode~='reader'or not(self.state and self.book and self.document and self.document.doc)then return false end
    local P=require('readinknative/preferences')
    local owner={state=self.state,book=self.book,document=self.document,rawDocument=self.document.doc,mode=self.mode,
        vid=self.client and self.client.data and self.client.data.vid}
    local buttons={}
    for _,option in ipairs{{'readink','阅墨面板'},{'koreader','KOReader 面板'}}do
        local key=option[1]
        buttons[#buttons+1]={{text=(P.formatPanel()==key and'✓ 'or'')..option[2],callback=function()
            if not formatPanelChoiceCurrent(self,owner)then
                if self.formatPanelChoice==owner then self:closeFormatPanelChoice()end
                return true
            end
            self:closeFormatPanelChoice()
            if P.formatPanel()~=key then P.setFormatPanel(key)end
            return self:showFormatPanel(key,true)
        end}}
    end
    buttons[#buttons+1]={{text='取消',callback=function()
        if self.formatPanelChoice==owner then self:closeFormatPanelChoice()end
        return true
    end}}
    local dialog=require('ui/widget/buttondialog'):new{title='选择排版面板',modal=true,stop_events_propagation=true,buttons=buttons}
    owner.dialog=dialog
    local onCloseWidget=dialog.onCloseWidget
    dialog.onCloseWidget=function(widget,...)
        owner.closed=true
        if self.formatPanelChoice==owner then self.formatPanelChoice=nil end
        if onCloseWidget then return onCloseWidget(widget,...)end
    end
    self.formatPanelChoice=owner;UI:show(dialog);return true
end
function App:closeFormatPanel()
    self:closeFormatPanelChoice()
    if self.nativeFormatPanel then require('readinknative/nativeformatpanel').close(self)end
end
function App:showFormatPanel(preferred,forceOpen)
    self:closeFormatPanelChoice()
    if self.closed or self.suspended or self.mode~='reader'or not(self.book and self.document and self.document.doc)then return false end
    if self.nativeFormatPanel then
        self:closeFormatPanel()
        if not forceOpen then self:draw();return true end
    end
    if self.panel=='font'or self.panel=='faces'then
        self.panel=nil;self.fontFacesReturn=nil
        if not forceOpen then self:draw();return true end
    end
    require('readinknative/readersliders').cancel(self.view)
    self:clearTextSelection();self.panel=nil;self.fontFacesReturn=nil
    local selected=preferred or require('readinknative/preferences').formatPanel()
    if selected=='koreader'then
        self.toolbar=false;self:draw()
        local ok,opened,reason=pcall(function()return require('readinknative/nativeformatpanel').open(self)end)
        if ok and opened then return true end
        -- A host without the required widget can still use the built-in sheet.
        self:closeFormatPanel()
        local logok,logger=pcall(require,'logger')
        if logok then logger.warn('ReadInk native format panel unavailable:',tostring(ok and reason or opened))end
        self.panel='font';self.toolbar=true;self:draw()
        self:message('当前 KOReader 版本暂不支持这个排版面板，已打开阅墨面板。')
        return true
    end
    self.panel='font';self.toolbar=true;self:draw();return true
end
function App:fontDialog()return self:showFormatPanel()end
function App:showFontFaces(origin)
    if self.closed or self.suspended or self.mode~='reader'or not self.document then return false end
    self:closeFormatPanel();require('readinknative/readersliders').cancel(self.view)
    self.fontFacesReturn=origin=='koreader'and'koreader'or'readink'
    self.panel='faces';self.fontCategory='全部';self.fontPage=1;self.toolbar=true;self:draw();return true
end
function App:backFromFontFaces()
    local origin=self.fontFacesReturn;self.fontFacesReturn=nil;self.panel=nil
    if origin=='koreader'then return self:showFormatPanel('koreader')end
    self.panel='font';self.toolbar=true;self:draw();return true
end
function App:notes()
    self:clearTextSelection()
    if not self.document or not self.book then return end
    self.panel=nil;self.mode='notes';self.notesPage=1;self.notesOnlyBookmarks=false;self.notesEditing=false;self.noteSelection={};self:draw()
    require('readinknative/social').refreshMine(self);self:ensureBookCover()
    return self.view
end
function App:cacheManager()return require('readinknative/readingmenu').cache(self)end
function App:editNote(record,selected)
    local A=require('readinknative/annotations')
    local position=record and record.position or selected and selected.position or self.document:position()
    local chapter=selected and selected.chapter or self.chapter
    local state,book=self.state,self.book
    local quote=record and record.quote or selected and selected.quote
    return require('readinknative/input').show(self,function(draft)
    local dialog
    dialog=require('ui/widget/inputdialog'):new{title=record and '编辑本地笔记'or'新增本地笔记',description=quote and A.summary(quote)or nil,input=draft or record and record.text or '',multiline=true,buttons={{
        {text='取消',callback=function()UI:close(dialog)end},
        {text='保存',callback=function()
            local text=dialog:getInputText()
            if text=='' or #text>65536 then self:message('请输入笔记，最多 64 KB。');return end
            if self.closed or self.state~=state or self.book~=book then UI:close(dialog);return end
            if record then
                local found=false;for _,row in ipairs(state.annotations)do if row==record then found=true;break end end
                if not found then UI:close(dialog);return end
                A.edit(record,text)
            else local row=A.add(state,book,chapter,'note',position,text);row.quote=quote end
            self.state:flush();UI:close(dialog);self:draw()
        end}}}}
    return dialog
    end)
end
function App:about()
    self:message('运行于 Kindle 原生系统的 KOReader 插件。界面依据微信读书墨水屏版 2.1.2。\n\n支持书架、书城、目录、章节与图片下载、书籍/公众号阅读、划线云端同步、阅读时长及进度同步。点划线可查看对应想法，并撰写想法、选择公开、关注、私密或屏蔽好友后发表。\n\n作者：kindle之家')
end
function App:suspend()
    require('readinknative/avatarqueue').stop(self,true)
    require('readinknative/chapterpreview').stop(self,true)
    require('readinknative/social').cancelMine(self)
    require('readinknative/wallpaper').stop(self)
    if self.wallpaperImport then self.wallpaperImport:cancel()end
    require('readinknative/store').stop(self)
    if self.nativeGestures then require('readinknative/nativegestures').suspend(self)end
    if self.view then require('readinknative/readerscroll').cancel(self.view,false)end
    self:closeFormatPanel()
    if self.quickMenu then self.quickMenu:close()end
    require('readinknative/readprofile').cancel(self)
    require('readinknative/shelfmodel').cancel(self)
    require('readinknative/fontprogress').cancel(self,true)
    require('readinknative/imagereflow').stop(self)
    require('readinknative/pagepreload').stop(self)
    require('readinknative/chapterwindow').stop(self,true)
    require('readinknative/underlinenext').stop(self)
    require('readinknative/readersliders').cancel(self.view)
    require('readinknative/actionpages').cancelCache(self)
    require('readinknative/articleimages').cancel(self)
    if self.closed or self.suspended then return end
    require('readinknative/chapterloader').stop(self)
    require('readinknative/chapterloader').cancel(self)
    require('readinknative/readsync').stop(self);require('readinknative/annotationsync').stop(self)
    self.suspended=true;require('readinknative/articles').suspend(self)
    if self.flushTask then UI:unschedule(self.flushTask)end
    if self.resumeTask then UI:unschedule(self.resumeTask);self.resumeTask=nil end
    if self.cacheCheckJobs then self.cacheCheckJobs:cancel()end
    require('readinknative/socialreader').cancel(self)
    require('readinknative/readerlinks').dismiss(self,true)
    local offlineChanged=require('readinknative/offline').stopAll(self,true)
    self:clearTextSelection()
    require('readinknative/readingstats').update(self);require('readinknative/readingstats').schedule(self);require('readinknative/input').close(self,true);if self.clockTask then UI:unschedule(self.clockTask)end;self:cancelLogin(true)
    self:savePosition();if self.flushTask then UI:unschedule(self.flushTask)end
    if offlineChanged then self.state:flush()else(self.state.flushProgress or self.state.flush)(self.state)end
end
function App:resume()
    if self.closed or not self.suspended then return end
    if require('readinknative/wallpaper').blocked()then self.wallpaperResumePending=true;return end
    self.wallpaperResumePending=nil
    require('logger').info('ReadInk resume mode/view/host:',self.mode,UI:isWidgetShown(self.view),self.host and UI:isWidgetShown(self.host)or false)
    self.suspended=false;self.resumeSettling=true;self:startClock();if self.mode=='cache'then require('readinknative/actionpages').cache(self)end;self:draw();require('readinknative/input').resume(self)
    if self.mode=='account'then require('readinknative/readprofile').refresh(self)end
    require('readinknative/socialreader').resume(self)
    require('readinknative/readsync').start(self);require('readinknative/annotationsync').start(self)
    self.resumeTask=function()self.resumeTask=nil;self.resumeSettling=false end;UI:scheduleIn(1,self.resumeTask)
    -- Reader/QR retries stay disabled; My statistics refresh is deferred.
end
function App:exit()
    -- Only an explicit Exit button follows this preference. Back navigation,
    -- suspend, host teardown and plugin cleanup still call close() normally.
    if self.closed or self.exiting then return end
    self.exiting=true
    local target=require('readinknative/preferences').exitTarget()
    if target~='kindle'then
        local ok,err=pcall(self.close,self);self.exiting=nil
        if not ok then error(err,0)end
        return
    end
    local ok,progress=pcall(function()return require('readinknative/exitprogress').show()end)
    if not ok then self.exiting=nil;self:failure(progress);return end
    self.exitProgress=progress
    -- The page and message are already painted before any saving/cleanup.
    UI:nextTick(function()
        local closed,err=pcall(function()
            self:close()
            -- Native host modules save/close their own documents and settings.
            -- Explicitly quit only in their completion callback: our persistent
            -- overlay would otherwise keep the window stack alive indefinitely.
            UI:broadcastEvent(require('ui/event'):new('Exit',function()UI:quit()end))
        end)
        if not closed then
            -- A failed final flush may happen after the document was closed,
            -- but before its now-unpaintable plugin view was removed.
            if self.closed and UI:isWidgetShown(self.view)then
                pcall(function()require('readinknative/hostreturn').leave(self)end)
            end
            self.exitProgress=nil;self.exiting=nil
            UI:close(progress);UI:setDirty('all','ui')
            self:failure(err)
        end
    end)
end
function App:close()
    require('readinknative/avatarqueue').stop(self,true)
    require('readinknative/chapterpreview').stop(self,true)
    require('readinknative/social').cancelMine(self)
    require('readinknative/wallpaper').detach(self)
    if self.wallpaperImport then self.wallpaperImport:cancel()end
    self.wallpaperResumePending=nil
    require('readinknative/store').stop(self)
    if self.nativeGestures then require('readinknative/nativegestures').close(self)end
    if self.view then require('readinknative/readerscroll').cancel(self.view,false)end
    self:closeFormatPanel()
    if self.quickMenu then self.quickMenu:close()end
    require('readinknative/readprofile').cancel(self)
    require('readinknative/shelfmodel').cancel(self)
    require('readinknative/fontprogress').cancel(self,true)
    require('readinknative/imagereflow').stop(self)
    require('readinknative/pagepreload').stop(self)
    require('readinknative/chapterwindow').stop(self,true)
    require('readinknative/underlinenext').stop(self)
    require('readinknative/readersliders').cancel(self.view)
    require('readinknative/actionpages').cancelCache(self)
    require('readinknative/cacheindex').close(self)
    require('readinknative/articleimages').cancel(self)
    if self.closed then return end
    require('readinknative/chapterloader').stop(self)
    require('readinknative/chapterloader').cancel(self)
    require('readinknative/readsync').stop(self);require('readinknative/annotationsync').stop(self)
    require('readinknative/resident').drop(self)
    if self.cacheCheckJobs then self.cacheCheckJobs:cancel()end
    if self.resumeTask then UI:unschedule(self.resumeTask);self.resumeTask=nil end
    require('readinknative/socialreader').cancel(self)
    require('readinknative/readerlinks').reset(self)
    local offlineChanged=require('readinknative/offline').stopAll(self,true)
    require('readinknative/input').close(self)
    if self.inputResumeTask then UI:unschedule(self.inputResumeTask);self.inputResumeTask=nil end
    self:clearTextSelection()
    if self.closed then return end
    if self.clockTask then UI:unschedule(self.clockTask)end
    self:cancelLogin(true);self:savePosition();if self.flushTask then UI:unschedule(self.flushTask)end
    require('readinknative/readingstats').update(self);if self.hasBeenShown then require('readinknative/readsync').request(self,false,true)end
    if self.document then self.document:close();self.document=nil end
    self.closed=true;require('readinknative/readingstats').update(self);require('readinknative/readingstats').schedule(self)
    if offlineChanged then self.state:flush()else(self.state.flushProgress or self.state.flush)(self.state)end
    require('readinknative/hostreturn').leave(self)
end
return App
