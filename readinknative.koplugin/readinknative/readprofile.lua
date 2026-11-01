-- Official Me/UserInfoViewModel statistics. Account totals are server values;
-- adding local or queued seconds here would double count successful reports.
local R={}
local function seconds(n)return type(n)=='number'and n==n and n>=0 and n<=1e12 and n%1==0 end
function R.weekKey(now)
 local d=os.date('*t',now or os.time());d.hour=12;d.min=0;d.sec=0;d.day=d.day-(d.wday+5)%7
 return os.date('%Y-%m-%d',os.time(d))
end
function R.normalize(raw,vid,now)
 assert(type(raw)=='table'and seconds(raw.totalReadingTime)and seconds(raw.einkTotalRead)and seconds(raw.currentReadingTime)and seconds(raw.rankWeek),'READ_PROFILE_SCHEMA_CHANGED')
 return{schema=1,owner=tostring(vid),total=raw.totalReadingTime,eink=raw.einkTotalRead,
  week=raw.rankWeek==1 and raw.currentReadingTime or 0,weekKey=R.weekKey(now),updated=now or os.time()}
end
function R.fetch(client)
 local vid=assert(client.data.vid,'LOGIN_REQUIRED')
 return R.normalize(client:api('/user/profile',{userVid=tostring(vid),totalReadingTime=1,currentReadingTime=1}),vid)
end
function R.current(a,now)
 local info=a.state.accountInfo;local p=info and info.reading
 if type(p)~='table'or p.schema~=1 or p.owner~=tostring(a.client.data.vid)or not seconds(p.total)or not seconds(p.eink)or not seconds(p.week)then return end
 local week=p.weekKey==R.weekKey(now)and p.week or nil
 return{total=p.total,eink=p.eink,week=week}
end
function R.duration(value)
 if value==nil then return '—'end
 local minutes=math.floor(value/60);local h=math.floor(minutes/60);local m=minutes%60
 if h>0 then return h..' 小时'..(m>0 and' '..m..' 分钟'or'')end
 return m>0 and m..' 分钟'or''
end
function R.spans(value)
 if value==nil then return{{text='累计阅读 ',size=15},{text='—',size=27}}end
 local text=R.duration(value);if text==''then return{}end
 local out={{text='累计阅读 ',size=15}}
 for count,unit in text:gmatch('(%d+) ([^%d]+)')do
  out[#out+1]={text=count,size=27};out[#out+1]={text=' '..unit,size=15}
 end
 return out
end
function R.detail(p)
 local eink=R.duration(p and p.eink);local week=R.duration(p and p.week);local out={}
 if eink~=''then out[#out+1]='在墨水屏阅读 '..eink end
 if week~=''then out[#out+1]='本周阅读 '..week end
 return #out>0 and table.concat(out,' | ')or'重拾阅读的习惯，为生活埋下微小的信仰'
end
-- Compare the visible header, not refreshed timestamps or seconds hidden by
-- minute formatting. A refreshed session can also change the displayed name.
function R.displayKey(a,now)
 local ready=a.client:ready();local p=ready and R.current(a,now)
 local name=ready and(a.client.data.name or'微信读书用户')or'登录微信读书'
 return table.concat({ready and'account'or'login',tostring(name),
  ready and R.duration(p and p.total)or'微信扫码登录',ready and R.detail(p)or''},'\0')
end
function R.header(v,bb,ready)
 local a,l=v.app,v.layout;local s=l.s;local y=s(78)
 if not ready then v:text(bb,'微信扫码登录',l.side,y,l.w-2*l.side,s(19),true);return s(152),'微信扫码登录'end
 local p=R.current(a);local spans=R.spans(p and p.total);local h=0;local chunks={}
 for _,part in ipairs(spans)do chunks[#chunks+1]=part.text end
 local total=table.concat(chunks)
 if #spans>0 then
  if v.richText then h=v:richText(bb,spans,l.side,y,l.w-2*l.side)
  else v:text(bb,total,l.side,y,l.w-2*l.side,s(19),true);h=s(30)end
 end
 local detail=R.detail(p);local detailY=y+h+s(4);local box=v:text(bb,detail,l.side,detailY,l.w-2*l.side,s(15),false,2)
 local detailH=box and box.getSize and box:getSize().h or s(44)
 return math.max(s(152),detailY+detailH+s(20)),total..'\0'..detail
end
function R.cancel(a)
 if a.profileTask then require('ui/uimanager'):unschedule(a.profileTask);a.profileTask=nil end
 if a.profileJobs then a.profileJobs:cancel()end;a.profileOwner=nil
end
function R.changed(a)
 a.profileDirty=true
 if a.mode=='account'then R.cancel(a);R.refresh(a,true)end
end
function R.refresh(a,force)
 if a.closed or a.suspended or a.mode~='account'or not a.client or not a.client:ready()or a.profileTask or a.profileOwner then return end
 local old=a.state.accountInfo and a.state.accountInfo.reading;local now=os.time()
 if not force and not a.profileDirty and old and old.owner==tostring(a.client.data.vid)and old.weekKey==R.weekKey()and type(old.updated)=='number'and now>=old.updated and now-old.updated<60 then return end
 local state,vid,data=a.state,a.client.data.vid,a.client.data;local UI=require('ui/uimanager');local tries=0
 local function valid()return not a.closed and not a.suspended and a.mode=='account'and a.state==state and a.client.data.vid==vid end
 a.profileTask=function()
  local task=a.profileTask;a.profileTask=nil;if not valid()then return end
  local net=require('ui/network/manager');if not net:isWifiOn()or not net:isConnected()then return end
  if(a.jobs and a.jobs.widget)or a.syncBusy or a.annotationSyncBusy or(a.offlineRuntime and a.offlineRuntime.busy)then
   tries=tries+1;if tries<=6 then a.profileTask=task;UI:scheduleIn(5,task)end;return
  end
  local owner={};a.profileOwner=owner;a.profileJobs=a.profileJobs or require('readinknative/jobs').new()
  a.profileJobs:run('',function()local c=require('readinknative/client'):new(data);return R.fetch(c),c.data end,function(ok,value,session)
   if a.profileOwner~=owner then return end;a.profileOwner=nil
   if not valid()then return end
   if not ok then return end -- Keep last valid totals when offline or on schema failure.
   local visibleAt=os.time();local previous=R.displayKey(a,visibleAt)
   if session and a.client.data==data then a.client.data=session;a.client.session.data=session;a.client:commit()end
   state.accountInfo=state.accountInfo or{};state.accountInfo.reading=value;a.profileDirty=nil
   (state.flushAccount or state.flush)(state)
   if previous~=R.displayKey(a,visibleAt)then require('readinknative/accountrefresh').request(a)end
  end,false)
 end
 UI:scheduleIn(1,a.profileTask)
end
return R
