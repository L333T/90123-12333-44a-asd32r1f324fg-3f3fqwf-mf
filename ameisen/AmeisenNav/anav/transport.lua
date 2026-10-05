-- ============================================================================
-- AmeisenNav
-- anav/transport.lua - HTTP to the AmeisenNavigation server
-- ============================================================================
-- Version: 1.0.0
-- Author: BLIZZ
-- ============================================================================
-- core.http_get / http_post are asynchronous and cannot be cancelled, so:
--   * every request gets a sequence number and a deadline; T.tick() fails
--     requests past their deadline with "timeout", and a late answer for a
--     finished sequence is ignored;
--   * at most C.max_inflight requests are on the wire, the rest queue;
--   * transport failures (http code 0 / timeout) in a row mark the server
--     down; while down, requests fail at once with "server_down" and a health
--     ping retries every C.health_retry seconds.
--
-- Callback shape for every request: cb(ok, status, body)
--   ok      true when the server answered (any HTTP status)
--   status  HTTP status, or "timeout" / "server_down" / "busy" / "error"
--   body    response body (string) or ""
-- ============================================================================

local C = require("anav/config")
local L = require("anav/log")

local T = {}

T.server_up = nil          -- nil = unknown yet, true / false after the first answer
T.server_info = ""         -- first line of the last /health answer
T.last_latency = 0         -- seconds, last completed request
T.avg_latency = 0          -- seconds, moving average
T.sent, T.failed = 0, 0

local seq = 0
local inflight = {}        -- seq -> request
local inflight_n = 0
local queue = {}           -- FIFO of requests not yet sent
local fail_streak = 0
local next_health = 0
local health_pending = false
local listeners = {}       -- fn(up) on server up/down changes

local function now()
    return core.time()
end

function T.on_server_change(fn)
    listeners[#listeners + 1] = fn
end

local function set_up(up, why)
    if T.server_up == up then return end
    T.server_up = up
    if up then
        L.info("server connected (%s)", T.server_info ~= "" and T.server_info or C.base_url)
    else
        L.warn("server unavailable at %s (%s) - start Ameisen\\Start-Ameisen.bat", C.base_url, tostring(why))
    end
    for i = 1, #listeners do pcall(listeners[i], up) end
end

local function headers()
    if C.token and C.token ~= "" then
        return { ["X-Nav-Token"] = C.token }
    end
    return nil
end

local function finish(req, ok, status, body)
    if req.done then return end
    req.done = true
    if inflight[req.seq] then
        inflight[req.seq] = nil
        inflight_n = inflight_n - 1
    end
    if req.cb then
        local cb_ok, err = pcall(req.cb, ok, status, body or "")
        if not cb_ok then L.error("callback error on %s: %s", req.path, tostring(err)) end
    end
end

local function note_transport_failure(why)
    T.failed = T.failed + 1
    fail_streak = fail_streak + 1
    if fail_streak >= C.down_after_failures then
        set_up(false, why)
        next_health = now() + C.health_retry
    end
end

local function send(req)
    seq = seq + 1
    req.seq = seq
    req.sent_at = now()
    req.deadline = req.sent_at + (req.timeout or C.request_timeout)
    inflight[seq] = req
    inflight_n = inflight_n + 1
    T.sent = T.sent + 1

    local url = C.base_url .. req.path
    local function answer(code, body)
        if req.done then return end -- timed out already
        local dt = now() - req.sent_at
        T.last_latency = dt
        T.avg_latency = T.avg_latency == 0 and dt or (T.avg_latency * 0.9 + dt * 0.1)
        -- A missing status or a body that is not a string is not an answer:
        -- callers do string work on it (body:sub, body:match).
        if type(code) ~= "number" or code == 0 or type(body) ~= "string" then
            note_transport_failure("no answer")
            finish(req, false, "error", "")
            return
        end
        fail_streak = 0
        if not req.is_health then set_up(true) end
        finish(req, true, code, body)
    end

    -- The game's HTTP layer calls this, so it must never raise: an error here
    -- would leave the request in flight and surface inside the host.
    local function on_answer(code, _ctype, body)
        local ok, err = xpcall(function() answer(code, body) end, L.traceback)
        if not ok then
            L.error("http answer for %s failed: %s", req.path, tostring(err))
            finish(req, false, "error", "")
        end
    end

    local h = headers()
    local ok, err
    if req.body then
        if h then ok, err = pcall(core.http_post, url, h, req.body, on_answer)
        else ok, err = pcall(core.http_post, url, req.body, on_answer) end
    else
        if h then ok, err = pcall(core.http_get, url, h, on_answer)
        else ok, err = pcall(core.http_get, url, on_answer) end
    end
    if not ok then
        L.error("http call failed for %s: %s", req.path, tostring(err))
        finish(req, false, "error", "")
    end
end

local function pump()
    while inflight_n < C.max_inflight and #queue > 0 do
        send(table.remove(queue, 1))
    end
end

--- Queue a request. `path` includes the query string ("/path?map=0&...").
--- `body` makes it a POST. opts: { timeout = seconds, force = true (send even while down) }
function T.request(path, body, cb, opts)
    local req = { path = path, body = body, cb = cb }
    if opts then
        req.timeout = opts.timeout
        req.is_health = opts.is_health
        if not opts.force and T.server_up == false then
            finish(req, false, "server_down", "")
            return
        end
    elseif T.server_up == false then
        finish(req, false, "server_down", "")
        return
    end
    if #queue >= C.max_queued then
        finish(req, false, "busy", "")
        return
    end
    queue[#queue + 1] = req
    pump()
end

--- Ping /health now. cb(up, first_line) is optional.
function T.health(cb)
    if health_pending then
        if cb then cb(T.server_up == true, T.server_info) end
        return
    end
    health_pending = true
    T.request("/health", nil, function(ok, status, body)
        health_pending = false
        local up = ok and status == 200 and body:sub(1, 2) == "ok"
        if up then
            T.server_info = body:match("^([^\n]*)") or ""
            fail_streak = 0
        end
        set_up(up, ok and ("HTTP " .. tostring(status)) or status)
        next_health = now() + (up and C.health_interval or C.health_retry)
        if cb then pcall(cb, up, T.server_info) end
    end, { force = true, is_health = true, timeout = 2.0 })
end

--- Call once per frame: expires timed-out requests, sends queued ones, pings.
function T.tick()
    local t = now()
    for _, req in pairs(inflight) do
        if not req.done and t > req.deadline then
            L.debug("timeout %s after %.1fs", req.path, t - req.sent_at)
            note_transport_failure("timeout")
            finish(req, false, "timeout", "")
        end
    end
    pump()
    if t >= next_health and not health_pending then
        T.health()
    end
end

function T.pending()
    return inflight_n + #queue
end

return T
