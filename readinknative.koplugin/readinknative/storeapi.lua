-- Read routes/queries are taken from the official APK's Retrofit annotations.
-- Results are bounded and normalized before reaching native scenes or disk.
local S={}
local function truncate(text,limit)
    if #text<=limit then return text end
    local finish=limit
    while finish>0 do local nextByte=text:byte(finish+1);if not nextByte or nextByte<128 or nextByte>=192 then break end;finish=finish-1 end
    return text:sub(1,finish)
end
local function scalar(value,max)
    if type(value)=='string'then return truncate(value,max or 4096)end
    if type(value)=='number'and value==value and math.abs(value)<1e15 then return value end
    if type(value)=='boolean'then return value end
end
function S.book(value,longIntro)
    if type(value)~='table'then return end
    local b=value.bookInfo or value.book or value
    if type(b)~='table'or (type(b.bookId)~='string'and type(b.bookId)~='number')or not scalar(b.bookId) or type(b.title)~='string'or b.title==''then return end
    local id=tostring(b.bookId);if id==''or #id>128 or id:find('[%c]')then return end
    local out={bookId=id,title=truncate(b.title,1024),author=type(b.author)=='string'and truncate(b.author,1024)or''}
    for _,key in ipairs({'cover','version','format','type','paid','payType','maxFreeChapter','isChapterPaid','intro','category','publisher','publishTime','totalWords','newRating','newRatingCount','soldout'})do
        out[key]=scalar(b[key],key=='intro'and(longIntro and 65536 or 4096)or 4096)
    end
    local detail=type(b.newRatingDetail)=='table'and b.newRatingDetail or b.ratingDetail
    if type(detail)=='table'then
        out.ratingDetail={title=type(detail.title)=='string'and truncate(detail.title,128)or nil}
        for _,key in ipairs({'good','fair','poor'})do
            local value=detail[key]
            if type(value)=='number'and value>=0 and value<1e9 and value==math.floor(value)then out.ratingDetail[key]=value end
        end
    end
    return out
