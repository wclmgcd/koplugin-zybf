-- ReaderTopActionBar order and size-qualified minimum widths from the E-Ink APK.
local M={}
function M.slots(l,localFile)
 local s=l.s;local logical=l.w/s(100)*100
 local width=logical>=702 and 100 or logical>=420 and 72 or 44
 local names=localFile and{'bookmark','shelf'}or{'bookmark','thought','shelf','download'}
 local gap=s(2);local right=s(width==44 and 8 or 0);local slot=s(width)
 local x=l.w-right-#names*slot-(#names-1)*gap;local out={}
 for _,name in ipairs(names)do out[#out+1]={name=name,x=x,y=0,w=slot,h=l.top,size=logical>=702 and 30 or 28};x=x+slot+gap end
 return out
end
function M.paint(v,bb)
 local a,l=v.app,v.layout;local items=M.slots(l,a.book.localFile)
 local exitWidth=math.min(l.s(144),items[1].x-l.side)
 v:button(bb,require('readinknative/preferences').exitButtonLabel(),l.side,0,exitWidth,l.top,function()a:exit()end)
 for _,q in ipairs(items)do
  if q.name=='download'then require('readinknative/offline').readerButton(v,bb,q.x,q.y,q.w,q.h,q.size)
  else
   local name,action
   if q.name=='bookmark'then name=a:hasBookmark()and'icon_reader_deletebookmark'or'icon_reader_addbookmark';action=function()a:bookmark()end
   elseif q.name=='thought'then name='icon_toolbar_show_idea';action=function()require('readinknative/social').top(a)end
   else name=require('readinknative/store').inShelf(a,a.book.bookId)and'icon_toolbar_bookshelf_added'or'icon_toolbar_bookshelf_add';action=function()require('readinknative/store').addFromReader(a)end end
   v:icon(bb,name,q.x,q.y,q.w,q.h,action,nil,{w=q.size,h=q.size})
  end
 end
end
return M
