-- ============================================================================
-- Master Farmer - Grindbot  ::  HTTP PLUGIN LOADER
-- http_loader.lua - fetch a Lua codebase over core.http_get
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 1.3.0
-- ============================================================================
-- API CONTRACT THIS CODES AGAINST
--
--   core.http_get(url: string, callback: function)
--   core.http_get(url: string, headers: table<string,string>, callback: function)
--
--   callback(http_code, content_type, response_data, response_headers)
--     http_code        integer  HTTP status. TRANSPORT FAILURE MAY BE 0.
--     content_type     string   server content type
--     response_data    string   raw body, binary safe
--     response_headers string   header dump
--
--   Both overloads are used below: `headers` is passed only when configured,
--   because passing nil as the 2nd argument would land the callback in the
--   `headers` slot.
--
--   core.http_post exists too, but a loader only ever reads, so it is not used.
--
-- THE FACT THAT SHAPES THE DESIGN
--   http_get is ASYNCHRONOUS. There is no synchronous variant and no way to
--   block, so a remote require() cannot exist. The loader is a state machine
--   that runs across frames:
--
--     IDLE -> MANIFEST -> FILES -> COMPILE -> READY
--                |           |         |
--                +-----------+---------+-> FAILED
--
-- WHY package.preload
--   Compiling a chunk does not run it. Installing every compiled chunk as a
--   LOADER lets require() pull them in whatever order the code itself asks for,
--   so download order is irrelevant and all requests can fly in parallel.
--
-- WHAT THIS DOES NOT FIX
--   Lua's 200-local-per-function limit. load() runs the same compiler the disk
--   loader does, so an oversized chunk fails here identically.
--
-- SECURITY
--   This executes code fetched from the network. The manifest hash is an
--   INTEGRITY check only - it catches truncation, proxy mangling and
--   half-written files. It is NOT authenticity: the manifest travels the same
--   channel as the code, so whoever can serve the manifest can serve anything.
--   Point base_url only at a host you control, over https, and pin a commit.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local M = {}

local TAG = "[Master Farmer]"

-- ============================================================================
-- CONFIGURATION
-- ============================================================================
local cfg = {
    base_url      = nil,
    manifest      = "manifest.lua",
    timeout       = 30.0,
    retries       = 2,
    retry_backoff = 0.75,   -- seconds before a retry is re-issued
    max_bytes     = 4 * 1024 * 1024,
    verify_hash   = true,
    headers       = nil,
    -- 1.3.0: mirror base URLs for the SAME files (same manifest, same hashes),
    -- tried in order when a load fails for a network reason. See finish_fail.
    fallbacks     = nil,
    on_fallback   = nil,    -- function(new_base, why), told once per switch
}

-- Explicit whitelist. `cfg.base_url` and `cfg.headers` are nil at rest, so a
-- `cfg[k] ~= nil` test would silently drop exactly the two keys that matter.
local CFG_KEYS = {
    base_url = true, manifest = true, timeout = true, retries = true,
    retry_backoff = true, max_bytes = true, verify_hash = true, headers = true,
    fallbacks = true, on_fallback = true,
}

-- ============================================================================
-- STATE
-- ============================================================================
local PHASE = { IDLE = "idle", MANIFEST = "manifest", FILES = "files",
                READY = "ready", FAILED = "failed" }

local phase       = PHASE.IDLE
local sources     = {}      -- module name -> source string
local entries     = {}      -- manifest entries
local want, got   = 0, 0
local attempts    = {}
local retry_queue = {}      -- { name =, entry =, at = }
local started_t   = 0
local fail_why    = nil
local on_ready    = nil
local installed   = false
local mod_cache   = {}

