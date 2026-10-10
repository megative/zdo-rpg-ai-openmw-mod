-- What the scene tells each NPC about the player: the journal only to the NPCs a quest involves,
-- secret factions only to fellow members.
-- Run from the repository root with Lua 5.4 or newer: lua tests/scene_secrets_test.lua
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

local function vec(x, y, z) return { x = x, y = y, z = z } end
local function newActor(recordId, name, isNpc, factions)
    local inv = { stacks = {} }
    function inv:isResolved() return true end
    function inv:resolve() end
    function inv:countOf() return 0 end
    function inv:getAll() return {} end
    local a = { recordId = recordId, _name = name, _isNpc = isNpc, _factions = factions, inv = inv,
        position = vec(0, 0, 0), cell = { name = 'Seyda Neen' } }
    function a:sendEvent() end
    function a:isValid() return true end
    return a
end

local player = newActor('player', 'Nerevar', false, { 'Blades', 'Fighters Guild' })
local sellus = newActor('sellus_gravius', 'Sellus Gravius', true, { 'Imperial Legion' })
local caius = newActor('caius_cosades', 'Caius Cosades', true, { 'Blades' })
local fargoth = newActor('fargoth', 'Fargoth', true, {})
local thug = newActor('camonna_thug', 'Thug', true, { 'Camonna Tong' })

package.loaded['openmw.types'] = {
    NPC = {
        record = function(actor) return { name = actor._name, race = 'dark elf', isMale = true, class = 'commoner', servicesOffered = {} } end,
        objectIsInstance = function(actor) return actor._isNpc == true end,
        getFactions = function(actor) return assert(actor, 'no actor')._factions end,
        getFactionRank = function() return 1 end,
        isExpelled = function() return false end,
        getDisposition = function() return 50 end,
        classes = { records = {} }, races = { records = {} },
    },
    Actor = {
        inventory = function(actor) return actor.inv end,
        isDead = function() return false end,
        getEquipment = function() return {} end,
        stats = {
            dynamic = { health = function() return { current = 1, base = 1 } end, fatigue = function() return { current = 1, base = 1 } end },
            level = function() return { current = 5 } end,
        },
    },
    Player = {
        objectIsInstance = function(actor) return actor == player end,
        -- Oldest first, like the game
        journal = function() return { journalTextEntries = {
            { questId = 'ms_fargothring', text = 'Fargoth says one of the guards has his ring.' },
            { questId = 'a1_1_findspymaster', text = "I've been told to go to Balmora and report to a man named Caius Cosades." },
        } } end,
        quests = function() return {
            a1_1_findspymaster = { stage = 1, finished = false },
            ms_fargothring = { stage = 10, finished = false },
        } end,
        getCrimeLevel = function() return 0 end,
    },
}

-- Dialogue lines whose result scripts move the quests on, each spoken by one NPC
local topics = {
    { id = 'package', name = 'package', infos = {
        { text = 'Take this package to Caius Cosades in Balmora.', filterActorId = 'sellus_gravius', resultScript = 'Journal "A1_1_FindSpymaster" 1' },
        { text = 'So you are the one they sent.', filterActorId = 'caius_cosades', resultScript = 'Journal A1_1_FindSpymaster 14' },
    } },
    { id = 'ring', name = 'ring', infos = {
        { text = 'My ring!', filterActorId = 'fargoth', resultScript = 'Journal MS_FargothRing 100' },
    } },
}

