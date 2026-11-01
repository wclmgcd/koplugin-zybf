-- Incremental ZIP -> owned font file. Only bounded headers/trailer are kept;
-- compressed payload is never staged on FAT or retained as a full Lua string.
local ffi=require('ffi');require('ffi/posix_h');require('ffi/zlib_h')
ffi.cdef[[typedef struct {const unsigned char *next_in;unsigned int avail_in;unsigned long total_in;
 unsigned char *next_out;unsigned int avail_out;unsigned long total_out;char *msg;void *state;
 void *(*zalloc)(void *,unsigned int,unsigned int);void (*zfree)(void *,void *);void *opaque;
 int data_type;unsigned long adler;unsigned long reserved;} readink_font_zstream;]]
pcall(ffi.cdef,[[const char *zlibVersion(void);int inflateInit2_(void *,int,const char *,int);int inflate(void *,int);int inflateEnd(void *);]])
local z=ffi.loadlib('z',1);local bit=require('bit');local M={MAX=48*1024*1024,TAIL=256*1024};local S={};S.__index=S
local function u16(s,p)local a,b=s:byte(p,p+1);assert(b,'FONT_ZIP_TRUNCATED');return a+b*256 end
local function u32(s,p)return u16(s,p)+u16(s,p+2)*65536 end
local function extras(s)
 local p=1;while p<=#s do local tag,len=u16(s,p),u16(s,p+2);assert(p+3+len<=#s,'FONT_ZIP_EXTRA')
  assert(tag~=1 and tag~=0x756e and tag~=0x000d,'FONT_ZIP_LINK_OR_ZIP64');p=p+4+len
 end
end
function M.new(path,size,wire)
 assert(type(size)=='number'and size>0 and size<=M.MAX and type(wire)=='number'and wire>0 and wire<=M.MAX,'FONT_SIZE_REJECTED')
 return setmetatable({path=path,size=size,limit=wire,wire=0,position=0,stage='header',need=4,header='',entries={},seen={},output=ffi.new('unsigned char[65536]'),fill=0,workMs=0,cpuMs=0,metadata=0},S)
end
function S:flush()
 if self.fill==0 then return end
 if self.entry.font then
  local offset=0;while offset<self.fill do local n=tonumber(ffi.C.write(self.fd,self.output+offset,self.fill-offset))
   if n<0 and ffi.errno()==ffi.C.EINTR then n=0 else assert(n>0,'FONT_WRITE_FAILED')end;offset=offset+n
  end
 end
 self.fill=0
end
function S:produced(n,start)
 if n==0 then return end;local e=self.entry;e.raw=e.raw+n
 assert(e.raw<=e.limit,'FONT_ARCHIVE_SIZE_REJECTED');e.crc=tonumber(z.crc32(e.crc,self.output+start,n));self.fill=self.fill+n
 if self.fill==65536 then self:flush()end
