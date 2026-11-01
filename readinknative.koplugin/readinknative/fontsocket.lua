-- Observe only. The original Kindle already has a larger receive buffer;
-- leave TCP autotuning and all socket settings under the kernel's control.
local M={}
function M.inspect(sock)
 local ffi=require('ffi');if ffi.os~='Linux'or not sock then return end
 local ok,fd=pcall(function()return tonumber(sock:getfd())end)
 if not ok or not fd or fd<0 or fd~=math.floor(fd)then return end
 pcall(ffi.cdef,[[int getsockopt(int,int,int,void*,unsigned int*);]])
 local good,result=pcall(function()
  local value=ffi.new('int[1]');local len=ffi.new('unsigned int[1]',ffi.sizeof(value))
  if ffi.C.getsockopt(fd,1,8,value,len)~=0 or len[0]~=ffi.sizeof(value)then return end
  local current=tonumber(value[0]);if current<=0 then return end
  return{before=current,after=current}
 end)
 if good then return result end
end
return M
