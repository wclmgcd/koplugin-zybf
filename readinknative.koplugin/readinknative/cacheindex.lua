-- Session-local inventory, updated by Linux file notifications. Never supplies
-- deletion targets: clear() always inventories and verifies the filesystem.
-- A missing/overflowed watcher or cancelled scan falls back to a full scan.
local I={}
local function library()
 local ok,ffi=pcall(require,'ffi');if not ok or ffi.os~='Linux'then return end
 for _,s in ipairs{'int inotify_init1(int);','int inotify_init(void);','int inotify_add_watch(int,const char*,unsigned int);','int fcntl(int,int,...);','int close(int);','long read(int,void*,unsigned long);'}do pcall(ffi.cdef,s)end
 return ffi
end
local function fdNew()
 local ffi=library();if not ffi then return end
 local ok,fd=pcall(function()return ffi.C.inotify_init1(0x80800)end)
 if not ok or fd<0 then
  ok,fd=pcall(function()local f=ffi.C.inotify_init();if f>=0 and ffi.C.fcntl(f,4,ffi.cast('int',0x800))<0 then ffi.C.close(f);return -1 end;return f end)
 end
 return ok and fd>=0 and tonumber(fd)or nil
end
local function path(w,name)return require('readinknative/cachefiles').target(w.root,name)end
function I.close(a)
 if a.cacheIndexTick then require('ui/uimanager'):unschedule(a.cacheIndexTick);a.cacheIndexTick=nil end
 local w=a.cacheIndex;a.cacheIndex=nil
 if w and w.fd then pcall(function()library().C.close(w.fd)end);w.fd=nil end
end
local function drain(w)
 if not w.fd then w.invalid=true;return end
 local ffi=library();local bit=require('bit');local buf=ffi.new('uint8_t[65536]')
 for _=1,16 do
  local n=tonumber(ffi.C.read(w.fd,buf,65536))
  if n<0 then local e=ffi.errno();if e~=11 and e~=4 then w.invalid=true end;return end
  if n==0 then w.invalid=true;return end
  local offset=0
  while offset+16<=n do
   local ptr=buf+offset;local wd=tonumber(ffi.cast('int32_t*',ptr)[0]);local mask=tonumber(ffi.cast('uint32_t*',ptr+4)[0]);local size=tonumber(ffi.cast('uint32_t*',ptr+12)[0])
   if offset+16+size>n then w.invalid=true;return end
   local name=size>0 and ffi.string(ptr+16,size):match('^[^%z]*')or'';local scope=w.map[wd]
   if bit.band(mask,0x4000)~=0 then w.invalid=true
   elseif scope then
    if bit.band(mask,0xC00)~=0 or bit.band(mask,0x8000)~=0 or bit.band(mask,0x40000000)~=0 then
     w.invalid=true
     if bit.band(mask,0x8000)~=0 then w.map[wd]=nil end
    else
     local relative
     if scope==''then relative=name
     elseif scope:sub(1,13)=='reader-files/'then relative=scope:sub(14)..'/'..name
     elseif scope:match('^v2/data/[a-f0-9][a-f0-9]$')or scope:match('^v2/mirrors/[a-f0-9][a-f0-9]/[^/]+$')then relative=scope:sub(4)..'/'..name
     else w.invalid=true end
     if relative and require('readinknative/cachefiles').kind(relative)then w.dirty[relative]=true end
    end
   else w.invalid=true end
   offset=offset+16+size
  end
 end
 -- More than 1MiB of pending notifications is treated conservatively.
 w.invalid=true
end
function I.ensure(a)
 local id=tostring(a.client.data.vid or'guest');local w=a.cacheIndex
 if w and w.id~=id then I.close(a);w=nil end
 if not w then
  w={id=id,vid=a.client.data.vid,root=require('readinknative/paths').account(a.client.data.vid),fd=fdNew(),map={},dirty={},dirs={},invalid=true};a.cacheIndex=w
 end
 local UI=require('ui/uimanager')
 a.cacheIndexTick=a.cacheIndexTick or function()
  if a.closed or tostring(a.client.data.vid or'guest')~=w.id then I.close(a);return end
  if not a.suspended and not a.cachePlan and w.rows then drain(w)end
  UI:scheduleIn(5,a.cacheIndexTick)
 end
 UI:unschedule(a.cacheIndexTick);UI:scheduleIn(5,a.cacheIndexTick)
 return w
