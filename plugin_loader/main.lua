-- ============================================================================
-- Master Farmer - Grindbot  ::  HTTP PLUGIN LOADER
-- main.lua - download the bot, then hand off to its real main.lua
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Loader version: 1.1.0
-- ============================================================================
-- FLOW
--   frame 1      issue the manifest request
--   frames 2..n  pulse() enforces the deadline and re-issues queued retries
--   on success   adopt the downloaded identity, then require("main")
--   on failure   log loudly and stop ticking. There is no fallback, because
--                this folder contains no bot code to fall back to.
--
-- HOW THE HANDOFF WORKS
--   http_loader puts every downloaded module into package.preload, which stock
--   require() consults BEFORE searching the filesystem. So require("main")
--   resolves to the DOWNLOADED main.lua, not to this file. The downloaded
--   main.lua ends by registering its own update and render callbacks, so it
--   wires itself up simply by being required.
--
-- THE RECURSION HAZARD
--   If the remote main.lua were absent from the manifest, require("main") would
--   fall through to the filesystem and re-execute THIS file, starting another
--   load, forever. source("main") is checked first: it is non-nil only if the
--   module genuinely arrived, so the require is only ever issued when it is
--   guaranteed to hit the downloaded copy.
--
-- THE SESSION HANDOVER
--   The bot's main.lua guards its callbacks with is_stale(), comparing a
--   captured value against NS._sessions[identity.folder], where identity comes
--   from the bot's own version.lua. Normally the bot's header.lua bumps that
--   counter - but the bot's header.lua never runs here; this loader's header
--   runs instead.
--
--   So we bump it ourselves, reading the folder key from the DOWNLOADED
--   version.lua rather than from a hardcoded guess. Hardcoding it is what broke
--   the previous loader: the string drifted, and a drifted key breaks the guard
--   silently, leaving stale callbacks running after every reload.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local net = require("http_loader")

-- ============================================================================
-- SOURCE
-- ============================================================================
-- Pinned to a commit, not a branch, deliberately. raw.githubusercontent caches
-- branch URLs for a few minutes and does not invalidate every path at the same
-- instant, so a branch URL can serve a fresh manifest.lua beside a stale cached
-- module; the hash check then fails and the whole load aborts - intermittently,
-- only for a few minutes after each push. A commit URL is immutable.
--
-- To ship an update:  python make_manifest.py && git add -A && git commit
--                     && git push && git rev-parse HEAD
-- then paste that SHA below.
local REPO = "L333T/90123-12333-44a-asd32r1f324fg-3f3fqwf-mf"
local SHA  = "e072643382437e557519d6c6aab696f5014be0e8"

local BASE = "https://raw.githubusercontent.com/" .. REPO .. "/" .. SHA .. "/"

-- Optional. Only needed if the repo is private; the token then ships inside
-- this file, so scope it read-only to this one repo.
--   local HEADERS = { ["Authorization"] = "Bearer github_pat_..." }
local HEADERS = nil

local TAG = "[MFG-HTTP]"

-- ============================================================================
-- SESSION GUARD  (the loader's own)
-- ============================================================================
_G.MasterFarmer_Grindbot = _G.MasterFarmer_Grindbot or {}
local NS = _G.MasterFarmer_Grindbot
local LOADER_KEY = (NS._loader and NS._loader.key) or "MFG_HTTP_LOADER"

NS._sessions = NS._sessions or {}
if type(NS._sessions[LOADER_KEY]) ~= "number" then
    NS._sessions[LOADER_KEY] = 1
end
local MY_SESSION = NS._sessions[LOADER_KEY]

local function is_stale()
    return NS._sessions[LOADER_KEY] ~= MY_SESSION
end

-- ============================================================================
-- STATE
-- ============================================================================
local started     = false
local handed_off  = false
local last_report = 0

-- ============================================================================
-- HANDOFF
-- ============================================================================
--- Bump the bot's own session counter using the key from the DOWNLOADED
--- version.lua, standing in for the bot's header.lua, which never ran.
local function adopt_identity()
    local ok, identity = pcall(require, "version")
    if not ok or type(identity) ~= "table" or type(identity.folder) ~= "string" then
        core.log_warning(TAG .. " downloaded version.lua has no folder field - "
            .. "the bot's reload guard will not be armed")
        return nil
    end

    NS.meta = {
        name        = identity.name,
        version     = identity.version,
        author      = identity.authors or identity.author,
        description = identity.description,
    }
    NS._sessions[identity.folder] = (NS._sessions[identity.folder] or 0) + 1
    return identity
end

local function hand_off()
    if handed_off then return end

    -- Only require("main") when the downloaded copy provably exists, otherwise
    -- require would fall through to this very file and recurse.
    if not net.source("main") then
        core.log_error(TAG .. " the manifest delivered no main.lua - refusing to "
            .. "require (it would re-enter this loader)")
        handed_off = true
        return
    end

    handed_off = true

    local identity = adopt_identity()

    package.loaded["main"] = nil
    local ok, e = pcall(require, "main")
    if not ok then
        core.log_error(TAG .. " downloaded main.lua failed: " .. tostring(e))
        return
    end

    core.log(string.format("%s handed off to %s v%s", TAG,
        identity and identity.name or "the bot",
        identity and identity.version or tostring(net.status().version)))
end

-- ============================================================================
-- PER-FRAME
-- ============================================================================
local function on_update()
    if is_stale() then return end
    if handed_off then return end        -- the bot drives itself from here

    if not started then
        started = true
        net.configure({
            base_url    = BASE,
            timeout     = 30.0,
            retries     = 2,
            verify_hash = true,
            headers     = HEADERS,
        })
        core.log(string.format("%s loading from %s @ %s", TAG, REPO, SHA:sub(1, 8)))

        local ok = net.start(function(loaded, why)
            if is_stale() then return end
            if loaded then
                hand_off()
            else
                core.log_error(TAG .. " load failed: " .. tostring(why))
                core.log_error(TAG .. " check REPO and SHA in main.lua, and that "
                    .. "the commit is pushed and manifest.lua matches it")
                handed_off = true        -- stop ticking; nothing more to try
            end
        end)

        if not ok then
            core.log_error(TAG .. " could not start the load")
            handed_off = true
        end
        return
    end

    -- Enforces the deadline (the HTTP API has no timeout callback) and
    -- re-issues queued retries.
    net.pulse()

    local t = izi.now()
    if (t - last_report) >= 2.0 then
        last_report = t
        local s = net.status()
        if s.phase == "manifest" or s.phase == "files" then
            core.log(string.format("%s %s: %d/%d (%.0fs)", TAG, s.phase, s.got, s.want, s.elapsed))
        end
    end
end

core.register_on_update_callback(on_update)

core.log(TAG .. " armed")
