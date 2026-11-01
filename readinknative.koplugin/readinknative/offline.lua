-- Official E-Ink flow: one book-wide action in the reader, or shelf selection.
-- No download page. A separate worker keeps navigation and page turns usable.
local O={}
local function queues(a)a.state.offlineQueues=a.state.offlineQueues or{};return a.state.offlineQueues end
local function id(b)return tostring(b.bookId)end
local function same(a,r)return a.offlineRuntime==r and a.state==r.state and a.client.data.vid==r.vid and not a.closed and not a.suspended end
local function copyBook(b)
    local out={};for _,k in ipairs({'bookId','title','version','format','paid','payType','maxFreeChapter','maxFreeInfo','shortTimeRead','_pdfText','otherType'})do out[k]=b[k]end;return out
end
function O.notice(a,text,icon)
    local UI=require('ui/uimanager');if a.offlineNoticeTask then UI:unschedule(a.offlineNoticeTask)end
    local note={text=text,icon=icon or'icon_toolbar_download_start'};a.offlineNotice=note
    a.offlineNoticeTask=function()if a.offlineNotice==note then a.offlineNotice=nil;if not a.closed then a:draw()end end end
    UI:scheduleIn(5,a.offlineNoticeTask);a:draw()
end
function O.queue(a,b)return queues(a)[id(b)]end
function O.status(a,b,displayOnly)
    if not b or b.localFile then return 0 end
    if require('readinknative/pdfbooks').isPdf(b)then
        local text=(a.state.pdfText or{})[id(b)]
        if text and text.sourceVersion==(b.version or 0)and require('readinknative/pdftext').valid(text.book,a.client.data.vid)then
            local q=O.queue(a,text.book)
            if q and(q.status==1 or q.status==2 or q.status==3 or q.status==4)then return O.status(a,text.book,displayOnly)end
        end
        return require('readinknative/pdfbooks').status(a,b)
    end
    local waiting=a.autoDownloadWaiting
    if waiting and waiting.book==b and waiting.state==a.state and waiting.vid==a.client.data.vid then return 1 end
    local q=O.queue(a,b);if not q or q.schema~=2 then return 0 end
    if q.version and b.version and tostring(q.version)~=tostring(b.version)then return 0 end
    local status=q.status or 0
    if status==1 or status==2 then
        local r=a.offlineRuntime;if not r or not same(a,r)then return 0 end
    elseif status==3 or status==4 then
        -- Once per app/queue revision: completion must be backed by actual files.
        a.offlineVerified=a.offlineVerified or{}
        if a.offlineVerified[id(b)]~=q then
            if #(q.chapters or{})==0 then return 0 end
            -- Preserve the last completed state while physical validation runs.
            if displayOnly then return status end
            for _,ch in ipairs(q.chapters)do
                local path,mode=require('readinknative/cache').stored(a.client.data.vid,q.book,ch)
                if not path or(ch.offlineMode=='full'and mode~='full')or not require('readinknative/images').ready(path)then return 0 end
            end
            a.offlineVerified[id(b)]=q
        end
    end
    return status
