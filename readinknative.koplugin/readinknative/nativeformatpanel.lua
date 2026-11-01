-- The complete host KOReader ConfigDialog and CreOptions. Only their document,
-- shared-format events and UI/settings ownership are adapted to ReadInk.
local M={}
local F=require('readinknative/format')
local unpack=table.unpack or unpack
local dispose
local function copy(v)
    if type(v)~='table'then return v end
    local q={};for k,x in pairs(v)do q[k]=copy(x)end;return q
end
local function finite(v)return type(v)=='number'and v==v and v~=math.huge and v~=-math.huge end
local function live(o)
    local a=o.app
    return not o.closed and a.nativeFormatPanel==o and not a.closed and not a.suspended
        and a.mode=='reader'and a.document==o.document and a.document.doc
        and a.book==o.book and a.state==o.state
end
local function current(o)return o.state:format(o.book)end
local scalar={SetFontSize='size',SetLineSpace='line',SetFontBaseWeight='weight',
    SetPageTopMargin='margin_top',SetPageBottomMargin='margin_bottom',
    SetBlockRenderingMode='block_rendering_mode',SetRenderDPI='render_dpi',
    SetWordExpansion='word_expansion',SetCJKWidthScaling='cjk_width_scaling',
    SetFontGamma='font_gamma',SetFontHinting='font_hinting',SetFontKerning='font_kerning',
    SetStatusLine='status_line'}
local boolean={SyncPageTopBottomMargins='sync_t_b_page_margins',
    ToggleEmbeddedStyleSheet='embedded_css',ToggleEmbeddedFonts='embedded_fonts',
    ToggleImageScaling='smooth_scaling',ToggleNightmodeImages='nightmode_images'}
local special={ChangeSize=true,SetPageHorizMargins=true,SetPageTopAndBottomMargin=true,
    SetWordSpacing=true,SetVisiblePages=true,SetViewMode=true,SetRotationMode=true}
local function supported(event)return scalar[event]or boolean[event]or special[event]end
local function patchFor(o,event,arg)
    if scalar[event]and finite(arg)then return{[scalar[event]]=arg}end
    if boolean[event]and type(arg)=='boolean'then return{[boolean[event]]=arg and 1 or 0}end
    if event=='ChangeSize'and finite(arg)then return{size=current(o).size+arg}end
    if type(arg)=='table'and finite(arg[1])and finite(arg[2])then
        if event=='SetPageHorizMargins'then return{margin_left=arg[1],margin_right=arg[2]}
        elseif event=='SetPageTopAndBottomMargin'then return{margin_top=arg[1],margin_bottom=arg[2]}
        elseif event=='SetWordSpacing'then return{word_spacing={arg[1],arg[2]}}end
    end
    if event=='SetVisiblePages'and(arg==1 or arg==2)then return{visible_pages=arg}end
    if event=='SetViewMode'and(arg=='page'or arg=='scroll')then return{view_mode=arg=='scroll'and 1 or 0}end
end
local function synchronize(o,dialog)
    -- Older saved formats may not yet contain engine defaults. Resolve those
    -- for display only; opening a panel never changes the stored format.
    local f=F.resolveEngineDefaults(o.document.doc,current(o));local c=dialog.configurable
    for _,panel in ipairs(dialog.config_options)do for _,q in ipairs(panel.options)do
        c[q.name]=copy(f[q.name])
    end end
    c.font_size=f.size;c.line_spacing=f.line;c.font_base_weight=f.weight
    c.h_page_margins={f.margin_left or f.margin,f.margin_right or f.margin}
    c.t_page_margin=f.margin_top or f.vertical;c.b_page_margin=f.margin_bottom or f.vertical
    -- The native toggle keeps the requested column count while scroll mode
    -- disables it. Actual scroll rendering still uses F.visiblePages() == 1.
    c.visible_pages=f.visible_pages or(f.columns and o.document.w>o.document.h and 2 or 1)
    c.rotation_mode=f.rotation_mode or require('device').screen:getRotationMode()
    dialog.document=o.document.doc
