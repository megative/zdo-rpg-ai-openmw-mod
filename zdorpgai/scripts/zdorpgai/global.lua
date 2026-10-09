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
local lastTargetNpcId = nil
-- Push-to-talk key from the client, passed on to the player script
local pushToTalkKey = nil

-- Identifies the playthrough: the server keeps a separate memory per save id. It is stored in
-- saves; saves from before it existed load as 'default', the memory the server already had.
local saveId = nil

local function currentSaveId()
    if not saveId then
        local okTime, now = pcall(function() return os.time() end)
        saveId = string.format('%d-%d', okTime and now or 0, math.floor(core.getRealTime() * 1000) % 1000000000)
    end
    return saveId
end

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
    if not id or id == '' then return nil end
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

local function dispositionOf(npc)
    if not playerObject then return nil end
    local ok, value = pcall(types.NPC.getDisposition, npc, playerObject)
    return ok and value or nil
end

-- Our service names, the servicesOffered flag behind each and the window that serves it
local SERVICES = {
    barter = { offered = 'Barter', mode = 'Barter' },
    training = { offered = 'Training', mode = 'Training' },
    travel = { offered = 'Travel', mode = 'Travel' },
    spells = { offered = 'Spells', mode = 'SpellBuying' },
    repair = { offered = 'Repair', mode = 'MerchantRepair' },
}

local function offersService(npc, service)
    local ok, offered = pcall(function() return types.NPC.record(npc).servicesOffered[service.offered] end)
    return ok and offered == true
end

local function offeredServices(npc)
    local names = json.array()
    for name, service in pairs(SERVICES) do
        if offersService(npc, service) then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

local function crimeLevelOf(player)
    local ok, bounty = pcall(types.Player.getCrimeLevel, player)
    return ok and bounty or 0
end

-- Factions the player belongs to and wasn't expelled from, with rank titles
local function playerFactions(player)
    local factions = json.array()
    local ok, factionIds = pcall(types.NPC.getFactions, player)
    if not ok or not factionIds then return factions end
    for _, factionId in ipairs(factionIds) do
        local okExpelled, expelled = pcall(types.NPC.isExpelled, player, factionId)
        if not (okExpelled and expelled) then
            local faction = core.factions.records[factionId]
            local okRank, rank = pcall(types.NPC.getFactionRank, player, factionId)
            local rankRecord = okRank and rank and rank > 0 and faction and faction.ranks[rank]
            factions[#factions + 1] = {
                name = faction and faction.name or factionId,
                rank = rankRecord and rankRecord.name or nil,
            }
        end
    end
    return factions
end

-------------------------------------------------------------------------------
-- Conversation hold: the NPC stops and faces the player (see npc.lua)
-------------------------------------------------------------------------------

-- facing: who the NPC turns to, the player by default
local function holdNpc(npc, seconds, facing)
    facing = facing or playerObject
    if npc and facing then
        npc:sendEvent('ZdorpgHold', { target = facing, seconds = seconds })
    end
end

local function releaseNpc(npc)
    if npc then npc:sendEvent('ZdorpgRelease') end
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
            disposition = dispositionOf(npc),
            services = offeredServices(npc),
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
            bounty = crimeLevelOf(playerObject),
            factions = playerFactions(playerObject),
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
    holdNpc(npc, (data.durationSec or 5) + 4, data.targetId and activeNpcs[data.targetId])
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
    -- The NPC being addressed stops to listen
    holdNpc(lastTargetNpcId and activeNpcs[lastTargetNpcId], 20)
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
    local save = currentSaveId()
    if not characterId then
        respond('GetCharactersWhoHear', msg.id, { characters = json.array(), gameTime = gameTime, saveId = save })
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
        respond('GetCharactersWhoHear', msg.id, { characters = json.array(), gameTime = gameTime, saveId = save })
        return
    end

    local okPos, speakerPos = pcall(function() return speaker.position end)
    if not okPos or not speakerPos then
        respond('GetCharactersWhoHear', msg.id, { characters = json.array(), gameTime = gameTime, saveId = save })
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
    respond('GetCharactersWhoHear', msg.id, {
        characters = characters, gameTime = gameTime, saveId = save, cellName = cellName(speaker),
    })
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

