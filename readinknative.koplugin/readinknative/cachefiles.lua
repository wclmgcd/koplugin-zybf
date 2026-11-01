-- Account-local append journal. Register before mutation, finalize after commit.
-- Each small append closes before the file operation; workers share O_APPEND,
-- never share an SQLite/stdio handle inherited from the parent.
local F={MAX=32*1024*1024,TAIL=8*1024*1024}
local P=require('readinknative/cachepath')
function F.basename(name)return P.plain(name)end
function F.kind(name)
 local plain,source=P.plain(name);if not plain then return end
 local C=require('readinknative/cache')
 if source then
  local kind=C.classify(source)
  if(kind=='full'or kind=='preview')and(plain==source or plain==source..'.stamp'or plain==source..'.part'or plain==source..'.stamp.part')then return plain:sub(-5)=='.part'and'temporary'or'readerFile'end
 else return C.classify(plain)end
end
function F.target(root,name)
 if not F.kind(name)then return end
 local target
 if name:match('^data/')or name:match('^mirrors/')then target=assert(P.root(root))..'/'..name
 elseif name:find('/',1,true)then target=root..'/reader-files/'..name else target=root..'/'..name end
 return P.safe(target)and target or nil
end
function F.location(path)
 local root,name,new=P.parse(path);if not root then return end
 if not new then name=name:gsub('^reader%-files/','')end
 if F.kind(name)then return root,name end
end
function F.walk(root,observe,visit)
 local lfs=require('libs/libkoreader-lfs')
 local oldDirectory=lfs.symlinkattributes(root,'mode')=='directory'
 local function dir(scope,path,fn)
  if lfs.symlinkattributes(path,'mode')~='directory'then return end
  if observe then observe(scope,path)end
  for name in lfs.dir(path)do if name~='.'and name~='..'then fn(name,path..'/'..name)end end
 end
 dir('',root,function(name,path)if require('readinknative/cache').classify(name)then visit(name,path)end end)
 if oldDirectory then dir('reader-files',root..'/reader-files',function(leaf,folder)
  local k=require('readinknative/cache').classify(leaf)
  if k=='full'or k=='preview'then dir('reader-files/'..leaf,folder,function(file,path)local name=leaf..'/'..file;if F.kind(name)then visit(name,path)end end)end
 end)end
 local base=P.root(root);if not base or lfs.symlinkattributes(base,'mode')~='directory'then return end
 dir('v2',base,function()end)
 for _,group in ipairs{'data','mirrors'}do
  dir('v2/'..group,base..'/'..group,function(bucket,folder)
   if bucket:match('^[a-f0-9][a-f0-9]$')then
    dir('v2/'..group..'/'..bucket,folder,function(leaf,path)
     if group=='data'then local name=group..'/'..bucket..'/'..leaf;if F.kind(name)then visit(name,path)end
     else
      local k=require('readinknative/cache').classify(leaf)
      if k=='full'or k=='preview'then dir('v2/mirrors/'..bucket..'/'..leaf,path,function(file,target)
       local name='mirrors/'..bucket..'/'..leaf..'/'..file;if F.kind(name)then visit(name,target)end
      end)end
     end
    end)
   end
  end)
 end
end
function F.attributes(path,key)local target=P.read(path);return target and require('libs/libkoreader-lfs').symlinkattributes(target,key)or nil end
function F.readPath(path)return P.read(path)end
function F.writePath(path)return P.write(path)end
function F.meta(root,name)return P.meta(root,name)end
local function failure(stage,path,err,code)require('readinknative/storagediag').failure(stage,path,err,code)end
function F.prepare(path)
 local target=P.write(path);local ok,err,code=P.ensure(target)
 if not ok then failure('mkdir',target,err,code);return nil,err,code end
 return target
end
function F.invalidate(root)
 -- Unlink only our own index; never follow a cache-supplied path.
 for _,name in ipairs{'cache-ledger.json','cache-ledger.json.part'}do
  local target=F.meta(root,name);if P.safe(target)then os.remove(target)end
 end
end
function F.cursor(root)
 local lfs=require('libs/libkoreader-lfs');local a=lfs.symlinkattributes(F.meta(root,'cache-ledger.log'))
 if not a then return 0 end
 if a.mode~='file'or a.size>=F.MAX then return end
 return a.size
