-- Extend the native widget sandbox for the original Gestures/Dispatcher code.
-- No host module, input class or global Lua environment is replaced.
local M={}
local hostRequire=require
local function copy(v,seen)
    if type(v)~='table'then return v end
    seen=seen or{};if seen[v]then return seen[v]end
    local t={};seen[v]=t;for k,x in pairs(v)do t[k]=copy(x,seen)end;return t
end
function M.source(name)
    local relative=name:gsub('%.','/')
    for pattern in package.path:gmatch('[^;]+')do
        local path=pattern:gsub('%?',relative)
        local f=io.open(path,'rb');if f then f:close();return path end
    end
end
local sharedKeys={multiswipes_enabled=true,ignore_hold_corners=true,gestures_migrated=true,
    hold_pan_rate=true,disable_double_tap=true,page_turns_swipe_always_active=true,
    night_mode=true,input_ignore_gsensor=true,input_lock_gsensor=true,
    input_invert_page_turn_keys=true,input_invert_left_page_turn_keys=true,
    input_invert_right_page_turn_keys=true,input_no_key_repeat=true,
    full_refresh_count=true,night_full_refresh_count=true}
local function shared(key)return sharedKeys[key]or key:match('^ges_')or key:match('^gesture_')end
function M.new(owner,isLive,onClose,dispatch)
    local c=hostRequire('readinknative/nativeuicontext').new(owner,
        hostRequire('readinknative/readerformat'),isLive,onClose)
    local baseRequire,baseSettings,baseClose=c.require,c.settings,c.close
    local hostSettings=G_reader_settings
    local cleanup={}
    local settings={}
    function settings:readSetting(key,default)
        if shared(key)then return copy(hostSettings:readSetting(key,default))end
        return baseSettings:readSetting(key,default)
    end
    function settings:saveSetting(key,value)
        if not c:active()then return self end
        if shared(key)then
            if value==nil then hostSettings:delSetting(key)else hostSettings:saveSetting(key,copy(value))end
            owner.preferencesDirty=true
        else baseSettings:saveSetting(key,value)end
        return self
    end
    function settings:delSetting(key)return self:saveSetting(key,nil)end
    function settings:has(key)return self:readSetting(key)~=nil end
    function settings:hasNot(key)return self:readSetting(key)==nil end
    function settings:isTrue(key)return self:readSetting(key)==true end
    function settings:isFalse(key)return self:readSetting(key)==false end
    function settings:nilOrTrue(key)local v=self:readSetting(key);return v==nil or v==true end
    function settings:nilOrFalse(key)local v=self:readSetting(key);return v==nil or v==false end
    function settings:makeTrue(key)return self:saveSetting(key,true)end
    function settings:makeFalse(key)return self:saveSetting(key,false)end
    function settings:flipNilOrTrue(key)if self:nilOrTrue(key)then return self:makeFalse(key)end;return self:delSetting(key)end
    function settings:flipNilOrFalse(key)if self:nilOrFalse(key)then return self:makeTrue(key)end;return self:delSetting(key)end
    function settings:toggle(key)return self:saveSetting(key,not self:readSetting(key))end
    function settings:flush()if owner.preferencesDirty and hostSettings.flush then hostSettings:flush();owner.preferencesDirty=nil end end
    c.settings=settings;c.env.G_reader_settings=settings
    function c.onClose(callback)cleanup[#cleanup+1]=callback end
    function c:loadFile(path,key)
        if key and self.modules[key]then return self.modules[key]end
        if not path then error('NATIVE_GESTURES_SOURCE_UNAVAILABLE: '..tostring(key),0)end
        local chunk,err
        if setfenv then chunk,err=loadfile(path);if chunk then setfenv(chunk,self.env)end
        else chunk,err=loadfile(path,'t',self.env)end
        if not chunk then error(err,0)end
        local value=chunk();if key then self.modules[key]=value end;return value
    end
    local extras={dispatcher=true,['ui/widget/container/inputcontainer']=true,
        ['device/devicelistener']=true,['ui/network/networklistener']=true}
    c.require=function(name)
        if name=='apps/reader/readerui'then return{instance=owner.reader}end
        if name=='migration'then return c:loadFile(owner.path..'/migration.lua',name)end
        if extras[name]then return c:loadFile(M.source(name),name)end
        return baseRequire(name)
    end
    c.env.require=c.require
    local UI=c.UI
    UI.silent_mode=false;UI._input_gestures_disabled=false
    function UI:sendEvent(event)if c:active()then return dispatch(event)end;return true end
    function UI:broadcastEvent(event)if c:active()then return dispatch(event)end;return true end
    -- Dispatcher and native menus may terminate their own context mid-call.
    -- These flags must never leave the host UI in a modified global state.
    function UI:setSilentMode(value)self.silent_mode=value==true end
    function UI:isInSilentMode()return self.silent_mode or false end
    function UI:setSuspendRepaints(value)self._readink_suspend_repaints=value or nil end
    function UI:getSuspendRepaints()return self._readink_suspend_repaints end
    function UI:setIgnoreTouchInput(value)
        local Input=c.require('ui/widget/container/inputcontainer')
        return Input:setIgnoreTouchInput(value)
    end
    local guarded=setmetatable({},{__mode='k'})
    local callbacks={callback=true,hold_callback=true,ok_callback=true,cancel_callback=true,
        extra_callback=true,option_callback=true}
    local descriptorTables={tab_item_table=true,item_table=true,buttons=true,sub_item_table=true}
    local guardTree
    guardTree=function(value,widget,seen)
        if type(value)~='table'then return end
        seen=seen or{};if seen[value]then return end;seen[value]=true
        for key,v in pairs(value)do
            if type(v)=='function'and(callbacks[key]or key=='sub_item_table_func')and not guarded[v]then
                local original=v;local factory=key=='sub_item_table_func'
                local wrapped=function(...)
                    if not c:active()then return factory and{}or nil end
                    if factory then
                        local items=original(...);guardTree(items,widget);return items
                    end
                    return original(...)
                end
                guarded[wrapped]=true;value[key]=wrapped
            elseif type(v)=='table'and(type(key)=='number'or descriptorTables[key])then
                guardTree(v,widget,seen)
            end
        end
    end
    local show,close=UI.show,UI.close
    function UI:show(widget,...)
        if not c:active()then return end
        -- Gesture callbacks edit the shared settings table directly. Guard
        -- original UI callbacks too, not just settings facade writes/events.
        guardTree(widget,widget)
        if self._input_gestures_disabled then
            self:setIgnoreTouchInput(false)
            widget._readink_restore_touch=true
        end
        return show(self,widget,...)
    end
    function UI:close(widget,...)
        local restore=widget and widget._readink_restore_touch
        local result=close(self,widget,...)
        if restore and c:active()then widget._readink_restore_touch=nil;self:setIgnoreTouchInput(true)end
        return result
    end
    function c:close()
        if self.closed then return end
        -- Cleanup is deliberately not guarded by active(): it must run after
        -- a book change/suspend, when scheduled native callbacks are cancelled.
        for i=#cleanup,1,-1 do pcall(cleanup[i])end
        cleanup={};settings:flush()
        UI.silent_mode=false;UI._readink_suspend_repaints=nil
        return baseClose(self)
    end
    return c
end
return M
