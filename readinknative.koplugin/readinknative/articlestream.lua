-- Incremental #js_content extraction. Publisher JS can exceed the body limit;
-- it is discarded while receiving, without executing or keeping it in memory.
local S={BODY_LIMIT=3*1024*1024,TRANSFER_LIMIT=24*1024*1024,TAG_LIMIT=65536}
local M={};M.__index=M
local function endTag(s)
 local quote
 for i=2,#s do local c=s:sub(i,i)
  if quote then if c==quote then quote=nil end
  elseif c=='"'or c=="'"then quote=c elseif c=='>'then return i end
 end
end
local function isContent(tag)
 local attributes=tag:match('^<%s*[%w:_%-]+(.*)>$')or''
 local function has(q)return attributes:match('%s[iI][dD]%s*=%s*'..q..'js_content'..q)end
 return has('"')or has("'")or(attributes..' '):match('%s[iI][dD]%s*=%s*js_content[%s/>]')
end
function S.new()return setmetatable({buffer='',parts={},bytes=0,received=0,depth=0,hint=''},M)end
function M:append(s)
 if self.root and not self.complete then
  self.bytes=self.bytes+#s;assert(self.bytes<=S.BODY_LIMIT-64,'ARTICLE_TOO_LARGE');self.parts[#self.parts+1]=s
 elseif #self.hint<8192 then self.hint=self.hint..s:sub(1,8192-#self.hint)end
end
function M:feed(chunk)
 assert(type(chunk)=='string','ARTICLE_HTML_INVALID')
 self.received=self.received+#chunk;assert(self.received<=S.TRANSFER_LIMIT,'ARTICLE_RESPONSE_TOO_LARGE')
 if self.complete then return end
 self.buffer=self.buffer..chunk
 while #self.buffer>0 do
  if self.comment then
   local _,b=self.buffer:find('-->',1,true)
   if b then self.buffer=self.buffer:sub(b+1);self.comment=nil else self.buffer=self.buffer:sub(-2);return end
  elseif self.raw then
   local a,b=self.buffer:lower():find('</'..self.raw..'%s*>')
   if b then self.buffer=self.buffer:sub(b+1);self.raw=nil else self.buffer=self.buffer:sub(-256);return end
  else
   local a=self.buffer:find('<',1,true)
   if not a then self:append(self.buffer);self.buffer='';return end
   if a>1 then self:append(self.buffer:sub(1,a-1));self.buffer=self.buffer:sub(a)end
   -- A fragmented comment opener must wait, rather than become a normal tag.
   if #self.buffer<4 and ('<!--'):sub(1,#self.buffer)==self.buffer then return end
   if self.buffer:sub(1,4)=='<!--'then self.comment=true;self.buffer=self.buffer:sub(5)
   else
    local b=endTag(self.buffer)
    if not b then assert(#self.buffer<=S.TAG_LIMIT,'ARTICLE_HTML_INVALID');return end
    local tag=self.buffer:sub(1,b);self.buffer=self.buffer:sub(b+1)
    local close,name=tag:match('^<%s*(/?)%s*([%w:_%-]+)');name=name and name:lower()
    local empty=tag:match('/%s*>$')~=nil
    if (name=='script'or name=='style'or name=='iframe'or name=='object')and close~='/'and not empty then self.raw=name
    elseif not self.root then
     if name and close~='/'and isContent(tag)then self.root=name;self.depth=1 end
    else
     if name==self.root then
      if close=='/'then self.depth=self.depth-1
      elseif not empty then self.depth=self.depth+1 end
     end
     if self.depth==0 then self.complete=true;self.buffer='';return end
     self:append(tag)
    end
   end
  end
 end
end
function M:finish()
 if not self.complete then
  if self.hint:find('验证',1,true)or self.hint:find('环境异常',1,true)or self.hint:lower():find('captcha',1,true)then error('ARTICLE_VERIFICATION_REQUIRED')end
  error('ARTICLE_BODY_UNAVAILABLE')
 end
 assert(self.bytes>0,'ARTICLE_BODY_UNAVAILABLE')
 return '<div id="js_content">'..table.concat(self.parts)..'</div>'
end
return S
