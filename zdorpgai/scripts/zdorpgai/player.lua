-- ZDORPG Player Script
-- Handles raycasting for NPC target detection, voice playback, HUD speech

local async = require('openmw.async')
local camera = require('openmw.camera')
local core = require('openmw.core')
local input = require('openmw.input')
local I = require('openmw.interfaces')
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local storage = require('openmw.storage')
local types = require('openmw.types')
local ui = require('openmw.ui')
local util = require('openmw.util')

local L = core.l10n('zdorpgai')

-- State
local TARGET_CHECK_FRAMES = 10
local frameCounter = 0
local lastTargetId = nil
local speechHideTime = nil
local listeningHideTime = nil

-- An openmw.input.KEY name as a key code; nil if there is no such key
local function keyCode(name, what)
    local ok, code = pcall(function() return input.KEY[name] end)
    if ok and code then return code end
    print('[ZDORPG] Unknown ' .. what .. ' key: ' .. tostring(name))
    return nil
end

-- Push-to-talk: the game itself watches the key, so it works on any OS and under Wayland. The
-- client says which key (an openmw.input.KEY name); it is remembered across game sessions.
local pushToTalkStorage = storage.playerSection('ZdorpgPushToTalk')
local pushToTalkCode = keyCode(pushToTalkStorage:get('key') or 'Y', 'push-to-talk')
local pushToTalkPressed = false

-- Event log: what NPCs did for or to the player (items and gold, tasks, disposition) shows as a
-- notification and in a list that the event log key shows and hides. The list is kept in the
-- save, so after a load it matches the inventory again.
local MAX_LOG_ENTRIES = 50
local SHOWN_LOG_ENTRIES = 12
local eventLogStorage = storage.playerSection('ZdorpgEventLog')
local eventLogCode = keyCode(eventLogStorage:get('key') or 'L', 'event log')
local eventLogKeyDown = false
-- The log window's page: 'events', 'conversation', or nil when it's hidden. The key goes through
-- them in turn.
local logPage = nil
local logEntries = {} -- { time, text }, oldest first
local openTasks = {} -- { id, npc, task, reward }

-- Conversation log: the latest lines said to and around the player, kept in the save too
local MAX_CONVERSATION_LINES = 50
local SHOWN_CONVERSATION_LINES = 14
local conversation = {} -- { time, who, to, text, player }, oldest first

-- Typing instead of speaking: the key opens a line to write in, Enter says it to the NPC in front
local textInputStorage = storage.playerSection('ZdorpgTextInput')
local textInputCode = keyCode(textInputStorage:get('key') or 'Enter', 'text input')
local textInputKeyDown = false
local typing = false
local typedText = ''

local function checkPushToTalk()
    -- Letters typed into the text line aren't push-to-talk
    local pressed = not typing and pushToTalkCode ~= nil and input.isKeyPressed(pushToTalkCode)
    if pressed ~= pushToTalkPressed then
        pushToTalkPressed = pressed
        core.sendGlobalEvent('ZdorpgPushToTalk', { pressed = pressed })
    end
end

-- Typewriter animation state
local DEFAULT_CHARS_PER_SEC = 18
local speechAnimPrefix = nil
local speechAnimText = nil
local speechAnimCharOffsets = nil  -- byte offset of end of each UTF-8 char
local speechAnimStart = nil
local speechAnimRevealed = 0
local speechAnimCharsPerSec = DEFAULT_CHARS_PER_SEC
local speechAnimHoldDuration = nil  -- how long text stays after fully revealed