end
function S.category(value,depth)
    if type(value)~='table'then return end
    local id=value.CategoryId or value.categoryId
    if (type(id)~='string'and type(id)~='number')or type(value.title)~='string'then return end
    id=tostring(id);if id==''or #id>128 or id:find('[%c]')then return end
    local out={id=id,title=truncate(value.title,1024),rank=tonumber(value.ranklist)==1 and 1 or tonumber(value.rank)or 0,total=tonumber(value.totalCount),children={}}
    if type(value.covers)=='table'and type(value.covers[1])=='string'then out.cover=truncate(value.covers[1],4096)end
    local cover=type(value.ranklistCover)=='table'and value.ranklistCover or{}
    if type(cover.eink_chart_title)=='string'then out.headerImage=truncate(cover.eink_chart_title,4096)end
    if (depth or 0)<3 then
        for i,c in ipairs(type(value.sublist)=='table'and value.sublist or{})do
            if i>100 then break end
            local child=S.category(c,(depth or 0)+1);if child then out.children[#out.children+1]=child end
        end
    end
    return out
end
function S.categories(client,ranks)
    local raw=client:api('/market/categories',ranks and {ranklist=1,synckey=0,subtype=0}or{recommend=0,categoryId='',synckey=0,subtype=0})
    assert(type(raw.categories)=='table','STORE_SCHEMA_CHANGED')
    local items={}
    for i,c in ipairs(raw.categories)do
        if i>200 then break end
        local value=S.category(c);if value then items[#items+1]={kind='category',category=value}end
    end
    return {items=items,more=false}
end
function S.home(client)
    local raw=client:api('/market/list',{synckey=0,subtype=0,eink_new=1,rn=1})
    assert(type(raw.data)=='table','STORE_SCHEMA_CHANGED')
    local items={};local reserve={}
    for si,section in ipairs(raw.data)do
        if si>30 then break end
        if type(section)=='table'then
            local first=#items
            local title=type(section.name)=='string'and truncate(section.name,512)or'精选好书'
            if title=='猜你喜欢'then title='精选好书'end
            local recommended=section.type==23 or title=='精选好书'
            items[#items+1]={kind='section',title=title,action=recommended and'refresh'or nil}
            local seen={}
            for i,row in ipairs(type(section.books)=='table'and section.books or{})do
                if i>(recommended and 18 or 6)then break end
                local book=S.book(row)
                if book and not seen[book.bookId]then
                    if i<=6 then items[#items+1]={kind='book',book=book}else reserve[#reserve+1]=book end
                    seen[book.bookId]=true
                end
            end
            if #items==first+1 then
                if section.type==12 and type(section.categories)=='table'and #section.categories>0 then
                    items[#items].title='分类';items[#items].action=nil
                else table.remove(items)end
            end
            for ci,c in ipairs(type(section.categories)=='table'and section.categories or{})do
                if ci>30 then break end
                local category=S.category(c)
                if category then
                    local previews={}
                    for i,row in ipairs(type(c.lectureBooks)=='table'and c.lectureBooks or{})do
                        if i>6 then break end
                        local book=S.book(row);if book then previews[#previews+1]={kind='book',book=book,rank=category.rank==1 and i or nil}end
                    end
                    if #previews>0 then
                        items[#items+1]={kind='section',title=category.title,category=category,headerImage=category.headerImage}
                        for _,row in ipairs(previews)do items[#items+1]=row end
                    else items[#items+1]={kind='category',category=category,card=section.type==12}end
                end
            end
        end
    end
    return {layout=2,items=items,more=false,recommendationPool=reserve,searchHint=type(raw.search)=='table'and scalar(raw.search.text,256)or nil}

end
-- Official StoreService.getGuessYouLike(): small recommendation-only read.
function S.recommendations(client)
    local raw=client:api('/promo/list',{type='recommend_new',subtype=0,count=18})
    assert(type(raw)=='table'and type(raw.books)=='table','STORE_SCHEMA_CHANGED')
    local books,seen={},{}
    for i,row in ipairs(raw.books)do
        if i>36 then break end
        local book=S.book(row)
        if book and not seen[book.bookId]then books[#books+1]=book;seen[book.bookId]=true end
    end
    return books
end
function S.listResult(raw,cursor)
    assert(type(raw)=='table'and type(raw.books)=='table','STORE_SCHEMA_CHANGED')
    local items,seen={},{};local last=cursor or 0
    for i,row in ipairs(raw.books)do
        if i>300 then break end
        if type(row)=='table'then
            local index=tonumber(row.searchIdx)
            if index and index==index and index>last and index<1e12 then last=index end
            local book=S.book(row)
            if book and not seen[book.bookId]then items[#items+1]={kind='book',book=book};seen[book.bookId]=true end
        end
    end
    local requestedMore=raw.hasMore==1 or raw.hasMore==true;local more=requestedMore and last>(cursor or 0)
    return {items=items,cursor=last,more=more,cursorStalled=requestedMore and not more,total=tonumber(raw.totalCount)}
end
function S.list(client,category,cursor)
    assert(type(category)=='table'and type(category.id)=='string','STORE_CATEGORY_INVALID')
    local raw=client:api('/market/category',{categoryId=category.id,synckey=0,count=20,maxIdx=cursor or 0,rank=category.rank or 0})
    return S.listResult(raw,cursor)
end
function S.search(client,query,cursor)
    assert(type(query)=='string'and query:find('%S')and #query<=256,'STORE_QUERY_INVALID')
    local raw=client:api('/store/search',{keyword=query,author='',authorVids='',categoryId='',count=20,maxIdx=cursor or 0,type=0,v=1,outer=0,fromBookId='',scope=0,scene=0,filterType=0,filterField=''})
    return S.listResult(raw,cursor)
end
function S.info(client,book)
    local raw=client:api('/book/info',{bookId=tostring(book.bookId)})
    local value=S.book(raw.book or raw,true)
    assert(value and value.bookId==tostring(book.bookId),'BOOK_SCHEMA_CHANGED');return value
end
function S.add(client,book)
    client.write_path='/shelf/add';client.write_state='unsent'
    client:api('/shelf/add',nil,{bookIds={tostring(book.bookId)},albumIds=require('rapidjson').array(),promoteId='',follow=0})
    -- A write response alone does not replace a shelf snapshot.
    return require('readinknative/api').shelf(client)
end
function S.merge(existing,incoming)
    local out,seen={},{}
    for _,list in ipairs({existing or{},incoming or{}})do
        for _,item in ipairs(list)do
            local id=item.kind=='book'and item.book.bookId or item.kind=='category'and item.category.id
            local key=id and(item.kind..':'..id)
            if not key or not seen[key]then out[#out+1]=item;if key then seen[key]=true end end
        end
    end
    return out
end
return S
