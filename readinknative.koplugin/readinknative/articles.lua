-- Official two-tab article collection with independent account/route epochs.
local API=require('readinknative/articleapi');local H=require('readinknative/articlecontent');local S={}
-- Account-scoped opaque tags correlate clicks, URLs and reader transitions.
-- Never log review IDs, titles, article URLs, account IDs or credentials.
local function tag(c,id)
    return id and require('ffi/sha2').sha256(tostring(c.vid)..':'..tostring(id)):sub(1,12)or'list'
end
local function context(a)
    local c=a.articles
    if not c or c.state~=a.state or c.vid~=a.client.data.vid then
        c={state=a.state,vid=a.client.data.vid,kind=0,routes={}};a.articles=c
    end
    return c
end
local function valid(a,c,r)
    return not a.closed and not a.suspended and a.mode=='articles'and a.articles==c and c.state==a.state and c.vid==a.client.data.vid and c.routes[c.kind]==r
end
local function listPath(vid,kind)
    local name=type(kind)=='number'and('articles-list-'..kind)or('articles-publisher-'..require('ffi/sha2').sha256(kind))
    return require('readinknative/paths').cache(vid,name..'.json')
end
local function cached(c,kind)
    local f=require('readinknative/cachefiles').open(listPath(c.vid,kind),'rb');if not f then return end
    local raw=f:read(4*1024*1024+1);f:close();if #raw>4*1024*1024 then return end
    local ok,r=pcall(require('rapidjson').decode,raw)
    if ok and type(r)=='table'and r.schema==(type(kind)=='number'and 1 or 2)and r.vid==tostring(c.vid)and r.kind==kind and type(r.data)=='table'and type(r.data.rows)=='table'and #r.data.rows<=5000 then local normalized,value=pcall(API.snapshot,r.data);if normalized then return value end end
end
local function save(c,r)
    local p=listPath(c.vid,c.kind);local f=assert(require('readinknative/cachefiles').open(p..'.part','wb'),'ARTICLE_CACHE_WRITE_FAILED')
    assert(f:write(require('rapidjson').encode{schema=c.publisher and 2 or 1,vid=tostring(c.vid),kind=c.kind,data=r.data}),'ARTICLE_CACHE_WRITE_FAILED');assert(f:close(),'ARTICLE_CACHE_WRITE_FAILED')
    assert(require('readinknative/cachefiles').rename(p..'.part',p),'ARTICLE_CACHE_WRITE_FAILED')
end
function S.enter(a)
    require('readinknative/articleimages').cancel(a)
    require('readinknative/chapterloader').stop(a);require('readinknative/chapterloader').cancel(a)
    require('readinknative/socialreader').cancel(a);require('readinknative/readerlinks').reset(a)
    require('readinknative/input').close(a);a.jobs:cancel();a.coverJobs:cancel();a:clearTextSelection();a:savePosition()
    require('readinknative/resident').park(a);a.articleReturn=nil;a.storeReturn=nil;a.panel=nil;a.mode='articles'
    local c=context(a);S.tab(a,type(c.kind)=='number'and c.kind or 0)
end
function S.tab(a,kind)
    assert(kind==0 or kind==1);a.jobs:cancel();a.coverJobs:cancel()
    local c=context(a);if c.routes[c.kind]then c.routes[c.kind].loading=nil end
    c.publisher=nil;c.kind=kind;c.epoch=(c.epoch or 0)+1
    local r=c.routes[kind]or{page=1,data=cached(c,kind)};c.routes[kind]=r
    a.mode='articles';a:draw();S.covers(a)
    if not r.data then S.fetch(a,false)end
end
local function publisherRow(a,c,r)
    local saved=(a.state.articleLast or{})[tostring(c.publisher.bookId)]
    local chosen
    for _,row in ipairs(r.data and r.data.rows or{})do if saved and row.reviewId==saved.reviewId then chosen=row;break end end
    if not chosen and saved and type(saved.reviewId)=='string'then chosen={reviewId=saved.reviewId,title=c.publisher.title,account=c.publisher.title,idx=0,publisherBookId=tostring(c.publisher.bookId)}end
    return chosen or(r.data and r.data.rows[1])
end
local function readPublisher(a,c,r)
    local chosen=publisherRow(a,c,r)
    r.autoRead=nil;if chosen then S.open(a,chosen)else r.publisherOpenStarted=nil end
