-- Bounded file-only progress between the cancellable font worker and the UI.
-- The worker never touches widgets, CRe, or a live reader's FreeType objects.
local M={serial=0,timeout=180}
local labels={download='正在下载',extract='正在解压',install='正在安装',done='安装完成',failed='下载未完成'}
function M.cancel(a,quiet)
 local status=a.fontDownload;if not status then return end
 a.jobs:cancel();if status.cancel then status.cancel(quiet)end
end
function M.run(a,item,task,done,inline)
 local UI=require('ui/uimanager');local socket=require('socket');local lfs=require('libs/libkoreader-lfs')
 local ffi=require('ffi');pcall(ffi.cdef,'int getpid(void);');M.serial=M.serial+1
 local dir=require('datastorage'):getDataDir()..'/cache';require('util').makePath(dir)
 local token='owner-'..tonumber(ffi.C.getpid())..'-'..string.format('%.0f',socket.gettime()*1000)..'-'..M.serial
 local path=dir..'/readink-font-progress-'..token
 local temporary=require('readinknative/fontfetch').path(item)..'.'..token..'.part'
 assert(not lfs.symlinkattributes(path),'FONT_PROGRESS_PATH_EXISTS')
 local f=assert(io.open(path,'wb'));assert(f:write('download 0\n'));assert(f:close())
 local started=socket.gettime();local lastPhase,lastWrite;local widget,closed,lastText
 local status=inline and{font=item.font,percent=0,phase='download'}or nil
 if status then a.fontDownload=status;a:draw()end
 local function report(phase,bytes,total)
  local now=socket.gettime();if phase==lastPhase and lastWrite and now-lastWrite<0.5 then return end
  lastPhase=phase;lastWrite=now
  if not labels[phase]then return end
  local percent=bytes and total and total>0 and math.min(100,math.max(0,math.floor(bytes/total*100)))or 0
  -- r+b cannot recreate the progress file after cancellation/cleanup.
  local out=io.open(path,'r+b');if out then out:write(string.format('%-10s %3d\n',phase,percent));out:close()end
 end
 local poll
 local function cleanup(redraw)
  if closed then return end;closed=true;UI:unschedule(poll);os.remove(path)
  -- The UI owns this unique job path. Jobs cancels/kills the writer first;
  -- unlink only our regular temporary file, never a completed/foreign font.
  if lfs.symlinkattributes(temporary:match('^(.*)/'),'mode')=='directory'and lfs.symlinkattributes(temporary,'mode')=='file'then os.remove(temporary)end
  if status and a.fontDownload==status then a.fontDownload=nil;if redraw and not a.closed and not a.suspended then a:draw()end end
 end
 if status then status.cancel=function(quiet)cleanup(not quiet)end end
 poll=function()
  if closed then return end
  if a.jobs.widget~=widget then cleanup(true);return end
  if a.closed or a.suspended then a.jobs:cancel();cleanup(true);return end
  if socket.gettime()-started>=M.timeout then
   a.jobs:cancel();cleanup(true);a:message('字体处理超时，已取消。请稍后重试。');return
  end
  local input=io.open(path,'rb');local raw=input and input:read(64);if input then input:close()end
  local phase,percent=(raw or''):match('^(%a+)%s+(%d+)')
  if labels[phase]then
   if status then
    -- The official tile says 下载中 until installation/selection completes.
    -- Avoid repainting the whole font sheet for invisible byte percentages.
    status.percent=math.min(100,tonumber(percent));status.phase=phase
   else
   local text=labels[phase]..' '..item.fontName..'\n'..math.min(100,tonumber(percent))..'% · 点击取消'
   if text~=lastText then
    lastText=text;widget.text=text;widget:free();widget:init();UI:setDirty(widget,'ui')
   end
   end
  end
  UI:scheduleIn(0.5,poll)
 end
 local target;if inline then target=false end
 local result=a.jobs:run('正在下载 '..item.fontName, function()return task(report,token)end,function(ok,value)
  cleanup();done(ok,value)
 end,target,function()cleanup(true)end,true)
 widget=a.jobs.widget
 if widget and not closed then UI:scheduleIn(0.5,poll)else cleanup()end
 return result
end
return M
