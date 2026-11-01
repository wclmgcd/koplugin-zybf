-- Compare signed public article identity for LOCAL cache reuse only.
-- Never alter an outbound URL, synthesize a signature or retry a challenge.
local M={}
local allowed={__biz=true,mid=true,idx=true,sn=true,chksm=true,scene=true,subscene=true,from=true,isappinstalled=true,ascene=true,clicktime=true,enterid=true,wx_header=true,lang=true,version=true,nettype=true,devicetype=true}
local function decode(s)
 if s:gsub('%%%x%x',''):find('%%')then return end
 s=s:gsub('%%(%x%x)',function(h)return string.char(tonumber(h,16))end)
 if s:find('[%c]')then return end;return s
end
function M.key(value)
 local ok,url=pcall(require('readinknative/articleapi').url,value);if not ok then return end
 local query=url:match('^https://mp%.weixin%.qq%.com/s%?([^#]+)');if not query then return end
 local q={};for part in (query..'&'):gmatch('(.-)&')do
  local k,v=part:match('^([^=]+)=(.*)$');k=k and decode(k);v=v and decode(v)
  if not k or not v or not allowed[k]or q[k]~=nil then return end;q[k]=v
 end
 if not q.__biz or #q.__biz<8 or #q.__biz>256 or not q.__biz:match('^[%w+/=]+$')or not q.mid or #q.mid>20 or not q.mid:match('^%d+$')or not q.idx or not q.idx:match('^%d+$')or tonumber(q.idx)<1 or tonumber(q.idx)>32 or not q.sn or #q.sn~=32 or not q.sn:match('^[a-fA-F0-9]+$')then return end
 return require('ffi/sha2').sha256(q.__biz..':'..q.mid..':'..q.idx..':'..q.sn:lower())
end
function M.same(a,b)
 if a==b then return true end;local key=M.key(a);return key~=nil and key==M.key(b)
end
return M
