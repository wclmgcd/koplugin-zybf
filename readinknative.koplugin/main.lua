local Plugin=require('ui/widget/container/widgetcontainer'):extend{name='readinknative',is_doc_only=false}
local startupChecked=false
function Plugin:init()
    self.ui.menu:registerToMainMenu(self)
    -- Only the Kindle file manager primes a recently used local chapter.
    -- This priming task performs no network or reading-time activity.
    if require('device'):isKindle()and not self.ui.document then
        self.primeTask=function()
            self.primeTask=nil
            if self.stopped or self.suspended then return end
            self.app=self.app or require('readinknative/app').new(self.path,self.ui)
            require('readinknative/chapterloader').prime(self.app)
        end
        require('ui/uimanager'):scheduleIn(0.3,self.primeTask)
    end
    -- A module can have separate FileManager and ReaderUI instances. Make one
    -- startup decision per process, after KOReader has installed its windows.
    if not startupChecked then
        startupChecked=true
        if require('readinknative/preferences').openOnStart()then
            local task;task=function()
                if self.startupTask~=task then return end
                self.startupTask=nil
                if self.stopped or self.suspended or not self.ui or self.ui.tearing_down
                    or not require('ui/uimanager'):isWidgetShown(self.ui)
                    or not require('readinknative/preferences').openOnStart()then return end
                self:open()
            end
            self.startupTask=task;require('ui/uimanager'):nextTick(task)
        end
    end
end
function Plugin:cancelStartup()
    if self.startupTask then require('ui/uimanager'):unschedule(self.startupTask);self.startupTask=nil end
end
function Plugin:open()
    self:cancelStartup()
    if self.primeTask then require('ui/uimanager'):unschedule(self.primeTask);self.primeTask=nil end
    if self.stopped or self.suspended or not self.ui or self.ui.tearing_down then return end
    if self.app and not self.app.closed then
        if require('ui/uimanager'):isWidgetShown(self.app.view)then self.app:raise()else self.app:show()end
        return
    end
    self.app=require('readinknative/app').new(self.path,self.ui)
    self.app:show()
end
function Plugin:addToMainMenu(items)
    items.readinknative={text='阅墨',sorting_hint='tools',callback=function()self:open()end}
end
function Plugin:onSuspend()self:cancelStartup();self.suspended=true;if self.primeTask then require('ui/uimanager'):unschedule(self.primeTask);self.primeTask=nil end;if self.app then self.app:suspend()end end
function Plugin:onResume()self.suspended=false;if self.app then if self.app.hasBeenShown then self.app:resume()else self.app.suspended=false end end end
function Plugin:onCloseWidget()self:cancelStartup();self.stopped=true;if self.primeTask then require('ui/uimanager'):unschedule(self.primeTask);self.primeTask=nil end;if self.app then self.app:close()end end
return Plugin
