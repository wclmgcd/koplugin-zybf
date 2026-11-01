-- Official TXT chapterdownload is a TAR of bookId_chapterUid_* plain text,
-- not an EPUB ZIP. Convert only the returned requested chapter text for CRe.
local T={MAX_TEXT=2*1024*1024}
local function xml(s)return s:gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;'):gsub('"','&quot;')end
function T.decode(raw)
 assert(type(raw)=='string'and #raw<=8*1024*1024,'TXT_CONTENT_INVALID')
 local offset,width,little=1
 if raw:sub(1,4)=='\255\254\0\0'then offset,width,little=5,4,true
 elseif raw:sub(1,4)=='\0\0\254\255'then offset,width,little=5,4,false
 elseif raw:sub(1,2)=='\255\254'then offset,width,little=3,2,true
 elseif raw:sub(1,2)=='\254\255'then offset,width,little=3,2,false
 elseif raw:sub(1,3)=='\239\187\191'then offset=4 end
 local text
 if width then
  assert((#raw-offset+1)%width==0,'TXT_CONTENT_INVALID')
  local function word(at)
   local value=0
   if little then for i=width-1,0,-1 do value=value*256+raw:byte(at+i)end
   else for i=0,width-1 do value=value*256+raw:byte(at+i)end end
   return value
  end
  local out={};local at=offset
  while at<=#raw do
   local code=word(at);at=at+width
   if width==2 and code>=0xD800 and code<=0xDBFF then
    assert(at<=#raw,'TXT_CONTENT_INVALID');local low=word(at);at=at+width
    assert(low>=0xDC00 and low<=0xDFFF,'TXT_CONTENT_INVALID');code=0x10000+(code-0xD800)*1024+low-0xDC00
   end
   assert(code>0 and code<=0x10FFFF and not(code>=0xD800 and code<=0xDFFF),'TXT_CONTENT_INVALID')
   out[#out+1]=require('util').unicodeCodepointToUtf8(code)
  end
  text=table.concat(out)
 else text=raw:sub(offset)end
 assert(#text>0 and #text<=T.MAX_TEXT and not text:find('%z')and require('util').fixUtf8(text,'')==text,'TXT_CONTENT_INVALID')
 return text
end
function T.key(uid)return'META-INF/readink-plain-'..tostring(uid)..'.json'end
function T.convert(files,book,chapters)
 local J=require('rapidjson');local meta=J.decode(assert(files['info.txt'],'CHAPTER_FILES_MISSING'))
 assert(type(meta)=='table'and tostring(meta.bookId)==tostring(book.bookId),'CHAPTER_BOOK_MISMATCH')
 assert(type(meta.chapters)=='table','TXT_CONTENT_INVALID')
 local available={};for _,ch in ipairs(meta.chapters)do
  local uid=type(ch)=='table'and tonumber(ch.chapterUid)
  assert(uid and uid>=0 and uid%1==0 and not available[tostring(uid)],'TXT_CONTENT_INVALID');available[tostring(uid)]=true
 end
 local bid=tostring(book.bookId);local byUid={}
 for name,body in pairs(files)do if name~='info.txt'then
  assert(name:sub(1,#bid+1)==bid..'_','CHAPTER_BOOK_MISMATCH')
  local rest=name:sub(#bid+2);local uid=rest:match('^(%d+)_')or rest:match('^(%d+)$')
  assert(uid and tonumber(uid)<=2147483647 and available[tostring(tonumber(uid))],'TXT_CONTENT_INVALID');uid=tostring(tonumber(uid))
  assert(not byUid[uid],'ARCHIVE_DUPLICATE');byUid[uid]=T.decode(body)
 end end
 local converted={};local info={bookId=bid,chapters={}};local seen={}
 -- Validate the entire batch before any cache file is committed.
 for _,ch in ipairs(chapters)do
  local uid=tostring(ch.chapterUid);local text=assert(byUid[uid],'CHAPTER_FILES_MISSING')
  assert(not seen[uid],'CHAPTER_BATCH_INVALID');seen[uid]=true
  local file='Text/txt-'..uid..'.xhtml';local paragraphs={}
  local lines=text:gsub('\r\n','\n'):gsub('\r','\n')
  for line in (lines..'\n'):gmatch('(.-)\n')do paragraphs[#paragraphs+1]=line==''and'<p><br/></p>'or'<p>'..xml(line)..'</p>'end
  local html='<html xmlns="http://www.w3.org/1999/xhtml"><head><title>'..xml(tostring(ch.title or book.title or''))..'</title></head><body>'..table.concat(paragraphs)..'</body></html>'
  assert(#html<=require('readinknative/content').MAX_ENTRY,'ARCHIVE_TOO_LARGE')
  converted[file]=html;info.chapters[#info.chapters+1]={chapterUid=ch.chapterUid,files={file}}
  converted[T.key(uid)]=J.encode{schema=2,format='txt',bookId=bid,chapterUid=uid,version=tostring(book.version or 0),text=text}
 end
 converted['info.txt']=J.encode(info);return converted
end
return T
