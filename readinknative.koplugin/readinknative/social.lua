local API=require('readinknative/socialapi');local Cache=require('readinknative/thoughtcache');local M={}
local function matches(a,c,allowSuspended)
    return c and not a.closed and(allowSuspended or not a.suspended)and a.state==c.state and a.book and tostring(a.book.bookId)==c.bookId
        and tostring(a.book.version or 0)==c.version and tostring(a.client.data.vid)==c.vid
end
function M.context(a)
    local c=a.social
    if not matches(a,c)then M.cancelMine(a);c={state=a.state,bookId=tostring(a.book.bookId),version=tostring(a.book.version or 0),vid=tostring(a.client.data.vid),stack={}};a.social=c end
    return c
end
function M.valid(a,c,r)return matches(a,c)and a.social==c and(not r or a.mode=='social'and c.route==r)end
local function returnMode(a,c)
    local mode=a.mode=='social'and c.returnMode or a.mode
    if not mode or mode=='social'or mode=='reader'and not a.document then return a.document and'reader'or'notes'end
    return mode
end
local function run(a,c,r,label,operation,done,quiet,background)
    if not M.valid(a,c,r)then return end
    local owner={}
    if r then r.requestOwner=owner;r.loading=true end
    require('readinknative/offline').beforeForeground(a);a.coverJobs:cancel();local snapshot=a.client.data
    local target;if quiet then target=false end
    return a.jobs:run(label,function()
        local child=require('readinknative/client'):new(snapshot);local ok,value=pcall(operation,child)
        return{ok=ok,value=ok and value or nil,error=not ok and require('readinknative/errors').code(value)or nil},child.data
    end,function(ok,envelope,session)
        if not M.valid(a,c,r)or r and r.requestOwner~=owner then return end
        if r then r.loading=nil end
        if session and a.client.data==snapshot then a.client.data=session;a.client.session.data=session;a.client:commit()end
        if not ok then envelope={ok=false,error='WORKER_FAILED'}end
        local painted=done(envelope)
        if painted~=true then a:draw()end
        if r then M.media(a)end
    end,target,function()
        if not r or not matches(a,c,true)or a.social~=c or r.requestOwner~=owner then return end
        r.loading=nil
        if background then return end
        r.resolving=nil;r.wantNext=nil;r.error='SOCIAL_REQUEST_CANCELLED'
        if not a.suspended and not a.exiting and a.mode=='social'and c.route==r then a:draw()end
    end)
end
-- Restore before the first paint; a fresh hit does not start a public request.
-- Expired hits stay visible throughout a silent refresh, including failure.
function M.showThoughts(a,c,r)
    local at=Cache.restore(c,r)
    if at then for _,g in ipairs(r.groups)do M.withMine(c,r,g)end end
    a:draw()
    if not at then M.fetchGroups(a,false);return true end
    require('ui/uimanager'):forceRePaint()
    Cache.save(c,r,at)
    if os.time()<at or os.time()-at>=Cache.TTL then M.fetchGroups(a,false,true)
    else M.fetchMine(a);M.media(a)end
    return true
end
-- Avatar workers are independent of book covers and authenticated requests.
function M.media(a)
    local P=require('readinknative/avatarpaint');local Q=require('readinknative/avatarqueue')
    Q.guard(a)
    local v=a.view;local scene=v and v.avatarScene
    if scene and not scene.invalid and P.same(v,scene.owner)then Q.request(a,scene)end
    local c=a.social;local r=c and c.route
    if r and r.kind=='detail'and M.valid(a,c,r)and a.book.cover then
        local C=require('readinknative/covercache');local url=a.book.cover
        if not C.find(c.vid,url)and not r.coverLoading then
            r.coverLoading=true
            a.coverJobs:run('',function()return C.prepare(c.vid,url,true)end,function(ok,path)
                r.coverLoading=nil
                if ok and path and M.valid(a,c,r)then a:draw()end
            end,false,function()r.coverLoading=nil end)
        end
    end
