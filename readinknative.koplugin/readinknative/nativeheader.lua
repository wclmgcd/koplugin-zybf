-- Keep CRengine's original header alive when the native panel enables it.
-- The engine draws its title, page numbers, clock and battery itself.
local M={}
function M.refresh(document)
    local f=document and document.format
    if not(f and f.status_line==0 and f.view_mode~=1 and document.doc)then return end
    local device=require('device');local battery
    if device:hasBattery()then
        local power=device:getPowerDevice();local level=power:getCapacity()
        battery=power:isCharging()and -1 or level
        if device:hasAuxBattery()and power:isAuxBatteryConnected()and not power:isAuxCharging()then
            local aux=power:getAuxCapacity()or 0
            battery=math.floor(((level or 0)+aux)/2)
        end
        if battery~=nil then document.doc:setBatteryState(battery)end
    end
    local stamp=tostring(math.floor(os.time()/60))..':'..tostring(battery)
    if stamp~=document.nativeHeaderStamp then
        document.nativeHeaderStamp=stamp
        -- setBatteryState deliberately bypasses CRe's call-cache invalidation.
        -- Clear both layers so a stationary page gets the new clock/battery.
        if document.doc.resetBufferCache then document.doc:resetBufferCache()
        elseif document.doc.resetCallCache then document.doc:resetCallCache()end
        document:clearPageImages()
    end
end
return M
