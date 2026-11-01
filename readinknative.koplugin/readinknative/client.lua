-- ReadInk transport/session core, reused from our independently authored 0.2 auth.
-- No previous reader, runtime configuration, or business facade is loaded.
local Wire=require('readinknative/auth/wire')
local Session=require('readinknative/auth/session')
local Identity=require('readinknative/identity')
local Profile=require('readinknative/auth/profile')
local C={};C.__index=C
C.hex=Wire.hex;C.encode=Wire.escape;C.query=Wire.query
function C:new(state)
    local session=Session.new(state)
    local self=setmetatable({session=session,store=session.store,data=session.data,identity=Identity.current()},C)
    self.auth=require('readinknative/auth/login').new(self)
    return self
end
function C:commit()self.session.data=self.data;self.session:save()end
function C:ready()return Session.ready(self.data)end
function C:imageArchive(book,chapter)
    local url=require('readinknative/protocol').archiveUrl(book.bookId,chapter.chapterUid,chapter.tar)
    assert(self:ready(),'LOGIN_REQUIRED')
    assert(require('readinknative/permission').mode(book,chapter,self.data.vid)=='full','READING_PERMISSION_REQUIRED')
    -- The authorized chapter request refreshed this session before image workers
    -- were forked. Never race refresh/persistence from parallel image children.
    local reply=require('readinknative/auth/transport').send{url=url,imageArchive=true,bookId=book.bookId,chapterUid=chapter.chapterUid,
        authenticated=true,timeout=20,limit=8*1024*1024,headers={['User-Agent']=Identity.current().ua,vid=tostring(self.data.vid),accessToken=self.data.accessToken,
            appver=Profile.appver,basever=Profile.basever,channelId=Profile.channelId,['Accept-Encoding']='identity'}}
    assert(reply.status==200,'IMAGE_ARCHIVE_FETCH_FAILED');return reply.body,'.tar'
end
function C:beginLogin()return self.auth:begin()end
function C:pollLogin(pending)return self.auth:poll(pending)end
function C:refresh(path)
    self.session.data=self.data
    return self.auth:refresh(path)
end
function C:request(url,body,authenticated,timeout,repeated)
    require('readinknative/protocol').checkRequest(url,authenticated)
    self.identity=Identity.current()
    if authenticated then
        assert(self:ready(),'LOGIN_REQUIRED')
        if not self.refreshing and not Identity.same(self.data.client,self.identity)then
            self:refresh(url:match('^https://[^/]+([^?]+)'))
        end
    end
    local headers={['User-Agent']=self.identity.ua,Accept='application/json',['Accept-Encoding']='identity',
        appver=Profile.appver,basever=Profile.basever,channelId=Profile.channelId}
    if authenticated then headers.vid=tostring(self.data.vid);headers.accessToken=self.data.accessToken end
    local path=url:match('^https://[^/]+([^?]+)')
    local tracked=body~=nil and self.write_path==path
    if tracked then self.write_state='unsent'end
    local reply=require('readinknative/auth/transport').send{
        url=url,body=body,headers=headers,authenticated=authenticated,timeout=timeout,
        onSent=tracked and function()self.write_state='unknown'end or nil,
    }
    if tracked and reply.status>=400 and reply.status<500 then self.write_state='rejected'end
    if reply.status==401 and authenticated and not self.refreshing and not repeated then
        self:refresh(path)
        return self:request(url,body,authenticated,timeout,true)
    end
    if reply.status==499 then
        local ok,value=pcall(require('rapidjson').decode,reply.body)
        if ok and type(value)=='table' and tonumber(value.errcode or value.errCode)==-2041 then error('VERIFICATION_REQUIRED')end
    end
    if reply.status~=200 then
        local suffix='';local decoded,value=pcall(require('rapidjson').decode,reply.body)
        if decoded and type(value)=='table'then
            local code=tonumber(value.errcode or value.errCode)
            if code and code%1==0 and math.abs(code)<1000000000 then suffix=' API_'..string.format('%.0f',code)end
        end
        error('HTTP_'..tostring(reply.status)..suffix,0)
    end
    return reply.body,reply.headers
end
local function decode(raw)
    if raw:find('<title>Site Unavailable</title>',1,true)then error('ENDPOINT_UNAVAILABLE')end
    local ok,value=pcall(require('rapidjson').decode,raw)
    assert(ok and type(value)=='table','INVALID_JSON')
    local errorCode=value.errcode or value.errCode
    assert(errorCode==nil or tonumber(errorCode)==0,'API_'..tostring(errorCode))
    return value
end
function C:jsonAt(url,query,body,timeout)
    return decode(self:request(Wire.url(url,query),body,false,timeout))
end
function C:api(path,query,body)
    assert(path:match('^/[A-Za-z/]+$'),'INVALID_ROUTE')
    return decode(self:request(Wire.url('https://i.weread.qq.com'..path,query),body,true))
end
return C
