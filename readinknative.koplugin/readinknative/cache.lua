local C={}
function C.path(vid,book,chapter,mode)
    assert(mode=='full' or mode=='preview','CACHE_MODE_INVALID')
    local key=require('ffi/sha2').sha256(tostring(book.bookId)..':'..tostring(chapter.chapterUid)..':'..tostring(book.version or 0))
    return require('readinknative/paths').cache(vid,key..'-'..mode..'.epub')
end
-- Limited account entitlements are recorded before the chapter is committed.
-- A cancelled write may leave metadata without a body, never an unrestricted body.
function C.accessPath(vid,book,chapter)return C.path(vid,book,chapter,'full')..'.access.json'end
function C.bookAccessPath(vid,book)
    return C.accessPath(vid,book,{chapterUid='book-access'})
end
local function limited(reason)return reason=='membership'or reason=='paying_membership'or reason=='short_time'end
local function accessRead(path)
    local f,err,code=require('readinknative/cachefiles').open(path,'rb');if not f then if code==2 then return nil end;return false end
    local raw=f:read(4097);f:close();if not raw or #raw>4096 then return false end
    local ok,r=pcall(require('rapidjson').decode,raw);if ok and type(r)=='table'then return r end;return false
end
local function accessWrite(path,r)
    local f=assert(require('readinknative/cachefiles').open(path..'.part','wb'),'CACHE_ACCESS_WRITE_FAILED')
    assert(f:write(require('rapidjson').encode(r)),'CACHE_ACCESS_WRITE_FAILED');assert(f:close(),'CACHE_ACCESS_WRITE_FAILED')
    assert(require('readinknative/cachefiles').rename(path..'.part',path),'CACHE_ACCESS_WRITE_FAILED')
end
-- A fresh server-confirmed book entitlement renews the limited receipts of
-- already downloaded chapters together. It cannot promote a preview, authorize
-- a download or cross an account/version. No chapter body is rewritten.
function C.recordBookAccess(vid,book)
    local p=book._readPermission;local now=os.time()
    if book._permissionError or type(p)~='table'or p.vid~=vid or p.bookId~=tostring(book.bookId)
        or type(p.checkedAt)~='number'or p.checkedAt>now or now-p.checkedAt>300 then return end
    if not(p.allowed and limited(p.reason))then return end
    local mode,reason=require('readinknative/permission').mode(book,{},vid,now)
    if mode~='full'or reason~=p.reason or type(p.accessUntil)~='number'or p.accessUntil<=now then return end
    accessWrite(C.bookAccessPath(vid,book),{schema=2,scope='book',vid=tostring(vid),bookId=tostring(book.bookId),
        version=tostring(book.version or 0),checkedAt=p.checkedAt,expiresAt=p.accessUntil,reason=p.reason})
end
local function accessRecord(vid,book,chapter,now)
    local r=accessRead(C.accessPath(vid,book,chapter));now=now or os.time()
    if r==nil then return nil elseif r==false then return false end
    if r.schema~=1 or r.vid~=tostring(vid)or r.bookId~=tostring(book.bookId)or r.chapterUid~=tostring(chapter.chapterUid)
        or r.version~=tostring(book.version or 0)or type(r.checkedAt)~='number'or type(r.expiresAt)~='number'or r.checkedAt>now then return false end
    if now<r.expiresAt then return r end
    local b=accessRead(C.bookAccessPath(vid,book))
    if limited(r.reason)and b and b.schema==2 and b.scope=='book'and b.vid==r.vid and b.bookId==r.bookId and b.version==r.version
        and limited(b.reason)and type(b.checkedAt)=='number'and b.checkedAt>=r.checkedAt and b.checkedAt<=now
        and type(b.expiresAt)=='number'and now<b.expiresAt then return b end
    return false
end
function C.recordAccess(vid,book,chapter,mode)
    if mode~='full'then return end
    local proof=book._readPermission;local path=C.accessPath(vid,book,chapter)
    local _,reason=require('readinknative/permission').mode(book,chapter,vid)
    local limited=proof and reason==proof.reason and proof.allowed and(proof.reason=='membership'or proof.reason=='paying_membership'or proof.reason=='short_time')
    if not limited then local ok,err,code=require('readinknative/cachefiles').remove(path);assert(ok or code==2,'CACHE_ACCESS_WRITE_FAILED');return end
    assert(type(proof.accessUntil)=='number'and proof.accessUntil>proof.checkedAt,'CACHE_ACCESS_INVALID')
    local data=require('rapidjson').encode{schema=1,vid=tostring(vid),bookId=tostring(book.bookId),chapterUid=tostring(chapter.chapterUid),
        version=tostring(book.version or 0),checkedAt=proof.checkedAt,expiresAt=proof.accessUntil,reason=proof.reason}
    local f=assert(require('readinknative/cachefiles').open(path..'.part','wb'),'CACHE_ACCESS_WRITE_FAILED');assert(f:write(data),'CACHE_ACCESS_WRITE_FAILED');assert(f:close(),'CACHE_ACCESS_WRITE_FAILED')
    assert(require('readinknative/cachefiles').rename(path..'.part',path),'CACHE_ACCESS_WRITE_FAILED')