-- 'player' is how the server refers to the player character
local function findActor(id)
    if not id then return nil end
    if playerObject and (id == 'player' or id == playerObject.recordId) then return playerObject end
    return activeNpcs[id]
end

-- Actions reply with { success, error }, so the server can tell the NPC when the game refused
local function respondResult(msg, ok, err)
    if not ok then
        print('[ZDORPG] ' .. tostring(msg.type) .. ' failed: ' .. tostring(err))
    end
    respond(msg.type, msg.id, { success = ok, error = err })
end

local function startAiPackage(msg, packageType)
    local data = msg.data or {}
    local npc = activeNpcs[data.npcId]
    local target = findActor(data.targetCharacterId)
    if not npc then return respondResult(msg, false, 'npc not found') end
    if not target then return respondResult(msg, false, 'target not found') end

    releaseNpc(npc)
    local ok, err = pcall(function()
        npc:sendEvent('RemoveAIPackages', packageType)
        npc:sendEvent('StartAIPackage', { type = packageType, target = target })
    end)
    respondResult(msg, ok, not ok and tostring(err) or nil)
end

local function removeAiPackages(msg, packageType)
    local data = msg.data or {}
    local npc = activeNpcs[data.npcId]
    if not npc then return respondResult(msg, false, 'npc not found') end

    local ok, err = pcall(function() npc:sendEvent('RemoveAIPackages', packageType) end)
    respondResult(msg, ok, not ok and tostring(err) or nil)
end

local function handleNpcStartFollowCharacter(msg) startAiPackage(msg, 'Follow') end
local function handleNpcStopFollowCharacter(msg) removeAiPackages(msg, 'Follow') end
local function handleNpcAttack(msg) startAiPackage(msg, 'Combat') end
local function handleNpcStopAttack(msg) removeAiPackages(msg, 'Combat') end

-- Moves the actual stacks, so condition, charge and souls survive. Checking that the giver
-- really has the items follows waterbobo24's Morrowind-llm-mod.
local function handleTransferItem(msg)
    local data = msg.data or {}
    local from = findActor(data.fromCharacterId)
    local to = findActor(data.toCharacterId)
    local itemId = data.itemId and string.lower(data.itemId)
    local count = math.floor(tonumber(data.count) or 0)
    if not from or not to then return respondResult(msg, false, 'character not found') end
    if not itemId or count < 1 then return respondResult(msg, false, 'no item or count') end

    local inventory = types.Actor.inventory(from)
    pcall(function()
        if not inventory:isResolved() then inventory:resolve() end
    end)
    local have = inventory:countOf(itemId)
    if have < count then
        return respondResult(msg, false, have == 0 and 'does not have it' or ('has only ' .. have))
    end

    local name = nil
    local ok, err = pcall(function()
        local target = types.Actor.inventory(to)
        local remaining = count
        for _, stack in ipairs(inventory:findAll(itemId)) do
            if remaining <= 0 then break end
            name = name or itemName(stack)
            local amount = math.min(remaining, stack.count)
            local moving = amount < stack.count and stack:split(amount) or stack
            moving:moveInto(target)
            remaining = remaining - amount
        end
    end)
    if not ok then
        print('[ZDORPG] TransferItem failed: ' .. tostring(err))
    end
    respond('TransferItem', msg.id, { success = ok, error = not ok and tostring(err) or nil, itemName = name })
end

local function handleModifyDisposition(msg)
    local data = msg.data or {}
    local npc = activeNpcs[data.npcId]
    local delta = math.floor(tonumber(data.delta) or 0)
    if not npc then return respondResult(msg, false, 'npc not found') end
    if not playerObject then return respondResult(msg, false, 'no player') end

    local ok, err = pcall(types.NPC.modifyBaseDisposition, npc, playerObject, delta)
    respondResult(msg, ok, not ok and tostring(err) or nil)