end
function S:startEntry(h)
 assert(#self.entries<16 and u16(h,5)<=20,'FONT_ZIP_VERSION_OR_ENTRIES')
 local flags,method=u16(h,7),u16(h,9);assert(bit.band(flags,bit.bnot(0x080e))==0 and(method==0 or method==8),'FONT_ZIP_ENCRYPTION_OR_METHOD')
 local nl,xl=u16(h,27),u16(h,29);assert(nl>0 and nl<=240 and #h==30+nl+xl,'FONT_ZIP_NAME')
 local name=h:sub(31,30+nl);assert(require('readinknative/content').safePath(name)and not self.seen[name],'FONT_ARCHIVE_PATH_REJECTED');extras(h:sub(31+nl))
 local directory=name:sub(-1)=='/';local metadata=directory or name:sub(1,9)=='__MACOSX/'or name=='.DS_Store'
 local font=not metadata;assert(metadata or name:match('^[%w_-]+%.ttf$')or name:match('^[%w_-]+%.otf$'),'FONT_ARCHIVE_PATH_REJECTED')
 if font then assert(not self.font,'FONT_ARCHIVE_ENTRY_REJECTED');self.font=name end
 local e={name=name,flags=flags,method=method,offset=self.position-#h,header=#h,raw=0,crc=0,compressed=0,font=font,directory=directory,
  declaredCrc=u32(h,15),declaredCompressed=u32(h,19),declaredRaw=u32(h,23),descriptor=bit.band(flags,8)~=0,limit=font and self.size or 1024*1024}
 assert(e.declaredRaw<=e.limit and e.declaredCompressed<=self.limit,'FONT_ARCHIVE_SIZE_REJECTED')
 if font and not e.descriptor then assert(e.declaredRaw==self.size,'FONT_ARCHIVE_SIZE_REJECTED')end
 self.seen[name]=e;self.entry=e;self.fill=0
 if font then
  local exclusive=ffi.os=='OSX'and 2048 or 128
  local fd=ffi.C.open(self.path,bit.bor(ffi.C.O_WRONLY,ffi.C.O_CREAT,exclusive,ffi.C.O_CLOEXEC),ffi.new('int',384));assert(fd>=0,'FONT_WRITE_FAILED');self.fd=fd;self.owned=true
 end
 if method==8 then
  self.stream=ffi.new('readink_font_zstream[1]');assert(z.inflateInit2_(ffi.cast('void*',self.stream),-15,z.zlibVersion(),ffi.sizeof(self.stream[0]))==0,'FONT_INFLATE_INIT');self.inflating=true
 else assert(e.descriptor or e.declaredRaw==e.declaredCompressed,'FONT_ZIP_STORED_SIZE')end
 self.stage='data';self.header='';self.need=4
end
function S:endData()
 self:flush();local e=self.entry
 if self.inflating then z.inflateEnd(ffi.cast('void*',self.stream));self.inflating=nil;self.stream=nil end
 assert(not e.font or e.raw==self.size,'FONT_ARCHIVE_SIZE_REJECTED')
 if not e.font then self.metadata=self.metadata+e.raw;assert(self.metadata<=1024*1024,'FONT_ARCHIVE_METADATA_REJECTED')end
 if e.directory then assert(e.raw==0,'FONT_ARCHIVE_METADATA_REJECTED')end
 if e.descriptor then self.stage='descriptor';self.header='';self.need=4
 else
  assert(e.crc==e.declaredCrc and e.raw==e.declaredRaw and e.compressed==e.declaredCompressed,'FONT_ZIP_LOCAL_MISMATCH')
  self.entries[#self.entries+1]=e;self.entry=nil;self.stage='header';self.header='';self.need=4
 end
end
function S:body(data,pos)
 local e=self.entry
 if e.method==0 then
  local size=e.descriptor and(e.font and self.size or e.declaredRaw)or e.declaredRaw
  if e.raw==size then self:endData();return pos end
  local n=math.min(#data-pos+1,size-e.raw,65536-self.fill);if n==0 then return pos end
  local start=self.fill;ffi.copy(self.output+start,ffi.cast('const unsigned char*',data)+pos-1,n);self:produced(n,start);e.compressed=e.compressed+n;self.position=self.position+n;pos=pos+n
  if e.raw==size then self:endData()end;return pos
 end
 if pos>#data then return pos end
 local st=self.stream[0];st.next_in=ffi.cast('const unsigned char*',data)+pos-1;st.avail_in=#data-pos+1
 repeat
  local input=tonumber(st.avail_in);local start=self.fill;st.next_out=self.output+start;st.avail_out=65536-start
  local rc=z.inflate(ffi.cast('void*',self.stream),0);local got=65536-start-tonumber(st.avail_out);local used=input-tonumber(st.avail_in)
  self:produced(got,start);e.compressed=e.compressed+used;self.position=self.position+used;pos=pos+used
  if rc==1 then self:endData();return pos end
  assert(rc==0 or(rc==-5 and st.avail_in==0),'FONT_ZIP_DEFLATE_FAILED')
  assert(used>0 or got>0 or st.avail_in==0,'FONT_ZIP_DEFLATE_STALLED')
 until st.avail_in==0 and st.avail_out>0
 return pos
end
function S:_feed(data)
 local pos=1
 while true do
  if self.stage=='data'then
   if pos>#data and not(self.entry.method==0 and self.entry.raw==(self.entry.font and self.size or self.entry.declaredRaw))then break end
   pos=self:body(data,pos)
  elseif self.stage=='trailer'then
   if pos>#data then break end
   local rest=data:sub(pos);assert(#self.trailer+#rest<=M.TAIL,'FONT_ZIP_TRAILER_TOO_LARGE');self.trailer=self.trailer..rest;self.position=self.position+#rest;break
  else
   if #self.header<self.need then
    if pos>#data then break end
    local n=math.min(self.need-#self.header,#data-pos+1);self.header=self.header..data:sub(pos,pos+n-1);pos=pos+n;self.position=self.position+n
   end
   if #self.header==self.need then
    if self.stage=='descriptor'then
     if self.need==4 then self.need=self.header=='PK\7\8'and 16 or 12
     else
      local p=self.need==16 and 5 or 1;local e=self.entry
      assert(u32(self.header,p)==e.crc and u32(self.header,p+4)==e.compressed and u32(self.header,p+8)==e.raw,'FONT_ZIP_DESCRIPTOR')
      self.entries[#self.entries+1]=e;self.entry=nil;self.header='';self.stage='header';self.need=4
     end
    elseif self.need==4 then
     if self.header=='PK\1\2'then self.centralOffset=self.position-4;self.trailer=self.header;self.header='';self.stage='trailer'
     else assert(self.header=='PK\3\4','FONT_ZIP_LOCAL_SIGNATURE');self.need=30 end
    elseif self.need==30 then
     local nl,xl=u16(self.header,27),u16(self.header,29);assert(nl>0 and nl<=240,'FONT_ZIP_NAME');self.need=30+nl+xl
    else self:startEntry(self.header)end
   end
  end
 end
end
function S:feed(data)
 assert(not self.closed,'FONT_STREAM_CLOSED');if not data or #data==0 then return 1 end
 self.wire=self.wire+#data;assert(self.wire<=self.limit,'FONT_TOO_LARGE')
 local clock=require('socket');local start,cpu=clock.gettime(),os.clock();self:_feed(data)
 self.workMs=self.workMs+(clock.gettime()-start)*1000;self.cpuMs=self.cpuMs+(os.clock()-cpu)*1000;return 1
end
function S:finish()
 assert(not self.closed and self.stage=='trailer'and self.font and self.wire==self.limit,'FONT_ZIP_TRUNCATED')
 local t,p=self.trailer,1;local central={}
 for i=1,#self.entries do
  assert(t:sub(p,p+3)=='PK\1\2'and #t>=p+45,'FONT_ZIP_CENTRAL')
  local nl,xl,cl=u16(t,p+28),u16(t,p+30),u16(t,p+32);assert(nl>0 and nl<=240 and p+45+nl+xl+cl<=#t,'FONT_ZIP_CENTRAL')
  local name=t:sub(p+46,p+45+nl);local e=self.seen[name];assert(e and not central[name],'FONT_ZIP_CENTRAL_ENTRIES');central[name]=true
  assert(u16(t,p+8)==e.flags and u16(t,p+10)==e.method and u32(t,p+16)==e.crc and u32(t,p+20)==e.compressed and u32(t,p+24)==e.raw and u32(t,p+42)==e.offset and u16(t,p+34)==0,'FONT_ZIP_CENTRAL_MISMATCH')
  local mode=bit.band(math.floor(u32(t,p+38)/65536),0xf000);assert(mode==0 or mode==(e.directory and 0x4000 or 0x8000),'FONT_ZIP_LINK_REJECTED')
  extras(t:sub(p+46+nl,p+45+nl+xl));p=p+46+nl+xl+cl
 end
 assert(t:sub(p,p+3)=='PK\5\6'and #t>=p+21,'FONT_ZIP_EOCD')
 assert(u16(t,p+4)==0 and u16(t,p+6)==0 and u16(t,p+8)==#self.entries and u16(t,p+10)==#self.entries and u32(t,p+12)==p-1 and u32(t,p+16)==self.centralOffset and #t==p+21+u16(t,p+20),'FONT_ZIP_EOCD_MISMATCH')
 assert(self.fd and self.fill==0,'FONT_ZIP_MISSING_FONT');local fd=self.fd;self.fd=nil;assert(ffi.C.close(fd)==0,'FONT_WRITE_FAILED');self.closed=true
 return{workMs=math.floor(self.workMs),cpuMs=math.floor(self.cpuMs),entries=#self.entries,bytes=self.size}
end
function S:abort()
 if self.inflating then z.inflateEnd(ffi.cast('void*',self.stream));self.inflating=nil end
 if self.fd then ffi.C.close(self.fd);self.fd=nil end
 if self.owned then os.remove(self.path)end;self.closed=true;self.header=nil;self.trailer=nil
end
return M
