-- Session persistence using KOReader's settings service, authored for ReadInk.
local Wire=require('readinknative/auth/wire')
local S={};S.__index=S
local function clone(value)
    if type(value)~='table'then return value end
    local result={}
    for key,item in pairs(value)do result[key]=type(item)=='table' and clone(item) or item end
    return result
end
function S.new(provided)
    local path=require('readinknative/paths').settings('session')
    local store=require('luasettings'):open(path)
    local state=clone(provided or store:readSetting('session',{}))
    assert(type(state)=='table','SESSION_INVALID')
    -- Retire alpha41's optional web jar without changing native login tokens.
    state.webMP=nil
    for _,name in ipairs({'deviceId','installId'})do
        if not Wire.nonempty(state[name]) then state[name]=Wire.hex(16)end
    end
    local self=setmetatable({data=state,store=store,path=path},S)
    if not provided then self:save()end
    return self
end
function S.ready(data)
    local id=data.vid
    local validId=Wire.nonempty(id) or (type(id)=='number' and id>0 and id<math.huge)
    return validId and Wire.nonempty(data.accessToken)
end
function S:save()
    self.store:saveSetting('session',self.data)
    self.store:flush()
    -- FAT-backed Kindle volumes may not support Unix mode bits.
    pcall(function()
        local ffi=require('ffi')
        pcall(ffi.cdef,'int chmod(const char *path, unsigned int mode);')
        ffi.C.chmod(self.path,384);ffi.C.chmod(self.path..'.old',384)
    end)
end
function S:accept(account,identity,refresh)
    assert(type(account)=='table' and S.ready(account),'LOGIN_FAILED')
    if refresh then assert(tostring(account.vid)==tostring(self.data.vid),'LOGIN_REQUIRED')end
    local nextData={deviceId=self.data.deviceId,installId=self.data.installId,
        vid=account.vid,accessToken=account.accessToken,client=clone(identity)}
    nextData.refreshToken=Wire.nonempty(account.refreshToken) and account.refreshToken or (refresh and self.data.refreshToken or nil)
    local name=account.name or (type(account.user)=='table' and account.user.name)
    nextData.name=Wire.nonempty(name) and name or (refresh and self.data.name or nil)
    self.data=nextData
    return nextData
end
return S
