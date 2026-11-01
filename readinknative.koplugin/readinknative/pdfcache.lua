-- Whole PDF files use the official PDF CDN route, not chapter ZIP conversion.
-- Streaming keeps large uploads out of Lua's heap. Receipt and body are account
-- bound; only a completed, MuPDF-validated file replaces the previous body.
local C={MAX_BYTES=256*1024*1024,MAX_REDIRECTS=5}
function C.id(book)
    local id=tostring(book.bookId or'')
    assert(#id<=128 and id:match('^[A-Za-z0-9_%-]+$'),'PDF_INVALID')
    return id
end
function C.path(vid,book)
    local key=require('ffi/sha2').sha256(C.id(book)..':'..tostring(book.version or 0))
    return require('readinknative/paths').cache(vid,'pdf-'..key..'.pdf')
end
function C.url(book)return'https://res.weread.qq.com/wrco/pdf_'..C.id(book)end
function C.redirectUrl(current,location)
    assert(type(location)=='string'and #location>0 and #location<=4096 and not location:find('[%c\\]'),'PDF_REDIRECT_REJECTED')
    local url=require('socket.url').absolute(current,location):gsub('#.*$','')
    -- Reuse the already supported WeRead resource/CDN origins. Legacy http
    -- resource locations are upgraded to HTTPS before issuing any request.
    local ok,accepted=pcall(require('readinknative/media').url,url)
    if not ok then
        local host=url:match('^https?://([A-Za-z0-9%.%-]+)/')
        if host and #host<=253 then error('PDF_REDIRECT_HOST_REJECTED:'..host,0)end
        error('PDF_REDIRECT_REJECTED',0)
    end
    return accepted
end
function C.stream(client,info,part)
    local profile=require('readinknative/auth/profile');local F=require('readinknative/cachefiles')
    assert(type(client.data.accessToken)=='string'and #client.data.accessToken>0,'LOGIN_REQUIRED')
    local url=C.url(info);local authenticated=true;local visited={};local started=require('socket').gettime()
    for hop=0,C.MAX_REDIRECTS do
        assert(not visited[url],'PDF_REDIRECT_LIMIT');visited[url]=true
        local remaining=125-(require('socket').gettime()-started);assert(remaining>0,'PDF_NETWORK_FAILED')
        local headers={['User-Agent']=require('readinknative/identity').current().ua,['Accept-Encoding']='identity',Accept='application/pdf'}
        if authenticated then
            headers.vid=tostring(client.data.vid);headers.accessToken=client.data.accessToken
            headers.appver=profile.appver;headers.basever=profile.basever;headers.channelId=profile.channelId
        end
        -- A redirect body is never prepended to the PDF returned by the next hop.
        local f=assert(F.open(part,'wb'),'PDF_WRITE_FAILED');local total=0;local overflow=false;local wrote=true
        local timer=require('socketutil');timer:set_timeout(math.min(120,remaining),remaining)
        local ok,accepted,status,response=pcall(require('socket.http').request,{
            url=url,method='GET',redirect=false,headers=headers,
            sink=function(chunk)
                if chunk then
                    total=total+#chunk
                    if total>C.MAX_BYTES then overflow=true;return nil,'PDF_TOO_LARGE'end
                    if not f:write(chunk)then wrote=false;return nil,'PDF_WRITE_FAILED'end
                end
                return 1
            end,
        })
        timer:reset_timeout();local closed=f:close()
        assert(not overflow,'PDF_TOO_LARGE');assert(wrote and closed,'PDF_WRITE_FAILED')
        local code=tonumber(status);assert(ok and accepted and code,'PDF_NETWORK_FAILED')
        if code~=301 and code~=302 and code~=303 and code~=307 and code~=308 then return code end
        assert(hop<C.MAX_REDIRECTS,'PDF_REDIRECT_LIMIT')
        local location
        for key,value in pairs(type(response)=='table'and response or{})do
            if type(key)=='string'and key:lower()=='location'then location=value;break end
        end
        local nextUrl=C.redirectUrl(url,location)
        -- Once the origin changes, account headers stay removed for the rest
        -- of this chain, including a later redirect back to the initial origin.
        authenticated=authenticated and nextUrl:match('^https://([^/]+)/')=='res.weread.qq.com'
        url=nextUrl
    end
end
function C.structural(path)
    local f=require('readinknative/cachefiles').open(path,'rb');if not f then return false end
    local size=f:seek('end');if not size or size<16 then f:close();return false end
    f:seek('set',0);local header=f:read(8)or''
    f:seek('set',math.max(0,size-4096));local tail=f:read('*a')or'';f:close()
    return header:sub(1,5)=='%PDF-'and tail:find('%%EOF',1,true)~=nil,size
end
function C.validate(path)
    assert(C.structural(path),'PDF_INVALID')
    local available,engine=pcall(require,'ffi/mupdf');assert(available,'PDF_ENGINE_UNAVAILABLE')
    local ok,doc=pcall(engine.openDocument,path)
    assert(ok and doc,'PDF_INVALID')
    local good,pages,locked=pcall(function()return doc:getPages(),doc:needsPassword()end)
    doc:close();assert(good and(locked or type(pages)=='number'and pages>0),'PDF_INVALID')
    return pages,locked
end
function C.find(vid,book)
    local path=require('readinknative/cachefiles').readPath(C.path(vid,book));if not path then return end;local f=require('readinknative/cachefiles').open(path..'.access.json','rb');if not f then return end
    local raw=f:read(4097);f:close();if #raw>4096 then return end
    local ok,r=pcall(require('rapidjson').decode,raw)
    if not ok or type(r)~='table'or r.schema~=1 or r.vid~=tostring(vid)or r.bookId~=C.id(book)
        or r.version~=tostring(book.version or 0)or r.expiresAt and(type(r.expiresAt)~='number'or os.time()>=r.expiresAt)then return end
    if C.structural(path)then return path end
end
function C.fetch(client,book,fromShelf,retried)
    assert(client:ready()and client.data.vid,'LOGIN_REQUIRED')
    local info=require('readinknative/api').info(client,book)
    assert(info.format=='pdf','PDF_INVALID')
    local uploaded=fromShelf==true and C.id(info):sub(1,3)=='CB_'
    local mode=require('readinknative/permission').mode(info,{},client.data.vid)
    assert(uploaded or mode=='full','PDF_PERMISSION_REQUIRED')
    local existing=C.find(client.data.vid,info);if existing then C.validate(existing);return{path=existing,book=info,reused=true}end
    local path=C.path(client.data.vid,info);local part=path..'.part';local F=require('readinknative/cachefiles')
    local streamed,code=pcall(C.stream,client,info,part)
    if not streamed then F.remove(part);error(code,0)end
    if code==401 and not retried and type(client.refresh)=='function'then
        F.remove(part);client:refresh('/book/info');return C.fetch(client,book,fromShelf,true)
    end
    local valid,pages=pcall(function()
        assert(code~=401,'PDF_AUTH_REQUIRED');assert(code~=403,'PDF_FORBIDDEN');assert(code~=404,'PDF_NOT_FOUND')
        assert(code<300 or code>=400,'PDF_REDIRECT_REJECTED')
        assert(code==200,'PDF_DOWNLOAD_FAILED')
        return C.validate(part)
    end)
    if not valid then F.remove(part);error(pages,0)end
    local proof=info._readPermission;local expires=not uploaded and proof and proof.allowed and proof.accessUntil or nil
    local receipt={schema=1,vid=tostring(client.data.vid),bookId=C.id(info),version=tostring(info.version or 0),uploaded=uploaded,expiresAt=expires,pages=pages}
    local rf=assert(F.open(path..'.access.json.part','wb'),'PDF_WRITE_FAILED')
    local written=rf:write(require('rapidjson').encode(receipt));local receiptClosed=rf:close()
    assert(written and receiptClosed,'PDF_WRITE_FAILED')
    assert(F.rename(part,path),'PDF_WRITE_FAILED')
    assert(F.rename(path..'.access.json.part',path..'.access.json'),'PDF_WRITE_FAILED')
    return{path=path,book=info,pages=pages}
end
return C