end
function S.publisher(a,book)
    local openedAt=require('ui/time').monotonic()
    require('readinknative/articleimages').cancel(a)
    require('readinknative/chapterloader').stop(a);require('readinknative/chapterloader').cancel(a)
    require('readinknative/socialreader').cancel(a);require('readinknative/readerlinks').reset(a)
    require('readinknative/input').close(a);a.jobs:cancel();a.coverJobs:cancel();a:clearTextSelection();a:savePosition()
    require('readinknative/resident').park(a);a.articleReturn=nil;a.storeReturn=nil;a.panel=nil;a.mode='articles'
    local c=context(a);if c.routes[c.kind]then c.routes[c.kind].loading=nil end
    c.kind='mp:'..API.id(tostring(book.bookId));c.publisher=book;c.epoch=(c.epoch or 0)+1
    local r=c.routes[c.kind]or{page=1,data=cached(c,c.kind)};c.routes[c.kind]=r;r.autoRead=true;r.publisherOpenStarted=openedAt
    a:draw()
    local chosen=publisherRow(a,c,r);local path,meta
    if chosen then path,meta=H.find(c.vid,chosen)end
    -- A stale catalog is not a reason to delay a valid, already downloaded
    -- last-read article. Catalog opening still performs its normal refresh.
    if path and not meta.requiresCheck then
        require('logger').info('ReadInk publisher opened cached article before catalog refresh')
        readPublisher(a,c,r)
    else
        S.covers(a)
        if r.data and(not a.client:ready()or os.time()-(r.data.updated or 0)<300)then readPublisher(a,c,r)else S.fetch(a,false)end
    end
end
function S.catalog(a)
    require('readinknative/articleimages').cancel(a)
    local c=a.articleReturn
    if not c or not c.publisher then return end
    require('readinknative/readerlinks').reset(a);a:clearTextSelection();a.toolbar=false;a.panel=nil;a.mode='articles'
    local r=c.routes[c.kind];r.loading=nil;a:draw();S.covers(a);if a.client:ready()and r.data and os.time()-(r.data.updated or 0)>=300 then S.fetch(a,false)end
