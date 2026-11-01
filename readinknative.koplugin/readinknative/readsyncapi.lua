-- Independently expressed official E-Ink report encoding; no Android library.
local A={}
local remap=('34ca55401db693c63130293532a7b811c2b516fa8bb124a4109004e908f83b8a9c8c44f9bc5c69e2a1dad2d37589f71e2d5056d77253bf22fb200f012e45876e6648f2e0cdfe67a943f49451cea54aee13268eccaa33145d0e39bbcf912b814dea99ec1a2c85c5d936744b18e1f13d9d419fb4170dd64cbedcaf972877f062ff71c1c8278f6c68a89be6591c1b1209984e3f063700ba1f0a192fc9d5d057496ffd25e4610c42cb96645fdbad60238d9a6dc3c45e3eb9926abd5b077f7695ed4fab847a80e778c7e5eb73836bfc38467d4765b352633a05d1efa3a6de9e3c02aeb27ba0f6f32ac0ac86035a540bf582d47ee3dfb0d8dd21e87c88a2795870b715'):gsub('..',function(h)return string.char(tonumber(h,16))end)
local function rotate(s)
 local xor=0;for i=1,#s do xor=require('bit').bxor(xor,s:byte(i))end
 local shift=(xor%11)%math.max(1,#s);return shift==0 and s or s:sub(-shift)..s:sub(1,-shift-1)
end
function A.signature(keys)
 local values={};for _,s in ipairs(keys)do
  assert(type(s)=='string'and not s:find('%z'),'SYNC_SIGNATURE_INPUT');local out={}
  for i=1,#s do out[i]=remap:sub(s:byte(i)+1,s:byte(i)+1)end;values[#values+1]=table.concat(out)
 end
 values[#values+1]='5a6f1';table.sort(values)
 local sha=require('ffi/sha2').sha256
 return sha(rotate(sha(rotate(table.concat(values)))))
end
local function int(n,lo,hi)return type(n)=='number'and n==n and n%1==0 and n>=lo and n<=hi end
local function pdf(book)return type(book.format)=='string'and book.format:lower()=='pdf'end
function A.pdfPosition(book,position)
 assert(pdf(book)and type(position)=='table'and position.pdf==true,'SYNC_PDF_POSITION_INVALID')
 local page,total=position.page,position.pages
 assert(int(total,1,2147483647)and int(page,1,total),'SYNC_PDF_POSITION_INVALID')
 local index=page-1;local percent=index>=total-1 and 100 or math.floor(index*100/total)
 return{pdf=true,page=page,pages=total,chapterUid=tostring(index),chapterIdx=index,chapterOffset=0,
  percent=percent,currentPercent=percent,chapterProgress=0,updated=position.updated,pdfEpoch=position.pdfEpoch}
end
function A.normalize(result,book)
 assert(type(result)=='table'and(result.bookId==nil or tostring(result.bookId)==tostring(book.bookId)),'SYNC_BOOK_MISMATCH')
 if pdf(book)then
  local v=type(result.book)=='table'and result.book or{}
  if type(v.otherType)=='table'then v=v.otherType end
  if(v.bookId==nil or tostring(v.bookId)==tostring(book.bookId))and int(v.chapterUid,0,2147483646)
   and(v.chapterOffset==nil or v.chapterOffset==0)and int(v.updateTime,0,1e12)then
   return{pdf=true,chapterUid=tostring(v.chapterUid),chapterIdx=v.chapterUid,chapterOffset=0,
    updated=v.updateTime,version=v.bookVersion,appId=v.appId,percent=v.progress,
    readingTime=v.readingTime or 0,recordReadingTime=v.recordReadingTime,readingTimeKnown=int(v.readingTime,0,1e12)}
  end
  return
 end
 local best;local converted=type(book.pdfText)=='table'or type(book._pdfText)=='table'
 for _,v in ipairs({result.book or{},result.tts or{}})do
  local textCoordinate=not converted or v.curType=='epub'or v.format=='epub'or int(v.chapterOffset,1,2147483647)
  if textCoordinate and v.curType~='pdf'and int(v.chapterUid,1,2147483647)and int(v.chapterOffset,0,2147483647)and int(v.updateTime,0,1e12)then
   if not best or v.updateTime>best.updated then best={chapterUid=tostring(v.chapterUid),chapterIdx=v.chapterIdx,chapterOffset=v.chapterOffset,
    updated=v.updateTime,version=v.bookVersion,appId=v.appId,percent=v.progress,readingTime=v.readingTime or 0,recordReadingTime=v.recordReadingTime,readingTimeKnown=int(v.readingTime,0,1e12)}end
  end
 end
 return best
end
function A.pull(c,book)
 local raw=c:api('/book/getProgress',{bookId=book.bookId});return A.normalize(raw,book),raw.timestamp
end
function A.config(c,old)
 if old and old.guest and os.time()-(old.checkedAt or 0)<3600 then return old end
 local data=c:api('/feature',{synckey=0});local features=data.feature
 assert(type(features)=='table','SYNC_FEATURE_UNAVAILABLE')
 local guest=features.guest_token or'5ecdcfd7f' -- Official FeatureGuestTokenWrapper default.
 assert(type(guest)=='string'and #guest>0,'SYNC_FEATURE_UNAVAILABLE')
 return{guest=guest,checkedAt=os.time()}
end
function A.body(c,row,position,guest,stamp,random)
 assert(c:ready()and type(c.data.deviceId)=='string'and type(c.data.installId)=='string','LOGIN_REQUIRED')
 assert(int(row.seconds or 0,0,2147483647)and type(row.hours)=='table','SYNC_TIME_INVALID')
 local hours,total=require('rapidjson').array(),0
 for _,h in ipairs(row.hours)do
  assert(int(h.startOfHour,0,1e12)and int(h.readingTime,0,3600)and type(h.timeZone)=='string'and h.timeZone:match('^[+-]%d%d:%d%d$'),'SYNC_TIME_INVALID')
  hours[#hours+1]={startOfHour=h.startOfHour,timeZone=h.timeZone,readingTime=h.readingTime,ttsTime=0};total=total+h.readingTime
 end
 assert(total==(row.seconds or 0),'SYNC_TIME_INVALID')
 local p={bookId=row.book.bookId,bookVersion=row.book.version or 0,appId=c.data.deviceId,installId=c.data.installId,deviceId=c.data.deviceId,
  readingTime=total,ttsTime=0,lectureTime=0,lectureTextTime=0,novalTime=0,autoTime=0,isLecture=0,isStoryFeed=0,
  isResendReadingInfo=0,reviewId='',voiceType=0,wordCount=0,risk=row.risk or 0,recordCreateTimeZone=row.zone or'+00:00',hours=hours,timestamp=stamp,random=random,summary=''}
 if position then
  if pdf(row.book)then
   local checked=A.pdfPosition(row.book,position)
   assert(tostring(position.chapterUid)==checked.chapterUid and position.chapterIdx==checked.chapterIdx and position.chapterOffset==0,'SYNC_PDF_POSITION_INVALID')
   position=checked
  end
  assert(int(tonumber(position.chapterUid),pdf(row.book)and 0 or 1,2147483647)and int(position.chapterOffset,0,2147483647),'SYNC_POSITION_INVALID')
  assert(position.percent==nil or int(position.percent,0,100),'SYNC_POSITION_INVALID')
  p.chapterUid=tonumber(position.chapterUid);p.chapterIdx=tonumber(position.chapterIdx)or-2;p.chapterOffset=position.chapterOffset
  p.progress=position.percent;p.currentProgress=position.currentPercent or position.percent;p.chapterProgress=position.chapterProgress or 0
 end
 if pdf(row.book)and type(row.book.otherType)=='string'and row.book.otherType:find('epub',1,true)then p.curType='pdf'end
 if not pdf(row.book)and type(row.book.pdfText)=='table'and row.book.pdfText.schema==1
  and row.book.pdfText.vid==tostring(c.data.vid)and row.book.pdfText.bookId==tostring(row.book.bookId)
  and row.book.pdfText.version==row.book.version then p.curType='epub'end
 local fields={tostring(c.data.vid),p.deviceId,p.appId,tostring(p.bookId),tostring(p.risk),p.recordCreateTimeZone,tostring(p.readingTime),'0'}
 for _,h in ipairs(hours)do fields[#fields+1]=tostring(h.startOfHour);fields[#fields+1]=h.timeZone;fields[#fields+1]=tostring(h.readingTime);fields[#fields+1]='0'end
 p.signature=A.signature{guest,tostring(random),tostring(stamp),table.concat(fields,'_')}
 return p
end
function A.send(c,body)
 c.write_path=nil;c.write_state='unsent'
 local route='/book/read';local payload=body
 if #body.hours>1 then
  local config=c:api('/config',{token=1});assert(type(config.token)=='string'and #config.token>0,'SYNC_CONFIG_UNAVAILABLE')
  local stamp=body.timestamp;local random=require('readinknative/auth/wire').random1000()
  route='/book/batchUploadProgress';payload={books=require('rapidjson').array{body},timestamp=stamp,random=random,
   signature=require('ffi/sha2').sha256(tostring(stamp)..config.token..tostring(random)),recordCreateTimeZone=body.recordCreateTimeZone}
 end
 c.write_path=route;c.write_state='unsent'
 local result=c:api(route,nil,payload)
 assert(result.succ==1 or result.succ==true or result.success==true or result.success==1,'SYNC_NOT_ACCEPTED')
 return true
end
return A