end
local function append(root,event)
 local ffi=require('ffi');pcall(ffi.cdef,'int getpid(void);');event.owner=tostring(tonumber(ffi.C.getpid()))
 local ok=pcall(function()
  local lfs=require('libs/libkoreader-lfs');assert(lfs.symlinkattributes(root,'mode')=='directory')
  assert(F.cursor(root)~=nil)
  local data=require('rapidjson').encode(event)..'\n';assert(#data<4096)
  local target=assert(F.prepare(F.meta(root,'cache-ledger.log')));local file=assert(F.open(target,'ab'));local wrote=file:write(data);local closed=file:close();assert(wrote and closed)
 end)
 if not ok then F.invalidate(root)end
 return ok
end
function F.touch(path)
 local root,name=F.location(path);if root then return append(root,{name=name,dirty=true})end
 return true
end
function F.record(path)
 local root,name=F.location(path);if not root then return true end
 local a=require('libs/libkoreader-lfs').symlinkattributes(path)
 return append(root,a and a.mode=='file'and{name=name,size=a.size or 0,modified=a.modification,changed=a.change}or{name=name,absent=true})
end
function F.open(path,mode,...)
 local writing=type(mode)=='string'and(mode:find('[wa]')or mode:find('+',1,true))
 local target,err,code
 if writing then target,err,code=F.prepare(path);if not target then return nil,err,code end;F.touch(target)
 else target=P.read(path);if not target or not P.safe(target)then return nil,'CACHE_SYMLINK_REJECTED',13 end end
 local file;file,err,code=io.open(target,mode,...)
 if not file then if writing then failure('open',target,err,code)end;return nil,err,code end
 if not writing then return file end
 -- Keep the actual return values, and capture buffered write/close failures.
 local proxy={}
 return setmetatable(proxy,{__index=function(_,key)
  local value=file[key];if type(value)~='function'then return value end
  return function(_,...)
   local a,b,c=value(file,...)
   if(key=='write'or key=='flush'or key=='close')and not a then failure(key,target,b,c)end
   if a==file then return proxy,b,c end
   return a,b,c
  end
 end})
end
function F.rename(old,new)
 local source=P.write(old);local target,err,code=F.prepare(new);if not target then return nil,err,code end
 F.touch(source);F.touch(target)
 local ok;ok,err,code=os.rename(source,target)
 if ok then F.record(source);F.record(target)else failure('rename',target,err,code)end
 return ok,err,code
end
function F.remove(path)
 local targets={P.write(path)};local root,name,new=P.parse(path)
 -- Legacy sidecar invalidation must remove both generations; access metadata
 -- is identity scoped and likewise cannot revive an old fallback receipt.
 if root and not name:find('/',1,true)then targets[#targets+1]=path
 elseif root and new and name:match('^data/')and name:match('%.access%.json$')then targets[#targets+1]=root..'/'..assert(P.plain(name))end
 local result,err,code,failed,failedErr,failedCode
 local seen={};for _,target in ipairs(targets)do if not seen[target]then
  seen[target]=true
  if P.safe(target)then F.touch(target);local ok,e,c=os.remove(target);F.record(target);if ok then result=true else err,code=e,c;if c~=2 then failed=true;failedErr,failedCode=e,c;failure('remove',target,e,c)end end end
 end end
 if failed then return nil,failedErr,failedCode end
 return result,err,code
end
function F.writePNG(buffer,path)
 local target=F.prepare(path);if not target then return false end
 F.touch(target);local ok,result=pcall(buffer.writePNG,buffer,target)
 if not ok or result==false then failure('png-write',target,ok and'PNG writer returned false'or result,nil);return false end
 return result
end
function F.archiveOpen(writer,path)
 local target,err,code=F.prepare(path);if not target then return end
 F.touch(target)
 -- Writer.open discards its native handle on failure. Intercept that one
 -- assignment to capture archive_errno before libarchive state is released.
 local captured,message
 local proxy=setmetatable({}, {__index=writer,__newindex=function(_,k,v)
  if k=='archive'and v==nil and writer.archive then captured,message=require('readinknative/storagediag').archive(writer,'archive-open',target)end
  writer[k]=v
 end})
 local ok=writer.open(proxy,target,'zip')
 if not ok then failure('archive-open',target,message or writer.err,captured)end
 return ok
end
function F.archiveCheck(ok,writer,stage,path)
 if not ok then local code,err=require('readinknative/storagediag').archive(writer,stage,path);failure(stage,P.write(path),err,code)end
 return ok
end
-- Deletion emits the same per-file protocol in bounded append batches. Every
-- intent reaches the journal before the first unlink; interruption therefore
-- leaves pending files recoverable even when a completion batch was not sent.
function F.removals(entries)
 local roots,paths={},{};local stats={writes=0};local ffi=require('ffi');pcall(ffi.cdef,'int getpid(void);');local owner=tostring(tonumber(ffi.C.getpid()))
 local function flush(root,events)
  if #events==0 then return end
  local fd
  local ok=pcall(function()
   local lfs=require('libs/libkoreader-lfs');assert(lfs.symlinkattributes(root,'mode')=='directory'and F.cursor(root)~=nil)
   assert(F.prepare(F.meta(root,'cache-ledger.log')));local data={};for _,r in ipairs(events)do r.owner=owner;data[#data+1]=require('rapidjson').encode(r)..'\n'end
   data=table.concat(data);assert(#data<4096)
   if ffi.os=='Linux'then
    pcall(ffi.cdef,'int open(const char*,int,...);');pcall(ffi.cdef,'long write(int,const void*,unsigned long);');pcall(ffi.cdef,'int close(int);')
    fd=tonumber(ffi.C.open(F.meta(root,'cache-ledger.log'),0x20441,ffi.cast('int',384)));if fd<0 then failure('ledger-open',F.meta(root,'cache-ledger.log'),'open failed',ffi.errno())end;assert(fd>=0)
    local count=tonumber(ffi.C.write(fd,data,#data));if count~=#data then failure('ledger-write',F.meta(root,'cache-ledger.log'),'write failed or short write',count<0 and ffi.errno()or nil)end;assert(count==#data);stats.writes=stats.writes+1
   else
    local f=assert(F.open(F.meta(root,'cache-ledger.log'),'ab'));local wrote=f:write(data);local closed=f:close();assert(wrote and closed);stats.writes=stats.writes+1
   end
  end)
  if fd and fd>=0 then ffi.C.close(fd)end
  if not ok then F.invalidate(root)end
 end
 for _,entry in ipairs(entries)do
  local root,name=F.location(entry.path)
  if root and not paths[entry.path]then
   local list=roots[root]or{};roots[root]=list;paths[entry.path]={root=root,name=name}
   list[#list+1]={name=name,dirty=true};if #list==8 then flush(root,list);roots[root]={}end
  end
 end
 for root,list in pairs(roots)do flush(root,list);roots[root]={}end
 return{stats=stats,
  removed=function(path)
   local target=paths[path];if not target then return end
   local list=roots[target.root];list[#list+1]={name=target.name,absent=true}
   if #list==8 then flush(target.root,list);roots[target.root]={}end
  end,
  finish=function()for root,list in pairs(roots)do flush(root,list);roots[root]={}end end}
end
local function event(line)
 local ok,r=pcall(require('rapidjson').decode,line)
 if not ok or type(r)~='table'or type(r.name)~='string'or not F.kind(r.name)or type(r.owner)~='string'or #r.owner>16 or not r.owner:match('^%d+$')or(r.dirty and r.absent)then return end
 if r.dirty==true or r.absent==true then return r end
 if type(r.size)=='number'and r.size>=0 and r.size%1==0 and r.size<=9007199254740991 then return r end
end
function F.pending(root)
 local ending=F.cursor(root);if ending==nil then return end
 if ending==0 then return{},0 end
 local f=F.open(F.meta(root,'cache-ledger.log'),'rb');if not f then return end
 local data=f:read(ending);f:close();if not data or #data~=ending then return end
 local pending={}
 -- Rebuild only: retain valid starts even after an interrupted append. A
 -- partial start cannot precede a mutation (append closes first); a partial
 -- completion leaves its earlier valid start pending. New valid records
 -- appended after a torn prefix can be recovered from the final JSON frame.
 for line in data:gmatch('([^\n]+)\n')do
  local r=event(line)or event(line:match('.*({[^{}]*})$')or'')
  if r then
   if r.dirty then pending[r.name]=pending[r.name]or{};pending[r.name][r.owner]=true
   elseif pending[r.name]then pending[r.name][r.owner]=nil;if not next(pending[r.name])then pending[r.name]=nil end end
  end
 end
 return pending,ending
end
function F.events(root,offset,limit)
 local actual=F.cursor(root);local ending=limit or actual
 if not actual or not ending or ending>actual then return end
 if not ending or type(offset)~='number'or offset<0 or offset>ending or ending-offset>F.TAIL then return end
 if ending==offset then return{},ending end
 local file=F.open(F.meta(root,'cache-ledger.log'),'rb');if not file then return end
 local at=file:seek('set',offset);local data=at and file:read(ending-offset);file:close()
 if not data or #data~=ending-offset or data:sub(-1)~='\n'or(offset>0 and at~=offset)then return end
 local result={};for line in data:gmatch('([^\n]+)\n')do local r=event(line);if not r then return end;result[#result+1]=r end
 return result,ending
end
return F
