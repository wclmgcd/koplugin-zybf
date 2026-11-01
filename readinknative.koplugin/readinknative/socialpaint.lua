-- Compose thoughts and bookstore pages before touching the mapped framebuffer.
-- Compose in one bounded surface; the host retains its normal refresh policy.
local P={}
function P.free(view)
    if view.socialPaintSurface then view.socialPaintSurface:free();view.socialPaintSurface=nil end
end
function P.begin(view,target)
    if view.app.mode~='social'and view.app.mode~='store'then P.free(view);return target end
    if target~=require('device').screen.bb then return target end
    local w,h=target:getWidth(),target:getHeight();local kind=target:getType()
    local surface=view.socialPaintSurface
    if surface and(surface:getWidth()~=w or surface:getHeight()~=h or surface:getType()~=kind)then P.free(view);surface=nil end
    if not surface then
        local ok,value=pcall(require('ffi/blitbuffer').new,w,h,kind)
        if not ok or not value then return target end
        surface=value;view.socialPaintSurface=surface
    end
    return surface
end
function P.commit(view,surface,target)
    if surface==target or surface~=view.socialPaintSurface then return end
    target:blitFrom(surface,0,0,0,0,target:getWidth(),target:getHeight())
    view.socialPaintSerial=(view.socialPaintSerial or 0)+1
    if view.socialPaintSerial==1 then
        require('logger').info('ReadInk off-screen composition active mode/w/h:',view.app.mode,target:getWidth(),target:getHeight())
    end
end
return P
