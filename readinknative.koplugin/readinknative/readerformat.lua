-- One installation-wide reading format. Account/book values are migration
-- inputs only; normal reads and writes use this settings file exclusively.
local F=require('readinknative/format')
local R={}
local keys=F.keys
local settings
local function store()
    if not settings then settings=require('luasettings'):open(require('readinknative/paths').settings('format'))end
    return settings
end
local function saved()
    local value=store():readSetting('format')
    return type(value)=='table'and value or nil
end
function R.read()
    -- Never return the stored table: callers edit a copy before saving it.
    local format=F.normalize(saved())
    if store():readSetting('font_schema')~=1 then format.face=require('readinknative/fontidentity').migrate(format.face)end
    return format
end
function R.save(value)
    local format=F.normalize(value)
    local s=store();s:saveSetting('schema',1);s:saveSetting('font_schema',1);s:saveSetting('format',format);s:flush()
    return F.normalize(format)
end
-- The native dialog's "Set as default" changes only its reset/default value.
-- It is namespaced inside the same plugin file and never changes copt_* or the
-- current shared format merely because a default button was pressed.
function R.readNativeDefault(name)
    local defaults=store():readSetting('native_defaults')
    if type(defaults)~='table'then return nil end
    local _,value=F.nativePatch(name,defaults[name])
    return value
end
function R.saveNativeDefault(name,value)
    local patch,normalized=F.nativePatch(name,value)
    assert(value==nil and F.isNativeName(name)or patch,'UNKNOWN_NATIVE_FORMAT_DEFAULT')
    local old=store():readSetting('native_defaults');local defaults={}
    for key,v in pairs(type(old)=='table'and old or{})do
        local p,n=F.nativePatch(key,v);if p then defaults[key]=n end
    end
    defaults[name]=normalized
    local s=store();s:saveSetting('schema',1);s:saveSetting('native_defaults',defaults);s:flush()
    return R.readNativeDefault(name)
end
function R.defaultFormat()
    local f=F.normalize(F.defaults);local patch={}
    local defaults=store():readSetting('native_defaults')
    for name,value in pairs(type(defaults)=='table'and defaults or{})do
        local p=F.nativePatch(name,value)
        for key,v in pairs(p or{})do patch[key]=v end
    end
    f=F.merge(f,patch)
    -- These are optional overrides. false is the explicit patch syntax for
    -- clearing one; a missing key would otherwise preserve the current value.
    f.face=false;f.visible_pages=f.visible_pages or false;f.rotation_mode=f.rotation_mode or false
    f.block_rendering_flags=false
    return f
end
function R.adoptEngineDefaults(value)
    local resolved=F.normalize(value);local old=saved()
    if not old then return R.save(resolved),true end
    local current=R.read();local changed=false
    for _,key in ipairs(F.engineKeys)do
        if old[key]==nil and resolved[key]~=nil then current[key]=resolved[key];changed=true end
    end
    if old.block_rendering_mode==nil and resolved.block_rendering_flags~=nil then
        current.block_rendering_flags=resolved.block_rendering_flags;changed=true
    end
    if changed then return R.save(current),true end
    return current,false
end
local function legacyFormat(value,font)
    local format=F.normalize(value,font)
    format.face=require('readinknative/fontidentity').migrate(format.face)
    return format
end
function R.init(legacy,vid)
    if saved()then
        local format=R.read()
        if store():readSetting('font_schema')~=1 then return R.save(format)end
        return format
    end
    legacy=legacy or{}
    local shared=G_reader_settings and G_reader_settings:readSetting('readink_native_global_format')
    if type(shared)=='table'then return R.save(legacyFormat(shared,legacy.font))end
    local guest=vid==nil or tostring(vid)=='guest'
    if type(legacy.globalFormat)=='table'then
        local format=legacyFormat(legacy.globalFormat,legacy.font)
        local defaults=F.normalize();local customized=false
        for _,key in ipairs(keys)do if not F.equal(format[key],defaults[key])then customized=true;break end end
        -- shelf11 could persist a guest's untouched defaults in its account
        -- progress. Those defaults must not block migration after login either.
        if not guest or customized then return R.save(format)end
        return format
    end

    local history=type(legacy.readingHistory)=='table'and legacy.readingHistory or{}
    local last=type(history[1])=='table'and history[1]or nil
    local formats=type(legacy.formats)=='table'and legacy.formats or{}
    local old=last and formats[tostring(last.bookId)]
    local value={}
    if type(old)=='table'then for k,v in pairs(old)do value[k]=v end end
    local p=require('readinknative/preferences').normalize(legacy.preferences)
    if value.indent==nil then value.indent=p.defaultIndent end
    if value.columns==nil then value.columns=p.defaultColumns end
    local format=legacyFormat(value,legacy.font)

    -- Startup/logout can create a guest before the real account is loaded.
    -- Empty guest defaults must not pre-empt that account's one-time migration.
    -- Existing guest choices, or any explicit save(), do belong to all books.
    local customized=false
    for _,key in ipairs(keys)do
        if type(old)=='table'and old[key]~=nil then customized=true;break end
    end
    if not guest or customized or format.size~=F.defaults.size
        or not p.defaultIndent or not p.defaultColumns then return R.save(format)end
    return F.normalize()
end
return R
