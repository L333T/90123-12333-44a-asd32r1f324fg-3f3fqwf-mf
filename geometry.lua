-- ============================================================================
-- Master Farmer - Grindbot
-- geometry.lua - object and position helpers, on the vec3 API
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.262.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- The handful of helpers every bot ends up writing - what is this object, how
-- far away is it, where is the point between here and there - done with the
-- vec3 methods the SDK already provides instead of trigonometry.
--
-- WHY NOT movement/geom.lua
--   That file is the hot steering path and is deliberately allocation-free:
--   it writes results into pooled points and its header says so. vec3 methods
--   allocate. These two want different things and stay separate.
--
-- EVERY METHOD USED HERE IS IN THE REFLECTED API
--   dist_to, dist_to_ignore_z, squared_dist_to, squared_dist_to_ignore_z,
--   length, length_squared, normalize, get_extended, get_angle, clone,
--   is_zero, is_nan, and the +, -, *, / operators.
--
-- normalize RETURNS a new unit vector
--   It does not modify the receiver, so it is safe to call on a vector the
--   caller still holds. get_unit_vector does the same thing; normalize is
--   used here because that is the documented name for the operation.
-- ============================================================================

---@type vec3
local vec3 = require("common/geometry/vector_3")

-- math.atan2 was removed in Lua 5.3, where math.atan takes the second argument
-- instead. Resolved once here so the module does not care which it is running
-- on.
local atan2 = math.atan2 or math.atan

local geometry = {}

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then
        return res
    end
    return nil
end

-- ============================================================================
-- OBJECT IDENTITY
-- ============================================================================

--- The object's GUID, or nil.
function geometry.guid(obj)
    if not obj then
        return nil
    end
    return safe(function() return obj:get_guid() end)
end

--- The object's creature id, or nil.
---
--- Replaces parsing it out of the GUID with a pattern. The client exposes it
--- directly, so the string match, the capture and the tonumber all go away -
--- and with them the assumption that the GUID's shape never changes.
---
--- npc_id and get_npc_id both exist; both are tried. An id of 0 means the
--- object is not a creature - a player, a pet, a world object - and is
--- returned as nil rather than passed on as if it were an id.
function geometry.object_id(obj)
    if not obj then
        return nil
    end
    local id = safe(function() return obj:npc_id() end)
    if type(id) ~= "number" then
        id = safe(function() return obj:get_npc_id() end)
    end
    if type(id) ~= "number" or id == 0 then
        return nil
    end
    return id
end

--- The object's world position as a vec3, or nil.
function geometry.position(obj)
    if not obj then
        return nil
    end
    local p = safe(function() return obj:get_position() end)
    if type(p) ~= "table" then
        return nil
    end
    return p
end

--- Interact with an object or NPC. Returns true when the call was issued.
function geometry.interact(obj)
    if not obj then
        return false
    end
    return pcall(function()
        core.input.interact_with_object(obj)
    end)
end

-- ============================================================================
-- POSITIONS
-- ============================================================================

--- Turn loose coordinates into a vec3.
---
--- Accepts a vec3, an { x, y, z } table, or a { [1], [2], [3] } array, which
--- are all shapes this project passes around.
function geometry.to_vec3(p, y, z)
    if type(p) == "number" then
        return vec3.new(p, tonumber(y) or 0, tonumber(z) or 0)
    end
    if type(p) ~= "table" then
        return nil
    end
    local px, py, pz = p.x, p.y, p.z
    if type(px) ~= "number" then
        px, py, pz = p[1], p[2], p[3]
    end
    if type(px) ~= "number" or type(py) ~= "number" or type(pz) ~= "number" then
        return nil
    end
    return vec3.new(px, py, pz)
end

--- Distance between two positions.
---
--- dist_to replaces sqrt(dx^2 + dy^2 + dz^2) outright.
function geometry.distance(a, b)
    local va, vb = geometry.to_vec3(a), geometry.to_vec3(b)
    if not va or not vb then
        return nil
    end
    return safe(function() return va:dist_to(vb) end)
end

--- Squared distance, for comparisons.
---
--- Worth reaching for whenever the number is only being compared against
--- another distance or a threshold: it skips a square root per call, and a
--- scan over every visible object does a lot of them. Compare against the
--- threshold squared.
function geometry.distance_squared(a, b)
    local va, vb = geometry.to_vec3(a), geometry.to_vec3(b)
    if not va or not vb then
        return nil
    end
    return safe(function() return va:squared_dist_to(vb) end)
end

