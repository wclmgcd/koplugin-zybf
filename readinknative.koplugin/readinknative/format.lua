-- Reading options mapped onto CRengine. Values are logical KOReader units.
-- Missing advanced options are inherited once from setupDefaultView(), rather
-- than silently replacing an older installation's cr3.ini settings on upgrade.
local F={defaults={size=26,line=135,margin=24,vertical=16,weight=0,indent=true,columns=true,
    margin_left=24,margin_right=24,margin_top=16,margin_bottom=16,
    view_mode=0,sync_t_b_page_margins=0,status_line=1,
    block_rendering_mode=3,render_dpi=96,word_spacing={95,75},word_expansion=0,cjk_width_scaling=100,
    font_gamma=15,font_hinting=2,font_kerning=3,embedded_css=1,embedded_fonts=1,smooth_scaling=0,nightmode_images=1}}
F.keys={'size','line','margin','vertical','weight','indent','columns','face',
    'margin_left','margin_right','margin_top','margin_bottom','visible_pages','rotation_mode',
    'view_mode','sync_t_b_page_margins','status_line','block_rendering_mode','block_rendering_flags','render_dpi',
    'word_spacing','word_expansion','cjk_width_scaling','font_gamma','font_hinting','font_kerning',
    'embedded_css','embedded_fonts','smooth_scaling','nightmode_images'}
F.engineKeys={'block_rendering_mode','render_dpi','word_spacing','word_expansion','cjk_width_scaling',
    'font_gamma','font_hinting','font_kerning','embedded_css','embedded_fonts','smooth_scaling','nightmode_images'}