end
function I.plan(w)
 local cursor=require('readinknative/cachefiles').cursor(w.root)
 if w.rows then drain(w)end
 local plan={vid=w.vid,root=w.root,fd=w.fd,map={},dirty={},dirs={},full=not w.rows or w.invalid or not w.fd,rows=w.rows,pending={},restore=w.rows==nil and w.fd~=nil,ledgerOffset=cursor,ledgerFrom=w.ledgerOffset or 0}
 for k,v in pairs(w.map)do plan.map[k]=v end
 for k,v in pairs(w.pending or{})do plan.pending[k]=v end
 for k in pairs(w.dirty)do plan.dirty[k]=true end
 for k in pairs(w.dirs)do plan.dirs[k]=true end
 return plan
end
function I.observer(plan)
 return function(scope,folder)
  if not plan.fd then plan.watchFailed=true;return end
  local ok,wd=pcall(function()return library().C.inotify_add_watch(plan.fd,folder,0x03000FCC)end)
  if not ok or wd<0 then plan.watchFailed=true;return end
  plan.map[tonumber(wd)]=scope
 end
end
function I.collect(plan)
 local C=require('readinknative/cache');local lfs=require('libs/libkoreader-lfs');local observe=I.observer(plan)
 local F=require('readinknative/cachefiles')
 if not F.prepare(F.meta(plan.root,'cache-ledger.log'))then plan.watchFailed=true end
 if plan.full and plan.restore then
  local rows,total,meta=require('readinknative/cacheledger').restore(plan.vid,observe)
  if rows then plan.full=false;plan.restored=true;plan.checked=meta.checked;plan.ledgerOffset=meta.offset;plan.pending=meta.pending;return rows,total end
 end
 if plan.full then
  plan.pending,plan.ledgerOffset=require('readinknative/cachefiles').pending(plan.root)
  plan.checked=-1;local rows,total=C.inventory(plan.vid,observe)
  local hints=require('readinknative/cachesnapshot').hints(plan.vid)
  for _,r in ipairs(rows)do local old=hints[r.name];if old and old.size==r.size and old.modified==r.modified and old.changed==r.changed then r.refs=old.refs end end
  return rows,total
 end
 local events=require('readinknative/cachefiles').events(plan.root,plan.ledgerFrom,plan.ledgerOffset)
 if not events then plan.ledgerOffset=nil else
  for _,e in ipairs(events)do
   plan.dirty[e.name]=true
   if e.dirty then plan.pending[e.name]=plan.pending[e.name]or{};plan.pending[e.name][e.owner]=true
   elseif plan.pending[e.name]then plan.pending[e.name][e.owner]=nil;if not next(plan.pending[e.name])then plan.pending[e.name]=nil end end
  end
 end
 local rows={};for _,r in ipairs(plan.rows)do
  local target=path(plan,r.name)
  if target then rows[r.name]={name=r.name,path=target,kind=r.kind,size=r.size,refs=r.refs,modified=r.modified,changed=r.changed}end
 end
 plan.checked=0
 for name in pairs(plan.dirty)do
  local kind=F.kind(name);local target=kind and path(plan,name);local attrs=target and lfs.symlinkattributes(target);plan.checked=plan.checked+1
  if attrs and attrs.mode=='file'then rows[name]={name=name,path=target,kind=kind,size=attrs.size or 0,modified=attrs.modification,changed=attrs.change}else rows[name]=nil end
 end
 local result,total={},0;for _,r in pairs(rows)do result[#result+1]=r;total=total+r.size end
 return result,total
end
function I.pack(plan,entries)
 local rows={}
 for _,e in ipairs(entries or{})do if e.kind~='engine'then rows[#rows+1]={name=e.name,kind=e.kind,size=e.size,refs=e.refs,modified=e.modified,changed=e.changed}end end
 return{rows=rows,map=plan.map,valid=plan.fd~=nil and not plan.watchFailed,full=plan.full,checked=plan.checked or-1,restored=plan.restored==true,pending=plan.pending,ledgerOffset=plan.ledgerOffset}
end
function I.accept(a,w,result,summary)
 if a.cacheIndex~=w or not result then return end
 if not result.valid then I.close(a);return end
 w.rows=result.rows;w.map=result.map;w.ledgerOffset=result.ledgerOffset;w.pending=result.pending;w.summary=summary;w.dirty={};w.dirs={};w.invalid=false
end
return I
