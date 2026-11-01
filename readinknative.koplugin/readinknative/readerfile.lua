-- CRe LVDirectoryContainer enumerates/stat()s every sibling before opening a
-- document. Account roots contain thousands of chapter/thumbnail sidecars.
-- Keep the public canonical path and all rights/positions there; only the
-- byte-identical provider file lives in a small per-document directory.
local R={MAX_BYTES=32*1024*1024}
function R.prepare(path)
 if type(path)~='string'then return path end
 local root,relative=require('readinknative/cachefiles').location(path)
 local name=relative and require('readinknative/cachefiles').basename(relative)
 if not root or not name then return path end
 local hash,mode=name:match('^([a-f0-9]+)%-([a-z]+)%.epub$')
 if not hash or #hash~=64 or(mode~='full'and mode~='preview')then return path end
 local lfs=require('libs/libkoreader-lfs');local a=lfs.attributes(path)
 if not a or a.mode~='file'or a.size>R.MAX_BYTES then return path end
 local target=require('readinknative/cachepath').mirror(root,name);local leaf=target:match('^(.*)/[^/]+$')
 local stamp=path..':'..tostring(a.size)..':'..tostring(a.modification);local record=target..'.stamp'
 local f=require('readinknative/cachefiles').open(record,'rb');local old=f and f:read(2048);if f then f:close()end
 if old==stamp and lfs.attributes(target,'size')==a.size then return target end
 assert(require('readinknative/cachefiles').prepare(target..'.part'),'READER_FILE_FAILED')
 local source=assert(require('readinknative/cachefiles').open(path,'rb'),'READER_FILE_FAILED');local dest=assert(require('readinknative/cachefiles').open(target..'.part','wb'),'READER_FILE_FAILED')
 local ok,err=pcall(function()
  local size=0
  while true do local data=source:read(65536);if not data then break end;size=size+#data;assert(dest:write(data),'READER_FILE_FAILED')end
  assert(size==a.size,'READER_FILE_FAILED')
 end)
 source:close();local closed=dest:close()
 if not ok or not closed then require('readinknative/cachefiles').remove(target..'.part');error(err or'READER_FILE_FAILED',0)end
 local now=lfs.attributes(path)
 assert(now and now.size==a.size and now.modification==a.modification,'READER_FILE_CHANGED')
 assert(require('readinknative/cachefiles').rename(target..'.part',target),'READER_FILE_FAILED')
 local f=assert(require('readinknative/cachefiles').open(record..'.part','wb'),'READER_FILE_FAILED');assert(f:write(stamp));assert(f:close());assert(require('readinknative/cachefiles').rename(record..'.part',record))
 return target
end
return R
