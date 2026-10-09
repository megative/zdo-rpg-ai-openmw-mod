-- ZDORPG Global Script
-- Handles IPC polling, command dispatch, world state tracking

local core = require('openmw.core')
local types = require('openmw.types')
local util = require('openmw.util')
local vfs = require('openmw.vfs')
local world = require('openmw.world')
local calendar = require('openmw_aux.calendar')

local ipc = require('scripts.zdorpgai.ipc')
local json = require('scripts.zdorpgai.json')

-- State
local POLL_INTERVAL_FRAMES = 5
local frameCounter = 0
local lastSeenClientMsgId = 0
local modMsgCounter = 0
local lastCellName = nil
local playerObject = nil
local activeNpcs = {}
local clientConnected = false
local currentSessionId = nil

-------------------------------------------------------------------------------
-- Outgoing helpers
-------------------------------------------------------------------------------

local function publish(msgType, data)
    modMsgCounter = ipc.sendMessage(msgType, data, nil, modMsgCounter)
end

local function respond(msgType, responseTo, data)
    modMsgCounter = ipc.sendMessage(msgType, data, responseTo, modMsgCounter)
end

-------------------------------------------------------------------------------
-- Character info gathering
-------------------------------------------------------------------------------

-- Display name of a record (class, region, ...), falling back to its id
local function recordName(store, id)
    if not id then return nil end
    local ok, record = pcall(function() return store.records[id] end)
    if ok and record and record.name and record.name ~= '' then return record.name end
    return id
end

-- The actor's faction and rank titles. Faction lookup follows waterbobo24's
-- Morrowind-llm-mod (github.com/waterbobo24/Morrowind-llm-mod).
local function getFaction(actor)
    local ok, factionIds = pcall(types.NPC.getFactions, actor)
    if not ok or not factionIds or #factionIds == 0 then return nil, nil end
    local factionId = factionIds[1]
    local okRec, faction = pcall(function() return core.factions.records[factionId] end)
    if not okRec or not faction then return factionId, nil end
    -- Ranks are 1-based; 0 means not a member
    local okRank, rank = pcall(types.NPC.getFactionRank, actor, factionId)
    local rankName = nil
    if okRank and rank and rank > 0 and faction.ranks and faction.ranks[rank] then
        rankName = faction.ranks[rank].name
    end
    return faction.name, rankName
end

local function getCharacterInfo(gameObject)
    local ok, record = pcall(types.NPC.record, gameObject)
    if not ok or not record then return nil end

    local health = types.Actor.stats.dynamic.health(gameObject)
    local faction, factionRank = getFaction(gameObject)

    return {
        objectId = gameObject.recordId,
        name = record.name,
        race = record.race,
        sex = record.isMale and 'male' or 'female',
        className = recordName(types.NPC.classes, record.class),
        faction = faction,
        factionRank = factionRank,
        isDead = types.Actor.isDead(gameObject),
        healthCurrent = health.current,
        healthMax = health.base,
    }
end

-------------------------------------------------------------------------------
-- Scene state: what an NPC can see right now
-------------------------------------------------------------------------------

-- Same format as waterbobo24's fork: "14:05, 16 Last Seed 3E 427"
local function currentGameTime()
    local ok, text = pcall(calendar.formatGameTime, '%H:%M, %d %B 3E %Y')
    return ok and text or nil
end

local function cellName(object)
    local ok, cell = pcall(function() return object.cell end)
    if not ok or not cell then return nil end
    if cell.name and cell.name ~= '' then return cell.name end
    -- Unnamed wilderness: fall back to the region
    return recordName(core.regions, cell.region) or cell.id
end

local function actorLevel(actor)
    local ok, level = pcall(function() return types.Actor.stats.level(actor).current end)
    return ok and level or 0
end

-- current/max of a dynamic stat (health, fatigue) in 0..1
local function dynamicRatio(stat, actor)
    local ok, value = pcall(stat, actor)
    if not ok or not value then return 1 end
    local max = value.base + (value.modifier or 0)
    if max <= 0 then return 1 end
    return math.max(0, math.min(1, value.current / max))
end

