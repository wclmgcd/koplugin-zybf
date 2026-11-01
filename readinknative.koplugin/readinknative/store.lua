-- Store navigation, account-scoped snapshots and guarded asynchronous results.
local API=require('readinknative/storeapi');local S={}
local function cache(app)
    local c=app.state.storeCache
    if type(c)~='table'or c.schema~=1 then c={schema=1,entries={},order={},pendingAdds={}};app.state.storeCache=c end
    c.entries=c.entries or{};c.order=c.order or{};c.pendingAdds=c.pendingAdds or{}
    return c
end
local function context(app)
    local c=app.store
    if not c or c.state~=app.state or c.vid~=app.client.data.vid then
        c={state=app.state,vid=app.client.data.vid,stack={}};app.store=c
    end
    return c
end
local function valid(app,ctx,route)
    return not app.closed and app.mode=='store'and app.store==ctx and ctx.state==app.state and ctx.vid==app.client.data.vid and ctx.route==route
end
local function present(app)
    app:draw();require('ui/uimanager'):forceRePaint()
end
local function covers(app)
    local UI=require('ui/uimanager');local ctx=context(app);local route=ctx.route
    if app.storeCoversTask then UI:unschedule(app.storeCoversTask)end
    if not route then app.storeCoversTask=nil;return end
    local page=route and route.page
    app.storeCoversTask=function()
        app.storeCoversTask=nil
        if not app.suspended and valid(app,ctx,route)and route.page==page then app:loadCovers()end
    end
    UI:scheduleIn(0.05,app.storeCoversTask)
