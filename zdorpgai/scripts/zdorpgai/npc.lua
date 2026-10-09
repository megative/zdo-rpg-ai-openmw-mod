-- ZDORPG NPC Script
-- Keeps an NPC still and turned to the player while they talk. Its AI is off only for the
-- hold, so its own packages (wander, travel, ...) resume untouched afterwards. With AI off the
-- NPC can't fight back either, so holds are short and get renewed while the talk goes on.

local core = require('openmw.core')
local self = require('openmw.self')
local types = require('openmw.types')
local util = require('openmw.util')

local TURN_SPEED = math.rad(240) -- radians per second
local MAX_DISTANCE = 1000 -- game units; past this the talk is over

local target = nil
local holdUntil = 0

local function release()
    if not target then return end
    target = nil
    self.controls.yawChange = 0
    self:enableAI(true)
end

local function onHold(data)
    if not data or not data.target then return end
    target = data.target
    holdUntil = core.getRealTime() + (data.seconds or 10)
    self:enableAI(false)
end

local function onUpdate(dt)
    if not target then return end
    if core.getRealTime() > holdUntil or not target:isValid() or types.Actor.isDead(self) then
        release()
        return
    end

    local delta = target.position - self.position
    if delta:length() > MAX_DISTANCE then
        release()
        return
    end

    self.controls.movement = 0
    self.controls.sideMovement = 0
    local turn = util.normalizeAngle(math.atan2(delta.x, delta.y) - self.rotation:getYaw())
    local maxTurn = TURN_SPEED * dt
    self.controls.yawChange = math.max(-maxTurn, math.min(maxTurn, turn))
end

return {
    engineHandlers = {
        onUpdate = onUpdate,
        onInactive = release,
    },
    eventHandlers = {
        ZdorpgHold = onHold,
        ZdorpgRelease = release,
    },
}
