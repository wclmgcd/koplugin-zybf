-- Failure-only diagnostics. Never log URLs, credentials, text or file contents.
local D={};local last={}
function D.failure(stage,path,err,code)
 pcall(function()
  local parent=type(path)=='string'and path:match('^(.*)/[^/]+$')or'.'
  local key=stage..':'..parent..':'..tostring(code);local now=os.time()
  if last[key]and now-last[key]<10 then return end;last[key]=now
  require('logger').warn('ReadInk storage failure stage/path/errno/message:',stage,path,code or'unknown',tostring(err or'unknown'):gsub('[\r\n]',' '):sub(1,256))
  local lfs=require('libs/libkoreader-lfs');local folder=parent
  while folder and lfs.symlinkattributes(folder,'mode')~='directory'do folder=folder:match('^(.*)/[^/]+$')end
  if not folder then return end
  local count,slots=0,0
  for name in lfs.dir(folder)do if name~='.'and name~='..'then count=count+1;slots=slots+1+math.ceil(#name/13);if count>=20000 then break end end end
  local disk=require('util').diskUsage(folder)or{}
  require('logger').warn('ReadInk storage directory/count/capped/estimated-lfn-slots/free/total:',folder,count,count>=20000,slots,disk.available or'unknown',disk.total or'unknown')
  local f=io.open('/proc/mounts','rb');local raw=f and f:read(65536);if f then f:close()end
  local best,fs,options='',nil,nil
  for mount,kind,opts in(raw or''):gmatch('%S+%s+(%S+)%s+(%S+)%s+(%S+)[^\n]*')do
   mount=mount:gsub('\\040',' ')
   local absolute=folder
   if folder:sub(1,1)~='/'then absolute=(lfs.currentdir()or'.')..'/'..folder:gsub('^%./','')end
   if(absolute==mount or absolute:sub(1,#mount+1)==mount..'/'or mount=='/')and #mount>#best then best,fs,options=mount,kind,opts end
  end
  if fs then require('logger').warn('ReadInk storage mount/type/read-only:',best,fs,(','..options..','):find(',ro,',1,true)~=nil)end
 end)
end
function D.archive(writer,stage,path)
 local code,err
 pcall(function()
  local ffi=require('ffi');pcall(ffi.cdef,'int archive_errno(void*); const char *archive_error_string(void*);')
  local lib=ffi.loadlib('archive','13');code=tonumber(lib.archive_errno(writer.archive));local msg=lib.archive_error_string(writer.archive)
  if msg~=nil then err=ffi.string(msg)end
 end)
 return code,err or writer.err
end
return D