end
local function cloudRows(c)
    local rows={}
    for _,r in ipairs(c.mine and c.mine.rows or{})do
        rows[#rows+1]={id='cloud-review:'..r.reviewId,cloud=true,review=r,kind=r.content==''and'highlight'or'note',bookId=c.bookId,
            chapterUid=r.chapterUid,chapterTitle=r.chapterTitle,text=r.content==''and r.quote or r.content,quote=r.content~=''and r.quote or nil,
            position={},created=r.created or 0,updated=r.created or 0}
    end
    for _,r in ipairs(c.bookmarks and c.bookmarks.rows or{})do
        if r.type~=1 then rows[#rows+1]={id='cloud-bookmark:'..r.bookmarkId,cloud=true,bookmark=r,kind='bookmark',bookId=c.bookId,
            chapterUid=r.chapterUid,chapterTitle=r.chapterTitle,quote=r.quote,position={},created=r.created or 0,updated=r.created or 0}end
    end
    c.cloudRows=rows
end
function M.records(a)
    local c=a.social;if not matches(a,c)or a.notesEditing then return{}end
    local rows={};local localIds={};for _,r in ipairs(a.state.annotations or{})do if r.cloudId then localIds[r.cloudId]=true end end
    for _,r in ipairs(c.cloudRows or{})do if not a.notesOnlyBookmarks or r.kind=='bookmark'then rows[#rows+1]=r end end
    local remote=require('readinknative/annotationsync').model(a.state).remote[c.bookId]
    for _,r in ipairs(c.bookmarks and c.bookmarks.rows or remote and remote.rows or{})do
        if r.type==1 and not a.notesOnlyBookmarks and not localIds[r.bookmarkId]then
            local deleted=false;for _,op in pairs(require('readinknative/annotationsync').model(a.state).pending)do if op.action=='delete'and op.cloudId==r.bookmarkId or op.book.bookId==c.bookId and op.chapter.chapterUid==r.chapterUid and require('readinknative/readingposition').compact(op.quote or'')==require('readinknative/readingposition').compact(r.quote or'')then deleted=true end end
            if not deleted then c.underlineViews=c.underlineViews or{};c.underlineViews[r.bookmarkId]=c.underlineViews[r.bookmarkId]or{id='cloud-bookmark:'..r.bookmarkId,cloud=true,bookmark=r,kind='highlight',bookId=c.bookId,chapterUid=r.chapterUid,chapterTitle=r.chapterTitle,text=r.quote,quote=r.quote,position={},created=r.created or 0,updated=r.created or 0};rows[#rows+1]=c.underlineViews[r.bookmarkId]end
        end
    end;return rows
end
function M.refreshMine(a,force)
    if a.book.localFile or not a.client:ready()then return end
    require('readinknative/annotationsync').changed(a)
    local c=M.context(a);if not force and c.mineAt and os.time()-c.mineAt<120 then return end
    local book=a.book;c.mineError=nil
    return run(a,c,nil,'读取云端笔记',function(client)
        local ok,notes=pcall(API.mine,client,book);local good,marks=pcall(API.bookmarks,client,book)
        return{notes=ok and notes or nil,marks=good and marks or nil,failed=not ok or not good}
    end,function(result)
        if result.ok then
            if result.value.notes then c.mine=result.value.notes end
            if result.value.marks then c.bookmarks=result.value.marks;require('readinknative/annotationsync').merge(a.state,book,result.value.marks);a.state:flush() end
            c.mineError=result.value.failed and'SOCIAL_PARTIAL_READ'or nil
            if not c.mineError then c.mineAt=os.time()end
            cloudRows(c)
        else c.mineError=result.error end
    end,true)
end
function M.openRange(a,row)
    if a.book.localFile or not a.chapter or not a.client:ready()then a:message('请先打开已登录账号的线上章节。');return end
    local reader=require('readinknative/socialreader');local source=reader.current(a);local owned=false
    for _,value in ipairs(source and source.mapped or{})do if value==row then owned=true;break end end
    if not owned or reader.hidden(a)then return end
    local c=M.context(a);c.returnMode=returnMode(a,c);c.stack={}
    local r={kind='thoughts',book=a.book,chapter=a.chapter,page=1,groups={},ranges={{range=row.range,quote=row.quote,foreign=row.foreign}},foreign=row.foreign,nextRange=2,quote=row.quote,singleRange=true,origin={document=a.document,chapter=a.chapter,position=row.position,stamp=require('readinknative/pagination').fileStamp(a.document.path)}}
    c.route=r;a:clearTextSelection();a.panel=nil;a.mode='social';M.showThoughts(a,c,r)
end
-- A personal solid underline opens the same paragraph thoughts as a passive
-- dotted underline. The notes list retains its separate record-detail action.
function M.openAnnotation(a,row)
    if not a.book or a.book.localFile or a.book.article or not a.client:ready()then return false end
    if a.closed or a.suspended or a.mode~='reader'or not a.document or not a.chapter or row.kind~='highlight'then return true end
    if row.bookId~=tostring(a.book.bookId)or row.chapterUid~=tostring(a.chapter.chapterUid)then return true end
    local owned=false;for _,value in ipairs(a.state.annotations)do if value==row then owned=true;break end end
    local p=row.position
    if not owned or not p or not p.endXPointer or not a.document.doc:isXPointerInDocument(p.xpointer)or not a.document.doc:isXPointerInDocument(p.endXPointer)then return true end
    local c=M.context(a);c.returnMode='reader';c.stack={}
    local origin={document=a.document,chapter=a.chapter,position=p,stamp=require('readinknative/pagination').fileStamp(a.document.path)}
    local r={kind='thoughts',book=a.book,chapter=a.chapter,page=1,groups={},ranges={},nextRange=1,quote=row.text,singleRange=true,origin=origin,annotationId=row.id}
    c.route=r;a:clearTextSelection();a.panel=nil;a.toolbar=false;a.mode='social'
    local left,right
    if type(row.sourceRange)=='string'then left,right=row.sourceRange:match('^(%d+)%-(%d+)$')end
    if left and right and tonumber(right)>tonumber(left)and row.sourceVersion==c.version then
        r.ranges={{range=row.sourceRange}};r.nextRange=2;return M.showThoughts(a,c,r)
    end
    -- Older/newly selected local lines may not have a service range yet.
    -- Keep the live quote/action visible while a cancellable worker maps it.
    r.resolve=function()
        if not r or not M.valid(a,c,r)or r.resolving then return end
        r.resolving=true;r.error=nil;a:draw()
        return run(a,c,r,'',function(client)
            local path=origin.document.path
            assert(require('readinknative/cache').find(client.data.vid,r.book,r.chapter)==path,'SOCIAL_READING_CACHE_CHANGED')
            return require('readinknative/annotationsync').map({book=r.book,chapter=r.chapter,quote=r.quote,position=p},client,path)
        end,function(result)
            r.resolving=nil
            if a.document~=origin.document or a.chapter~=origin.chapter or require('readinknative/pagination').fileStamp(origin.document.path)~=origin.stamp then r.error='SOCIAL_READING_CACHE_CHANGED';return end
            if not result.ok then r.error=result.error;return end
            r.ranges={{range=result.value}};r.nextRange=2
            row.sourceRange=result.value;row.sourceVersion=c.version;a.state:flush()
            return M.showThoughts(a,c,r)
        end,true)
    end
    a:draw();r.resolve();return true
end
-- Exact original range -> CRe annotation and the account-local sync outbox.
function M.highlighted(a,r)
    if not r or r.kind~='thoughts'or not r.chapter then return end
    local range=r.ranges[1]and r.ranges[1].range;local p=r.origin and r.origin.position
    for _,row in ipairs(require('readinknative/annotations').list(a.state,r.book.bookId,'highlight'))do
        if row.chapterUid==tostring(r.chapter.chapterUid)and
            (range and row.sourceRange==range and row.sourceVersion==tostring(r.book.version or 0)or
            p and row.position.xpointer==p.xpointer and row.position.endXPointer==p.endXPointer)then return row end
    end
end
function M.highlightBusy(a,r)
    if r.highlightBusy and r.highlightEpoch~=a.jobs.epoch then r.highlightBusy=nil end
    return r.highlightBusy
end
function M.highlight(a)
    local c=a.social;local r=c and c.route
    if not r or not M.valid(a,c,r)or r.kind~='thoughts'or not r.chapter or r.resolving or M.highlightBusy(a,r)then return end
    local A=require('readinknative/annotations');local existing=M.highlighted(a,r)
    if existing then A.remove(a.state,existing.id);a.state:flush();require('readinknative/annotationsync').changed(a);a:draw();return end
    local function save(position,path,stamp)
        if not M.valid(a,c,r)then return end
        if not position or not path or require('readinknative/pagination').fileStamp(path)~=stamp then
            a:message('原文位置未能准确匹配，未添加划线。');return
        end
        local row=A.add(a.state,r.book,r.chapter,'highlight',position,r.quote)
        row.sourceRange=r.ranges[1].range;row.sourceVersion=tostring(r.book.version or 0);require('readinknative/annotationsync').queue(a.state,r.book,r.chapter,row)
        a.state:flush();require('readinknative/annotationsync').changed(a);a:draw();return row
    end
    local origin=r.origin;local doc=a.document
    if origin and doc==origin.document and a.chapter==origin.chapter and origin.position
        and(r.annotationId or require('readinknative/socialreader').current(a))then
        local p=origin.position
        if doc.doc:isXPointerInDocument(p.xpointer)and doc.doc:isXPointerInDocument(p.endXPointer)then
            return save(p,doc.path,origin.stamp)
        end
    end
    -- Popular underlines may belong to another chapter. Resolve in the worker
    -- without changing the user's live document or saved reading position.
    if not r.loaded then return end
    r.highlightBusy=true;r.highlightEpoch=a.jobs.epoch;a:draw()
    local book,chapter,quote=r.book,r.chapter,r.quote;local body=a.view.layout.body
    local font,format=a.state.font,a.state:format(book)
    local pending=run(a,c,r,'',function(client)
        local path=require('readinknative/cache').find(client.data.vid,book,chapter)
        if not path then
            local result=require('readinknative/api').chapter(client,book,chapter)
            assert(tostring(result.book.version or 0)==c.version,'SOCIAL_SOURCE_VERSION_CHANGED');path=result.path
        end
        assert(path,'CHAPTER_FILES_MISSING')
        local stamp=require('readinknative/pagination').fileStamp(path)
        local d=require('readinknative/document').open(path,body.w,body.h,font,nil,format)
        local ok,position=pcall(require('readinknative/socialranges').position,d,quote);d:close()
        if not ok then error(position)end
        return{position=position,path=path,stamp=stamp}
    end,function(result)
        r.highlightBusy=nil
        if result.ok then local value=result.value;save(value.position,value.path,value.stamp)
        else a:message('划线未能保存，请稍后重试。')end
    end,true)
    r.highlightEpoch=a.jobs.epoch;return pending
end
function M.openBookList(a,kind)
    if kind~='hot'and kind~='reviews'then return end
    if a.book.localFile or not a.client:ready()then return end
    local c=M.context(a);c.returnMode=returnMode(a,c);c.stack={};c.route={kind=kind,book=a.book,page=1,rows={}}
    local r=c.route
    if kind=='reviews'and c.reviewsPreview then r.rows=c.reviewsPreview.rows;r.data=c.reviewsPreview;r.loaded=true end
    a:clearTextSelection();a.panel=nil;a.toolbar=false;a.mode='social';a:draw();if not r.loaded then M.fetchBookList(a)end
end
function M.top(a)
    if a.panel=='social'then a.panel=nil else a.panel='social'end
    a:draw();if a.panel~='social'then return end
    local c=M.context(a)
    if c.summaryAt and os.time()-c.summaryAt<120 then return end
    return run(a,c,nil,'',function(client)
        local ok,reviews=pcall(API.bookReviews,client,a.book);local good,hot=pcall(require('readinknative/relatededitions').hotInfo,client,a.book,a.chapters)
        return{reviews=ok and reviews or nil,hot=good and hot or nil}
    end,function(result)
        if result.ok then
            local data=result.value
            if data.reviews then c.reviewsPreview=data.reviews;c.reviewsTotal=data.reviews.total end
            if data.hot then c.hotTotal=data.hot.total;c.hotRelated=data.hot.relatedTitle end
            if data.reviews and data.hot then c.summaryAt=os.time()end
        end
        local reader=require('readinknative/socialreader');local current=reader.current(a)
        if not current or current.error or not current.complete and not current.loading then reader.start(a,true)end
    end,true)
end
function M.fetchBookList(a,append)
    local c=M.context(a);local r=c.route;if not r or not M.valid(a,c,r)or(r.kind~='hot'and r.kind~='reviews')then return end
    r.error=nil
    return run(a,c,r,'读取'..(r.kind=='hot'and'热门划线'or'书评'),function(client)
        if r.kind=='hot'then return require('readinknative/relatededitions').hot(client,r.book,append and r.data or nil,a.chapters)end
        return API.bookReviews(client,r.book,append and r.data or nil)
    end,function(result)
        if not result.ok then r.error=result.error;return end
        local data=result.value;r.rows=append and API.merge(r.rows,data.rows,r.kind=='hot'and'id'or'reviewId')or data.rows
        r.data=data;r.loaded=true
        if r.kind=='hot'then c.hotTotal=data.total;c.hotRelated=data.relatedTitle else c.reviewsTotal=data.total end
        if r.wantNext then r.page=r.page+1;r.wantNext=nil end
    end)
end
function M.openHot(a,row)
    local c=M.context(a);local r=c.route;if not r or not M.valid(a,c,r)or r.kind~='hot'then return end
    local owned=false;for _,value in ipairs(r.rows)do if value==row then owned=true;break end end;if not owned then return end
    c.stack[#c.stack+1]=r;c.route={kind='thoughts',book=a.book,chapter=row.chapter,page=1,groups={},ranges={{range=row.range,quote=row.quote,foreign=row.foreign}},foreign=row.foreign,nextRange=2,quote=row.quote,singleRange=true}
    M.showThoughts(a,c,c.route)
end
-- Public paragraph ranking may omit the author's own published reviews.
-- The authenticated personal list is authoritative for that user's entries.
local function ownRows(c,r,g)
 local out={}
 for _,row in ipairs(c.mine and c.mine.rows or{})do
  if row.userVid==c.vid and row.bookId==c.bookId and row.chapterUid==tostring(r.chapter.chapterUid)
   and row.range==g.range and row.content~=''and(not row.bookVersion or tostring(row.bookVersion)==c.version)then out[#out+1]=row end
 end
 return out
end
function M.withMine(c,r,g)
 g.publicRows=g.publicRows or g.rows
 g.rows=API.merge(ownRows(c,r,g),g.publicRows,'reviewId')
end
function M.cancelMine(a)
    if a.socialMineJobs then a.socialMineJobs:cancel()end
    local c=a.social;if not c then return end
    c.mineOwner=nil
    if c.route then c.route.mineLoading=nil end
    for _,r in ipairs(c.stack or{})do r.mineLoading=nil end
end
-- Enrich already-visible public thoughts with personal entries independently.
function M.fetchMine(a,force)
    local c=a.social;local r=c and c.route
    if not r or r.kind~='thoughts'or not M.valid(a,c,r)or not r.loaded then return end
    if not force and c.mine and c.mineAt and os.time()-c.mineAt<120 then return end
    if c.mineOwner and a.socialMineJobs and c.mineOwner.epoch==a.socialMineJobs.epoch then r.mineLoading=true;return end
    a.socialMineJobs=a.socialMineJobs or require('readinknative/inkjobs').new{TIMEOUT=20,NICE=10}
    local owner={route=r,mineError=r.mineError};c.mineOwner=owner;r.mineLoading=true;r.mineError=nil
    local snapshot=a.client.data;local book=r.book
    a.socialMineJobs:run('',function()
        local child=require('readinknative/client'):new(snapshot)
        return API.mine(child,book),child.data
    end,function(ok,data,session)
        if not M.valid(a,c)or c.mineOwner~=owner then return end
        c.mineOwner=nil
        if session and a.client.data==snapshot then a.client.data=session;a.client.session.data=session;a.client:commit()end
        if ok then c.mine=data;c.mineAt=os.time();cloudRows(c);owner.route.mineError=nil end
        local current=c.route
        if not current or current.kind~='thoughts'or not M.valid(a,c,current)then return end
        local changed=current.mineError~=(not ok or nil)or(owner.route==current and owner.mineError~=nil)
        current.mineLoading=nil;current.mineError=not ok or nil
        if ok and current.loaded then
            for _,g in ipairs(current.groups)do
                local old=g.rows;M.withMine(c,current,g)
                if #old~=#g.rows then changed=true
                else for i,row in ipairs(g.rows)do if row~=old[i]then changed=true;break end end end
            end
            if changed then current.page=math.max(1,math.min(current.page or 1,#M.pages(a)))end
        end
        if changed then a:draw()end
        if ok then M.media(a)end
    end,false)
    owner.epoch=a.socialMineJobs.epoch
end
function M.fetchGroups(a,append,background)
    local c=M.context(a);local r=c.route;if not r or not M.valid(a,c,r)or r.kind~='thoughts'then return end
    if r.resolving then return end
    if r.loading and r.loadEpoch==a.jobs.epoch and a.jobs.widget then return end
    if #r.ranges==0 and r.resolve then return r.resolve()end
    r.error=nil
    local pending=run(a,c,r,'读取段落想法',function(client)
        local ranges=r.ranges
        local start=append and r.nextRange or 1
        local groups=require('readinknative/relatededitions').groups(client,r.book,r.chapter,ranges,start)
        return{ranges=ranges,groups=groups,nextRange=math.min(#ranges+1,start+5)}
    end,function(result)
        if not result.ok then if background then return true end;r.error=result.error;return end
        local value=result.value
        for _,g in ipairs(value.groups)do M.withMine(c,r,g)end
        if r.singleRange and value.groups[1]then value.groups[1].quote=r.quote or value.groups[1].quote end
        local unchanged=background and Cache.equal(r.groups,value.groups)and r.nextRange==value.nextRange
        r.ranges=value.ranges
        if not unchanged then r.groups=append and API.merge(r.groups,value.groups,'range')or value.groups end
        r.nextRange=value.nextRange;r.loaded=true
        if r.wantNext then r.page=math.min(#M.pages(a),r.page+1);r.wantNext=nil end
        if not unchanged then
            r.page=math.max(1,math.min(r.page or 1,#M.pages(a)))
            a:draw();require('ui/uimanager'):forceRePaint()
        end
        Cache.save(c,r);M.fetchMine(a)
        return true
    end,true,background)
    if r.loading then r.loadEpoch=a.jobs.epoch end
    return pending
end
function M.moreGroup(a,g)
    local c=M.context(a);local r=c.route
    if not r or not M.valid(a,c,r)or r.kind~='thoughts'or not g.more then return end
    r.error=nil
    return run(a,c,r,'加载更多想法',function(client)return require('readinknative/relatededitions').moreGroup(client,r.book,r.chapter,g)end,function(result)
        if not result.ok then r.error=result.error;r.wantNext=nil;return end
        local data=result.value;local old=g.publicRows or g.rows;local rows=API.merge(old,data.rows,'reviewId')
        if data.more and #rows==#old then r.error='SOCIAL_CURSOR_STALLED';r.wantNext=nil;return end
        g.publicRows=rows;g.more=data.more;g.maxIdx=data.maxIdx;g.synckey=data.synckey;g.total=data.total;M.withMine(c,r,g)
        Cache.save(c,r)
        if r.wantNext then local pages=M.pages(a);r.page=math.min(#pages,math.floor(r.wantNext/pages[1].viewport)+1);r.wantNext=nil end
    end)
end
function M.pages(a)
    local c=a.social;local r=c and c.route;if not r or r.kind~='thoughts'then return{}end
    return require('readinknative/sociallayout').thoughts(a,r)
end
function M.detail(a,row)
    local c=M.context(a);if c.route and a.mode=='social'then c.stack[#c.stack+1]=c.route else c.returnMode=returnMode(a,c);c.stack={}end
    local r={kind='detail',row=row,page=1,tab='comments'};c.route=r;a.mode='social';a.panel=nil;a:draw();M.fetchDetail(a)
end
function M.fetchDetail(a,part)
    local c=M.context(a);local r=c.route;if not r or not M.valid(a,c,r)or r.kind~='detail'then return end
    local previous=r.data;local append=part~=nil;local offset=append and(part=='likes'and previous.likesOffset or previous.offset)or nil
    return run(a,c,r,'读取想法详情',function(client)return API.detail(client,r.row.reviewId,r.row.bookId or c.bookId,offset,append and previous.synckey or 0,part)end,function(result)
        if not result.ok then r.error=result.error;r.appendAt=nil;return end
        local data=result.value
        if append then
            if part=='likes'then
                local merged=API.merge(previous.likes,data.likes,'vid')
                if #merged==#previous.likes and data.moreLikes then r.error='SOCIAL_CURSOR_STALLED';r.appendAt=nil;return end
                previous.likes=merged;previous.likesOffset=data.likesOffset;previous.moreLikes=data.moreLikes
            else
                local merged=API.merge(previous.comments,data.comments,'commentId')
                if data.moreComments and #merged==#previous.comments then r.error='SOCIAL_CURSOR_STALLED';r.appendAt=nil;return end
                previous.comments=merged;previous.offset=data.offset;previous.moreComments=data.moreComments
            end
            previous.review=data.review;previous.synckey=data.synckey
        else r.data=data;r.expandedComment=nil end
        if r.appendAt then local layout=require('readinknative/sociallayout').detail(a,r);r.page=math.min(layout.pages,math.floor(r.appendAt/layout.viewport)+1);r.appendAt=nil end
        local updated=r.data.review;M.updateReview(a,c,updated)
        r.row=updated
        r.error=nil;if c.pendingLikes then c.pendingLikes[r.row.reviewId]=nil end
    end)
end
-- All authoritative review changes reach off-screen cache entries as well as
-- navigation parents; an older personal worker cannot roll them back.
function M.updateReview(a,c,updated)
    M.cancelMine(a);c.mineAt=nil
    local function replace(rows)for i,old in ipairs(rows or{})do if old.reviewId==updated.reviewId then rows[i]=updated end end end
    local routes={};if c.route then routes[1]=c.route end
    for _,r in ipairs(c.stack or{})do routes[#routes+1]=r end
    for _,r in ipairs(routes)do
        replace(r.rows)
        for _,g in ipairs(r.groups or{})do replace(g.rows);replace(g.publicRows)end
    end
    if c.mine then replace(c.mine.rows);cloudRows(c)end
    Cache.replace(c,updated)
end
function M.invalidateThoughts(c,op)Cache.invalidate(c,op)end
function M.openCloud(a,row)
    local owned=false;for _,r in ipairs(M.records(a))do if r==row then owned=true;break end end;if not owned then return end
    if row.review then M.detail(a,row.review)
    else
        local c=M.context(a);c.returnMode=returnMode(a,c);c.stack={};c.route={kind='bookmark',row=row,page=1};a.mode='social';a:draw()
    end
end
function M.like(a,row)
    local c=M.context(a);local r=c.route;if not r or not M.valid(a,c,r)then return end
    if r.kind=='detail'then row=r.data and r.data.review
    elseif r.kind=='thoughts'then
        local owned=false;for _,g in ipairs(r.groups)do for _,v in ipairs(g.rows)do if v==row then owned=true end end end
        if not owned then return end
    else return end
    if not row then M.fetchDetail(a);return end
    c.pendingLikes=c.pendingLikes or{}
    if c.pendingLikes[row.reviewId]or type(row.liked)~='boolean'then
        if r.kind=='detail'then M.fetchDetail(a)else M.detail(a,row)end;return
    end
    local rid=row.reviewId;local desired=not row.liked;c.pendingLikes[rid]=true;r.error=nil;a:draw()
    -- Keep unknown writes pending. Only a new authoritative read unlocks them;
    -- cancellation or a network error must never replay a toggle.
    return run(a,c,r,desired and'点赞'or'取消点赞',function(client)
        API.like(client,rid,desired);local ok,data=pcall(API.detail,client,rid,row.bookId or c.bookId)
        return{data=ok and data or nil}
    end,function(result)
        if not result.ok then r.error='SOCIAL_LIKE_UNCERTAIN';return end
        local data=result.value.data;local updated=data and data.review or row
        if not data then updated.liked=desired;updated.likesCount=nil end
        if r.kind=='detail'then if data then r.data=data else r.data.review=updated end end
        M.updateReview(a,c,updated)
        c.pendingLikes[rid]=nil
        if r.kind=='thoughts'then M.fetchMine(a,true)end
    end)
end
function M.openComment(a,value)
    local c=M.context(a);local r=c.route;if not r or not M.valid(a,c,r)or not r.data then return end
    local owned=false;for _,v in ipairs(r.data.comments)do if v==value then owned=true;break end end;if not owned then return end
    r.listPage=r.page;r.expandedComment=value;r.page=1;a:draw()
end
function M.selectTab(a,tab)
    local c=M.context(a);local r=c.route;if not r or not M.valid(a,c,r)or not r.data then return end
    r.tab=tab=='likes'and'likes'or'comments';r.expandedComment=nil
    r.page=tab=='review'and 1 or math.floor((r.tabsY or 0)/a.view.layout.listFooter)+1;a:draw();M.media(a)
end
function M.turn(a,delta)
    local c=M.context(a);local r=c.route;if not r or not M.valid(a,c,r)then return end
    if r.kind=='hot'or r.kind=='reviews'then
        local capacity=M.bookListCapacity(a);local pages=math.max(1,math.ceil(#r.rows/capacity))
        if delta>0 and r.page+delta>pages and r.data and r.data.more and r.data.maxIdx then r.wantNext=true;M.fetchBookList(a,true)
        else r.page=math.max(1,math.min(pages,r.page+delta))end
    elseif r.kind=='thoughts'then
        local pages=M.pages(a);local nextPage=math.max(1,(r.page or 1)+delta)
        if nextPage>#pages and delta>0 then
            local last=pages[#pages]
            if M.highlightBusy(a,r)then return end
            if last and last.group and last.group.more then r.wantNext=last.totalHeight;M.moreGroup(a,last.group)
            elseif r.nextRange<=#r.ranges then r.wantNext=true;M.fetchGroups(a,true)end
        else r.page=math.max(1,math.min(math.max(1,#pages),nextPage))end
    elseif r.expandedComment then r.page=math.max(1,math.min(r.commentTextPages or 1,r.page+delta))
    elseif r.kind=='detail'then
        local layout=require('readinknative/sociallayout').detail(a,r);local max=layout.pages
        if r.page+delta>max and delta>0 and r.data and(r.tab=='likes'and r.data.moreLikes or r.tab=='comments'and r.data.moreComments)then r.appendAt=layout.height;M.fetchDetail(a,r.tab)
        else r.page=math.max(1,math.min(max,r.page+delta))end
    else r.page=math.max(1,math.min(r.textPages or 1,r.page+delta))end
    a:draw();M.media(a)
end
function M.bookListCapacity(a)return math.max(1,math.floor((a.view.layout.listFooter-a.view.layout.s(110))/a.view.layout.s(176)))end
function M.listCapacity(a)return math.max(1,math.floor((a.view.layout.listFooter-a.view.layout.s(180))/a.view.layout.s(112)))end
function M.back(a)
    require('readinknative/avatarqueue').stop(a)
    M.cancelMine(a)
    local c=a.social;if not matches(a,c)then a.mode=a.document and'reader'or'notes';a:startClock();a:draw();return end
    if c.route and c.route.expandedComment then c.route.expandedComment=nil;c.route.page=c.route.listPage or 1;a:draw();return end
    a.jobs:cancel();if c.route then c.route.highlightBusy=nil end;local previous=table.remove(c.stack or{})
    if previous then c.route=previous else c.route=nil;a.mode=returnMode(a,c);a:startClock()end
    a:draw()
    if previous and previous.kind=='thoughts'and previous.loaded then
        for _,g in ipairs(previous.groups)do M.withMine(c,previous,g)end
        previous.page=math.max(1,math.min(previous.page or 1,#M.pages(a)))
        a:draw();M.fetchMine(a)
    end
end
M.run=run
return M
