-- Read-only account information. Never buys, renews, redeems or changes settings.
local A={}
local function number(x,max)return type(x)=='number'and x==x and x>=0 and x<=(max or 1e12)and x or nil end
function A.balance(raw)
    assert(type(raw)=='table'and number(raw.balance),'ACCOUNT_SCHEMA_CHANGED')
    return {balance=raw.balance,giftBalance=number(raw.giftBalance),peerBalance=number(raw.peerBalance)}
end
function A.membership(raw)
    assert(type(raw)=='table'and number(raw.expiredTime)and(raw.expired==0 or raw.expired==1),'MEMBER_SCHEMA_CHANGED')
    local out={}
    for _,key in ipairs({'expiredTime','expired','permanent','isPaying','remainTime','payingRemainTime','timestamp'})do out[key]=number(raw[key])end
    return out
end
function A.fetch(client)
    local result={}
    for _,kind in ipairs({'balance','membership'})do
        local ok,value=pcall(function()
            if kind=='balance'then return A.balance(client:api('/pay/balance',nil,{pf='wechat_wx-2001-android-100-weread',zoneid='1',release=1,onlyLimitFree=0,noSnapshot=1}))end
            return A.membership(client:api('/pay/memberCardSummary',{pf='wechat_wx-2001-android-100-weread',snapshot=0}))
        end)
        if ok then result[kind]=value else result[kind..'Error']=require('readinknative/errors').code(value)end
    end
    return result
end
function A.refresh(app)
    if not app.client:ready()then return end
    local owner={state=app.state,vid=app.client.data.vid};app.accountRequest=owner
    app:remote('更新账户信息',A.fetch,function(result)
        if app.closed or app.accountRequest~=owner or app.state~=owner.state or app.client.data.vid~=owner.vid or app.mode~='accountDetails'then return end
        local info=app.state.accountInfo or{}
        for _,key in ipairs({'balance','membership'})do
            if result[key]then info[key]=result[key];info[key..'Updated']=os.time()end
            info[key..'Error']=result[key..'Error']
        end
        app.state.accountInfo=info;(app.state.flushAccount or app.state.flush)(app.state);app:draw()
    end)
end
function A.memberText(info)
    local m=info and info.membership
    if not m then return '未读取'end
    if m.permanent==1 then return '永久会员'end
    if m.expired==1 or(info.membershipUpdated and m.remainTime and os.time()>=info.membershipUpdated+m.remainTime)then return '已到期'end
    return(m.isPaying==1 and'付费会员 · 'or'体验卡 · ')..os.date('%Y-%m-%d',m.expiredTime)..' 到期'
end
return A
