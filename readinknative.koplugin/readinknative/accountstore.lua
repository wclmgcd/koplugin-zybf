-- Native compact serialization avoids Lua's deeply indented whole-account
-- formatter on chapter completion. Commit one complete snapshot atomically;
-- legacy state.lua remains the migration fallback, never a concurrent writer.
local A={MAX_BYTES=32*1024*1024}
function A.pack(raw)
 local ffi=require('ffi');require('ffi/zlib_h');local z=ffi.loadlib('z',1)
 local n=z.compressBound(#raw);local buffer=ffi.new('uint8_t[?]',n);local size=ffi.new('unsigned long[1]',n)
 assert(z.compress2(buffer,size,raw,#raw,1)==0,'ACCOUNT_SNAPSHOT_COMPRESS')
 return ffi.string(buffer,size[0])
end
function A.unpack(raw,size)return require('ffi/zlib').zlib_uncompress(raw,size)end
local function readFile(path)
 local f=io.open(path,'rb');if not f then return end
 local raw=f:read(A.MAX_BYTES+65);f:close()
 if raw and #raw<=A.MAX_BYTES+64 then
  local data=raw
  if raw:sub(1,11)=='RIACCOUNT1\n' then
   local length,at=raw:match('^RIACCOUNT1\n(%d+)\n()')
   local n=length and #length<=8 and tonumber(length)
   if not n or n<1 or n>A.MAX_BYTES then return end
   local decoded;decoded,data=pcall(A.unpack,raw:sub(at),n)
   if not decoded or type(data)~='string'or #data~=n then return end
  end
  local ok,v=pcall(require('rapidjson').decode,data)
  if ok and type(v)=='table'and v.schema==1 and type(v.data)=='table'then return v.data end
 end
end
function A.read(root)
 return readFile(root..'/state.json.z')or readFile(root..'/state.json.z.old')or readFile(root..'/state.json')or readFile(root..'/state.json.old')
end
function A.save(root,data)
 local raw=require('rapidjson').encode{schema=1,data=data}
 assert(type(raw)=='string'and #raw<=A.MAX_BYTES,'ACCOUNT_SNAPSHOT_SIZE')
 local packed=A.pack(raw);assert(#packed<=A.MAX_BYTES,'ACCOUNT_SNAPSHOT_SIZE')
 local body='RIACCOUNT1\n'..#raw..'\n'..packed
 local path=root..'/state.json.z';local part=path..'.part'
 local file,err=io.open(part,'wb');assert(file,'ACCOUNT_SNAPSHOT_OPEN')
 local ok,result=pcall(function()
  assert(file:write(body),'ACCOUNT_SNAPSHOT_WRITE');assert(file:flush(),'ACCOUNT_SNAPSHOT_WRITE')
  assert(require('ffi/util').fsyncOpenedFile(file),'ACCOUNT_SNAPSHOT_SYNC')
  assert(file:close(),'ACCOUNT_SNAPSHOT_CLOSE');file=nil
  local attrs=require('libs/libkoreader-lfs').attributes(path)
  -- Keep the host's one-minute backup age so rapid consecutive saves cannot
  -- replace the last settled backup with an unflushed newer generation.
  if attrs and type(attrs.modification)=='number'and attrs.modification<os.time()-60 and readFile(path)then
   assert(os.rename(path,path..'.old'),'ACCOUNT_SNAPSHOT_BACKUP')
  end
  assert(os.rename(part,path),'ACCOUNT_SNAPSHOT_COMMIT')
  assert(require('ffi/util').fsyncDirectory(path),'ACCOUNT_SNAPSHOT_DIRECTORY_SYNC')
 end)
 if file then pcall(file.close,file)end
 if not ok then os.remove(part);error(result,0)end
end
return A
