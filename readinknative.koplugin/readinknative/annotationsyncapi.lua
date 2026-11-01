-- Private underline records, verified against NoteService in E-Ink 2.1.2.
-- No review publication, arbitrary text offsets, or automatic write retries.
local A={}
local function id(v)return type(v)=='string'and #v>0 and #v<=160 and v:match('^[%w_%-]+$')end
local function write(c,path,body)
 c.write_path=path
 local ok,r=pcall(c.api,c,path,nil,body);c.write_path=nil
 if not ok then error(r,0)end
 return r
end
function A.add(c,book,chapter,range,quote)
 local left,right
  if type(range)=='string'then left,right=range:match('^(%d+)%-(%d+)$')end
 local uid,version=tonumber(chapter.chapterUid),tonumber(book.version)
 assert(id(tostring(book.bookId))and uid and uid>=0 and uid%1==0 and version and version>=0 and version%1==0,'ANNOTATION_SYNC_METADATA_INVALID')
 assert(left and right and tonumber(right)>tonumber(left)and tonumber(right)<=2*1024*1024,'ANNOTATION_SYNC_RANGE_INVALID')
 assert(type(quote)=='string'and #quote>0 and #quote<=65536 and require('util').fixUtf8(quote,'')==quote,'NOTE_TEXT_INVALID')
 local r=write(c,'/book/addBookmark',{bookId=tostring(book.bookId),chapterUid=uid,type=1,range=range,markText=quote,bookVersion=version,style=0})
 assert(type(r)=='table'and id(r.bookmarkId),'ANNOTATION_SYNC_NOT_CONFIRMED')
 if r.bookId~=nil then assert(tostring(r.bookId)==tostring(book.bookId),'ANNOTATION_SYNC_NOT_CONFIRMED')end
 if r.range~=nil then assert(r.range==range,'ANNOTATION_SYNC_NOT_CONFIRMED')end
 return r.bookmarkId
end
function A.remove(c,bookmarkId)
 assert(id(bookmarkId),'SOCIAL_ID_INVALID')
 local r=write(c,'/book/removeBookmark',{bookmarkId=bookmarkId})
 assert(type(r)=='table'and tonumber(r.succ)==1,'ANNOTATION_SYNC_NOT_CONFIRMED')
 return true
end
return A
