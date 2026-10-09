-- Quest steps an NPC can give through the game's own dialogue. The Lua API doesn't expose the
-- conditions of dialogue lines, but it does expose their result scripts: a line that runs
-- "Journal MS_FargothRing 10" moves that quest on when the player picks its topic.

local M = {}

-- Quest stages a result script sets: Journal MS_FargothRing 10, SetJournalIndex, "A1_1", 1
function M.journalCalls(script)
    local calls = {}
    for line in string.gmatch(string.lower(script or ''), '[^\r\n]+') do
        line = string.gsub(line, ';.*', '')
        local questId, stage = string.match(line, '%f[%w_]journal[%s,]+"?([^%s,"]+)"?[%s,]+(%d+)')
        if not questId then
            questId, stage = string.match(line, '%f[%w_]setjournalindex[%s,]+"?([^%s,"]+)"?[%s,]+(%d+)')
        end
        if questId then
            calls[#calls + 1] = { questId = questId, stage = tonumber(stage) }
        end
    end
    return calls
end

-- The next step of each quest among an NPC's lines: the lowest stage above the player's current
-- one. Quests in progress come before new ones. lines: { questId, stage, ... } in dialogue order;
-- questState(questId) returns the current stage and whether the quest is finished, or nil.
function M.nextSteps(lines, questState, limit)
    local best, order = {}, {}
    for _, line in ipairs(lines) do
        local stage, finished = questState(line.questId)
        if stage and not finished and line.stage > stage then
            local current = best[line.questId]
            if not current then
                order[#order + 1] = { questId = line.questId, started = stage > 0 }
            end
            if not current or line.stage < current.stage then
                best[line.questId] = line
            end
        end
    end

    local result = {}
    for _, started in ipairs({ true, false }) do
        for _, quest in ipairs(order) do
            if quest.started == started and #result < limit then
                result[#result + 1] = best[quest.questId]
            end
        end
    end
    return result
end

-- Dialogue text marks topic links as @word#
function M.plainText(text)
    return (string.gsub(text or '', '[@#]', ''))
end

return M
