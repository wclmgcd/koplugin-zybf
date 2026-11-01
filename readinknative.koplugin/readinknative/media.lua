-- Public cover client. It has no session/client argument and never sends account
-- headers, even when the image host differs from the authenticated API host.
local M={LIMIT=1536*1024}
local hosts={['weread-1258476243.file.myqcloud.com']=true,['rescdn.qqmail.com']=true,['wrco-40036.sh.gfp.tencent-cloud.com']=true,['cdn.weread.qq.com']=true,['res.weread.qq.com']=true,['wfqqreader-1252317822.image.myqcloud.com']=true,
    ['wfqqreader-1252317822.pic.myqcloud.com']=true,['pic.weread.qq.com']=true,
    ['thirdwx.qlogo.cn']=true,['wx.qlogo.cn']=true,['qpic.cn']=true,['mmbiz.qpic.cn']=true,['mmbiz.qlogo.cn']=true,['shp.qpic.cn']=true,['s.weread.qq.com']=true}
function M.url(value)
    assert(type(value)=='string' and #value<=4096 and not value:find('[%c\\]'),'COVER_URL_REJECTED')
    value=value:gsub('^http:','https:')
    local host=value:match('^https://([^/]+)/')
    assert(host and hosts[host],'COVER_URL_REJECTED');return value
end
function M.base(vid,url)
    return require('readinknative/paths').cache(vid,'cover-'..require('ffi/sha2').sha256(url))
end
function M.find(vid,value)
    local ok,url=pcall(M.url,value);if not ok then return end
    local base=M.base(vid,url)
    for _,ext in ipairs({'.jpg','.png','.webp','.gif'})do
        local path=require('readinknative/cachefiles').readPath(base..ext)
        if path and require('libs/libkoreader-lfs').attributes(path,'mode')=='file'then return path end
    end
end
function M.kind(data)
    if data:sub(1,3)=='\255\216\255'then return'.jpg'
    elseif data:sub(1,8)=='\137PNG\r\n\26\n' then return'.png'
    elseif data:sub(1,4)=='RIFF' and data:sub(9,12)=='WEBP'then return'.webp'
    elseif data:sub(1,6)=='GIF87a'or data:sub(1,6)=='GIF89a'then return'.gif'end
end
function M.read(value,limit,options)
    local url=M.url(value);limit=limit or M.LIMIT
    local timer=require('socketutil');local data;local requestUrl=url
    local clock=require('ui/time');local started=clock.monotonic();local firstByte
    for attempt=1,3 do
        local parts,total,overflow,head={},0,false,''
        firstByte=nil
        local output=options and options.output
        local file=output and assert(require('readinknative/cachefiles').open(output,'wb'),'IMAGE_CACHE_WRITE_FAILED')
        local remaining=options and options.timeout and(options.timeout-clock.to_ms(clock.monotonic()-started)/1000)
        assert(not remaining or remaining>0,'COVER_FETCH_FAILED')
        timer:set_timeout(remaining and math.min(2,remaining)or 10,remaining or 20)
        local requestHeaders={['User-Agent']='ReadInk/'..require('readinknative/version'),Accept='image/png,image/jpeg,image/webp',['Accept-Encoding']='identity'}
        if options and options.article then requestHeaders.Referer='https://mp.weixin.qq.com/'end
        local ok,accepted,status,headers=pcall(require('socket.http').request,{
            url=requestUrl,method='GET',redirect=false,
            headers=requestHeaders,
            sink=function(chunk)
                if chunk then
                    firstByte=firstByte or clock.monotonic()
                    total=total+#chunk;if total>limit then overflow=true;return nil,'COVER_TOO_LARGE'end
                    if #head<32 then head=(head..chunk):sub(1,32)end
                    if file then if not file:write(chunk)then return nil,'IMAGE_CACHE_WRITE_FAILED'end else parts[#parts+1]=chunk end
                end
                return 1
            end})
        timer:reset_timeout()
        local closed=not file or file:close()
        assert(closed,'IMAGE_CACHE_WRITE_FAILED')
        assert(not overflow,'COVER_TOO_LARGE');assert(ok and accepted and tonumber(status),'COVER_FETCH_FAILED')
        status=tonumber(status)
        if output and status~=200 then require('logger').info('ReadInk illustration HTTP status/bytes/hop:',status,total,attempt)end
        if status==200 then
            if output then
                local ext=assert(M.kind(head),'COVER_FORMAT_REJECTED')
                require('logger').info('ReadInk illustration transfer ms/first-byte/bytes/hops:',math.floor(clock.to_ms(clock.monotonic()-started)),math.floor(clock.to_ms((firstByte or clock.monotonic())-started)),total,attempt)
                return true,ext,total
            end
            data=table.concat(parts);break
        end
        assert((status==301 or status==302 or status==303 or status==307 or status==308) and attempt<3
            and type(headers)=='table' and type(headers.location)=='string','COVER_FETCH_FAILED')
        -- Every hop is independently restricted to the public cover host list.
        requestUrl=M.url(require('socket.url').absolute(requestUrl,headers.location))
    end
    assert(data,'COVER_FETCH_FAILED')
    local ext=M.kind(data)
    assert(ext,'COVER_FORMAT_REJECTED')
    return data,ext
end
function M.fetch(vid,value)
    local url=M.url(value);local found=M.find(vid,url);if found then return found end
    local data,ext=M.read(url)
    local path=M.base(vid,url)..ext
    local f=assert(require('readinknative/cachefiles').open(path..'.part','wb'),'COVER_WRITE_FAILED')
    local wrote=f:write(data);local closed=f:close()
    if not wrote or not closed then require('readinknative/cachefiles').remove(path..'.part');error('COVER_WRITE_FAILED')end
    assert(require('readinknative/cachefiles').rename(path..'.part',path),'COVER_WRITE_FAILED');return path
end
return M
