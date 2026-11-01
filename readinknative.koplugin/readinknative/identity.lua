-- Native KOReader device adapter; the system/device portion is our own UA.
local P=require('readinknative/auth/profile')
local I={}
local function headerText(value,fallback)
    local text=type(value)=='string' and value or fallback
    return text:gsub('[%c()\\]',''):sub(1,80)
end
function I.current()
    local device=require('device')
    local platform=headerText(require('ffi').os,'Linux')
    local brand=device:isKindle() and 'Amazon' or 'KOReader'
    local model=headerText(device.model,'KOReader')
    return {version=2,brand=brand,model=model,platform=platform,
        ua='WeRead/'..P.uaVersion..' WRBrand/'..brand..' wr_eink ReadInk/'..require('readinknative/version')..' ('..platform..'; '..model..')'}
end
function I.same(a,b)
    return type(a)=='table' and type(b)=='table' and a.ua==b.ua and a.model==b.model
end
return I
