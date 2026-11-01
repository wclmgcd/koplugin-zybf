-- Native equivalents of the official image / MPOffline / book cleaners.
-- Only inventory-owned files are eligible. Never traverse a JSON-provided path.
local M={}
function M.decorate(entries,state,now)
    if #entries==0 then return entries end
    local mp,books,seen={},{},{};local C=require('readinknative/cache');now=now or os.time()
    for _,e in ipairs(entries)do
        local name=(require('readinknative/cachefiles').basename(e.name)or e.name):gsub('%.part$','')
        local hash=name:match('^([a-f0-9]+)%-full%.epub%.article%.json$')
        if hash and #hash==64 then mp[hash]=true end
    end
    for _,list in ipairs({state and state.books or{},state and state.readingHistory or{}})do
        for _,book in ipairs(list)do
            if not book.localFile and not book.article and book.type~=3 then
                local id=tostring(book.bookId);local read=tonumber((state.recent or{})[id])
                local key=id..':'..tostring(book.version or 0)
                if read and read>0 and read<=now-30*86400 and not seen[key]then
                    seen[key]=true
                    books[require('ffi/sha2').sha256(id..':book-access:'..tostring(book.version or 0))]=read
                    for _,ch in ipairs((state.catalogs or{})[id]or{})do
                        local hash=require('ffi/sha2').sha256(id..':'..tostring(ch.chapterUid)..':'..tostring(book.version or 0))
                        books[hash]=read
                    end
                end
            end
        end
    end
    local J=require('rapidjson');local lfs=require('libs/libkoreader-lfs')
    for _,e in ipairs(entries)do
        local name=(require('readinknative/cachefiles').basename(e.name)or e.name):gsub('%.part$','');local kind=C.classify(name)
        local hash=name:match('^([a-f0-9]+)%-[a-z]+%.epub')
        local category=(kind=='articleList'or kind=='articleUrl'or(hash and mp[hash]))and'mp'or kind=='cover'and'cover'or'books'
        local last=hash and books[hash]
        if kind=='pagination'and e.kind~='temporary'then
            local refs=e.refs
            if not refs then
                refs={};local known={}
                if e.size<=2*1024*1024 and lfs.symlinkattributes(e.path,'mode')=='file'then
                    local f=io.open(e.path,'rb');local data=f and f:read(2*1024*1024+1);if f then f:close()end
                    local ok,r=pcall(J.decode,data or'')
                    if ok and type(r)=='table'and type(r.entries)=='table'then
                        for _,row in pairs(r.entries)do
                            local h=type(row)=='table'and type(row.stamp)=='string'and row.stamp:match('/([a-f0-9]+)%-[a-z]+%.epub:')
                            if h and not known[h]then refs[#refs+1]=h;known[h]=true end
                        end
                    end
                end
                e.refs=refs
            end
            local mixed=false
            for _,h in ipairs(refs)do
                if mp[h]then category='mp'else mixed=true;last=math.max(last or 0,books[h]or now)end
            end
            if mixed then category='books'end
        end
        e.category=category
        -- Unknown ages and never-read books are retained rather than guessed old.
        e.unread=category=='books'and last~=nil and last>0 and last<=now-30*86400
    end
    return entries
end
function M.summary(entries,total)
    local groups={mp={count=0,bytes=0},books={count=0,bytes=0},unread={count=0,bytes=0},cover={count=0,bytes=0},
        chapters={count=0,bytes=0},temporary={count=0,bytes=0},all={count=#entries,bytes=total}}
    local function add(key,e)local g=groups[key];g.count=g.count+1;g.bytes=g.bytes+e.size end
    for _,e in ipairs(entries)do
        add(e.category,e);if e.unread then add('unread',e)end
        if e.kind=='temporary'then add('temporary',e)
        elseif e.kind~='cover'and e.kind~='articleList'then add('chapters',e)end
    end
    return groups
end
return M