end
local function finish(callback)if type(callback)=='function'then pcall(callback)end end
local function apply(o,event,arg,callback)
    local success,err=false,'NATIVE_FORMAT_STALE'
    if live(o)then
        local ok,result,problem
        if event=='SetRotationMode'and finite(arg)and arg>=0 and arg<=3 and arg%1==0 then
            ok,result,problem=pcall(o.app.setReaderRotation,o.app,arg)
        else
            local patch=patchFor(o,event,arg)
            if patch then ok,result,problem=pcall(o.app.changeFormat,o.app,patch)
            else ok,result,problem=true,false,'NATIVE_FORMAT_OPTION_UNSUPPORTED'end
        end
        success=ok and result==true;err=ok and problem or result
        if live(o)then synchronize(o,o.dialog)end
        if not ok and live(o)and o.app.message then o.app:message('排版未能应用，请重试。')end
    elseif not o.closed then dispose(o)end
    -- Native hide_on_apply callbacks must always be completed. The private UI
    -- facade suppresses repainting if a rotation/close invalidated the owner.
    finish(callback)
    return success,err
end
local function bridge(o)
    return{handleEvent=function(_,event)
        local name=event.handler or(event.name and'on'..event.name)
        local args=event.args or{}
        if name=='onConfigChange'then
            if live(o)then o.dialog.configurable[args[1]]=copy(args[2])end
            return true
        end
        return apply(o,name and name:sub(3)or'',unpack(args,1,args.n or #args))
    end}
end
local function dialogClass(o,Base)
    local Class=Base:extend{}
    function Class:update()
        if not live(o)then return end
        synchronize(o,self)
        return Base.update(self)
    end
    function Class:onShowConfigPanel(...)
        if live(o)then return Base.onShowConfigPanel(self,...)end
        return true
    end
    function Class:closeDialog()dispose(o);return true end
    function Class:onCloseWidget()
        dispose(o)
        if self.dialog_frame and Base.onCloseWidget then Base.onCloseWidget(self)end
    end
    return Class
end
dispose=function(o)
    if not o or o.closed then return end
    o.closed=true
    if o.app.nativeFormatPanel==o then
        o.app.nativeFormatPanel=nil
        if o.dialog then o.app.nativeFormatPanelIndex=o.dialog.panel_index end
    end
    if o.context then o.context:close()end
end
function M.close(app)if app then dispose(app.nativeFormatPanel)end;return true end
function M.open(app)
    if app.nativeFormatPanel and live(app.nativeFormatPanel)then return true end
    M.close(app)
    if app.closed or app.suspended or app.mode~='reader'or not app.book or not app.document or not app.document.doc then
        return false,'NATIVE_FORMAT_NO_DOCUMENT'
    end
    local o
    local previous={panel=app.panel,toolbar=app.toolbar,readerChrome=app.readerChrome}
    local ok,err=pcall(function()
        local R=require('readinknative/readerformat')
        assert(type(R.readNativeDefault)=='function'and type(R.saveNativeDefault)=='function'
            and type(F.visiblePages)=='function'and type(app.changeFormat)=='function'
            and type(app.setReaderRotation)=='function','NATIVE_FORMAT_UNAVAILABLE')
        o={app=app,document=app.document,state=app.state,book=app.book}
        app.nativeFormatPanel=o
        o.context=require('readinknative/nativeuicontext').new(o,R,function()return live(o)end,function()dispose(o)end)
        o.UI=o.context.UI;o.children=o.context.order
        local Base=o.context.require('ui/widget/configdialog')
        local options=o.context.require('ui/data/creoptions')
        for _,panel in ipairs(options)do for _,option in ipairs(panel.options)do
            assert(supported(option.event),'NATIVE_FORMAT_OPTIONS_UNAVAILABLE: '..tostring(option.event))
            local more=option.more_options_param
            if more then assert(supported(more.event or option.event),'NATIVE_FORMAT_OPTIONS_UNAVAILABLE')end
        end end
        o.bridge=bridge(o)
        o.dialog=dialogClass(o,Base):new{document=app.document.doc,ui=o.bridge,
            configurable={},config_options=options,is_always_active=true,covers_footer=true}
        if app.clearTextSelection then app:clearTextSelection()end
        app.panel=nil;app.toolbar=false;app.readerChrome=nil;app:draw()
        assert(live(o),'NATIVE_FORMAT_STALE')
        local index=tonumber(app.nativeFormatPanelIndex)or o.dialog.panel_index or 1
        o.dialog:onShowConfigPanel(math.max(1,math.min(#options,index)))
        o.UI:show(o.dialog)
    end)
    if not ok then
        dispose(o);app.panel=previous.panel;app.toolbar=previous.toolbar;app.readerChrome=previous.readerChrome
        return false,tostring(err)
    end
    return true
end
return M
