-- Account-local reading records; layout comes from one installation-wide file.
local State={};State.__index=State
local annotationKeys={'annotations','annotationSchema','annotationSync'}
local function timed(label,fn)
 local clock=require('ui/time');local started=clock.monotonic()
 local ok,err=pcall(fn)
 local elapsed=clock.to_ms(clock.monotonic()-started)
 if elapsed>=80 then require('logger').info('ReadInk state save ms/kind/ok:',math.floor(elapsed),label,ok)end
 if not ok then error(err,0)end
end
local progressKeys={'articleLast','articlePositions','positions','recent','readingHistory','last','readingStats','readSync','shelfReading','pdfText'}
local function searchHistory(rows)
    local out,seen={},{}
    for _,query in ipairs(type(rows)=='table'and rows or{})do
        if type(query)=='string'and #query<=256 and query:find('%S')and not seen[query]then
            out[#out+1]=query;seen[query]=true;if #out==20 then break end
        end
    end
    return out
end
function State.new(vid)
    local root=require('readinknative/paths').account(vid)
    local snapshot=require('readinknative/accountstore').read(root)
    local settings=require('luasettings')
    local store=snapshot and settings:wrap(snapshot)or settings:open(root..'/state.lua')
    local legacy={font=store:readSetting('font',26),formats=store:readSetting('formats',{}),globalFormat=store:readSetting('globalFormat')}
    local self=setmetatable({root=root,store=store,readSync=store:readSetting('readSync',{schema=1,serial=0,pending={},remote={}}),books=store:readSetting('books',{}),
        articleLast=store:readSetting('articleLast',{}),articlePositions=store:readSetting('articlePositions',{}),positions=store:readSetting('positions',{}),notes=store:readSetting('notes',{}),
        bookmarks=store:readSetting('bookmarks',{}),catalogs=store:readSetting('catalogs',{}),
        recent=store:readSetting('recent',{}),readingHistory=store:readSetting('readingHistory',{}),last=store:readSetting('last',{}),
        accountInfo=store:readSetting('accountInfo'),catalogRights=store:readSetting('catalogRights',{}),offlineQueues=store:readSetting('offlineQueues',{}),sort=store:readSetting('sort','server'),shelfGroups=store:readSetting('shelfGroups',{}),shelfMutation=store:readSetting('shelfMutation'),shelfMetadataSchema=store:readSetting('shelfMetadataSchema',0),storeCache=store:readSetting('storeCache'),readingStats=require('readinknative/readingstats').normalize(store:readSetting('readingStats')),annotations=store:readSetting('annotations',{}),
        readerSummary=store:readSetting('readerSummary',{}),annotationSchema=store:readSetting('annotationSchema',0),annotationSync=store:readSetting('annotationSync'),
        preferences=require('readinknative/preferences').normalize(store:readSetting('preferences')),
        hiddenBooks=store:readSetting('hiddenBooks',{}),socialDisplay=store:readSetting('socialDisplay',{})},State)
    -- Small store/history writes must not serialize books, annotations and
    -- reading progress before a tap can update its screen.
    local legacyHistory=type(self.storeCache)=='table'and self.storeCache.searchHistory
    self.bookstoreStore=require('luasettings'):open(root..'/bookstore.lua')
    local storeCache=self.bookstoreStore:readSetting('cache')
    if self.bookstoreStore:readSetting('schema')==1 and type(storeCache)=='table'and storeCache.schema==1 then self.storeCache=storeCache end
    self.searchStore=require('luasettings'):open(root..'/search.lua')
    local savedHistory=self.searchStore:readSetting('history')
    local hasHistory=self.searchStore:readSetting('schema')==1 and type(savedHistory)=='table'
    self.searchHistory=searchHistory(hasHistory and savedHistory or legacyHistory or(type(self.storeCache)=='table'and self.storeCache.searchHistory))
    self.searchHistoryDirty=not hasHistory
    if type(self.storeCache)=='table'then self.storeCache.searchHistory=nil end
    self.accountStore=require('luasettings'):open(root..'/account.lua')
    local accountInfo=self.accountStore:readSetting('accountInfo')
    if self.accountStore:readSetting('schema')==1 and type(accountInfo)=='table'then self.accountInfo=accountInfo end
    self.offlineStore=require('luasettings'):open(root..'/offline.lua')
    local queues=self.offlineStore:readSetting('queues')
    if self.offlineStore:readSetting('schema')==1 and type(queues)=='table'then self.offlineQueues=queues end
    -- Automatic cloud underline refreshes must not rewrite the catalog,
    -- bookstore and every reading record while the visible page waits for input.
    -- Existing installations fall back to their original account state.
    self.annotationStore=require('luasettings'):open(root..'/annotations.lua')
    if self.annotationStore:readSetting('schema')==1 then
        for _,key in ipairs(annotationKeys)do
            local value=self.annotationStore:readSetting(key)
            if (key=='annotationSchema'and type(value)=='number')or(key~='annotationSchema'and type(value)=='table')then self[key]=value end
        end
    end
    self.progressStore=require('luasettings'):open(root..'/progress.lua')
    self.shelfReading=store:readSetting('shelfReading',{})
    if self.progressStore:readSetting('schema')==1 then
        for _,key in ipairs(progressKeys)do
            local value=self.progressStore:readSetting(key)
            if type(value)==type(self[key])then self[key]=value end
        end
        -- Merge the latest progress first, including the legacy font fallback.
        -- Legacy format fields stay untouched on disk and are never written back.
        for _,key in ipairs{'font','formats','globalFormat'}do
            local value=self.progressStore:readSetting(key)
            if (key=='font'and type(value)=='number')or(key~='font'and type(value)=='table')then legacy[key]=value end
        end
    end
    self.pdfText=self.progressStore:readSetting('pdfText',{})
    if type(self.pdfText)~='table'then self.pdfText={}end
    self.readingStats=require('readinknative/readingstats').normalize(self.readingStats)
    legacy.readingHistory=self.readingHistory;legacy.preferences=self.preferences
    self.font=require('readinknative/readerformat').init(legacy,vid).size
    require('readinknative/annotations').migrate(self)
    require('readinknative/shelforder').model(self)
    return self
end
function State:flush()
    if self.fullFlushTask then require('ui/uimanager'):unschedule(self.fullFlushTask);self.fullFlushTask=nil end
    self.flushingFull=true
    local ok,err=pcall(function()
        self:flushStore();self:flushAccount();self:flushOffline();self:flushAnnotations();self:flushProgress()
        for _,k in ipairs({'books','positions','notes','bookmarks','catalogs','recent','readingHistory','last','sort','annotations','annotationSchema','annotationSync','preferences','hiddenBooks','readingStats','storeCache','offlineQueues','accountInfo','catalogRights','socialDisplay','readerSummary','shelfGroups','shelfMutation','shelfMetadataSchema'})do self.store:saveSetting(k,self[k])end
        timed('account',function()require('readinknative/accountstore').save(self.root,self.store.data)end)
    end)
    self.flushingFull=nil
    if ok then self.fullFlushPending=nil else self.fullFlushPending=true;error(err,0)end
end
function State:deferFlush()
    self.fullFlushPending=true
    local UI=require('ui/uimanager')
    if self.fullFlushTask then UI:unschedule(self.fullFlushTask)end
    self.fullFlushTask=function()
        self.fullFlushTask=nil
        if not pcall(self.flush,self)then require('logger').warn('ReadInk account save deferred until next flush')end
    end
    UI:scheduleIn(0.5,self.fullFlushTask)
end
function State:setSearchHistory(rows)
    self.searchHistory=searchHistory(rows);self.searchHistoryDirty=true
    local UI=require('ui/uimanager')
    if self.searchHistoryFlushTask then UI:unschedule(self.searchHistoryFlushTask)end
    self.searchHistoryFlushTask=function()
        self.searchHistoryFlushTask=nil
        local ok=pcall(self.flushSearchHistory,self)
        if not ok then require('logger').warn('ReadInk search history save deferred until next flush')end
    end
    UI:scheduleIn(0.25,self.searchHistoryFlushTask)
end
function State:flushSearchHistory()
    if self.searchHistoryFlushTask then require('ui/uimanager'):unschedule(self.searchHistoryFlushTask);self.searchHistoryFlushTask=nil end
    if not self.searchHistoryDirty then return end
    self.searchStore:saveSetting('schema',1);self.searchStore:saveSetting('history',self.searchHistory)
    self.searchStore:flush();self.searchHistoryDirty=nil
end
function State:flushStore()
    self:flushSearchHistory()
    self.bookstoreStore:saveSetting('schema',1);self.bookstoreStore:saveSetting('cache',self.storeCache)
    self.bookstoreStore:flush()
end
function State:flushAccount()
    self.accountStore:saveSetting('schema',1);self.accountStore:saveSetting('accountInfo',self.accountInfo);self.accountStore:flush()
end
function State:flushOffline()
    self.offlineStore:saveSetting('schema',1);self.offlineStore:saveSetting('queues',self.offlineQueues);self.offlineStore:flush()
end
function State:flushAnnotations()
    timed('annotations',function()
        self.annotationStore:saveSetting('schema',1)
        for _,key in ipairs(annotationKeys)do self.annotationStore:saveSetting(key,self[key])end
        self.annotationStore:flush()
    end)
end
function State:flushProgress()
    if self.fullFlushPending and not self.flushingFull then return self:flush()end
    self:flushSearchHistory()
    self.progressStore:saveSetting('schema',1)
    for _,key in ipairs(progressKeys)do self.progressStore:saveSetting(key,self[key])end
    timed('progress',function()self.progressStore:flush()end)
end
function State:key(book,chapter)
    return tostring(book.bookId)..':'..tostring(chapter and chapter.chapterUid or 'local')
end
function State:position(book,chapter,value)
    if book.article then
        self.articlePositions=self.articlePositions or{}
        if value then self.articlePositions[tostring(book.bookId)]=value end
        return self.articlePositions[tostring(book.bookId)]
    end
    local key=self:key(book,chapter)
    if value then
        local previous=self.positions[key]
        if previous and type(previous.xpointer)=='string'and type(value.xpointer)=='string'and previous.xpointer~=value.xpointer then require('readinknative/shelforder').touch(self,book,value.updated)end
        self.positions[key]=value;self:rememberRead(book,value.updated)
        if chapter then self.last[tostring(book.bookId)]={chapterUid=tostring(chapter.chapterUid)}end
    end
    return self.positions[key]
end
-- Called only once a document exists, never when merely requesting a book.
-- The bounded snapshots retain books read outside the shelf; array order breaks
-- timestamp ties when several books are opened within the same second.
function State:rememberRead(book,updated)
    local snapshot=require('readinknative/storeapi').book(book)
    if not snapshot then return end
    snapshot.localFile=book.localFile
    local id=snapshot.bookId
    self.recent[id]=updated or os.time()
    self.readingHistory=self.readingHistory or{}
    for i=#self.readingHistory,1,-1 do
        if tostring(self.readingHistory[i].bookId)==id then table.remove(self.readingHistory,i)end
    end
    table.insert(self.readingHistory,1,snapshot)
    while #self.readingHistory>30 do table.remove(self.readingHistory)end
end
function State:filtered(query)
    local books={};query=(query or ''):lower()
    for _,book in ipairs(self.books)do
        if not (self.hiddenBooks or {})[tostring(book.bookId)] and
            (query=='' or (tostring(book.title or '')..' '..tostring(book.author or '')):lower():find(query,1,true))then books[#books+1]=book end
    end
    if self.sort~='server'then
        local rank={};for i,b in ipairs(self.books)do rank[b]=i end
        table.sort(books,function(a,b)
            if self.sort=='recent'then
                return require('readinknative/shelforder').less(self,a,b)
            elseif self.sort=='title' and a.title~=b.title then return tostring(a.title)<tostring(b.title)end
            return rank[a]<rank[b]
        end)
    end
    return books
end
function State:format(book)
    local value=require('readinknative/readerformat').read()
    self.font=value.size;return value
end
function State:setGlobalFormat(value)
    local f=require('readinknative/format').normalize(value,self:format().size)
    f=require('readinknative/readerformat').save(f)
    self.font=f.size;return f
end
return State
