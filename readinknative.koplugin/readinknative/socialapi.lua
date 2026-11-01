-- Official E-Ink note/review models, separate from local XPointer records.
local A={}
local function id(value)
    if type(value)~='string'and type(value)~='number'then return end
    local s=tostring(value);if #s>0 and #s<=160 and s:match('^[A-Za-z0-9_%-]+$')then return s end
end
local function text(value,max)
    if type(value)~='string'then return''end
    assert(#value<=(max or 65536)and require('util').fixUtf8(value,'')==value,'SOCIAL_TEXT_INVALID')
    return value
end
local function integer(value,max)
    local n=tonumber(value);if n and n>=0 and n%1==0 and n<=(max or 9007199254740991)then return n end
end
local function count(value)return integer(value,1000000000)end
-- Retrofit's maxIdx is a signed Int cursor, not a count or an offset we own.
local function cursor(value)local n=tonumber(value);if n and n%1==0 and n>=-2147483648 and n<=2147483647 then return n end end
local function timestamp(value)local n=integer(value,4102444800);return n and n>0 and n or nil end
local function flag(value)
    if value==true or value==1 then return true elseif value==false or value==0 then return false end
end
local function user(value)
    value=type(value)=='table'and value or{}
    return{vid=id(value.userVid),name=text(value.name or value.nick or'微信读书用户',1024),avatar=type(value.avatar)=='string'and text(value.avatar,4096)or nil}
end
function A.review(item,bookId)
    if type(item)~='table'or type(item.review)~='table'then return end
    local r=item.review;local rid=id(item.reviewId or r.reviewId)
    if not rid or id(r.reviewId)~=rid or bookId and tostring(r.bookId)~=tostring(bookId)then return end
    local author=user(r.author);local uid=id(r.userVid)
    if author.vid and uid and author.vid~=uid then return end
    return{reviewId=rid,bookId=id(r.bookId),bookVersion=tonumber(r.bookVersion),chapterUid=id(r.chapterUid or r.chapterIdx),
        chapterTitle=text(r.chapterName or r.chapterTitle or'',4096),content=text(r.content),quote=text(r.abstract),
        title=text(r.title,4096),author=author,userVid=uid or author.vid,type=count(r.type),created=timestamp(r.createTime),
        liked=flag(r.isLike),private=flag(r.isPrivate),friendship=flag(r.friendship),notVisibleToFriends=flag(r.notVisibleToFriends),likesCount=count(item.likesCount)or count(r.likesCount),commentsCount=count(item.commentsCount)or count(r.commentsCount),
        range=type(r.range)=='string'and text(r.range,4096)or nil}
end
function A.comment(value,reviewId)
    if type(value)~='table'then return end
    local cid=id(value.commentId);if not cid or value.reviewId and tostring(value.reviewId)~=reviewId then return end
    local target=id(value.toCommentId);if target=='0'then target=nil end
    return{commentId=cid,content=text(value.content),author=user(value.author),replyUser=value.replyUser and user(value.replyUser),
        toCommentId=target,created=timestamp(value.createTime),likesCount=count(value.likesCount),liked=flag(value.isLike)}
end
function A.list(response,bookId)
    assert(type(response)=='table'and type(response.reviews)=='table','SOCIAL_SCHEMA_CHANGED')
    local rows,seen={},{}
    for i,item in ipairs(response.reviews)do
        assert(i<=1000,'SOCIAL_RESULT_TOO_LARGE')
        local row=A.review(item,bookId)
        if row and not seen[row.reviewId]then rows[#rows+1]=row;seen[row.reviewId]=true end
    end
    return{rows=rows,total=count(response.totalCount),more=flag(response.hasMore)==true,synckey=integer(response.synckey)}
end
function A.mine(client,book)
    local response=client:api('/review/list',{bookId=tostring(book.bookId),listType=11,mine=1,synckey=0,listMode=0})
    local data=A.list(response,book.bookId);local rows={}
    for _,row in ipairs(data.rows)do if row.userVid==tostring(client.data.vid)then rows[#rows+1]=row end end
    data.rows=rows;return data
end
function A.bookmarks(client,book)
    local response=client:api('/book/bookmarklist',{bookId=tostring(book.bookId),synckey=0})
    assert(type(response.updated)=='table'and type(response.book)=='table'and tostring(response.book.bookId)==tostring(book.bookId),'SOCIAL_SCHEMA_CHANGED')
    local rows,seen={},{}
    for i,r in ipairs(response.updated)do
        assert(i<=1000,'SOCIAL_RESULT_TOO_LARGE');local bid=id(r.bookmarkId)
        if bid and not seen[bid]and tostring(r.bookId)==tostring(book.bookId)then
            rows[#rows+1]={bookmarkId=bid,bookId=id(r.bookId),bookVersion=tonumber(r.bookVersion),chapterUid=id(r.chapterUid or r.chapterIdx),chapterTitle=text(r.chapterName,4096),
                quote=text(r.markText),created=timestamp(r.createTime),type=count(r.type),range=type(r.range)=='string'and text(r.range,4096)or nil};seen[bid]=true
        end
    end
    return{rows=rows,synckey=integer(response.synckey)}
end
function A.ranges(client,book,chapter)
    local r=client:api('/book/underlines',{bookId=tostring(book.bookId),chapterUid=chapter.chapterUid,synckey=0})
    assert(type(r.underlines)=='table'and tostring(r.bookId)==tostring(book.bookId)and tostring(r.chapterUid)==tostring(chapter.chapterUid),'SOCIAL_SCHEMA_CHANGED')
    local rows,seen={},{}
    for i,item in ipairs(r.underlines)do
        assert(i<=1000,'SOCIAL_RESULT_TOO_LARGE')
        local range=type(item.range)=='string'and item.range
        if range and #range<=4096 and not seen[range]then rows[#rows+1]={range=range,count=count(item.count),type=count(item.type),score=tonumber(item.score)};seen[range]=true end
    end
    return rows
end
function A.bookReviews(client,book,cursor)
    local q={bookId=tostring(book.bookId),listType=3,synckey=cursor and cursor.synckey or 0,listMode=0,count=20}
    if cursor then assert(cursor.maxIdx,'SOCIAL_CURSOR_INVALID');q.maxIdx=cursor.maxIdx end
    local response=client:api('/review/list',q);local data=A.list(response,book.bookId)
    data.maxIdx=count(response.maxIdx)
    -- A count larger than this curated list does not establish a next cursor.
    if data.more then assert(data.maxIdx and(not cursor or data.maxIdx>cursor.maxIdx),'SOCIAL_CURSOR_STALLED')end
    return data
end
function A.hotInfo(client,book)
    local r=client:api('/book/bestbookmarksinfo',{bookId=tostring(book.bookId)})
    return{total=count(r.totalCount)}
end
function A.hot(client,book,cursor)
    local q={bookId=tostring(book.bookId),synckey=cursor and cursor.synckey or 0,maxIdx=cursor and cursor.maxIdx or 0,count=500}
    local r=client:api('/book/bestbookmarks',q);assert(type(r.items)=='table'and type(r.chapters)=='table','SOCIAL_SCHEMA_CHANGED')
    local chapters={}
    for _,ch in ipairs(r.chapters)do
        assert(tostring(ch.bookId)==tostring(book.bookId),'SOCIAL_SCHEMA_CHANGED')
        local uid=id(ch.chapterUid);if uid then chapters[uid]={chapterUid=uid,chapterIdx=count(ch.chapterIdx),title=text(ch.title,4096)}end
    end
    local rows,seen={},{}
    for i,item in ipairs(r.items)do
        assert(i<=1000 and tostring(item.bookId)==tostring(book.bookId),'SOCIAL_SCHEMA_CHANGED')
        local uid=id(item.chapterUid);local range=text(item.range,4096);local chapter=uid and chapters[uid]
        if chapter and range:match('^%d+%-%d+$')and not seen[uid..':'..range]then
            rows[#rows+1]={id=uid..':'..range,range=range,quote=text(item.markText),chapter=chapter,count=count(item.totalCount)};seen[uid..':'..range]=true
        end
    end
    table.sort(rows,function(a,b)
        if a.chapter.chapterIdx~=b.chapter.chapterIdx then return(a.chapter.chapterIdx or 0)<(b.chapter.chapterIdx or 0)end
        return(tonumber(a.range:match('^%d+'))or 0)<(tonumber(b.range:match('^%d+'))or 0)
    end)
    return{rows=rows,total=count(r.totalCount),synckey=integer(r.synckey),maxIdx=count(r.maxIdx),more=flag(r.hasMore)==true}
end
function A.groups(client,book,chapter,ranges,start)
    start=start or 1;local request={};local expected={}
    for i=start,math.min(#ranges,start+4)do
        local range=ranges[i].range;request[#request+1]={range=range,count=10,synckey=0};expected[range]=true
    end
    if #request==0 then return{}end
    local r=client:api('/book/readreviews',nil,{bookId=tostring(book.bookId),chapterUid=assert(integer(chapter.chapterUid,2147483647),'SOCIAL_CHAPTER_INVALID'),cht2sMode='',reviews=request})
    assert(type(r.reviews)=='table'and tostring(r.bookId)==tostring(book.bookId)and tostring(r.chapterUid)==tostring(chapter.chapterUid),'SOCIAL_SCHEMA_CHANGED')
    local groups,seen={},{}
    for _,g in ipairs(r.reviews)do
        assert(type(g)=='table'and expected[g.range]and not seen[g.range]and type(g.pageReviews)=='table','SOCIAL_SCHEMA_CHANGED')
        local data=A.list({reviews=g.pageReviews,hasMore=g.hasMore,totalCount=g.totalCount,synckey=g.synckey},book.bookId)
        for _,row in ipairs(data.rows)do assert(row.chapterUid==tostring(chapter.chapterUid),'SOCIAL_SCHEMA_CHANGED')end
        data.range=g.range;data.maxIdx=cursor(g.maxIdx);data.quote=data.rows[1]and data.rows[1].quote or''
        groups[#groups+1]=data;seen[g.range]=true
    end
    -- Request order is meaningful even if a service changes array order.
    local ordered={};for _,req in ipairs(request)do for _,g in ipairs(groups)do if g.range==req.range then ordered[#ordered+1]=g;break end end end
    assert(#ordered==#request,'SOCIAL_SCHEMA_CHANGED');return ordered
end
function A.moreGroup(client,book,chapter,group)
    assert(cursor(group.maxIdx),'SOCIAL_CURSOR_INVALID')
    local r=client:api('/book/readreviews',nil,{bookId=tostring(book.bookId),chapterUid=assert(integer(chapter.chapterUid,2147483647),'SOCIAL_CHAPTER_INVALID'),cht2sMode='',reviews={{range=group.range,count=10,maxIdx=group.maxIdx}}})
    assert(type(r.reviews)=='table'and #r.reviews==1 and tostring(r.bookId)==tostring(book.bookId)and tostring(r.chapterUid)==tostring(chapter.chapterUid),'SOCIAL_SCHEMA_CHANGED')
    local g=r.reviews[1];assert(g.range==group.range and type(g.pageReviews)=='table','SOCIAL_SCHEMA_CHANGED')
    local data=A.list({reviews=g.pageReviews,hasMore=g.hasMore,totalCount=g.totalCount,synckey=g.synckey},book.bookId)
    for _,row in ipairs(data.rows)do assert(row.chapterUid==tostring(chapter.chapterUid),'SOCIAL_SCHEMA_CHANGED')end
    data.range=g.range;data.maxIdx=cursor(g.maxIdx);data.quote=group.quote
    if data.more then assert(data.maxIdx and data.maxIdx~=group.maxIdx,'SOCIAL_CURSOR_STALLED')end
    return data
end
function A.detail(client,reviewId,bookId,offset,synckey,part)
    assert(id(reviewId),'SOCIAL_ID_INVALID')
    local query={reviewId=reviewId,synckey=synckey or 0,commentsCount=100,commentsDirection=1}
    if part=='likes'then query={reviewId=reviewId,synckey=synckey or 0,likesMaxIdx=offset or 0,likesCount=20,likesDirection=1}
    elseif offset then query.commentsMaxIdx=offset else query.bookReviewCount=1;query.likesCount=20;query.likesDirection=1 end
    local response=client:api('/review/single',query)
    local row=A.review(response,bookId);assert(row and row.reviewId==reviewId,'SOCIAL_SCHEMA_CHANGED')
    local comments,seen={},{}
    for i,c in ipairs(response.comments or{})do
        assert(i<=1000,'SOCIAL_RESULT_TOO_LARGE');local comment=A.comment(c,reviewId)
        if comment and not seen[comment.commentId]then comments[#comments+1]=comment;seen[comment.commentId]=true end
    end
    local likes={};for i,v in ipairs(response.likes or{})do assert(i<=1000,'SOCIAL_RESULT_TOO_LARGE');local u=user(v);if u.vid then likes[#likes+1]=u end end
    -- Official count fields may be omitted for zero. Keep unknown distinct from
    -- zero, and never manufacture counts or a complete list from a partial reply.
    local commentOffset=(part~='likes'and(offset or 0)or 0)+#(response.comments or{})
    local likesOffset=(part=='likes'and(offset or 0)or 0)+#(response.likes or{})
    return{review=row,comments=comments,likes=likes,synckey=integer(response.synckey),offset=commentOffset,likesOffset=likesOffset,
        moreComments=#comments>0 and(row.commentsCount~=nil and commentOffset<row.commentsCount or row.commentsCount==nil and #comments>=100),
        moreLikes=#likes>0 and(row.likesCount~=nil and likesOffset<row.likesCount or row.likesCount==nil and #likes>=20)}
end
function A.like(client,reviewId,desired)
    assert(id(reviewId)and type(desired)=='boolean','SOCIAL_WRITE_INVALID')
    client.write_path='/review/like'
    local ok,result=pcall(client.api,client,'/review/like',nil,{reviewId=reviewId,isUnlike=desired and 0 or 1})
    client.write_path=nil
    if not ok then error(result,0)end
    assert(type(result)=='table'and tonumber(result.succ)==1,'SOCIAL_WRITE_NOT_CONFIRMED')
    return true
end
function A.merge(old,new,key)
    local rows,seen={},{}
    for _,list in ipairs{old,new}do for _,r in ipairs(list or{})do
        if not seen[r[key]]then rows[#rows+1]=r;seen[r[key]]=true end
    end end
    return rows
end
return A
