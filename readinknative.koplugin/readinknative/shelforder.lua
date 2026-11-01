-- Shelf reading events are independent of position/cache persistence. Old
-- recent/position timestamps are deliberately not promoted during migration.
local O={}
function O.time(v)
 local n=tonumber(v);if not n or n~=n or n<0 or n>1e15 then return 0 end
 if n>1e12 then n=n/1000 end;return n
end
function O.model(state)
 local m=state.shelfReading
 if type(m)~='table'or m.schema~=1 or type(m.events)~='table'or type(m.serial)~='number'then
  m={schema=1,serial=0,events={}};state.shelfReading=m
 end
 return m
end
function O.touch(state,book,at)
 if not book or book.article or not book.bookId then return end
 local m=O.model(state);m.serial=m.serial+1
 m.events[tostring(book.bookId)]={at=O.time(at or os.time()),serial=m.serial}
end
function O.serial(state,bookId)
 local e=O.model(state).events[tostring(bookId)];return e and e.serial
end
function O.ack(state,bookId,serial,serverTime)
 if not serial then return end
 local m=O.model(state);local e=m.events[tostring(bookId)]
 if e and e.serial==serial then m.serial=m.serial+1;e.confirmed=m.serial;e.serverTime=serverTime and O.time(serverTime)or nil end
end
function O.fence(state)return O.model(state).serial end
function O.merge(state,books,fence)
 local m=O.model(state)
 for _,b in ipairs(books)do
  local key=tostring(b.bookId);local e=m.events[key]
  if e and type(e.at)=='number'and type(e.serial)=='number'then
   -- An acknowledgement only yields to a snapshot requested after that ACK.
   -- Reads made while the request was in flight retain their own newer event.
   local reflected=O.time(b.readUpdateTime)>=O.time(e.at)
   local serverReflected=fence and type(e.confirmed)=='number'and e.confirmed<=fence and e.serial<=fence and type(e.serverTime)=='number'and e.serverTime>0 and O.time(b.readUpdateTime)>=e.serverTime
   if reflected or serverReflected then m.events[key]=nil end
  end
 end
end
function O.recent(state,b)
 local e=O.model(state).events[tostring(b.bookId)];local at=type(e)=='table'and O.time(e.at)or 0
 return math.max(O.time(b.readUpdateTime),at)
end
function O.top(b)return b.isTop==true or tonumber(b.isTop)==1 end
function O.less(state,a,b)
 if O.top(a)~=O.top(b)then return O.top(a)end
 local x,y=O.recent(state,a),O.recent(state,b)
 if x~=y then return x>y end
 return tostring(a.bookId)<tostring(b.bookId)
end
function O.groupTime(state,books)
 local first=books[1];if not first then return 0 end
 local at=O.recent(state,first)
 if O.top(first)then for _,b in ipairs(books)do if not O.top(b)then return math.max(at,O.recent(state,b))end end end
 return at
end
return O
