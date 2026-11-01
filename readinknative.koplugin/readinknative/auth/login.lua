-- ReadInk implementation from official LoginService/WRLoginService and WX SDK
-- protocol evidence. Does not import runtimeconfig or any WeReader client code.
local Profile=require('readinknative/auth/profile')
local Wire=require('readinknative/auth/wire')
local Login={};Login.__index=Login
function Login.new(client,environment)
    environment=environment or {}
    return setmetatable({client=client,
        milliseconds=environment.milliseconds or function()return math.floor(require('socket').gettime()*1000)end,
        random=environment.random or Wire.random1000,
        sha=environment.sha or require('ffi/sha2').sha256},Login)
end
function Login:signed(fields)
    local body={}
    for key,value in pairs(fields)do body[key]=value end
    local stamp=math.floor(self.milliseconds())
    local number=self.random()
    assert(type(number)=='number' and number>=0 and number<1000 and number%1==0,'RANDOM_FAILED')
    body.deviceId=self.client.data.deviceId
    body.deviceName=self.client.identity.model
    body.trackId='';body.timestamp=stamp;body.random=number
    body.signature=self.sha(string.format('%.0f',stamp)..body.deviceId..tostring(number))
    return body
end
function Login:begin()
    local ticket=self.client:jsonAt(Profile.ticket,{nonceStr=Profile.nonce})
    assert(Wire.nonempty(ticket.signature) and ticket.timeStamp~=nil,'QR_FAILED')
    local qr=self.client:jsonAt(Profile.qr,{
        appid=Profile.appid,noncestr=Profile.nonce,timestamp=ticket.timeStamp,
        scope=Profile.scope,signature=ticket.signature,
    })
    assert(Wire.nonempty(qr.uuid) and type(qr.qrcode)=='table','QR_FAILED')
    local encoded=qr.qrcode.qrcodebase64
    assert(type(encoded)=='string' and #encoded<=2*1024*1024,'QR_FAILED')
    local image=require('mime').unb64(encoded)
    assert(type(image)=='string' and #image>0 and #image<=1024*1024,'QR_FAILED')
    return {uuid=qr.uuid,png=image,last=0,created=os.time()}
end
function Login:poll(pending)
    assert(type(pending)=='table' and Wire.nonempty(pending.uuid),'QR_PROTOCOL_ERROR')
    local query={f='json',uuid=pending.uuid}
    if pending.last and pending.last~=0 then query.last=pending.last end
    local answer=self.client:jsonAt(Profile.poll,query,nil,60)
    local status=tonumber(answer.wx_errcode)
    assert(status,'QR_PROTOCOL_ERROR')
    pending.last=status
    if status==402 then error('QR_EXPIRED')end
    if status==403 then error('QR_CANCELLED')end
    if status==404 or status==408 then return false end
    assert(status==405 and Wire.nonempty(answer.wx_code),'QR_PROTOCOL_ERROR')
    local account=self.client:jsonAt(Profile.login,nil,self:signed{
        code=answer.wx_code,isFromQrcode=1,isAutoLogout=0,deviceType=Profile.deviceType,
    })
    self.client.data=self.client.session:accept(account,self.client.identity,false)
    return true
end
function Login:refresh(path)
    local c=self.client
    assert(Wire.nonempty(c.data.refreshToken),'LOGIN_REQUIRED')
    assert(not c.refreshing,'LOGIN_REQUIRED')
    c.refreshing=true
    local ok,account=pcall(function()
        return c:jsonAt(Profile.login,nil,self:signed{
            refreshToken=c.data.refreshToken,wxToken=0,inBackground=c.background and 1 or 0,
            kickType=1,refCgi=path or '/login',
        })
    end)
    c.refreshing=false
    if not ok then error(account,0)end
    c.data=c.session:accept(account,c.identity,true)
end
return Login
