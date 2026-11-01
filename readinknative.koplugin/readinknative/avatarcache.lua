-- Small, account-local, circular grayscale avatars. Raw cover objects are only
-- read; concurrent avatar/cover workers never share a source .part writer.
local A={MAX_SIZE=256,MAX_BYTES=1536*1024,MAX_PIXELS=4*1024*1024,TTL=7*86400}
local function be(s,i,n)local v=0;for p=i,i+n-1 do local b=s:byte(p);if not b then return end;v=v*256+b end;return v end
local function le(s,i,n)local v=0;for p=i+n-1,i,-1 do local b=s:byte(p);if not b then return end;v=v*256+b end;return v end
function A.dimensions(s)
 if s:sub(1,8)=='\137PNG\r\n\26\n'then return be(s,17,4),be(s,21,4)end
 if s:sub(1,6)=='GIF87a'or s:sub(1,6)=='GIF89a'then return le(s,7,2),le(s,9,2)end
 if s:sub(1,2)=='\255\216'then
  local i=3
  while i<#s do
   if s:byte(i)~=255 then return end
   while s:byte(i)==255 do i=i+1 end
   local marker=s:byte(i);i=i+1
   if marker==217 or marker==218 then return end
   if marker~=1 and not(marker>=208 and marker<=216)then
    local n=be(s,i,2);if not n or n<2 or i+n-1>#s then return end
    if marker>=192 and marker<=207 and marker~=196 and marker~=200 and marker~=204 then return be(s,i+5,2),be(s,i+3,2)end
    i=i+n
   end
  end
 elseif s:sub(1,4)=='RIFF'and s:sub(9,12)=='WEBP'then
  local kind=s:sub(13,16)
  if kind=='VP8X'then local w,h=le(s,25,3),le(s,28,3);if w and h then return w+1,h+1 end
  elseif kind=='VP8L'and s:byte(21)==47 then local v=le(s,22,4);if v then return v%16384+1,math.floor(v/16384)%16384+1 end
  elseif kind=='VP8 'and s:sub(24,26)=='\157\1\42'then local w,h=le(s,27,2),le(s,29,2);if w and h then return w%16384,h%16384 end end
 end
end
function A.identity(vid,value,size)
 if type(size)~='number'or size%1~=0 or size<8 or size>A.MAX_SIZE then return end
 local ok,url=pcall(require('readinknative/media').url,value);if not ok then return end
 return tostring(vid)..':'..size..':'..url,url
end
function A.path(vid,url,size)
 return require('readinknative/paths').cache(vid,'avatar-'..require('ffi/sha2').sha256(url)..'-'..size..'-c1.png')
end
function A.find(vid,value,size)
 local key,url=A.identity(vid,value,size);if not key then return end
 local path=A.path(vid,url,size);local F=require('readinknative/cachefiles');local attrs=F.attributes(path)
 if not attrs or attrs.mode~='file'or attrs.size<24 or attrs.size>128*1024 then return end
 local f=F.open(path,'rb');local header=f and f:read(24);if f then f:close()end
 if not header or header:sub(1,8)~='\137PNG\r\n\26\n'or be(header,17,4)~=size or be(header,21,4)~=size then return end
 return path,tostring(attrs.modification)..':'..attrs.size,attrs.modification
