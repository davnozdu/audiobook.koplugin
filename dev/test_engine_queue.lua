-- Regression tests: real controller + parser + XPointer window, no Android/KOReader dependency.
local now = 0
package.preload['ui/event'] = function() return {} end
package.preload['ui/uimanager'] = function() return {getTime=function() return now end, scheduleIn=function() end} end
package.preload['ui/time'] = function() return {to_s=function(t) return t end} end
package.preload['logger'] = function() return setmetatable({}, {__index=function() return function() end end}) end
package.preload['audiobook_gettext'] = function() return function(s) return s end end
package.preload['ffi/util'] = function() return {template=function(s) return s end} end
local SC = dofile('synccontroller.lua')
local Parser = dofile('textparser.lua')
local XP = dofile('xptext.lua')
local passed = 0
local function check(ok, name) assert(ok, name); passed=passed+1 end
local function count(t) local n=0 for _ in pairs(t) do n=n+1 end return n end
local function new(texts)
    local c=setmetatable({}, {__index=SC})
    c:_queueReset()
    c.state=c.STATE.PLAYING; c._q_page=1; c._page_gen=1; c.reading_sentence_idx=1
    c.parsed_data={sentences={}}; c.sent={}; c.flushes=0
    for i,t in ipairs(texts) do c.parsed_data.sentences[i]={index=i,text=t} end
    c.total_sentences=#texts; c.current_sentence=c.parsed_data.sentences[1]
    c.tts_engine={_queue_active=true, rate=1, queueSpeakAndroid=function(e,id,text,flush)
        if flush then c.flushes=c.flushes+1; c.sent={} end
        c.sent[#c.sent+1]={id=id,text=text}; e._queue_active=true; return true
    end}
    c.advanceToNextPage=function(self) self.advanced=(self.advanced or 0)+1 end
    for _,k in ipairs({'_prefetchNextPage','_applyBarVisibility','_queueEnsurePoll','_publishPlaying',
        '_noteHeard','_disarmTtsWaitUi','_rememberSpoken'}) do c[k]=function() end end
    c:_queueFill(1)
    return c
end
do
    local c=new({'Hello.', ').'})
    c:_queueOnDone(c._q_queued[1])
    check(c.advanced==1, 'punctuation tail advances without watchdog')
end
do
    local c=new({'Hello.', 'Goodbye.'})
    c._q_started_in_run=true
    c.tts_engine.queueEventsAndroid=function() return {{kind='E',id=c._q_queued[2],extra='code=-8'}},false end
    c:_queueTick()
    check(not c.advanced, 'future terminal error cannot advance sounding page')
    c:_queueOnDone(c._q_queued[1])
    check(c.advanced==1, 'ordered completion advances after future error')
end
do
    local c=new({'Hello.'}); c._q_changed_at=0; now=26
    c._queueRecover=function(self) self.recovered=true end
    c.tts_engine.queueEventsAndroid=function() return {{kind='D',id='q:old:1:1'}},false end
    c:_queueTick()
    check(c._q_changed_at==0 and c.recovered, 'stale callback cannot postpone watchdog')
end
do
    local c=new({'Hello.'}); local id=c._q_queued[1]
    c:_queueOnDone(id); c._q_page=2; c:_queuePrune()
    check(not c._q_ids[id], 'departed terminal metadata freed')
end
do
    local texts={} for i=1,150 do texts[i]='Yes.' end
    local c=new(texts)
    check(#c.sent>6 and #c.sent<=64, 'short dialogue buffered beyond six with hard bound')
    check(count(c._q_ids)<=64, 'bounded live IDs')
end
local function docFor(text, perpage)
    local starts,ends={},{}
    for a,_,b in text:gmatch('()(%S+)()') do starts[#starts+1]=a; ends[#ends+1]=b end
    local d={page=1}
    function d:compareXPointers(a,b) a,b=tonumber(a),tonumber(b); return b==a and 0 or (b>a and 1 or -1) end
    function d:getNextVisibleWordStart(x) for _,a in ipairs(starts) do if a>tonumber(x) then return tostring(a) end end end
    function d:getPrevVisibleWordStart(x) for i=#starts,1,-1 do if starts[i]<tonumber(x) then return tostring(starts[i]) end end end
    function d:getNextVisibleWordEnd(x) for i,a in ipairs(starts) do if a>=tonumber(x) then return tostring(ends[i]) end end end
    function d:getTextFromXPointers(a,b) return text:sub(tonumber(a),tonumber(b)-1) end
    function d:getPageXPointer(p) return starts[(p-1)*perpage+1] and tostring(starts[(p-1)*perpage+1]) end
    function d:getXPointer() return self:getPageXPointer(self.page) end
    function d:getCurrentPage() return self.page end
    function d:getPageCount() return math.ceil(#starts/perpage) end
    return d
end
for _,shape in ipairs({'short','mixed'}) do
for _,range_turn in ipairs({false,true}) do
    local c=new({}); local items={}
    -- Include literal identical adjacent sentences: they belong to different ranges and must both sound.
    for i=1,150 do items[#items+1]= i%7==0 and 'Да, да.' or ('Фраза номер '..i..' заканчивается здесь.') end
    if shape=='mixed' then
        for i=17,#items,17 do
            local words={}
            for k=1,110 do words[k]='длинноеописание'..k end
            items[i]=table.concat(words,' ')..'.'
        end
    end
    local text=table.concat(items,' ')
    local doc=docFor(text,11)
    c.plugin={ui={document=doc},getSetting=function(_,key,default) if key=='highlight_sentences' then return false end return default end}
    c.text_parser=Parser:new{}
    local heard, dispatched, maxids={}, {}, 0
    local function view(turned)
        c._xp_turned=turned; c._page_gen=c._page_gen+1
        local parsed,empty=c:_xpView()
        if not parsed then return false,empty end
        c.parsed_data=parsed; c.total_sentences=#parsed.sentences; c.reading_sentence_idx=1; c.current_sentence=nil
        c._next_page_prefetched=false; c._q_advancing=nil
        c:_queuePlay(parsed.sentences[1])
        -- Real prefetch method copies the already built XPointer window.
        c._q_next_parsed=c._xp_next_parsed; c:_queueFill(1)
        return true
    end
    local function settle()
        if not c.advanced then return end
        c.advanced=nil
        local built=false
        repeat
            doc.page=doc.page+1
            if doc.page>doc:getPageCount() then break end
            built=view(true)
        until built
    end
    c.tts_engine._queue_active=false
    check(view(false), 'initial document window builds')
    local cursor=1
    while cursor<=#c.sent do
        local item=c.sent[cursor]; cursor=cursor+1
        local m=c._q_ids[item.id]
        check(m~=nil, 'queued ID retained until playback')
        local pos=m.position
        check(not dispatched[pos], 'each document range dispatched once')
        dispatched[pos]=true; heard[#heard+1]=item.text
        c._q_last_started=item.id; c:_queueOnStart(item.id)
        if range_turn then
            local current=c.parsed_data.sentences[m.idx]
            if m.page==c._q_page and current and current.xp_turn_at then
                c:_queueOnRange(item.id,tostring(current.xp_turn_at).."\t0")
                settle()
            end
        end
        now=now+2
        c:_queueOnDone(item.id)
        -- Audio callbacks can turn the page before Lua receives the next start event.
        settle()
        maxids=math.max(maxids,count(c._q_ids))
    end
    local expected=Parser:new{}:parse(text).sentences
    if #heard~=#expected then
        print('MISMATCH',shape,tostring(range_turn),#heard,#expected,'flush',c.flushes,'page',doc.page)
        for i,s in ipairs(expected) do if heard[i]~=s.text then for j=math.max(1,i-3),i+3 do print('AT',j,'got',heard[j],'wanted',expected[j] and expected[j].text) end; break end end
    end
    check(#heard==#expected, 'all sentences heard across many page turns')
    for i,s in ipairs(expected) do check(heard[i]==s.text, 'text order preserved '..i) end
    check(c.flushes==1, 'only initial flush, no page-boundary replay')
    check(maxids<=c.QUEUE_MAX_ITEMS+20, 'metadata bounded across book')
end
end
print(passed..' queue/XPointer assertions passed')
