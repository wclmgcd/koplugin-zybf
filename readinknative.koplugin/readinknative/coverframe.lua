-- Official BookCoverView uses centerCrop(). Work from the existing bounded
-- grayscale thumbnail: crop before scaling, so wide covers never allocate a
-- full-height, arbitrarily wide intermediate bitmap on the Kindle.
local C={}
function C.crop(sw,sh,w,h)
    assert(sw>0 and sh>0 and w>0 and h>0,'INVALID_COVER_SIZE')
    local cw,ch=sw,sh
    if sw*h>sh*w then cw=math.max(1,math.floor(sh*w/h+0.5))
    else ch=math.max(1,math.floor(sw*h/w+0.5))end
    return math.floor((sw-cw)/2),math.floor((sh-ch)/2),cw,ch
end
function C.load(path,w,h)
    local R=require('ui/renderimage');local image=assert(R:renderImageFile(path,false),'COVER_DECODE_FAILED')
    local crop,frame
    local ok,result=pcall(function()
        local x,y,cw,ch=C.crop(image:getWidth(),image:getHeight(),w,h)
        if cw~=image:getWidth()or ch~=image:getHeight()then
            crop=require('ffi/blitbuffer').new(cw,ch,image:getType())
            crop:blitFrom(image,0,0,x,y,cw,ch);image:free();image=nil
        else crop=image;image=nil end
        -- Retain ownership until scaling returns, including native failures.
        frame=assert(R:scaleBlitBuffer(crop,w,h,false),'COVER_SCALE_FAILED')
        if frame~=crop then crop:free()end;crop=nil
        local widget=require('ui/widget/imagewidget'):new{image=frame,alpha=true}
        widget:getSize() -- Establish native ownership before entering the cache.
        frame=nil;return widget
    end)
    if image then image:free()end;if crop then crop:free()end;if frame then frame:free()end
    if not ok then error(result,0)end;return result
end
return C
