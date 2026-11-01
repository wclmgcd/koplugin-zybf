-- CRengine's font manager and the device screen are process-wide. Keep the
-- underlying KOReader reader exactly as it was when this window was entered.
local M={}
local properties={'font.hinting.mode','font.kerning.mode',
    'font.fractional.positioning','font.face.base.weight',
    'crengine.render.dpi','crengine.render.scale.font.with.dpi',
    'font.antialiasing.mode','font.monospace.size.scale.percent','crengine.font.fallback.sizes.adjusted',
    'crengine.hyphenation.left.hyphen.min','crengine.hyphenation.right.hyphen.min','crengine.hyphenation.trust.soft.hyphens',
    'crengine.textlang.embedded.langs.enabled','crengine.textlang.hyphenation.enabled',
    'crengine.textlang.hyphenation.soft.hyphens.only','crengine.textlang.hyphenation.force.algorithmic'}
local stringProperties={'crengine.font.fallback.faces','crengine.hyphenation.directory',
    'crengine.textlang.main.lang','crengine.textlang.hyphenation.user.dict'}
local function call(object,name,...)
    if object and type(object[name])=='function'then
        local ok,value=pcall(object[name],object,...)
        if ok then return value end
    end
end
function M.capture(a)
    if a.renderContext then return end
    local screen=require('device').screen
    local host=a.host;local doc=host and host.document
    local c={rotation=call(screen,'getRotationMode'),document=doc,properties={},strings={}}
    if doc and doc._document and type(doc.setFontBaseWeight)=='function'then
        c.pointer=call(doc,'getXPointer');c.position=call(doc,'getCurrentPos')
        for _,name in ipairs(properties)do
            local value=tonumber(call(doc._document,'getStringProperty',name))
            if value and value==value and value~=math.huge and value~=-math.huge then c.properties[name]=value end
        end
        for _,name in ipairs(stringProperties)do
            local value=call(doc._document,'getStringProperty',name)
            if type(value)=='string'and value~=''then c.strings[name]=value end
        end
        local face=call(doc._document,'getStringProperty','font.face.default')
        if type(face)=='string'and face~=''then c.face=face end
        c.engine=call(doc,'engineInit')
    else c.document=nil end
    -- Do not initialize a second engine just to take a snapshot in FileManager.
    c.engine=c.engine or package.loaded['libs/libkoreader-cre']
    if c.engine and type(c.engine.getGammaIndex)=='function'then
        local ok,value=pcall(c.engine.getGammaIndex);if ok then c.gamma=value end
    end
    a.renderContext=c
end
function M.restore(a)
    local c=a.renderContext;if not c then return end
    a.renderContext=nil
    local logger=require('logger')
    local function restore(label,fn)
        local ok,err=pcall(fn)
        if not ok then logger.warn('ReadInk restoring host '..label..':',tostring(err))end
    end
    local screen=require('device').screen
    local rotated=false
    if c.rotation~=nil and call(screen,'getRotationMode')~=c.rotation then
        restore('rotation',function()screen:setRotationMode(c.rotation);rotated=true end)
    end
    if c.engine and c.gamma~=nil and type(c.engine.setGammaIndex)=='function'then
        restore('gamma',function()c.engine.setGammaIndex(c.gamma)end)
    end
    local host=a.host;local doc=c.document
    if doc and host and host.document==doc and not host.tearing_down and doc._document then
        restore('font properties',function()
            -- This public setter also restores the process-wide preferred
            -- font bias; restoring the raw face property alone would not.
            if c.face then doc:setFontFace(c.face)end
            for _,name in ipairs(stringProperties)do
                local value=c.strings[name]
                if value~=nil then doc._document:setStringProperty(name,value)end
            end
            for _,name in ipairs(properties)do
                local value=c.properties[name]
                if value~=nil then doc._document:setIntProperty(name,value)end
            end
            if doc.resetCallCache then doc:resetCallCache()end
            -- Restoring the global font manager can invalidate this reader's
            -- glyph/layout caches. Render before showing its surviving window.
            if doc.render then doc:render()end
            if (doc._view_mode=='scroll'or doc._view_mode==doc.SCROLL_VIEW_MODE)and c.position~=nil and doc.gotoPos then doc:gotoPos(c.position)
            elseif c.pointer and doc.gotoXPointer then doc:gotoXPointer(c.pointer)end
        end)
    end
    return rotated
end
return M
