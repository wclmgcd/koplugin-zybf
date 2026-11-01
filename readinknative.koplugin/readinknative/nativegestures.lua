-- Use KOReader's original gesture definitions, manager, recognizer and
-- Dispatcher with a private reader/input context and one shared gestures.lua.
local M={}
local stores={}
local dynamicWarning=false
local closeOwner
local function copy(v,seen)
    if type(v)~='table'then return v end
    seen=seen or{};if seen[v]then return seen[v]end
    local t={};seen[v]=t;for k,x in pairs(v)do t[k]=copy(x,seen)end;return t
end
local function live(o)
    local a=o.app
    return not o.closed and a.nativeGestures==o and not a.closed and not a.suspended
        and a.mode==o.mode and a.book==o.book and a.document==o.document and a.state==o.state
end
local function findPlugin(app)
    local host=app.host and app.host.gestures
    local ok,loader=pcall(require,'pluginloader')
    if not host and ok and loader.loaded_plugins then host=loader.loaded_plugins.gestures end
    if host and host.path then return host.path,host end
    if ok then for _,list in ipairs{loader.enabled_plugins or{},loader.disabled_plugins or{}}do
        for _,p in ipairs(list)do if p.name=='gestures'and p.path then return p.path,p end end
    end end
    local path='plugins/gestures.koplugin';local file=io.open(path..'/main.lua','rb')
    if file then file:close();return path end
    return nil
end
local function refresh(o)
    o.reader.document=o.app.document and o.app.document.doc or o.placeholder
    o.registry.document=o.reader.document
    o.registry.disable_double_tap=G_reader_settings:nilOrTrue('disable_double_tap')
    if o.gestures then
        o.gestures.ignore_hold_corners=G_reader_settings:isTrue('ignore_hold_corners')
        o.gestures.multiswipes_enabled=G_reader_settings:isTrue('multiswipes_enabled')
    end
end
local function flush(o)
    if o.gestures then pcall(o.gestures.onFlushSettings,o.gestures)end
    if o.module and o.host and o.host.loadSettings and o.host.settings==o.module.settings then
        pcall(o.host.loadSettings,o.host)
    end
end
local function route(o,event)
    if not live(o)then closeOwner(o);return true end
    refresh(o)
    local name=event.handler or(event.name and'on'..event.name)
    local args=event.args or{}
    if name=='onHandledAsSwipe'then
        if o.app.view and o.app.view.onHandledAsSwipe then o.app.view:onHandledAsSwipe()end
        return true
    elseif name=='onDispatcherRegisterActions'or name=='onBatchedUpdate'or name=='onBatchedUpdateDone'then return true
    elseif name=='onRebuildMenu'then
        if o.menu then o.menu:updateItems()end;return true
    elseif name=='onShowGestureOverview'then o.gestures:onShowGestureOverview();return true
    elseif name=='onIgnoreTouchInput'then o.registry:onIgnoreTouchInput(args[1]);return true
    elseif name=='onIgnoreHoldCorners'then
        o.holdLease=nil;o.gestures:onIgnoreHoldCorners(args[1]);return true
    elseif name=='onIgnoreHoldCornersTime'then
        if G_reader_settings:hasNot('ignore_hold_corners')then
            o.holdLease={previous=G_reader_settings:readSetting('ignore_hold_corners'),owned=true}
        end
        o.gestures:onIgnoreHoldCornersTime(args[1]);return true
    elseif name=='onUpdateHoldPanRate'then
        if o.app.view and o.app.view.onUpdateHoldPanRate then o.app.view:onUpdateHoldPanRate()end
        return true
    end
    return require('readinknative/nativegestureactions').handle(o.app,event,o.context)
end
local function upvalue(fn,wanted)
    if not debug or type(debug.getupvalue)~='function'or type(fn)~='function'then return nil end
    for i=1,60 do local name,value=debug.getupvalue(fn,i);if not name then break end
        if name==wanted then return value end
    end
end
local function importActions(o)
    local ok,host=pcall(require,'dispatcher')
    local list=ok and upvalue(host.registerAction,'settingsList')
    local order=ok and upvalue(host.registerAction,'dispatcher_menu_order')
    if type(list)=='table'and type(order)=='table'then
        for _,name in ipairs(order)do if list[name]then o.dispatcher:registerAction(name,copy(list[name]))end end
        o.dynamicActionsAvailable=true
    else
        o.dynamicActionsAvailable=false
        if not dynamicWarning then
            dynamicWarning=true;require('logger').warn('ReadInk: native gesture dynamic action metadata unavailable; built-in actions retained')
        end
    end
end
closeOwner=function(o)
    if not o or o.closed then return end
    o.closed=true
    if o.app.nativeGestures==o then o.app.nativeGestures=nil end
    if o.app.nativeGestureSettings==o.menu then o.app.nativeGestureSettings=nil end
    if o.holdLease and G_reader_settings:readSetting('ignore_hold_corners')==o.holdLease.owned then
        if o.holdLease.previous==nil then G_reader_settings:delSetting('ignore_hold_corners')
        else G_reader_settings:saveSetting('ignore_hold_corners',o.holdLease.previous)end
        o.preferencesDirty=true
    end
    flush(o)
    if o.gestures and o.gestures.onCloseWidget then pcall(o.gestures.onCloseWidget,o.gestures)end
    if o.context then o.context:close()end
    if o.app.view and o.app.view.syncGestureSettings then o.app.view:syncGestureSettings()end
