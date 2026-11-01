-- Pre-size covers in a worker. Page painting only decodes small grayscale PNGs.
local C={W=512,H=768}
function C.path(vid,url,square)
    local source=require('readinknative/media').find(vid,url);if not source then return end
    local a=require('libs/libkoreader-lfs').attributes(source);if not a then return end
    local hash=require('ffi/sha2').sha256(source..':'..a.size..':'..a.modification..(square and':512x512:gray-square1'or':512x768:gray1'))
    return require('readinknative/paths').cache(vid,'thumb-'..hash..'.png'),source
end
function C.find(vid,url,square)
    local path=C.path(vid,url,square);if path then path=require('readinknative/cachefiles').readPath(path)end
    if path and require('libs/libkoreader-lfs').attributes(path,'mode')=='file'then return path end
end
function C.prepare(vid,url,fetch,square)
    local M=require('readinknative/media');if not M.find(vid,url)and fetch then M.fetch(vid,url)end
    local path,source=C.path(vid,url,square);if not path then return end
    local found=C.find(vid,url,square);if found then return found end
    local image=require('ui/renderimage'):renderImageFile(source,false);assert(image,'COVER_DECODE_FAILED')
    local gray
    local ok,result=pcall(function()
        if square then
            local side=math.min(image:getWidth(),image:getHeight());local BB=require('ffi/blitbuffer')
            local crop=BB.new(side,side,image:getType());crop:blitFrom(image,0,0,math.floor((image:getWidth()-side)/2),math.floor((image:getHeight()-side)/2),side,side)
            image:free();image=crop
        end
        local ratio=math.min(C.W/image:getWidth(),C.H/image:getHeight(),1)
        image=require('ui/renderimage'):scaleBlitBuffer(image,math.max(1,math.floor(image:getWidth()*ratio)),math.max(1,math.floor(image:getHeight()*ratio)))
        local BB=require('ffi/blitbuffer');gray=BB.new(image:getWidth(),image:getHeight(),BB.TYPE_BB8);gray:fill(BB.COLOR_WHITE)
        gray:alphablitFrom(image,0,0,0,0,image:getWidth(),image:getHeight());assert(require('readinknative/cachefiles').writePNG(gray,path..'.part')~=false,'COVER_WRITE_FAILED')
        assert(require('readinknative/cachefiles').rename(path..'.part',path),'COVER_WRITE_FAILED');return path
    end)
    if gray then gray:free()end;image:free()
    if not ok then require('readinknative/cachefiles').remove(path..'.part');error(result,0)end
    return result
end
return C
