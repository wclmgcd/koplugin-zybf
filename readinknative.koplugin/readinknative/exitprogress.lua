-- A frozen page plus the native message survives plugin/host teardown.
-- It has no timer: KOReader's completed exit clears the window stack.
local UI=require('ui/uimanager')
local Progress=require('ui/widget/container/inputcontainer'):extend{
    name='readink_exit_progress',modal=true,covers_fullscreen=true,
    stop_events_propagation=true,
}
function Progress:paintTo(bb)
    if not self.snapshot then return end
    -- Host restoration may change software rotation or night-mode flags.
    -- Matching buffer metadata preserves the same physical screen pixels.
    self.snapshot:setRotation(bb:getRotation())
    self.snapshot:setInverse(bb:getInverse())
    bb:blitFrom(self.snapshot,0,0,0,0,bb:getWidth(),bb:getHeight())
end
local function consume()return true end
Progress.onGesture=consume
Progress.onKeyPress=consume
Progress.onKeyRelease=consume
Progress.onClose=consume
Progress.onBack=consume
Progress.onHome=consume
function Progress:onCloseWidget()
    if self.snapshot then self.snapshot:free();self.snapshot=nil end
end
local M={}
function M.show()
    -- Exit buttons may have just dismissed their menu; paint the page first.
    UI:forceRePaint()
    local screen=require('device').screen
    local snapshot=screen.bb:copy()
    local message,label
    local ok,err=pcall(function()
        local face=require('ui/font'):getFace('infofont')
        label=require('ui/widget/textwidget'):new{text='退出中...',face=face}
        local width=math.min(math.ceil(label:getSize().w+screen:scaleBySize(16)),screen:getWidth()-screen:scaleBySize(48))
        label:free();label=nil
        message=require('ui/widget/infomessage'):new{
            text='退出中...',show_icon=false,alignment='center',
            dismissable=false,unmovable=true,face=face,width=width,force_one_line=true,
        }
        message:paintTo(snapshot,0,0)
    end)
    if label then label:free()end
    if message then message:free()end
    if not ok then snapshot:free();error(err,0)end
    local progress=Progress:new{
        snapshot=snapshot,
        dimen=require('ui/geometry'):new{x=0,y=0,w=screen:getWidth(),h=screen:getHeight()},
    }
    UI:show(progress);UI:forceRePaint()
    return progress
end
return M