-- ReaderTypeset:setBlockRenderingMode(): these are flags, not the menu index.
F.blockRenderingFlags={0x00000000,0x03030031,0x03375131,0x7FFFFFFF}
-- Legacy symmetric controls are aliases, not additional rendering properties.
local layoutKeys={}
for _,key in ipairs(F.keys)do if key~='margin'and key~='vertical'then layoutKeys[#layoutKeys+1]=key end end
local function finite(v)
    v=tonumber(v)
    if v and v==v and v~=math.huge and v~=-math.huge then return v end
end
local function bounded(v,default,lo,hi,step)
    v=finite(v)or default
    v=math.max(lo,math.min(hi,v))
    return math.floor(v/(step or 1)+0.5)*(step or 1)
end
local function optional(v,lo,hi,step)
    if v==nil or v==false then return nil end
    v=finite(v);if not v then return nil end
    return bounded(v,lo,lo,hi,step)
end
local function switch(v,default)
    if v==nil then return default end
    if v==true then return 1 elseif v==false then return 0 end
    return bounded(v,default or 0,0,1)
end
function F.normalize(value,legacy)
    value=type(value)=='table' and value or {}
    local margin=bounded(value.margin,24,0,140)
    local vertical=bounded(value.vertical,16,0,140)
    local spacing=type(value.word_spacing)=='table'and value.word_spacing
    return {size=bounded(value.size,finite(legacy)or 26,12,255,0.5),line=bounded(value.line,135,50,220),
        margin=margin,vertical=vertical,
        margin_left=bounded(value.margin_left,margin,0,140),margin_right=bounded(value.margin_right,margin,0,140),
        margin_top=bounded(value.margin_top,vertical,0,140),margin_bottom=bounded(value.margin_bottom,vertical,0,140),
        weight=bounded(value.weight,0,-3,5.5,0.25),indent=value.indent~=false,columns=value.columns~=false,
        face=type(value.face)=='string' and value.face~='' and value.face or nil,
        visible_pages=optional(value.visible_pages,1,2),rotation_mode=optional(value.rotation_mode,0,3),
        view_mode=bounded(value.view_mode,0,0,1),sync_t_b_page_margins=switch(value.sync_t_b_page_margins,0),
        status_line=switch(value.status_line,1),block_rendering_mode=optional(value.block_rendering_mode,0,3),
        block_rendering_flags=optional(value.block_rendering_flags,0,0x7FFFFFFF),render_dpi=optional(value.render_dpi,0,300),
        word_spacing=spacing and{bounded(spacing[1],95,10,500),bounded(spacing[2],75,25,100)}or nil,
        word_expansion=optional(value.word_expansion,0,20),cjk_width_scaling=optional(value.cjk_width_scaling,100,150),
        font_gamma=optional(value.font_gamma,0,56),font_hinting=optional(value.font_hinting,0,2),font_kerning=optional(value.font_kerning,0,3),
        embedded_css=switch(value.embedded_css),embedded_fonts=switch(value.embedded_fonts),
        smooth_scaling=switch(value.smooth_scaling),nightmode_images=switch(value.nightmode_images)}
end
-- Patches carry only the controls actually edited. A symmetric margin edit
-- owns its two sides; font/size edits must leave all four sides untouched.
function F.merge(current,changes,legacy)
    local value=F.normalize(current,legacy)
    changes=type(changes)=='table'and changes or{}
    if changes.margin~=nil then
        value.margin_left=changes.margin;value.margin_right=changes.margin
    end
    if changes.vertical~=nil then
        value.margin_top=changes.vertical;value.margin_bottom=changes.vertical
    end
    -- The old switch means landscape-only columns. An explicit native choice
    -- is orientation-independent until the old switch is edited again.
    if changes.columns~=nil then value.visible_pages=nil end
    if changes.block_rendering_mode~=nil then value.block_rendering_flags=nil end
    for k,v in pairs(changes)do value[k]=v end
    value=F.normalize(value,legacy)
    local top,bottom=changes.margin_top~=nil,changes.margin_bottom~=nil
    if top and bottom and value.margin_top~=value.margin_bottom then
        value.sync_t_b_page_margins=0
    elseif value.sync_t_b_page_margins==1 then
        if top and not bottom then value.margin_bottom=value.margin_top
        elseif bottom and not top then value.margin_top=value.margin_bottom
        elseif changes.sync_t_b_page_margins~=nil and value.margin_top~=value.margin_bottom then
            local mean=math.floor((value.margin_top+value.margin_bottom)/2+0.5)
            value.margin_top=mean;value.margin_bottom=mean
        end
    end
    -- Keep the simple controls current when an independent edit becomes
    -- symmetric, without inventing a symmetric value for unequal margins.
    if changes.margin==nil and(changes.margin_left~=nil or changes.margin_right~=nil)
        and value.margin_left==value.margin_right then value.margin=value.margin_left end
    if changes.vertical==nil and(changes.margin_top~=nil or changes.margin_bottom~=nil or changes.sync_t_b_page_margins~=nil)
        and value.margin_top==value.margin_bottom then value.vertical=value.margin_top end
    return value
end
function F.visiblePages(value,w,h)
    local f=F.normalize(value)
    if f.view_mode==1 then return 1 end
    return f.visible_pages or(f.columns and w>h and 2 or 1)
end
function F.blockFlags(value)
    return value.block_rendering_flags or F.blockRenderingFlags[(value.block_rendering_mode or F.defaults.block_rendering_mode)+1]
end
local engineProps={
    render_dpi='crengine.render.dpi',word_expansion='crengine.style.max.added.letter.spacing.percent',
    cjk_width_scaling='crengine.style.cjk.width.scale.percent',font_hinting='font.hinting.mode',font_kerning='font.kerning.mode',
    embedded_css='crengine.doc.embedded.styles.enabled',embedded_fonts='crengine.doc.embedded.fonts.enabled',
}
function F.resolveEngineDefaults(doc,value)
    local f=F.normalize(value)
    local function prop(name)
        -- getIntProperty in older bindings has no defined result for a missing
        -- property. getStringProperty returns an empty string in that case.
        local raw=doc and doc._document
        if raw and type(raw.getStringProperty)=='function'then
            local ok,v=pcall(raw.getStringProperty,raw,name)
            if ok then return finite(v)end
        end
    end
    for key,name in pairs(engineProps)do if f[key]==nil then f[key]=prop(name)or F.defaults[key]end end
    if f.block_rendering_mode==nil then
        local flags=prop('crengine.render.block.rendering.flags')
        for i,known in ipairs(F.blockRenderingFlags)do if flags==known then f.block_rendering_mode=i-1;break end end
        if f.block_rendering_mode==nil then
            f.block_rendering_mode=F.defaults.block_rendering_mode
            -- Keep nonstandard older flags until the user explicitly selects
            -- a native rendering mode; never rewrite them merely to show UI.
            f.block_rendering_flags=flags
        end
    end
    if f.word_spacing==nil then
        f.word_spacing={prop('crengine.style.space.width.scale.percent')or F.defaults.word_spacing[1],
            prop('crengine.style.space.condensing.percent')or F.defaults.word_spacing[2]}
    end
    if f.font_gamma==nil then
        local ok,engine=pcall(function()return doc:engineInit()end)
        local good,index
        if ok and engine and type(engine.getGammaIndex)=='function'then good,index=pcall(engine.getGammaIndex)end
        f.font_gamma=good and finite(index)or F.defaults.font_gamma
    end
    if f.smooth_scaling==nil then f.smooth_scaling=doc and doc._smooth_scaling==true and 1 or 0 end
    if f.nightmode_images==nil then f.nightmode_images=doc and doc._nightmode_images==false and 0 or 1 end
    return F.normalize(f)
end
function F.equal(a,b)
    if type(a)~=type(b)then return false end
    if type(a)~='table'then return a==b end
    for k,v in pairs(a)do if not F.equal(v,b[k])then return false end end
    for k in pairs(b)do if a[k]==nil then return false end end
    return true
end
local nativeFields={font_size='size',line_spacing='line',font_base_weight='weight',
    t_page_margin='margin_top',b_page_margin='margin_bottom'}
for _,key in ipairs{'rotation_mode','visible_pages','sync_t_b_page_margins','view_mode','block_rendering_mode','render_dpi',
    'word_spacing','word_expansion','cjk_width_scaling','font_gamma','font_hinting','font_kerning','status_line',
    'embedded_css','embedded_fonts','smooth_scaling','nightmode_images'}do nativeFields[key]=key end
function F.isNativeName(name)return name=='h_page_margins'or nativeFields[name]~=nil end
function F.nativePatch(name,value)
    if name=='h_page_margins'then
        if type(value)~='table'or not finite(value[1])or not finite(value[2])then return nil end
        local f=F.normalize{margin_left=value[1],margin_right=value[2]}
        return{margin_left=f.margin_left,margin_right=f.margin_right},{f.margin_left,f.margin_right}
    end
    local key=nativeFields[name]
    if not key then return nil end
    if name=='word_spacing'then
        if type(value)~='table'or not finite(value[1])or not finite(value[2])then return nil end
    elseif not finite(value)then return nil end
    local f=F.normalize{[key]=value}
    return{[key]=f[key]},f[key]
end
-- One canonical signature for foreground, workers, page counts and reuse.
-- Length-prefix values so a font family containing separators stays distinct.
function F.signature(value,legacy)
    local f=F.normalize(value,legacy);local parts={'readink-format-v3'}
    for _,key in ipairs(layoutKeys)do
        local v=f[key]
        local kind=type(v)
        local text=kind=='table'and table.concat(v,',')or kind=='number'and string.format('%.12g',v)or tostring(v)
        parts[#parts+1]=key..'='..kind:sub(1,1)..#text..':'..text
    end
    return table.concat(parts,'|')
end
return F
