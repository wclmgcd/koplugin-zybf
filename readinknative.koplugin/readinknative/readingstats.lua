-- Foreground time remains local; newly observed real intervals may be synced.
local S={}
function S.normalize(value)
    value=type(value)=='table'and value or{}
    local result={books={},days={}}
    for _,key in ipairs({'books','days'})do
        for id,seconds in pairs(type(value[key])=='table'and value[key]or{})do
            if type(id)=='string'and type(seconds)=='number'and seconds==seconds and seconds>=0 and seconds<1e10 then result[key][id]=math.floor(seconds)end
        end
    end
    return result
end
local function active(app)
    return not app.closed and not app.suspended and app.mode=='reader'and app.document and app.book
        and not app.activeInput and not app.panel and not app.quickMenu and not app.chapterLoading and not(app.jobs and app.jobs.widget)
end
function S.update(app,now,wall)
    now=math.floor(now or require('ui/time').to_s(require('ui/time').now()));wall=wall or os.time()
    local previous=app.readingInterval;local changed=false
    if previous and previous.state==app.state and previous.active then
        local delta=math.floor(now-previous.now)
        -- A delayed/missed timer or clock discontinuity cannot inflate the count.
        if delta>0 and delta<=90 then
            local stats=app.state.readingStats or S.normalize();app.state.readingStats=stats
            stats.books[previous.id]=(stats.books[previous.id]or 0)+delta
            -- Allocate the short interval by local calendar day, including midnight.
            local start=wall-delta
            for offset=0,delta-1 do
                local day=os.date('%Y-%m-%d',start+offset)
                stats.days[day]=(stats.days[day]or 0)+1
            end
            require('readinknative/readsync').record(app,previous,delta,wall)
            require('readinknative/shelforder').touch(app.state,previous.book,wall)
            changed=true
        end
    end
    app.readingInterval={state=app.state,now=now,wall=wall,book=app.book,id=app.book and tostring(app.book.bookId),active=active(app)and true or false}
    return changed
end
function S.schedule(app)
    local UI=require('ui/uimanager')
    if app.statsTask then UI:unschedule(app.statsTask)end
    if not active(app)then return end
    app.statsTask=app.statsTask or function()
        if S.update(app)then(app.state.flushProgress or app.state.flush)(app.state)end
        S.schedule(app)
    end
    UI:scheduleIn(30,app.statsTask)
end
function S.total(state,bookId)
    local books=(state.readingStats or{}).books or{}
    if bookId then return books[tostring(bookId)]or 0 end
    local seconds=0;for _,n in pairs(books)do seconds=seconds+n end;return seconds
end
function S.week(state,wall)
    local now=os.date('*t',wall or os.time());local weekday=(now.wday+5)%7
    now.hour=12;now.min=0;now.sec=0;now.day=now.day-weekday
    local monday=os.date('%Y-%m-%d',os.time(now));local today=os.date('%Y-%m-%d',wall or os.time())
    local seconds=0
    for day,n in pairs((state.readingStats or{}).days or{})do if day>=monday and day<=today then seconds=seconds+n end end
    return seconds
end
function S.duration(seconds)
    local minutes=math.floor(math.max(0,seconds or 0)/60)
    if minutes==0 then return '不足 1 分钟'end
    if minutes<60 then return minutes..' 分钟'end
    return math.floor(minutes/60)..' 小时 '..(minutes%60)..' 分钟'
end
return S
