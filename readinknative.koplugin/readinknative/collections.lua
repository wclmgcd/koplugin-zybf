-- Native list presentation model. Source indices survive catalog filtering.
local C={}
function C.catalog(app)
    local rows={};local query=app.catalogQuery or ''
    for index,chapter in ipairs(app:catalogItems())do
        if query=='' or tostring(chapter.title or ''):find(query,1,true)then
            rows[#rows+1]={chapter=chapter,index=index}
        end
    end
    return rows
end
function C.current(app)
    if app.chapter then
        for i,c in ipairs(app:catalogItems())do
            if tostring(c.chapterUid)==tostring(app.chapter.chapterUid)then return i end
        end
    elseif app.document then
        local current=app.document:page();local selected
        for i,c in ipairs(app:catalogItems())do
            local page=tonumber(c.page)
            if c.xpointer and app.document.doc:isXPointerInDocument(c.xpointer)then
                page=app.document.doc:getPageFromXPointer(c.xpointer)
            end
            if page and page<=current then selected=i end
        end
        return selected
    end
end
function C.records(app)
    local rows=require('readinknative/annotations').list(app.state,app.book.bookId,
        app.notesOnlyBookmarks and 'bookmark' or nil)
    for _,row in ipairs(require('readinknative/social').records(app))do rows[#rows+1]=row end
    local order={}
    for i,c in ipairs(app:catalogItems())do if c.chapterUid then order[tostring(c.chapterUid)]=i end end
    table.sort(rows,function(a,b)
        local ac,bc=order[a.chapterUid]or math.huge,order[b.chapterUid]or math.huge
        if ac~=bc then return ac<bc end
        local ap,bp=tonumber(a.position.page)or 0,tonumber(b.position.page)or 0
        if ap~=bp then return ap<bp end
        if a.created~=b.created then return a.created<b.created end
        return a.id<b.id
    end)
    return rows
end
-- Notes and the reader footer use the same book coordinates. A chapter-local
-- count must never be presented as the whole book's reading progress.
function C.progress(app)
    if app.book.localFile and app.document and app.document.count then
        local page,total=app.document:page(),app.document:count()
        return '本文件已读 '..math.floor(100*page/math.max(1,total))..'%'
    end
    if app.document and not app.book.localFile then
        local page,total=require('readinknative/pagination').position(app)
        if type(page)=='number'and type(total)=='number'and total>=1 and page>=1 and page<=total then
            return '本书已读 '..math.floor(100*page/total)..'%'
        end
    end
    local progress=app.book.cloudProgress and tonumber(app.book.cloudProgress.percent)
    if progress and progress>=0 and progress<=100 then return '云端记录已读 '..math.floor(progress)..'%'end
    return '全书进度尚未读取'
end
function C.page(page,count,size)
    local pages=math.max(1,math.ceil(count/size))
    return math.max(1,math.min(page or 1,pages)),pages
end
return C
