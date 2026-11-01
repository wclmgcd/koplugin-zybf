-- Account/book/version scoped hot cache. Never retain routes, documents,
-- callbacks, images or widgets. Row cardLayout/quoteLayout contain only measured
-- text and numbers; their renderer keys revalidate screen/font geometry.
local C={TTL=120,MAX_ENTRIES=24,MAX_ROWS=600,MAX_BYTES=1024*1024}
local function part(value)local s=tostring(value or'');return #s..':'..s end
function C.key(c,r)
    if not r.singleRange or not r.chapter or #r.ranges~=1 then return end
    local row=r.ranges[1];if type(row.range)~='string'then return end
    local values={c.vid,c.bookId,c.version,tostring(r.chapter.chapterUid),row.range,r.quote or row.quote or''}
    local source=row.foreign or r.foreign or{}
    for _,name in ipairs{'bookId','version','chapterUid','range','title','targetBookId','targetVersion','targetChapterUid'}do values[#values+1]=source[name]or''end
    for i,v in ipairs(values)do values[i]=part(v)end
    return table.concat(values)
end
local function copy(rows)local out={};for i,row in ipairs(rows or{})do out[i]=row end;return out end
local function groups(source,hydrate)
    local out={}
    for i,g in ipairs(source)do
        local v={};for k,value in pairs(g)do if k~='rows'and k~='publicRows'then v[k]=value end end
        v.publicRows=copy(g.publicRows or g.rows)
        if hydrate then v.rows=copy(v.publicRows)end
        out[i]=v
    end
    return out
end
local function textWeight(value)
    if type(value)=='string'then return #value end
    if type(value)~='table'then return 0 end
    local bytes=0;for k,v in pairs(value)do bytes=bytes+textWeight(k)+textWeight(v)end;return bytes
end
local function weight(gs,quoteLayout,key)
    local rows=0;for _,g in ipairs(gs)do rows=rows+#g.publicRows end
    return rows,textWeight(gs)+textWeight(quoteLayout)+#key
end
local function trim(c)
    local cache=c.thoughtCache or{}
    while true do
        local count,rows,bytes,oldest=0,0,0
        for key,e in pairs(cache)do
            local n,size=weight(e.groups,e.quoteLayout,key)
            count=count+1;rows=rows+n;bytes=bytes+size
            if not oldest or e.used<cache[oldest].used then oldest=key end
        end
        if count<=C.MAX_ENTRIES and rows<=C.MAX_ROWS and bytes<=C.MAX_BYTES then return end
        cache[oldest]=nil
    end
end
function C.save(c,r,at)
    local key=C.key(c,r);if not key or not r.loaded then return end
    c.thoughtCache=c.thoughtCache or{};c.thoughtCacheClock=(c.thoughtCacheClock or 0)+1
    local gs=groups(r.groups);local rows,bytes=weight(gs,r.quoteLayout,key)
    if rows>C.MAX_ROWS or bytes>C.MAX_BYTES then c.thoughtCache[key]=nil;return end
    c.thoughtCache[key]={groups=gs,nextRange=r.nextRange,at=at or os.time(),used=c.thoughtCacheClock,
        chapterUid=tostring(r.chapter.chapterUid),range=r.ranges[1].range,quoteLayout=r.quoteLayout}
    trim(c)
end
function C.restore(c,r)
    local key=C.key(c,r);local e=key and c.thoughtCache and c.thoughtCache[key];if not e then return end
    c.thoughtCacheClock=c.thoughtCacheClock+1;e.used=c.thoughtCacheClock
    r.groups=groups(e.groups,true);r.nextRange=e.nextRange;r.quoteLayout=e.quoteLayout;r.loaded=true
    return e.at
end
function C.invalidate(c,op)
    if not op.book or tostring(op.book.bookId)~=c.bookId or tostring(op.book.version or 0)~=c.version or not op.chapter then return end
    for key,e in pairs(c.thoughtCache or{})do
        if e.chapterUid==tostring(op.chapter.chapterUid)and e.range==op.range then c.thoughtCache[key]=nil end
    end
end
function C.replace(c,updated)
    for _,e in pairs(c.thoughtCache or{})do
        for _,g in ipairs(e.groups)do
            for i,row in ipairs(g.publicRows)do if row.reviewId==updated.reviewId then g.publicRows[i]=updated end end
        end
    end
    trim(c)
end
-- Compare API data, excluding the local text measurement cache. Stable data
-- keeps the existing row objects/layout and avoids a redundant E-Ink redraw.
function C.equal(a,b)
    if a==b then return true end
    if type(a)~=type(b)or type(a)~='table'then return false end
    for k,v in pairs(a)do if k~='cardLayout'and not C.equal(v,b[k])then return false end end
    for k in pairs(b)do if k~='cardLayout'and a[k]==nil then return false end end
    return true
end
return C
