-- Load KOReader's own widgets in a private environment. Their source and
-- controls stay unchanged; settings, popup ownership and scheduling are local.
local C={}
local host_require=require
local unpack=table.unpack or unpack
local function pack(...)return{n=select('#',...),...}end
local function copy(value,seen)
    if type(value)~='table'then return value end
    seen=seen or{};if seen[value]then return seen[value]end
    local out={};seen[value]=out
    for k,v in pairs(value)do out[k]=copy(v,seen)end
    return out
end
local function sourcePath(name)
    local relative=name:gsub('%.','/')
    for pattern in package.path:gmatch('[^;]+')do
        local path=pattern:gsub('%?',relative)
        local f=io.open(path,'rb')
        if f then f:close();return path end
    end
end
local required={['ui/widget/configdialog']=true,['ui/data/creoptions']=true,
    ['ui/data/optionsutil']=true,['ui/widget/spinwidget']=true,
    ['ui/widget/doublespinwidget']=true,['ui/widget/numberpickerwidget']=true,
    ['ui/widget/confirmbox']=true,['ui/widget/inputdialog']=true,
    ['ui/widget/infomessage']=true,['ui/widget/virtualkeyboard']=true,
    ['ui/widget/notification']=true}
function C.new(owner,settings,is_live,on_close)
    local c={owner=owner,widgets={},watched=setmetatable({},{__mode='k'}),order={},tasks={},modules={},loading={}}
    local hostUI=host_require('ui/uimanager')
    local hostSettings=G_reader_settings
    local UI,facade={},{}
    local preferences,deleted={},{}
    c.UI=UI;c.settings=facade
    function c:active()
        if self.closed then return false end
        if is_live()then return true end
        on_close();return false
    end
    local function read(name,default)
        if name:sub(1,5)=='copt_'then
            local value=settings.readNativeDefault(name:sub(6))
            if value==nil then return copy(default)end
            return copy(value)
        end
        if preferences[name]~=nil then return copy(preferences[name])end
        if deleted[name]then return copy(default)end
        if hostSettings then return copy(hostSettings:readSetting(name,default))end
        return copy(default)
    end
    function facade:readSetting(name,default)return read(name,default)end
    function facade:has(name)return read(name)~=nil end
    function facade:hasNot(name)return read(name)==nil end
    function facade:isTrue(name)return read(name)==true end
    function facade:isFalse(name)return read(name)==false end
    function facade:nilOrTrue(name)local v=read(name);return v==nil or v==true end
    function facade:nilOrFalse(name)local v=read(name);return v==nil or v==false end
    function facade:saveSetting(name,value)
        if c:active()then
            if name:sub(1,5)=='copt_'then settings.saveNativeDefault(name:sub(6),copy(value))
            else preferences[name]=copy(value);deleted[name]=value==nil or nil end
        end
        return self
    end
    -- Keyboard/UI choices work within this context, but their temporary
    -- overlay is discarded on close and never writes host settings.
    function facade:delSetting(name)return self:saveSetting(name,nil)end
    function facade:flush()return self end
    function facade:makeTrue(name)return self:saveSetting(name,true)end
    function facade:makeFalse(name)return self:saveSetting(name,false)end
    function facade:flipNilOrTrue(name)
        if self:nilOrTrue(name)then return self:saveSetting(name,false)end
        return self:delSetting(name)
    end
    function facade:flipNilOrFalse(name)
        if self:nilOrFalse(name)then return self:saveSetting(name,true)end
        return self:delSetting(name)
    end
    local function forget(widget)
        c.widgets[widget]=nil
        for i=#c.order,1,-1 do if c.order[i]==widget then table.remove(c.order,i);break end end
    end
    local function watch(widget)
        if c.widgets[widget]then return end
        c.widgets[widget]=true;c.order[#c.order+1]=widget
        widget._readink_native_closed=nil
        -- Native QuickMenu can close and reopen the same widget after every
        -- action. Install lifecycle guards once instead of nesting wrappers.
        if c.watched[widget]then return end
        c.watched[widget]=true
        local original=widget.onCloseWidget
        widget.onCloseWidget=function(self,...)
            self._readink_native_closed=true;forget(self)
            if original then return original(self,...)end
        end
        -- Native callbacks may retain their parent after closing. Keep their
        -- original implementation, but prevent rebuilding closed widgets.
        for _,name in ipairs{'update','onShow','onShowKeyboard'}do
            local method=widget[name]
            if type(method)=='function'then widget[name]=function(self,...)
                if self._readink_native_closed or not c:active()then return end
                return method(self,...)
            end end
        end
    end
    function UI:show(widget,...)
        if not c:active()then return end
        watch(widget);return hostUI:show(widget,...)
    end
    function UI:close(widget,...)
        if not c.widgets[widget]then return end
        widget._readink_native_closed=true;forget(widget)
        return hostUI:close(widget,...)
    end
    local function schedule(method,when,callback,...)
        if not c:active()then return end
        local args=pack(...);local task
        task=function()
            c.tasks[task]=nil
            if c:active()then return callback(unpack(args,1,args.n))end
        end
        c.tasks[task]=callback
        if when~=nil then return hostUI[method](hostUI,when,task)end
        return hostUI[method](hostUI,task)
    end
    function UI:tickAfterNext(fn,...)return schedule('tickAfterNext',nil,fn,...)end
    function UI:nextTick(fn,...)return schedule('nextTick',nil,fn,...)end
    function UI:scheduleIn(delay,fn,...)return schedule('scheduleIn',delay,fn,...)end
    function UI:schedule(when,fn,...)return schedule('schedule',when,fn,...)end
    function UI:unschedule(fn)
        for task,original in pairs(c.tasks)do if original==fn or task==fn then
            hostUI:unschedule(task);c.tasks[task]=nil
        end end
    end
    function UI:setDirty(widget,...)
        if c:active()and not(type(widget)=='table'and widget._readink_native_closed)then
            return hostUI:setDirty(widget,...)
        end
    end
    setmetatable(UI,{__index=function(_,name)
        local value=hostUI[name]
        if type(value)~='function'then return value end
        return function(_,...)if c:active()then return value(hostUI,...)end end
    end})
    function c:close()
        if self.closed then return end
        self.closed=true
        preferences={};deleted={}
        for task in pairs(self.tasks)do pcall(hostUI.unschedule,hostUI,task)end
        self.tasks={}
        local widgets={};for i,w in ipairs(self.order)do widgets[i]=w end
        for i=#widgets,1,-1 do pcall(UI.close,UI,widgets[i])end
        if #widgets>0 then hostUI:setDirty('all','partial')end
    end
    local env=setmetatable({G_reader_settings=facade},{__index=_G})
    env._G=env
    c.env=env
    local function privateRequire(name)
        if name=='ui/uimanager'then return UI end
        if c.modules[name]~=nil then return c.modules[name]end
        local private=required[name]or name:sub(1,10)=='ui/widget/'
        local path=private and sourcePath(name)
        if not path then
            if required[name]then error('NATIVE_FORMAT_SOURCE_UNAVAILABLE: '..name,0)end
            return host_require(name)
        end
        if c.loading[name]then error('NATIVE_FORMAT_MODULE_CYCLE: '..name,0)end
        c.loading[name]=true
        local chunk,err
        if setfenv then
            chunk,err=loadfile(path)
            if chunk then setfenv(chunk,env)end
        else chunk,err=loadfile(path,'t',env)end
        if not chunk then c.loading[name]=nil;error(err,0)end
        local ok,result=pcall(chunk)
        c.loading[name]=nil
        if not ok then error(result,0)end
        if result==nil then result=true end
        c.modules[name]=result
        return result
    end
    env.require=privateRequire;c.require=privateRequire
    return c
end
return C
