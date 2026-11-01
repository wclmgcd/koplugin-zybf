-- Download-time quotation references, bound to the original cached chapter.
-- Geometry remains owned by the visible CRe reader; server offsets never do.
local M={}
function M.owner(vid,book,ch,path)
 local stamp=require('readinknative/pagination').fileStamp(path)
 local c={vid=tostring(vid),book=book,chapter=ch,document={path=path},stamp=stamp}
 c.cacheKey=table.concat({c.vid,tostring(book.bookId),tostring(book.version or 0),tostring(ch.chapterUid),stamp or''},':')..(require('readinknative/relatededitions').isCB(book)and ':cb3'or '')
 return c
end
function M.ready(vid,book,ch,path)
 if not require('readinknative/relatededitions').isCB(book)then return true end
 local rows,_,_,meta=require('readinknative/underlinecache').load(M.owner(vid,book,ch,path))
 return rows~=nil and not(meta and meta.partial)
end
function M.prepare(client,book,ch,path,catalog)
 assert(require('readinknative/cache').find(client.data.vid,book,ch)==path,'SOCIAL_READING_CACHE_CHANGED')
 local UC=require('readinknative/underlinecache');local owner=M.owner(client.data.vid,book,ch,path)
 local cached,_,anchor,meta=UC.load(owner)
 if cached and not(meta and meta.partial)then return{rows=cached,anchor=anchor,reused=true}end
 local Related=require('readinknative/relatededitions');local R=require('readinknative/socialranges')
 local rows=Related.readRanges(client,book,ch);local source
 if #rows>0 or Related.isCB(book)then rows,source=R.load(client,book,ch,path,rows)end
 local partial;rows,partial=Related.collect(client,book,ch,path,rows,catalog,source)
 anchor=UC.anchor(require('readinknative/underlinepage').anchor(source))
 assert(UC.save(owner,rows,nil,anchor,{partial=partial}),'UNDERLINE_SEED_WRITE_FAILED')
 return{rows=rows,anchor=anchor,partial=partial,reused=false}
end
return M