end
function S.run(a,label,operation,done)
    local c=context(a);local r=c.routes[c.kind];local epoch=c.epoch;local snapshot=a.client.data;local trace=tag(c,r.failedRow and r.failedRow.reviewId)
    require('readinknative/offline').beforeForeground(a);a.coverJobs:cancel()
    r.loading=label;r.error=nil;a:draw()
    a.jobs:run('',function()
        local child=require('readinknative/client'):new(snapshot)
        local phase='start';local publicUrl;local clock=require('ui/time');local mark=clock.monotonic();local stages={}
        local function checkpoint(value,url)
            local now=clock.monotonic();stages[#stages+1]=phase..'='..math.floor(clock.to_ms(now-mark));mark=now
            phase=value;if url then publicUrl=url;require('logger').info('ReadInk article trace original:',trace,require('readinknative/articleaccess').key(url):sub(1,12))end
        end
        local ok,result=pcall(operation,child,checkpoint)
        local lastPhase=phase;checkpoint('done');phase=lastPhase;require('logger').info('ReadInk article stages ms:',table.concat(stages,' '))
        local code=not ok and require('readinknative/errors').code(result)or nil
        return {ok=ok,result=ok and result or nil,error=code,phase=phase,publicUrl=not ok and publicUrl or nil},child.data
    end,function(ok,result,session)
        if not valid(a,c,r)or epoch~=c.epoch then return end
        r.loading=nil
        -- A read may refresh credentials before the public body fails. Preserve
        -- that refresh for this same account/route even on a CAPTCHA/error.
        if ok and session and tostring(session.vid)==tostring(c.vid)then a.client.data=session;a.client.session.data=session;a.client:commit()end
        if not ok or not result.ok then
            r.error=ok and result.error or require('readinknative/errors').code(result)
            if r.error=='ARTICLE_VERIFICATION_REQUIRED'and ok and result.publicUrl then
                local G=require('readinknative/articleaccess');local keyed,key=pcall(G.key,result.publicUrl)
                if keyed then
                    local saved,pause=pcall(G.record,c.vid,result.publicUrl)
                    c.publicBlocks=c.publicBlocks or{};c.publicBlocks[key]=saved and pause.untilTime or os.time()+300
                end
            end
            require('logger').warn('ReadInk article operation failed:',r.error,ok and result.phase or'worker',c.publisher and'publisher'or'collection',trace)
            a:draw();if r.failedRow then a:message(require('readinknative/errors').message(r.error))end;return
        end
        done(result.result,c,r)
    end,false,function()if valid(a,c,r)and epoch==c.epoch then r.loading=nil;a:draw()end end)
end
function S.fetch(a,append)
    local c=context(a);local r=c.routes[c.kind];if not r or r.loading then return end
    if not a.client:ready()then r.error='LOGIN_REQUIRED';a:draw();return end
    local kind=c.kind;local cursor=append and r.data and r.data.cursor or nil
    local oldCount=append and r.data and #r.data.rows or 0
    S.run(a,'正在加载文章…',function(client,phase)phase(c.publisher and'publisher-list'or'collection-list');return c.publisher and API.publisher(client,c.publisher,cursor)or API.list(client,kind,cursor)end,function(data,ctx,route)
        if append then
            data.rows=API.merge(route.data.rows,data.rows)
            if not ctx.publisher and data.more and #data.rows==oldCount then route.error='ARTICLE_CURSOR_STALLED';data.more=false end
        end
        route.data=data
        if not append then route.page=1 end
        local ok,err=pcall(save,ctx,route);if not ok then route.error=require('readinknative/errors').code(err)end
        if append and #data.rows>oldCount then route.page=math.floor(oldCount/S.capacity(a))+1 end
        a:draw();S.covers(a);if route.autoRead and ctx.publisher then readPublisher(a,ctx,route)end
    end)
end
function S.capacity(a)
    local l=a.view.layout;return math.max(1,math.floor((l.h-l.bottom-l.s(112))/l.s(112)))
end
function S.turn(a,delta)
    local c=context(a);local r=c.routes[c.kind];if not r then return end
    local pages=math.max(1,math.ceil(#(r.data and r.data.rows or{})/S.capacity(a)))
    if delta>0 and r.page>=pages and r.data and r.data.more then S.fetch(a,true);return end
    r.page=math.max(1,math.min(pages,(r.page or 1)+delta));a:draw();S.covers(a)
end
function S.covers(a)
    local c=context(a);local r=c.routes[c.kind];if not r or r.loading or not r.data or not valid(a,c,r)then return end
    a.coverJobs:cancel();local urls={};local M=require('readinknative/media');local C=require('readinknative/covercache');local cap=S.capacity(a)
    for i=(r.page-1)*cap+1,math.min(#r.data.rows,r.page*cap)do
        local url=r.data.rows[i].cover
        if url and not C.find(c.vid,url,true)then local ok,value=pcall(M.url,url);if ok then urls[#urls+1]=value end end
    end
    if #urls==0 then return end
    local page=r.page;local epoch=c.epoch
    a.coverJobs:run('',function()for _,url in ipairs(urls)do pcall(C.prepare,c.vid,url,true,true)end;return true end,function()
        if valid(a,c,r)and c.epoch==epoch and r.page==page then a:draw()end
    end,false)
end
local function openPrepared(a,c,r,row,path,meta)
    if not valid(a,c,r)then return end
    a.coverJobs:cancel()
    a:savePosition();require('readinknative/resident').park(a);a:clearTextSelection()
    a.book=H.book(meta);a.book.articleReviewId=row.reviewId;a.book.localFile=path;
    a.book.articlePreview=meta.preview;a.articleReturn=c;a.storeReturn=nil
    a.chapter=nil;a.chapters=nil;a.panel=nil;a.preview=false;a.pageIndex=nil;a.searchResults=nil;a.searchOwner=nil;a.catalogQuery='';a.notesPage=1;a.notesOnlyBookmarks=false
    r.loading='正在打开文章…';a:draw()
    require('readinknative/chapterloader').prepare(a,path,{chapterUid=1},function()
        if not valid(a,c,r)or a.articleReturn~=c then return end
        r.loading=nil;a:openDocument(path)
        if a.document then require('logger').info('ReadInk article trace reader:',tag(c,row.reviewId),r.openSource or'prepared')end
        if a.document and r.openStarted then require('logger').info('ReadInk article click-to-reader ms/source:',math.floor(require('ui/time').to_ms(require('ui/time').monotonic()-r.openStarted)),r.openSource,c.publisher and'publisher'or'collection')end
        r.openStarted=nil;r.openSource=nil
        if a.document and c.publisher then a.state.articleLast=a.state.articleLast or{};a.state.articleLast[tostring(c.publisher.bookId)]={reviewId=row.reviewId,updated=os.time()};a.state:flushProgress()end
        if a.document then require('readinknative/articleimages').start(a,row,meta)end
    end)
end
function S.open(a,row)
    local openedAt=require('ui/time').monotonic()
    local c=context(a);local r=c.routes[c.kind];if not valid(a,c,r)or r.loading then return end
    require('readinknative/articleimages').cancel(a)
    r.openStarted=r.publisherOpenStarted or openedAt;r.publisherOpenStarted=nil
    local path,meta=H.find(c.vid,row);r.openSource=path and'local'or'online'
    require('logger').info('ReadInk article trace click:',tag(c,row.reviewId),r.openSource,c.publisher and'publisher'or'collection')
    r.error=nil;r.failedRow=nil
    if path and not meta.requiresCheck then
        openPrepared(a,c,r,row,path,meta)
        return
    end
    if not a.client:ready()then r.error='LOGIN_REQUIRED';a:draw();return end
    r.failedRow=row
    local blocks=c.publicBlocks or{}
    S.run(a,'正在读取文章正文…',function(client,phase)
        phase('article-detail');local detail=API.detail(client,row)
        phase('article-url-cache');local path,record=require('readinknative/articleshared').reuse(client.data.vid,detail)
        if path then return {path=path,meta=record}end
        phase('article-body');local body=API.body(client,detail,function(url)
            phase('article-body',url);local G=require('readinknative/articleaccess')
            return G.read(client.data.vid,url,function()return API.fetch(url)end,blocks[G.key(url)])
        end)
        phase('article-cache');path,record=H.prepare(body,client.data.vid,detail,a.asyncChapterLoad or require('device'):isKindle())
        return {path=path,meta=record}
    end,function(result,ctx,route)route.failedRow=nil;openPrepared(a,ctx,route,row,result.path,result.meta)end)
end
function S.retry(a)
    local c=context(a);local r=c.routes[c.kind];if not r or r.loading then return end
    if r.failedRow then S.open(a,r.failedRow)else S.fetch(a,false)end
end
function S.returnFromReader(a)
    require('readinknative/articleimages').cancel(a)
    local c=a.articleReturn
    if not c or c.state~=a.state or c.vid~=a.client.data.vid then a:home();return end
    if c.publisher then a:home();return end
    a.jobs:cancel();a.coverJobs:cancel();require('readinknative/chapterloader').cancel(a);require('readinknative/readerlinks').reset(a)
    require('readinknative/input').close(a);a:clearTextSelection();a:savePosition(true)
    if a.document then a.document:close();a.document=nil end
    a.articleReturn=nil;a.book=nil;a.chapter=nil;a.chapters=nil;a.panel=nil;a.mode='articles'
    local r=c.routes[c.kind];if r then r.loading=nil end
    a:draw();S.covers(a)
end
function S.suspend(a)
    local c=a.articles;if not c then return end
    c.epoch=(c.epoch or 0)+1;local r=c.routes[c.kind];if r then r.loading=nil end
end
function S.back(a)
    local c=context(a)
    if c.publisher and a.document and a.articleReturn==c then require('logger').info('ReadInk article trace return-existing:',tag(c,a.book and a.book.articleReviewId),tag(c,c.routes[c.kind]and c.routes[c.kind].failedRow and c.routes[c.kind].failedRow.reviewId));a.jobs:cancel();a.coverJobs:cancel();a.mode='reader';a.toolbar=false;a:draw();return end
    if c.publisher then a:home();return end
    if a.articleReturn and not a.document then require('readinknative/chapterloader').cancel(a);a.articleReturn=nil;a.book=nil end
    local c=context(a);c.epoch=(c.epoch or 0)+1
    a.jobs:cancel();a.coverJobs:cancel();local r=c.routes[c.kind];if r then r.loading=nil end
    a:account()
end
return S