end
function A.prepare(vid,value,size,force)
 local key,url=A.identity(vid,value,size);assert(key,'AVATAR_INVALID')
 local found=A.find(vid,url,size);if found and not force then return found end
 local M=require('readinknative/media');local R=require('ui/renderimage');local F=require('readinknative/cachefiles')
 local source=not force and M.find(vid,url);local data
 if source then
  local f=F.open(source,'rb');if f then data=f:read(A.MAX_BYTES+1);f:close()end
 end
 if not data then data=M.read(url,A.MAX_BYTES,{timeout=5})end
 assert(type(data)=='string'and #data<=A.MAX_BYTES,'AVATAR_TOO_LARGE')
 local w,h=A.dimensions(data);assert(w and h and w>0 and h>0 and w<=4096 and h<=4096 and w*h<=A.MAX_PIXELS,'AVATAR_DIMENSIONS')
 local scale=math.min(1,size/math.min(w,h),math.max(256,size*4)/math.max(w,h))
 local image,crop,scaled,gray;local path=A.path(vid,url,size)
 local ffi=require('ffi');pcall(ffi.cdef,'int getpid(void);');local part=path..'.worker'..tostring(tonumber(ffi.C.getpid()))..'.part'
 local ok,result=pcall(function()
  image=assert(R:renderImageData(data,#data,false,math.max(1,math.floor(w*scale)),math.max(1,math.floor(h*scale))),'AVATAR_DECODE_FAILED');data=nil
  local side=math.min(image:getWidth(),image:getHeight());local BB=require('ffi/blitbuffer')
  crop=BB.new(side,side,image:getType());crop:blitFrom(image,0,0,math.floor((image:getWidth()-side)/2),math.floor((image:getHeight()-side)/2),side,side)
  image:free();image=nil
  scaled=assert(R:scaleBlitBuffer(crop,size,size,false),'AVATAR_SCALE_FAILED');if scaled==crop then crop=nil else crop:free();crop=nil end
  gray=BB.new(size,size,BB.TYPE_BB8);gray:fill(BB.COLOR_WHITE);gray:alphablitFrom(scaled,0,0,0,0,size,size)
  scaled:free();scaled=nil
  local radius=size/2
  for y=0,size-1 do
   local edge=math.ceil(radius-math.sqrt(math.max(0,radius*radius-(y-radius+0.5)^2)))
   if edge>0 then gray:paintRect(0,y,edge,1,BB.COLOR_WHITE);gray:paintRect(size-edge,y,edge,1,BB.COLOR_WHITE)end
  end
  assert(F.writePNG(gray,part)~=false,'AVATAR_WRITE_FAILED');assert(F.rename(part,path),'AVATAR_WRITE_FAILED');return path
 end)
 for _,b in ipairs{image or false,crop or false,scaled or false,gray or false}do if b then pcall(b.free,b)end end
 if not ok then F.remove(part);error(result,0)end
 return result
end
function A.bytes(b)
 return (tonumber(b.stride)or b:getWidth()*4)*(tonumber(b.h)or b:getHeight())
end
function A.free(v)
 for _,entry in pairs(v.avatarImages or{})do pcall(entry.image.free,entry.image)end
 v.avatarImages={};v.avatarImageOrder={};v.avatarImageBytes=0;v.avatarBad={}
end
function A.invalidate(v,vid,url,size)
 local prefix=A.path(vid,url,size)..':'
 for key,entry in pairs(v.avatarImages or{})do if key:sub(1,#prefix)==prefix then
  pcall(entry.image.free,entry.image);v.avatarImageBytes=math.max(0,(v.avatarImageBytes or 0)-entry.bytes);v.avatarImages[key]=nil
 end end
 local order={};for _,key in ipairs(v.avatarImageOrder or{})do if v.avatarImages[key]then order[#order+1]=key end end;v.avatarImageOrder=order
 for key in pairs(v.avatarBad or{})do if key:sub(1,#prefix)==prefix then v.avatarBad[key]=nil end end
end
function A.load(v,vid,url,size)
 local path,stamp=A.find(vid,url,size);if not path then return end
 local key=path..':'..stamp
 v.avatarImages=v.avatarImages or{};v.avatarImageOrder=v.avatarImageOrder or{};v.avatarBad=v.avatarBad or{}
 if v.avatarBad[key]then return end
 local entry=v.avatarImages[key]
 if not entry then
  local ok,b=pcall(require('ui/renderimage').renderImageFile,require('ui/renderimage'),path,false)
  if not ok or not b then v.avatarBad[key]=true;return end
  if b:getWidth()~=size or b:getHeight()~=size then b:free();v.avatarBad[key]=true;return end
  entry={image=b,bytes=A.bytes(b)};v.avatarImages[key]=entry;v.avatarImageBytes=(v.avatarImageBytes or 0)+entry.bytes
 end
 for i=#v.avatarImageOrder,1,-1 do if v.avatarImageOrder[i]==key then table.remove(v.avatarImageOrder,i)end end
 v.avatarImageOrder[#v.avatarImageOrder+1]=key
 while #v.avatarImageOrder>1 and(#v.avatarImageOrder>64 or v.avatarImageBytes>512*1024)do
  local old=table.remove(v.avatarImageOrder,1);local item=v.avatarImages[old]
  if item then v.avatarImageBytes=v.avatarImageBytes-item.bytes;item.image:free();v.avatarImages[old]=nil end
 end
 return entry.image
end
return A
