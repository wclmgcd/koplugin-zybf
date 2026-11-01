-- Own only the plugin/host handoff. Do not replace KOReader quit/restart APIs.
local M={};local owners=setmetatable({},{__mode='k'})
local function shown(a)
 return a and not a.closed and a.hasBeenShown and require('ui/uimanager'):isWidgetShown(a.view)
end
local function painted(d)
 return d and type(d.x)=='number'and type(d.y)=='number'and type(d.w)=='number'and type(d.h)=='number'and d.w>0 and d.h>0
end
function M.attach(a)
 if not a.host or owners[a]then return end
 local UI=require('ui/uimanager');local host=a.host;owners[a]=true
 -- A native Close routed while the plugin is visible must first leave this
 -- plugin, rather than finalize FileManager and all plugins beneath it.
 if type(host.onClose)=='function'then
  local original=host.onClose
  local wrapper;wrapper=function(instance,...)
   if instance==host and shown(a)and not host.tearing_down then
    require('logger').info('ReadInk host close routed to plugin back:',a.mode)
    if a.view.inputCurrent and not a.view:inputCurrent()then a.view:refresh();return true end
    a:back();return true
   end
   return original(instance,...)
  end
  a.hostCloseOriginal=original;a.hostCloseWrapper=wrapper;host.onClose=wrapper
 end
 if not M.iconWrapper then
  local Icon=require('ui/widget/iconbutton');local original=Icon.onTapIconButton
  local wrapper=function(button,...)
   local owned=false;for app in pairs(owners)do if shown(app)or app.returningToHost then owned=true;break end end
   if owned and button.callback and button.allow_flash and not G_reader_settings:isFalse('flash_ui')
    and(not painted(button.dimen)or not painted(button.image and button.image.dimen))then
    -- The native feedback path dereferences image.dimen before the callback.
    -- Request the real layout; never execute or replay an unpainted action.
    require('logger').warn('ReadInk host icon tap skipped: geometry not painted')
    UI:setDirty('all','ui');return true
   end
   return original(button,...)
  end
  M.iconClass=Icon;M.iconOriginal=original;M.iconWrapper=wrapper;Icon.onTapIconButton=wrapper
 end
end
function M.leave(a)
 local UI=require('ui/uimanager');local host=a.host
 local exiting=a.exitProgress and UI:isWidgetShown(a.exitProgress)
 a.returningToHost=true
 local rotated=require('readinknative/rendercontext').restore(a)
 -- Remove only our window, then paint the actual surviving host before input
 -- can address its old image buttons. Never show a torn-down FileManager.
 UI:close(a.view)
 if not exiting and host and UI:isWidgetShown(host)and not host.tearing_down then UI:setDirty(host,rotated and'full'or'ui');UI:forceRePaint()end
 if host and host.onClose==a.hostCloseWrapper then host.onClose=a.hostCloseOriginal end
 a.hostCloseWrapper=nil;a.hostCloseOriginal=nil;a.returningToHost=nil;owners[a]=nil
 if not next(owners)and M.iconClass and M.iconClass.onTapIconButton==M.iconWrapper then
  M.iconClass.onTapIconButton=M.iconOriginal;M.iconClass=nil;M.iconOriginal=nil;M.iconWrapper=nil
 end
 require('logger').info(exiting and'ReadInk host released under exit overlay:'or'ReadInk returned to KOReader host:',host and UI:isWidgetShown(host)or false)
end
return M
