-- Give independently selectable styles unique families in CRe; keep all glyph,
-- copyright and license data. Standard SFNT directory and head checksums rebuilt.
local M={MAX=48*1024*1024}
local function u16(s,p)local a,b=s:byte(p,p+1);assert(b,'FONT_TRUNCATED');return a*256+b end
local function u32(s,p)return u16(s,p)*65536+u16(s,p+2)end
local function b16(v)return string.char(math.floor(v/256)%256,v%256)end
local function b32(v)return b16(math.floor(v/65536))..b16(v%65536)end
local function luaSum(s)
 local value=0;local rest=#s%4;if rest>0 then s=s..string.rep('\0',4-rest)end
 for p=1,#s,4 do value=(value+u32(s,p))%4294967296 end;return value
end
-- Copy into aligned, bounded storage: unaligned uint32 reads fault on some
-- Kindles. Do not allocate a second full CJK font just to checksum it.
local sum=luaSum
local function fileSum(path,size,progress)
 local f=assert(io.open(path,'rb'),'FONT_READ_FAILED');local total,bytes=0,0
 local ok,err=pcall(function()
  while bytes<size do local amount=math.min(65536,size-bytes);local chunk=assert(f:read(amount),'FONT_TRUNCATED');assert(#chunk==amount,'FONT_TRUNCATED')
   total=(total+sum(chunk))%4294967296;bytes=bytes+amount;if progress then progress(bytes,size)end
  end
 end)
 f:close();if not ok then error(err,0)end;return total
end
do
 local ok,ffi=pcall(require,'ffi');local yes,bit=pcall(require,'bit')
 if ok and yes then
  local words=ffi.new('uint32_t[16384]');local swap=ffi.abi('le')and bit.bswap or function(v)return v end
  local function wordSum(count)local value=0;for i=0,count-1 do value=value+swap(words[i])end;return value end
  sum=function(s)
   local total=0;local pointer=ffi.cast('const uint8_t *',s)
   for start=0,#s-1,65536 do
    local size=math.min(65536,#s-start);local count=math.ceil(size/4)
    words[count-1]=0;ffi.copy(words,pointer+start,size)
    total=(total+wordSum(count))%4294967296
   end
   return total
  end
  fileSum=function(path,size,progress)
   require('ffi/posix_h');local fd=ffi.C.open(path,bit.bor(ffi.C.O_RDONLY,ffi.C.O_CLOEXEC));assert(fd>=0,'FONT_READ_FAILED')
   local total,bytes=0,0;local pointer=ffi.cast('uint8_t *',words)
   local good,err=pcall(function()
    while bytes<size do
     local amount=math.min(65536,size-bytes);local count=math.ceil(amount/4);words[count-1]=0;local offset=0
     while offset<amount do local got=tonumber(ffi.C.read(fd,pointer+offset,amount-offset))
      if got<0 and ffi.errno()==ffi.C.EINTR then got=0 else assert(got>0,'FONT_TRUNCATED')end;offset=offset+got
     end
     total=(total+wordSum(count))%4294967296;bytes=bytes+amount;if progress then progress(bytes,size)end
    end
   end)
   ffi.C.close(fd);if not good then error(err,0)end;return total
  end
 end
end
local function names(data,family)
 assert(u16(data,1)==0,'FONT_NAME_FORMAT_UNSUPPORTED');local n=u16(data,3);local offset=u16(data,5)
 assert(n<=4096 and offset>=6+12*n and offset<=#data,'FONT_NAME_REJECTED')
 local records,strings,total={},{},0
 for j=1,n do local p=7+(j-1)*12;local platform=u16(data,p);local id=u16(data,p+6);local len=u16(data,p+8);local off=u16(data,p+10)
  assert(offset+off+len<=#data,'FONT_NAME_REJECTED');local value=data:sub(offset+off+1,offset+off+len)
  if id==1 or id==4 or id==6 or id==16 or id==18 then
   if platform==0 or platform==3 then value=family:gsub('.',function(c)return'\0'..c end)
   elseif platform==1 then value=family end
  end
  assert(total+#value<=65535,'FONT_NAME_TOO_LARGE')
  records[#records+1]=data:sub(p,p+7)..b16(#value)..b16(total);strings[#strings+1]=value;total=total+#value
 end
 data=b16(0)..b16(n)..b16(6+12*n)..table.concat(records)..table.concat(strings)
 return data
end
function M.rename(s,family)
 assert(type(s)=='string'and #s>=28 and #s<=M.MAX,'FONT_TOO_LARGE')
 assert(type(family)=='string'and #family<90 and family:match('^[%w_-]+$'),'FONT_NAME_REJECTED')
 local magic=s:sub(1,4);assert(magic=='\0\1\0\0'or magic=='OTTO','FONT_FORMAT_REJECTED')
 local count=u16(s,5);assert(count>0 and count<=128 and 12+count*16<=#s,'FONT_DIRECTORY_REJECTED')
 local tables,seen={},{};local head
 for i=1,count do local pos=13+(i-1)*16;local tag=s:sub(pos,pos+3);local start=u32(s,pos+8);local size=u32(s,pos+12)
  assert(not seen[tag]and start>=12+count*16 and start+size<=#s,'FONT_TABLE_REJECTED');seen[tag]=true
  local data=s:sub(start+1,start+size)
  if tag=='name'then
   data=names(data,family)
  elseif tag=='head'then assert(size>=54,'FONT_HEAD_REJECTED');data=data:sub(1,8)..'\0\0\0\0'..data:sub(13)end
  tables[#tables+1]={tag=tag,data=data}
 end
 assert(seen.name and seen.head,'FONT_TABLE_MISSING')
 local offset=12+count*16;local directory,body={},{}
 for _,q in ipairs(tables)do
  directory[#directory+1]=q.tag..b32(sum(q.data))..b32(offset)..b32(#q.data)
  if q.tag=='head'then head=offset end
  local padded=q.data..string.rep('\0',(4-#q.data%4)%4);body[#body+1]=padded;offset=offset+#padded
 end
 local result=s:sub(1,12)..table.concat(directory)..table.concat(body)
 local adjust=(0xb1b0afba-sum(result))%4294967296
 return result:sub(1,head+8)..b32(adjust)..result:sub(head+13)
end
-- Stream the large glyph tables; only bounded name/head metadata is rewritten.
function M.file(source,target,family)
 assert(type(family)=='string'and #family<90 and family:match('^[%w_-]+$'),'FONT_NAME_REJECTED')
 local input=assert(io.open(source,'rb'),'FONT_READ_FAILED');local output
 local ok,result=pcall(function()
  local size=input:seek('end');assert(size>=28 and size<=M.MAX,'FONT_TOO_LARGE');input:seek('set',0)
  local header=assert(input:read(12),'FONT_TRUNCATED');local magic=header:sub(1,4)
  assert(magic=='\0\1\0\0'or magic=='OTTO','FONT_FORMAT_REJECTED')
  local count=u16(header,5);assert(count>0 and count<=128 and 12+count*16<=size,'FONT_DIRECTORY_REJECTED')
  local directory=assert(input:read(count*16));local tables,seen={},{}
  for i=1,count do local p=1+(i-1)*16;local tag=directory:sub(p,p+3);local start=u32(directory,p+8);local len=u32(directory,p+12)
   assert(not seen[tag]and start>=12+count*16 and start+len<=size,'FONT_TABLE_REJECTED');seen[tag]=true
   tables[#tables+1]={tag=tag,start=start,len=len}
  end
  assert(seen.name and seen.head,'FONT_TABLE_MISSING')
  output=assert(io.open(target,'wb'),'FONT_WRITE_FAILED');assert(output:write(header,string.rep('\0',count*16)),'FONT_WRITE_FAILED')
  local position=12+count*16;local entries={};local checksum=0;local head
  for _,q in ipairs(tables)do
   assert(input:seek('set',q.start),'FONT_READ_FAILED');local value=0;local len=q.len
   if q.tag=='name'or q.tag=='head'then
    assert(q.len<=1024*1024,'FONT_METADATA_TOO_LARGE');local data=assert(input:read(q.len),'FONT_TRUNCATED');assert(#data==q.len,'FONT_TRUNCATED')
    if q.tag=='name'then data=names(data,family)
    else assert(q.len>=54,'FONT_HEAD_REJECTED');data=data:sub(1,8)..'\0\0\0\0'..data:sub(13);head=position end
    len=#data;assert(output:write(data),'FONT_WRITE_FAILED');value=sum(data)
   else
    local remaining=q.len
    while remaining>0 do local amount=math.min(65536,remaining);local chunk=assert(input:read(amount),'FONT_TRUNCATED');assert(#chunk==amount,'FONT_TRUNCATED')
     assert(output:write(chunk),'FONT_WRITE_FAILED');value=(value+sum(chunk))%4294967296;remaining=remaining-amount
    end
   end
   local pad=(4-len%4)%4;assert(output:write(string.rep('\0',pad)),'FONT_WRITE_FAILED')
   entries[#entries+1]=q.tag..b32(value)..b32(position)..b32(len)
   checksum=(checksum+value)%4294967296;position=position+len+pad;assert(position<=M.MAX+1024*1024,'FONT_TOO_LARGE')
  end
  local prefix=header..table.concat(entries);assert(output:seek('set',0)and output:write(prefix),'FONT_WRITE_FAILED')
  local adjust=(0xb1b0afba-checksum-sum(prefix))%4294967296
  assert(output:seek('set',head+8)and output:write(b32(adjust))and output:close(),'FONT_WRITE_FAILED');output=nil
  return position
 end)
 input:close();if output then output:close()end
 if not ok then os.remove(target);error(result,0)end;return result
end
-- Only call on an owned temporary file. Append the small renamed metadata
-- and update its directory entry in place; glyph/copyright tables are never
-- recopied. On failure the caller discards the entire temporary file.
function M.inplace(path,family,progress)
 assert(type(family)=='string'and #family<90 and family:match('^[%w_-]+$'),'FONT_NAME_REJECTED')
 local f=assert(io.open(path,'r+b'),'FONT_WRITE_FAILED')
 local ok,result=pcall(function()
  local size=f:seek('end');assert(size>=28 and size<=M.MAX,'FONT_TOO_LARGE');assert(f:seek('set',0))
  local header=assert(f:read(12),'FONT_TRUNCATED');local magic=header:sub(1,4)
  assert(magic=='\0\1\0\0'or magic=='OTTO','FONT_FORMAT_REJECTED')
  local count=u16(header,5);assert(count>0 and count<=128 and 12+count*16<=size,'FONT_DIRECTORY_REJECTED')
  local directory=assert(f:read(count*16),'FONT_TRUNCATED');assert(#directory==count*16,'FONT_TRUNCATED')
  local seen={};local head,name;local ranges={}
  for i=1,count do
   local p=1+(i-1)*16;local tag=directory:sub(p,p+3);local start=u32(directory,p+8);local len=u32(directory,p+12)
   assert(not seen[tag]and start%4==0 and start>=12+count*16 and start+len<=size,'FONT_TABLE_REJECTED');seen[tag]=true
   ranges[#ranges+1]={start=start,finish=start+len}
   if tag=='name'then name={start=start,len=len,entry=12+p-1}
   elseif tag=='head'then assert(len>=54,'FONT_HEAD_REJECTED');head=start end
  end
  table.sort(ranges,function(a,b)return a.start<b.start end)
  for i=2,#ranges do assert(ranges[i].start>=ranges[i-1].finish,'FONT_TABLE_OVERLAP')end
  assert(name and head,'FONT_TABLE_MISSING');assert(name.len<=1024*1024,'FONT_METADATA_TOO_LARGE')
  assert(f:seek('set',name.start));local data=assert(f:read(name.len),'FONT_TRUNCATED');assert(#data==name.len,'FONT_TRUNCATED')
  data=names(data,family);local offset=size+(4-size%4)%4
  assert(offset+#data<=M.MAX+1024*1024,'FONT_TOO_LARGE')
  assert(f:seek('end')and f:write(string.rep('\0',offset-size),data,string.rep('\0',(4-#data%4)%4)),'FONT_WRITE_FAILED')
  local final=assert(f:seek('end'));assert(f:seek('set',name.entry+4)and f:write(b32(sum(data)),b32(offset),b32(#data)),'FONT_WRITE_FAILED')
  assert(f:seek('set',head+8)and f:write('\0\0\0\0')and f:flush(),'FONT_WRITE_FAILED')
  local total=fileSum(path,final,progress)
  assert(f:seek('set',head+8)and f:write(b32((0xb1b0afba-total)%4294967296))and f:flush(),'FONT_WRITE_FAILED')
  return final
 end)
 local closed=f:close();if not ok then error(result,0)end;assert(closed,'FONT_WRITE_FAILED');return result
end
return M
