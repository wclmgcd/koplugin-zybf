-- REA: official OfficialArticleService /mp/list and MP review detail contracts.
-- Public article HTML is fetched separately: no WeRead account headers/cookies.
local A={COUNT=50,LIMIT=3*1024*1024}
local function text(v,n)
    assert(type(v)=='string'and #v<=(n or 4096)and not v:find('%z'),'ARTICLE_SCHEMA_CHANGED');return v
end
function A.id(v)
    assert(type(v)=='string'and #v>0 and #v<=128 and v:match('^[%w_~+/=%-]+$'),'ARTICLE_SCHEMA_CHANGED');return v
end
function A.url(v)
    assert(type(v)=='string'and #v<=8192 and not v:find('[%c\\]'),'ARTICLE_URL_REJECTED')
    v=v:gsub('&amp;','&'):gsub('^http:','https:')
    assert(v:match('^https://mp%.weixin%.qq%.com/s[/?]')or v=='https://mp.weixin.qq.com/s','ARTICLE_URL_REJECTED')
    return v
end
local function cursor(v)
    return type(v)=='number'and v==v and v>=0 and v<=9007199254740991 and v%1==0 and v or nil
end
function A.row(r)
    assert(type(r)=='table','ARTICLE_SCHEMA_CHANGED')
    return {reviewId=A.id(r.reviewId),key=type(r.key)=='string'and text(r.key,8192)or nil,idx=assert(cursor(r.idx),'ARTICLE_SCHEMA_CHANGED'),
        title=text(r.title,2048),account=type(r.account)=='string'and text(r.account,1024)or'',
        cover=type(r.thumbUrl)=='string'and text(r.thumbUrl,4096)or nil,fromWechat=r.fromWechat==1 or r.fromWeChat==1,
        published=cursor(r.published),publisherBookId=type(r.publisherBookId)=='string'and A.id(r.publisherBookId)or nil,
        url=type(r.url)=='string'and text(r.url,8192)or nil,bookId=type(r.bookId)=='string'and text(r.bookId,128)or nil}
end
function A.merge(old,new)
    local rows,seen={},{}
    for _,list in ipairs{old or{},new or{}}do for _,r in ipairs(list)do
        if not seen[r.reviewId]then rows[#rows+1]=r;seen[r.reviewId]=true end
    end end
    assert(#rows<=5000,'ARTICLE_LIST_LIMIT');return rows
end
function A.snapshot(data)
    assert(type(data)=='table'and type(data.rows)=='table'and #data.rows<=5000 and type(data.more)=='boolean','ARTICLE_SCHEMA_CHANGED')
    local rows={}
    for _,r in ipairs(data.rows)do
        rows[#rows+1]=A.row{reviewId=r.reviewId,key=r.key,idx=r.idx,title=r.title,account=r.account,thumbUrl=r.cover,
            fromWechat=r.fromWechat and 1 or 0,url=r.url,bookId=r.bookId,published=r.published,publisherBookId=r.publisherBookId}
    end
    assert(not data.more or cursor(data.cursor),'ARTICLE_SCHEMA_CHANGED')
    return {rows=A.merge({},rows),cursor=cursor(data.cursor),more=data.more,synckey=cursor(data.synckey),updated=cursor(data.updated)}
end
function A.list(c,kind,maxIdx)
    assert(kind==0 or kind==1,'ARTICLE_SCHEMA_CHANGED')
    local q={count=A.COUNT,listType=kind,showWx=1}
    if maxIdx~=nil then q.maxIdx=assert(cursor(maxIdx),'ARTICLE_SCHEMA_CHANGED')else q.synckey=0 end
    local r=c:api('/mp/list',q)
    assert(type(r)=='table'and type(r.lists)=='table'and #r.lists<=A.COUNT,'ARTICLE_SCHEMA_CHANGED')
    local rows={};for _,v in ipairs(r.lists)do rows[#rows+1]=A.row(v)end
    local nextIdx=rows[#rows]and rows[#rows].idx
    local more=r.hasMore==1 or r.hasMore==true or(r.hasMore==nil and #rows==A.COUNT)
    assert(not more or(nextIdx and nextIdx~=maxIdx),'ARTICLE_CURSOR_STALLED')
    return {rows=A.merge({},rows),cursor=nextIdx,more=more,synckey=cursor(r.synckey),updated=os.time()}
end
-- Shelf type=3 is an MP subscription. Official MpService uses batches of
-- 50, advances the requested offset by 50, and ends only on an empty reply.
-- The sync reply can contain more/fewer items and duplicate review IDs.
function A.publisher(c,book,offset)
    local count=50;local q={bookId=A.id(tostring(book.bookId)),count=count}
    if offset~=nil then q.offset=assert(cursor(offset),'ARTICLE_SCHEMA_CHANGED')end
    local r=c:api('/mp/chapters',q)
    assert(type(r)=='table'and type(r.data)=='table'and #r.data<=5000,'ARTICLE_SCHEMA_CHANGED')
    local rows={}
    for i,v in ipairs(r.data)do
        assert(type(v)=='table'and type(v.mpInfo)=='table','ARTICLE_SCHEMA_CHANGED')
        local m=v.mpInfo
        rows[#rows+1]={reviewId=A.id(v.reviewId),idx=(offset or 0)+i,title=text(m.title,2048),account=book.title,
            cover=type(m.pic_url)=='string'and text(m.pic_url,4096)or nil,published=cursor(v.createTime),publisherBookId=tostring(book.bookId)}
    end
    return {rows=A.merge({},rows),cursor=(offset or 0)+(#r.data>0 and count or 0),more=#r.data>0,synckey=cursor(r.synckey),updated=os.time()}
end
function A.detail(c,row)
    local id=A.id(row.reviewId);local r=c:api('/review/single',{reviewId=id})
    assert(type(r)=='table'and type(r.review)=='table','ARTICLE_SCHEMA_CHANGED')
    local v=r.review;assert((not r.reviewId or r.reviewId==id)and v.reviewId==id and type(v.mpInfo)=='table','ARTICLE_SCHEMA_CHANGED')
    local m=v.mpInfo
    assert(m.payType==nil or cursor(m.payType),'ARTICLE_SCHEMA_CHANGED')
    assert(m.inner==0 or m.inner==1 or m.inner==true or m.inner==false or m.inner==nil,'ARTICLE_SCHEMA_CHANGED')
    return {reviewId=id,title=text(m.title or row.title,2048),account=text(m.mp_name or row.account or'',1024),
        url=not(m.inner==1 or m.inner==true)and A.url(m.doc_url or row.url)or nil,published=cursor(m.time),cover=m.pic_url or row.cover,
        internal=m.inner==1 or m.inner==true,bookId=(m.inner==1 or m.inner==true)and A.id(v.belongBookId)or nil,
        payType=cursor(m.payType)or 0}
end
-- These two routes are reads in the official APK; no purchase, membership
-- claim, collection change, comment or /mp/read mutation is made here.
function A.body(c,meta,publicRead)
    if meta.internal then
        local r=c:api('/book/chapterread',{bookId=A.id(meta.bookId),reviewId=A.id(meta.reviewId)})
        assert(type(r)=='table'and type(r.content)=='string','ARTICLE_SCHEMA_CHANGED')
        meta.bodySource='eink-internal';meta.fragment=true;meta.preview=r.isTraialReading~=false and r.isTraialReading~=0;meta.requiresCheck=true
        return text(r.content,A.LIMIT)
    end
    if meta.payType==2 then
        local url=A.url(meta.url)
        local r=c:api('/mp/getpaidinfo',nil,{urls={url},need_content=1})
        assert(type(r)=='table'and type(r.pay_appmsg_infos)=='table','ARTICLE_SCHEMA_CHANGED')
        local match
        for _,v in ipairs(r.pay_appmsg_infos)do if type(v)=='table'and A.url(v.url)==url then assert(not match,'ARTICLE_SCHEMA_CHANGED');match=v end end
        assert(match,'ARTICLE_SCHEMA_CHANGED');meta.requiresCheck=true
        if match.ispaid==1 or match.ispaid==true then meta.bodySource='eink-paid';return text(match.content,A.LIMIT)end
        -- Only the publicly returned preview may be shown without entitlement.
        meta.preview=true
    end
    -- Official E-Ink MpContentRequest: ordinary/preview articles read the
    -- public original URL. Native metadata/paid/internal RPCs remain separate.
    meta.bodySource='wechat-public'
    if publicRead then return publicRead(meta.url)end
    return A.fetch(meta.url)
end
function A.fetch(value)
    local url=A.url(value);local timer=require('socketutil')
    for attempt=1,3 do
        local stream=require('readinknative/articlestream').new();local streamError;local stoppedAtBody
        local timed,clock=pcall(require,'ui/time');local began=timed and clock.monotonic()
        local logged,logger=pcall(require,'logger');if logged then logger.info('ReadInk article public request started')end
        timer:set_timeout(10,25)
        local ok,accepted,status,headers=pcall(require('socket.http').request,{
            url=url,method='GET',redirect=false,
            -- LuaSocket's pump step may end normally once the complete balanced
            -- article subtree is received. request() still returns the parsed
            -- HTTP status/headers and closes this non-reused GET connection.
            -- No footer scripts/resources are needed for native reading.
            step=function(source,sink)
                local chunk,sourceError=source();local accepted,sinkError=sink(chunk,sourceError)
                if sourceError or not accepted then return nil,sourceError or sinkError end
                if stream.complete then stoppedAtBody=true;return nil end
                if chunk then return 1 end
            end,
            -- Official WRRequestUAInterceptor applies the native client UA even
            -- on ordinary original GETs; account credentials remain excluded.
            headers={['User-Agent']=require('readinknative/identity').current().ua,Accept='text/html',['Accept-Encoding']='identity'},
            sink=function(chunk)
                if chunk then local fed,err=pcall(stream.feed,stream,chunk);if not fed then streamError=err;return nil,'ARTICLE_STREAM_FAILED'end end
                return 1
            end})
        timer:reset_timeout()
        if streamError then error(streamError,0)end;assert(ok and accepted and tonumber(status),'NETWORK_FAILED')
        status=tonumber(status)
        if logged then
            logger.info('ReadInk article public response status:',status)
            if timed then logger.info('ReadInk article request ms/read-bytes/body-complete/early-stop:',math.floor(clock.to_ms(clock.monotonic()-began)),stream.received,stream.complete==true,stoppedAtBody==true)end
        end
        if status==200 then
            local logged,logger=pcall(require,'logger');if logged then logger.info('ReadInk article body/response bytes:',stream.bytes,stream.received)end
            return stream:finish()
        end
        assert((status==301 or status==302 or status==303 or status==307 or status==308)and attempt<3 and type(headers)=='table'and type(headers.location)=='string','ARTICLE_FETCH_FAILED')
        local nextUrl=require('socket.url').absolute(url,headers.location)
        -- Verification redirects are reported to the reader, never retried via a
        -- browser/proxy or sent authenticated WeRead headers.
        if nextUrl:find('/mp/verify',1,true)or nextUrl:find('/mp/wappoc_appmsgcaptcha',1,true)then error('ARTICLE_VERIFICATION_REQUIRED')end
        url=A.url(nextUrl)
    end
    error('ARTICLE_FETCH_FAILED')
end
return A