end

-- The engine opens a service window for anyone, so check the NPC really offers it
local function handleOpenService(msg)
    local data = msg.data or {}
    local npc = activeNpcs[data.npcId]
    local service = SERVICES[data.service or '']
    if not npc then return respondResult(msg, false, 'npc not found') end
    if not service then return respondResult(msg, false, 'unknown service') end
    if not offersService(npc, service) then return respondResult(msg, false, 'does not offer ' .. data.service) end
    if not playerObject then return respondResult(msg, false, 'no player') end

    releaseNpc(npc)
    playerObject:sendEvent('AddUiMode', { mode = service.mode, target = npc })
    respondResult(msg, true)
end

local function npcName(npcId)
    local npc = activeNpcs[npcId]
    local ok, record = pcall(function() return types.NPC.record(npc) end)
    return ok and record and record.name or npcId
end

-- The NPC is working on an answer: show "Name: ..." and keep it facing the player meanwhile
local function handleNpcThinking(msg)
    local data = msg.data or {}
    if not playerObject or not data.npcId then return end
    holdNpc(activeNpcs[data.npcId], 15)
    playerObject:sendEvent('ZdorpgShowSpeech', {
        npcName = npcName(data.npcId),
        text = '...',
        animate = false,
        durationSec = 10,
    })
end

local function handleTaskUpdate(msg)
    local data = msg.data or {}
    if not playerObject then return end
    playerObject:sendEvent('ZdorpgTaskUpdate', {
        npcName = npcName(data.npcId),
        task = data.description or '',
        status = data.status,
    })
end

-------------------------------------------------------------------------------
-- Lore from the game's own dialogue
-------------------------------------------------------------------------------

-- Topic infos sit in a linked list (indexing is O(n)), so each topic is copied once
local topicCache = {}

local function topicInfos(topic)
    local cached = topicCache[topic.id]
    if cached then return cached end
    cached = {}
    local infos = topic.infos
    for i = 1, #infos do
        local info = infos[i]
        if info.text and info.text ~= '' then
            cached[#cached + 1] = {
                text = info.text,
                actorId = info.filterActorId,
                race = info.filterActorRace,
                class = info.filterActorClass,
                faction = info.filterActorFaction,
                rank = info.filterActorFactionRank,
                gender = info.filterActorGender,
                disposition = info.filterActorDisposition,
                cell = info.filterPlayerCell,
            }
        end
    end
    topicCache[topic.id] = cached
    return cached
end

local function sameId(a, b)
    return string.lower(tostring(a)) == string.lower(tostring(b))
end

