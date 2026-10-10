-- ============================================================================
-- AmeisenNav
-- anav/follow.lua - follow a moving unit (target, focus or a name)
-- ============================================================================
-- Version: 1.0.0
-- Author: BLIZZ
-- ============================================================================
-- Continuous re-pathing, after the Sylvanas "Nav Follower" example:
--   * adaptive interval: C.follow_fast seconds within C.follow_fast_range
--     yards, C.follow_slow beyond (far targets move little relative to us)
--   * dead zone: within C.follow_near yards the walk stops; it resumes on
--     its own when the unit moves away
--   * only re-path when the unit moved C.follow_repath_move yards from the
--     last goal, and always seamlessly (client:move_to{ seamless = true }):
--     on WoW Forever a stop + restart of move forward may not resume
--   * name mode: the object manager is scanned at most every
--     C.follow_scan_every seconds; the found object is reused meanwhile
--
-- Differences from the example, for WoW Forever:
--   * the player comes from anav/context (get_local_player() is nil there)
--   * core.input.get_focus() is documented nil on Classic Era and the
--     private-server clients; the "focus" unit token is tried as well
-- ============================================================================

local C = require("anav/config")
local L = require("anav/log")
local X = require("anav/context")

local FW = {}

FW.MODES = { "target", "focus", "name" }
FW.active = false
FW.paused = false
FW.mode = "target"
FW.name = ""
FW.unit = nil          -- the object being followed (last resolved)
FW.unit_name = nil
FW.distance = nil

local last_goal = nil  -- { x, y } the last path was requested for
local next_path = 0
local name_obj, next_scan = nil, 0

local function now() return core.time() end

local function alive(obj)
    if obj == nil then return false end
    local okv, valid = X.call(obj, "is_valid")
    if okv and valid == false then return false end
    local okd, dead = X.call(obj, "is_dead")
    return not (okd and dead == true)
end

local function focus_obj()
    local ok, f = X.call_fn("core.input.get_focus", core.input and core.input.get_focus)
    if ok and f then return f end
    local okt, t = X.call_fn("get_object_from_guid(focus)", core.object_manager.get_object_from_guid, "focus")
    if okt and t then return t end
    return nil
end

local function find_by_name(wanted)
    local t = now()
    if name_obj and alive(name_obj) and t < next_scan then return name_obj end
    next_scan = t + C.follow_scan_every
    name_obj = nil
    local list_fn = core.object_manager and core.object_manager.get_visible_objects
    local ok, objects = X.call_fn("get_visible_objects", list_fn)
    if not ok or type(objects) ~= "table" then return nil end
    for i = 1, #objects do
        local object = objects[i]
        if object ~= nil then
            local okn, name = X.call(object, "get_name")
            if okn and name == wanted and alive(object) then
                name_obj = object
                return object
            end
        end
    end
    return nil
end

--- The unit to follow right now, or nil.
function FW.resolve()
    if FW.mode == "target" then return X.target() end
    if FW.mode == "focus" then return focus_obj() end
    if FW.mode == "name" then
        if FW.name == nil or FW.name == "" then return nil end
        return find_by_name(FW.name)
    end
    return nil
end

function FW.start(mode, name)
    FW.mode = mode or FW.mode
    FW.name = name or FW.name
    FW.active, FW.paused = true, false
    FW.unit, FW.distance = nil, nil
    last_goal, next_path, name_obj, next_scan = nil, 0, nil, 0
    L.info("follow: started (%s%s)", FW.mode, FW.mode == "name" and (" '" .. tostring(FW.name) .. "'") or "")
end

function FW.stop(client)
    if not FW.active then return end
    FW.active, FW.paused = false, false
    FW.unit, FW.distance, last_goal = nil, nil, nil
    if client and client:is_busy() then client:stop() end
    L.info("follow: stopped")
end

function FW.toggle_pause(client)
    if not FW.active then return end
    FW.paused = not FW.paused
    if FW.paused then
        if client and client:is_busy() then client:stop() end
        last_goal = nil
    end
    L.info("follow: %s", FW.paused and "paused" or "resumed")
end

--- Call every frame after client:update().
function FW.update(client)
    if not FW.active or FW.paused then return end
    local px, py = X.position()
    if not px then return end

    local unit = FW.resolve()
    if not alive(unit) then
        FW.unit, FW.distance = nil, nil
        return -- keep searching; whatever walk is running continues to its goal
    end
    FW.unit = unit
    local okn, name = X.call(unit, "get_name")
    FW.unit_name = okn and name or nil

    local okp, pos = X.call(unit, "get_position")
    if not okp or not pos then return end
    local dx, dy = pos.x - px, pos.y - py
    local d = math.sqrt(dx * dx + dy * dy)
    FW.distance = d

    -- dead zone: close enough, stand still until the unit moves off
    if d < C.follow_near then
        if client:is_busy() then client:stop() end
        last_goal = nil
        return
    end

    local t = now()
    if t < next_path then return end
    -- the unit has not moved much from the goal being walked to: keep walking
    if client:is_busy() and last_goal then
        local gx, gy = pos.x - last_goal.x, pos.y - last_goal.y
        if gx * gx + gy * gy < C.follow_repath_move * C.follow_repath_move then return end
    end
    next_path = t + (d < C.follow_fast_range and C.follow_fast or C.follow_slow)
    last_goal = { x = pos.x, y = pos.y }
    client:move_to({ x = pos.x, y = pos.y, z = pos.z }, function(ok, reason, detail)
        if not ok and detail and detail.code ~= "cancelled" then
            L.debug("follow: path failed (%s)", tostring(detail.code))
        end
    end, { seamless = true, allow_partial = true })
end

return FW
