-- Verified official membership predicates, bound to fresh account/book metadata.
local P={MEMBERSHIP=4096,PAYING_MEMBERSHIP=1048576}
local function yes(v)return v==true or v==1 or v=='1'end
local function num(v)return type(v)=='number'and v==v and v>=0 and v<1e13 and v or nil end
local function bit(value,mask)local n=tonumber(value);return n and n>=0 and n%1==0 and math.floor(n/mask)%2==1 end
function P.shortUntil(book,now)
    local short=book.shortTimeRead
    if type(short)=='table'and short.active==1 and num(short.expireTime)and short.expireTime>0 then
        local ending=(math.floor(short.expireTime/60)+30)*60
        if now<ending then return ending end
    end
end
function P.attach(book,summary,vid,now)
    now=now or os.time();local ending=P.shortUntil(book,now);local reason=ending and'short_time'or'permission_unconfirmed'
    local membership=type(summary)=='table'and summary.expired==0 and num(summary.expiredTime)and summary.expiredTime>0 and num(summary.remainTime)and summary.remainTime>0
    local paying=membership and(summary.isPaying==1 or summary.permanent==1)and num(summary.payingRemainTime)and summary.payingRemainTime>0
    if not ending then
        if bit(book.payType,P.MEMBERSHIP)and membership then ending=now+summary.remainTime;reason='membership'
        elseif bit(book.payType,P.PAYING_MEMBERSHIP)then
            if paying then ending=now+math.min(summary.remainTime,summary.payingRemainTime);reason='paying_membership'
            else reason='paid_membership_required'end
        end
    end
    book._readPermission={bookId=tostring(book.bookId),vid=vid,checkedAt=now,accessUntil=ending,untilTime=math.min(ending or now,now+300),reason=reason,allowed=ending~=nil}
    return book
end
function P.mode(book,chapter,vid,now)
    now=now or os.time()
    if yes(book.paid)or yes(chapter.paid)then return'full','paid'end
    if bit(book.payType,32)then return'full','free_book'end
    local proof=book._readPermission
    if type(proof)=='table'and proof.bookId==tostring(book.bookId)and proof.vid~=nil and proof.vid==vid and num(proof.checkedAt)and num(proof.untilTime)and proof.checkedAt<=now and now<proof.untilTime and proof.allowed then return'full',proof.reason end
    local limit,index=tonumber(book.maxFreeChapter),tonumber(chapter.chapterIdx)
    if limit and index and index>=0 and index<=limit then
        local partial=book.maxFreeInfo
        if index==limit and type(partial)=='table'and num(partial.maxFreeChapterRatio)and partial.maxFreeChapterRatio<100 then return'preview','partial_free_chapter'end
        return'full','free_chapter'
    end
    return'preview',proof and proof.reason or'permission_unconfirmed'
end
-- A catalog hint never grants download rights. Trial chapters stay readable,
-- including the final partial preview; auto-buy is not a reading entitlement.
function P.catalogLocked(book,chapter,vid,proof,now)
    if book.localFile then return false end
    now=now or os.time()
    local view=book
    if type(proof)=='table'and proof.allowed and proof.bookId==tostring(book.bookId)and proof.vid==vid and num(proof.checkedAt)and num(proof.accessUntil)and proof.checkedAt<=now and now<proof.accessUntil then
        return false
    end
    local mode,reason=P.mode(view,chapter,vid,now)
    if mode=='full'or reason=='partial_free_chapter'then return false end
    local index,limit=tonumber(chapter.chapterIdx),tonumber(book.maxFreeChapter)
    if index and limit then return index>limit end
    return num(chapter.price)and chapter.price>0 and not yes(chapter.paid)or false
end
return P
