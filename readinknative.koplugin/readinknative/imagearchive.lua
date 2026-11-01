-- Official EPUB chapter image bundles. A failed/missing bundle falls back to
-- ordinary public-image fetches, without buying content or trusting new hosts.
local A={}
local function ext(data)
    if data:sub(1,3)=='\255\216\255'then return'.jpg'end
    if data:sub(1,8)=='\137PNG\r\n\26\n' then return'.png'end
    if data:sub(1,4)=='RIFF'and data:sub(9,12)=='WEBP'then return'.webp'end
    if data:sub(1,6)=='GIF87a'or data:sub(1,6)=='GIF89a'then return'.gif'end
end
function A.prepare(client,book,chapters,refs)
    local context={};if #refs==0 or not require('readinknative/imagefetch').enabled or not client.imageArchive then return context end
    local urls,byUrl={},{};local P=require('readinknative/protocol')
    for _,ch in ipairs(chapters)do
        if ch.tar and require('readinknative/permission').mode(book,ch,client.data.vid)=='full'then
            local ok,url=pcall(P.archiveUrl,book.bookId,ch.chapterUid,ch.tar)
            if ok and not byUrl[url]then urls[#urls+1]=url;byUrl[url]=ch end
        end
    end
    if #urls==0 then return context end
    local clock=require('ui/time');local started=clock.monotonic();local decoded=0
    local F=require('readinknative/imagefetch');local reader=function(url)return client:imageArchive(book,byUrl[url])end
    local fetched
    if #urls==1 then
        local ok,data,kind=pcall(reader,urls[1]);fetched={[urls[1]]=ok and{data=data,ext=kind}or false}
    else fetched=F.readAll(urls,require('readinknative/content').MAX_ENTRY,reader)end
    local required={};for _,url in ipairs(refs)do local key=url:gsub('^http:','https:');required[key]=required[key]or{};table.insert(required[key],url)end
    local used=0
    for _,url in ipairs(urls)do
        local value=fetched[url]
        if value then
            local ok,files=pcall(require('readinknative/content').unpack,value.data,nil,'tar')
            if ok then
                decoded=decoded+1
                for name,data in pairs(files)do
                    local key='https://res.weread.qq.com/wrepub/'..name:match('([^/]+)$');local wanted=required[key];local kind=wanted and ext(data)
                    if kind and used+#data<=32*1024*1024 then
                        for _,ref in ipairs(wanted)do if not context[ref]then context[ref]={data=data,ext=kind}end end
                        used=used+#data
                    end
                end
            end
        end
    end
    local count=0;for _ in pairs(context)do count=count+1 end
    require('logger').info('ReadInk image bundle ms/requests/decoded/images:',math.floor(clock.to_ms(clock.monotonic()-started)),#urls,decoded,count)
    return context
end
return A
