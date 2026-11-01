-- Separate storage from P3, WeReader and ReadInk 0.1/0.2.
local D=require('datastorage');local P={}
function P.settings(kind)
    assert(kind=='session'or kind=='format','UNKNOWN_SETTINGS_KIND')
    return D:getSettingsDir()..(kind=='format'and'/readink-native-reader-format.lua'or'/readink-native-session.lua')
end
function P.account(vid)
    local path=D:getDataDir()..'/readink-native/'..require('ffi/sha2').sha256(tostring(vid or 'guest')):sub(1,24)
    require('util').makePath(path)
    assert(require('libs/libkoreader-lfs').attributes(path,'mode')=='directory','CACHE_DIRECTORY_FAILED')
    return path
end
function P.cache(vid,name)return require('readinknative/cachepath').file(P.account(vid),name)end
return P
