-- Localize public book illustrations before an EPUB is committed. No account headers.
local I={}
local function unxml(s)
    return(s:gsub('&amp;','&'):gsub('&quot;','"'):gsub('&apos;',"'"))
end
local function walk(files,visit)
    local changed=false
    local names={};for name in pairs(files)do names[#names+1]=name end;table.sort(names)
    for _,name in ipairs(names)do
        local lower=name:lower();local text=files[name]
        if lower:match('%.x?html?$')then
            text=text:gsub('<[iI][mM][gG]%f[%s/>][^>]*>',function(tag)
                return(tag:gsub('(%s[sS][rR][cC]%s*=%s*)(["\'])(.-)%2',function(before,quote,ref)return before..quote..visit(name,ref)..quote end))
            end)
        elseif lower:match('%.svg$')then
            text=text:gsub('<[iI][mM][aA][gG][eE]%f[%s/>][^>]*>',function(tag)
                return(tag:gsub('([%s:][hH][rR][eE][fF]%s*=%s*)(["\'])(.-)%2',function(before,quote,ref)return before..quote..visit(name,ref)..quote end))
            end)
        elseif lower:match('%.css$')then
            text=text:gsub('([uU][rR][lL]%(%s*)(["\']?)(.-)%2(%s*%))',function(before,quote,ref,after)
                local path=ref:match('^[^?#]+')or ref
                if path:lower():match('%.jpe?g$')or path:lower():match('%.png$')or path:lower():match('%.webp$')or path:lower():match('%.gif$')then ref=visit(name,ref)end
                return before..quote..ref..quote..after
            end)
        end
        if text~=files[name]then changed=true end
        files[name]=text
    end
    return changed
end
function I.references(files)
    local urls,seen={},{}
    walk(files,function(_,ref)
        local url=unxml(ref);if url:sub(1,2)=='//'then url='https:'..url end
        if url:match('^https?://')and not seen[url]and #urls<1024 then urls[#urls+1]=url;seen[url]=true end
        return ref
    end)
    return urls
end
function I.prefetch(files,seed,limit,reader,root,maxRequests)
    seed=seed or{};local urls={};limit=limit or require('readinknative/content').MAX_ENTRY
    local S=root and require('readinknative/illustrationcache');local pending=seed._pending or{}
    for _,url in ipairs(I.references(files))do
        if S then
            local ok,value=pcall(S.find,root,url,limit);if not ok then value=nil end
            if not value and type(seed[url])=='table'and seed[url].data then
                local image=seed[url];local ok,saved=pcall(S.fetch,root,url,limit,function()return image.data,image.ext end)
                if ok then value=saved end
            end
            if value then seed[url]=value end
        end
        if type(seed[url])=='table'then pending[url]=nil end
        if seed[url]==nil then
            if maxRequests and #urls>=maxRequests then seed[url]=false;pending[url]=true
            else urls[#urls+1]=url end
        end
    end
    local fetched=require('readinknative/imagefetch').readAll(urls,limit,reader,root)
    for url,value in pairs(fetched)do seed[url]=value end
    seed._pending=next(pending)and pending or nil;return seed
end
local types={['.jpg']='image/jpeg',['.png']='image/png',['.webp']='image/webp',['.gif']='image/gif'}
function I.localize(files,prefix,context)
    prefix=prefix or'';local seen,added={},{};local result={schema=1,total=0,downloaded=0,missing=0,complete=true}
    local bytes,count=0,0;local names={};local existing={};local waiting=0
    for name,data in pairs(files)do bytes=bytes+#data;count=count+1;names[#names+1]=name end;table.sort(names)
    local limits=require('readinknative/content')
    local function image(source,ref)
        local url=unxml(ref);if url:sub(1,2)=='//'then url='https:'..url end
        if not url:match('^https?://')then
            if url:find('readink-assets/',1,true)then
                local resolved={}
                for part in((source:match('^(.*)/')or'')..'/'..url):gmatch('[^/]+')do
                    if part=='..'then table.remove(resolved)elseif part~='.'then resolved[#resolved+1]=part end
                end
                local name=table.concat(resolved,'/')
                if files[name]and not existing[name]then existing[name]=true;result.total=result.total+1;result.downloaded=result.downloaded+1 end
            end
            return ref
        end
        if seen[url]==nil then
            result.total=result.total+1
            local ok,data,ext=pcall(function()
                assert(count<limits.MAX_FILES,'IMAGE_RESOURCE_LIMIT')
                local cached=context and context[url]
                assert(cached~=false,'IMAGE_FETCH_FAILED')
                local data,ext
                if cached and cached.path then data,ext=require('readinknative/illustrationcache').read(cached,limits.MAX_ENTRY)
                elseif cached then data,ext=cached.data,cached.ext else data,ext=require('readinknative/media').read(url,limits.MAX_ENTRY)end
                assert(bytes+#data<=limits.MAX_TOTAL,'IMAGE_RESOURCE_LIMIT')
                return data,ext
            end)
            if ok then
                local name=prefix..'readink-assets/'..require('ffi/sha2').sha256(url)..ext
                if not files[name]then files[name]=data;added[#added+1]={name=name,type=types[ext]};bytes=bytes+#data;count=count+1 end
                seen[url]=name;result.downloaded=result.downloaded+1
            else
                seen[url]=false;result.missing=result.missing+1
                if context and context._pending and context._pending[url]then waiting=waiting+1 else result.error='IMAGE_FETCH_FAILED'end
            end
        end
        local target=seen[url];if not target then return ref end
        local relative=source:sub(#prefix+1);local _,depth=relative:gsub('/','')
        return string.rep('../',depth)..target:sub(#prefix+1)
    end
    result.changed=walk(files,image)or nil
    result.complete=result.missing==0
    if waiting>0 then result.pending=true end
    return result,added
end
function I.marker(path,status)
    local f=assert(require('readinknative/cachefiles').open(path..'.images.json.part','wb'),'IMAGE_STATUS_WRITE_FAILED')
    assert(f:write(require('rapidjson').encode(status)),'IMAGE_STATUS_WRITE_FAILED');assert(f:close(),'IMAGE_STATUS_WRITE_FAILED')
    assert(require('readinknative/cachefiles').rename(path..'.images.json.part',path..'.images.json'),'IMAGE_STATUS_WRITE_FAILED')
end
function I.status(path)
    local f=require('readinknative/cachefiles').open(path..'.images.json','rb');if not f then return end
    local s=f:read(4097);f:close();if not s or #s>4096 then return end
    local ok,r=pcall(require('rapidjson').decode,s)
    if not ok or type(r)~='table'or r.schema~=1 or type(r.complete)~='boolean'then return end
    for _,key in ipairs({'total','downloaded','missing'})do
        local value=r[key];if type(value)~='number'or value<0 or value>1024 or value%1~=0 then return end
    end
    local unsupported=r.unsupported or 0
    if type(unsupported)~='number'or unsupported<0 or unsupported>1024 or unsupported%1~=0 then return end
    if r.downloaded+r.missing==r.total and r.complete==(r.missing==0 and unsupported==0)then return r end
end
function I.ready(path)local r=I.status(path);return r and r.complete and r.missing==0 end
return I
