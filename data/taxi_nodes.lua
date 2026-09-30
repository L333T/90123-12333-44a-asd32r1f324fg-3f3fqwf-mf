-- ============================================================================
-- Master Farmer - Grindbot
-- Flight points (taxi nodes) - positions and faction
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.151.0
-- ============================================================================
-- Trimmed from SentinelCore's kernel/catalogs/taxi_nodes.lua, which is
-- generated from the client's TaxiNodes.dbc (2.4.3). Kept: Eastern Kingdoms
-- (map 0), Kalimdor (1) and Outland (530); dropped: quest / PvP / test /
-- scripted-flight nodes. x, y, z are the flight master's landing spot.
-- ============================================================================

local M = {}

M.nodes = {
    { id = 2, name = "Stormwind, Elwynn", map = 0, x = -8840.56, y = 489.70, z = 109.61, alliance = true, horde = false },
    { id = 4, name = "Sentinel Hill, Westfall", map = 0, x = -10629.29, y = 1036.95, z = 34.02, alliance = true, horde = false },
    { id = 5, name = "Lakeshire, Redridge", map = 0, x = -9429.10, y = -2231.40, z = 68.65, alliance = true, horde = false },
    { id = 6, name = "Ironforge, Dun Morogh", map = 0, x = -4821.78, y = -1155.44, z = 502.21, alliance = true, horde = false },
    { id = 7, name = "Menethil Harbor, Wetlands", map = 0, x = -3792.26, y = -783.29, z = 9.06, alliance = true, horde = false },
    { id = 8, name = "Thelsamar, Loch Modan", map = 0, x = -5421.91, y = -2930.01, z = 347.25, alliance = true, horde = false },
    { id = 9, name = "Booty Bay, Stranglethorn", map = 0, x = -14271.77, y = 299.87, z = 31.09, alliance = false, horde = true },
    { id = 10, name = "The Sepulcher, Silverpine Forest", map = 0, x = 478.86, y = 1536.59, z = 131.32, alliance = false, horde = true },
    { id = 11, name = "Undercity, Tirisfal", map = 0, x = 1568.62, y = 267.97, z = -43.10, alliance = false, horde = true },
    { id = 12, name = "Darkshire, Duskwood", map = 0, x = -10515.46, y = -1261.65, z = 41.34, alliance = true, horde = false },
    { id = 13, name = "Tarren Mill, Hillsbrad", map = 0, x = -0.06, y = -859.91, z = 58.83, alliance = false, horde = true },
    { id = 14, name = "Southshore, Hillsbrad", map = 0, x = -711.48, y = -515.48, z = 26.11, alliance = true, horde = false },
    { id = 15, name = "Eastern Plaguelands", map = 0, x = 2253.40, y = -5344.90, z = 83.38, alliance = false, horde = true },
    { id = 16, name = "Refuge Pointe, Arathi", map = 0, x = -1240.53, y = -2515.11, z = 22.16, alliance = true, horde = false },
    { id = 17, name = "Hammerfall, Arathi", map = 0, x = -916.29, y = -3496.89, z = 70.45, alliance = false, horde = true },
    { id = 18, name = "Booty Bay, Stranglethorn", map = 0, x = -14444.29, y = 509.62, z = 26.20, alliance = false, horde = true },
    { id = 19, name = "Booty Bay, Stranglethorn", map = 0, x = -14473.05, y = 464.15, z = 36.43, alliance = true, horde = false },
    { id = 20, name = "Grom'gol, Stranglethorn", map = 0, x = -12414.18, y = 146.29, z = 3.28, alliance = false, horde = true },
    { id = 21, name = "Kargath, Badlands", map = 0, x = -6633.99, y = -2180.05, z = 244.14, alliance = false, horde = true },
    { id = 22, name = "Thunder Bluff, Mulgore", map = 1, x = -1197.21, y = 29.71, z = 176.95, alliance = false, horde = true },
    { id = 23, name = "Orgrimmar, Durotar", map = 1, x = 1677.59, y = -4315.71, z = 61.17, alliance = false, horde = true },
    { id = 25, name = "Crossroads, The Barrens", map = 1, x = -441.80, y = -2596.08, z = 96.06, alliance = false, horde = true },
    { id = 26, name = "Auberdine, Darkshore", map = 1, x = 6341.38, y = 557.68, z = 16.29, alliance = true, horde = false },
    { id = 27, name = "Rut'theran Village, Teldrassil", map = 1, x = 8643.59, y = 841.05, z = 23.30, alliance = true, horde = false },
    { id = 28, name = "Astranaar, Ashenvale", map = 1, x = 2827.34, y = -289.24, z = 107.16, alliance = true, horde = false },
    { id = 29, name = "Sun Rock Retreat, Stonetalon Mountains", map = 1, x = 966.57, y = 1040.32, z = 104.27, alliance = false, horde = true },
    { id = 30, name = "Freewind Post, Thousand Needles", map = 1, x = -5407.71, y = -2414.30, z = 90.32, alliance = false, horde = true },
    { id = 31, name = "Thalanaar, Feralas", map = 1, x = -4491.88, y = -775.89, z = -39.52, alliance = true, horde = false },
    { id = 32, name = "Theramore, Dustwallow Marsh", map = 1, x = -3825.37, y = -4516.58, z = 10.44, alliance = true, horde = false },
    { id = 33, name = "Stonetalon Peak, Stonetalon Mountains", map = 1, x = 2681.13, y = 1461.68, z = 232.88, alliance = true, horde = false },
    { id = 37, name = "Nijel's Point, Desolace", map = 1, x = 139.24, y = 1325.82, z = 193.50, alliance = true, horde = false },
    { id = 38, name = "Shadowprey Village, Desolace", map = 1, x = -1767.64, y = 3263.89, z = 4.94, alliance = false, horde = true },
    { id = 39, name = "Gadgetzan, Tanaris", map = 1, x = -7223.97, y = -3734.59, z = 8.39, alliance = true, horde = false },
    { id = 40, name = "Gadgetzan, Tanaris", map = 1, x = -7048.89, y = -3780.36, z = 10.19, alliance = false, horde = true },
    { id = 41, name = "Feathermoon, Feralas", map = 1, x = -4373.80, y = 3338.65, z = 12.27, alliance = true, horde = false },
    { id = 42, name = "Camp Mojache, Feralas", map = 1, x = -4419.86, y = 199.31, z = 25.06, alliance = false, horde = true },
    { id = 43, name = "Aerie Peak, The Hinterlands", map = 0, x = 283.74, y = -2002.76, z = 194.74, alliance = true, horde = false },
    { id = 44, name = "Valormok, Azshara", map = 1, x = 3661.52, y = -4390.38, z = 113.05, alliance = false, horde = true },
    { id = 45, name = "Nethergarde Keep, Blasted Lands", map = 0, x = -11112.25, y = -3435.74, z = 79.09, alliance = true, horde = false },
    { id = 48, name = "Bloodvenom Post, Felwood", map = 1, x = 5068.40, y = -337.22, z = 367.41, alliance = false, horde = true },
    { id = 49, name = "Moonglade", map = 1, x = 7458.45, y = -2487.21, z = 462.33, alliance = true, horde = false },
    { id = 52, name = "Everlook, Winterspring", map = 1, x = 6796.80, y = -4742.39, z = 701.50, alliance = true, horde = false },
    { id = 53, name = "Everlook, Winterspring", map = 1, x = 6813.06, y = -4611.12, z = 710.67, alliance = false, horde = true },
    { id = 55, name = "Brackenwall Village, Dustwallow Marsh", map = 1, x = -3147.39, y = -2842.18, z = 34.61, alliance = false, horde = true },
    { id = 56, name = "Stonard, Swamp of Sorrows", map = 0, x = -10456.97, y = -3279.25, z = 21.35, alliance = false, horde = true },
    { id = 57, name = "Fishing Village, Teldrassil", map = 1, x = 8701.51, y = 991.37, z = 14.21, alliance = true, horde = false },
    { id = 58, name = "Zoram'gar Outpost, Ashenvale", map = 1, x = 3374.71, y = 996.97, z = 5.19, alliance = false, horde = true },
    { id = 61, name = "Splintertree Post, Ashenvale", map = 1, x = 2302.39, y = -2524.55, z = 104.40, alliance = false, horde = true },
    { id = 62, name = "Nighthaven, Moonglade", map = 1, x = 7793.61, y = -2403.47, z = 489.32, alliance = true, horde = false },
    { id = 63, name = "Nighthaven, Moonglade", map = 1, x = 7787.72, y = -2404.10, z = 489.56, alliance = false, horde = true },
    { id = 64, name = "Talrendis Point, Azshara", map = 1, x = 2721.99, y = -3880.64, z = 100.87, alliance = true, horde = false },
    { id = 65, name = "Talonbranch Glade, Felwood", map = 1, x = 6205.88, y = -1949.63, z = 571.29, alliance = true, horde = false },
    { id = 66, name = "Chillwind Camp, Western Plaguelands", map = 0, x = 931.32, y = -1430.11, z = 64.67, alliance = true, horde = false },
    { id = 67, name = "Light's Hope Chapel, Eastern Plaguelands", map = 0, x = 2271.09, y = -5340.80, z = 87.11, alliance = true, horde = false },
    { id = 68, name = "Light's Hope Chapel, Eastern Plaguelands", map = 0, x = 2327.41, y = -5286.89, z = 81.78, alliance = false, horde = true },
    { id = 69, name = "Moonglade", map = 1, x = 7470.39, y = -2123.38, z = 492.34, alliance = false, horde = true },
    { id = 70, name = "Flame Crest, Burning Steppes", map = 0, x = -7504.03, y = -2187.54, z = 165.53, alliance = false, horde = true },
    { id = 71, name = "Morgan's Vigil, Burning Steppes", map = 0, x = -8364.61, y = -2738.35, z = 185.46, alliance = true, horde = false },
    { id = 72, name = "Cenarion Hold, Silithus", map = 1, x = -6811.39, y = 836.74, z = 49.81, alliance = false, horde = true },
    { id = 73, name = "Cenarion Hold, Silithus", map = 1, x = -6761.83, y = 772.03, z = 88.91, alliance = true, horde = false },
    { id = 74, name = "Thorium Point, Searing Gorge", map = 0, x = -6552.59, y = -1168.27, z = 309.31, alliance = true, horde = false },
    { id = 75, name = "Thorium Point, Searing Gorge", map = 0, x = -6554.93, y = -1100.05, z = 309.57, alliance = false, horde = true },
    { id = 76, name = "Revantusk Village, The Hinterlands", map = 0, x = -635.26, y = -4720.50, z = 5.38, alliance = false, horde = true },
    { id = 77, name = "Camp Taurajo, The Barrens", map = 1, x = -2380.67, y = -1882.67, z = 95.85, alliance = false, horde = true },
    { id = 79, name = "Marshal's Refuge, Un'Goro Crater", map = 1, x = -6113.82, y = -1142.70, z = -187.63, alliance = true, horde = true },
    { id = 80, name = "Ratchet, The Barrens", map = 1, x = -894.59, y = -3773.01, z = 11.48, alliance = true, horde = true },
    { id = 82, name = "Silvermoon City", map = 530, x = 9375.24, y = -7165.89, z = 9.03, alliance = false, horde = true },
    { id = 83, name = "Tranquillien, Ghostlands", map = 530, x = 7594.47, y = -6784.29, z = 86.46, alliance = false, horde = true },
    { id = 93, name = "Blood Watch, Bloodmyst Isle", map = 530, x = -1933.27, y = -11954.61, z = 57.19, alliance = true, horde = false },
    { id = 94, name = "The Exodar", map = 530, x = -4054.89, y = -11793.35, z = 9.05, alliance = true, horde = false },
    { id = 99, name = "Thrallmar, Hellfire Peninsula", map = 530, x = 228.50, y = 2633.57, z = 87.67, alliance = false, horde = true },
    { id = 100, name = "Honor Hold, Hellfire Peninsula", map = 530, x = -673.42, y = 2717.27, z = 94.18, alliance = true, horde = false },
    { id = 101, name = "Temple of Telhamat, Hellfire Peninsula", map = 530, x = 199.16, y = 4241.56, z = 121.75, alliance = true, horde = false },
    { id = 102, name = "Falcon Watch, Hellfire Peninsula", map = 530, x = -587.41, y = 4101.01, z = 91.37, alliance = false, horde = true },
    { id = 117, name = "Telredor, Zangarmarsh", map = 530, x = 213.75, y = 6063.75, z = 148.31, alliance = true, horde = false },
    { id = 118, name = "Zabra'jin, Zangarmarsh", map = 530, x = 219.45, y = 7816.00, z = 22.72, alliance = true, horde = true },
    { id = 119, name = "Telaar, Nagrand", map = 530, x = -2729.00, y = 7305.30, z = 88.64, alliance = true, horde = false },
    { id = 120, name = "Garadar, Nagrand", map = 530, x = -1261.09, y = 7133.39, z = 57.34, alliance = false, horde = true },
    { id = 121, name = "Allerian Stronghold, Terokkar Forest", map = 530, x = -2987.24, y = 3872.78, z = 9.13, alliance = true, horde = false },
    { id = 122, name = "Area 52, Netherstorm", map = 530, x = 3082.31, y = 3596.11, z = 144.02, alliance = true, horde = true },
    { id = 123, name = "Shadowmoon Village, Shadowmoon Valley", map = 530, x = -3018.62, y = 2557.09, z = 79.09, alliance = false, horde = true },
    { id = 124, name = "Wildhammer Stronghold, Shadowmoon Valley", map = 530, x = -3982.07, y = 2156.47, z = 105.15, alliance = true, horde = false },
    { id = 125, name = "Sylvanaar, Blade's Edge Mountains", map = 530, x = 2183.65, y = 6794.46, z = 183.28, alliance = true, horde = false },
    { id = 126, name = "Thunderlord Stronghold, Blade's Edge Mountains", map = 530, x = 2446.37, y = 6020.93, z = 154.34, alliance = false, horde = true },
    { id = 127, name = "Stonebreaker Hold, Terokkar Forest", map = 530, x = -2567.33, y = 4423.83, z = 39.33, alliance = false, horde = true },
    { id = 128, name = "Shattrath, Terokkar Forest", map = 530, x = -1837.23, y = 5301.90, z = -12.43, alliance = true, horde = true },
    { id = 139, name = "The Stormspire, Netherstorm", map = 530, x = 4157.58, y = 2959.69, z = 352.08, alliance = true, horde = true },
    { id = 140, name = "Altar of Sha'tar, Shadowmoon Valley", map = 530, x = -3065.60, y = 749.42, z = -10.10, alliance = true, horde = true },
    { id = 141, name = "Spinebreaker Ridge, Hellfire Peninsula", map = 530, x = -1316.84, y = 2358.62, z = 88.96, alliance = false, horde = true },
    { id = 149, name = "Shatter Point, Hellfire Peninsula", map = 530, x = 276.20, y = 1486.91, z = -15.10, alliance = true, horde = false },
    { id = 150, name = "Cosmowrench, Netherstorm", map = 530, x = 2974.95, y = 1848.24, z = 141.28, alliance = true, horde = true },
    { id = 151, name = "Swamprat Post, Zangarmarsh", map = 530, x = 91.67, y = 5214.92, z = 23.10, alliance = false, horde = true },
    { id = 156, name = "Toshley's Station, Blade's Edge Mountains", map = 530, x = 1857.35, y = 5531.87, z = 277.01, alliance = true, horde = false },
    { id = 159, name = "Sanctum of the Stars, Shadowmoon Valley", map = 530, x = -4073.17, y = 1123.61, z = 42.47, alliance = true, horde = true },
    { id = 160, name = "Evergrove, Blade's Edge Mountains", map = 530, x = 2976.01, y = 5501.13, z = 143.67, alliance = true, horde = true },
    { id = 163, name = "Mok'Nathal Village, Blade's Edge Mountains", map = 530, x = 2028.79, y = 4705.27, z = 150.51, alliance = false, horde = true },
    { id = 164, name = "Orebor Harborage, Zangarmarsh", map = 530, x = 966.67, y = 7399.16, z = 29.14, alliance = true, horde = true },
    { id = 166, name = "Emerald Sanctuary, Felwood", map = 1, x = 3978.74, y = -1316.42, z = 250.11, alliance = true, horde = true },
    { id = 167, name = "Forest Song, Ashenvale", map = 1, x = 3000.25, y = -3202.41, z = 189.77, alliance = true, horde = false },
    { id = 171, name = "Skettis", map = 530, x = -3364.68, y = 3650.18, z = 284.78, alliance = true, horde = true },
    { id = 172, name = "Ogri'La", map = 530, x = 2531.10, y = 7322.09, z = 373.64, alliance = true, horde = true },
    { id = 179, name = "Mudsprocket, Dustwallow Marsh", map = 1, x = -4566.23, y = -3226.05, z = 34.70, alliance = true, horde = true },
    { id = 205, name = "Zul'Aman, Ghostlands", map = 530, x = 6789.79, y = -7747.58, z = 126.51, alliance = true, horde = true },
}