end
function C.accessValid(vid,book,chapter,now)
    return accessRecord(vid,book,chapter,now)~=false
end
function C.accessExpiry(vid,book,chapter)
    local r=accessRecord(vid,book,chapter);if r then return r.expiresAt end
end
-- Physical presence is for download indicators/authorized reuse only. Reader
-- callers still use find(), which enforces the account's reading expiry.
function C.stored(vid,book,chapter,requestedMode)
    local lfs=require('libs/libkoreader-lfs')
    for _,mode in ipairs(requestedMode and{requestedMode}or{'full','preview'})do
        local path=require('readinknative/cachefiles').readPath(C.path(vid,book,chapter,mode))
        if path and lfs.attributes(path,'mode')=='file' and (lfs.attributes(path,'size')or 0)>0 then return path,mode end
    end
end
function C.find(vid,book,chapter)
    local path,mode=C.stored(vid,book,chapter)
    if path and(mode~='full'or C.accessValid(vid,book,chapter))then return path,mode end
    if mode=='full'then
        local preview=require('readinknative/cachefiles').readPath(C.path(vid,book,chapter,'preview'));local lfs=require('libs/libkoreader-lfs')
        if preview and lfs.attributes(preview,'mode')=='file'and(lfs.attributes(preview,'size')or 0)>0 then return preview,'preview'end
    end
end
function C.classify(name)
    name=require('readinknative/cachepath').plain(name)or''
    name=name:gsub('^legacy%-','')
    local avatar,avatarSize=name:match('^avatar%-([a-f0-9]+)%-(%d+)%-c1%.png$')
    if avatar and #avatar==64 and tonumber(avatarSize)>=8 and tonumber(avatarSize)<=256 then return'cover'end
    local avatarPart,pid=name:match('^(avatar%-[a-f0-9]+%-%d+%-c1%.png)%.worker(%d+)%.part$')
    if avatarPart and #pid<=16 and C.classify(avatarPart)=='cover'then return'temporary'end
    local illustration,imageExt=name:match('^illustration%-([a-f0-9]+)%.([a-z]+)$')
    if illustration and #illustration==64 and(imageExt=='jpg'or imageExt=='png'or imageExt=='webp'or imageExt=='gif')then return'illustration'end
    local pdf=name:match('^pdf%-([a-f0-9]+)%.pdf$');if pdf and #pdf==64 then return'full'end
    local receipt=name:match('^pdf%-([a-f0-9]+)%.pdf%.access%.json$');if receipt and #receipt==64 then return'access'end
    local related=name:match('^related%-edition%-([a-f0-9]+)%.json$')or name:match('^related%-quotes%-([a-f0-9]+)%.json$')or name:match('^related%-hot%-([a-f0-9]+)%.json$')or name:match('^related%-ranges%-([a-f0-9]+)%.json$');if related and #related==64 then return'source'end
    local url=name:match('^article%-url%-([a-f0-9]+)%.json$')or name:match('^article%-id%-([a-f0-9]+)%.json$');if url and #url==64 then return'articleUrl'end
    if name:match('^articles%-publisher%-[a-f0-9]+%.json$')or name:match('^articles%-list%-[01]%.json$')then return'articleList'end
    local article=name:match('^([a-f0-9]+)%-full%.epub%.article%.json$');if article and #article==64 then return'article'end
    local opening=name:match('^([a-f0-9]+)%-[a-z]+%.epub%.opening%.json$');if opening and #opening==64 then return'source'end
    local reader,readerMode=name:match('^([a-f0-9]+)%-([a-z]+)%.epub%.reader%.json$');if reader and #reader==64 and(readerMode=='full'or readerMode=='preview')then return'reader'end
    local thumb=name:match('^thumb%-([a-f0-9]+)%.png$');if thumb and #thumb==64 then return'cover'end
    local source,sourceMode=name:match('^([a-f0-9]+)%-([a-z]+)%.epub%.source%.json$');if source and #source==64 and(sourceMode=='full'or sourceMode=='preview')then return 'source'end
    local underline,underlineMode=name:match('^([a-f0-9]+)%-([a-z]+)%.epub%.underlines%.json$');if underline and #underline==64 and(underlineMode=='full'or underlineMode=='preview')then return 'source'end
    local pages=name:match('^pagination%-([a-f0-9]+)%.json$');if pages and #pages==64 then return'pagination'end
    local images,imageMode=name:match('^([a-f0-9]+)%-([a-z]+)%.epub%.images%.json$');if images and #images==64 and(imageMode=='full'or imageMode=='preview')then return 'images'end
    local access=name:match('^([a-f0-9]+)%-full%.epub%.access%.json$');if access and #access==64 then return 'access'end
    local stem,mode=name:match('^([a-f0-9]+)%-([a-z]+)%.epub$')
    if stem and #stem==64 and (mode=='full' or mode=='preview')then return mode end
    local hash,ext=name:match('^cover%-([a-f0-9]+)%.([a-z]+)$')
    if hash and #hash==64 and (ext=='jpg' or ext=='png' or ext=='webp' or ext=='gif')then return 'cover'end
    if name:sub(-5)=='.part' and C.classify(name:sub(1,-6))then return 'temporary'end
