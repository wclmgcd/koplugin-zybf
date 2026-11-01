-- One cancellable subprocess at a time. Child results are committed only in
-- the parent after completion and epoch validation (including session updates).
local Jobs={};Jobs.__index=Jobs
function Jobs.new()return setmetatable({epoch=0},Jobs)end
function Jobs:cancel()
    self.epoch=self.epoch+1
    local widget=self.widget;self.widget=nil
    if widget and widget.dismiss_callback then widget.dismiss_callback()end
end
function Jobs:run(label,task,done,target,cancelled,keepPriority)
    self:cancel();local epoch=self.epoch
    local UI=require('ui/uimanager')
    -- Silent work must not install an invisible modal widget. Otherwise the
    -- first ordinary tap cancels it, and suspend can leave queued gestures.
    local silent=target==false
    local message=target or(silent and{})or require('ui/widget/infomessage'):new{text=label..'\n点击取消',dismissable=true}
    self.widget=message
    if target==nil then UI:show(message)end
    return require('ui/trapper'):wrap(function()
        local completed,result=require('ui/trapper'):dismissableRunInSubprocess(function()
            -- Forked thumbnail/range/pagination work should yield CPU to input.
            if not keepPriority and(silent or target)then pcall(function()local ffi=require('ffi');pcall(ffi.cdef,'int nice(int inc);');ffi.C.nice(10)end)end
            require('readinknative/imagefetch').enabled=true
            local ok,value,session=pcall(task)
            if ok then return {ok=true,value=value,session=session}end
            -- Raw transport errors are not persisted or logged by this module.
            return {ok=false,error=tostring(value)}
        end,message)
        if self.widget==message then self.widget=nil end
        if target==nil then UI:close(message)end
        if epoch~=self.epoch or not completed then if cancelled then cancelled()end;return end
        if type(result)~='table'then done(false,'WORKER_FAILED');return end
        if result.ok then done(true,result.value,result.session)else done(false,result.error)end
    end)
end
return Jobs