--- Build table of byte offsets marking the end of each UTF-8 character.
local function utf8CharOffsets(s)
    local offsets = {}
    local i = 1
    while i <= #s do
        local b = string.byte(s, i)
        local charLen
        if b < 0x80 then charLen = 1
        elseif b < 0xE0 then charLen = 2
        elseif b < 0xF0 then charLen = 3
        else charLen = 4 end
        i = i + charLen
        offsets[#offsets + 1] = i - 1
    end
    return offsets
end

-------------------------------------------------------------------------------
-- Target detection (raycast)
-------------------------------------------------------------------------------

-- The name of the NPC the player looks at, for the text line's header
local lastTargetObject = nil

local function checkTarget()
    local ok, pos = pcall(camera.getPosition)
    if not ok or not pos then return end

    local okDir, viewTransform = pcall(camera.getViewTransform)
    if not okDir or not viewTransform then return end

    local invView = viewTransform:inverse()
    local forward = invView:apply(util.vector3(0, 0, -1))
    local dir = (forward - pos):normalize()
    local to = pos + dir * 2000

    local okRay, result = pcall(nearby.castRenderingRay, pos, to)
    if not okRay then return end

    local targetId = nil
    local targetObject = nil
    if result and result.hitObject and result.hitObject ~= self.object then
        local okCheck, isNpc = pcall(types.NPC.objectIsInstance, result.hitObject)
        if okCheck and isNpc then
            targetId = result.hitObject.recordId
            targetObject = result.hitObject
        end
    end
    if targetObject or not typing then
        lastTargetObject = targetObject
    end

    if targetId ~= lastTargetId then
        lastTargetId = targetId
        print('[ZDORPG_DEBUG] Target changed: ' .. tostring(targetId))
        core.sendGlobalEvent('ZdorpgTargetChanged', {
            playerId = self.object.recordId,
            npcId = targetId,
        })
    end
end

-------------------------------------------------------------------------------
-- UI elements — destroyed and recreated on every text change for robustness
-------------------------------------------------------------------------------

local speechElement = nil
local listeningElement = nil
local eventLogElement = nil
local textInputElement = nil

local SPEECH_PADDING = 80

local function destroyElements()
    if speechElement then
        speechElement:destroy()
        speechElement = nil
    end
    if listeningElement then
        listeningElement:destroy()
        listeningElement = nil
    end
    if eventLogElement then
        eventLogElement:destroy()
        eventLogElement = nil
    end
end

local function setSpeechText(text)
    if speechElement then
        speechElement:destroy()
    end
    local screenWidth = ui.screenSize().x
    local maxWidth = screenWidth - SPEECH_PADDING * 2
    speechElement = ui.create {
        layer = 'HUD',
        type = ui.TYPE.Text,
        props = {
            relativePosition = util.vector2(0.5, 1),
            anchor = util.vector2(0.5, 1),
            position = util.vector2(0, -80),
            -- size = util.vector2(maxWidth, 300),
            size = util.vector2(800, 300),
            autoSize = false,
            text = text,
            textSize = 16,
            textColor = util.color.rgb(0.871, 0.867, 0.667),
            wordWrap = true,
            textAlignH = ui.ALIGNMENT.Center,
            textAlignV = ui.ALIGNMENT.End,
        },
    }
end

local function setListeningText(text)
    if listeningElement then
        listeningElement:destroy()
    end
    local screenWidth = ui.screenSize().x
    listeningElement = ui.create {
        layer = 'HUD',
        type = ui.TYPE.Text,
        props = {
            relativePosition = util.vector2(1, 1),
            anchor = util.vector2(1, 1),
            position = util.vector2(-20, -200),
            -- size = util.vector2(screenWidth * 0.3, 300),
            size = util.vector2(800, 300),
            autoSize = false,
            text = text,
            textSize = 16,
            textColor = util.color.rgb(0.871, 0.867, 0.667),
            wordWrap = true,
            textAlignH = ui.ALIGNMENT.End,
            textAlignV = ui.ALIGNMENT.End,
        },
    }
end

-------------------------------------------------------------------------------
-- Speech bubble
-------------------------------------------------------------------------------

local function stopSpeechAnim()
    speechAnimPrefix = nil
    speechAnimText = nil
    speechAnimCharOffsets = nil
    speechAnimStart = nil
    speechAnimRevealed = 0
    speechAnimCharsPerSec = DEFAULT_CHARS_PER_SEC
    speechAnimHoldDuration = nil
end

local function showSpeech(npcName, text, animate, duration)
    stopSpeechAnim()
    speechHideTime = nil

    local prefix = npcName .. ': '

    if not duration then
        duration = math.max(2, #(prefix .. text) / 30)
    end

    if animate then
        speechAnimPrefix = prefix
        speechAnimText = text
        speechAnimCharOffsets = utf8CharOffsets(text)
        speechAnimStart = core.getRealTime()
        speechAnimRevealed = 0

        local numChars = #speechAnimCharOffsets
        if numChars > 0 and duration > 0 then
            -- Reveal all characters over the full audio duration, then hold 3s extra
            speechAnimCharsPerSec = numChars / duration
            speechAnimHoldDuration = 3
        else
            speechAnimCharsPerSec = DEFAULT_CHARS_PER_SEC
            speechAnimHoldDuration = 3
        end

        setSpeechText(prefix)
    else
        setSpeechText(prefix .. text)
        speechHideTime = core.getRealTime() + duration
    end
end

local function hideSpeech()
    stopSpeechAnim()
    speechHideTime = nil
    setSpeechText('')
end

-------------------------------------------------------------------------------
-- Listening indicator
-------------------------------------------------------------------------------

local function showListening(text)
    setListeningText(text or L('listening'))
    listeningHideTime = core.getRealTime() + 4
end

local function hideListening()
    listeningHideTime = nil
    setListeningText('')
end

-------------------------------------------------------------------------------
-- Event log
-------------------------------------------------------------------------------

-- Open tasks first, then the latest entries, newest on top
local function eventLogText()
    local lines = {}
    if #openTasks > 0 then
        lines[#lines + 1] = L('logTasks')
        for _, task in ipairs(openTasks) do
            local line = task.npc .. ': ' .. task.task
            if task.reward and task.reward ~= '' then
                line = line .. ' (' .. L('logReward', { reward = task.reward }) .. ')'
            end
            lines[#lines + 1] = line
        end
        lines[#lines + 1] = ''
    end

    lines[#lines + 1] = L('logRecent')
    if #logEntries == 0 then
        lines[#lines + 1] = L('logEmpty')
    end
    for i = #logEntries, math.max(1, #logEntries - SHOWN_LOG_ENTRIES + 1), -1 do
        local entry = logEntries[i]
        lines[#lines + 1] = entry.time and (entry.time .. ' - ' .. entry.text) or entry.text
    end
    return table.concat(lines, '\n')
end

-- The last lines, oldest first, like a chat
local function conversationText()
    local lines = { L('logConversation') }
    if #conversation == 0 then
        lines[#lines + 1] = L('logConversationEmpty')
    end
    for i = math.max(1, #conversation - SHOWN_CONVERSATION_LINES + 1), #conversation do
        local line = conversation[i]
        local who = line.player and L('logYou') or (line.who or '?')
        if line.to and line.to ~= '' then
            who = who .. ' → ' .. line.to
        end
        lines[#lines + 1] = (line.time and (line.time .. ' ') or '') .. who .. ': ' .. (line.text or '')
    end
    return table.concat(lines, '\n')
end

local function logWindowText()
    local key = eventLogStorage:get('key') or 'L'
    if logPage == 'conversation' then
        return conversationText() .. '\n\n' .. L('logHintClose', { key = key })
    end
    return eventLogText() .. '\n\n' .. L('logHintConversation', { key = key })
end

local function renderEventLog()
    if eventLogElement then
        eventLogElement:destroy()
        eventLogElement = nil
    end
    if not logPage then return end
    eventLogElement = ui.create {
        layer = 'HUD',
        type = ui.TYPE.Text,
        props = {
            relativePosition = util.vector2(0, 0),
            anchor = util.vector2(0, 0),
            position = util.vector2(20, 20),
            size = util.vector2(640, 600),
            autoSize = false,
            text = logWindowText(),
            textSize = 16,
            textColor = util.color.rgb(0.871, 0.867, 0.667),
            textShadow = true,
            textShadowColor = util.color.rgb(0, 0, 0),
            multiline = true,
            wordWrap = true,
            textAlignH = ui.ALIGNMENT.Start,
            textAlignV = ui.ALIGNMENT.Start,
        },
    }
end

local NEXT_LOG_PAGE = { events = 'conversation', conversation = nil }

-- The key goes events, conversation, hidden; not while a menu or the console has the keyboard
local function checkEventLogKey()
    local down = eventLogCode ~= nil and input.isKeyPressed(eventLogCode)
    if down and not eventLogKeyDown and not I.UI.getMode() then
        if logPage then
            logPage = NEXT_LOG_PAGE[logPage]
        else
            logPage = 'events'
        end
        renderEventLog()
    end
    eventLogKeyDown = down
end

-------------------------------------------------------------------------------
-- Text line: typing instead of speaking
-------------------------------------------------------------------------------

local function closeTextInput()
    typing = false
    if textInputElement then
        textInputElement:destroy()
        textInputElement = nil
    end
    if I.UI.getMode() == 'Interface' then
        I.UI.removeMode('Interface')
    end
end

local function submitTypedText()
    local text = string.match(typedText or '', '^%s*(.-)%s*$')
    closeTextInput()
    if text ~= '' then
        core.sendGlobalEvent('ZdorpgPlayerTyped', { text = text })
    end
end

local function targetName()
    local ok, record = pcall(function() return types.NPC.record(lastTargetObject) end)
    return ok and record and record.name or nil
end

-- The game pauses with the cursor out; Lua can't put the keyboard into the line by itself, so
-- the player clicks it first
local function openTextInput()
    typedText = ''
    typing = true
    I.UI.setMode('Interface', { windows = {} })
    local name = targetName()
    textInputElement = ui.create {
        layer = 'Windows',
        template = I.MWUI.templates.boxSolid,
        props = {
            relativePosition = util.vector2(0.5, 0.78),
            anchor = util.vector2(0.5, 0.5),
        },
        content = ui.content {
            {
                props = { size = util.vector2(640, 82) },
                content = ui.content {
                    {
                        template = I.MWUI.templates.textHeader,
                        props = {
                            position = util.vector2(10, 6),
                            text = name and L('typeTo', { npc = name }) or L('typeToAnyone'),
                        },
                    },
                    {
                        template = I.MWUI.templates.textEditLine,
                        props = {
                            position = util.vector2(10, 30),
                            size = util.vector2(620, 24),
                            text = '',
                        },
                        events = {
                            textChanged = async:callback(function(text) typedText = text end),
                            keyPress = async:callback(function(e)
                                if e.code == input.KEY.Enter or e.code == input.KEY.NumpadEnter then
                                    submitTypedText()
                                end
                            end),
                        },
                    },
                    {
                        template = I.MWUI.templates.textNormal,
                        props = {
                            position = util.vector2(10, 58),
                            text = L('typeHint'),
                        },
                    },
                },
            },
        },
    }
end

-- The key opens the line; Esc, or any other window taking over, closes it unsent
local function checkTextInputKey()
    local down = textInputCode ~= nil and input.isKeyPressed(textInputCode)
    if typing then
        if I.UI.getMode() ~= 'Interface' then
            closeTextInput()
        end
    elseif down and not textInputKeyDown and not I.UI.getMode() then
        openTextInput()
    end
    textInputKeyDown = down
end

-------------------------------------------------------------------------------
-- Engine handlers
-------------------------------------------------------------------------------

local function onFrame(dt)
    checkPushToTalk()
    checkEventLogKey()
    checkTextInputKey()

    -- Typewriter animation (UTF-8 aware)
    if speechAnimText then
        local numChars = #speechAnimCharOffsets
        local elapsed = core.getRealTime() - speechAnimStart
        local target = math.min(math.floor(elapsed * speechAnimCharsPerSec) + 1, numChars)
        if target ~= speechAnimRevealed then
            speechAnimRevealed = target
            local byteEnd = speechAnimCharOffsets[target]
            setSpeechText(speechAnimPrefix .. string.sub(speechAnimText, 1, byteEnd))
        end
        if target >= numChars then
            speechHideTime = core.getRealTime() + speechAnimHoldDuration
            stopSpeechAnim()
        end
    end

    if speechHideTime and core.getRealTime() >= speechHideTime then
        hideSpeech()
    end

    if listeningHideTime and core.getRealTime() >= listeningHideTime then
        hideListening()
    end

    frameCounter = frameCounter + 1
    if frameCounter % TARGET_CHECK_FRAMES ~= 0 then return end
    pcall(checkTarget)
end

-------------------------------------------------------------------------------
-- Event handlers (from global script)
-------------------------------------------------------------------------------

local function onSayMp3(data)
    local npc = data.npc
    if npc then
        local okSay, err = pcall(function()
            core.sound.say('zdorpgai_mp3/' .. data.mp3Name, npc, data.text or '')
        end)
        if not okSay then
            print('[ZDORPG] Error playing voice: ' .. tostring(err))
        end
    else
        print('[ZDORPG] NPC object not provided for voice')
    end
end

local function onShowSpeech(data)
    local duration = data.durationSec or (data.persistent and 9999 or nil)
    showSpeech(data.npcName or '???', data.text or '', data.animate, duration)
end

local function onHideSpeech(data)
    hideSpeech()
end

local function onShowListening(data)
    showListening(data.text)
end

local function onHideListening(data)
    hideListening()
end

local function onSetPushToTalkKey(data)
    if data and data.key then
        pushToTalkStorage:set('key', data.key)
        pushToTalkCode = keyCode(data.key, 'push-to-talk')
    end
end

local function onSetEventLogKey(data)
    if data and data.key then
        eventLogStorage:set('key', data.key)
        eventLogCode = keyCode(data.key, 'event log')
    end
end

local function onSetTextInputKey(data)
    if data and data.key then
        textInputStorage:set('key', data.key)
        textInputCode = keyCode(data.key, 'text input')
    end
end

-- A line said by an NPC or by the player (see logSaid in the global script)
local function onSaid(data)
    if not data or not data.text or data.text == '' then return end
    conversation[#conversation + 1] = { time = data.time, who = data.who, to = data.to, text = data.text, player = data.player == true }
    while #conversation > MAX_CONVERSATION_LINES do
        table.remove(conversation, 1)
    end
    if logPage == 'conversation' then
        renderEventLog()
    end
end

local function onNotify(data)
    ui.showMessage(data.text or '')
end

-- Updated: a quest moved on, the task now reads what to do next
local TASK_MESSAGES = { Open = 'taskNew', Updated = 'taskUpdated', Done = 'taskDone', Cancelled = 'taskCancelled' }
local ACTION_MESSAGES = {
    follow = 'logFollow', stopFollow = 'logStopFollow', attack = 'logAttack', stopAttack = 'logStopAttack',
}

-- "Torch", "Gold x50"
local function itemText(data)
    local count = tonumber(data.count) or 1
    local item = data.item or '?'
    return count > 1 and (item .. ' x' .. count) or item
end

-- The line for an event from the global script (see logEvent there), nil for an unknown one
local function eventText(data)
    local npc = data.npcName or ''
    if data.kind == 'received' then
        return L('logReceived', { npc = npc, item = itemText(data) })
    elseif data.kind == 'given' then
        return L('logGiven', { npc = npc, item = itemText(data) })
    elseif data.kind == 'disposition' then
        local text = L('logDisposition', { npc = npc, delta = string.format('%+d', math.floor(tonumber(data.delta) or 0)) })
        if data.reason and data.reason ~= '' then
            text = text .. ' (' .. data.reason .. ')'
        end
        return text
    elseif data.kind == 'task' then
        local key = TASK_MESSAGES[data.status]
        if not key then return nil end
        local text = L(key, { npc = npc, task = data.task or '' })
        if data.status == 'Open' and data.reward and data.reward ~= '' then
            text = text .. ' (' .. L('logReward', { reward = data.reward }) .. ')'
        end
        return text
    end
    local key = ACTION_MESSAGES[data.kind]
    return key and L(key, { npc = npc }) or nil
end

-- Without task ids (from an older server) tasks match by the NPC and the wording
local function sameTask(task, data)
    if task.id and data.taskId then return task.id == data.taskId end
    return task.npc == data.npcName and task.task == data.task
end

local function updateOpenTasks(data)
    if data.status == 'Open' then
        openTasks[#openTasks + 1] = { id = data.taskId, npc = data.npcName or '', task = data.task or '', reward = data.reward }
        return
    end
    if data.status == 'Updated' then
        for _, task in ipairs(openTasks) do
            if data.taskId and task.id == data.taskId then
                task.task = data.task or task.task
            end
        end
        return
    end
    for i = #openTasks, 1, -1 do
        if sameTask(openTasks[i], data) then
            table.remove(openTasks, i)
        end
    end
end

local function onLogEvent(data)
    local text = eventText(data or {})
    if not text then return end
    ui.showMessage(text)
    if data.kind == 'task' then
        updateOpenTasks(data)
    end
    logEntries[#logEntries + 1] = { time = data.time, text = text }
    while #logEntries > MAX_LOG_ENTRIES do
        table.remove(logEntries, 1)
    end
    if logPage == 'events' then
        renderEventLog()
    end
end

-------------------------------------------------------------------------------
-- Save / Load
-------------------------------------------------------------------------------

local function onSave()
    if typing then
        closeTextInput()
    end
    destroyElements()
    stopSpeechAnim()
    speechHideTime = nil
    listeningHideTime = nil
    logPage = nil
    return {
        lastTargetId = lastTargetId,
        logEntries = logEntries,
        openTasks = openTasks,
        conversation = conversation,
    }
end

local function onLoad(data)
    if data then
        lastTargetId = data.lastTargetId
    end
    -- Saves from before the event log or the conversation log load with empty ones
    logEntries = data and data.logEntries or {}
    openTasks = data and data.openTasks or {}
    conversation = data and data.conversation or {}
    if typing then
        closeTextInput()
    end
    destroyElements()
    stopSpeechAnim()
    speechHideTime = nil
    listeningHideTime = nil
    logPage = nil
end

-------------------------------------------------------------------------------
-- Script interface
-------------------------------------------------------------------------------

print('[ZDORPG] Player script loaded')

return {
    engineHandlers = {
        onFrame = onFrame,
        onSave = onSave,
        onLoad = onLoad,
    },
    eventHandlers = {
        ZdorpgSayMp3 = onSayMp3,
        ZdorpgShowSpeech = onShowSpeech,
        ZdorpgHideSpeech = onHideSpeech,
        ZdorpgShowListening = onShowListening,
        ZdorpgHideListening = onHideListening,
        ZdorpgNotify = onNotify,
        ZdorpgLogEvent = onLogEvent,
        ZdorpgSetPushToTalkKey = onSetPushToTalkKey,
        ZdorpgSetEventLogKey = onSetEventLogKey,
        ZdorpgSetTextInputKey = onSetTextInputKey,
        ZdorpgSaid = onSaid,
    },
}
