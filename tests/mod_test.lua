-- The event log, the conversation log and the text line: notifications, the log window, typing
-- what to say, and what goes into the save, with the global and player scripts running against
-- stand-ins for OpenMW's API.
-- Run from the repository root with Lua 5.4 or newer: lua tests/mod_test.lua
local MOD = arg[1] or ((arg[0]:match('^(.*)[/\\]') or '.') .. '/../zdorpgai')
package.path = MOD .. '/?.lua;' .. package.path

local failures, passes = 0, 0
local function check(cond, what, extra)
    if cond then
        passes = passes + 1
    else
        failures = failures + 1
        io.stdout:write('FAIL: ' .. what .. (extra and ('\n      got: ' .. tostring(extra)) or '') .. '\n')
    end
end

local printed = {}
print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    printed[#printed + 1] = table.concat(parts, '\t')
end

-- l10n: {name} placeholders from the mod's yaml
local function loadYaml(path)
    local t = {}
    for line in io.lines(path) do
        local k, v = line:match('^(%w+):%s*"(.*)"%s*$')
        if k then t[k] = v end
    end
    return t
end
local strings = loadYaml(MOD .. '/l10n/zdorpgai/ru.yaml')
local function L(key, args)
    local s = assert(strings[key], 'missing l10n key ' .. key)
    return (s:gsub('{(%w+)}', function(k) return tostring(args and args[k]) end))
end

-- Game objects
local KEY = { L = 'key_L', Y = 'key_Y', K = 'key_K', Enter = 'key_Enter', NumpadEnter = 'key_NumpadEnter' }
local function vec(x, y, z) return { x = x, y = y, z = z } end

local itemType = { record = function(item) return { name = item._name, value = 1 } end }
local function newInventory()
    local inv = { stacks = {} }
    function inv:isResolved() return true end
    function inv:resolve() end
    function inv:countOf(id)
        local n = 0
        for _, s in ipairs(self.stacks) do if s.recordId == id then n = n + s.count end end
        return n
    end
    function inv:findAll(id)
        local found = {}
        for _, s in ipairs(self.stacks) do if s.recordId == id then found[#found + 1] = s end end
        return found
    end
    function inv:getAll() return self.stacks end
    return inv
end
local function newStack(inv, id, name, count)
    local s = { recordId = id, _name = name, count = count, type = itemType, _owner = inv, id = id .. '#' .. tostring(math.random(1e6)) }
    function s:split(n)
        self.count = self.count - n
        return newStack(nil, self.recordId, self._name, n)
    end
    function s:moveInto(target)
        if self._owner then
            for i, other in ipairs(self._owner.stacks) do
                if other == self then table.remove(self._owner.stacks, i) break end
            end
        end
        self._owner = target
        target.stacks[#target.stacks + 1] = self
    end
    if inv then inv.stacks[#inv.stacks + 1] = s end
    return s
end

local function newActor(recordId, name, isNpc)
    local a = { recordId = recordId, _name = name, _isNpc = isNpc, events = {}, inv = newInventory(),
        position = vec(0, 0, 0), cell = { name = 'Seyda Neen' } }
    function a:sendEvent(event, data)
        self.events[#self.events + 1] = { name = event, data = data }
        if self.handlers and self.handlers[event] then self.handlers[event](data) end
    end
    function a:isValid() return true end
    return a
end

local player = newActor('player', 'Nerevar', false)
local fargoth = newActor('fargoth', 'Фаргот', true)
local arrille = newActor('arrille', 'Арриль', true)
newStack(fargoth.inv, 'torch', 'Факел', 1)
newStack(player.inv, 'gold_001', 'Золото', 100)

local types = {
    NPC = {
        record = function(actor) assert(actor and actor._isNpc ~= nil, 'not an actor'); return { name = actor._name, race = 'dark elf', isMale = true, class = 'commoner' } end,
        objectIsInstance = function(actor) return actor._isNpc == true end,
        modifyBaseDisposition = function(npc, p, delta) npc.disposition = (npc.disposition or 50) + delta end,
        getFactions = function() return {} end,
        classes = { records = {} }, races = { records = {} },
    },
    Actor = {
        inventory = function(actor) return actor.inv end,
        isDead = function() return false end,
        stats = { dynamic = { health = function() return { current = 1, base = 1 } end } },
    },
    Player = { objectIsInstance = function(actor) return actor == player end },
}

-- Stubs shared by both scripts
local ipcFile = nil
local function setIncoming(session, messages)
    local json = require('scripts.zdorpgai.json')
    local lines = { 'session:' .. session }
    for _, m in ipairs(messages) do lines[#lines + 1] = json.encode(m) end
    ipcFile = table.concat(lines, '\n') .. '\n'
end

local realTime = 0
local globalHandlers = {}
package.loaded['openmw.core'] = {
    getRealTime = function() return realTime end,
    sendGlobalEvent = function(event, data) if globalHandlers[event] then globalHandlers[event](data) end end,
    l10n = function() return L end,
    sound = { say = function() end, isSayActive = function() return false end },
    dialogue = { topic = { records = {} }, greeting = { records = {} }, journal = { records = {} } },
    factions = { records = {} }, regions = { records = { ['bitter coast region'] = { name = 'Горький берег' } } },
}
package.loaded['openmw.types'] = types
package.loaded['openmw.util'] = {
    vector2 = function(x, y) return { x = x, y = y } end,
    vector3 = vec,
    color = { rgb = function(r, g, b) return { r = r, g = g, b = b } end },
    normalizeAngle = function(a) return a end,
}
package.loaded['openmw.vfs'] = {
    open = function(path)
        assert(path == 'zdorpgai_to_mod.txt')
        if not ipcFile then error('no file') end
        return { read = function() return ipcFile end, close = function() end }
    end,
}
package.loaded['openmw.world'] = { activeActors = {} }
package.loaded['openmw_aux.calendar'] = {
    formatGameTime = function(format)
        if format == '%d %B, %H:%M' then return '16 Last Seed, 14:05' end
        if format == '%H:%M' then return '14:05' end
        return '14:05, 16 Last Seed 3E 427'
    end,
}

-- Player-side stubs
local pressed = {}
local uiMode = nil
local created, messages = {}, {}
local storageSections = {}
package.loaded['openmw.input'] = { KEY = KEY, isKeyPressed = function(code) return pressed[code] == true end }
local modeCalls = {}
package.loaded['openmw.interfaces'] = {
    UI = {
        getMode = function() return uiMode end,
        setMode = function(mode, options) uiMode = mode; modeCalls[#modeCalls + 1] = 'set ' .. mode end,
        removeMode = function(mode) if uiMode == mode then uiMode = nil end; modeCalls[#modeCalls + 1] = 'remove ' .. mode end,
    },
    MWUI = { templates = { boxSolid = { name = 'boxSolid' }, textEditLine = { name = 'textEditLine' }, textHeader = { name = 'textHeader' }, textNormal = { name = 'textNormal' } } },
}
package.loaded['openmw.async'] = { callback = function(_, fn) return fn end }
package.loaded['openmw.camera'] = { getPosition = function() return nil end, getViewTransform = function() return nil end }
package.loaded['openmw.nearby'] = { castRenderingRay = function() return nil end }
package.loaded['openmw.self'] = { object = player }
package.loaded['openmw.storage'] = {
    playerSection = function(name)
        storageSections[name] = storageSections[name] or {}
        local data = storageSections[name]
        return { get = function(_, k) return data[k] end, set = function(_, k, v) data[k] = v end }
    end,
}
package.loaded['openmw.ui'] = {
    TYPE = { Text = 'Text' },
    ALIGNMENT = { Start = 'Start', Center = 'Center', End = 'End' },
    screenSize = function() return { x = 1920, y = 1080 } end,
    showMessage = function(text) messages[#messages + 1] = text end,
    content = function(list) return list end,
    create = function(layout)
        local el = { layout = layout, destroyed = false }
        function el:destroy() self.destroyed = true end
        created[#created + 1] = el
        return el
    end,
}

-- Load the scripts
local globalScript = dofile(MOD .. '/scripts/zdorpgai/global.lua')
local playerScript = dofile(MOD .. '/scripts/zdorpgai/player.lua')
globalHandlers = globalScript.eventHandlers
player.handlers = playerScript.eventHandlers

local g = globalScript.engineHandlers
g.onActorActive(fargoth)
g.onActorActive(arrille)

local msgId = 0
local function deliver(session, list)
    for _, m in ipairs(list) do
        msgId = msgId + 1
        m.id = msgId
    end
    -- The client keeps unacked messages in the file; the mod skips the ones it has seen
    setIncoming(session, list)
    for _ = 1, 5 do g.onUpdate(0.016) end
end

local function frame()
    realTime = realTime + 0.016
    playerScript.engineHandlers.onFrame(0.016)
end

local function visibleLog()
    for i = #created, 1, -1 do
        local el = created[i]
        if not el.destroyed and el.layout.props.position.x == 20 and el.layout.props.position.y == 20 then
            return el
        end
    end
    return nil
end

local function pressKey(code)
    pressed[code] = true; frame()
    pressed[code] = nil; frame()
end

local function lastMessage() return messages[#messages] end

local function logText() local el = visibleLog(); return el and el.layout.props.text end
local function logPage()
    local text = logText()
    if not text then return nil end
    return text:find('^Разговор') and 'conversation' or 'events'
end
-- Presses the log key until the page shows
local function showPage(page)
    for _ = 1, 3 do
        if logPage() == page then return end
        pressKey(KEY.K)
    end
end

-- 1. The key from the client reaches the player script and its storage; the player appears later
deliver('s1', { { type = 'SetEventLogKey', data = { key = 'K' } } })
g.onPlayerAdded(player)
check(storageSections.ZdorpgEventLog and storageSections.ZdorpgEventLog.key == 'K', 'event log key stored', storageSections.ZdorpgEventLog and storageSections.ZdorpgEventLog.key)

-- 2. Fargoth gives the player a torch
deliver('s1', { { type = 'TransferItem', data = { fromCharacterId = 'fargoth', toCharacterId = 'player', itemId = 'torch', count = 1 } } })
check(lastMessage() == 'Фаргот даёт вам: Факел', 'received item toast', lastMessage())
check(player.inv:countOf('torch') == 1, 'torch moved to the player')

-- 3. The player pays Arrille 20 gold
deliver('s1', { { type = 'TransferItem', data = { fromCharacterId = 'player', toCharacterId = 'arrille', itemId = 'gold_001', count = 20 } } })
check(lastMessage() == 'Арриль получает от вас: Золото x20', 'given gold toast', lastMessage())

-- 4. A refused transfer logs nothing
local before = #messages
deliver('s1', { { type = 'TransferItem', data = { fromCharacterId = 'fargoth', toCharacterId = 'player', itemId = 'torch', count = 1 } } })
check(#messages == before, 'no toast for a refused transfer', lastMessage())
local refused = printed[#printed - 1] or ''
check(refused:find('"success":false', 1, true) ~= nil, 'refusal still answered', refused)

-- 5. Disposition with and without a reason
deliver('s1', { { type = 'ModifyDisposition', data = { npcId = 'fargoth', playerId = 'player', delta = 5, reason = 'искреннее извинение' } } })
check(lastMessage() == 'Фаргот: отношение +5 (искреннее извинение)', 'disposition toast with reason', lastMessage())
deliver('s1', { { type = 'ModifyDisposition', data = { npcId = 'arrille', playerId = 'player', delta = -3 } } })
check(lastMessage() == 'Арриль: отношение -3', 'disposition toast without reason', lastMessage())

-- 6. Follow and attack
deliver('s1', { { type = 'NpcStartFollowCharacter', data = { npcId = 'fargoth', targetCharacterId = 'player' } } })
check(lastMessage() == 'Фаргот идёт с вами', 'follow toast', lastMessage())
deliver('s1', { { type = 'NpcStopFollowCharacter', data = { npcId = 'fargoth' } } })
check(lastMessage() == 'Фаргот больше не идёт с вами', 'stop following toast', lastMessage())
deliver('s1', { { type = 'NpcAttack', data = { npcId = 'arrille', targetCharacterId = 'player' } } })
check(lastMessage() == 'Арриль нападает на вас!', 'attack toast', lastMessage())
deliver('s1', { { type = 'NpcStopAttack', data = { npcId = 'arrille' } } })
check(lastMessage() == 'Арриль прекращает бой', 'stop attacking toast', lastMessage())

-- 7. Tasks: two given, one done
deliver('s1', {
    { type = 'TaskUpdate', data = { npcId = 'fargoth', description = 'извиниться перед Селлусом', status = 'Open', taskId = 1, reward = 'факел' } },
    { type = 'TaskUpdate', data = { npcId = 'arrille', description = 'принести две шкуры скампа', status = 'Open', taskId = 2 } },
})
check(messages[#messages - 1] == 'Новое поручение от Фаргот: извиниться перед Селлусом (награда: факел)', 'new task toast with reward', messages[#messages - 1])
check(lastMessage() == 'Новое поручение от Арриль: принести две шкуры скампа', 'new task toast without reward', lastMessage())
deliver('s1', { { type = 'TaskUpdate', data = { npcId = 'fargoth', description = 'извиниться перед Селлусом', status = 'Done', taskId = 1, reward = 'факел' } } })
check(lastMessage() == 'Поручение для Фаргот выполнено: извиниться перед Селлусом', 'task done toast', lastMessage())

-- 8. The log key toggles the window: open tasks, then recent entries newest first
pressKey(KEY.L)
check(visibleLog() == nil, 'the old default key does nothing once the client set another')
pressKey(KEY.K)
local log = visibleLog()
check(log ~= nil, 'log shows on the key')
local text = log and log.layout.props.text or ''
local expected = table.concat({
    'Открытые поручения',
    'Арриль: принести две шкуры скампа',
    '',
    'Недавнее',
    '16 Last Seed, 14:05 - Поручение для Фаргот выполнено: извиниться перед Селлусом',
    '16 Last Seed, 14:05 - Новое поручение от Арриль: принести две шкуры скампа',
    '16 Last Seed, 14:05 - Новое поручение от Фаргот: извиниться перед Селлусом (награда: факел)',
    '16 Last Seed, 14:05 - Арриль прекращает бой',
    '16 Last Seed, 14:05 - Арриль нападает на вас!',
    '16 Last Seed, 14:05 - Фаргот больше не идёт с вами',
    '16 Last Seed, 14:05 - Фаргот идёт с вами',
    '16 Last Seed, 14:05 - Арриль: отношение -3',
    '16 Last Seed, 14:05 - Фаргот: отношение +5 (искреннее извинение)',
    '16 Last Seed, 14:05 - Арриль получает от вас: Золото x20',
    '16 Last Seed, 14:05 - Фаргот даёт вам: Факел',
    '',
    'K — разговор',
}, '\n')
check(text == expected, 'log text', '\n' .. text)
check(log and log.layout.props.multiline == true and log.layout.layer == 'HUD', 'log is a multiline HUD text')

-- 9. A new event while the log is open redraws it
deliver('s1', { { type = 'TaskUpdate', data = { npcId = 'arrille', description = 'принести две шкуры скампа', status = 'Cancelled', taskId = 2 } } })
local redrawn = visibleLog()
check(redrawn ~= nil and redrawn ~= log and log.destroyed, 'log redrawn on a new event')
check(redrawn and not redrawn.layout.props.text:find('Открытые поручения', 1, true), 'no open tasks section once all are closed', redrawn and redrawn.layout.props.text)

-- 10. Not in menus or the console; then the conversation, then hidden
uiMode = 'Console'
pressKey(KEY.K)
check(logPage() == 'events', 'key ignored while the console is open', logPage())
uiMode = nil
pressKey(KEY.K)
check(logPage() == 'conversation', 'second press shows the conversation', logText())
check(logText() == 'Разговор\nПока никто ничего не сказал.\n\nK — закрыть', 'empty conversation page', logText())
pressKey(KEY.K)
check(visibleLog() == nil, 'third press hides the log')

-- 11. Holding the key toggles once
pressed[KEY.K] = true; frame(); frame(); frame()
pressed[KEY.K] = nil; frame()
check(visibleLog() ~= nil, 'holding the key toggles only once')

-- 12. Save and load keep the log; an old save loads an empty one
local saved = playerScript.engineHandlers.onSave()
check(visibleLog() == nil, 'save closes the window')
check(saved.logEntries and #saved.logEntries == 12 and saved.openTasks and #saved.openTasks == 0, 'save holds the log', saved.logEntries and #saved.logEntries)
playerScript.engineHandlers.onLoad(nil)
showPage('events')
check(logText() == 'Недавнее\nПока ничего.\n\nK — разговор', 'old save: empty log', logText())
showPage(nil)
playerScript.engineHandlers.onLoad(saved)
showPage('events')
check(logText() and logText():find('Фаргот даёт вам: Факел', 1, true), 'loaded log restored')
showPage(nil)

-- 13. The log keeps the last 50 entries and shows 12
for i = 1, 60 do
    deliver('s1', { { type = 'ModifyDisposition', data = { npcId = 'fargoth', playerId = 'player', delta = 1, reason = 'r' .. i } } })
end
showPage('events')
local lines = {}
for line in (visibleLog().layout.props.text .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = line end
check(#lines == 15, 'shows the 12 newest entries', #lines)
check(lines[2] == '16 Last Seed, 14:05 - Фаргот: отношение +1 (r60)', 'newest first', lines[2])
local saved2 = playerScript.engineHandlers.onSave()
check(#saved2.logEntries == 50, 'keeps 50 entries', #saved2.logEntries)

-- 14. A new session (client restart) still delivers; unknown keys are reported, not fatal
deliver('s2', { { type = 'SetEventLogKey', data = { key = 'NoSuchKey' } } })
local reported = false
for _, line in ipairs(printed) do if line:find('Unknown event log key: NoSuchKey', 1, true) then reported = true end end
check(reported, 'unknown key reported')
pressKey(KEY.K)
check(visibleLog() == nil, 'no key, no toggle')

-- 14b. A quest that moves on rewrites its open task instead of adding one
deliver('s2', { { type = 'SetEventLogKey', data = { key = 'K' } } })
deliver('s2', {
    { type = 'TaskUpdate', data = { npcId = 'arrille', description = 'Весть для Кая: найти Кая в Балморе', status = 'Open', taskId = 7, reward = '30 золота' } },
    { type = 'TaskUpdate', data = { npcId = 'arrille', description = 'Весть для Кая: вернуться к Арриль', status = 'Updated', taskId = 7, reward = '30 золота' } },
})
check(lastMessage() == 'Дальше по поручению Арриль: Весть для Кая: вернуться к Арриль', 'quest update toast', lastMessage())
showPage('events')
check(logText():find('Открытые поручения\nАрриль: Весть для Кая: вернуться к Арриль (награда: 30 золота)\n', 1, true), 'the open task reads the next step', logText())
showPage(nil)
deliver('s2', { { type = 'TaskUpdate', data = { npcId = 'arrille', description = 'Весть для Кая', status = 'Done', taskId = 7 } } })
showPage('events')
check(not logText():find('Открытые поручения', 1, true), 'done quest leaves the open tasks', logText())
showPage(nil)

-- 15. Who said what goes into the conversation: NPCs, banter with whom it was for, the player's speech
deliver('s2', { { type = 'SetEventLogKey', data = { key = 'K' } } })
deliver('s2', {
    { type = 'SayMp3File', data = { npcId = 'fargoth', mp3Name = 'a.mp3', text = 'Ты кто такой?', durationSec = 1.5 } },
    { type = 'SayMp3File', data = { npcId = 'fargoth', mp3Name = 'b.mp3', text = 'Слыхал новость?', targetId = 'arrille' } },
})
globalHandlers.ZdorpgTargetChanged({ playerId = 'player', npcId = 'fargoth' })
deliver('s2', { { type = 'SpeechRecognitionComplete', data = { playerId = 'player', text = 'Я ищу Кая.' } } })
showPage('conversation')
check(logText() == table.concat({
    'Разговор',
    '14:05 Фаргот: Ты кто такой?',
    '14:05 Фаргот → Арриль: Слыхал новость?',
    '14:05 Вы → Фаргот: Я ищу Кая.',
    '',
    'K — закрыть',
}, '\n'), 'conversation page', logText())
deliver('s2', { { type = 'SayMp3File', data = { npcId = 'arrille', mp3Name = 'c.mp3', text = 'Нет.' } } })
check(logText() and logText():find('14:05 Арриль: Нет.', 1, true), 'a new line shows while the page is open', logText())
showPage(nil)

local json = require('scripts.zdorpgai.json')
-- The messages the mod sent since `from`, decoded
local function sentSince(from, msgType)
    local found = {}
    for i = from + 1, #printed do
        local body = printed[i]:match('^%[ZDORPG_MSG%](.*)$')
        if body then
            local msg = json.decode(body)
            if msg.type == msgType then found[#found + 1] = msg end
        end
    end
    return found
end

-- 16. The text line: the key opens it with the game paused, Enter says the line to the NPC in front
local before = #printed
pressKey(KEY.Enter)
check(uiMode == 'Interface', 'typing pauses the game with the cursor out', uiMode)
local box = created[#created]
local rows = box and box.layout.content and box.layout.content[1].content
check(box.layout.template.name == 'boxSolid' and rows and rows[2].template.name == 'textEditLine', 'a box with a line to type in')
check(rows and (rows[1].props.text == 'Кому: кто рядом' or rows[1].props.text == 'Кому: Фаргот'), 'the header says to whom', rows and rows[1].props.text)
check(rows and rows[3].props.text == 'Кликни по строке и пиши. Enter — сказать, Esc — закрыть.', 'the hint', rows and rows[3].props.text)
pressed[KEY.Y] = true; frame(); frame()
pressed[KEY.Y] = nil; frame()
check(#sentSince(before, 'PushToTalk') == 0, 'typing Y is not push-to-talk')
rows[2].events.textChanged('  Где Кай Косадес?  ')
rows[2].events.keyPress({ code = KEY.Enter })
frame()
check(uiMode == nil and box.destroyed, 'Enter closes the line and the game goes on', uiMode)
local said = sentSince(before, 'PlayerSpeaksText')
check(#said == 1 and said[1].data.text == 'Где Кай Косадес?' and said[1].data.targetCharacterId == 'fargoth'
    and said[1].data.playerId == 'player' and said[1].data.gameTime == '14:05, 16 Last Seed 3E 427', 'the line goes to the server for Fargoth',
    said[1] and json.encode(said[1].data))
local fargothHold = fargoth.events[#fargoth.events]
check(fargothHold.name == 'ZdorpgHold', 'Fargoth stops to listen', fargothHold.name)
showPage('conversation')
check(logText():find('14:05 Вы → Фаргот: Где Кай Косадес?', 1, true), 'the typed line is in the conversation', logText())
showPage(nil)

-- 17. Esc (the game leaving the mode) closes the line unsent; a blank line isn't sent either
before = #printed
pressKey(KEY.Enter)
local box2 = created[#created]
box2.layout.content[1].content[2].events.textChanged('не надо')
uiMode = nil
frame()
check(box2.destroyed, 'Esc closes the line')
pressKey(KEY.Enter)
local box3 = created[#created]
box3.layout.content[1].content[2].events.textChanged('   ')
box3.layout.content[1].content[2].events.keyPress({ code = KEY.NumpadEnter })
check(box3.destroyed and uiMode == nil, 'the keypad Enter closes it too')
check(#sentSince(before, 'PlayerSpeaksText') == 0, 'nothing sent')

-- 18. Not over another window
uiMode = 'Inventory'
local count = #created
pressKey(KEY.Enter)
check(#created == count and uiMode == 'Inventory', 'no line over the inventory')
uiMode = nil

-- 19. The client sets the key; the old one stops working
deliver('s2', { { type = 'SetTextInputKey', data = { key = 'K' } } })
check(storageSections.ZdorpgTextInput and storageSections.ZdorpgTextInput.key == 'K', 'text input key stored')
count = #created
pressKey(KEY.Enter)
check(#created == count and uiMode == nil, 'Enter no longer opens it')
deliver('s2', { { type = 'SetTextInputKey', data = { key = 'Enter' } } })

-- 20. The conversation keeps 50 lines, shows 14 and lives in the save
for i = 1, 55 do
    deliver('s2', { { type = 'SayMp3File', data = { npcId = 'arrille', mp3Name = 'x.mp3', text = 'Реплика ' .. i } } })
end
local saved3 = playerScript.engineHandlers.onSave()
check(#saved3.conversation == 50 and saved3.conversation[50].text == 'Реплика 55', 'keeps 50 lines', #saved3.conversation)
showPage('conversation')
local shown = {}
for line in (logText() .. '\n'):gmatch('([^\n]*)\n') do shown[#shown + 1] = line end
check(#shown == 17 and shown[2] == '14:05 Арриль: Реплика 42' and shown[15] == '14:05 Арриль: Реплика 55', 'shows the 14 latest, oldest first', logText())
showPage(nil)
playerScript.engineHandlers.onLoad(nil)
showPage('conversation')
check(logText() == 'Разговор\nПока никто ничего не сказал.\n\nK — закрыть', 'an old save loads an empty conversation', logText())
showPage(nil)
playerScript.engineHandlers.onLoad(saved3)
showPage('conversation')
check(logText():find('Реплика 55', 1, true), 'the conversation comes back with the save')
showPage(nil)

-- 21. Cell changes: named cells by name, the wilds by region, and no news within one region
before = #printed
player.cell = { name = 'Seyda Neen, Arrille\'s Tradehouse' }
deliver('s2', {})
player.cell = { name = '', region = 'bitter coast region', id = 'Bitter Coast Region (-2, -9)' }
deliver('s2', {})
player.cell = { name = '', region = 'bitter coast region', id = 'Bitter Coast Region (-3, -9)' }
deliver('s2', {})
local cells = {}
for _, msg in ipairs(sentSince(before, 'CellChange')) do cells[#cells + 1] = msg.data.cellName end
check(table.concat(cells, ' | ') == "Seyda Neen, Arrille's Tradehouse | Горький берег", 'cell changes', table.concat(cells, ' | '))

for _, line in ipairs(printed) do
    if line:find('Error', 1, true) or line:find('failed', 1, true) then io.stdout:write('LOG: ' .. line .. '\n') end
end
io.stdout:write(string.format('%d passed, %d failed\n', passes, failures))
os.exit(failures == 0 and 0 or 1)