end
function C.inventory(vid,observe)
    local root=require('readinknative/paths').account(vid);local lfs=require('libs/libkoreader-lfs');local F=require('readinknative/cachefiles')
    local result,total={},0
    F.walk(root,observe,function(name,path)
        local attrs=lfs.symlinkattributes(path);local kind=F.kind(name)
        if kind and attrs and attrs.mode=='file'then
            local size=attrs.size or 0;result[#result+1]={name=name,path=path,size=size,kind=kind,modified=attrs.modification,changed=attrs.change};total=total+size
        end
    end)
    return result,total
end
function C.groups(vid,state,now,inventory)
    local entries,total
    if inventory then entries,total=inventory()else entries,total=C.inventory(vid)end;local G=require('readinknative/cachegroups')
    G.decorate(entries,state,now);require('readinknative/cacheengine').append(entries,vid)
    total=0;for _,e in ipairs(entries)do total=total+e.size end
    return G.summary(entries,total),entries
end
function C.matches(kind,entry)
    return kind==entry.category or(kind=='unread'and entry.unread)or kind=='all' or entry.kind==kind or(kind=='chapters'and(entry.kind=='full'or entry.kind=='preview'or entry.kind=='access'or entry.kind=='images'or entry.kind=='illustration'or entry.kind=='pagination'or entry.kind=='source'or entry.kind=='reader'or entry.kind=='article'or entry.kind=='articleUrl'or entry.kind=='readerFile'or entry.kind=='engine'))
end
function C.clear(vid,kind,state,observe,baseline)
    assert(kind=='all' or kind=='cover' or kind=='temporary' or kind=='chapters' or kind=='mp' or kind=='books' or kind=='unread','CACHE_CLEAR_KIND_INVALID')
    local deleted,failed=0,0
    local entries,all,metrics
    if baseline and(kind=='mp'or kind=='cover'or kind=='books'or kind=='unread')then
        entries,all,metrics=require('readinknative/cacheclear').plan(vid,kind,state,baseline,observe)
    else local _;_,entries=C.groups(vid,state,nil,observe and function()return C.inventory(vid,observe)end);all=entries end
    local selected={};for _,entry in ipairs(entries)do if C.matches(kind,entry)then selected[#selected+1]=entry end end
    local batch=require('readinknative/cachefiles').removals(selected)
    local markers={};local mpFailed=false;local removedPaths={}
    local function remove(entry)
        if entry.protected then failed=failed+1;if entry.category=='mp'then mpFailed=true end;return end
        if os.remove(entry.path)then
            batch.removed(entry.path)
            deleted=deleted+1;removedPaths[entry.path]=true
            if entry.path:find('/reader-files/',1,true)then pcall(require('libs/libkoreader-lfs').rmdir,entry.path:match('^(.*)/[^/]+$'))end
        else failed=failed+1;if entry.category=='mp'then mpFailed=true end end
    end
    for _,entry in ipairs(entries)do
        if C.matches(kind,entry)then
            -- Keep classification anchors until every MP resource is removed.
            -- Cancellation/failure must not orphan a body as ordinary books.
            if entry.category=='mp'and require('readinknative/cachefiles').basename(entry.name):gsub('%.part$',''):match('^[a-f0-9]+%-full%.epub%.article%.json$')then markers[#markers+1]=entry
            else remove(entry)end
        end
    end
    if not mpFailed then for _,entry in ipairs(markers)do remove(entry)end end
    batch.finish()
    if metrics then metrics.journalWrites=batch.stats.writes end
    if metrics then require('logger').info('ReadInk selected clear checked/markers/pages/mirror-dirs:',metrics.files,metrics.markers,metrics.pages,metrics.mirrorDirs,batch.stats.writes)end
    local remaining={};for _,entry in ipairs(all)do if not removedPaths[entry.path]and entry.kind~='engine'then remaining[#remaining+1]=entry end end
    return deleted,failed,remaining,metrics
end
return C
