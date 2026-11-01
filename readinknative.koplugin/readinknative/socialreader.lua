-- Range fetching remains cancellable. Small-memory readers may resolve a
-- bounded number of cached candidates during input, never inside paint.
local S={PRIORITY_SECONDS=8,AHEAD=3,BEHIND=1}
local function copyRows(rows)
    local out={};for _,row in ipairs(rows)do local r={};for k,v in pairs(row)do if k~='geometry'and k~='firstPage'and k~='lastPage'then r[k]=v end end;out[#out+1]=r end;return out
end
local function remember(a,c)
    local bytes=require('readinknative/underlinecache').bytes(c.rows);if not bytes then return end
    a.socialReaderAnchors=a.socialReaderAnchors or{};a.socialReaderCache=a.socialReaderCache or{};a.socialReaderOrder=a.socialReaderOrder or{};a.socialReaderSizes=a.socialReaderSizes or{};a.socialReaderDirty=a.socialReaderDirty or{}
    for i=#a.socialReaderOrder,1,-1 do if a.socialReaderOrder[i]==c.cacheKey then table.remove(a.socialReaderOrder,i)end end
    a.socialReaderPartial=a.socialReaderPartial or{};a.socialReaderPartial[c.cacheKey]=c.enrichPending or nil
    a.socialReaderDirty[c.cacheKey]=c.cacheDirty or nil;a.socialReaderCache[c.cacheKey]=copyRows(c.rows);a.socialReaderSizes[c.cacheKey]=bytes+(c.anchor and #c.anchor.text+#c.anchor.blocks*32 or 0);a.socialReaderAnchors[c.cacheKey]=c.anchor;a.socialReaderOrder[#a.socialReaderOrder+1]=c.cacheKey
    local total=0;for _,key in ipairs(a.socialReaderOrder)do total=total+(a.socialReaderSizes[key]or 0)end
    while #a.socialReaderOrder>6 or total>1024*1024 do
        local key=table.remove(a.socialReaderOrder,1);total=total-(a.socialReaderSizes[key]or 0);a.socialReaderCache[key]=nil;a.socialReaderSizes[key]=nil;a.socialReaderDirty[key]=nil;a.socialReaderAnchors[key]=nil;a.socialReaderPartial[key]=nil
    end
end
local function same(a,o)
    return o and not a.closed and not a.suspended and a.state==o.state and a.document==o.document and a.book==o.book
        and a.chapter==o.chapter and tostring(a.chapter.chapterUid)==o.uid and tostring(a.book.bookId)==o.bookId
        and tostring(a.book.version or 0)==o.version and tostring(a.client.data.vid)==o.vid and(not o.expires or os.time()<o.expires)
end
function S.current(a)if same(a,a.socialReader)then return a.socialReader end end
function S.hidden(a)return(a.state.socialDisplay or{})[tostring(a.book.bookId)]==false end
function S.cancel(a)
    local c=a.socialReader
    if c then c.loading=false;c.runningPage=nil;c.pageRequest=nil;c.ahead=nil;c.cacheSaving=nil;c.enriching=nil
        if c.aheadTask then require('ui/uimanager'):unschedule(c.aheadTask);c.aheadTask=nil end
        if c.enrichTask then require('ui/uimanager'):unschedule(c.enrichTask);c.enrichTask=nil end
    end
    if a.socialReaderJobs then a.socialReaderJobs:cancel()end
    if a.socialReaderTask then require('ui/uimanager'):unschedule(a.socialReaderTask);a.socialReaderTask=nil end
    if a.socialReaderRetryTask then require('ui/uimanager'):unschedule(a.socialReaderRetryTask);a.socialReaderRetryTask=nil end
    if a.socialReaderMapTask then require('ui/uimanager'):unschedule(a.socialReaderMapTask);a.socialReaderMapTask=nil end
end
local function geometryKey(d)
    local f=d.format or{};local parts={d.w,d.h,d.doc:getVisiblePageCount(),tostring(d.doc.default_font)}
    parts[#parts+1]=require('readinknative/format').signature(f)
    return table.concat(parts,':')
end
local function pageKey(c)
    local d=c.document
    return(d.isScroll and d:isScroll()and('scroll:'..d:scrollPos())or tostring(d:page()))..':'..geometryKey(d)
end
S.pageKey=pageKey
function S.start(a,force)
    if a.book.localFile or not a.chapter or not a.document or not a.client:ready()or S.hidden(a)then return end
    local c=S.current(a)
    if c and not force and(c.loaded or c.loading or c.error)then if c.loaded then S.input(a)end;return end
    S.cancel(a)
    c={state=a.state,book=a.book,bookId=tostring(a.book.bookId),chapter=a.chapter,uid=tostring(a.chapter.chapterUid),document=a.document,vid=tostring(a.client.data.vid),version=tostring(a.book.version or 0),rows={},mapped={}}
    c.coordinateIndex=require('device'):isKindle()or a.coordinateIndex==true
    c.loading=true;a.socialReader=c
    local UI=require('ui/uimanager');local UC=require('readinknative/underlinecache');local clock=require('socket')
    if require('readinknative/cache').find(c.vid,c.book,c.chapter)~=c.document.path then c.loading=false;c.error='SOCIAL_READING_CACHE_CHANGED';return end
    c.expires=require('readinknative/cache').accessExpiry(c.vid,c.book,c.chapter)
    c.fileStamp=require('readinknative/pagination').fileStamp(c.document.path)
    c.cacheKey=table.concat({c.vid,c.bookId,c.version,c.uid,c.fileStamp or''},':')..(require('readinknative/relatededitions').isCB(c.book)and ':cb3'or '');c.started=clock.gettime();c.openStarted=c.started
    local function valid()
        if not same(a,c)or a.socialReader~=c then return end
        if require('readinknative/pagination').fileStamp(c.document.path)~=c.fileStamp then c.loading=false;c.error='SOCIAL_READING_CACHE_CHANGED';return end
        return true
    end
    local function saveRows(rows)
        local Cache=require('readinknative/cache')
        if Cache.find(c.vid,c.book,c.chapter)==c.document.path and require('readinknative/pagination').fileStamp(c.document.path)==c.fileStamp then return UC.save(c,rows,nil,c.anchor,{partial=c.enrichPending})end
        return false
    end
    local function mapped(row)
        local p=row.position;local d=c.document.doc
        if p and d:isXPointerInDocument(p.xpointer)and d:isXPointerInDocument(p.endXPointer)then
            row.firstPage=d:getPageFromXPointer(p.xpointer);row.lastPage=d:getPageFromXPointer(p.endXPointer)
            row.geometry=geometryKey(c.document)
            c.mappedSet=c.mappedSet or{}
            if not c.mappedSet[row]then c.mappedSet[row]=true;c.mapped[#c.mapped+1]=row end
            return c.document.isScroll and c.document:isScroll()or row.firstPage<=c.document:page()+d:getVisiblePageCount()-1 and row.lastPage>=c.document:page()
        elseif p then row.position=nil;row.resolved=nil;c.noSearch=false;c.cacheDirty=true;c.cacheRevision=(c.cacheRevision or 0)+1 end
    end
    local function repaint()
        if not c.firstPaint then c.firstPaint=true;require('logger').info('ReadInk underline first visible total ms/cache:',math.floor((clock.gettime()-(c.openStarted or c.started))*1000),c.cached or false)end
        a:draw()
    end
    local function mapCached()
        a.socialReaderMapTask=nil
        if not valid()or not c.mapQueue or S.hidden(a)or a.mode~='reader'then return end
        if a.panel or a.textSelection then return end
        local changed=false;local deadline=clock.gettime()+0.006;local count=0
        while c.mapIndex<=#c.mapQueue do
            if mapped(c.mapQueue[c.mapIndex])then changed=true end
            c.mapIndex=c.mapIndex+1;count=count+1
            if count>=32 or clock.gettime()>=deadline then break end
        end
        if changed then repaint()end
        if c.mapIndex<=#c.mapQueue then a.socialReaderMapTask=mapCached;UI:scheduleIn(0.01,mapCached)else c.mapQueue=nil;if c.coordinateIndex and c.scheduleAhead then c.scheduleAhead()end end
    end
    c.resumeMap=function()
        if c.mapQueue and not a.socialReaderMapTask then a.socialReaderMapTask=mapCached;UI:scheduleIn(0.01,mapCached)end
    end
    local function keyFor(page)return tostring(page)..':'..geometryKey(c.document)end
    c.keyForPage=keyFor
    local function markDone(key,prepared)
        c.pageDone=c.pageDone or{};c.pageOrder=c.pageOrder or{};c.prepared=c.prepared or{}
        if not c.pageDone[key]then c.pageOrder[#c.pageOrder+1]=key end
        c.pageDone[key]=true;if prepared then c.prepared[key]=true end
        while #c.pageOrder>32 do local old=table.remove(c.pageOrder,1);c.pageDone[old]=nil;c.prepared[old]=nil end
    end
    local function indexNeeded()
        if not c.coordinateIndex or c.coordinateAttempted or c.anchor and c.anchor.coordinateAttempted then return false end
        for _,row in ipairs(c.rows)do if not row.position and type(row.quote)=='string'and row.quote~=''then return true end end
        return false
    end
    local function refreshPending()
        c.noSearch=true
        if indexNeeded()then c.noSearch=false;return end
        for _,row in ipairs(c.rows)do
            if row.needsFragments or not row.position and not row.resolved and type(row.quote)=='string'and row.quote~=''then c.noSearch=false;break end
        end
    end
    local function applyUpdate(u)
        local row=c.rows[u.index]
        if u.enriched then row.quote=u.quote;row.endpoints=u.endpoints;row.needsFragments=nil end
        row.position=u.position;row.resolved=u.resolved
        if u.indexed then return false end -- Map in bounded UI chunks below.
        return mapped(row)
    end
    local function acceptCoordinates(result)
        if result.coordinateAttempted then c.coordinateAttempted=true end
        if not result.coordinates or result.coordinates==0 then return end
        c.mapQueue={};c.mapIndex=1
        for _,row in ipairs(c.rows)do if row.position and not(c.mappedSet and c.mappedSet[row])then c.mapQueue[#c.mapQueue+1]=row end end
        local page=c.document:page()
        table.sort(c.mapQueue,function(x,y)return math.abs(x.position.page-page)<math.abs(y.position.page-page)end)
        c.resumeMap()
    end
    -- The worker slot is shared with idle lookahead/cache saves. A page key
    -- alone is not proof of an active request: cancelled/replaced epochs must
    -- never leave a phantom "already loading" owner behind.
    local function pageRunning()
        local owner=c.pageRequest;local job=a.socialReaderJobs
        if not owner or not job or owner.geometry~=geometryKey(c.document)or(owner.epoch and owner.epoch~=job.epoch)or not job.widget then
            c.pageRequest=nil;c.runningPage=nil;return false
        end
        return true
    end
    local function cancelPage()
        c.pageRequest=nil;c.runningPage=nil
        if a.socialReaderJobs then a.socialReaderJobs:cancel()end
    end
    local function cancelAhead()
        if c.aheadTask then UI:unschedule(c.aheadTask);c.aheadTask=nil end
        local owner=c.ahead;c.ahead=nil
        if owner and a.socialReaderJobs and(not owner.epoch or owner.epoch==a.socialReaderJobs.epoch)then a.socialReaderJobs:cancel()end
    end
    local function persistIdle()
        if not valid()or not c.cacheDirty or pageRunning()or not c.complete or c.ahead or c.enriching or a.mode~='reader'then return end
        a.socialReaderJobs=a.socialReaderJobs or require('readinknative/inkjobs').new()
        if c.cacheSaving and c.cacheSaving.epoch==a.socialReaderJobs.epoch then return end
        local owner={revision=c.cacheRevision};c.cacheSaving=owner
        a.socialReaderJobs:run('',function()return saveRows(c.rows)and true or false end,function(ok,saved)
            if not valid()or c.cacheSaving~=owner then return end
            c.cacheSaving=nil
            if ok and saved and c.cacheRevision==owner.revision then c.cacheDirty=false;if a.socialReaderDirty then a.socialReaderDirty[c.cacheKey]=nil end end
        end,false)
        owner.epoch=a.socialReaderJobs.epoch
    end
    local requestPage,scheduleAhead,runAhead,accept,scheduleEnrich
    scheduleAhead=function(delay)
        if not valid()or S.hidden(a)or c.ahead or c.aheadTask or not c.loaded or pageRunning()then return end
        if c.enrichPending then scheduleEnrich();return end
        -- A scroll viewport can straddle arbitrary page boundaries. Keep
        -- mapped anchors, but do not mark page-based lookahead as its result.
        if c.document.isScroll and c.document:isScroll()then persistIdle();require('readinknative/chapterloader').next(a);return end
        if c.noSearch and not c.mapQueue then
            local page=c.document:page()
            for delta=-S.BEHIND,S.AHEAD do local p=page+delta;if p>=1 and p<=c.document:count()then markDone(keyFor(p),true)end end
            persistIdle();require('readinknative/chapterloader').next(a);return
        end
        if require('readinknative/chapterloader').compact(a)then persistIdle();require('readinknative/chapterloader').next(a);return end
        if #c.rows==0 then persistIdle();require('readinknative/chapterloader').next(a);return end
        c.aheadTask=function()
            c.aheadTask=nil
            if not valid()or pageRunning()or a.mode~='reader'or a.panel or a.textSelection or not c.pageDone or not c.pageDone[pageKey(c)]then return end
            if c.noSearch and not c.mapQueue then scheduleAhead();return end
            local page=c.document:page();local target
            for step=1,S.AHEAD do local nextPage=page+step;if nextPage<=c.document:count()and not c.pageDone[keyFor(nextPage)]then target=nextPage;break end end
            if not target then for step=1,S.BEHIND do local prev=page-step;if prev>=1 and not c.pageDone[keyFor(prev)]then target=prev;break end end end
            if target then
                local owner={page=target,key=keyFor(target),geometry=geometryKey(c.document),started=clock.gettime(),searches=0}
                c.ahead=owner;runAhead(owner)
            else persistIdle();require('readinknative/chapterloader').next(a)end
        end
        UI:scheduleIn(delay or 0.05,c.aheadTask)
    end
    runAhead=function(owner)
        if not valid()or c.ahead~=owner or owner.geometry~=geometryKey(c.document)then return end
        if pageRunning()or a.mode~='reader'or a.panel or a.textSelection then c.ahead=nil;return end
        owner.indexing=indexNeeded()
        if not owner.indexing and pageKey(c)~=owner.key and not(c.pageDone and c.pageDone[pageKey(c)])then
            c.ahead=nil;c.schedulePage(0.01);return
        end
        require('readinknative/chapterloader').pause(a)
        a.socialReaderJobs=a.socialReaderJobs or require('readinknative/inkjobs').new()
        local epoch
        a.socialReaderJobs:run('',function()
            assert(require('readinknative/cache').find(c.vid,c.book,c.chapter)==c.document.path,'SOCIAL_READING_CACHE_CHANGED')
            -- Only the fork changes page. The parent keeps the visible body,
            -- selection, progress and chapter; no document open/render or RPC.
            c.document:jump(owner.page)
            assert(c.document:page()==owner.page,'SOCIAL_PAGE_CHANGED')
            return require('readinknative/underlinepage').batch(c.document,c.rows,owner.pending,c.book,c.chapter,c.anchor,{coordinates=owner.indexing})
        end,function(ok,result)
            if not valid()or c.ahead~=owner or(epoch and epoch~=a.socialReaderJobs.epoch)then return end
            if owner.geometry~=geometryKey(c.document)then c.ahead=nil;c.schedulePage();return end
            if not ok then c.ahead=nil;require('logger').info('ReadInk underline lookahead deferred');if owner.indexing or pageKey(c)==owner.key then c.schedulePage(0.15)end;return end
            if result.anchor then
                if not c.anchor then c.cacheDirty=true;c.cacheRevision=(c.cacheRevision or 0)+1 end
                c.anchor=result.anchor;remember(a,c)
            end
            local changed=false
            for _,u in ipairs(result.updates)do if applyUpdate(u)then changed=true end end
            acceptCoordinates(result)
            refreshPending()
            c.searches=(c.searches or 0)+result.searches;owner.searches=owner.searches+result.searches;owner.pending=result.remaining
            if #result.updates>0 then c.cacheDirty=true;c.cacheRevision=(c.cacheRevision or 0)+1;remember(a,c)end
            if changed then repaint()end
            if owner.indexing and pageKey(c)~=owner.key then
                if not result.more then markDone(owner.key,true)end
                c.ahead=nil;c.schedulePage(0.01);return
            end
            if result.more then
                c.aheadTask=function()c.aheadTask=nil;runAhead(owner)end;UI:scheduleIn(0.01,c.aheadTask)
            else
                markDone(owner.key,true);c.ahead=nil
                if pageKey(c)==owner.key then c.completedPage=owner.key;c.complete=true;c.loading=false end
                require('logger').info('ReadInk underline lookahead ready page/searches/ms:',owner.page,owner.searches,math.floor((clock.gettime()-owner.started)*1000))
                scheduleAhead()
            end
        end,false)
        epoch=a.socialReaderJobs.epoch;owner.epoch=epoch
    end
    c.scheduleAhead=scheduleAhead
    c.onMoved=function()
        local page=c.document:page();local key=pageKey(c)
        -- A chapter index is useful on every page; rapid turns must not keep
        -- restarting it. Pure old-page searches yield immediately to this page.
        if pageRunning()and c.runningPage~=key and not c.pageRequest.indexing then cancelPage()end
        if c.prepareCurrent then c.prepareCurrent()end
        if c.ahead and(not c.ahead.indexing or c.ahead.geometry~=geometryKey(c.document))and(c.ahead.page<page-S.BEHIND or c.ahead.page>page+S.AHEAD or not(c.pageDone and c.pageDone[key])and c.ahead.key~=key)then cancelAhead()end
        if c.pageDone and c.pageDone[key]then c.completedPage=key;c.complete=true;c.loading=false;scheduleAhead()
        else c.complete=false;c.loading=true;c.schedulePage(0.01)end
    end
    local function schedule(delay)
        if a.socialReaderTask then UI:unschedule(a.socialReaderTask)end
        a.socialReaderTask=function()a.socialReaderTask=nil;requestPage()end
        UI:scheduleIn(delay or 0.03,a.socialReaderTask)
    end
    requestPage=function()
        if not valid()or not c.loaded or S.hidden(a)or a.chapterLoading or a.jobs and a.jobs.widget then return end
        if a.mode~='reader'or a.textSelection or a.panel then c.loading=false;return end
        local key=pageKey(c)
        if pageRunning()and c.runningPage~=key then
            if c.pageRequest.indexing then return end
            cancelPage()
        end
        if c.ahead and c.ahead.indexing and c.ahead.geometry==geometryKey(c.document)then return end
        if c.ahead and(c.ahead.page<c.document:page()-S.BEHIND or c.ahead.page>c.document:page()+S.AHEAD or not(c.pageDone and c.pageDone[key])and c.ahead.key~=key)then cancelAhead()end
        if #c.rows==0 then c.completedPage=key;c.complete=true;c.loading=false;return end
        if c.noSearch and not c.mapQueue then c.completedPage=key;c.complete=true;c.loading=false;markDone(key,true);scheduleAhead();return end
        if c.pageDone and c.pageDone[key]then c.completedPage=key;c.complete=true;c.loading=false;scheduleAhead();return end
        if c.ahead and c.ahead.key==key then c.complete=false;c.loading=true;return end
        if pageRunning()and c.runningPage==key then return end
        -- Page turns preempt the repeatable idle reference pass.
        if c.enriching then c.enriching=nil end
        a.socialReaderJobs=a.socialReaderJobs or require('readinknative/inkjobs').new()
        cancelPage()
        local owner={key=key,geometry=geometryKey(c.document),indexing=indexNeeded()and not c.fastOpening};c.pageRequest=owner
        c.runningPage=key;c.complete=false;c.loading=true
        if c.requestedPage~=key then c.started=clock.gettime();c.requestedPage=key end
        require('readinknative/offline').beforeForeground(a)
        require('readinknative/chapterloader').pause(a)
        local pending=c.pendingPage==key and c.pagePending or nil
        a.socialReaderJobs:run('',function()
            assert(require('readinknative/cache').find(c.vid,c.book,c.chapter)==c.document.path,'SOCIAL_READING_CACHE_CHANGED')
            local result=require('readinknative/underlinepage').batch(c.document,c.rows,pending,c.book,c.chapter,c.anchor,{coordinates=owner.indexing})
            return result
        end,function(ok,result)
            if not valid()or c.pageRequest~=owner or(owner.epoch and owner.epoch~=a.socialReaderJobs.epoch)then return end
            c.pageRequest=nil;c.runningPage=nil
            if owner.geometry~=geometryKey(c.document)then schedule();return end
            if not ok then c.loading=false;c.error='WORKER_FAILED';return end
            c.fastOpening=nil
            if result.anchor then
                if not c.anchor then c.cacheDirty=true;c.cacheRevision=(c.cacheRevision or 0)+1 end
                c.anchor=result.anchor;remember(a,c)
            end
            local changed=false
            for _,u in ipairs(result.updates)do
                if applyUpdate(u)then changed=true end
            end
            acceptCoordinates(result)
            refreshPending()
            c.searches=(c.searches or 0)+result.searches;c.pendingPage=key;c.pagePending=result.remaining
            if #result.updates>0 then c.cacheDirty=true;c.cacheRevision=(c.cacheRevision or 0)+1;remember(a,c)end
            if changed then repaint()end
            if not result.more then markDone(key)end
            if pageKey(c)~=key then schedule();return end
            if result.more then schedule(0.01)
            else
                c.completedPage=key;c.complete=true;c.loading=false
                markDone(key);scheduleAhead()
                require('logger').info('ReadInk page underlines ready ms/searches/rows:',math.floor((clock.gettime()-c.started)*1000),result.searches,#c.rows)
            end
        end,false)
        owner.epoch=a.socialReaderJobs.epoch
    end
    c.requestPage=requestPage;c.schedulePage=schedule
    c.prepareCurrent=function()
        if not valid()or not c.loaded or S.hidden(a)or a.mode~='reader'or a.panel or a.textSelection then return false end
        local key=pageKey(c);if c.pageDone and c.pageDone[key]then return true end
        if c.noSearch and not c.mapQueue then c.completedPage=key;c.complete=true;c.loading=false;markDone(key,true);return true end
        if indexNeeded()then return false end -- Never build an index in input/paint.
        if not require('readinknative/chapterloader').compact(a)then return false end
        if c.ahead or c.aheadTask then cancelAhead()end
        if #c.rows==0 then c.completedPage=key;c.complete=true;c.loading=false;markDone(key,true);scheduleAhead();return true end
        if pageRunning()and c.runningPage==key then return false end
        if pageRunning()then cancelPage()end
        local result=require('readinknative/underlinepage').batch(c.document,c.rows,nil,c.book,c.chapter,c.anchor,{eager=true,budget=2,seconds=0.04})
        if result.deferred then return false end
        if result.anchor then
                if not c.anchor then c.cacheDirty=true;c.cacheRevision=(c.cacheRevision or 0)+1 end
                c.anchor=result.anchor;remember(a,c)
            end
        for _,u in ipairs(result.updates)do applyUpdate(u)end
        refreshPending()
        c.searches=(c.searches or 0)+result.searches
        c.pendingPage=key;c.pagePending=result.remaining
        if #result.updates>0 then c.cacheDirty=true;c.cacheRevision=(c.cacheRevision or 0)+1;remember(a,c)end
        require('logger').info('ReadInk compact current-page searches/more:',result.searches,result.more)
        if not result.more then c.completedPage=key;c.complete=true;c.loading=false;markDone(key,true);scheduleAhead();return true end
        return false
    end
    accept=function(rows,cached,seed,dirty)
        if not valid()then return end
        c.mapped={};c.mappedSet=nil;c.pageDone=nil;c.pageOrder=nil;c.prepared=nil;c.completedPage=nil;c.pendingPage=nil;c.pagePending=nil
        c.rows=copyRows(rows);c.loaded=true;c.fetching=nil;c.waitingNext=nil;c.cached=cached;c.workDone=true;c.cacheDirty=not cached or dirty;c.cacheRevision=(c.cacheRevision or 0)+1
        c.available=#rows;c.mapQueue={};c.mapIndex=1
        for _,row in ipairs(c.rows)do if row.position then c.mapQueue[#c.mapQueue+1]=row end end
        local page=c.document:page()
        table.sort(c.mapQueue,function(x,y)return math.abs(x.position.page-page)<math.abs(y.position.page-page)end)
        if seed then c.searches=seed.result.searches;c.anchor=seed.result.anchor;if seed.result.coordinateAttempted then c.coordinateAttempted=true end end
        local opening=not force and require('readinknative/openingmarks').apply(a,c,c.rows)
        if opening then
            for _,row in ipairs(opening.rows)do mapped(row)end
            for page,done in pairs(opening.pages)do if done==true then markDone(keyFor(tonumber(page)),true)end end
        end
        refreshPending();remember(a,c);mapCached()
        if opening and c.pageDone and c.pageDone[pageKey(c)]then
            c.completedPage=pageKey(c);c.complete=true;c.loading=false;if #opening.rows>0 then repaint()end;scheduleAhead();return
        end
        if seed and seed.key==pageKey(c)then
            c.pendingPage=seed.key;c.pagePending=seed.result.remaining
            if not seed.result.more then
                c.completedPage=seed.key;c.complete=true;c.loading=false;markDone(seed.key);scheduleAhead()
                return
            end
        end
        if not c.prepareCurrent()then requestPage()end
    end
    scheduleEnrich=function(delay)
        if not valid()or not c.enrichPending or c.enrichTask or c.enriching or(c.enrichFailures or 0)>=3 then return end
        c.enrichTask=function()
            c.enrichTask=nil
            if not valid()or S.hidden(a)or a.mode~='reader'then return end
            if a.panel or a.textSelection or a.chapterLoading or a.jobs and a.jobs.widget or pageRunning()or c.ahead or c.mapQueue or not c.complete then scheduleEnrich(0.2);return end
            require('readinknative/chapterloader').pause(a);require('readinknative/offline').beforeForeground(a)
            a.socialReaderJobs=a.socialReaderJobs or require('readinknative/inkjobs').new()
            local owner={started=clock.gettime()};c.enriching=owner;local snapshot=a.client.data
            a.socialReaderJobs:run('',function()
                assert(require('readinknative/cache').find(c.vid,c.book,c.chapter)==c.document.path,'SOCIAL_READING_CACHE_CHANGED')
                local client=require('readinknative/client'):new(snapshot)
                local result=require('readinknative/underlinerefs').fetch(client,c.book,c.chapter,c.document.path,a.chapters,false)
                return{rows=result.rows,partial=result.partial},client.data
            end,function(ok,result,session)
                if not valid()or c.enriching~=owner then return end
                c.enriching=nil
                if session and a.client.data==snapshot then a.client.data=session;a.client.session.data=session;a.client:commit()end
                if not ok then
                    c.enrichFailures=(c.enrichFailures or 0)+1
                    require('logger').info('ReadInk remaining underline references deferred:',require('readinknative/errors').code(result))
                    scheduleEnrich(5*c.enrichFailures);return
                end
                c.enrichPending=result.partial or nil
                c.enrichFailures=result.partial and(c.enrichFailures or 0)+1 or nil
                c.enrichDelay=result.partial and 5*c.enrichFailures or nil
                c.coordinateAttempted=nil
                if c.anchor then c.anchor.coordinateAttempted=nil end
                local rows=require('readinknative/underlinerefs').merge(result.rows,c.rows)
                accept(rows,false);scheduleAhead()
                require('logger').info('ReadInk remaining underline references ready:',#rows)
            end,false)
        end
        UI:scheduleIn(delay or c.enrichDelay or 0.15,c.enrichTask)
    end
    local saved
    if not force then
        saved=a.socialReaderCache and a.socialReaderCache[c.cacheKey]
        if saved then c.anchor=a.socialReaderAnchors and a.socialReaderAnchors[c.cacheKey];c.enrichPending=a.socialReaderPartial and a.socialReaderPartial[c.cacheKey]
        else local available,meta;saved,available,c.anchor,meta=UC.load(c);c.enrichPending=meta and meta.partial end
    end
    if saved then
        if a.underlineNext and a.underlineNext.document.path==c.document.path then require('readinknative/underlinenext').stop(a)end
        c.fastOpening=require('readinknative/relatededitions').isCB(c.book)
        accept(saved,true,nil,a.socialReaderDirty and a.socialReaderDirty[c.cacheKey]);scheduleEnrich();return
    end
    if require('readinknative/underlinenext').join(a,c,function(ok,value)
        if not valid()then return end
        if ok then
            c.anchor=value.anchor;c.enrichPending=value.partial
            c.fastOpening=require('readinknative/relatededitions').isCB(c.book)
            accept(value.rows,true);scheduleEnrich()
        else c.loading=false;c.error=require('readinknative/errors').code(value)end
    end)then c.waitingNext=true;return end
    local function begin()
        a.socialReaderTask=nil;if not valid()or S.hidden(a)then return end
        if a.mode~='reader'then c.loading=false;return end
        require('readinknative/underlinenext').stop(a)
        require('readinknative/chapterloader').pause(a);require('readinknative/offline').beforeForeground(a)
        c.expires=require('readinknative/cache').accessExpiry(c.vid,c.book,c.chapter)
        a.socialReaderJobs=a.socialReaderJobs or require('readinknative/inkjobs').new();c.fetching=true
        local snapshot=a.client.data;local path=c.document.path;local catalog=a.chapters
        a.socialReaderJobs:run('',function()
            local client=require('readinknative/client'):new(snapshot);local start=clock.gettime()
            local ok,result=pcall(function()
                assert(require('readinknative/cache').find(client.data.vid,c.book,c.chapter)==path,'SOCIAL_READING_CACHE_CHANGED')
                local refs=require('readinknative/underlinerefs').fetch(client,c.book,c.chapter,path,catalog,true)
                local ranges,source=refs.rows,refs.source;local network=clock.gettime()
                local prepared=clock.gettime();local key=pageKey(c)
                local Page=require('readinknative/underlinepage');local anchor=source and Page.anchor(source)
                local pageResult=#ranges>0 and Page.batch(c.document,ranges,nil,c.book,c.chapter,anchor,{coordinates=c.coordinateIndex and not refs.partial,source=source})or{updates={},remaining={},more=false,searches=0}
                -- Supply the already built source index without reopening/hash-reading the EPUB.
                if anchor and #anchor.text<=256*1024 then pageResult.anchor=anchor end
                return{rows=ranges,partial=refs.partial,seed={key=key,result=pageResult},networkMs=math.floor((network-start)*1000),sourceMs=math.floor((prepared-network)*1000),firstMapMs=math.floor((clock.gettime()-prepared)*1000)}
            end)
            return{ok=ok,value=ok and result or nil,error=not ok and require('readinknative/errors').code(result)or nil},client.data
        end,function(ok,result,session)
            if not valid()then return end;c.fetching=nil
            if session and a.client.data==snapshot then a.client.data=session;a.client.session.data=session;a.client:commit()end
            if not ok or not result.ok then
                c.loading=false;c.error=ok and result.error or'WORKER_FAILED';require('logger').warn('ReadInk underline read:',c.error)
                local previous=a.socialReaderRetry;a.socialReaderRetry={key=c.cacheKey,count=previous and previous.key==c.cacheKey and previous.count+1 or 1}
                if a.socialReaderRetry.count<=3 then
                    a.socialReaderRetryTask=function()a.socialReaderRetryTask=nil;if valid()and a.mode=='reader'and not S.hidden(a)then S.start(a,true)end end
                    UI:scheduleIn(5*a.socialReaderRetry.count,a.socialReaderRetryTask)
                end
                return
            end
            a.socialReaderRetry=nil
            require('logger').info('ReadInk underline references network/source/first-map ms/rows:',result.value.networkMs,result.value.sourceMs,result.value.firstMapMs,#result.value.rows)
            c.enrichPending=result.value.partial
            accept(result.value.rows,false,result.value.seed)
            scheduleEnrich()
        end,false,nil,function(result)
            if result.ok and require('readinknative/cache').find(c.vid,c.book,c.chapter)==path
                and require('readinknative/pagination').fileStamp(path)==c.fileStamp then
                UC.save(c,result.value.rows,nil,result.value.seed.result.anchor,{partial=result.value.partial})
            end
        end)
    end
    -- Queue cold references on the next UI tick; do not add a fixed delay
    -- after the text is ready. All network/index work remains in the worker.
    a.socialReaderTask=begin;UI:scheduleIn(0,begin)
end
function S.busy(a)
    local c=S.current(a)
    return a.mode=='reader'and c and not c.error and not a.panel
        and ((c.loading and not c.complete and require('socket').gettime()-(c.started or 0)<S.PRIORITY_SECONDS)
        or(c.ahead and require('socket').gettime()-c.ahead.started<S.PRIORITY_SECONDS)
        or(c.enriching and require('socket').gettime()-c.enriching.started<S.PRIORITY_SECONDS))and true or false
end
function S.resume(a)
    local c=S.current(a)
    if c and c.loaded and c.schedulePage then c.resumeMap();c.schedulePage(0.15)end
end
function S.input(a)
    local c=S.current(a)
    if a.mode~='reader'or not c or not c.loaded or c.error or a.socialReaderTask or a.chapterLoading or a.jobs and a.jobs.widget
        or a.view and a.view.scrollDrag then return end
    c.resumeMap()
    c.schedulePage(0.05)
end
function S.moved(a)
    local c=S.current(a);if c and c.loaded and not c.error and not S.hidden(a)then c.onMoved()end
end
function S.toggle(a)
    a.state.socialDisplay=a.state.socialDisplay or{};a.state.socialDisplay[tostring(a.book.bookId)]=S.hidden(a)
    a.state:flush();a.panel=nil;a.toolbar=false
    if S.hidden(a)then S.cancel(a)elseif S.current(a)and S.current(a).loaded then S.input(a)else S.start(a,true)end
    a:draw()
end
function S.paint(v,bb)
    local a,l=v.app,v.layout;local c=S.current(a)
    if not c or S.hidden(a)then return end
    local key=pageKey(c)
    if c.loaded and c.completedPage~=key then S.input(a)end
    if c.prepared and c.prepared[key]and c.firstReadyPaintKey~=key then
        c.firstReadyPaintKey=key;require('logger').info('ReadInk underline prepared page first paint:',a.document:page())
    end
    local BB=require('ffi/blitbuffer');local s=l.s
    local document=a.document;local page=document:page();local visible=document.doc:getVisiblePageCount()
    local geometry=geometryKey(document)
    for _,row in ipairs(c.mapped)do if row.position then
        if row.geometry~=geometry then
            row.firstPage=document.doc:getPageFromXPointer(row.position.xpointer);row.lastPage=document.doc:getPageFromXPointer(row.position.endXPointer);row.geometry=geometry
        end
        if document.isScroll and document:isScroll()or row.firstPage<=page+visible-1 and row.lastPage>=page then
        for _,box in ipairs(document:rangeBoxes(row.position))do
            local x=math.max(0,box.x);local finish=math.min(l.body.w,box.x+box.w);local y=box.y+box.h-s(1)
            if finish>x and y>=0 and y<l.body.h then
                local dash,gap=math.max(1,s(2)),math.max(1,s(2));local left=x
                while left<finish do bb:paintRect(l.body.x+left,l.body.y+y,math.min(dash,finish-left),math.max(1,s(1)),BB.COLOR_BLACK);left=left+dash+gap end
                if not a.toolbar and not a.panel and not a.textSelection and not a.footnote and not a.readerOverlay then
                    local top=math.max(0,box.y);local bottom=math.min(l.body.h,box.y+box.h)
                    if bottom>top then v:hit({x=l.body.x+x,y=l.body.y+top,w=finish-x,h=bottom-top},function()
                        if S.current(a)==c and not S.hidden(a)then require('readinknative/social').openRange(a,row)end
                    end,true)end
                end
            end
        end
        end
    end end
end
return S
