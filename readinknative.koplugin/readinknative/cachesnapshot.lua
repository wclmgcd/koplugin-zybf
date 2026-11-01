-- Durable display totals and pagination hints, never deletion authority.
-- Files are still revalidated after every process restart, including USB edits.
local S={};local keys={'mp','books','unread','cover','chapters','temporary','all'}
local function path(vid,suffix)return require('readinknative/cachepath').meta(require('readinknative/paths').account(vid),'cache-inventory-'..suffix..'.json')end
local function read(vid,suffix,limit)
 local target=path(vid,suffix);if require('libs/libkoreader-lfs').symlinkattributes(target,'mode')~='file'then return end
 local f=require('readinknative/cachefiles').open(target,'rb');if not f then return end;local data=f:read(limit+1);f:close();if not data or #data>limit then return end
 local ok,r=pcall(require('rapidjson').decode,data)
 if ok and type(r)=='table'and r.schema==1 and r.vid==tostring(vid)then return r end
end
local function number(v)return type(v)=='number'and v==v and v>=0 and v<=9007199254740991 and v%1==0 end
function S.summary(vid)
 local r=read(vid,'summary',8192);if not r or not number(r.updated)or r.updated>os.time()+60 or type(r.groups)~='table'then return end
 local groups={};for _,k in ipairs(keys)do local g=r.groups[k];if type(g)~='table'or not number(g.count)or not number(g.bytes)then return end;groups[k]={count=g.count,bytes=g.bytes}end
 return groups,r.updated
end
local function write(vid,suffix,value)
 local target=path(vid,suffix);if require('libs/libkoreader-lfs').symlinkattributes(target..'.part','mode')=='link'then return end
 local f=assert(require('readinknative/cachefiles').open(target..'.part','wb'),'CACHE_SNAPSHOT_WRITE_FAILED');assert(f:write(require('rapidjson').encode(value)));assert(f:close());assert(require('readinknative/cachefiles').rename(target..'.part',target))
end
function S.save(vid,entries,groups)
 local rows={};for _,e in ipairs(entries)do
  if e.kind=='pagination'and e.refs and number(e.size)and number(e.modified)and number(e.changed)then
   rows[#rows+1]={name=e.name,size=e.size,modified=e.modified,changed=e.changed,refs=e.refs}
  end
 end
 write(vid,'hints',{schema=1,vid=tostring(vid),rows=rows})
 write(vid,'summary',{schema=1,vid=tostring(vid),updated=os.time(),groups=groups})
end
function S.hints(vid)
 local r=read(vid,'hints',4*1024*1024);local rows={};if not r or type(r.rows)~='table'or #r.rows>20000 then return rows end
 for _,e in ipairs(r.rows)do
  if type(e)=='table'and type(e.name)=='string'and require('readinknative/cache').classify(e.name)=='pagination' and number(e.size)and number(e.modified)and number(e.changed)and type(e.refs)=='table'and #e.refs<=10000 then
   local valid=true;for _,h in ipairs(e.refs)do if type(h)~='string'or #h~=64 or not h:match('^[a-f0-9]+$')then valid=false;break end end
   if valid then rows[e.name]=e end
  end
 end;return rows
end
return S
