-- Local, book-wide annotation model. Position is a chapter UID plus an XPointer.
local A={}
local function copy(t)local v={};for k,x in pairs(t or {})do v[k]=x end;return v end
function A.add(state,book,chapter,kind,position,text,id)
    assert(kind=='note' or kind=='bookmark' or kind=='highlight','ANNOTATION_KIND_INVALID')
    assert(type(position)=='table' and type(position.xpointer)=='string','ANNOTATION_POSITION_INVALID')
    assert((kind~='note' and kind~='highlight') or (type(text)=='string' and #text>0 and #text<=65536),'NOTE_TEXT_INVALID')
    if kind=='highlight'then assert(type(position.endXPointer)=='string','ANNOTATION_RANGE_INVALID')end
    local row={id=id or require('readinknative/auth/wire').hex(12),bookId=tostring(book.bookId),
        chapterUid=chapter and tostring(chapter.chapterUid)or nil,chapterTitle=chapter and chapter.title or book.title,
        kind=kind,position=copy(position),text=text,bookVersion=book.version,created=os.time(),updated=os.time()}
    state.annotations[#state.annotations+1]=row;require('readinknative/annotationsync').queue(state,book,chapter,row);return row
end
function A.list(state,bookId,kind)
    local result={}
    for _,row in ipairs(state.annotations)do
        if row.bookId==tostring(bookId) and (not kind or row.kind==kind)then result[#result+1]=row end
    end
    table.sort(result,function(a,b)if a.updated==b.updated then return a.id<b.id end;return a.updated>b.updated end)
    return result
end
function A.remove(state,id)
    for i,row in ipairs(state.annotations)do if row.id==id then require('readinknative/annotationsync').remove(state,row);table.remove(state.annotations,i);return true end end
    return false
end
function A.edit(row,text)
    assert(row.kind=='note' and type(text)=='string' and #text>0 and #text<=65536,'NOTE_TEXT_INVALID')
    row.text=text;row.updated=os.time()
end
function A.summary(text)
    local chars,n={},0
    for c in tostring(text or ''):gsub('[\r\n]',' '):gmatch('[%z\1-\127\194-\244][\128-\191]*')do
        n=n+1;if n>48 then chars[#chars+1]='…';break end;chars[#chars+1]=c
    end
    return table.concat(chars)
end
function A.migrate(state)
    if state.annotationSchema==1 then return end
    local existing={};for _,row in ipairs(state.annotations)do existing[row.id]=true end
    for kind,source in pairs({bookmark=state.bookmarks,note=state.notes})do
        for key,value in pairs(source or {})do
            local bookId,uid=key:match('^(.*):([^:]*)$')
            local pos=kind=='bookmark' and value or value.position
            local id='legacy-'..kind..':'..key
            if bookId and type(pos)=='table' and type(pos.xpointer)=='string' and not existing[id]then
                local text=kind=='note' and value.text or nil
                if kind=='bookmark' or (type(text)=='string' and #text>0 and #text<=65536)then
                    local row=A.add(state,{bookId=bookId,title='本地记录'},uid~='local' and {chapterUid=uid,title='章节 '..uid}or nil,kind,pos,text,id)
                    row.created=pos.updated or row.created;row.updated=row.created
                end
            end
        end
    end
    state.annotationSchema=1
end
return A
