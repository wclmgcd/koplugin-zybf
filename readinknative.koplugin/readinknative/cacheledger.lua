-- Persistent cache membership/sizes. Cold queries reconcile names and the
-- mutation journal, not every file's attributes/content. Deletion never trusts it.
local M={MAX=8*1024*1024};local F=require('readinknative/cachefiles')
local function number(v)return type(v)=='number'and v==v and v>=0 and v%1==0 and v<=9007199254740991 end
local function validRefs(refs)
 if refs==nil then return true end
 if type(refs)~='table'or #refs>10000 then return end
 for k,h in pairs(refs)do if type(k)~='number'or k%1~=0 or k<1 or k>#refs or type(h)~='string'or #h~=64 or not h:match('^[a-f0-9]+$')then return end end
 return true
end
local function target(root,name)return F.target(root,name)end
function M.save(vid,entries,offset,pending)
 local root=require('readinknative/paths').account(vid);local file=F.meta(root,'cache-ledger.json')
 if not number(offset)or F.cursor(root)==nil then F.invalidate(root);return end
 local rows={};for _,e in ipairs(entries)do
  if e.kind~='engine'and F.kind(e.name)==e.kind then rows[#rows+1]={name=e.name,kind=e.kind,size=e.size,refs=e.refs,modified=e.modified,changed=e.changed}end
 end
 local value={schema=2,vid=tostring(vid),offset=offset,rows=rows,pending=pending or{}}
 local data=require('rapidjson').encode(value);if #data>M.MAX then F.invalidate(root);return end
 if require('libs/libkoreader-lfs').symlinkattributes(file..'.part','mode')=='link'then F.invalidate(root);return end
 local out=assert(F.open(file..'.part','wb'),'CACHE_LEDGER_WRITE_FAILED');assert(out:write(data));assert(out:close());assert(F.rename(file..'.part',file))
end
function M.restore(vid,observe)
 local root=require('readinknative/paths').account(vid);local lfs=require('libs/libkoreader-lfs')
 if lfs.symlinkattributes(root,'mode')~='directory'or lfs.symlinkattributes(F.meta(root,'cache-ledger.json'),'mode')~='file'then return end
 local f=F.open(F.meta(root,'cache-ledger.json'),'rb');if not f then return end;local data=f:read(M.MAX+1);f:close();if not data or #data>M.MAX then return end
 local ok,r=pcall(require('rapidjson').decode,data)
 if not ok or type(r)~='table'or r.schema~=2 or r.vid~=tostring(vid)or not number(r.offset)or type(r.rows)~='table'or #r.rows>100000 or type(r.pending)~='table'then return end
 local rows,pending={},{}
 for _,e in ipairs(r.rows)do
  if type(e)~='table'or type(e.name)~='string'or not F.kind(e.name)or F.kind(e.name)~=e.kind or not number(e.size)or not validRefs(e.refs)or rows[e.name]then return end
  rows[e.name]={name=e.name,path=target(root,e.name),kind=e.kind,size=e.size,refs=e.refs,modified=e.modified,changed=e.changed}
 end
 local n=0;for name,value in pairs(r.pending)do
  if type(value)~='table'or type(name)~='string'or not F.kind(name)then return end
  local owners={};for owner,active in pairs(value)do n=n+1;if active~=true or type(owner)~='string'or #owner>16 or not owner:match('^%d+$')or n>100000 then return end;owners[owner]=true end
  if next(owners)then pending[name]=owners end
 end
 local events,ending=F.events(root,r.offset);if not events then return end
 for _,e in ipairs(events)do
  if e.dirty then pending[e.name]=pending[e.name]or{};pending[e.name][e.owner]=true
  else
   if pending[e.name]then pending[e.name][e.owner]=nil;if not next(pending[e.name])then pending[e.name]=nil end end
   if e.absent then rows[e.name]=nil else rows[e.name]={name=e.name,path=target(root,e.name),kind=F.kind(e.name),size=e.size,modified=e.modified,changed=e.changed}end
  end
 end
 local checked=0
 local function refresh(name)
  local path=target(root,name);local a=path and lfs.symlinkattributes(path);checked=checked+1
  rows[name]=a and a.mode=='file'and{name=name,path=path,kind=F.kind(name),size=a.size or 0,modified=a.modification,changed=a.change}or nil
 end
 -- Enumerating names catches unlogged additions/deletions and old orphan .part
 -- files without stat/open on every previously registered chapter or thumbnail.
 local present={}
 F.walk(root,observe,function(name)
  present[name]=true;if not rows[name]or pending[name]then refresh(name)end
 end)
 for name in pairs(rows)do if not present[name]then rows[name]=nil end end
 for name in pairs(pending)do if not present[name]then pending[name]=nil end end
 local result,total={},0;for _,e in pairs(rows)do result[#result+1]=e;total=total+e.size end
 return result,total,{offset=ending,pending=pending,checked=checked}
end
return M