-- The filters the Lua API exposes; the dialogue's script conditions can't be checked from Lua
local function infoMatches(info, who)
    if info.actorId and info.actorId ~= '' and not sameId(info.actorId, who.id) then return false end
    if info.race and info.race ~= '' and not sameId(info.race, who.race) then return false end
    if info.class and info.class ~= '' and not sameId(info.class, who.class) then return false end
    if info.faction then
        -- '' means "no faction"
        if info.faction == '' then
            if who.faction then return false end
        elseif not who.faction or not sameId(info.faction, who.faction) then
            return false
        end
    end
    if info.rank and info.rank > 0 and (who.rank or 0) < info.rank then return false end
    if info.gender and info.gender ~= '' and not sameId(info.gender, who.gender) then return false end
    if info.disposition and info.disposition > 0 and (who.disposition or 0) < info.disposition then return false end
    if info.cell and info.cell ~= '' and string.sub(who.playerCell or '', 1, #info.cell) ~= info.cell then return false end
    return true
end

local function fillPlaceholders(text, who)
    local values = {
        PCName = who.playerName, PCRace = who.playerRace, PCClass = who.playerClass,
        Name = who.name, Race = who.raceName, Class = who.className, Faction = who.factionName,
        Rank = who.rankName, Cell = who.playerCell,
    }
    return (string.gsub(text, '%%(%a+)', function(key)
        return values[key] or ('%' .. key)
    end))
end

local function handleGetTopics(msg)
    local topics = json.array()
    for _, topic in ipairs(core.dialogue.topic.records) do
        topics[#topics + 1] = topic.id
    end
    respond('GetTopics', msg.id, { topics = topics })
end

-- Lines the NPC could say on each topic, as the vanilla dialogue would pick them: first matches first
local function handleGetTopicLines(msg)
    local data = msg.data or {}
    local npc = activeNpcs[data.npcId]
    local limit = data.limit or 3
    local result = json.array()
    local okRec, record = pcall(types.NPC.record, npc)
    if not npc or not okRec or not record then
        respond('GetTopicLines', msg.id, { topics = result })
        return
    end

    local factionIds = select(2, pcall(types.NPC.getFactions, npc))
    local factionId = type(factionIds) ~= 'string' and factionIds and factionIds[1] or nil
    local okRank, rank = pcall(types.NPC.getFactionRank, npc, factionId)
    local factionName, rankName = getFaction(npc)
    local player = playerObject and getCharacterInfo(playerObject)
    local who = {
        id = npc.recordId, race = record.race, class = record.class, gender = record.isMale and 'male' or 'female',
        faction = factionId, rank = okRank and rank or 0, disposition = dispositionOf(npc),
        playerCell = playerObject and cellName(playerObject) or '',
        name = record.name, raceName = recordName(types.NPC.races, record.race), className = recordName(types.NPC.classes, record.class),
        factionName = factionName, rankName = rankName,
        playerName = player and player.name, playerRace = player and recordName(types.NPC.races, player.race),
        playerClass = player and player.className,
    }

    for _, topicId in ipairs(data.topics or {}) do
        local topic = core.dialogue.topic.records[topicId]
        if topic then
            local lines = json.array()
            for _, info in ipairs(topicInfos(topic)) do
                if infoMatches(info, who) then
                    lines[#lines + 1] = fillPlaceholders(info.text, who)
                    if #lines >= limit then break end
                end
            end
            if #lines > 0 then
                result[#result + 1] = { topic = topic.name or topicId, lines = lines }
            end
        end
    end
    respond('GetTopicLines', msg.id, { topics = result })
end

local function handleSetPushToTalkKey(msg)
    local data = msg.data or {}
    if not data.key then return end
    pushToTalkKey = data.key
    if playerObject then
        playerObject:sendEvent('ZdorpgSetPushToTalkKey', { key = pushToTalkKey })
    end
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
    elseif msg.type == 'TransferItem' then
        handleTransferItem(msg)
    elseif msg.type == 'SetPushToTalkKey' then
        handleSetPushToTalkKey(msg)
    elseif msg.type == 'ModifyDisposition' then
        handleModifyDisposition(msg)
    elseif msg.type == 'OpenService' then
        handleOpenService(msg)
    elseif msg.type == 'NpcThinking' then
        handleNpcThinking(msg)
    elseif msg.type == 'TaskUpdate' then
        handleTaskUpdate(msg)
    elseif msg.type == 'GetTopics' then
        handleGetTopics(msg)
    elseif msg.type == 'GetTopicLines' then
        handleGetTopicLines(msg)
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
    if pushToTalkKey then
        player:sendEvent('ZdorpgSetPushToTalkKey', { key = pushToTalkKey })
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

local function onPushToTalk(data)
    publish('PushToTalk', { pressed = data.pressed == true })
end

local function onTargetChanged(data)
    lastTargetNpcId = data.npcId
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
        saveId = currentSaveId(),
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

-- A new game: its save id is made on first use
local function onInit()
    saveId = nil
end

local function onLoad(data)
    if data then
        saveId = data.saveId or 'default'
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
        onInit = onInit,
        onSave = onSave,
        onLoad = onLoad,
        onPlayerAdded = onPlayerAdded,
        onActorActive = onActorActive,
        onObjectActive = onObjectActive,
    },
    eventHandlers = {
        ZdorpgTargetChanged = onTargetChanged,
        ZdorpgPushToTalk = onPushToTalk,
    },
}
