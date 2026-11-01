-- Pick a chapter by stable UID. Engine offsets are never interchangeable.
local R={}
local function find(chapters,uid)
    if uid==nil then return end
    for index,chapter in ipairs(chapters or {})do
        if tostring(chapter.chapterUid)==tostring(uid)then return chapter,index end
    end
end
function R.choose(state,book,chapters)
    local saved=(state.last or {})[tostring(book.bookId)]
    if saved then
        local chapter,index=find(chapters,saved.chapterUid)
        if chapter then return chapter,index,'local'end
    end
    -- Cloud synchronization checks the original source after the first frame.
    -- A newer remote location is offered without replacing a valid local XPointer.
    if chapters and chapters[1]then
        -- Skip only the separate cover on a fresh start, as the E-Ink client
        -- does. Saved locations and explicit catalogue selection retain it.
        local index=1
        if chapters[1].title=='封面'and chapters[2]then index=2 end
        return chapters[index],index,'start'
    end
end
function R.cloud(book,chapters)
    local p=book.cloudProgress
    if type(p)~='table'then return end
    return find(chapters,p.chapterUid)
end
function R.normalize(row)
    if type(row)~='table'then return end
    local uid=tonumber(row.chapterUid);local offset=tonumber(row.chapterOffset)
    local percent=tonumber(row.progress);local updated=tonumber(row.updateTime)
    if not uid or uid<=0 or uid%1~=0 or uid>2147483647 then return end
    local result={chapterUid=tostring(uid)}
    if offset and offset>=0 and offset%1==0 and offset<=2147483647 then result.chapterOffset=offset end
    if percent and percent>=0 and percent<=100 then result.percent=percent end
    if updated and updated>=0 and updated<math.huge then result.updated=updated end
    return result
end
return R