-- QUIET BY DEFAULT (1.2.3). URLs, HTTP codes, module names and progress go to
-- the console only with verbose on (main.lua's VERBOSE). main.lua reports a
-- failed load in plain words either way, so nothing is lost when quiet.
local verbose = false

function M.set_verbose(on)
    verbose = on == true
end

local function log(m)  if verbose then core.log(TAG .. " " .. m) end end
local function warn(m) if verbose then core.log_warning(TAG .. " " .. m) end end
local function err(m)  if verbose then core.log_error(TAG .. " " .. m) end end

-- ============================================================================
-- INTEGRITY  (Adler-32)
-- ============================================================================
-- Addition-only, so there is no xor operator involved: `~` is a SYNTAX error on
-- LuaJIT / 5.1, and a file containing one will not compile there at all, which
-- no runtime guard can rescue. Every intermediate also stays under 2^17, so it
-- is exact in a double - FNV-1a needs hash * 16777619 with hash up to 2^32,
-- which is 2^56 and silently loses precision. Python's zlib.adler32 produces
-- the identical value, so the manifest generator needs no re-implementation.
local function adler32(s)
    local a, b = 1, 0
    for i = 1, #s do
        a = (a + s:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return string.format("%08x", b * 65536 + a)
end

M.hash = adler32

-- ============================================================================
-- COMPILE  (5.1 / 5.2+)
-- ============================================================================
local function compile(src, chunkname)
    if loadstring then return loadstring(src, chunkname) end
    return load(src, chunkname, "t")
end

-- ============================================================================
-- INSTALL
-- ============================================================================
--- Does require() on this host ACTUALLY consult package.preload?
---
--- Testing `type(package.preload) == "table"` only proves the table exists. A
--- host with its own plugin-scoped require can leave a perfectly normal
--- package.preload sitting there and never look at it - in which case every
--- module we "install" is unreachable, while the loader cheerfully reports
--- success. So install a sentinel and try to require it for real.
local function preload_reachable()
    if type(package) ~= "table" or type(package.preload) ~= "table" then return false end
    if type(require) ~= "function" then return false end

    local probe = "__mfg_preload_probe__"
    package.preload[probe] = function() return "MFG_PROBE_OK" end
    local ok, v = pcall(require, probe)
    package.preload[probe] = nil
    if type(package.loaded) == "table" then package.loaded[probe] = nil end

    return ok == true and v == "MFG_PROBE_OK"
end

local function install_modules()
    if installed then return true end

    local names = {}
    for name in pairs(sources) do names[#names + 1] = name end
    table.sort(names)

    -- Compile everything BEFORE installing anything: one syntax error must abort
    -- the swap-over rather than leave half the plugin remote and half on disk.
    local chunks = {}
    for i = 1, #names do
        local name = names[i]
        local chunk, cerr = compile(sources[name], "@" .. name .. ".lua")
        if not chunk then
            err("compile failed for " .. name .. ": " .. tostring(cerr))
            return false, "compile:" .. name
        end
        chunks[name] = chunk
    end

    M._chunks = chunks

    if preload_reachable() then
        for i = 1, #names do
            local name = names[i]
            -- Clear any cached module of the same name FIRST. require() checks
            -- package.loaded before package.preload, so a generic name like
            -- "version" or "state" already cached by another plugin would
            -- shadow ours permanently and we would silently read its table.
            if type(package.loaded) == "table" then package.loaded[name] = nil end
            package.preload[name] = chunks[name]
        end
        log("installed " .. #names .. " modules into package.preload")
    else
        -- Sandboxed host with no package.preload: wrap require instead and
        -- delegate anything we did not download (izi_sdk, common/*) onward.
        local base_require = require
        _G.require = function(name)
            if mod_cache[name] ~= nil then return mod_cache[name] end
            local chunk = chunks[name]
            if not chunk then return base_require(name) end
            local ok, value = pcall(chunk, name)
            if not ok then
                err("module " .. name .. " raised: " .. tostring(value))
                error(value, 0)
            end
            if value == nil then value = true end
            mod_cache[name] = value
            return value
        end
        log("installed " .. #names .. " modules via require wrapper "
            .. "(this host does not honour package.preload)")
    end

    installed = true
    return true
end

-- ============================================================================
-- COMPLETION
-- ============================================================================
local function finish_ok()
    phase = PHASE.READY
    log(string.format("ready: %d modules in %.1fs", got, izi.now() - started_t))
    if on_ready then
        local cb = on_ready
        on_ready = nil
        pcall(cb, true)
    end
end

-- MIRRORS (1.3.0). A load that failed for a network reason - a refused
-- connection (curl 7 arrives as a code-0 transport failure), 408 / 429 / 5xx,
-- retries exhausted, the overall timeout - starts over from the manifest on
-- the next mirror in cfg.fallbacks. A hash mismatch, a bad manifest or a
-- 404 is not a network problem and still fails: the hashes come from the
-- manifest, so a mirror can only ever deliver the exact same code.
local mirror_i = 0
local load_gen = 0          -- answers from an abandoned load (an older gen) are dropped
local begin_load            -- defined with the public API below

local function finish_fail(why, network)
    if phase == PHASE.FAILED then return end
    local mirrors = cfg.fallbacks
    if network and type(mirrors) == "table" and mirror_i < #mirrors then
        mirror_i = mirror_i + 1
        local nxt = tostring(mirrors[mirror_i])
        warn("load failed (" .. tostring(why) .. ") - trying mirror " .. nxt)
        if type(cfg.on_fallback) == "function" then pcall(cfg.on_fallback, nxt, why) end
        cfg.base_url = nxt
        if cfg.timeout < 60 then cfg.timeout = 60 end   -- a cold CDN is slower
        begin_load()
        return
    end
    phase, fail_why = PHASE.FAILED, why
    retry_queue = {}
    err("load failed: " .. tostring(why))
    if on_ready then
        local cb = on_ready
        on_ready = nil
        pcall(cb, false, why)
    end
end

-- ============================================================================
-- RESPONSE CLASSIFICATION
-- ============================================================================
--- Returns "ok" | "retry" | "fatal", plus a reason.
---
--- Every argument is treated as untrusted. The documented type of http_code is
--- integer, but this runs as a callback from native code: if it ever arrives as
--- nil, a bare `http_code >= 500` raises "attempt to compare number with nil"
--- INSIDE the callback, which propagates back across the C boundary. Coercing
--- first costs nothing and keeps the failure a clean retry.
local function classify(http_code, content_type, body)
    local code = tonumber(http_code) or 0

    if code == 0 then return "retry", "transport failure" end
    if code == 408 or code == 429 or (code >= 500 and code <= 599) then
        return "retry", "http " .. code
    end
    if code ~= 200 then return "fatal", "http " .. code end

    if type(body) ~= "string" or #body == 0 then return "retry", "empty body" end
    if #body > cfg.max_bytes then return "fatal", "oversize (" .. #body .. " bytes)" end

    -- A captive portal or an error page answers 200 with HTML. Lua source never
    -- opens with a doctype or a tag, so this is cheap and reliable.
    local head = body:sub(1, 64):lower()
    if head:find("<!doctype", 1, true) or head:find("<html", 1, true) then
        return "fatal", "html body (wrong URL, or a captive portal?)"
    end
    if type(content_type) == "string" and content_type:lower():find("text/html", 1, true) then
        return "fatal", "content-type text/html"
    end
    return "ok"
end

-- ============================================================================
-- REQUEST
-- ============================================================================
--- Dispatch on the documented overloads. `headers` is omitted entirely when
--- unset - passing nil would put the callback in the headers position.
local function request(url, cb)
    if type(cfg.headers) == "table" then
        core.http_get(url, cfg.headers, cb)
    else
        core.http_get(url, cb)
    end
end

local function url_for(path)
    return cfg.base_url .. path
end

-- ============================================================================
-- FILE FETCH
-- ============================================================================
local fetch_one

local function on_file(name, entry, http_code, content_type, body)
    if phase ~= PHASE.FILES then return end        -- aborted, timed out, or done

    local verdict, why = classify(http_code, content_type, body)

    if verdict == "retry" then
        attempts[name] = (attempts[name] or 0) + 1
        if attempts[name] <= cfg.retries then
            warn(string.format("%s: %s - retry %d/%d", name, why, attempts[name], cfg.retries))
            -- Queued rather than re-issued inline: a code-0 transport failure
            -- can return instantly, and an inline retry would burn the whole
            -- retry budget inside a single frame without ever pausing.
            retry_queue[#retry_queue + 1] = {
                name = name, entry = entry, at = izi.now() + cfg.retry_backoff,
            }
            return
        end
        return finish_fail(name .. ": " .. why .. " (retries exhausted)", true)
    end
    if verdict == "fatal" then
        return finish_fail(name .. ": " .. why)
    end

    if cfg.verify_hash and entry.hash then
        local actual = adler32(body)
        if actual ~= entry.hash then
            return finish_fail(string.format(
                "%s: hash %s, expected %s (manifest and code are out of sync)",
                name, actual, entry.hash))
        end
    end

    -- Idempotent. A duplicate delivery must not advance the counter, or `got`
    -- could reach `want` while a module is still outstanding and we would
    -- install an incomplete set.
    if sources[name] == nil then
        sources[name] = body
        got = got + 1
    end
    if got < want then return end

    local ok, iwhy = install_modules()
    if not ok then return finish_fail(iwhy) end
    finish_ok()
end

fetch_one = function(name, entry)
    local gen = load_gen
    request(url_for(entry.path), function(http_code, content_type, response_data, response_headers)
        if gen ~= load_gen then return end      -- 1.3.0: from before a mirror switch
        on_file(name, entry, http_code, content_type, response_data)
    end)
end

-- ============================================================================
-- MANIFEST
-- ============================================================================
-- A Lua chunk, not JSON: there is no guaranteed JSON decoder here, and load()
-- is already needed for the modules. It must return:
--
--   return {
--       version = "2.3.0",
--       files = {
--           { path = "movement/const.lua", hash = "9d8613aa", size = 4785 },
--           ...
--       },
--   }
--
-- `path` is relative to base_url; the module name is that path minus ".lua".
local function on_manifest(http_code, content_type, body)
    if phase ~= PHASE.MANIFEST then return end

    local verdict, why = classify(http_code, content_type, body)
    if verdict ~= "ok" then
        -- A manifest retry is not worth a queue; the whole load is cheap to redo
        -- - on the next mirror when the failure was a network one (1.3.0).
        return finish_fail("manifest: " .. tostring(why), verdict == "retry")
    end

    local chunk, cerr = compile(body, "@manifest.lua")
    if not chunk then return finish_fail("manifest parse: " .. tostring(cerr)) end

    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" or type(data.files) ~= "table" then
        return finish_fail("manifest shape (expected a table with a files array)")
    end

    entries = {}
    local seen = {}
    for i = 1, #data.files do
        local e = data.files[i]
        if type(e) == "table" and type(e.path) == "string" then
            -- Reject traversal and absolute paths before they reach a URL.
            if e.path:find("%.%.", 1, false) or e.path:find("^[/\\]") or e.path:find("^%a+://") then
                return finish_fail("manifest: unsafe path " .. e.path)
            end
            local name = e.path:gsub("%.lua$", "")
            if not seen[name] then
                seen[name] = true
                entries[#entries + 1] = { name = name, path = e.path, hash = e.hash }
            end
        end
    end

    want, got = #entries, 0
    if want == 0 then return finish_fail("manifest lists no files") end

    M.manifest_version = data.version
    log(string.format("manifest %s: %d modules", tostring(data.version or "?"), want))
    phase = PHASE.FILES

    -- All requests go out on this frame. They complete in any order, which
    -- package.preload makes irrelevant.
    for i = 1, #entries do
        local e = entries[i]
        attempts[e.name] = 0
        fetch_one(e.name, e)
    end
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================
function M.configure(opts)
    if type(opts) ~= "table" then return end
    for k, v in pairs(opts) do
        if CFG_KEYS[k] then cfg[k] = v end
    end
end

--- Begin the load. `callback(ok, why)` fires once, on a later frame.
--- Returns false when the load could not even be started.
function M.start(callback)
    if phase == PHASE.MANIFEST or phase == PHASE.FILES then return false end

    if type(core) ~= "table" or type(core.http_get) ~= "function" then
        err("core.http_get is unavailable in this build")
        return false
    end
    if type(cfg.base_url) ~= "string" or cfg.base_url == "" then
        err("base_url is not configured")
        return false
    end
    if not cfg.base_url:find("^https://") then
        err("base_url must be https (got: " .. tostring(cfg.base_url) .. ")")
        return false
    end
    if cfg.base_url:sub(-1) ~= "/" then cfg.base_url = cfg.base_url .. "/" end

    on_ready = callback
    mirror_i = 0
    begin_load()
    return true
end

--- (Re)start from the manifest on cfg.base_url. Shared by M.start and the
--- mirror switch in finish_fail (1.3.0).
begin_load = function()
    if cfg.base_url:sub(-1) ~= "/" then cfg.base_url = cfg.base_url .. "/" end
    sources, attempts, mod_cache, retry_queue = {}, {}, {}, {}
    entries, fail_why, installed = {}, nil, false
    want, got = 0, 0
    started_t = izi.now()
    phase = PHASE.MANIFEST
    load_gen = load_gen + 1
    local gen = load_gen

    log("fetching " .. url_for(cfg.manifest))
    request(url_for(cfg.manifest), function(http_code, content_type, body)
        if gen ~= load_gen then return end
        on_manifest(http_code, content_type, body)
    end)
end

--- Call once per frame while loading. Two jobs the HTTP API cannot do itself:
---   * there is no timeout callback, so a request that never completes would
---     hang the load forever;
---   * queued retries are re-issued here, spaced by retry_backoff.
function M.pulse()
    if phase ~= PHASE.MANIFEST and phase ~= PHASE.FILES then return end

    local t = izi.now()

    if #retry_queue > 0 then
        local keep = {}
        for i = 1, #retry_queue do
            local r = retry_queue[i]
            if t >= r.at then
                fetch_one(r.name, r.entry)
            else
                keep[#keep + 1] = r
            end
        end
        retry_queue = keep
    end

    if (t - started_t) >= cfg.timeout then
        finish_fail(string.format("timeout after %.0fs (%d/%d modules)", cfg.timeout, got, want), true)
    end
end

function M.is_ready()   return phase == PHASE.READY end
function M.is_failed()  return phase == PHASE.FAILED end
function M.is_loading() return phase == PHASE.MANIFEST or phase == PHASE.FILES end

function M.status()
    return {
        phase   = phase,
        got     = got,
        want    = want,
        elapsed = phase == PHASE.IDLE and 0 or (izi.now() - started_t),
        reason  = fail_why,
        version = M.manifest_version,
    }
end

--- Source of a downloaded module, or nil. Used to prove a module really arrived
--- before requiring it.
function M.source(name) return sources[name] end

--- Drop everything kept only for the load (1.2.0). Call once the plugin has
--- been handed off.
---
--- After install, every module lives in package.preload (or the require
--- wrapper's closure) as a compiled chunk. The source strings - the whole
--- plugin as text, ~1.6 MB - and M._chunks, a second reference to the same
--- chunks, were kept for the rest of the session and never read again.
--- M.source returns nil afterwards; its one caller runs before hand-off.
function M.release()
    sources = {}
    entries = {}
    M._chunks = nil
    pcall(collectgarbage, "collect")
end

return M
