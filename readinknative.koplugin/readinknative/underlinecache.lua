-- Bounded account/chapter/source/engine-scoped cache. Counts are only used
-- for reader marks; opening a thought still reads its current server data.
local M={MAX_ROWS=1000,MAX_BYTES=1024*1024,TTL=3600}
local function clean(rows,available)
 local result={}
 for i,r in ipairs(rows)do
  local row={range=r.range,quote=r.quote,count=r.count,type=r.type,score=r.score,endpoints=r.endpoints,needsFragments=r.needsFragments,foreign=r.foreign}
  if r.resolved==true or available and i<=available then row.resolved=true end
  if r.position then local p=r.position;row.position={xpointer=p.xpointer,endXPointer=p.endXPointer,page=p.page}end
  result[#result+1]=row
 end
 return result
end
function M.key(c)
 return c.cacheKey..(require('readinknative/relatededitions').isCB(c.book)and ':cb-related-v3'or '')..':underline-map-v1:'..tostring(require('version'):getCurrentRevision())
end
function M.bytes(rows)
 if type(rows)~='table'or #rows>M.MAX_ROWS then return end
 local total=0
 for _,r in ipairs(rows)do
  if type(r)~='table'or type(r.range)~='string'or #r.range>64 or not r.range:match('^%d+%-%d+$')then return end
  if r.quote~=nil and(type(r.quote)~='string'or #r.quote>16384)then return end
  if r.foreign and not require('readinknative/relatededitions').validSource(r.foreign)then return end
  local e=r.endpoints
  if e and(type(e)~='table'or type(e.first)~='string'or type(e.last)~='string'or #e.first==0 or #e.last==0 or #e.first>16384 or #e.last>16384)then return end
  local p=r.position
  if p and(type(p)~='table'or type(p.xpointer)~='string'or type(p.endXPointer)~='string'or #p.xpointer>2048 or #p.endXPointer>2048
   or type(p.page)~='number'or p.page<1 or p.page>1000000 or p.page%1~=0)then return end
  total=total+(r.foreign and 2048 or 0)+320+#r.range+#(r.quote or'')+(e and #e.first+#e.last or 0)+(p and #p.xpointer+#p.endXPointer or 0)
  if total>M.MAX_BYTES then return end
 end
 return total
end
function M.anchor(value)
 if type(value)~='table'or type(value.text)~='string'or #value.text>256*1024 or type(value.blocks)~='table'or #value.blocks>4096 then return end
 if value.coordinateAttempted~=nil and type(value.coordinateAttempted)~='boolean'then return end
 local lastByte=0;local first=0
 for _,b in ipairs(value.blocks)do
  if type(b)~='table'or type(b.byte)~='number'or b.byte%1~=0 or b.byte<=lastByte or b.byte>#value.text+1
   or type(b.first)~='number'or type(b.last)~='number'or b.first%1~=0 or b.last%1~=0 or b.first<first or b.first>b.last or b.last>10000000 then return end
  lastByte=b.byte;first=b.first
 end
 return value
end
function M.load(c)
 local path=c.document.path..'.underlines.json';local F=require('readinknative/cachefiles')
 if require('readinknative/cachefiles').attributes(path,'mode')~='file'then return end
 local f=F.open(path,'rb');if not f then return end;local raw=f:read(M.MAX_BYTES+1);f:close();if #raw>M.MAX_BYTES then return end
 local ok,v=pcall(require('rapidjson').decode,raw);local now=os.time()
 if ok and type(v)=='table'and(v.schema==1 or v.schema==2 or v.schema==3 or v.schema==4)and v.key==M.key(c)and type(v.created)=='number'and v.created<=now and now-v.created<(require('readinknative/relatededitions').isCB(c.book)and type(v.rows)=='table'and(#v.rows==0 and 60 or 30*86400)or M.TTL) and M.bytes(v.rows)then
  local available=v.schema==1 and #v.rows or v.available
  if type(available)=='number'and available%1==0 and available>=0 and available<=#v.rows then
   for _,row in ipairs(v.rows)do if row.foreign and not require('readinknative/relatededitions').validSource(row.foreign,c.book,c.chapter)then return end end
   local rows=clean(v.rows,v.schema<3 and available or nil)
   if v.schema<4 then for _,r in ipairs(rows)do r.needsFragments=true;if not r.position then r.resolved=nil end end end
   return rows,available,M.anchor(v.anchor),{partial=v.partial==true}
  end
 end
end
function M.save(c,rows,available,anchor,meta)
 if not M.bytes(rows)then return end
 local path=c.document.path..'.underlines.json';local F=require('readinknative/cachefiles');local lfs=require('libs/libkoreader-lfs')
 for _,p in ipairs{path,path..'.part'}do local mode=lfs.symlinkattributes(p,'mode');if mode and mode~='file'then return end end
 local availableExplicit=available;available=available or #rows;if type(available)~='number'or available%1~=0 or available<0 or available>#rows then return end
 local value={schema=4,key=M.key(c),created=os.time(),rows=clean(rows,availableExplicit),available=#rows,anchor=M.anchor(anchor),partial=meta and meta.partial==true or nil}
 local raw=require('rapidjson').encode(value)
 if #raw>M.MAX_BYTES then value.anchor=nil;raw=require('rapidjson').encode(value)end
 if #raw>M.MAX_BYTES then return end
 local f=F.open(path..'.part','wb');if not f then return end;local wrote=f:write(raw);local closed=f:close()
 if wrote and closed then return F.rename(path..'.part',path)end;F.remove(path..'.part')
end
return M