end
function O.displayStatus(a,b)return O.status(a,b,true)end
function O.checkCompleted(a,books,done)
    local wanted={};local state,vid=a.state,a.client.data.vid
    for _,b in ipairs(books)do
        local q=O.queue(a,b)
        if q and(q.status==3 or q.status==4)and(not q.version or not b.version or tostring(q.version)==tostring(b.version))and(not a.offlineVerified or a.offlineVerified[id(b)]~=q)then wanted[#wanted+1]={book=b,queue=q}end
    end
    if #wanted==0 then if done then done()end;return end
    a.cacheCheckJobs=a.cacheCheckJobs or require('readinknative/jobs').new()
    a.cacheCheckJobs:run('',function()
        local result={}
        for _,row in ipairs(wanted)do local status=O.status(a,row.book);result[id(row.book)]=status==3 or status==4 end
        return result
    end,function(ok,result)
        if not ok or a.closed or a.suspended or a.state~=state or a.client.data.vid~=vid then return end
        a.offlineVerified=a.offlineVerified or{}
        for _,row in ipairs(wanted)do
            local key=id(row.book)
            if queues(a)[key]==row.queue then
                if result[key]then a.offlineVerified[key]=row.queue else row.queue.status=0 end
            end
        end
        a:draw();if done then done()end
    end,false)
end
function O.presentation(a,b)
    local status=O.displayStatus(a,b);local q=b and O.queue(a,b)
    if status==1 then return'icon_toolbar_pre_download','正在下载…',status
    elseif status==2 then return'icon_toolbar_downloading','正在下载…',status
    elseif status==3 or status==4 then return'icon_toolbar_download_done','',status
    elseif status==5 then return'icon_toolbar_download_error','下载失败',status end
    return'icon_toolbar_download','下载',0
end
local function schedule(a,r,delay)
    if not same(a,r)or r.timer then return end
    r.timer=function()r.timer=nil;if same(a,r)then O.pump(a,r)end end
    require('ui/uimanager'):scheduleIn(delay or 0.01,r.timer)
end
local function runtime(a)
    local r=a.offlineRuntime
    if r and same(a,r)then return r end
    r={state=a.state,vid=a.client.data.vid,jobs=require('readinknative/inkjobs').new{NICE=10,TIMEOUT=300},pending={}}
    a.offlineRuntime=r;return r
end
local function persist(a)(a.state.flushOffline or a.state.flush)(a.state)end
function O.paginate(a,spec,index)
    local r=runtime(a);r.pageTask={spec=spec,index=index};schedule(a,r)
end
local function updateBook(a,b)
    require('readinknative/catalogrights').remember(a,b)
    local function merge(target)
        local rawPdf=target.format=='pdf'and b._pdfText~=nil
        for k,v in pairs(b)do if k~='_readPermission'and k~='_permissionError'and(not rawPdf or k~='format'and k~='version'and k~='_pdfText')then target[k]=v end end
    end
    for _,old in ipairs(a.state.books or{})do if id(old)==id(b)then merge(old)end end
    if a.book and id(a.book)==id(b)then merge(a.book);a.catalogPermission={state=a.state,vid=a.client.data.vid,bookId=id(b),version=tostring(b.version or 0),proof=b._readPermission}end
end
local function work(a,r,fn,done,writes)
    r.contentWrites=writes;r.busy=true;local snapshot=a.client.data;local pageOnly=r.pageOnly;r.pageOnly=nil
    r.jobs.TIMEOUT=writes and writes.images and 30 or 300
    -- No modal intercepts input; compact reading explicitly cancels repeatable
    -- content work when it needs foreground resources.
    r.jobs:run('',function()
        require('readinknative/imagefetch').enabled=true
        local c=require('readinknative/client'):new(snapshot)
        local ok,value=pcall(fn,c)
        return{ok=ok,value=ok and value or nil,error=not ok and require('readinknative/errors').code(value)or nil},c.data
    end,function(ok,result,session)
        if not same(a,r)then return end
        r.busy=false;r.contentWrites=nil
        if session and a.client.data==snapshot then a.client.data=session;a.client.session.data=session;a.client:commit()end
        if not ok then result={ok=false,error='WORKER_FAILED'}end
        local oldIndex=a.pageIndex;local oldTotal=oldIndex and oldIndex.total;local oldEstimated=oldIndex and oldIndex.estimated
        local uid=a.chapter and tostring(a.chapter.chapterUid);local oldOffset=oldIndex and oldIndex.rows and oldIndex.rows[uid]and oldIndex.rows[uid].offset
        done(result);if same(a,r)then
            if not pageOnly then if writes and r.active then persist(a)else a.state:flush()end end
            local index=a.pageIndex;local offset=index and index.rows and index.rows[uid]and index.rows[uid].offset
            if not pageOnly or a.mode=='reader'and(oldTotal~=(index and index.total)or oldEstimated~=(index and index.estimated)or oldOffset~=offset)then a:draw()end
            schedule(a,r)
        end
    end,{})
end
-- A download of a different chapter need not block a local next-chapter
-- layout. Never share a path with repair/download or a pagination worker.
function O.canPreload(a,book,chapter)
    local r=a.offlineRuntime
    if not r or not same(a,r)or not r.busy then return true end
    local writes=r.contentWrites;if not writes then return false end
    return writes.bookId~=id(book)or writes.version~=tostring(book.version or 0)or not writes.uids[tostring(chapter.chapterUid)]
end
function O.beforeForeground(a)
    local r=a.offlineRuntime;if not r or not same(a,r)then return end
    -- Serialize foreground network/content writes with the background worker.
    if r.busy then
        r.jobs:cancel();r.busy=false;r.contentWrites=nil;r.pageOnly=nil
        if r.imageActive then r[r.imageActive.prefetch and'bufferImageTask'or'imageTask']=r.imageActive;r.imageActive=nil;r.imageAfter=require('socket').gettime()+0.5 end
        if r.pageActive then r.pageTask=r.pageActive;r.pageActive=nil elseif r.active then r.active.q.status=1 end
    end
    schedule(a,r)
end
-- A store book need not be on the shelf to finish its current illustrations.
-- Share the offline writer so image repair cannot race a download/cache tail.
function O.images(a)
    local r=a.offlineRuntime;local d=a.document
    if r and same(a,r)and r.imageActive and(a.mode~='reader'or r.imageActive.document~=d)then
        O.beforeForeground(a);r.imageTask=nil
    end
    if a.mode~='reader'then a.readerImageDocument=nil;if r then r.bufferImageTask=nil end;return end
    if a.mode~='reader'or not d or not d.doc or not a.book or a.book.localFile or a.book.article or not a.chapter
        or a.closed or a.suspended or not a.client:ready()or a.readerImageDocument==d then return end
    a.readerImageDocument=d
    local stamp=require('readinknative/pagination').fileStamp(d.path)
    local watch=a.readerImageWatch
    if watch and watch.document==d and watch.stamp~=stamp then
        a.pendingImageReload=d;require('readinknative/imagereflow').request(a)
    end
    a.readerImageWatch={document=d,stamp=stamp}
    -- Chapters now pass a complete-image barrier before opening. Never create
    -- a visible-page repair job that replaces an empty frame after the text.
end
-- Finish one adjacent chapter's illustrations after its text/layout is ready.
-- It shares the current-image writer and is discarded when its reader leaves.
function O.bufferImages(a,result)
    if a.closed or a.suspended or a.mode~='reader'or not a.document or not a.client:ready()
        or not a.book or a.book.localFile or a.book.article or not result.book or not result.chapter
        or id(result.book)~=id(a.book)or tostring(result.book.version or 0)~=tostring(a.book.version or 0)
        or require('readinknative/cache').find(a.client.data.vid,result.book,result.chapter)~=result.path then return end
    local status=require('readinknative/images').status(result.path)
    if not status or status.complete or result.path==a.document.path then return end
    local r=runtime(a)
    r.bufferImageTask={book=a.book,chapter=result.chapter,document=a.document,path=result.path,version=tostring(a.book.version or 0),
        stamp=require('readinknative/pagination').fileStamp(result.path),failures=0,prefetch=true,earlyDone=true}
    schedule(a,r,1)
end
local function compactReader(a)
    return a.mode=='reader'and a.document and require('readinknative/chapterloader').compact(a)
end
-- On the Basic, a content child may otherwise decode images while the parent
-- allocates the next CRe DOM. Cancel repeatable download work before input or a
-- native load; committed chapters and the queue cursor remain reusable.
function O.beforeDocument(a,after)
    if not require('readinknative/chapterloader').compact(a)then return end
    local r=a.offlineRuntime;if not r or not same(a,r)then return end
    if after and r.busy and r.contentWrites and r.contentWrites.short then
        if r.documentWait then require('ui/uimanager'):unschedule(r.documentWait)end
        local started=require('ui/time').monotonic();local state,book,document,mode=a.state,a.book,a.document,a.mode
        local function wait()
            if r.documentWait~=wait then return end
            if not same(a,r)or a.state~=state or a.book~=book or a.document~=document or a.mode~=mode then r.documentWait=nil;return end
            if r.busy and require('ui/time').monotonic()-started<require('ui/time').s(1.2)then require('ui/uimanager'):scheduleIn(0.025,wait);return end
            r.documentWait=nil;O.beforeForeground(a);after()
        end
        r.documentWait=wait;r.readerAfter=started+require('ui/time').s(2)
        require('ui/uimanager'):scheduleIn(0.025,wait);return true
    end
    O.beforeForeground(a)
    r.readerAfter=require('ui/time').monotonic()+require('ui/time').s(2)
end
function O.beforePageTurn(a)
    local r=a.offlineRuntime;if not r or not same(a,r)then return end
    if r.pageActive then
        r.jobs:cancel();r.pageTask=r.pageActive;r.pageActive=nil;r.busy=false
    end
    local clock=require('ui/time');r.pageAfter=clock.monotonic()+clock.s(4);r.readerAfter=clock.monotonic()+clock.s(0.15)
    schedule(a,r)
end
function O.interact(a)
    require('readinknative/articleimages').input(a)
    local r=a.offlineRuntime;if not r or not same(a,r)then return end
    if r.pageActive then r.jobs:cancel();r.pageTask=r.pageActive;r.pageActive=nil;r.busy=false;r.pageOnly=nil end
    r.pageAfter=require('ui/time').monotonic()+require('ui/time').s(4);r.readerAfter=require('ui/time').monotonic()+require('ui/time').s(0.15)
end
function O.pump(a,r)
    if not same(a,r)or r.busy then return end
    local compact=compactReader(a)
    if compact then
        local clock=require('ui/time')
        local wait=r.readerAfter and r.readerAfter-clock.monotonic()or 0
        if wait>0 then schedule(a,r,math.max(0.25,clock.to_s(wait)));return end
        local free=require('util').calcFreeMem()
        if free and free<48*1024*1024 then
            if not r.memoryDeferred then require('logger').info('ReadInk download waiting for reader memory KB:',math.floor(free/1024));r.memoryDeferred=true end
            schedule(a,r,2);return
        end
        r.memoryDeferred=nil
    end
    if a.cacheOwner or a.cacheBusy or a.jobs.widget or a.chapterFetchJobs and a.chapterFetchJobs.widget or a.chapterJobs and a.chapterJobs.widget or a.preloadJobs and a.preloadJobs.widget
        or a.socialReaderJobs and a.socialReaderJobs.widget
        or require('readinknative/socialreader').busy(a)or require('readinknative/underlinenext').busy(a)then schedule(a,r);return end
    local slot=r.imageTask and'imageTask'or'bufferImageTask';local image=r[slot]
    if image then
        local function current()
            return same(a,r)and a.mode=='reader'and a.document==image.document and a.book==image.book
                and(image.prefetch or a.chapter==image.chapter)and tostring(a.book.version or 0)==image.version
        end
        if not current()then r[slot]=nil
        elseif a.panel or a.toolbar or a.textSelection or a.readerOverlay or a.resumeSettling or a.pendingImageReload
            or a.view and a.view.scrollDrag or require('socket').gettime()<(r.imageAfter or 0)then schedule(a,r,0.5);return
        else
            local free=require('util').calcFreeMem()
            if free and free<96*1024*1024 then schedule(a,r,2);return end
            r[slot]=nil;r.imageActive=image;r.pageOnly=true
            local writes={bookId=id(image.book),version=image.version,uids={[tostring(image.chapter.chapterUid)]=true},images=true}
            work(a,r,function(c)
                assert(require('readinknative/cache').find(r.vid,image.book,image.chapter)==image.path,'READING_CACHE_CHANGED')
                local C=require('readinknative/content');local I=require('readinknative/images')
                local path,status=C.repair(image.path,function(files)
                    -- Public illustrations need no failed bundle round-trip.
                    -- If that pass misses protected images, retry the official
                    -- authenticated bundle through the same bound chapter.
                    local root=require('readinknative/paths').account(r.vid)
                    local context=I.prefetch(files,nil,nil,nil,root,not image.earlyDone and 2 or nil)
                    if image.failures>0 then
                        local missing={}
                        for _,url in ipairs(I.references(files))do
                            if context[url]==false and not(context._pending and context._pending[url])then missing[#missing+1]=url end
                        end
                        local seed=require('readinknative/imagearchive').prepare(c,image.book,{image.chapter},missing)
                        for url,value in pairs(seed)do context[url]=value end
                        context=I.prefetch(files,context,nil,nil,root)
                    end
                    return context
                end)
                if not status.complete then status.deferred=true;I.marker(path,status)end
                return{images=status,stamp=require('readinknative/pagination').fileStamp(path)}
            end,function(result)
                r.imageActive=nil
                if not current()then return end
                image.earlyDone=true
                local stamp=require('readinknative/pagination').fileStamp(image.path)
                if stamp~=image.stamp and not image.prefetch then
                    a.pendingImageReload=image.document;image.stamp=stamp
                    a.readerImageWatch={document=image.document,stamp=stamp};a:draw()
                end
                if result.ok and result.value.images.pending then
                    -- The first two original illustrations can be displayed
                    -- while the rest are still pending. This is progress,
                    -- not a failed attempt or a reason to request a bundle.
                    r[slot]=image;r.imageAfter=require('socket').gettime()+0.25
                elseif not result.ok or not result.value.images.complete then
                    image.failures=image.failures+1
                    if image.failures<3 then r[slot]=image;r.imageAfter=require('socket').gettime()+5*image.failures end
                    require('logger').info('ReadInk current illustration repair deferred attempts:',image.failures)
                else require('logger').info('ReadInk current illustrations ready:',result.value.images.downloaded)end
            end,writes)
            return
        end
    end
    if not r.active then
        local key=table.remove(r.pending,1)
        if not key then
            local task=r.pageTask;r.pageTask=nil
            if task then
                local current=require('readinknative/pagination').spec(a)
                if not current or current.key~=task.spec.key then return end
                if a.mode~='reader'or a.toolbar or a.panel or a.textSelection then r.pageTask=task;schedule(a,r,2);return end
                local clock=require('ui/time');local wait=r.pageAfter and r.pageAfter-clock.monotonic()or 0
                if wait>0 then r.pageTask=task;schedule(a,r,clock.to_s(wait));return end
                r.pageActive=task;r.pageOnly=true
                work(a,r,function(c)
                    local words
                    if task.spec.needMetadata then
                        local ok,chapters=pcall(require('readinknative/api').catalog,c,task.spec.book)
                        if ok then
                            local map={};for _,ch in ipairs(chapters)do map[tostring(ch.chapterUid)]=ch end
                            words={}
                            for _,ch in ipairs(task.spec.chapters)do
                                local fresh=map[tostring(ch.chapterUid)]
                                if fresh and type(fresh.wordCount)=='number'then ch.wordCount=fresh.wordCount;words[tostring(ch.chapterUid)]=fresh.wordCount end
                            end
                        end
                    end
                    local index=require('readinknative/pagination').build(task.spec,task.index,1)
                    return{index=index,words=words}
                end,function(result)
                    r.pageActive=nil
                    if result.ok then
                        local current=require('readinknative/pagination').spec(a)
                        if current and current.key==task.spec.key then
                            local value=result.value
                            if value.words then for _,ch in ipairs(a.chapters)do
                                local w=value.words[tostring(ch.chapterUid)];if w~=nil then ch.wordCount=w end
                            end end
                            a.pageIndex=value.index
                            if value.index.pending then
                                current.needMetadata=nil;r.pageTask={spec=current,index=value.index};r.pageAfter=require('ui/time').monotonic()+require('ui/time').s(4)
                            end
                        end
                    end
                end)
            end
            return
        end
        local q=queues(a)[key];if not q or q.status~=1 then schedule(a,r);return end
        r.active={q=q,cursor=1}
    end
    local ctx=r.active;local q=ctx.q
    if not ctx.info then
        q.status=1
        work(a,r,function(c)local A=require('readinknative/api');local b=A.info(c,q.book);return{book=b,chapters=A.catalog(c,b)}end,function(result)
            if not result.ok then q.status=5;q.error=result.error;r.active=nil;O.notice(a,'下载失败，请联网后重试','icon_toolbar_download_error');return end
            local b,all=result.value.book,result.value.chapters
            ctx.info=b;q.book=copyBook(b);q.version=b.version;q.chapters={};q.total=#all;q.completed={};q.error=nil;q.expiresAt=nil
            a.state.catalogs[id(b)]=all;updateBook(a,b)
            for _,ch in ipairs(all)do
                local mode=require('readinknative/permission').mode(b,ch,r.vid)
                local index,limit=tonumber(ch.chapterIdx),tonumber(b.maxFreeChapter)
                -- Only known readable content; never probe every locked chapter.
                if mode=='full'or(mode=='preview'and index and limit and index<=limit)then
                    local entry={};for k,v in pairs(ch)do entry[k]=v end;entry.offlineMode=mode;q.chapters[#q.chapters+1]=entry
                end
            end
            q.status=2
            if #q.chapters==0 then q.status=5;q.error='READING_PERMISSION_REQUIRED';r.active=nil;O.notice(a,'本书暂无可下载内容','icon_toolbar_download_error')end
        end)
        return
    end
    local ch=q.chapters[ctx.cursor]
    if not ch then
        local full=#q.chapters==q.total
        for _,entry in ipairs(q.chapters)do if entry.offlineMode~='full'then full=false end end
        q.status=full and 3 or 4;q.updated=os.time();q.checkedAt=q.updated;r.active=nil
        -- Every chapter and image was just verified in the worker/queue pass.
        a.offlineVerified=a.offlineVerified or{};a.offlineVerified[q.bookId]=q
        if a.book and id(a.book)==q.bookId and a.mode=='reader'and a.document then require('readinknative/pagination').request(a)end
        O.notice(a,'已下载本书全部可阅读内容','icon_toolbar_download_done');persist(a);schedule(a,r);return
    end
    q.status=2
    local Cache=require('readinknative/cache');local Images=require('readinknative/images')
    local path,mode
    -- Inspect committed files in one pass instead of one timer tick per chapter.
    local checked=0;local started=require('socket').gettime()
    while ch do
        path,mode=Cache.find(r.vid,ctx.info,ch)
        if not(path and(mode=='full'or ch.offlineMode=='preview')and Images.ready(path))then break end
        if not require('readinknative/underlineseed').ready(r.vid,ctx.info,ch,path)then break end
        q.completed[tostring(ch.chapterUid)]=mode;ctx.cursor=ctx.cursor+1
        local expiry=Cache.accessExpiry(r.vid,ctx.info,ch)
        if expiry then q.expiresAt=math.min(q.expiresAt or expiry,expiry)end
        ch=q.chapters[ctx.cursor];checked=checked+1
        -- A 350-chapter cache must yield between bounded storage checks. Never
        -- walk the complete book in one UI event or rewrite state per chapter.
        if ch and(checked>=8 or require('socket').gettime()-started>=0.01)then schedule(a,r,0.01);return end
    end
    if not ch then persist(a);return O.pump(a,r)end
    local batch={ch}
    local words=tonumber(ch.wordCount)
    if not path then
        for index=ctx.cursor+1,math.min(#q.chapters,ctx.cursor+4)do
            local nextChapter=q.chapters[index];local nextWords=tonumber(nextChapter.wordCount)
            if compact and(not words or words<0 or words>1200 or not nextWords or nextWords<0 or nextWords>400 or words+nextWords>1200)then break end
            if Cache.find(r.vid,ctx.info,nextChapter)then break end
            batch[#batch+1]=nextChapter;words=words and nextWords and words+nextWords or nil
        end
    end
    local writes={bookId=id(ctx.info),version=tostring(ctx.info.version or 0),uids={},short=words and words<=1200 or false}
    for _,entry in ipairs(batch)do writes.uids[tostring(entry.chapterUid)]=true end
    work(a,r,function(c)
        local results
        if path and(mode=='full'or ch.offlineMode=='preview')then
            local file,images=require('readinknative/content').repair(path)
            results={{path=file,images=images,mode=mode,book=ctx.info,chapter=ch}}
        else results=require('readinknative/api').prepareChapters(c,ctx.info,batch,true)end
        if require('readinknative/relatededitions').isCB(ctx.info)then
            for _,value in ipairs(results)do
                local ok,seed=pcall(require('readinknative/underlineseed').prepare,c,value.book or ctx.info,value.chapter,value.path,q.chapters)
                value.underlineSeedReady=ok
                if not ok then require('logger').info('ReadInk downloaded chapter thoughts deferred:',require('readinknative/errors').code(seed))end
            end
        end
        return results
    end,function(result)
        if not result.ok then
            q.status=5;q.error=result.error;r.active=nil
            O.notice(a,'下载失败，请联网后重试','icon_toolbar_download_error');return
        end
        if a.offlineVerified then a.offlineVerified[q.bookId]=nil end
        if a.pageIndex then a.pageIndex.cacheStamp=nil end
        for _,value in ipairs(result.value)do
            local images=value.images
            if images and images.changed and a.document and a.document.path==value.path then a.pendingImageReload=a.document end
            if images and not images.complete then
                q.status=5;q.error='IMAGES_INCOMPLETE';r.active=nil
                O.notice(a,'图片未下载完整，请重试','icon_toolbar_download_error');return
            end
            local fresh=value.book or ctx.info
            if tostring(fresh.version)~=tostring(q.version)then
                q.status=5;q.error='BOOK_UPDATED';q.book=copyBook(fresh);q.version=fresh.version;r.active=nil;updateBook(a,fresh)
                O.notice(a,'图书已更新，请重新下载','icon_toolbar_download_error');return
            end
            ctx.info=fresh
            local completed=q.chapters[ctx.cursor]
            completed.offlineMode=value.mode;q.completed[tostring(completed.chapterUid)]=value.mode
            local expiry=Cache.accessExpiry(r.vid,ctx.info,completed)
            if expiry then q.expiresAt=math.min(q.expiresAt or expiry,expiry)end
            q.updated=os.time();ctx.cursor=ctx.cursor+1
        end
        if a.mode=='reader'and a.document and a.chapter and a.book and id(a.book)==writes.bookId and not a.chapterLoading then require('readinknative/chapterloader').next(a)end
    end,writes)
end
function O.start(a,books)
    local pdfs,others={},{}
    for _,b in ipairs(books)do if not b.localFile and require('readinknative/pdfbooks').isPdf(b)then pdfs[#pdfs+1]=b else others[#others+1]=b end end
    if #pdfs>0 then
        if not a.client:ready()then a:message('请先登录微信读书。');return false end
        local state,vid=a.state,a.client.data.vid;local owned={};local owner={}
        require('readinknative/pdfbooks').cancel(a);a.pdfDownloads=a.pdfDownloads or{};a.pdfFailures=a.pdfFailures or{}
        for _,b in ipairs(pdfs)do a.pdfDownloads[id(b)]=owner;a.pdfFailures[id(b)]=nil end
        local function clear(failed)for _,b in ipairs(pdfs)do if a.pdfDownloads[id(b)]==owner then a.pdfDownloads[id(b)]=nil;a.pdfFailures[id(b)]=failed or nil end end end
        for _,b in ipairs(state.books or{})do if not b.localFile then owned[id(b)]=true end end
        return a:remote('准备 PDF 文字版下载',function(client)
            local result={}
            for _,b in ipairs(pdfs)do
                local text=require('readinknative/pdftext');local options={fromShelf=owned[id(b)]==true}
                local position=state:position(b,nil);if position and position.pdf then options.page=position.page end
                local last=state.last[id(b)];options.resumeChapterUid=last and last.chapterUid
                local ok,value=pcall(text.prepare,client,b,options)
                if ok then result[#result+1]={text=value}
                else result[#result+1]={original=require('readinknative/pdfcache').fetch(client,b,owned[id(b)]==true)}end
            end
            return result
        end,function(results)
            clear(false)
            for _,result in ipairs(results)do
                if result.text then require('readinknative/pdftext').remember(a,result.text);others[#others+1]=result.text.book
                elseif result.original then
                    local info=result.original.book
                    for _,b in ipairs(state.books or{})do if id(b)==id(info)then for k,v in pairs(info)do if k:sub(1,1)~='_'then b[k]=v end end end end
                end
            end
            state:flush();if #others>0 then O.start(a,others)else a:draw()end
        end,nil,{valid=function()return not a.closed and not a.suspended and a.state==state and a.client.data.vid==vid end,
            failed=function(err)clear(true);if not a.closed then a:failure(err);a:draw()end end,
            cancelled=function()clear(false);if not a.closed then a:draw()end end})
    end
    if not a.client:ready()then a:message('请先登录微信读书。');return false end
    local r=runtime(a);local added=0
    for _,b in ipairs(books)do
        if not b.localFile then
            local status=O.displayStatus(a,b)
            if status~=1 and status~=2 and status~=3 and status~=4 then
                local q={schema=2,bookId=id(b),book=copyBook(b),title=b.title,version=b.version,status=1,chapters={},completed={}}
                queues(a)[q.bookId]=q;r.pending[#r.pending+1]=q.bookId;added=added+1
            end
        end
    end
    if added>0 and r.pageActive then r.jobs:cancel();r.pageTask=r.pageActive;r.pageActive=nil;r.busy=false end
    persist(a);a:draw();schedule(a,r);return added>0
end
function O.autoStart(a,connected)
    local book=a.book
    if not book or book.localFile or a.closed or a.suspended or a.autoDownloadBook==book or not a.client:ready()then return end
    if not require('device'):isKindle()then return end
    local onShelf=false;for _,b in ipairs(a.state.books or{})do if id(b)==id(book)and not b.localFile then onShelf=true;break end end
    if not onShelf then return end
    local existing=O.queue(a,book)
    if existing and existing.schema==2 and(existing.status==3 or existing.status==4)then
        a.autoDownloadBook=book;local state,vid=a.state,a.client.data.vid
        O.checkCompleted(a,{book},function()
            if not a.closed and not a.suspended and a.mode=='reader'and a.book==book and a.state==state and a.client.data.vid==vid and existing.status==0 then
                a.autoDownloadBook=nil;O.autoStart(a)
            end
        end);return
    end
    local network=require('ui/network/manager')
    local device=require('device')
    if device:hasBattery()then
        local power=device:getPowerDevice();if not power:isCharging()and power:getCapacity()<=30 then return end
    end
    local disk=require('util').diskUsage(a.state.root)
    if disk.available and disk.available<100*1024*1024 then return end
    if not connected and(not network:isWifiOn()or not network:isConnected())then
        if a.autoDownloadWaiting then return end
        local owner={state=a.state,book=book,vid=a.client.data.vid};a.autoDownloadWaiting=owner;a:draw()
        network:runWhenConnected(function()
            if a.autoDownloadWaiting~=owner then return end
            a.autoDownloadWaiting=nil
            if a.state==owner.state and a.book==book and a.client.data.vid==owner.vid and a.mode=='reader'and not a.closed and not a.suspended then O.autoStart(a,true)end
        end)
        return
    end
    a.autoDownloadWaiting=nil;a.autoDownloadBook=book
    local q=O.queue(a,book)
    O.start(a,{book})
end
function O.stop(a,b)
    if require('readinknative/pdfbooks').isPdf(b)then require('readinknative/pdfbooks').cancel(a);a:draw();return end
    if a.autoDownloadWaiting and a.autoDownloadWaiting.book==b then a.autoDownloadWaiting=nil;a.autoDownloadBook=b end
    local r=a.offlineRuntime;local q=O.queue(a,b);if not q then return end
    q.status=0
    if r and same(a,r)then
        if r.active and r.active.q==q then r.jobs:cancel();r.busy=false;r.active=nil end
        for i=#r.pending,1,-1 do if r.pending[i]==id(b)then table.remove(r.pending,i)end end
        schedule(a,r)
    end
    persist(a);a:draw()
end
function O.stopAll(a,deferFlush)
    a.readerImageDocument=nil
    a.autoDownloadWaiting=nil
    if a.offlineNoticeTask then require('ui/uimanager'):unschedule(a.offlineNoticeTask);a.offlineNoticeTask=nil end
    a.offlineNotice=nil
    local r=a.offlineRuntime;if not r then return end
    if r.timer then require('ui/uimanager'):unschedule(r.timer)end
    if r.documentWait then require('ui/uimanager'):unschedule(r.documentWait);r.documentWait=nil end
    r.jobs:cancel()
    local changed=false
    for _,q in pairs(r.state.offlineQueues or{})do if q.status==1 or q.status==2 then q.status=0;changed=true end end
    a.offlineRuntime=nil
    if changed and(not deferFlush or r.state~=a.state)then(r.state.flushOffline or r.state.flush)(r.state)end
    return changed and r.state==a.state
end
function O.toggle(a,b)
    b=b or a.book;if not b or b.localFile then return end
    local status=O.displayStatus(a,b)
    if status==1 or status==2 then O.stop(a,b);O.notice(a,'已取消下载')
    elseif status==3 or status==4 then O.notice(a,'本书已下载','icon_toolbar_download_done')
    elseif O.start(a,{b})then O.notice(a,'已开始下载本书所有可阅读内容')end
    if a.mode=='reader'then a.toolbar=false;a.panel=nil end;a:draw()
end
function O.progress(a,b)
    local status=O.displayStatus(a,b);local q=b and O.queue(a,b);local done,total=0,q and #(q.chapters or{})or 0
    for _ in pairs(q and q.completed or{})do done=done+1 end
    local percent=(status==3 or status==4)and 100 or math.min(99,math.floor(done/math.max(1,total)*100))
    return{status=status,done=done,total=total,percent=percent}
end
function O.selectionState(a,books)
    local out={online={},start=false,stop=false,done=0,total=0,failed=false}
    for _,b in ipairs(books)do if not b.localFile then
        out.online[#out.online+1]=b;local p=O.progress(a,b)
        out.done=out.done+p.done;out.total=out.total+p.total
        if p.status==0 or p.status==5 then out.start=true elseif p.status==1 or p.status==2 then out.stop=true end
        if p.status==5 then out.failed=true end
    end end
    out.action=out.start and'start'or out.stop and'stop'or'done'
    out.percent=out.action=='done'and 100 or math.min(99,math.floor(out.done/math.max(1,out.total)*100))
    out.icon=out.action=='stop'and'icon_toolbar_downloading'or out.action=='done'and'icon_toolbar_download_done'or out.failed and'icon_toolbar_download_error'or'icon_toolbar_download_start'
    return out
end
function O.shelfAction(a)
    local selected=require('readinknative/shelfmodel').selected(a)
    local state=O.selectionState(a,selected)
    if #state.online==0 then a:message('请选择需要下载的线上书籍。');return end
    if state.action=='start'then O.start(a,state.online);O.notice(a,'开始下载选中书籍')
    elseif state.action=='stop'then for _,b in ipairs(state.online)do O.stop(a,b)end;O.notice(a,'停止下载选中书籍')
    else O.notice(a,'已离线全部可阅读内容','icon_toolbar_download_done')end
    a.shelfEditing=false;a.shelfSelection={};a:draw()
end
function O.invalidate(a)
    O.stopAll(a);a.offlineVerified={};a.pageIndex=nil
    for _,q in pairs(queues(a))do q.status=0 end
end
function O.readerButton(v,bb,x,y,w,h,size)
    local a=v.app;local icon,_,status=O.presentation(a,a.book)
    size=size or 28
    if status==2 then v:downloadCircle(bb,O.progress(a,a.book).percent,x,y,w,h,size)
    else local n=(status==3 or status==4)and 30 or size;v:icon(bb,icon,x,y,w,h,nil,nil,{w=n,h=n})end
    v:hit({x=x,y=y,w=w,h=h},function()O.toggle(a)end)
end
function O.readerBadge(v,bb)
    local a,l=v.app,v.layout;local s=l.s
    if a.toolbar or not a.book or a.book.localFile then return false end
    local status=O.displayStatus(a,a.book);local note=a.offlineNotice;local terminal=note and(note.icon=='icon_toolbar_download_done'or note.icon=='icon_toolbar_download_error')
    if status~=1 and status~=2 and not terminal then return false end
    local done=terminal and note.icon=='icon_toolbar_download_done';local dark=terminal and status~=1 and status~=2
    local label=dark and(done and'已下载'or'下载失败')or'正在下载'
    local w=s(done and 76 or 90);local h=s(20);local x=l.w-l.side-w-require('readinknative/readerstatus').width(a);local y=s(4);local BB=require('ffi/blitbuffer')
    bb:paintRoundedRect(x,y,w,h,dark and BB.COLOR_BLACK or BB.COLOR_WHITE,math.floor(h/2))
    local ix=x+s(5);local iy=y+s(5)
    if status==2 and not dark then v:downloadCircle(bb,O.progress(a,a.book).percent,ix,iy,s(10),s(10),10)
    else
        if dark then bb:paintRect(ix,iy,s(10),s(10),BB.COLOR_WHITE)end
        v:icon(bb,dark and(done and'icon_bookshelf_downloaded'or'icon_bookshelf_error')or'icon_bookshelf_pre_download',ix,iy,s(10),s(10),nil,nil,{w=10,h=10})
        if dark then bb:invertRect(ix,iy,s(10),s(10))end
    end
    v:text(bb,label,x+s(20),y+s(2),w-s(25),s(12),false,1,dark and BB.COLOR_BLACK or nil,dark and BB.COLOR_WHITE or nil)
    v:hit({x=x,y=y,w=w,h=h},function()O.toggle(a)end)
    return true
end
function O.paintNotice(v,bb)
    local a,l=v.app,v.layout;local s=l.s;local note=a.offlineNotice
    if not note then return end
    if a.mode=='reader'and(note.icon=='icon_toolbar_download_done'or note.icon=='icon_toolbar_download_error')then return end
    local BB=require('ffi/blitbuffer');local w=math.min(l.w-2*l.side,s(340));local h=s(64);local x=(l.w-w)/2;local y=l.h-l.bottom-s(88)
    bb:paintRect(x,y,w,h,BB.COLOR_BLACK)
    local ix=x+s(16);local iy=y+(h-s(28))/2
    bb:paintRect(ix,iy,s(28),s(28),BB.COLOR_WHITE)
    v:icon(bb,note.icon,ix,iy,s(28),s(28),nil,nil,{w=24,h=24});bb:invertRect(ix,iy,s(28),s(28))
    v:text(bb,note.text,x+s(56),y+s(12),w-s(68),s(14),false,2,BB.COLOR_BLACK,BB.COLOR_WHITE,nil,'center')
end
return O
