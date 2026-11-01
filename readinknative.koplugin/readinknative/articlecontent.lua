-- Convert the actual #js_content subtree to a bounded, offline native EPUB.
-- No publisher scripts, tracking forms, web fonts or fixed-size mobile CSS run.
local H={LIMIT=3*1024*1024,RESPONSE_LIMIT=6*1024*1024,LAYOUT=1,SOURCE=2}
local function xml(v)return tostring(v or''):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;'):gsub('"','&quot;')end
local function unxml(v)return(v:gsub('&amp;','&'):gsub('&quot;','"'):gsub('&#39;',"'"))end
local function attrs(tag)
    local out={};local pos=(select(2,tag:find('^<%s*/?[%w:_%-]+'))or 0)+1
    while pos<=#tag do
        local a,b,name=tag:find('^%s*([%w:_%-]+)',pos)
        if not a then break end;pos=b+1;name=name:lower()
        local _,e=tag:find('^%s*=%s*',pos)
        if e then
            pos=e+1;local quote=tag:sub(pos,pos);local value
            if quote=='"'or quote=="'"then local finish=tag:find(quote,pos+1,true);if not finish then break end;value=tag:sub(pos+1,finish-1);pos=finish+1
            else local s,f=tag:find('^[^%s>]+',pos);if not s then break end;value=tag:sub(s,f):gsub('/$','');pos=f+1 end
            if not out[name]then out[name]=unxml(value)end
        end
    end
    return out