end
function M.ensure(app)
    if app.nativeGestures and live(app.nativeGestures)then refresh(app.nativeGestures);return app.nativeGestures end
    M.close(app)
    if app.closed or app.suspended then return false,'NATIVE_GESTURES_INACTIVE'end
    local o
    local ok,err=pcall(function()
        local path,host=findPlugin(app);assert(path,'NATIVE_GESTURES_UNAVAILABLE')
        o={app=app,path=path,host=host,mode=app.mode,book=app.book,document=app.document,state=app.state,specs={}}
        app.nativeGestures=o
        o.placeholder={info={has_pages=false},is_reflowable=true}
        o.reader={rolling=true,document=app.document and app.document.doc or o.placeholder,
            profiles={},bookinfo={expandString=function(_,text)return tostring(text or'')end}}
        o.context=require('readinknative/nativegesturecontext').new(o,function()return live(o)end,
            function()closeOwner(o)end,function(event)return route(o,event)end)
        local Input=o.context.require('ui/widget/container/inputcontainer')
        o.registry=Input:new{dimen=require('device').screen:getSize(),document=o.reader.document,
            menu={registerToMainMenu=function()end}}
        o.registry.handleEvent=function(_,event)return route(o,event)end
        o.registry.disable_double_tap=G_reader_settings:nilOrTrue('disable_double_tap')
        local Native=o.context:loadFile(path..'/main.lua','readink-native-gestures')
        assert(not Native.disabled and type(Native.init)=='function','NATIVE_GESTURES_UNAVAILABLE')
        o.module=Native
        local store=host and host.settings and host.default_settings and host or stores[path]
        if store then
            Native.settings=store.settings;Native.default_settings=store.default_settings;Native.rtl_applied=store.rtl_applied
        end
        local Class=Native:extend{}
        function Class:registerGesture(id,kind,zone,overrides,direction,distance)
            o.specs[id]={id=id,kind=kind,zone=copy(zone),direction=copy(direction),distance=distance}
            return Native.registerGesture(self,id,kind,zone,overrides,direction,distance)
        end
        o.dispatcher=o.context.require('dispatcher')
        o.gestures=Class:new{path=path,ui=o.registry}
        o.reader.gestures=o.gestures
        stores[path]={settings=Native.settings,default_settings=Native.default_settings,rtl_applied=Native.rtl_applied}
        importActions(o);refresh(o)
    end)
    if not ok then closeOwner(o);return false,tostring(err)end
    return o
end
local function contains(spec,g,pan,range)
    local p=pan and(g.start_pos or g.pos)or g.pos;if not p then return false end
    if type(range)=='function'then range=range()end
    if not range or not range:contains(p)then return false end
    if spec.direction and not spec.direction[g.direction]then return false end
    if spec.distance=='short'and(g.distance or 0)>require('device').screen:scaleBySize(300)then return false end
    return true
end
local function bound(o,id,g)
    if id=='multiswipe'then
        if not o.gestures.multiswipes_enabled then return false end
        id='multiswipe_'..o.gestures:safeMultiswipeName(g.multiswipe_directions or'')
    end
    if g.ges=='hold'and o.gestures.ignore_hold_corners then return false end
    return o.gestures.gestures[id]~=nil
end
function M.claims(app,g)
    if not g or app.mode~='reader'or not app.document then return false end
    local o=M.ensure(app);if not o then return false end
    for _,zone in ipairs(o.registry._ordered_touch_zones or{})do
        local spec=o.specs[zone.def.id]
        if spec then
            local same=spec.kind==g.ges
            local pan=(g.ges=='pan'or g.ges=='pan_release')and spec.kind=='swipe'and spec.id:match('^one_finger_swipe_')
            if(same or pan)and contains(spec,g,pan,zone.gs_range.range)and bound(o,spec.id,g)then return true end
        end
    end
    return false
end
function M.isTouchDisabled(app)
    local o=app.nativeGestures
    return(require('ui/uimanager')._input_gestures_disabled or(o and live(o)and o.context.UI._input_gestures_disabled))and true or false
end
function M.dispatch(app,g)
    if not g or app.mode~='reader'or not app.document or not app.book then return false end
    local o=M.ensure(app);if not o then return false end
    for _,widget in ipairs(o.context.order)do if not widget.toast then return true end end
    local ok,result
    if M.isTouchDisabled(app)then
        ok,result=pcall(o.registry._onGestureFiltered,o.registry,g)
        if not ok then closeOwner(o)end
        return true
    end
    ok,result=pcall(o.registry.onGesture,o.registry,g)
    if not ok then require('logger').warn('ReadInk native gesture failed:',result);closeOwner(o);return true end
    return result==true
end
function M.openSettings(app)
    M.close(app)
    local o,err=M.ensure(app);if not o then return false,err end
    local ok,problem=pcall(function()
        local items={};o.gestures:addToMainMenu(items)
        local menu=o.context.require('ui/widget/touchmenu'):new{
            width=require('device').screen:getWidth(),tab_item_table={{icon='appbar.settings',
                items.gesture_manager,items.gesture_overview,items.gesture_intervals}},
            stop_events_propagation=true,close_callback=function()M.closeSettings(app)end}
        o.menu=menu;app.nativeGestureSettings=menu
        local original=menu.onCloseWidget
        menu.onCloseWidget=function(self,...)
            if original then original(self,...)end
            closeOwner(o)
        end
        o.context.UI:show(menu)
    end)
    if not ok then closeOwner(o);return false,tostring(problem)end
    return true
end
function M.closeSettings(app)M.close(app);return true end
function M.close(app)if app then closeOwner(app.nativeGestures)end;return true end
function M.suspend(app)return M.close(app)end
function M.resize(app)M.close(app);return M.ensure(app)end
return M
