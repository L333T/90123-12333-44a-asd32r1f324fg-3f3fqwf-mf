-- ============================================================================
-- Master Farmer - mf_skin.lua (shared by every product window)
-- ============================================================================
-- The product window drawn from the Master Farmer mockups
-- (images/source/product_gui_4tab.webp / _5tab.webp, sliced by
-- tools/build_product_gui.py into the master-farmer-assets repo, gui/product/).
-- Source of truth: _MASTER-FARMER_/tools/product_skin/ - copied into each
-- product by tools/sync_product_skin.py. Do not edit a product's copy.
--
--   header   the mockup's MASTER FARMER logo; product name + version on the
--            left, the hotkeys on the right
--   tabs     4 slots (4-tab art) for up to 4 tab groups, 5 slots (5-tab art)
--            for 5. A group holds one or more of the product's own tabs
--            (ui.new{ tab_groups = { { label, tabs = { ids } } } }); a group
--            of several shows its tabs as sub-tabs in the left panel's title
--            strip. More than 5 groups: the last ones are merged.
--   panels   left: the active tab's controls (the product's own scroll area);
--            right: the status rows
--   buttons  the mockup's Start / Pause / Resume / Stop run the product's
--            start / pause / stop actions; the mockup's X closes the window
--   footer   the mockup's Discord bar
--
-- PIXEL-PERFECT: the art exists for 1080 / 1440 / 2160 screens (the set whose
-- height is at least the screen's, smaller when it would not fit) and is drawn
-- 1:1 at that set's window size.
-- Nothing here calls the game except the texture / http / data-file natives
-- the product windows already use while drawing.
-- ============================================================================

local vec2 = require("common/geometry/vector_2")
local color = require("common/color")
local G = require("mf_skin_geom")

local S = {}

S.ASSET_VERSION = "p1"
S.ART_URL = "https://raw.githubusercontent.com/L333T/master-farmer-assets/main/gui/product/"
local DIR = "master_farmer/gui_product_" .. S.ASSET_VERSION

-- the mockup's palette
S.COL = {
    gold      = color.new(240, 196, 135, 255),   -- product name ("Intelligent Ally")
    gold_dim  = color.new(206, 168, 118, 255),
    parchment = color.new(226, 214, 196, 255),   -- idle tab / sub-tab text
    white     = color.new(246, 246, 250, 255),   -- selected tab text
    label     = color.new(172, 184, 206, 255),   -- status labels
    value     = color.new(236, 239, 246, 255),
    hint_key  = color.new(240, 196, 135, 230),
    hint_text = color.new(200, 206, 222, 220),
    hover     = color.new(255, 255, 255, 26),
    press     = color.new(255, 255, 255, 46),
    underline = color.new(240, 196, 135, 220),
}

-- text sizes in mockup pixels (scaled with the set)
local SIZE = { name = 40, version = 24, tab = 30, title = 28, sub = 25, row = 22, hint = 20 }

local function safe(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

local function now() return safe(core.time) or 0 end

-- ---------------------------------------------------------------------------
-- the artwork set for this screen
-- ---------------------------------------------------------------------------
local screen = { w = nil, h = nil, t = -1e9 }

local function screen_size()
    local t = now()
    if t - screen.t > 5 or not screen.h then
        screen.t = t
        local s = safe(function() return core.graphics.get_screen_size() end)
        if type(s) == "table" and type(s.x) == "number" and type(s.y) == "number" and s.x > 0 and s.y > 0 then
            screen.w, screen.h = s.x, s.y
        end
    end
    return screen.w, screen.h
end

--- The set for a screen: the first whose height is at least the screen's,
--- then smaller while it would not fit (98 %). nil while the screen is unknown.
function S.set_for(sw, sh)
    if not sw or not sh then return nil end
    local pick = G.sets[#G.sets]
    for i = 1, #G.sets do
        if G.sets[i].screen_h >= sh - 0.5 then pick = G.sets[i] break end
    end
    local i = 1
    for j = 1, #G.sets do if G.sets[j] == pick then i = j end end
    while i > 1 and (G.sets[i].w > sw * 0.98 or G.sets[i].h > sh * 0.98) do i = i - 1 end
    return G.sets[i]
end

function S.current_set()
    return S.set_for(screen_size())
end

-- ---------------------------------------------------------------------------
-- textures (downloaded once, cached in scripts_data)
-- ---------------------------------------------------------------------------
local tex = {}           -- name -> { id, bytes } | "pending" | false
local fail_t = {}
local RETRY = 30

local function upload(name, bytes)
    local id = safe(function() return core.graphics.load_texture(bytes) end)
    if id ~= nil then
        tex[name] = { id = id, bytes = bytes }       -- bytes kept with the texture
        return true
    end
    return false
end

local function usable(data)
    return type(data) == "string" and #data > 64 and data:sub(2, 4) == "PNG"
end

--- { id } once the art is loaded; nil while it downloads (or failed recently).
function S.texture(name)
    local e = tex[name]
    if type(e) == "table" then return e end
    if e == "pending" then return nil end
    if e == false and now() - (fail_t[name] or 0) < RETRY then return nil end
    local path = DIR .. "/" .. name
    local cached = safe(function() return core.read_data_file(path) end)
    if usable(cached) and upload(name, cached) then return tex[name] end
    tex[name] = "pending"
    local ok = pcall(core.http_get, S.ART_URL .. name .. "?" .. S.ASSET_VERSION, function(code, _, data)
        if tonumber(code) ~= 200 or not usable(data) then
            tex[name], fail_t[name] = false, now()
            return
        end
        pcall(core.create_data_folder, "master_farmer")
        pcall(core.create_data_folder, DIR)
        pcall(core.create_data_file, path)
        pcall(core.write_data_file, path, data)
        if not upload(name, data) then tex[name], fail_t[name] = false, now() end
    end)
    if not ok then tex[name], fail_t[name] = false, now() end
    return type(tex[name]) == "table" and tex[name] or nil
end

--- Forget every texture (tests).
function S.reset() tex, fail_t, screen = {}, {}, { w = nil, h = nil, t = -1e9 } end

-- ---------------------------------------------------------------------------
-- tab groups
-- ---------------------------------------------------------------------------
--- The visible tab groups: { { label, ids = { tab ids } } } in tab order.
--- menu.tab_groups names the groups; a tab in none is a group of its own;
--- more than 5 groups: the last two are merged until 5 remain.
function S.groups(menu)
    local tabs = menu.tabs or {}
    local spec = type(menu.tab_groups) == "table" and menu.tab_groups or {}
    local key = {}
    for gi = 1, #spec do
        local g = spec[gi]
        if type(g) == "table" and type(g.tabs) == "table" then
            for _, id in ipairs(g.tabs) do key[id] = gi end
        end
    end
    local present = {}
    for i = 1, #tabs do present[tabs[i].id] = tabs[i] end
    local out, done = {}, {}
    for i = 1, #tabs do
        local t = tabs[i]
        local gi = key[t.id]
        if gi then
            if not done[gi] then
                done[gi] = true
                local g = spec[gi]
                local ids = {}
                for _, id in ipairs(g.tabs) do if present[id] then ids[#ids + 1] = id end end
                out[#out + 1] = { label = g.label or t.label, ids = ids }
            end
        else
            out[#out + 1] = { label = t.label or t.id, ids = { t.id } }
        end
    end
    while #out > 5 do
        local a, b = out[#out - 1], out[#out]
        for _, id in ipairs(b.ids) do a.ids[#a.ids + 1] = id end
        a.label = a.label .. " & " .. b.label
        out[#out] = nil
    end
    return out
end

local function label_of(menu, id)
    for i = 1, #(menu.tabs or {}) do
        if menu.tabs[i].id == id then return menu.tabs[i].label or id end
    end
    return id
end

-- ---------------------------------------------------------------------------
-- the window
-- ---------------------------------------------------------------------------
--- Size the window for the screen's artwork set (also before the art loads,
--- so the window does not jump when it arrives). False while the screen size
--- is unknown.
function S.fit(menu)
    local set = S.current_set()
    if not set then return false end
    menu.width, menu.height = set.w, set.h
    return true
end

local function names(set, n)
    return "product_bg_" .. set.tag .. ".png", "tab" .. n .. "_off_" .. set.tag .. ".png",
        "tab" .. n .. "_on_" .. set.tag .. ".png"
end

local function layout_n(menu)
    return (#S.groups(menu) <= 4) and 4 or 5
end

--- True when this screen's set is loaded for the menu's tab count (the
--- textured window is drawn); starts the downloads otherwise.
function S.ready(menu)
    local set = S.current_set()
    if not set then return false end
    local n = layout_n(menu)
    local bg, off, on = names(set, n)
    local a, b, c = S.texture(bg), S.texture(off), S.texture(on)
    local ok = a ~= nil and b ~= nil and c ~= nil
    if ok then
        -- the other layout too, so a window that changes its tab count
        -- (Intelligent Ally: follower / leader) never falls back meanwhile
        local _, off2, on2 = names(set, n == 4 and 5 or 4)
        S.texture(off2)
        S.texture(on2)
    end
    return ok
end

-- per-frame context
local C = { win = nil, ox = 0, oy = 0, k = 1, set = nil, H = nil }

local function px(v) return math.floor(v * C.k + 0.5) end

local function rect(name)
    local r = G.rects[name]
    return px(r[1]), px(r[2]), px(r[3]), px(r[4])
end

local function draw_tex(name, x, y, alpha)
    local t = tex[name]
    local size = G.tex[name]
    if type(t) ~= "table" or not size then return false end
    return pcall(core.graphics.draw_texture_rect, t.id, vec2.new(C.ox + x, C.oy + y), size[1], size[2],
        0, 0, 1, 1, color.white(alpha or 255), true)
end

local function text(font, x, y, col, s, size)
    C.H.draw_text(C.win, font, vec2.new(x, y), col, s, size)
end

local function text_w(font, size, s)
    local sz = C.H.text_size(C.win, font, size, s)
    return (sz and sz.x) or (#s * size * 0.5), (sz and sz.y) or size
end

local function area(x0, y0, x1, y1)
    local a, b = vec2.new(x0, y0), vec2.new(x1, y1)
    C.H.block_drag(C.win, a, b)
    return C.H.hovered(C.win, a, b), C.H.clicked(C.win, a, b)
end

local function run(menu, fn)
    if type(fn) ~= "function" then return end
    if type(menu.defer) == "function" then menu:defer(fn) else pcall(fn) end
end

local function fonts(menu)
    local t = menu.theme or {}
    local base = t.font
    return t.font_title or t.font_big or base, t.font_section or base, base
end

-- the hotkeys (ui.new{ header_hints }) right of the logo, two columns
local function draw_hints(menu, f_small)
    local hints = menu.header_hints
    if type(hints) ~= "table" or #hints == 0 then return end
    local size = px(SIZE.hint)
    local rows = math.ceil(#hints / 2)
    -- fixed columns: key | command, two pairs per row (the font's own widths
    -- vary, a measured key column made the pairs run into each other)
    local x0, col_w, key_w = px(1345), px(300), px(128)
    local y0 = px(118) - math.floor((rows - 1) * size * 0.65)
    for i = 1, #hints do
        local h = hints[i]
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        local x, y = x0 + col * col_w, y0 + row * math.floor(size * 1.35)
        text(f_small, x, y, S.COL.hint_key, tostring(h.key or ""), size)
        text(f_small, x + key_w, y, S.COL.hint_text, tostring(h.command or ""), size)
    end
end

local function draw_header(menu, f_title, f_sec)
    local x0, y0 = rect("title")
    local name = menu.product or menu.subtitle or menu.header_text or ""
    if name == "" or name == "MASTER FARMER" then name = menu.header_text or "" end
    local nsize = px(SIZE.name)
    if name ~= "" then text(f_title, x0, y0 + px(4), S.COL.gold, name, nsize) end
    local v = tostring(menu.version or "")
    if v ~= "" then
        if not v:match("^[vV]") then v = "v" .. v end
        text(f_sec, x0 + px(2), y0 + px(4) + math.floor(nsize * 1.15), S.COL.gold_dim, v, px(SIZE.version))
    end
end

local function draw_tabs(menu, groups, active_gi, f_sec)
    local n = (#groups <= 4) and 4 or 5
    local L = G.tabs[n]
    local _, off, on = names(C.set, n)
    local size = px(SIZE.tab)
    for i = 1, n do
        local sx, sy = L.slot1[1] + (i - 1) * L.pitch, L.slot1[2]
        local x, y = px(sx), px(sy)
        local w, h = px(L.off[1]), px(L.off[2])
        local g = groups[i]
        if g then
            local hov, clk = area(x + px(10), y + px(6), x + w - px(10), y + h - px(8))
            if i == active_gi then
                draw_tex(on, px(sx + L.on_offset[1]), px(sy + L.on_offset[2]))
            else
                draw_tex(off, x, y)
                if hov then draw_tex(on, px(sx + L.on_offset[1]), px(sy + L.on_offset[2]), 110) end
            end
            if clk and i ~= active_gi then
                -- the group's last-used sub-tab (menu slider only - render-safe,
                -- as the old tab row did)
                local last = menu._skin_last and menu._skin_last[g.label]
                pcall(menu.set_active_tab, menu, last or g.ids[1])
            end
            local label = tostring(g.label or "")
            local tw, th = text_w(f_sec, size, label)
            local col = (i == active_gi or hov) and S.COL.white or S.COL.parchment
            text(f_sec, x + math.floor((w - tw) * 0.5), y + math.floor((h - th) * 0.5) - px(2), col, label, size)
        else
            draw_tex(off, x, y, 150)                 -- an empty slot keeps the row whole
        end
    end
end

-- the left panel's title strip: the group's name, or its tabs as sub-tabs
local function draw_left_title(menu, group, active_id, f_sec)
    local x0, y0, x1, y1 = rect("left_title")
    if #group.ids <= 1 then
        local s = tostring(group.label or "")
        local _, th = text_w(f_sec, px(SIZE.title), s)
        text(f_sec, x0, y0 + math.floor((y1 - y0 - th) * 0.5), S.COL.gold, s, px(SIZE.title))
        return
    end
    local size = px(SIZE.sub)
    local x = x0
    for _, id in ipairs(group.ids) do
        local s = tostring(label_of(menu, id))
        local tw, th = text_w(f_sec, size, s)
        local ty = y0 + math.floor((y1 - y0 - th) * 0.5)
        local hov, clk = area(x - px(8), y0, x + tw + px(8), y1)
        local active = id == active_id
        text(f_sec, x, ty, active and S.COL.gold or (hov and S.COL.white or S.COL.parchment), s, size)
        if active then
            pcall(function()
                C.win:render_rect_filled(vec2.new(x, y1 - px(5)), vec2.new(x + tw, y1 - px(2)), S.COL.underline, 0)
            end)
        end
        if clk and not active then
            menu._skin_last = menu._skin_last or {}
            menu._skin_last[group.label] = id
            pcall(menu.set_active_tab, menu, id)
        end
        x = x + tw + px(40)
    end
end

local function draw_status(menu, f_sec, f_row)
    local x0, y0, x1, y1 = rect("right_title")
    local title = menu.status_title or "Status"
    local _, th = text_w(f_sec, px(SIZE.title), title)
    text(f_sec, x0, y0 + math.floor((y1 - y0 - th) * 0.5), S.COL.gold, title, px(SIZE.title))
    local bx0, by0, bx1, by1 = rect("right_body")
    local items = menu.status_items
    local size = px(SIZE.row)
    local row_h = px(44)
    local y = by0 + px(6)
    if type(items) ~= "table" or #items == 0 then
        local s = tostring(menu.subtitle or "")
        if s ~= "" then text(f_row, bx0 + px(12), y, S.COL.label, s, size) end
        return
    end
    for i = 1, #items do
        if y + row_h > by1 then break end
        local it = items[i]
        if type(it) == "table" then
            local label = tostring(it.label or it.key or "")
            local value = tostring(C.H.value(it.value) or "")
            local vc = it.color
            if type(vc) == "function" then vc = safe(vc) end
            local lw, lh = text_w(f_row, size, label)
            local vw = text_w(f_row, size, value)
            local ty = y + math.floor((row_h - lh) * 0.5)
            text(f_row, bx0 + px(12), ty, S.COL.label, label, size)
            text(f_row, math.max(bx0 + px(24) + lw, bx1 - px(12) - vw), ty, vc or S.COL.value, value, size)
            y = y + row_h
        end
    end
end

-- Start / Pause / Resume / Stop: the product's actions by style (start,
-- pause, stop), else by position
local BUTTONS = { { "btn_start", "btn_start_face", "start" }, { "btn_pause", "btn_pause_face", "pause" },
    { "btn_stop", "btn_stop_face", "stop" } }

local function action_for(menu, style, index)
    local list = type(menu.actions) == "table" and menu.actions or {}
    for i = 1, #list do
        local st = list[i].style
        if st == style or (style == "start" and st == "primary") or (style == "pause" and st == "secondary")
            or (style == "stop" and st == "danger") then
            return list[i]
        end
    end
    return list[index]
end

local function draw_buttons(menu)
    for i, b in ipairs(BUTTONS) do
        local x0, y0, x1, y1 = rect(b[1])
        local hov, clk = area(x0, y0, x1, y1)
        if hov then
            local fx0, fy0, fx1, fy1 = rect(b[2])
            pcall(function()
                C.win:render_rect_filled(vec2.new(fx0, fy0), vec2.new(fx1, fy1),
                    clk and S.COL.press or S.COL.hover, px(14))
            end)
        end
        if clk then
            local a = action_for(menu, b[3], i)
            if a then run(menu, a.on_click) end
        end
    end
end

local function draw_close(menu)
    local x0, y0, x1, y1 = rect("close")
    local hov, clk = area(x0, y0, x1, y1)
    if hov then
        pcall(function()
            C.win:render_rect_filled(vec2.new(x0 + px(4), y0 + px(4)), vec2.new(x1 - px(4), y1 - px(4)), S.COL.hover, px(4))
        end)
    end
    if clk then
        pcall(menu.mark_closed, menu)
        return true
    end
    return false
end

--- Draw the whole window (inside win:begin). H: the product ui.lua's helpers
--- { draw_text, text_size, hovered, clicked, block_drag, value }. Returns the
--- active tab id (the product's scroll area was drawn for it).
function S.draw(menu, win, H)
    local set = S.current_set()
    if not set then return nil end
    C.win, C.H, C.set, C.k = win, H, set, set.w / G.src_w
    local o = safe(function() return win:get_position() end)
    C.ox, C.oy = (o and o.x) or 0, (o and o.y) or 0

    local f_title, f_sec, f_row = fonts(menu)
    draw_tex("product_bg_" .. set.tag .. ".png", 0, 0)
    if draw_close(menu) then return nil end

    local groups = S.groups(menu)
    local active_id = menu:active_tab()
    local active_gi = 1
    for gi, g in ipairs(groups) do
        for _, id in ipairs(g.ids) do if id == active_id then active_gi = gi end end
    end
    if groups[active_gi] then
        menu._skin_last = menu._skin_last or {}
        menu._skin_last[groups[active_gi].label] = active_id
    end

    draw_header(menu, f_title, f_sec)
    draw_hints(menu, f_row)
    draw_tabs(menu, groups, active_gi, f_sec)
    if groups[active_gi] then draw_left_title(menu, groups[active_gi], active_id, f_sec) end

    local x0, y0, x1, y1 = rect("left_body")
    pcall(menu.draw_tab_scroll_area, menu, win, active_id, x0, y0, x1 - x0, y1 - y0)
    draw_status(menu, f_sec, f_row)
    draw_buttons(menu)
    return active_id
end

return S
