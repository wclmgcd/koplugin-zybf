-- Reuse unrestricted cached articles in one account. Exact URL remains the
-- official cache key; signed identity additionally unifies local URL aliases.
local M={}
local function eligible(meta)
    return type(meta)=='table'and not meta.internal and not meta.requiresCheck and not meta.preview
        and(meta.payType==nil or meta.payType==0)and type(meta.url)=='string'
end
local function indexPath(vid,url)
    return require('readinknative/paths').cache(vid,'article-url-'..require('ffi/sha2').sha256(url)..'.json')
end
local function read(path,limit)
    local f=require('readinknative/cachefiles').open(path,'rb');if not f then return end
    local raw=f:read(limit+1);f:close();if #raw>limit then return end
    local ok,r=pcall(require('rapidjson').decode,raw);if ok and type(r)=='table'then return r end
end
local function write(path,value)
    local f=assert(require('readinknative/cachefiles').open(path..'.part','wb'),'ARTICLE_CACHE_WRITE_FAILED')
    assert(f:write(require('rapidjson').encode(value)),'ARTICLE_CACHE_WRITE_FAILED');assert(f:close(),'ARTICLE_CACHE_WRITE_FAILED')
    assert(require('readinknative/cachefiles').rename(path..'.part',path),'ARTICLE_CACHE_WRITE_FAILED')
end
function M.remember(vid,meta)
    if not eligible(meta)then return end
    local url=require('readinknative/articleapi').url(meta.url)
    write(indexPath(vid,url),{schema=1,vid=tostring(vid),urlHash=require('ffi/sha2').sha256(url),reviewId=meta.reviewId})
    local key=require('readinknative/articleidentity').key(url)
    if key then write(require('readinknative/paths').cache(vid,'article-id-'..key..'.json'),{schema=1,vid=tostring(vid),identity=key,reviewId=meta.reviewId})end
end
local function source(vid,meta)
    local H=require('readinknative/articlecontent');local lfs=require('libs/libkoreader-lfs')
    local function candidate(row)
        if not row or not pcall(require('readinknative/articleapi').id,row.reviewId)then return end
        local path,record=H.find(vid,row)
        if path and eligible(record)and require('readinknative/articleidentity').same(record.url,meta.url)and lfs.symlinkattributes(path,'mode')=='file'then return path,record end
    end
    local r=read(indexPath(vid,meta.url),4096)
    if r and r.schema==1 and r.vid==tostring(vid)and r.urlHash==require('ffi/sha2').sha256(meta.url)then
        local path,record=candidate(r);if path then return path,record end
    end
    local identity=require('readinknative/articleidentity').key(meta.url)
    if identity then
        local indexed=read(require('readinknative/paths').cache(vid,'article-id-'..identity..'.json'),4096)
        if indexed and indexed.schema==1 and indexed.vid==tostring(vid)and indexed.identity==identity then
            local path,record=candidate(indexed);if path then return path,record end
        end
    end
    -- Older versions have no URL index. Scan metadata filenames in the worker,
    -- without stat()ing every chapter or migrating the original article files.
    local root=require('readinknative/paths').account(vid)
    local found,metadata
    require('readinknative/cachefiles').walk(root,nil,function(name,path)
        if found then return end
        local base=require('readinknative/cachefiles').basename(name)
        if base and base:match('^[a-f0-9]+%-full%.epub%.article%.json$')and lfs.symlinkattributes(path,'mode')=='file'then
            local record=read(path,16384)
            if record and record.vid==tostring(vid)and require('readinknative/articleidentity').same(record.url,meta.url)then
                found,metadata=candidate(record)
            end
        end
    end)
    if found then pcall(M.remember,vid,metadata);return found,metadata end
end
function M.reuse(vid,meta)
    -- Require fresh detail proving a normal public article. Internal, paid and
    -- trial articles always retain their existing entitlement/read checks.
    if not eligible(meta)or meta.payType~=0 then return end
    local old,record=source(vid,meta);if not old then return end
    local H=require('readinknative/articlecontent');local path=H.path(vid,meta)
    if old==path then return path,record end
    local lfs=require('libs/libkoreader-lfs');local before=lfs.attributes(old)
    if not before or before.size>require('readinknative/content').MAX_TOTAL+1024*1024 then return end
    local pending=assert(require('readinknative/cachefiles').open(path..'.article.json.part','wb'),'ARTICLE_CACHE_WRITE_FAILED');assert(pending:write('{}'));assert(pending:close())
    local input=assert(require('readinknative/cachefiles').open(old,'rb'),'ARTICLE_CACHE_WRITE_FAILED');local output=require('readinknative/cachefiles').open(path..'.part','wb')
    if not output then input:close();error('ARTICLE_CACHE_WRITE_FAILED')end
    local ok,err=pcall(function()
        local bytes=0
        while true do local data=input:read(65536);if not data then break end;bytes=bytes+#data;assert(bytes<=before.size,'ARTICLE_CACHE_WRITE_FAILED');assert(output:write(data),'ARTICLE_CACHE_WRITE_FAILED')end
        assert(bytes==before.size,'ARTICLE_CACHE_WRITE_FAILED')
    end)
    input:close();local closed=output:close()
    if not ok or not closed then require('readinknative/cachefiles').remove(path..'.part');error(err or'ARTICLE_CACHE_WRITE_FAILED',0)end
    local after=lfs.attributes(old)
    assert(after and after.size==before.size and after.modification==before.modification,'ARTICLE_CACHE_WRITE_FAILED')
    assert(require('readinknative/cachefiles').rename(path..'.part',path),'ARTICLE_CACHE_WRITE_FAILED')
    local images=require('readinknative/images').status(old)
    if images then require('readinknative/images').marker(path,images)end
    local alias={schema=1,vid=tostring(vid),reviewId=meta.reviewId,title=meta.title,account=meta.account or'',url=meta.url,
        published=meta.published,updated=os.time(),images=images or record.images,rejectedImages=record.rejectedImages,imagesAttemptAt=record.imagesAttemptAt,
        sourceSchema=record.sourceSchema,emptyImages=record.emptyImages,bodySource=record.bodySource}
    write(path..'.article.json',alias);pcall(M.remember,vid,alias)
    require('logger').info('ReadInk article reused cached public identity:',record.url==meta.url and'exact-url'or'signed-identity')
    return path,alias
end
return M