end
local function save(app,route,defer)
    local c=cache(app);c.entries[route.key]=route.data
    for i=#c.order,1,-1 do if c.order[i]==route.key then table.remove(c.order,i)end end
    c.order[#c.order+1]=route.key
    while #c.order>12 do local key=table.remove(c.order,1);c.entries[key]=nil end
    if not(route.kind=='detail'and route.readRequested)then
        if defer then
            local state,vid=app.state,app.client.data.vid;local UI=require('ui/uimanager')
            if app.storeFlushTask then UI:unschedule(app.storeFlushTask)end
            app.storeFlushTask=function()app.storeFlushTask=nil;if not app.closed and app.state==state and app.client.data.vid==vid then state:flushStore()end end
            UI:scheduleIn(0.25,app.storeFlushTask)
        else app.state:flushStore()end
    end
end
function S.stop(app)
    if app.storeCoversTask then require('ui/uimanager'):unschedule(app.storeCoversTask);app.storeCoversTask=nil end
    if app.storeJobs and(app.storeJobs.active or app.storeJobs.queued or app.storeJobs.widget)then app.storeJobs:cancel()end
    if app.store then
        if app.store.refilling then app.store.refillAt=nil end
        app.store.refilling=nil;app.store.shuffleWaiter=nil
        local r=app.store.route;if r then r.shuffling=nil;r.shuffleEpoch=nil end
    end
end
function S.enter(app,tab)
    require('readinknative/readerlinks').reset(app)
    app.jobs:cancel();app.coverJobs:cancel();require('readinknative/input').close(app);app:clearTextSelection();app:savePosition()
    if app.document then app.document:close();app.document=nil end
    app.storeReturn=nil;app.panel=nil;app.mode='store'
    local ctx=context(app)
    if tab or not ctx.route then S.tab(app,tab or'home')else S.show(app,ctx.route,false)end
end
function S.tab(app,kind)
    if kind~='home'and kind~='categories'and kind~='ranks'then return end
    local ctx=context(app);ctx.tab=kind;ctx.stack={}
    S.show(app,{kind=kind,key=kind,title=({home='书城',categories='分类',ranks='排行榜'})[kind]},false)
end
function S.show(app,route,push)
    S.stop(app);app.jobs:cancel();app.coverJobs:cancel();local ctx=context(app)
    if push and ctx.route then ctx.stack[#ctx.stack+1]=ctx.route;if #ctx.stack>16 then table.remove(ctx.stack,1)end end
    ctx.route=route;route.page=route.page or 1;route.data=route.data or cache(app).entries[route.key]
    route.pagesCache=nil;route.loading=nil;route.loadEpoch=nil;route.readRequested=nil
    if route.kind=='home'and route.data and route.data.layout~=2 then route.data=nil end
    local needsFetch=not route.data or route.provisional
    if needsFetch and route.kind~='groups'and app.client:ready()then route.loading=true end
    app.mode='store';present(app)
    if needsFetch then S.fetch(app,false)end
    covers(app)
    if route.kind=='home'and route.data then S.refill(app)end
end
local function pool(app,route,incoming)
    local data=route.data;local seen={};local first
    for i,row in ipairs(data.items or{})do if row.kind=='section'and(row.title=='精选好书'or row.action=='refresh')then first=i;break end end
    if not first then return end
    local last=first
    for i=first+1,#data.items do if data.items[i].kind~='book'then break end;seen[data.items[i].book.bookId]=true;last=i end
    local available={}
    for _,list in ipairs({data.recommendationPool or{},incoming or{}})do
        for _,book in ipairs(list)do if not seen[book.bookId]and #available<30 then available[#available+1]=book;seen[book.bookId]=true end end
    end
    data.recommendationPool=available;return first,last,available
end
function S.refill(app)
    local ctx=context(app);local route=ctx.route
    if not route or route.kind~='home'or not route.data or not valid(app,ctx,route)or ctx.refilling or not app.client:ready()then return end
    local _,_,available=pool(app,route)
    if not available or #available>6 or(ctx.refillAt and os.time()-ctx.refillAt<20)then return end
    local owner={};ctx.refilling=owner;ctx.refillAt=os.time()
    local snapshot=app.client.data
    app.storeJobs=app.storeJobs or require('readinknative/inkjobs').new{NICE=10,TIMEOUT=20}
    app.storeJobs:run('',function()
        local c=require('readinknative/client'):new(snapshot);c.refresh=function()error('PRELOAD_AUTH_REFRESH_DEFERRED')end
        return API.recommendations(c)
    end,function(ok,books)
        if ctx.refilling~=owner then return end;ctx.refilling=nil
        if ok and valid(app,ctx,route)then pool(app,route,books);save(app,route,true)end
        local waiter=ctx.shuffleWaiter;ctx.shuffleWaiter=nil
        if waiter then waiter(ok)elseif ok and valid(app,ctx,route)then covers(app)end
    end,false)
end
function S.reserveBooks(app)
    local ctx=context(app);local r=ctx.route
    if not r or r.kind~='home'or not r.data then return{}end
    local out={};for i,b in ipairs(r.data.recommendationPool or{})do if i>6 then break end;out[#out+1]=b end
    return out
end
function S.shuffle(app)
    local ctx=context(app);local r=ctx.route
    if not r or not valid(app,ctx,r)or r.kind~='home'or not r.data or r.shuffling then return end
    local function swap()
        local first,last,available=pool(app,r)
        if not first or #available==0 then return false end
        local count=math.min(6,#available);local items={}
        for i=1,first do items[#items+1]=r.data.items[i]end
        for i=1,count do items[#items+1]={kind='book',book=table.remove(available,1)}end
        for i=last+1,#r.data.items do items[#items+1]=r.data.items[i]end
        r.data.items=items;r.shuffling=nil;r.shuffleError=nil
        save(app,r,true);present(app);covers(app);S.refill(app);return true
    end
    if swap()then return end
    if not app.client:ready()then app:message('请先登录微信读书。');return end
    r.shuffling=true;present(app)
    if ctx.refilling then
        ctx.shuffleWaiter=function(ok)
            if not valid(app,ctx,r)then return end
            r.shuffling=nil;if not ok or not swap()then r.shuffleError=true;app:draw()end
        end
        return
    end
    app:remote('',function(c)return API.recommendations(c)end,function(books)
        if not valid(app,ctx,r)then return end
        pool(app,r,books);r.shuffling=nil
        if not swap()then r.shuffleError=true;app:draw()end
    end,false,{valid=function()return valid(app,ctx,r)end,failed=function()
        if valid(app,ctx,r)then r.shuffling=nil;r.shuffleError=true;app:draw()end
    end,cancelled=function()if valid(app,ctx,r)then r.shuffling=nil;app:draw()end end})
end
function S.fetch(app,append,retry)
    local ctx=context(app);local route=ctx.route;if not route then return end
    if route.loading and route.loadEpoch==app.jobs.epoch and app.jobs.widget then return end
    if not app.client:ready()then app:message('请先在“我 → 账户”登录，再加载书城。');return end
    if route.kind=='groups'then return end
    local oldCount=route.data and #(route.data.items or{})or 0
    local cursor=append and route.data and route.data.cursor or 0
    local function load(c)
        if route.kind=='home'then return API.home(c)
        elseif route.kind=='categories'then return API.categories(c,false)
        elseif route.kind=='ranks'then return API.categories(c,true)
        elseif route.kind=='list'then return API.list(c,route.category,cursor)
        elseif route.kind=='search'then return API.search(c,route.query,cursor)
        elseif route.kind=='detail'then
            local A=require('readinknative/api');local book=A.info(c,route.book)
            return{book=API.book(book,true)or book,readContext=A.readContext(c,book)}
        end
    end
    local owner={};route.fetchOwner=owner;route.loading=true;route.error=nil;present(app)
    local function alive()return valid(app,ctx,route)and route.fetchOwner==owner end
    local function failed(error)
        if not alive()then return end
        route.loading=nil;route.loadEpoch=nil;route.readRequested=nil
        route.error=require('readinknative/errors').code(error)
        require('logger').info('ReadInk store read failed kind/code:',route.kind,route.error)
        route.addMessage=route.kind=='detail'and'图书详情未能更新，可点击开始阅读重试'or nil
        -- Only one repeatable read after a transient transport/server failure.
        -- Authentication, verification, schema errors and writes never retry.
        local transient=route.error=='NETWORK_FAILED'or route.error=='WORKER_FAILED'or route.error:match('^HTTP_50[0234]$')
        if not retry and transient then
            route.loading=true
            require('ui/uimanager'):scheduleIn(1,function()
                if not alive()or app.suspended then if alive()then route.loading=nil end;return end
                route.loading=nil;S.fetch(app,append,true)
            end)
        end
        app:draw()
    end
    app:remote(route.kind=='detail'and'读取图书详情'or append and'加载更多书籍'or'加载书城',function(c)
        local ok,result=pcall(load,c)
        return {ok=ok,data=ok and result or nil,error=not ok and require('readinknative/errors').code(result)or nil}
    end,function(result)
        if not alive()then return end
        route.loading=nil;route.loadEpoch=nil
        if not result.ok then failed(result.error);return end
        local data=result.data;route.readContext=data.readContext;data.readContext=nil;route.provisional=nil
        if append then data.items=API.merge(route.data.items,data.items)end
        route.data=data;route.error=data.cursorStalled and'STORE_CURSOR_STALLED'or nil;save(app,route,true)
        if append and #(data.items or{})>oldCount then
            local pages=S.pages(app)
            for i,page in ipairs(pages)do
                for _,row in ipairs(page)do if row.sourceIndex==oldCount+1 then route.page=i end end
            end
        elseif not append then route.page=1 end
        if route.readRequested then route.readRequested=nil;S.read(app);return end
        present(app);covers(app);if route.kind=='home'then S.refill(app)end
    end,false,{failed=failed,cancelled=function()if alive()then route.loading=nil;route.loadEpoch=nil;route.readRequested=nil;app:draw()end end})
    if route.loading then route.loadEpoch=app.jobs.epoch end
end
function S.category(app,value)
    if #value.children>0 then
        local all={id=value.id,title='全部 · '..value.title,rank=value.rank,total=value.total,children={}}
        local items={{kind='category',category=all}}
        for _,child in ipairs(value.children)do items[#items+1]={kind='category',category=child}end
        S.show(app,{kind='groups',key='groups:'..value.id,title=value.title,data={items=items}},true)
    else S.show(app,{kind='list',key='list:'..value.id..':'..value.rank,title=value.title,category=value},true)end
end
function S.detail(app,book)
    local key='book:'..book.bookId;local cached=cache(app).entries[key]
    if cached and(not cached.book or tostring(cached.book.bookId)~=tostring(book.bookId)or book.version and cached.book.version and tostring(book.version)~=tostring(cached.book.version))then cached=nil end
    S.show(app,{kind='detail',key=key,title='图书详情',book=book,detailTab='book',data=book.localFile and{book=book}or cached or{book=book},provisional=not book.localFile and not cached},true)
end
function S.search(app,localOnly)
    local state,vid,mode=app.state,app.client.data.vid,app.mode
    local route=app.store and app.store.route
    local initial=localOnly and app.query or route and route.kind=='search'and route.query or ''
    local hint=route and route.data and route.data.searchHint
    local function alive()return not app.closed and app.state==state and app.client.data.vid==vid and app.mode==mode end
    return require('readinknative/input').show(app,function(draft)
        local dialog
        local function submit(query)
            if not alive()then require('ui/uimanager'):close(dialog);return end
            query=tostring(query or ''):match('^%s*(.-)%s*$')
            if not query:find('%S')or #query>256 then app:message('请输入搜索词，最多 256 字节。');return end
            local history={query}
            for _,q in ipairs(state.searchHistory or{})do if q~=query and #history<20 then history[#history+1]=q end end
            state:setSearchHistory(history);require('ui/uimanager'):close(dialog)
            if localOnly then app.query=query;app.shelfPage=1;app:draw();app:loadCovers()
            else S.show(app,{kind='search',key='search:'..query,title='搜索 · '..query,query=query},true)end
        end
        dialog=require('readinknative/officialinput'):new{app=app,input=draft or initial or '',official={kind='search',submit=submit,hint=hint,
            history=function()return alive()and state.searchHistory or{}end,
            clear=function()if alive()then state:setSearchHistory({})end end}}
        return dialog
    end,initial)
end
function S.inShelf(app,id)
    for _,book in ipairs(app.state.books)do if tostring(book.bookId)==tostring(id)then return true end end
    return false
end
function S.pendingAdd(app,id)return cache(app).pendingAdds[tostring(id)]==true end
function S.adding(app,id)
    local o=app.shelfAddOperation
    return o and o.state==app.state and o.vid==app.client.data.vid and o.id==tostring(id)
        and(o.epoch==nil or o.epoch==app.jobs.epoch)and true or false
end
-- Shared explicit shelf mutation for store details and the reader's add icon.
-- Unknown results stay pending; a later tap verifies the shelf without replaying
-- the POST. Reading and its document/position remain untouched.
local function addBook(app,book,alive,notice)
    if not app.client:ready()then app:message('请先登录微信读书。');return end
    if book.localFile or book.article then app:message(book.article and'公众号文章请使用收藏。'or'本地书籍已在本机书架。');return end
    local id=tostring(book.bookId);local state,vid=app.state,app.client.data.vid
    if S.inShelf(app,id)then
        local hidden=state.hiddenBooks and state.hiddenBooks[id]
        if hidden then state.hiddenBooks[id]=nil end
        notice('已在微信书架中');present(app);if hidden then state:flush()end;return
    end
    local active=app.shelfAddOperation
    if active and active.state==state and active.vid==vid and active.id==id and active.epoch==app.jobs.epoch then return end
    local checkOnly=S.pendingAdd(app,id)
    local operation={state=state,vid=vid,id=id,checkOnly=checkOnly};app.shelfAddOperation=operation
    cache(app).pendingAdds[id]=true;notice(checkOnly and'正在核对微信书架…'or'正在加入微信书架…',true);present(app)
    -- This marker must reach disk before any POST, even though the feedback
    -- is painted first. An unknown outcome may only be verified, never replayed.
    local saved=pcall(state.flushStore,state)
    if not saved then
        app.shelfAddOperation=nil;cache(app).pendingAdds[id]=checkOnly and true or nil
        notice('本机加入状态未能保存，请稍后重试。');present(app);return
    end
    app:remote(checkOnly and'核对微信书架'or'加入微信书架',function(c)
        local ok,books,groups=pcall(function()if checkOnly then return require('readinknative/api').shelf(c)else return API.add(c,book)end end)
        return {ok=ok,books=ok and books or nil,groups=ok and groups or nil,error=not ok and require('readinknative/errors').code(books)or nil}
    end,function(result)
        if app.shelfAddOperation==operation then app.shelfAddOperation=nil end
        if not alive()or app.state~=state or app.client.data.vid~=vid then return end
        local message
        if result.ok then
            require('readinknative/shelfmodel').apply(app,{books=result.books,groups=result.groups or state.shelfGroups or{}})
            cache(app).pendingAdds[id]=nil
            if S.inShelf(app,id)then
                state.hiddenBooks=state.hiddenBooks or{};state.hiddenBooks[id]=nil;message='已加入微信书架'
            else message=checkOnly and'当前快照未找到此书，可重新手动加入'or'加入结果尚未确认，请核对书架';if not checkOnly then cache(app).pendingAdds[id]=true end end
        else message='结果未确认，请核对书架（'..result.error..'）'end
        notice(message);present(app);state:flush()
    end)
    if app.shelfAddOperation==operation then operation.epoch=app.jobs.epoch end
end
function S.addShelf(app)
    local ctx=context(app);local route=ctx.route
    if not valid(app,ctx,route)or not route or route.kind~='detail'then return end
    return addBook(app,route.data and route.data.book or route.book,function()return valid(app,ctx,route)end,function(message)route.addMessage=message end)
end
function S.addFromReader(app)
    local book=app.book
    if app.closed or app.suspended or app.mode~='reader'or not app.document or not book then return end
    local state,vid=app.state,app.client.data.vid;local id,version=tostring(book.bookId),tostring(book.version or 0)
    return addBook(app,book,function()
        return not app.closed and not app.suspended and app.mode=='reader'and app.state==state and app.client.data.vid==vid
            and app.book and tostring(app.book.bookId)==id and tostring(app.book.version or 0)==version
    end,function(message,progress)if not progress then app:message(message)end end)
end
-- Page contents use the same order as the official vertical store; rows never
-- overlap the fixed footer. A section header stays with its first book row.
function S.recent(app)
    local state=app.state;local books,seen,rank={},{},{}
    for i,book in ipairs(state.readingHistory or{})do rank[tostring(book.bookId)]=i end
    local function less(a,b)
        local x,y=tostring(a.bookId),tostring(b.bookId)
        local tx,ty=tonumber(state.recent[x]),tonumber(state.recent[y])
        if tx~=ty then return tx>ty end
        local rx,ry=rank[x]or math.huge,rank[y]or math.huge
        if rx~=ry then return rx<ry end
        return x<y
    end
    local function add(book)
        local id=tostring(book.bookId);local updated=tonumber((state.recent or{})[id])
        if not seen[id]and updated and updated==updated and updated>0 and updated<math.huge then
            local at=#books+1
            for i,current in ipairs(books)do if less(book,current)then at=i;break end end
            if at<=4 then table.insert(books,at,book);if #books>4 then table.remove(books)end end
            seen[id]=true
        end
    end
    -- Shelf snapshots carry fresher metadata. Legacy store entries provide only
    -- metadata: a click without a saved reading position is not a recent read.
    for _,book in ipairs(state.books or{})do add(book)end
    for _,book in ipairs(state.readingHistory or{})do add(book)end
    for _,book in ipairs(cache(app).recent or{})do add(book)end
    return books
end
function S.pages(app)
    local route=context(app).route;local l=app.view.layout;local items=route and route.data and route.data.items or{}
    local key=table.concat({l.w,l.h,l.bottom,l.side,l.s(76),l.s(128)},':')
    local cached=route and route.pagesCache
    if cached and cached.items==items and cached.layout==key and cached.books==app.state.books
        and cached.history==app.state.readingHistory and cached.recent==app.state.recent then return cached.pages end
    local display={}
    if route and route.kind=='home'then
        local recent=S.recent(app)
        if #recent>0 then
            display[#display+1]={kind='section',title='最近阅读',localRecent=true}
            display[#display+1]={kind='recent',books=recent}
        end
    end
    local index=1
    while index<=#items do
        local row=items[index]
        if route.kind=='home'and row.kind=='category'and row.card then
            local next=items[index+1]
            local paired=next and next.kind=='category'and next.card
            display[#display+1]={kind='categoryPair',leftCategory=row.category,rightCategory=paired and next.category or nil,sourceIndex=index}
            index=index+(paired and 2 or 1)
        elseif route.kind=='home'and row.kind=='book'then
            local next=items[index+1]
            display[#display+1]={kind='pair',left=row.book,right=next and next.kind=='book'and next.book or nil,
                leftRank=row.rank,rightRank=next and next.kind=='book'and next.rank or nil,sourceIndex=index}
            index=index+(next and next.kind=='book'and 2 or 1)
        else
            local copy={};for k,v in pairs(row)do copy[k]=v end
            copy.sourceIndex=index;display[#display+1]=copy;index=index+1
        end
    end
    local top=route.kind=='home'and l.s(60)or l.s(88)
    local limit=l.h-l.bottom-top;local pages={{}};local used=0
    local coverWidth=math.floor((l.w-2*l.side-l.s(60))/4)
    for _,row in ipairs(display)do
        row.height=row.kind=='recent'and math.min(math.floor(coverWidth*1.44)+l.s(24),limit-l.s(76))or
            l.s(row.kind=='section'and 76 or row.kind=='category'and 72 or row.kind=='categoryPair'and 108 or row.kind=='pair'and(row.leftRank and 102 or 82)or row.kind=='browse'and 64 or 128)
    end
    for i,row in ipairs(display)do
        local required=row.height
        if row.kind=='section'and display[i+1]then required=required+display[i+1].height end
        if used>0 and used+required>limit then pages[#pages+1]={};used=0;if route.kind=='home'then limit=l.h-l.bottom end end
        pages[#pages][#pages[#pages]+1]=row;used=used+row.height
    end
    route.pagesCache={items=items,layout=key,books=app.state.books,history=app.state.readingHistory,recent=app.state.recent,pages=pages}
    return pages
end

function S.turn(app,delta)
    local route=context(app).route;if not route then return end
    if route.kind=='detail'then
        if route.detailTab=='intro'then route.textPage=math.max(1,math.min(route.textPages or 1,(route.textPage or 1)+delta));app:draw()end
        return
    end
    local pages=S.pages(app);local page=math.max(1,math.min(route.page or 1,#pages))
    if delta>0 and page==#pages and route.data and route.data.more then S.fetch(app,true);return end
    route.page=math.max(1,math.min(#pages,page+delta));present(app);covers(app)
end
function S.back(app)
    app.jobs:cancel();app.coverJobs:cancel();local ctx=context(app)
    if #ctx.stack>0 then S.show(app,table.remove(ctx.stack),false)
    else app:home()end
end
function S.read(app)
    local ctx=context(app);local route=ctx.route
    if not route or route.kind~='detail'then return end
    local book=route.data and route.data.book or route.book
    if not book.localFile and not pcall(require('readinknative/api').format,book)then app:message('这本书的线上格式尚未适配。');return end
    if not book.localFile and not app.client:ready()then app:message('请先登录微信读书。');return end
    route.readRequested=true;present(app)
    if route.loading and route.loadEpoch==app.jobs.epoch and app.jobs.widget then return end
    route.loading=nil;route.readRequested=nil
    app:openBook(book,ctx,route.readContext)
end
function S.returnFromReader(app)
    require('readinknative/readerlinks').reset(app)
    local ctx=app.storeReturn
    if not ctx or ctx.state~=app.state or ctx.vid~=app.client.data.vid then app:home();return end
    app.jobs:cancel();app.coverJobs:cancel();require('readinknative/input').close(app);app:clearTextSelection();app:savePosition()
    require('readinknative/readingstats').update(app)
    if app.flushTask then require('ui/uimanager'):unschedule(app.flushTask)end
    local document=app.document;app.document=nil
    if ctx.route then ctx.route.pagesCache=nil end
    app.storeReturn=nil;app.mode='store';app.panel=nil;present(app)
    if document then document:close()end
    (app.state.flushProgress or app.state.flush)(app.state);covers(app)
end
function S.visibleBooks(app)
    local ctx=context(app);local route=ctx.route;if not route then return{}end
    if route.kind=='detail'then return {route.data and route.data.book or route.book}end
    local pages=S.pages(app);local rows=pages[math.max(1,math.min(route.page or 1,#pages))];local books={}
    if route.category and route.category.headerImage then books[#books+1]={cover=route.category.headerImage}end
    for _,row in ipairs(rows)do
        if row.book then books[#books+1]=row.book end
        for _,category in ipairs({row.leftCategory,row.rightCategory})do if category.cover then books[#books+1]={cover=category.cover}end end
        for _,book in ipairs(row.books or{})do books[#books+1]=book end
        if row.headerImage then books[#books+1]={cover=row.headerImage}end
        if row.left then books[#books+1]=row.left end;if row.right then books[#books+1]=row.right end
    end
    return books
end
return S