package.loaded['openmw.core'] = {
    getRealTime = function() return 0 end,
    getGameTime = function() return 1388400 end,
    sendGlobalEvent = function() end,
    l10n = function() return function(key) return key end end,
    sound = { say = function() end, isSayActive = function() return false end },
    dialogue = {
        topic = { records = topics },
        greeting = { records = {} },
        journal = { records = {
            a1_1_findspymaster = { questName = 'Report to Caius Cosades', infos = {} },
            ms_fargothring = { questName = "Fargoth's Ring", infos = {} },
        } },
    },
    factions = { records = {
        ['Blades'] = { name = 'Blades', ranks = { { name = 'Novice' } } },
        ['Fighters Guild'] = { name = 'Fighters Guild', ranks = { { name = 'Associate' } } },
        ['Imperial Legion'] = { name = 'Imperial Legion', ranks = { { name = 'Recruit' } } },
        ['Camonna Tong'] = { name = 'Camonna Tong', ranks = { { name = 'Thug' } } },
    } },
    regions = { records = {} },
}
package.loaded['openmw.util'] = {
    vector2 = function(x, y) return { x = x, y = y } end,
    vector3 = vec,
    color = { rgb = function(r, g, b) return { r = r, g = g, b = b } end },
    normalizeAngle = function(a) return a end,
}
local ipcFile = nil
package.loaded['openmw.vfs'] = {
    open = function()
        if not ipcFile then error('no file') end
        return { read = function() return ipcFile end, close = function() end }
    end,
}
package.loaded['openmw.world'] = { activeActors = {} }
package.loaded['openmw_aux.calendar'] = { formatGameTime = function() return '14:05, 16 Last Seed 3E 427' end }
local json = require('scripts.zdorpgai.json')
local globalScript = dofile(MOD .. '/scripts/zdorpgai/global.lua')
local g = globalScript.engineHandlers
g.onPlayerAdded(player)
for _, npc in ipairs({ sellus, caius, fargoth, thug }) do g.onActorActive(npc) end

local msgId = 0
local function sceneFor(npcId)
    msgId = msgId + 1
    ipcFile = 'session:s1\n' .. json.encode({ id = msgId, type = 'GetSceneContext', data = { npcId = npcId, playerId = 'player' } }) .. '\n'
    for _ = 1, 5 do g.onUpdate(0.016) end
    for i = #printed, 1, -1 do
        local line = printed[i]:match('^%[ZDORPG_MSG%](.*)$')
        if line then
            local msg = json.decode(line)
            if msg.type == 'GetSceneContext' and msg.responseTo == msgId then return msg.data end
        end
    end
    error('no scene for ' .. npcId)
end

local function questNames(scene)
    local names = {}
    for _, q in ipairs(scene.player.quests or {}) do names[#names + 1] = q.name end
    return table.concat(names, ', ')
end
local function factionNames(scene)
    local names = {}
    for _, f in ipairs(scene.player.factions or {}) do names[#names + 1] = f.name end
    return table.concat(names, ', ')
end

local s = sceneFor('sellus_gravius')
check(questNames(s) == 'Report to Caius Cosades', 'Sellus, who sends the player, knows that quest only', questNames(s))
check(factionNames(s) == 'Fighters Guild', 'Sellus does not know about the Blades', factionNames(s))

local c = sceneFor('caius_cosades')
check(questNames(c) == 'Report to Caius Cosades', 'Caius, who ends it, knows it', questNames(c))
check(factionNames(c) == 'Blades, Fighters Guild', 'a fellow Blade knows the player is one', factionNames(c))

local f = sceneFor('fargoth')
check(questNames(f) == "Fargoth's Ring", 'Fargoth knows his own quest only', questNames(f))
check(factionNames(f) == 'Fighters Guild', 'Fargoth sees the public guild only', factionNames(f))

local t = sceneFor('camonna_thug')
check(questNames(t) == '', 'a bystander knows none of the journal', questNames(t))
check(factionNames(t) == 'Fighters Guild', 'a bystander does not know about the Blades', factionNames(t))
check(t.player.name == 'Nerevar' and t.player.level == 5, 'the rest of the player is still described', t.player.name)
check(t.gameSeconds == 1388400 and t.gameTime == '14:05, 16 Last Seed 3E 427', 'the scene tells the time as a number too', t.gameSeconds)

local unknown = sceneFor('nobody_here')
check(questNames(unknown) == '' and factionNames(unknown) == 'Fighters Guild', 'an NPC that is not around gets no secrets', questNames(unknown) .. ' / ' .. factionNames(unknown))

for _, line in ipairs(printed) do
    if line:find('Error', 1, true) or line:find('failed', 1, true) then io.stdout:write('LOG: ' .. line .. '\n') end
end
io.stdout:write(string.format('%d passed, %d failed\n', passes, failures))
os.exit(failures == 0 and 0 or 1)