--- Horizontal distance, ignoring height.
---
--- The one to use when a floor above or below should not count as far away -
--- a vendor upstairs is not fifty yards from the door.
function geometry.distance_flat(a, b)
    local va, vb = geometry.to_vec3(a), geometry.to_vec3(b)
    if not va or not vb then
        return nil
    end
    return safe(function() return va:dist_to_ignore_z(vb) end)
end

--- Distance between two objects.
function geometry.object_distance(o1, o2)
    return geometry.distance(geometry.position(o1), geometry.position(o2))
end

-- ============================================================================
-- DERIVED POSITIONS
-- ============================================================================

--- The point `dist` yards from `a` along the line toward `b`.
---
--- get_extended is exactly this, so the angle work the original did - two
--- atan calls, a modulo, then sin and cos to rebuild the point - is not
--- needed. It also avoids that version's bug: it computed AngleXYZ but then
--- applied sin(AngleXYZ) * dist to Z directly, which is not the height of a
--- point along the line.
function geometry.between(a, b, dist)
    local va, vb = geometry.to_vec3(a), geometry.to_vec3(b)
    if not va or not vb or type(dist) ~= "number" then
        return nil
    end
    return safe(function() return va:get_extended(vb, dist) end)
end

--- `origin` moved `dist` yards along `direction`.
---
--- direction is any vector; it is turned into a unit vector first, so its
--- length does not scale the result.
function geometry.offset(origin, direction, dist)
    local o = geometry.to_vec3(origin)
    local d = geometry.to_vec3(direction)
    if not o or not d or type(dist) ~= "number" then
        return nil
    end
    return safe(function()
        return o + (d:normalize() * dist)
    end)
end

--- The direction from `a` to `b` as a unit vector.
function geometry.direction(a, b)
    local va, vb = geometry.to_vec3(a), geometry.to_vec3(b)
    if not va or not vb then
        return nil
    end
    return safe(function() return (vb - va):normalize() end)
end

--- The heading from `a` to `b`, in radians, 0 to 2pi.
---
--- Plain atan2 is kept here deliberately. vec3:get_angle(target, origin)
--- exists, but its exact convention - radians or degrees, which plane, which
--- zero - is not recorded in the reflected reference and the SDK source is
--- not on disk. A heading that is silently in the wrong unit points the
--- character the wrong way, so the arithmetic that is known to be right stays
--- until the convention can be confirmed.
function geometry.heading(a, b)
    local va, vb = geometry.to_vec3(a), geometry.to_vec3(b)
    if not va or not vb then
        return nil
    end
    return atan2(vb.y - va.y, vb.x - va.x) % (math.pi * 2)
end

-- ============================================================================
-- FUTURE POSITION (2.245.0) - the documented Sylvanas method:
--   future = position + normalize(direction) * movement_speed * t
-- A unit that is not moving stays put. Guarded; answers the current
-- position when anything is missing.
-- ============================================================================
local FUTURE_MAX_T = 3.0
local FUTURE_VEC3 = require("common/geometry/vector_3")

local function fcall(obj, name, ...)
    local fn = obj and obj[name]
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, obj, ...)
    if ok then return v end
    return nil
end

--- Where `unit` will be in `t` seconds (vec3), or nil when it has no position.
function geometry.future_position(unit, t)
    if not unit then return nil end
    local pos = fcall(unit, "get_position")
    if type(pos) ~= "table" or type(pos.x) ~= "number" then return nil end
    t = tonumber(t) or 0
    if t <= 0 then return pos end
    if t > FUTURE_MAX_T then t = FUTURE_MAX_T end
    if fcall(unit, "is_moving") == false then return pos end
    local dir = fcall(unit, "get_direction")
    local speed = tonumber(fcall(unit, "get_movement_speed"))
    if type(dir) ~= "table" or type(dir.x) ~= "number" or not speed or speed <= 0 then
        return pos
    end
    -- normalize: a length of 1
    local dx, dy, dz = dir.x, dir.y or 0, dir.z or 0
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1e-6 then return pos end
    -- displacement = speed * time along the direction
    local d = speed * t / len
    local ok, f = pcall(FUTURE_VEC3.new, pos.x + dx * d, pos.y + dy * d, (pos.z or 0) + dz * d)
    if ok and type(f) == "table" and type(f.x) == "number" then return f end
    return pos
end

--- Distance from `from` (a vec3) to where `unit` will be in `t` seconds.
function geometry.future_distance(unit, t, from)
    local f = geometry.future_position(unit, t)
    if not f or type(from) ~= "table" or type(from.x) ~= "number" then return nil end
    local dx, dy, dz = f.x - from.x, f.y - from.y, (f.z or 0) - (from.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

return geometry
