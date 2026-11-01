-- Reader preferences; panel/startup choices belong to the installation.
local P={}
-- The gesture binding table remains KOReader's own gesture_reader table.
-- This preference only chooses which input handler owns ReadInk's reader.
function P.gestureMode()
    local key=G_reader_settings and G_reader_settings:readSetting('readinknative_gesture_mode')
    return key=='readink'and'readink'or'koreader'
end
function P.setGestureMode(key)
    assert(key=='readink'or key=='koreader','UNKNOWN_GESTURE_MODE')
    assert(G_reader_settings,'SETTINGS_NOT_READY')
    G_reader_settings:saveSetting('readinknative_gesture_mode',key);G_reader_settings:flush()
end
function P.gestureModeLabel()
    return P.gestureMode()=='koreader'and'KOReader 手势'or'阅墨手势'
end
function P.formatPanel()
    local key=G_reader_settings and G_reader_settings:readSetting('readinknative_format_panel')
    return key=='koreader'and'koreader'or'readink'
end
function P.setFormatPanel(key)
    assert(key=='readink'or key=='koreader','UNKNOWN_FORMAT_PANEL')
    assert(G_reader_settings,'SETTINGS_NOT_READY')
    G_reader_settings:saveSetting('readinknative_format_panel',key);G_reader_settings:flush()
end
function P.formatPanelLabel()
    return P.formatPanel()=='koreader'and'KOReader 面板'or'阅墨面板'
end
-- Exit destination belongs to the installation, not the WeRead account.
function P.exitTarget()
    return G_reader_settings and G_reader_settings:readSetting('readinknative_exit_target')=='kindle'and'kindle'or'koreader'
end
function P.setExitTarget(target)
    assert(target=='koreader'or target=='kindle','UNKNOWN_EXIT_TARGET')
    assert(G_reader_settings,'SETTINGS_NOT_READY')
    G_reader_settings:saveSetting('readinknative_exit_target',target);G_reader_settings:flush()
end
function P.exitTargetLabel()
    return P.exitTarget()=='kindle'and'退出 KOReader，返回 Kindle 系统'or'返回 KOReader'
end
function P.exitButtonLabel()
    return P.exitTarget()=='kindle'and'退出到 Kindle'or'退出到 KOReader'
end
P.shelfDensities={{key='large',label='大封面',columns=3},{key='standard',label='标准',columns=4},{key='compact',label='紧凑',columns=5}}
function P.shelfDensity()
    local key=G_reader_settings and G_reader_settings:readSetting('readinknative_shelf_density')
    for _,row in ipairs(P.shelfDensities)do if row.key==key then return key end end
    return 'standard'
end
function P.setShelfDensity(key)
    local valid=false;for _,row in ipairs(P.shelfDensities)do if row.key==key then valid=true end end
    assert(valid,'UNKNOWN_SHELF_DENSITY');assert(G_reader_settings,'SETTINGS_NOT_READY')
    G_reader_settings:saveSetting('readinknative_shelf_density',key);G_reader_settings:flush()
end
function P.shelfDensityLabel()
    for _,row in ipairs(P.shelfDensities)do if row.key==P.shelfDensity()then return row.label..' · 每行 '..row.columns..' 本' end end
end
-- Startup belongs to this KOReader installation, independent of the active
-- WeRead account. Do not change KOReader's own start_with/lastfile settings.
function P.openOnStart()
    return G_reader_settings and G_reader_settings:readSetting('readinknative_open_on_start')==true or false
end
function P.setOpenOnStart(enabled)
    assert(G_reader_settings,'SETTINGS_NOT_READY')
    G_reader_settings:saveSetting('readinknative_open_on_start',enabled==true);G_reader_settings:flush()
end
function P.normalize(value)
    value=type(value)=='table' and value or {}
    return {pageTurnEffect=value.pageTurnEffect==true,showDeviceStatus=value.showDeviceStatus~=false,tapLeftNext=value.tapLeftNext==true,showTime=value.showTime==true,tapImages=value.tapImages==true,syncReading=value.syncReading~=false,
        defaultIndent=value.defaultIndent~=false,defaultColumns=value.defaultColumns~=false}
end
return P
