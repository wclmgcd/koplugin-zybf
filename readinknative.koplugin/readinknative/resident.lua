-- One bounded online chapter can remain resident while showing the shelf.
-- This never grants access: reuse re-checks the normal account cache lookup.
local R={MAX_FILE=512*1024,MAX_PAGES=200}
local function stamp(path)
    local s=require('libs/libkoreader-lfs').attributes(path)
    if s and s.mode=='file'then return tostring(s.size)..':'..tostring(s.modification),s.size end
end
local function formatKey(format,w,h)
    return table.concat({w,h,require('readinknative/format').signature(format)},'|')
end
function R.drop(a)
    local parked=a.residentChapter;a.residentChapter=nil
    if parked and parked.document then parked.document:close()end
end
function R.park(a)
    local doc=a.document;if not doc then return end
    R.drop(a);a.document=nil
    if doc.window or not a.book or a.book.localFile or not a.chapter or not doc.format then doc:close();return end
    local fingerprint,bytes=stamp(doc.path)
    if not fingerprint or bytes>R.MAX_FILE or doc:count()>R.MAX_PAGES then doc:close();return end
    doc:clearPageImages()
    a.residentChapter={document=doc,state=a.state,vid=a.client.data.vid,bookId=tostring(a.book.bookId),version=tostring(a.book.version or 0),
        uid=tostring(a.chapter.chapterUid),path=doc.path,stamp=fingerprint,format=formatKey(doc.format,doc.w,doc.h)}
end
function R.peek(a,path,w,h,font,format,chapter)
    local r=a.residentChapter;if not r then return end
    chapter=chapter or a.chapter
    local current=stamp(path)
    local valid=r.state==a.state and r.vid==a.client.data.vid and a.book and not a.book.localFile and chapter
        and r.bookId==tostring(a.book.bookId)and r.version==tostring(a.book.version or 0)and r.uid==tostring(chapter.chapterUid)
        and r.path==path and r.stamp==current and r.format==formatKey(require('readinknative/format').normalize(format,font),w,h)
    if valid then valid=require('readinknative/cache').find(a.client.data.vid,a.book,chapter)==path end
    return valid and r or nil
end
function R.take(a,path,w,h,font,format,position)
    local r=R.peek(a,path,w,h,font,format)
    if not r then R.drop(a);return end
    a.residentChapter=nil
    local doc=r.document
    if position and position.xpointer then doc:restorePosition(position)end
    require('logger').info('ReadInk reused resident chapter')
    return doc
end
return R
