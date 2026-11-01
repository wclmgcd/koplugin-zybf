-- A verification result applies to the requested article URL. It is not proof
-- that every other article/account route is blocked. Persist local pauses;
-- do not re-request the challenged URL until the next explicit read after it.
local G={PAUSE=300,MAX_ENTRIES=128}
function G.path(vid)return require('readinknative/cachepath').meta(require('readinknative/paths').account(vid),'article-access.json')end
function G.key(url)return require('ffi/sha2').sha256((require('readinknative/articleapi').url(url):gsub('#.*$','')))end
local function active(r,now)
    return type(r)=='table'and type(r.observedAt)=='number'and r.observedAt%1==0 and type(r.untilTime)=='number'
        and r.untilTime==r.observedAt+G.PAUSE and r.observedAt<=now and r.untilTime>now
end
local function read(vid)
    local path=G.path(vid);local F=require('readinknative/cachefiles')
    if not F.attributes(path,'mode')then path=require('readinknative/paths').account(vid)..'/article-access.json'end
    local f=F.open(path,'rb');if not f then return end
    local raw=f:read(65537);f:close();if #raw>65536 then return end
    local ok,r=pcall(require('rapidjson').decode,raw)
    if ok and type(r)=='table'and r.vid==tostring(vid)then
        if r.schema==1 and r.reason=='verification'then return r end
        if r.schema==2 and type(r.entries)=='table'then
            local n=0;for k in pairs(r.entries)do n=n+1;if n>G.MAX_ENTRIES or type(k)~='string'or #k~=64 or not k:match('^[a-f0-9]+$')then return end end
            return r
        end
    end
end
function G.status(vid,url,now)
    now=now or os.time();local r=read(vid);if not r then return end
    -- alpha36 could not identify the triggering URL. Preserve only that
    -- already-observed, short legacy pause until its original expiry.
    if r.schema==1 then if active(r,now)then return r end;return end
    local entry=r.entries[G.key(url)];if active(entry,now)then return entry end
end
function G.record(vid,url,now)
    now=now or os.time();local existing=G.status(vid,url,now);if existing then return existing end
    local old=read(vid);local r={schema=2,vid=tostring(vid),entries={}};local count=0
    if old and old.schema==2 then for key,value in pairs(old.entries)do
        if active(value,now)then r.entries[key]={observedAt=value.observedAt,untilTime=value.untilTime};count=count+1 end
    end end
    assert(count<G.MAX_ENTRIES,'ARTICLE_ACCESS_WRITE_FAILED')
    local entry={observedAt=now,untilTime=now+G.PAUSE};r.entries[G.key(url)]=entry
    local path=G.path(vid);local f=assert(require('readinknative/cachefiles').open(path..'.part','wb'),'ARTICLE_ACCESS_WRITE_FAILED')
    assert(f:write(require('rapidjson').encode(r)),'ARTICLE_ACCESS_WRITE_FAILED');assert(f:close(),'ARTICLE_ACCESS_WRITE_FAILED')
    assert(require('readinknative/cachefiles').rename(path..'.part',path),'ARTICLE_ACCESS_WRITE_FAILED');return entry
end
function G.read(vid,url,operation,memoryUntil)
    local now=os.time();local pause=G.status(vid,url,now)
    if pause or(type(memoryUntil)=='number'and memoryUntil>now)then
        require('logger').info('ReadInk article trace local-pause:',G.key(url):sub(1,12),math.max(0,(pause and pause.untilTime or memoryUntil)-now))
        error('ARTICLE_VERIFICATION_PENDING')
    end
    local ok,result=pcall(operation)
    if not ok then
        if require('readinknative/errors').code(result)=='ARTICLE_VERIFICATION_REQUIRED'then
            local saved=pcall(G.record,vid,url);if not saved then require('logger').warn('ReadInk article access state write failed')end
        end
        error(result,0)
    end
    return result
end
return G