-- WOW FOREVER (2.124.0): vanilla content only. Outland (map 530) does not
-- exist there, nor do the old-world flight points added in TBC - their flight
-- masters have no Forever NPC page on Wowhead (checked 2026-09-29): Forest
-- Song (Suralais Farwind), Emerald Sanctuary (Gorrim), Mudsprocket (Dyslix
-- Silvergrub). Talrendis Point, Marshal's Refuge, Cenarion Hold, Light's Hope
-- and Thorium Point do exist there.
local TBC_ONLY = { [166] = true, [167] = true, [179] = true }

--- Does this flight point exist on the running game version?
function M.in_game(n)
    if type(n) ~= "table" then return false end
    local ok, gamever = pcall(require, "gamever")
    if ok and type(gamever) == "table" and gamever.is_forever() then
        return n.map ~= 530 and not TBC_ONLY[n.id]
    end
    return true
end

local by_name = nil

--- Catalog entry for a name as the flight map shows it ("Stormwind, Elwynn"),
--- exact first, then by the part before the comma. nil when unknown.
function M.find(name)
    if type(name) ~= "string" or name == "" then return nil end
    if not by_name then
        by_name = { full = {}, head = {} }
        for i = 1, #M.nodes do
            local n = M.nodes[i]
            local low = n.name:lower()
            by_name.full[low] = by_name.full[low] or {}
            table.insert(by_name.full[low], n)
            local head = low:match("^([^,]+)") or low
            by_name.head[head] = by_name.head[head] or {}
            table.insert(by_name.head[head], n)
        end
    end
    local low = name:lower()
    local list = by_name.full[low] or by_name.head[low:match("^([^,]+)") or low]
    if not list then return nil end
    local out = {}
    for i = 1, #list do
        if M.in_game(list[i]) then out[#out + 1] = list[i] end
    end
    return #out > 0 and out or nil
end

return M
