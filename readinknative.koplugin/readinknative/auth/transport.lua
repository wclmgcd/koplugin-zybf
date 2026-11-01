-- Bounded, non-redirecting HTTP transport. It never refreshes or stores tokens.
local T={}
function T.send(request)
    if request.imageArchive then
        assert(request.authenticated and not request.body,'IMAGE_ARCHIVE_REQUEST_REJECTED')
        require('readinknative/protocol').archiveUrl(request.bookId,request.chapterUid,request.url)
    else require('readinknative/protocol').checkRequest(request.url,request.authenticated)end
    local http=require('socket.http')
    local timer=require('socketutil')
    local parts,total,overflow={},0,false
    local raw=request.body and require('rapidjson').encode(request.body)
    local headers=request.headers or {}
    if raw then
        headers['Content-Type']='application/json; charset=utf-8'
        headers['Content-Length']=tostring(#raw)
    end
    local source=raw and require('ltn12').source.string(raw)
    local seconds=request.timeout or 10
    assert(type(seconds)=='number' and seconds>0 and seconds<=120,'TIMEOUT_INVALID')
    timer:set_timeout(seconds,request.timeout and seconds+5 or 35)
    local ok,accepted,status,responseHeaders=pcall(http.request,{
        url=request.url,method=raw and 'POST' or 'GET',headers=headers,redirect=false,
        source=source and function()
            local chunk,err=source()
            if chunk and request.onSent then request.onSent()end
            return chunk,err
        end,
        sink=function(chunk)
            if chunk then
                total=total+#chunk
                if total>(request.limit or 16*1024*1024) then overflow=true;return nil,'RESPONSE_TOO_LARGE'end
                parts[#parts+1]=chunk
            end
            return 1
        end,
    })
    timer:reset_timeout()
    assert(not overflow,'RESPONSE_TOO_LARGE')
    assert(ok and accepted and tonumber(status),'NETWORK_FAILED')
    return {status=tonumber(status),body=table.concat(parts),headers=responseHeaders or {}}
end
return T
