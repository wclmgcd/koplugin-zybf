-- At most two public-image requests in the existing background worker. Children
-- join that worker's process group, so cancel/exit/suspend kills the whole job.
local F={enabled=false}
local function disk(urls,limit,reader,root)
    local results={};local S=require('readinknative/illustrationcache')
    local unique,keys,aliases={},{},{}
    for _,url in ipairs(urls)do
        results[url]=false
        local ok,key=pcall(require('readinknative/media').url,url)
        if ok then
            local first=keys[key]
            if not first then first=url;keys[key]=first;unique[#unique+1]=url;aliases[first]={}end
            aliases[first][#aliases[first]+1]=url
        end
    end
    urls=unique
    local function publish(url,value)for _,alias in ipairs(aliases[url])do results[alias]=value end end
    if not F.enabled or #urls<2 then
        local used=0
        for _,url in ipairs(urls)do
            if used+limit>32*1024*1024 then break end
            local ok,value=pcall(S.fetch,root,url,limit,reader);if ok then publish(url,value);used=used+value.size end
        end
        return results
    end
    local ffi=require('ffi');local U=require('ffi/util');pcall(ffi.cdef,'int getpgid(int);')
    local C=ffi.C;local group=tonumber(C.getpgid(0));local children={};local nextUrl,used=1,0
    -- Children publish tiny receipts, never multi-megabyte image bytes. Each
    -- completed slot starts another request without waiting for its partner.
    while nextUrl<=#urls or #children>0 do
        while nextUrl<=#urls and #children<2 do
            if used+(#children+1)*limit>32*1024*1024 then if #children==0 then nextUrl=#urls+1 end;break end
            local url=urls[nextUrl];nextUrl=nextUrl+1
            local pid,fd=U.runInSubProcess(function(_,out)
                local ok,value=pcall(function()
                    assert(C.setpgid(0,group)==0,'IMAGE_GROUP_FAILED')
                    return S.fetch(root,url,limit,reader)
                end)
                U.writeToFD(out,ok and(value.ext..':'..value.size)or'fail',true)
            end,true)
            if pid then children[#children+1]={pid=pid,fd=fd,url=url}
            else local ok,value=pcall(S.fetch,root,url,limit,reader);if ok then publish(url,value);used=used+value.size end end
        end
        local progressed=false
        for i=#children,1,-1 do
            local child=children[i]
            if U.isSubProcessDone(child.pid)then
                local receipt=U.readAllFromFD(child.fd);local ext,size=receipt:match('^(%.%a+):(%d+)$')
                local value=ext and S.find(root,child.url,limit)
                if value and value.ext==ext and value.size==tonumber(size)and used+value.size<=32*1024*1024 then
                    publish(child.url,value);used=used+value.size
                end
                table.remove(children,i);progressed=true
            end
        end
        if not progressed and #children>0 then U.usleep(5000)end
    end
    return results
end
function F.readAll(urls,limit,reader,root)
    if root then return disk(urls,limit,reader,root)end
    local results={};local media=require('readinknative/media');local budget=32*1024*1024;local used=0
    if not F.enabled or #urls<2 then return results end
    local ffi=require('ffi');local U=require('ffi/util');pcall(ffi.cdef,'int getpgid(int);')
    local C=ffi.C;local group=tonumber(C.getpgid(0))
    for first=1,#urls,2 do
        local children={}
        for i=first,math.min(first+1,#urls)do
            local url=urls[i]
            if pcall(media.url,url)then
                local pid,fd=U.runInSubProcess(function(_,out)
                    local ok,data,ext=pcall(function()
                        assert(C.setpgid(0,group)==0,'IMAGE_GROUP_FAILED')
                        return(reader or media.read)(url,limit)
                    end)
                    local value=ok and('ok'..ext..':'..#data..'\n'..data)or'fail\n'
                    local offset=0;while offset<#value do
                        local n=tonumber(C.write(out,ffi.cast('const char*',value)+offset,#value-offset))
                        if n<=0 then break end;offset=offset+n
                    end
                    C.close(out)
                end,true)
                if pid then children[#children+1]={pid=pid,fd=fd,url=url}end
            else results[url]=false end
        end
        for _,child in ipairs(children)do
            local value=U.readAllFromFD(child.fd);U.isSubProcessDone(child.pid,true)
            local ext,size,data=value:match('^ok(%.%a+):(%d+)\n(.*)$')
            if ext and #data==tonumber(size)and #data<=limit and(ext=='.jpg'or ext=='.png'or ext=='.webp'or ext=='.gif'or(reader and ext=='.tar'))then
                if used+#data<=budget then results[child.url]={data=data,ext=ext};used=used+#data end
            else results[child.url]=false end
        end
        if used>=budget-limit*2 then break end
    end
    return results
end
return F