end
-- Quote-aware token boundaries, comments and raw script/style regions. This
-- avoids truncating a nested div at the first </div> or treating script as HTML.
local function tokens(raw,visit)
    local lower=raw:lower();local pos=1;local count=0
    while pos<=#raw do
        local start=raw:find('<',pos,true)
        if not start then visit(raw:sub(pos),nil,nil,nil,pos,#raw);break end
        if start>pos then visit(raw:sub(pos,start-1),nil,nil,nil,pos,start-1)end
        if raw:sub(start,start+3)=='<!--'then pos=(raw:find('-->',start+4,true)or(#raw-2))+3
        else
            local finish=start+1;local quote
            while finish<=#raw do
                local ch=raw:sub(finish,finish)
                if quote then if ch==quote then quote=nil end
                elseif ch=='"'or ch=="'"then quote=ch elseif ch=='>'then break end
                finish=finish+1
            end
            assert(finish<=#raw,'ARTICLE_HTML_INVALID')
            local tag=raw:sub(start,finish);local closing,name=tag:match('^<%s*(/?)%s*([%w:_%-]+)')
            name=name and name:lower();count=count+1;assert(count<=100000,'ARTICLE_TOO_LARGE')
            if name=='script'or name=='style'or name=='iframe'or name=='object'then
                if closing~='/'then
                    local _,endpos=lower:find('</'..name..'%s*>',finish+1);assert(endpos,'ARTICLE_HTML_INVALID');pos=endpos+1
                else pos=finish+1 end
            else
                if visit(tag,name,closing=='/',tag:match('/%s*>$')~=nil,start,finish)==false then return end
                pos=finish+1
            end
        end
    end
end
function H.extract(raw,response)
    assert(type(raw)=='string'and #raw<=(response and H.RESPONSE_LIMIT or H.LIMIT),'ARTICLE_TOO_LARGE')
    local start,finish,root,depth
    tokens(raw,function(tag,name,closing,selfClose,a,b)
        if not start then
            if name and not closing then
                local a=attrs(tag);local class=' '..tostring(a.class or''):gsub('%s+',' ')..' '
                if a.id=='js_content'or((name=='div'or name=='section'or name=='article'or name=='main')and class:find(' rich_media_content ',1,true))then start=b+1;root=name;depth=1 end
            end
        elseif name==root then
            if closing then depth=depth-1;if depth==0 then finish=a-1;return false end
            elseif not selfClose then depth=depth+1 end
        end
    end)
    local body=start and finish and raw:sub(start,finish)or nil
    if not body or not body:gsub('<!%-%-.-%-%->',''):find('%S')then body=require('readinknative/articlemarkup').embedded(raw,H.LIMIT)end
    if not body or not body:find('%S')then
        if raw:find('验证',1,true)or raw:find('captcha',1,true)or raw:find('环境异常',1,true)then error('ARTICLE_VERIFICATION_REQUIRED')end
        error('ARTICLE_BODY_UNAVAILABLE')
    end
    assert(#body<=H.LIMIT,'ARTICLE_TOO_LARGE');return body
end
-- Article paragraphs follow the web article flow, independently of the
-- novel reader's global first-line indent. Never import publisher dimensions,
-- positioning, web fonts or backgrounds into the reflowable document.
H.LAYOUT_MARKER='<meta name="readink-article-layout" content="1" />'
H.CSS=[[
body.readink-article{color:#000;background:#fff;text-align:left;text-indent:0}
body.readink-article p{margin:0 0 .7em 0;text-indent:0 !important}
body.readink-article div,body.readink-article section{margin:0;padding:0;text-indent:0}
body.readink-article a{color:#000;text-decoration:underline}
body.readink-article img{max-width:100%;height:auto}
body.readink-article h1{font-size:1.3em}
body.readink-article pre{white-space:pre-wrap;text-indent:0 !important}
body.readink-article table{max-width:100%}
body.readink-article .readink-empty,body.readink-article p+br,body.readink-article img+br{display:none !important}
]]
local function articleStyle(raw,align)
    local styles={};local values={}
    for key,value in tostring(raw or''):lower():gmatch('([%w%-]+)%s*:%s*([^;]+)')do
        value=value:gsub('%s*!important%s*$',''):match('^%s*(.-)%s*$');values[key]=value
    end
    local a=values['text-align']or tostring(align or''):lower()
    if a=='left'or a=='right'or a=='center'or a=='justify'then styles[#styles+1]='text-align:'..a end
    local weight=values['font-weight']
    if weight=='bold'or weight=='normal'or(weight and weight:match('^[1-9]00$'))then styles[#styles+1]='font-weight:'..weight end
    local italic=values['font-style'];if italic=='italic'or italic=='normal'then styles[#styles+1]='font-style:'..italic end
    local decoration=values['text-decoration']or values['text-decoration-line']
    if decoration and decoration:find('underline',1,true)then styles[#styles+1]='text-decoration:underline'
    elseif decoration and decoration:find('line-through',1,true)then styles[#styles+1]='text-decoration:line-through'end
    local size,unit=tostring(values['font-size']or''):match('^(%d*%.?%d+)([a-z%%]+)$')
    size=tonumber(size)
    if size and(unit=='px'or unit=='em'or unit=='%')then
        local ratio=unit=='px'and size/16 or(unit=='%'and size/100 or size)
        styles[#styles+1]=string.format('font-size:%.3fem',math.max(.75,math.min(1.5,ratio)))
    end
    return #styles>0 and table.concat(styles,';')or nil
end
local function visible(text)
    return text:gsub('&nbsp;',''):gsub('&ensp;',''):gsub('&emsp;',''):gsub('&thinsp;','')
        :gsub('&#[xX]([%da-fA-F]+);',function(n)local x=tonumber(n,16);return(x==160 or x==8192 or x==8193 or x==8194 or x==8195 or x==8201 or x==8203 or x==65279)and''or'X'end)
        :gsub('&#(%d+);',function(n)local x=tonumber(n);return(x==9 or x==10 or x==13 or x==32 or x==160 or x==8192 or x==8193 or x==8194 or x==8195 or x==8201 or x==8203 or x==65279)and''or'X'end)
        :gsub('\194\160',''):gsub('\226\128\139',''):gsub('\239\187\191',''):gsub('%s','')~=''
end
-- Mark blank layout containers without deleting or renaming any node. Saved
-- article XPointer paths, named anchors and inline/preformatted breaks survive.
local function compact(body)
    local out,stack={},{};local void={br=true,hr=true,img=true}
    tokens(body,function(tag,name,closing,selfClose)
        out[#out+1]=tag
        local parent=stack[#stack]
        if not name then if parent and visible(tag)then parent.content=true end;return end
        if closing then
            local node=stack[#stack];if not node or node.name~=name then return end
            stack[#stack]=nil
            if not node.content and not node.pre and(name=='p'or name=='div'or name=='section')then
                local opening=out[node.index];local classes=attrs(opening).class
                if not classes then opening=opening:gsub('^(<[%w:_%-]+)','%1 class="readink-empty"',1)
                elseif not classes:find('readink-empty',1,true)then opening=opening:gsub('class%s*=%s*(["\'])(.-)%1',function(q,v)return'class='..q..v..' readink-empty'..q end,1)end
                out[node.index]=opening
            end
            if node.content and stack[#stack]then stack[#stack].content=true end
        elseif not void[name]and not selfClose then
            stack[#stack+1]={name=name,index=#out,pre=name=='pre'or name=='code'or(parent and parent.pre),content=false}
        elseif(name=='img'or name=='hr')and parent then parent.content=true end
    end)
    return table.concat(out)
end
function H.reflow(html)
    if html:find(H.LAYOUT_MARKER,1,true)then return html end
    local lower=html:lower();local start,finish=lower:find('<body[^>]*>');local ending=finish and lower:find('</body%s*>',finish+1)
    assert(start and ending,'ARTICLE_HTML_INVALID')
    local opening=html:sub(start,finish)
    assert(not attrs(opening).class,'ARTICLE_HTML_INVALID') -- generated article body only
    opening=opening:gsub('>',' class="readink-article">',1)
    local head=html:sub(1,start-1):gsub('<style[^>]*>.-</style>','')
    head=head:gsub('</head>',function()return H.LAYOUT_MARKER..'<style>'..H.CSS..'</style></head>'end,1)
    return head..opening..compact(html:sub(finish+1,ending-1))..html:sub(ending)
end
local allowed={div=true,p=true,section=true,span=true,h1=true,h2=true,h3=true,h4=true,h5=true,h6=true,
    strong=true,b=true,em=true,i=true,u=true,s=true,del=true,blockquote=true,pre=true,code=true,
    ul=true,ol=true,li=true,table=true,thead=true,tbody=true,tr=true,td=true,th=true,sup=true,sub=true,small=true,a=true,br=true,hr=true,img=true}
local void={br=true,hr=true,img=true}
function H.clean(body)
    local out,stack={},{};local images,rejected,skipped,seen=0,0,0,{}
    tokens(body,function(tag,name,closing,selfClose)
        if not name then if tag:sub(1,1)~='<'then out[#out+1]=tag:gsub('%z','')end;return end
        if not allowed[name]then return end
        if closing then
            for i=#stack,1,-1 do if stack[i]==name then for j=#stack,i,-1 do out[#out+1]='</'..table.remove(stack)..'>'end;break end end
        else
            local a=attrs(tag);local extra=''
            if name=='img'then
                local src,reason=require('readinknative/articlemarkup').image(a)
                if not src and reason=='empty'then skipped=skipped+1;out[#out+1]='<p class="readink-empty-image"></p>';return end
                local ok,url=pcall(require('readinknative/media').url,src and(src:sub(1,2)=='//'and'https:'..src or src))
                if not ok then rejected=rejected+1;out[#out+1]='<p>[图片暂不可用]</p>';return end
                if not seen[url]then
                    if images>=512 then rejected=rejected+1;out[#out+1]='<p>[图片暂不可用]</p>';return end
                    images=images+1;seen[url]=true
                end;extra=' src="'..xml(url)..'" alt="'..xml(a.alt)..'"'
            elseif name=='a'and a.href and a.href:match('^#[%w_%-]+$')then extra=' href="'..xml(a.href)..'"'end
            if a.id and #a.id<=128 and a.id:match('^[%w_%-]+$')then extra=extra..' id="'..xml(a.id)..'"'end
            if(name=='td'or name=='th')then
                for _,key in ipairs{'colspan','rowspan'}do local n=tonumber(a[key]);if n and n>=1 and n<=20 and n%1==0 then extra=extra..' '..key..'="'..n..'"'end end
            end
            local style=articleStyle(a.style,a.align);if style then extra=extra..' style="'..style..'"'end
            out[#out+1]='<'..name..extra..(void[name]and' />'or'>')
            if not void[name]then stack[#stack+1]=name;assert(#stack<=256,'ARTICLE_HTML_INVALID');if selfClose then out[#out+1]='</'..table.remove(stack)..'>'end end
        end
    end)
    for i=#stack,1,-1 do out[#out+1]='</'..stack[i]..'>'end
    local html=table.concat(out)
    assert(html:gsub('<[^>]*>',''):find('%S')or images>0,'ARTICLE_BODY_UNAVAILABLE')
    return html,{images=images,rejectedImages=rejected,emptyImages=skipped}
end
function H.html(raw,meta)
    assert(type(raw)=='string'and #raw<=(meta.fragment and H.LIMIT or H.RESPONSE_LIMIT),'ARTICLE_TOO_LARGE')
    local fragment
    if meta.fragment then
        local lower=raw:lower();local _,start=lower:find('<body[^>]*>');local finish=start and lower:find('</body',start+1,true)
        fragment=start and finish and raw:sub(start+1,finish-1)or raw
    else fragment=H.extract(raw)end
    local body,stats=H.clean(fragment)
    local date=meta.published and os.date('%Y-%m-%d %H:%M',meta.published)or''
    return H.reflow('<html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"/><title>'..xml(meta.title)..'</title></head><body><h1>'..xml(meta.title)..'</h1><p>'..xml(meta.account)..' '..xml(date)..'</p>'..body..'</body></html>'),stats
end
function H.book(row)
    return {bookId='mp-'..require('ffi/sha2').sha256(require('readinknative/articleapi').id(row.reviewId)),version=1,title=row.title,author=row.account or'',article=true}
end
function H.path(vid,row)return require('readinknative/cache').path(vid,H.book(row),{chapterUid=1},'full')end
function H.find(vid,row)
    local path=require('readinknative/cachefiles').readPath(H.path(vid,row));if not path then return end;local f=require('readinknative/cachefiles').open(path..'.article.json','rb');if not f then return end
    local data=f:read(16385);f:close();if #data>16384 then return end
    local ok,r=pcall(require('rapidjson').decode,data)
    if ok and type(r)=='table'and r.schema==1 and r.vid==tostring(vid)and r.reviewId==row.reviewId and type(r.title)=='string'and type(r.account)=='string'
        and(require('libs/libkoreader-lfs').attributes(path,'size')or 0)>0 then return path,r end
end
-- Missing-image repair only touches existing article/image resources. It
-- never re-fetches cached article text through a separate account session.
function H.repair(vid,row)
    local path,record=H.find(vid,row);assert(path,'ARTICLE_BODY_UNAVAILABLE')
    record.imagesAttemptAt=os.time()
    local attempt=assert(require('readinknative/cachefiles').open(path..'.article.json.part','wb'),'ARTICLE_CACHE_WRITE_FAILED');assert(attempt:write(require('rapidjson').encode(record)));assert(attempt:close());assert(require('readinknative/cachefiles').rename(path..'.article.json.part',path..'.article.json'))
    local _,status=require('readinknative/content').repair(path,H.imageContext);status.unsupported=record.rejectedImages or 0;status.complete=status.missing==0 and status.unsupported==0;require('readinknative/images').marker(path,status);record.images=status
    local f=assert(require('readinknative/cachefiles').open(path..'.article.json.part','wb'),'ARTICLE_CACHE_WRITE_FAILED')
    assert(f:write(require('rapidjson').encode(record)),'ARTICLE_CACHE_WRITE_FAILED');assert(f:close(),'ARTICLE_CACHE_WRITE_FAILED')
    assert(require('readinknative/cachefiles').rename(path..'.article.json.part',path..'.article.json'),'ARTICLE_CACHE_WRITE_FAILED')
    pcall(require('readinknative/articleshared').remember,vid,record)
    return {path=path,meta=record}
end
-- Keep public images parallel in small groups; never retain hundreds of
-- full-size responses before the EPUB's 32 MiB resource budget is checked.
function H.imageContext(files)
    local I=require('readinknative/images');local urls=I.references(files);local remaining=require('readinknative/content').MAX_TOTAL
    for _,body in pairs(files)do remaining=remaining-#body end
    local context={};local index=1
    while index<=#urls do
        local batch={};local tags={}
        for j=index,math.min(index+3,#urls)do
            local url=urls[j];batch[#batch+1]=url;tags[#tags+1]='<img src="'..xml(url)..'"/>'
        end
        local function readImage(url,limit)return require('readinknative/media').read(url,limit,{article=true})end
        local fetched=remaining>0 and I.prefetch({['batch.xhtml']=table.concat(tags)},nil,math.min(require('readinknative/content').MAX_ENTRY,remaining),readImage)or{}
        for _,url in ipairs(batch)do
            local value=fetched[url]
            -- The generic prefetch intentionally leaves a singleton (or a
            -- disabled parallel runtime) to the caller's serial fallback.
            -- nil is not a failed download; explicit false must not be retried.
            if value==nil and remaining>0 then
                local ok,data,ext=pcall(readImage,url,math.min(require('readinknative/content').MAX_ENTRY,remaining))
                value=ok and{data=data,ext=ext}or false
            end
            if type(value)=='table'and type(value.data)=='string'and #value.data<=remaining then context[url]=value;remaining=remaining-#value.data
            else context[url]=false end
        end
        index=index+#batch
    end
    return context
end
function H.prepare(raw,vid,meta,deferImages,seed)
    local html,stats=H.html(raw,meta);local b=H.book(meta);local chapter={chapterUid=1,title=meta.title}
    local files={['article.xhtml']=html,['info.txt']=require('rapidjson').encode{bookId=b.bookId,chapters={{chapterUid=1,files={'article.xhtml'}}}}}
    local context
    if deferImages then context={};for _,url in ipairs(require('readinknative/images').references(files))do context[url]=seed and seed[url]or false end
    else context=H.imageContext(files)end
    local pending=assert(require('readinknative/cachefiles').open(H.path(vid,meta)..'.article.json.part','wb'),'ARTICLE_CACHE_WRITE_FAILED');assert(pending:write('{}'));assert(pending:close())
    local path,status=require('readinknative/content').prepareFiles(files,vid,b,chapter,'full',context)
    status.unsupported=stats.rejectedImages;status.complete=status.missing==0 and status.unsupported==0;require('readinknative/images').marker(path,status)
    local record={schema=1,vid=tostring(vid),reviewId=meta.reviewId,title=meta.title,account=meta.account,url=meta.url,published=meta.published,
        updated=os.time(),images=status,rejectedImages=stats.rejectedImages,emptyImages=stats.emptyImages,sourceSchema=H.SOURCE,bodySource=meta.bodySource,requiresCheck=meta.requiresCheck,preview=meta.preview}
    local f=assert(require('readinknative/cachefiles').open(path..'.article.json.part','wb'),'ARTICLE_CACHE_WRITE_FAILED')
    assert(f:write(require('rapidjson').encode(record)),'ARTICLE_CACHE_WRITE_FAILED');assert(f:close(),'ARTICLE_CACHE_WRITE_FAILED')
    assert(require('readinknative/cachefiles').rename(path..'.article.json.part',path..'.article.json'),'ARTICLE_CACHE_WRITE_FAILED');pcall(require('readinknative/articleshared').remember,vid,record);return path,record
end
return H
