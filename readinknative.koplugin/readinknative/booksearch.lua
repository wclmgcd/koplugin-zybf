-- Search only the account/version/entitlement-valid local reading material.
-- Official remote offsets are not CRengine XPointers and must not be guessed.
local S={LIMIT=200}
function S.valid(a,owner)
    if not owner or a.closed or a.suspended or a.state~=owner.state or not a.document or not a.book then return false end
    if owner.document then return a.document==owner.document end
    local spec=require('readinknative/pagination').spec(a)
    return spec and spec.key==owner.key and tostring(a.client.data.vid)==owner.vid
end
function S.scan(spec,query)
    local Cache=require('readinknative/cache');local P=require('readinknative/pagination')
    local result={rows={},chapters=#spec.chapters,cached=0,full=0,preview=0,failed=0};local files={}
    for index,ch in ipairs(spec.chapters)do
        local path,mode=Cache.find(spec.vid,spec.book,ch)
        if path then
            files[#files+1]={path=path,mode=mode,chapter=ch,index=index,stamp=P.fileStamp(path)}
            result.cached=result.cached+1;result[mode]=result[mode]+1
        end
    end
    local seen={}
    for _,file in ipairs(files)do
        local doc
        local ok,rows=pcall(function()
            local signature=P.signature(file.path)
            if seen[signature]then return{}end
            doc=require('readinknative/document').open(file.path,spec.w,spec.h,spec.format.size,nil,spec.format)
            local matches=doc:search(query);seen[signature]=true;return matches
        end)
        if doc then doc:close()end
        if ok then
            for _,row in ipairs(rows)do
                row.chapterUid=tostring(file.chapter.chapterUid);row.chapterTitle=file.chapter.title;row.chapterIndex=file.index
                row.path=file.path;row.stamp=file.stamp;row.cacheMode=file.mode
                result.rows[#result.rows+1]=row
                if #result.rows>=S.LIMIT then result.truncated=true;return result end
            end
        else result.failed=result.failed+1 end
    end
    return result
end
function S.start(a,query)
    if not a.document then a:message('请先打开书籍，再搜索正文。');return end
    if type(query)~='string'or not query:find('%S')or #query>256 or require('util').fixUtf8(query,'')~=query then a:message('请输入有效搜索词，最多 256 字节。');return end
    require('readinknative/offline').beforeForeground(a);a.coverJobs:cancel()
    local document=a.document;local spec=require('readinknative/pagination').spec(a)
    if not a.book.localFile and not spec then a:message('当前正文尚不能搜索，请重新打开书籍。');return end
    local owner={state=a.state,document=a.book.localFile and document or nil,key=spec and spec.key,vid=tostring(a.client.data.vid)}
    local returnMode=a.mode=='catalog'and'catalog'or'reader'
    return a.jobs:run('搜索本书正文',function()
        if spec then
            -- This runs only in the child. Drop its inherited registry reference
            -- so a recently replaced cache is loaded from disk, never old CRe memory.
            document:close();return S.scan(spec,query)
        end
        local rows=document:search(query);return{rows=rows,localFile=true,truncated=#rows>=S.LIMIT}
    end,function(ok,result)
        if not S.valid(a,owner)or a.document~=document then return end
        if not ok then a:failure(result);return end
        a.searchOwner=owner;a.searchResults=result.rows;a.searchInfo=result;a.searchPage=1;a.searchReturnMode=returnMode
        a.textQuery=query;a.searchFromReader=nil;a.mode='search';a.panel=nil;a:draw()
    end)
end
function S.session(a)return{owner=a.searchOwner,rows=a.searchResults,info=a.searchInfo,page=a.searchPage,query=a.textQuery,returnMode=a.searchReturnMode}end
function S.restore(a,session)
    if not S.valid(a,session.owner)then return end
    a.searchOwner=session.owner;a.searchResults=session.rows;a.searchInfo=session.info;a.searchPage=session.page
    a.textQuery=session.query;a.searchReturnMode=session.returnMode;a.searchFromReader=true
end
function S.jump(a,row)
    if not S.valid(a,a.searchOwner)then a:message('搜索内容已经变化，请重新搜索。');return end
    local found=false;for _,item in ipairs(a.searchResults or{})do if item==row then found=true;break end end
    if not found then return end
    if not a.book.localFile then
        local ch=(a.chapters or{})[row.chapterIndex]
        if not ch or tostring(ch.chapterUid)~=row.chapterUid then a:message('目录已经变化，请重新搜索。');return end
        local path,mode=require('readinknative/cache').find(a.client.data.vid,a.book,ch)
        if path~=row.path or mode~=row.cacheMode or require('readinknative/pagination').fileStamp(path)~=row.stamp then
            a:message('搜索内容已经变化或可读权限已到期，请重新搜索。');return
        end
        a:selectChapter(ch,row.chapterIndex,{xpointer=row.xpointer,searchSession=S.session(a),cacheOnly=true});return
    end
    if a.document:gotoPointer(row.xpointer)then
        a.searchFromReader=true;a.mode='reader';a.toolbar=false;a.panel=nil;a:savePosition();a:startClock();a:draw()
    else a:message('搜索位置已失效，请重新搜索。')end
end
function S.back(a)
    if a.textSelection or a.panel or a.readerOverlay or a.footnote then return end
    if a.searchFromReader and S.valid(a,a.searchOwner)then a.searchFromReader=nil;a.mode='search';a.toolbar=false;a.panel=nil;a:draw();return true end
end
function S.snippet(row)
    local text=tostring(row.text or''):gsub('%s+',' ')
    local matched=type(row.match)=='string'and row.match:gsub('%s+',' ')
    local first=matched and text:find(matched,1,true)
    if first then
        local chars=require('util').splitToChars(text:sub(1,first-1))
        if #chars>12 then text='…'..table.concat(chars,'',#chars-11)..text:sub(first)end
    end
    return text,matched
end
-- TextBox shapes the visible lines first; use its glyph rectangles so Chinese,
-- ligatures and wrapping retain the actual rendered match coordinates.
function S.highlight(bb,box,text,matched,x,y)
    if type(matched)~='string'or matched==''or not box._xtext or not box.getXtextHighlightRects then return end
    local first,last=text:find(matched,1,true);if not first then return end
    local chars=require('util').splitToChars
    first=#chars(text:sub(1,first-1))+1;last=first+#chars(matched)-1
    local rects=box:getXtextHighlightRects(first,last,box.virtual_line_num,math.min(#box.vertical_string_list,box.virtual_line_num+box.lines_per_page-1))
    box.searchHighlights=rects
    for _,r in ipairs(rects)do
        local left,top=math.max(0,math.floor(r.x)),math.max(0,math.floor(r.y))
        local right,bottom=math.min(box.width,math.ceil(r.x+r.w)),math.min(box:getSize().h,math.ceil(r.y+r.h))
        if right>left and bottom>top then bb:invertRect(x+left,y+top,right-left,bottom-top)end
    end
end
function S.empty(a)
    local r=a.searchInfo or{}
    if(r.failed or 0)>0 then return'部分章节未能搜索，请重试。'end
    if not r.localFile and r.full~=r.chapters then return'已下载或试读正文中没有匹配；其他内容尚未搜索。'end
    return'没有找到匹配的正文'
end
function S.scope(a)
    local r=a.searchInfo or{}
    local count=(r.truncated and'至少 'or'')..#(a.searchResults or{})..' 处'
    if r.localFile then return'本书正文 · '..count end
    local scope=r.full==r.chapters and'本书正文'or('已下载正文 '..(r.cached or 0)..'/'..(r.chapters or 0)..' 章')
    if(r.preview or 0)>0 then scope=scope..'（含试读）'end
    if(r.failed or 0)>0 then scope=scope..' · '..r.failed..' 章搜索失败'end
    return scope..' · '..count..(r.truncated and'（显示上限）'or'')
end
return S
