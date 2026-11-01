-- Map original XHTML UTF-16 offsets to CRe text by exact unique quotations.
-- Page numbers and engine XPointers never leave the device.
local M={MAX_SOURCE=512*1024}
local function scalar(s,i)
 local b=s:byte(i);if not b then return end
 local n=b<128 and 1 or b<224 and 2 or b<240 and 3 or 4
 return s:sub(i,i+n-1),n,n==4 and 2 or 1
end
local function whitespace(c)return c:match('^%s$')or c==' 'or c=='　'or c=='\226\128\168'or c=='\226\128\169'end
function M.compact(s)
 local out={};local i=1
 while i<=#s do local c,n=scalar(s,i);if not whitespace(c)then out[#out+1]=c end;i=i+n end
 return table.concat(out)
end
-- TXT offsets address the returned plain UTF-16 text, excluding its BOM.
-- XHTML generated for CRe must never become its cloud coordinate source.
function M.indexPlain(raw)
 if type(raw)~='string'or #raw>M.MAX_SOURCE or require('util').fixUtf8(raw,'')~=raw then return end
 local text,offsets,ends,expanded,map={},{},{},{},{};local i,u,bytes,expandedBytes=1,0,0,0
 while i<=#raw do
  local c,n,units=scalar(raw,i)
  if not whitespace(c)then text[#text+1]=c;offsets[bytes+1]=u;ends[bytes+#c]=u+units;map[bytes+1]=expandedBytes+1;bytes=bytes+#c end
  local display=(c=='\n'or c=='\r')and'\n'or whitespace(c)and' 'or c
  expanded[#expanded+1]=display;expandedBytes=expandedBytes+#display;u=u+units;i=i+n
 end
 return{text=table.concat(text),offsets=offsets,ends=ends,units=u,expanded=table.concat(expanded),expandedMap=map}
end
function M.index(html)
 if type(html)~='string'or #html>M.MAX_SOURCE or require('util').fixUtf8(html,'')~=html then return end
 local text,offsets,ends,expanded,expandedMap={},{},{},{},{};local expandedBytes=0;local i,u,bytes=1,0,0;local body=false;local skip
 local function emit(c,offset,finish)
  if not whitespace(c)then text[#text+1]=c;offsets[bytes+1]=offset;ends[bytes+#c]=finish;expandedMap[bytes+1]=expandedBytes+1;bytes=bytes+#c end
  if whitespace(c)then c=' 'end;expanded[#expanded+1]=c;expandedBytes=expandedBytes+#c
 end
 while i<=#html do
  if html:sub(i,i)=='<'then
   local endTag=html:find('>',i,true);if not endTag then return end
   if html:sub(i,i+3)=='<!--'then local e=html:find('-->',i+4,true);if not e then return end;endTag=e+2 end
   local tag=html:sub(i,endTag):lower();if body and tag:match('^</?[phd][%w]*%f[%s/>]')then expanded[#expanded+1]='\n';expandedBytes=expandedBytes+1 end;if tag:match('^<body%f[%s>]')then body=true elseif tag:match('^</body%s*>')then body=false
   elseif tag:match('^<script%f[%s>]')then skip='script'elseif tag:match('^<style%f[%s>]')then skip='style'
   elseif skip and tag:match('^</'..skip..'%s*>')then skip=nil end
   while i<=endTag do local _,n,units=scalar(html,i);u=u+units;i=i+n end
  elseif html:sub(i,i)=='&'and body and not skip then
   local e=html:find(';',i+1,true);local raw=e and e-i<=32 and html:sub(i,e)
   local decoded=raw and require('util').htmlEntitiesToUtf8(raw)
   if raw and decoded~=raw then
    local j=1;while j<=#decoded do local c,n=scalar(decoded,j);emit(c,u,u+#raw);j=j+n end
    u=u+#raw;i=e+1
   else local c,n,units=scalar(html,i);emit(c,u,u+units);u=u+units;i=i+n end
  else
   local c,n,units=scalar(html,i);if body and not skip then emit(c,u,u+units)end;u=u+units;i=i+n
  end
 end
 return{text=table.concat(text),offsets=offsets,ends=ends,units=u,expanded=table.concat(expanded),expandedMap=expandedMap}
end
-- Full selection, never the truncated page prefix used for reading progress.
-- Both endpoints address original XHTML UTF-16 units (entities included).
function M.ranges(index,quote)
 if not index or type(quote)~='string'then return end
 local needle=M.compact(quote);if needle==''then return end
 local rows={};local at=1
 while at<=#index.text do
  local first,last=index.text:find(needle,at,true);if not first then break end
  local left,right=index.offsets[first],index.ends and index.ends[last]
  if left and right and right>left then rows[#rows+1]=tostring(left)..'-'..tostring(right)end
  if #rows>2000 then return end;at=first+1
 end
 return rows
end
function M.range(index,quote)
 local rows=M.ranges(index,quote);return rows and #rows==1 and rows[1]or nil
end
local function prefix(text,max)
 local i,count=1,0;while i<=#text and count<max do local _,n=scalar(text,i);i=i+n;count=count+1 end
 return text:sub(1,i-1)
end
function M.offset(index,visible,node)
 if not index or type(visible)~='string'then return end
 local compact=M.compact(visible)
 for _,size in ipairs{32,64,96,192,384}do
  local quote=prefix(compact,size);if #quote>=12 then
   local first=index.text:find(quote,1,true)
   if first and not index.text:find(quote,first+1,true)then return index.offsets[first],quote end
  end
 end
 if type(node)=='string'and #node<=8192 then
  local context=M.compact(node);local start=index.text:find(context,1,true)
  local line=M.compact(visible:match('^[^\n]+')or visible)
  if start and #context>=12 and not index.text:find(context,start+1,true)and #line>=6 then
   local at=context:find(line,1,true)
   if at and not context:find(line,at+1,true)then return index.offsets[start+at-1],line end
  end
 end
end
function M.quote(index,offset)
 if not index or type(offset)~='number'or offset<0 or offset%1~=0 or offset>index.units then return end
 local first
 for i=1,#index.text do local u=index.offsets[i];if u and u>=offset then first=i;break end end
 if not first then return end
 local quote=prefix(index.text:sub(first),64);if #quote<12 then return end
 if index.text:find(quote,1,true)~=first or index.text:find(quote,first+1,true)then return end
 return quote,first
end
function M.visible(document)
 local doc=document.doc;local point=doc:getXPointer();local nextPoint=doc:getPageXPointer(math.min(document:count(),document:page()+1))
 local node=doc:getTextFromXPointer(point)
 if nextPoint and nextPoint~=point then return doc:getTextFromXPointers(point,nextPoint),node end
 -- On a last page a tap at the top margin can select text from before the
 -- page. Keep CRe's exact page XPointer and read only towards a conservative
 -- valid end of its current text node. No engine character index is exported.
 local prefixPath=point and point:match('^(.*%.)%d+$');local current=point and tonumber(point:match('%.(%d+)$'))
 if not prefixPath or not node then return end
 local count,i=0,1;while i<=#node do local _,n=scalar(node,i);count=count+1;i=i+n end
 if count<=current then return end
 local finish=prefixPath..count
 if doc:isXPointerInDocument(finish)then return doc:getTextFromXPointers(point,finish),node end
end
function M.source(path,book,chapter)
 local f=assert(io.open(path,'rb'));local bytes=f:read('*a');f:close()
 local C=require('readinknative/content');local files=C.unpack(bytes,nil,nil,true);local key=require('readinknative/socialranges').ENTRY
 local raw=files[key];local value=raw and require('rapidjson').decode(raw)
 if not require('readinknative/socialranges').valid(value,book,chapter)then
  local sf=require('readinknative/cachefiles').open(path..'.source.json','rb');if sf then local data=sf:read(3*M.MAX_SOURCE+1);sf:close();local ok,v=pcall(require('rapidjson').decode,data)
   if ok and v.digest==require('ffi/sha2').sha256(bytes)then value=v end
  end
 end
 if require('readinknative/socialranges').valid(value,book,chapter)then return value.format=='txt'and M.indexPlain(value.text)or M.index(value.html)end
end
function M.toCloud(path,book,chapter,visible,node)
 return M.offset(M.source(path,book,chapter),visible,node)
end
function M.fromCloud(document,path,book,chapter,offset)
 local index=M.source(path,book,chapter)
 if not index or type(offset)~='number'or offset<0 or offset%1~=0 or offset>index.units then return end
 local first;for i=1,#index.text do local u=index.offsets[i];if u and u>=offset then first=i;break end end
 if not first then return end
 local raw=index.expanded;local at=index.expandedMap[first]
 local start=1
 for newline in raw:gmatch('()\n')do if newline>=at then break end;start=newline+1 end
 local finish=(raw:find('\n',at,true)or(#raw+1))-1
 local paragraph=M.compact(raw:sub(start,finish));local quote=prefix(raw:sub(at,finish),96):gsub('%s+',' '):gsub('%s+$','')
 if #quote<12 or paragraph==''then return end
 local needle=M.compact(quote);local expected=#M.compact(raw:sub(start,at-1))+1
 if paragraph:find(needle,1,true)~=expected or paragraph:find(needle,expected+1,true)then return end
 local hits=document.doc:findAllText(quote,false,0,200,false,0x00FF);local found
 local rawFirst=index.text:find(needle,1,true)
 if hits and #hits==1 and rawFirst==first and not index.text:find(needle,first+1,true)then return hits[1].start end
 for _,hit in ipairs(hits or{})do if hit.start and document.doc:isXPointerInDocument(hit.start)then
  local node=document.doc:getTextFromXPointer(hit.start)
  if node and M.compact(node)==paragraph then if found then return end;found=hit.start end
 end end
 return found
end
return M