local function goldOf(actor)
    local ok, gold = pcall(function() return types.Actor.inventory(actor):countOf('gold_001') end)
    return ok and gold or 0
end

local function itemName(item)
    local ok, record = pcall(function() return item.type.record(item) end)
    if ok and record and record.name and record.name ~= '' then return record.name end
    return item.recordId
end

local function equippedItems(actor)
    local ok, equipment = pcall(types.Actor.getEquipment, actor)
    if not ok or not equipment then return {} end
    return equipment
end

local function equippedNames(actor)
    local names = json.array()
    for _, item in pairs(equippedItems(actor)) do
        names[#names + 1] = itemName(item)
    end
    table.sort(names)
    return names
end

-- Belongings besides gold and worn gear, most valuable first: what the NPC could give or sell
local function inventoryItems(actor, limit)
    local inventory = types.Actor.inventory(actor)
    pcall(function()
        if not inventory:isResolved() then inventory:resolve() end
    end)

    local equipped = {}
    for _, item in pairs(equippedItems(actor)) do
        equipped[item.id] = true
    end

    local byRecord = {}
    local list = {}
    for _, item in ipairs(inventory:getAll()) do
        if not equipped[item.id] and item.recordId ~= 'gold_001' then
            local entry = byRecord[item.recordId]
            if not entry then
                local okRec, record = pcall(function() return item.type.record(item) end)
                entry = {
                    id = item.recordId,
                    name = itemName(item),
                    count = 0,
                    value = (okRec and record and record.value) or 0,
                }
                byRecord[item.recordId] = entry
                list[#list + 1] = entry
            end
            entry.count = entry.count + item.count
        end
    end

    table.sort(list, function(a, b) return a.value * a.count > b.value * b.count end)
    local items = json.array()
    for i = 1, math.min(limit, #list) do
        items[i] = { id = list[i].id, name = list[i].name, count = list[i].count }
    end
    return items
end

-------------------------------------------------------------------------------
-- Incoming message handlers
-------------------------------------------------------------------------------

local function handleGetPlayerInfo(msg)
    if not playerObject then
        respond('GetPlayerInfo', msg.id, { error = 'no_player' })
        return
    end
    local info = getCharacterInfo(playerObject)
    if not info then
        respond('GetPlayerInfo', msg.id, { error = 'info_failed' })
        return
    end
    respond('GetPlayerInfo', msg.id, {
        objectId = info.objectId,
        name = info.name,
        race = info.race,
        sex = info.sex,
    })
end

local function handleGetNpcInfo(msg)
    local data = msg.data or {}
    if not data.npcId then
        respond('GetNpcInfo', msg.id, { error = 'missing_npcId' })
        return
    end
    local npc = activeNpcs[data.npcId]
    if not npc then
        respond('GetNpcInfo', msg.id, { error = 'not_found' })
        return
    end
    local info = getCharacterInfo(npc)
    if not info then
        respond('GetNpcInfo', msg.id, { error = 'info_failed' })
        return
    end
    respond('GetNpcInfo', msg.id, {
        objectId = info.objectId,
        name = info.name,
        race = info.race,
        sex = info.sex,
        className = info.className,
        faction = info.faction,
        factionRank = info.factionRank,
    })
end

local function handleGetSceneContext(msg)
    local data = msg.data or {}
    local response = {
        gameTime = currentGameTime(),
        cellName = playerObject and cellName(playerObject) or nil,
    }

    local npc = activeNpcs[data.npcId]
    if npc then
        response.npc = {
            level = actorLevel(npc),
            healthRatio = dynamicRatio(types.Actor.stats.dynamic.health, npc),
            gold = goldOf(npc),
            equipped = equippedNames(npc),
            items = inventoryItems(npc, 12),
        }
    end

    local info = playerObject and getCharacterInfo(playerObject)
    if info then
        response.player = {
            name = info.name,
            race = info.race,
            sex = info.sex,
            className = info.className,
            level = actorLevel(playerObject),
            healthRatio = dynamicRatio(types.Actor.stats.dynamic.health, playerObject),
            fatigueRatio = dynamicRatio(types.Actor.stats.dynamic.fatigue, playerObject),
            equipped = equippedNames(playerObject),
        }
    end

    respond('GetSceneContext', msg.id, response)
end

local function handleSayMp3File(msg)
    local data = msg.data or {}
    local npc = activeNpcs[data.npcId]
    if not npc then
        print('[ZDORPG] SayMp3File: NPC not found in activeNpcs: ' .. tostring(data.npcId))
        return
    end
    print('[ZDORPG] SayMp3File: playing ' .. tostring(data.mp3Name) .. ' for ' .. tostring(data.npcId))
    local okSay, err = pcall(core.sound.say, 'Sound/zdorpgai_mp3/' .. data.mp3Name, npc, '')
    if not okSay then
        print('[ZDORPG] Error playing voice: ' .. tostring(err))
    end
    if playerObject and data.text and data.text ~= '' then
        local npcName = data.npcId or '???'
        local okRec, record = pcall(types.NPC.record, npc)
        if okRec and record then
            npcName = record.name
        end
        playerObject:sendEvent('ZdorpgShowSpeech', {
            npcName = npcName,
            text = data.text,
            animate = true,
            durationSec = data.durationSec,
        })
    end
end

local function handleSpeechRecognitionInProgress(msg)
    if not playerObject then return end
    local data = msg.data or {}
    playerObject:sendEvent('ZdorpgShowListening', {
        text = data.text or '',
    })
end

local function handleSpeechRecognitionComplete(msg)
    if not playerObject then return end
    local data = msg.data or {}
    playerObject:sendEvent('ZdorpgShowListening', {
        text = data.text or '',
    })
end

local function handlePlayerStartSpeak(msg)
    if playerObject then
        playerObject:sendEvent('ZdorpgShowListening', {})
    end
end

local function handlePlayerStopSpeak(msg)
    -- Don't hide listening here; let SpeechRecognitionComplete or the
    -- 4-second auto-hide timer handle it instead.
end

local function showConnectedIndicator()
    if playerObject then
        playerObject:sendEvent('ZdorpgNotify', { text = 'ZdoRPG connected' })
    end
end

local function handleGetCharactersWhoHear(msg)
    local data = msg.data or {}
    local characterId = data.characterId
    local gameTime = currentGameTime()
    if not characterId then
        respond('GetCharactersWhoHear', msg.id, { characters = json.array(), gameTime = gameTime })
        return
    end

    -- Find the speaking character
    local speaker = nil
    if playerObject and playerObject.recordId == characterId then
        speaker = playerObject
    else
        speaker = activeNpcs[characterId]
    end

    if not speaker then
        respond('GetCharactersWhoHear', msg.id, { characters = json.array(), gameTime = gameTime })
        return
    end

    local okPos, speakerPos = pcall(function() return speaker.position end)
    if not okPos or not speakerPos then
        respond('GetCharactersWhoHear', msg.id, { characters = json.array(), gameTime = gameTime })
        return
    end

    local maxDistMeters = data.maxDistanceMeters or (2000 / 70)
    local maxDistUnits = maxDistMeters * 70
    local hearingRangeSq = maxDistUnits * maxDistUnits
    local characters = json.array()
    for id, npc in pairs(activeNpcs) do
        if id ~= characterId then
            local okDead, isDead = pcall(types.Actor.isDead, npc)
            if okDead and not isDead then
                local okNpc, npcPos = pcall(function() return npc.position end)
                if okNpc and npcPos then
                    local dx = npcPos.x - speakerPos.x
                    local dy = npcPos.y - speakerPos.y
                    local dz = npcPos.z - speakerPos.z
                    local distSq = dx*dx + dy*dy + dz*dz
                    if distSq < hearingRangeSq then
                        characters[#characters + 1] = { characterId = id, distanceMeters = math.sqrt(distSq) / 70 }
                    end
                end
            end
        end
    end

    table.sort(characters, function(a, b) return a.distanceMeters < b.distanceMeters end)
    respond('GetCharactersWhoHear', msg.id, { characters = characters, gameTime = gameTime })
end

local function handleSpawnOnGroundInFrontOfCharacter(msg)
    local data = msg.data or {}
    local npcId = data.npcId
    local itemId = data.itemId
    local count = data.count or 1

    if not npcId or not itemId then
        print('[ZDORPG] SpawnOnGround: missing npcId or itemId')
        return
    end

    local npc = activeNpcs[npcId]
    if not npc then
        print('[ZDORPG] SpawnOnGround: NPC not found: ' .. tostring(npcId))
        return
    end

    local okPos, npcPos = pcall(function() return npc.position end)
    if not okPos or not npcPos then
        print('[ZDORPG] SpawnOnGround: cannot get NPC position')
        return
    end

    local okRot, facing = pcall(function() return npc.rotation:getYaw() end)
    if not okRot then
        facing = 0
    end

    local spawnDistance = 70
    local spawnPos = util.vector3(
        npcPos.x + math.sin(facing) * spawnDistance,
        npcPos.y + math.cos(facing) * spawnDistance,
        npcPos.z
    )

    local okCreate, item = pcall(world.createObject, itemId, count)
    if not okCreate or not item then
        print('[ZDORPG] SpawnOnGround: failed to create ' .. tostring(itemId) .. ': ' .. tostring(item))
        return
    end

    local okBB, bb = pcall(function() return item:getBoundingBox() end)
    if okBB and bb then
        spawnPos = util.vector3(spawnPos.x, spawnPos.y, spawnPos.z + bb.halfSize.z)
    end

    local okTeleport, err = pcall(function()
        item:teleport(npc.cell, spawnPos)
    end)
    if not okTeleport then
        print('[ZDORPG] SpawnOnGround: failed to place object: ' .. tostring(err))
        return
    end

    print('[ZDORPG] Spawned ' .. tostring(count) .. 'x ' .. tostring(itemId) .. ' in front of ' .. tostring(npcId))
end

local function handlePlaySound3dOnCharacter(msg)
    local data = msg.data or {}
    local npcId = data.npcId
    local sound = data.sound

    if not npcId or not sound then
        print('[ZDORPG] PlaySound3d: missing npcId or sound')
        return
    end

    local npc = activeNpcs[npcId]
    if not npc then
        print('[ZDORPG] PlaySound3d: NPC not found: ' .. tostring(npcId))
        return
    end

    local ok, err = pcall(core.sound.playSound3d, sound, npc)
    if not ok then
        print('[ZDORPG] PlaySound3d: failed to play ' .. tostring(sound) .. ': ' .. tostring(err))
    end
end

local function handleNpcStartFollowCharacter(msg)
    local data = msg.data or {}
    local npcId = data.npcId
    local targetId = data.targetCharacterId

    if not npcId or not targetId then
        print('[ZDORPG] NpcStartFollow: missing npcId or targetCharacterId')
        return
    end

    local npc = activeNpcs[npcId]
    if not npc then
        print('[ZDORPG] NpcStartFollow: NPC not found: ' .. tostring(npcId))
        return
    end

    local target = activeNpcs[targetId]
    if not target then
        if playerObject and playerObject.recordId == targetId then
            target = playerObject
        else
            print('[ZDORPG] NpcStartFollow: target not found: ' .. tostring(targetId))
            return
        end
    end

    local ok, err = pcall(function()
        npc:sendEvent('RemoveAIPackages', 'Follow')
        npc:sendEvent('StartAIPackage', {type = 'Follow', target = target})
    end)
    if not ok then
        print('[ZDORPG] NpcStartFollow: failed: ' .. tostring(err))
        return
    end

    print('[ZDORPG] NPC ' .. tostring(npcId) .. ' now following ' .. tostring(targetId))
end

local function handleNpcStopFollowCharacter(msg)
    local data = msg.data or {}
    local npcId = data.npcId

    if not npcId then
        print('[ZDORPG] NpcStopFollow: missing npcId')
        return
    end

    local npc = activeNpcs[npcId]
    if not npc then
        print('[ZDORPG] NpcStopFollow: NPC not found: ' .. tostring(npcId))
        return
    end

    local ok, err = pcall(function()
        npc:sendEvent('RemoveAIPackages', 'Follow')
    end)
    if not ok then
        print('[ZDORPG] NpcStopFollow: failed: ' .. tostring(err))
        return
    end

    print('[ZDORPG] NPC ' .. tostring(npcId) .. ' stopped following')
end

local function handleNpcAttack(msg)
    local data = msg.data or {}
    local npcId = data.npcId
    local targetId = data.targetCharacterId

    if not npcId or not targetId then
        print('[ZDORPG] NpcAttack: missing npcId or targetCharacterId')
        return
    end

    local npc = activeNpcs[npcId]
    if not npc then
        print('[ZDORPG] NpcAttack: NPC not found: ' .. tostring(npcId))
        return
    end

    local target = activeNpcs[targetId]
    if not target then
        if playerObject and playerObject.recordId == targetId then
            target = playerObject
        else
            print('[ZDORPG] NpcAttack: target not found: ' .. tostring(targetId))
            return
        end
    end

    local ok, err = pcall(function()
        npc:sendEvent('RemoveAIPackages', 'Combat')
        npc:sendEvent('StartAIPackage', {type = 'Combat', target = target})
    end)
    if not ok then
        print('[ZDORPG] NpcAttack: failed: ' .. tostring(err))
        return
    end

    print('[ZDORPG] NPC ' .. tostring(npcId) .. ' attacking ' .. tostring(targetId))
end

local function handleNpcStopAttack(msg)
    local data = msg.data or {}
    local npcId = data.npcId

    if not npcId then
        print('[ZDORPG] NpcStopAttack: missing npcId')
        return
    end

    local npc = activeNpcs[npcId]
    if not npc then
        print('[ZDORPG] NpcStopAttack: NPC not found: ' .. tostring(npcId))
        return
    end

    local ok, err = pcall(function()
        npc:sendEvent('RemoveAIPackages', 'Combat')
    end)
    if not ok then
        print('[ZDORPG] NpcStopAttack: failed: ' .. tostring(err))
        return
    end

    print('[ZDORPG] NPC ' .. tostring(npcId) .. ' stopped attacking')
end

local function handleShowMessageBox(msg)
    if not playerObject then return end
    local data = msg.data or {}
    playerObject:sendEvent('ZdorpgNotify', { text = data.message or '' })
end

-------------------------------------------------------------------------------
-- Message dispatch
-------------------------------------------------------------------------------

local function processIncomingMessage(msg)
    print('[ZDORPG:DEBUG] Processing message: ' .. tostring(msg.type))

    if msg.type == 'GetPlayerInfo' then
        handleGetPlayerInfo(msg)
    elseif msg.type == 'GetNpcInfo' then
        handleGetNpcInfo(msg)
    elseif msg.type == 'GetSceneContext' then
        handleGetSceneContext(msg)
    elseif msg.type == 'SayMp3File' then
        handleSayMp3File(msg)
    elseif msg.type == 'SpeechRecognitionInProgress' then
        handleSpeechRecognitionInProgress(msg)
    elseif msg.type == 'SpeechRecognitionComplete' then
        handleSpeechRecognitionComplete(msg)
    elseif msg.type == 'PlayerStartSpeak' then
        handlePlayerStartSpeak(msg)
    elseif msg.type == 'PlayerStopSpeak' then
        handlePlayerStopSpeak(msg)
    elseif msg.type == 'GetCharactersWhoHear' then
        handleGetCharactersWhoHear(msg)
    elseif msg.type == 'SpawnOnGroundInFrontOfCharacter' then
        handleSpawnOnGroundInFrontOfCharacter(msg)
    elseif msg.type == 'PlaySound3dOnCharacter' then
        handlePlaySound3dOnCharacter(msg)
    elseif msg.type == 'NpcStartFollowCharacter' then
        handleNpcStartFollowCharacter(msg)
    elseif msg.type == 'NpcStopFollowCharacter' then
        handleNpcStopFollowCharacter(msg)
    elseif msg.type == 'NpcAttack' then
        handleNpcAttack(msg)
    elseif msg.type == 'NpcStopAttack' then
        handleNpcStopAttack(msg)
    elseif msg.type == 'ShowMessageBox' then
        handleShowMessageBox(msg)
    else
        print('[ZDORPG:ERROR] Unknown message type: ' .. tostring(msg.type))
    end
end

-------------------------------------------------------------------------------
-- Cell change detection
-------------------------------------------------------------------------------

local function checkCellChange()
    if not playerObject then return end
    local ok, cell = pcall(function() return playerObject.cell end)
    if not ok or not cell then return end
    local cellName = cell.name or cell.id
    if cellName ~= lastCellName then
        lastCellName = cellName
        publish('CellChange', {
            playerId = playerObject.recordId,
            cellName = cellName,
        })
    end
end

-------------------------------------------------------------------------------
-- Engine handlers
-------------------------------------------------------------------------------

local function onUpdate(dt)
    frameCounter = frameCounter + 1
    if frameCounter % POLL_INTERVAL_FRAMES ~= 0 then return end

    local messages, newLastId, sessionId, sessionChanged =
        ipc.readIncoming(vfs, lastSeenClientMsgId, currentSessionId)

    if sessionChanged then
        print('[ZDORPG] Session changed: ' .. tostring(currentSessionId) .. ' -> ' .. tostring(sessionId))
        currentSessionId = sessionId
        lastSeenClientMsgId = newLastId or 0
        modMsgCounter = 0
        clientConnected = true
        publish('StartSessionAck', { sessionId = sessionId })
        showConnectedIndicator()
    end

    if messages and #messages > 0 then
        lastSeenClientMsgId = newLastId
        for _, msg in ipairs(messages) do
            local ok, err = pcall(processIncomingMessage, msg)
            if not ok then
                print('[ZDORPG] Error processing message: ' .. tostring(err))
            end
        end
        ipc.sendAck(lastSeenClientMsgId)
    end

    checkCellChange()
end

local function onPlayerAdded(player)
    playerObject = player
    print('[ZDORPG] Player added: ' .. tostring(player.recordId))
    publish('PlayerAdded', {
        playerId = player.recordId,
    })
    if clientConnected then
        showConnectedIndicator()
    end
end

local function onActorActive(actor)
    if types.NPC.objectIsInstance(actor) then
        activeNpcs[actor.recordId] = actor
    end
end

local function onObjectActive(object)
end

-------------------------------------------------------------------------------
-- Event handlers (from player script)
-------------------------------------------------------------------------------

local function onTargetChanged(data)
    publish('TargetChanged', {
        playerId = data.playerId,
        npcId = data.npcId,
    })
end

-------------------------------------------------------------------------------
-- Save / Load
-------------------------------------------------------------------------------

local function onSave()
    return {
        lastSeenClientMsgId = lastSeenClientMsgId,
        lastCellName = lastCellName,
        modMsgCounter = modMsgCounter,
        currentSessionId = currentSessionId,
    }
end

local function rebuildActiveNpcs()
    activeNpcs = {}
    for _, actor in ipairs(world.activeActors) do
        if types.NPC.objectIsInstance(actor) then
            activeNpcs[actor.recordId] = actor
        end
    end
    print('[ZDORPG] Rebuilt activeNpcs: ' .. tostring(#world.activeActors) .. ' actors checked')
end

local function onLoad(data)
    if data then
        lastSeenClientMsgId = data.lastSeenClientMsgId or 0
        lastCellName = data.lastCellName
        modMsgCounter = data.modMsgCounter or 0
        currentSessionId = data.currentSessionId
    end
    rebuildActiveNpcs()
    -- Try to restore playerObject (onPlayerAdded may not fire after reloadlua)
    for _, actor in ipairs(world.activeActors) do
        if types.Player.objectIsInstance(actor) then
            playerObject = actor
            break
        end
    end
    publish('GameSaveLoad', {})
end

-------------------------------------------------------------------------------
-- Script interface
-------------------------------------------------------------------------------

print('[ZDORPG] Global script loaded')

return {
    engineHandlers = {
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
        onPlayerAdded = onPlayerAdded,
        onActorActive = onActorActive,
        onObjectActive = onObjectActive,
    },
    eventHandlers = {
        ZdorpgTargetChanged = onTargetChanged,
    },
}
