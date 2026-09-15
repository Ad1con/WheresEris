-- =============================================================================
-- WheresEris (v0.1.0) -- outlines Eris and marks where she is about to land.
-- =============================================================================
-- Goal 1: an outline and a ground marker on Eris, in RealHecate's own
-- vocabulary and palette. Goal 2: a bullseye on the spot she will land on,
-- from takeoff to touchdown. See WHERES_ERIS_SPEC.md (one level up, not
-- shipped) for the design brief; DESIGN.md (repo root, not shipped) for the
-- rationale behind every decision below.
--
-- Eris exists twice in the scripts (EnemyData_Eris.lua's boss "Eris" and
-- NPCData_Eris.lua's "NPC_Eris_01"). Every hook is scoped to
-- `enemy.Name == "Eris"`, never a bare string match.
--
-- Facts, verified against the shipped scripts, that force this file's shape:
--
--   * `ErisFlyUp`/`ErisFlyUp_P4` and `ErisFlyDown` are named weapons.
--     `DoWeaponFire` (EnemyAILogic.lua:3923) stamps `aiData.WeaponName` with
--     whichever fired (`GetWeaponAIData`, :5949-5970), so wrapping that one
--     function reports takeoff and landing directly.
--   * The landing spot does not exist until the instant of the teleport.
--     `HandleEnemyTeleportation` (:1086) calls `SelectSpawnPoint`
--     (EncounterLogic.lua:1071), which shuffles and takes the first id that
--     passes `IsSpawnPointEligible` (:1211). A spot can only be chosen from
--     that same eligible set, then substituted for vanilla's own pick.
--   * `SelectSpawnPoint` shuffles with the run's own seeded RNG, so it must
--     always run for real first -- consuming exactly vanilla's draws -- with
--     only its RESULT discarded. See DESIGN.md.
--   * The fly-down teleport is scoped by shape, not guessed: the real call
--     (EnemyAILogic.lua:1105) carries `args.RequireLoS`/`LoSTarget` and a
--     `SpawnNearId` aimed at the hero. Her own summons call the same
--     function without any of that (HandleSpawnerBurst, :4869) and must pass
--     through untouched.
--   * If the real `SelectSpawnPoint` returns nil, vanilla does not teleport
--     her at all (:1113). This mod returns nil too, and hides the bullseye.
-- =============================================================================

local mods = rom.mods
mods["LuaENVY-ENVY"].auto()

---@diagnostic disable: lowercase-global
rom = rom
_PLUGIN = _PLUGIN

local modutil = mods["SGG_Modding-ModUtil"]
local reload = mods["SGG_Modding-ReLoad"]
local sjson = mods["SGG_Modding-SJSON"]

local LOG_PREFIX = "[WheresEris] "

-- Namespaced fields stashed on the live enemy table. None outlive the fight.
local MARKED_FIELD = "WheresEris_Marked"
local GENERATION_FIELD = "WheresEris_Generation"
local AIRBORNE_FIELD = "WheresEris_Airborne"
local LANDING_GENERATION_FIELD = "WheresEris_LandingGeneration"
local LANDING_SPOT_FIELD = "WheresEris_LandingSpotId"

-- ErisFlyUp_P4 (WeaponData_Eris.lua:1520) is ErisFlyUp with MaxUses = 1, used
-- on her fourth phase; both stamp aiData.WeaponName with their own key.
-- ErisRelocate_Up (and _P4) is the SAME maneuver at speed --
-- Enemy_Eris_FlyUp_Start_Fast / _Fire_Fast -- chaining to ErisRelocate_Down.
-- Missed in the first build; the 2026-09-15 log showed the ground marker
-- floating with her through it and no landing marker placed. See DESIGN.md.
local FLY_UP_WEAPONS = {
    ErisFlyUp = true, ErisFlyUp_P4 = true,
    ErisRelocate_Up = true, ErisRelocate_Up_P4 = true,
}
local FLY_DOWN_WEAPONS = {
    ErisFlyDown = true, ErisRelocate_Down = true, ErisRelocate_Down_P4 = true,
}

-- ErisFlyDown never sets TeleportMaxDistance, so HandleEnemyTeleportation's
-- own default applies (EnemyAILogic.lua:1105: `aiData.TeleportMaxDistance or
-- 1000`). Must match exactly, or this mod's candidate search disagrees with
-- vanilla about what is reachable.
local TELEPORT_RADIUS = 1000

-- Poll cadence for the landing marker. See DESIGN.md and
-- WHERES_ERIS_SPEC.md section 6.6 for why 0.1s and when to back off.
local LANDING_POLL_INTERVAL = 0.1

-- Poll cadence for the death-cleanup watcher. Not time-critical.
local IDENTIFIER_POLL_INTERVAL = 0.25

-- =============================================================================
-- Logging
-- =============================================================================

-- rom.log.error RAISES in this build rather than logging, so warnings go
-- through rom.log.info too.
local function logAlways(message)
    if rom and rom.log and rom.log.info then
        rom.log.info(LOG_PREFIX .. tostring(message))
    end
end

local function logWarn(message)
    if rom and rom.log and rom.log.info then
        rom.log.info(LOG_PREFIX .. "WARNING: " .. tostring(message))
    end
end

-- =============================================================================
-- Settings
-- =============================================================================

local CONFIG = {}

-- Palette lifted verbatim from Adicon-RealHecate (src/main.lua:101-112).
CONFIG.colors = {
    Amber   = { 1.00, 0.45, 0.08 },
    Ember   = { 1.00, 0.30, 0.05 },
    Violet  = { 0.72, 0.22, 1.00 },
    Gold    = { 1.00, 0.78, 0.25 },
    Teal    = { 0.10, 0.90, 0.75 },
    Cyan    = { 0.20, 0.95, 1.00 },
    Green   = { 0.30, 1.00, 0.35 },
    Magenta = { 1.00, 0.20, 1.00 },
    Red     = { 1.00, 0.15, 0.10 },
    White   = { 1.00, 1.00, 1.00 },
}

CONFIG.colorOrder = { "Amber", "Ember", "Violet", "Gold", "Teal",
                      "Cyan", "Green", "Magenta", "Red", "White" }

-- Ground marker only: None leaves the art its own gold-orange.
CONFIG.groundColorOrder = { "None" }
for _, name in ipairs(CONFIG.colorOrder) do
    CONFIG.groundColorOrder[#CONFIG.groundColorOrder + 1] = name
end

local settings = {
    values = {
        Enabled = true,

        Outline = true,
        OutlineColor = "Red",
        OutlineThickness = 6,
        OutlineOpacity = 1.0,
        GroundFx = true,
        GroundFxColor = "Red",
        GroundFxScale = 3.0,
        -- Vanilla already outlines her in a Dream Dive (EnemyData_Eris.lua:281).
        -- This doubles up behind its own setting rather than replacing it.
        OutlineInDreamDives = true,

        LandingMarker = true,
        LandingMarkerColor = "Red",
        -- Estimated from a 2026-09-09 playtest screenshot, not yet confirmed
        -- live: 3.0 (RealHecate's ApolloGroundGlow default) rendered the
        -- 240x240 keepsake-face texture far larger than a character. See
        -- DESIGN.md.
        LandingMarkerScale = 1.0,
    },
    entries = {},
    file = nil,
    persistent = false,
}

local CONFIG_DESCRIPTIONS = {
    Enabled = "Master switch. Off leaves the fight completely vanilla.",

    Outline = "Draw a colored outline around Eris. Unaffected by her height, so it stays on through takeoff and landing.",
    OutlineColor = "Color of the outline: Amber, Ember, Violet, Gold, Teal, Cyan, Green, Magenta, Red or White.",
    OutlineThickness = "How heavy the outline is, 1 to 10. The game's own elite outlines are 3.",
    OutlineOpacity = "How solid the outline is, 0 to 1. The game's own elite outlines are 0.8.",
    GroundFx = "Show a colored ground marker under Eris while she is standing on the ground. Hidden while she is airborne, since it would otherwise float.",
    GroundFxColor = "Color of the ground marker: Amber, Ember, Violet, Gold, Teal, Cyan, Green, Magenta, Red, White, or None to leave the art its own gold-orange.",
    GroundFxScale = "Size of the ground marker. 3 is roughly her own footprint.",
    OutlineInDreamDives = "Apply this mod's outline in Dream Dives too, on top of vanilla's own. Off leaves Dream runs exactly as the game made them.",

    LandingMarker = "Show a marker on the spot Eris will land on, from the moment she takes off until she touches down. Always one of the spots the game itself would have picked; see the README for how.",
    LandingMarkerColor = "Tint of the landing marker: Amber, Ember, Violet, Gold, Teal, Cyan, Green, Magenta, Red or White.",
    LandingMarkerScale = "Size of the landing marker. 1 is about half her footprint.",
}

local function sectionFor(key)
    if key == "Outline" or key == "OutlineColor" or key == "OutlineThickness"
        or key == "OutlineOpacity" or key == "OutlineInDreamDives" then
        return "Outline (applies at next fight)"
    end
    if key == "GroundFx" or key == "GroundFxColor" or key == "GroundFxScale" then
        return "Ground marker (applies at next fight)"
    end
    if key == "LandingMarker" or key == "LandingMarkerColor" or key == "LandingMarkerScale" then
        return "Landing marker (applies at next fight)"
    end
    return "General (applies at next fight)"
end

local function loadSettings()
    local ok, err = pcall(function()
        if rom.config == nil or rom.config.config_file == nil then
            logWarn("rom.config unavailable; settings will not persist between sessions")
            return
        end
        local configDir = rom.paths and rom.paths.config and rom.paths.config() or nil
        if configDir == nil then
            logWarn("config directory unavailable; settings will not persist between sessions")
            return
        end

        local guid = (_PLUGIN and _PLUGIN.guid) or "Adicon-WheresEris"
        local path = rom.path.combine(configDir, guid .. ".cfg")
        local file = rom.config.config_file:new(path, true)

        for key, default in pairs(settings.values) do
            settings.entries[key] = file:bind(sectionFor(key), key, default, CONFIG_DESCRIPTIONS[key] or "")
        end

        -- Only adopt a stored value whose type matches the default, so a
        -- hand-edited .cfg cannot put a string where a boolean is expected.
        for key, entry in pairs(settings.entries) do
            local stored = entry:get()
            if type(stored) == type(settings.values[key]) then
                settings.values[key] = stored
            end
        end

        settings.file = file
        settings.persistent = true
    end)

    if not ok then
        logWarn("config load failed, using in-memory settings: " .. tostring(err))
    end
end

local function saveSetting(key, value)
    settings.values[key] = value

    local entry = settings.entries[key]
    if entry == nil then return end

    local ok, err = pcall(function()
        entry:set(value)
        if settings.file ~= nil and type(settings.file.save) == "function" then
            settings.file:save()
        end
    end)
    if not ok then
        logWarn("failed to persist " .. tostring(key) .. ": " .. tostring(err))
    end
end

local function resolveColor(chosen, label)
    local rgb = CONFIG.colors[chosen]
    if rgb == nil then
        logWarn("unknown " .. label .. " color " .. tostring(chosen) .. "; falling back to Red")
        rgb = CONFIG.colors.Red
    end
    return rgb
end

-- AddOutline/CreateAnimation take 0-255 channels; the presets are 0-1.
local function colorTo255(rgb)
    return math.floor(rgb[1] * 255 + 0.5),
           math.floor(rgb[2] * 255 + 0.5),
           math.floor(rgb[3] * 255 + 0.5)
end

local function clamp(value, low, high, fallback)
    local n = tonumber(value)
    if n == nil then return fallback end
    if n < low then return low end
    if n > high then return high end
    return n
end

function CONFIG.resolvedOutline(objectId)
    local r, g, b = colorTo255(resolveColor(settings.values.OutlineColor, "outline"))
    return {
        Id = objectId,
        R = r, G = g, B = b,
        Opacity = clamp(settings.values.OutlineOpacity, 0, 1, 1.0),
        Thickness = clamp(settings.values.OutlineThickness, 1, 10, 6),
        Threshold = 0.6, -- every vanilla outline uses this; no precedent for anything else
    }
end

function CONFIG.resolvedGroundColor()
    local name = settings.values.GroundFxColor
    if name == nil or name == "None" then return nil end
    local rgb = CONFIG.colors[name]
    if rgb == nil then
        logWarn("unknown ground color " .. tostring(name) .. "; leaving the art untinted")
        return nil
    end
    local r, g, b = colorTo255(rgb)
    return { r, g, b, 255 }
end

function CONFIG.resolvedLandingColor()
    local r, g, b = colorTo255(resolveColor(settings.values.LandingMarkerColor, "landing marker"))
    return { r, g, b, 255 }
end

-- =============================================================================
-- Art
-- =============================================================================
-- Ground marker: vanilla's own ApolloGroundGlow sprite, tinted (RealHecate's
-- technique, src/main.lua:385-389). No new art registered.
local GROUND_FX = "ApolloGroundGlow"

-- Landing marker: her keepsake face, already shipped inside GUI.pkg. Registered
-- as a new Animation entry pointing at that existing texture -- see DESIGN.md
-- for the technique and its one open risk (confirmed for CreateScreenComponent,
-- not yet for CreateAnimation in the 3D world).
local LANDING_ANIMATION_NAME = "WheresEris_LandingMarker"
local LANDING_TEXTURE_PATH = [[GUI\Screens\AwardMenu\KeepsakeMaxGift\KeepsakeMaxGift_big\Eris]]
local LANDING_ANIMATIONS_FILE = "Game/Animations/GUI_Screens_VFX.sjson"

local function registerLandingArt()
    if sjson == nil or type(sjson.hook) ~= "function" then
        logWarn("SGG_Modding-SJSON unavailable; the landing marker will not be visible")
        return false
    end
    if rom.path == nil or rom.paths == nil or rom.paths.Content == nil then
        logWarn("rom.paths.Content unavailable; the landing marker will not be visible")
        return false
    end

    local ok, err = pcall(function()
        local animFile = rom.path.combine(rom.paths.Content, LANDING_ANIMATIONS_FILE)
        local order = { "Name", "FilePath", "EndFrame", "NumFrames", "StartFrame", "Material" }
        local entry = (sjson.to_object and sjson.to_object({
            Name = LANDING_ANIMATION_NAME,
            FilePath = LANDING_TEXTURE_PATH,
            EndFrame = 1,
            NumFrames = 1,
            StartFrame = 1,
            Material = "Unlit",
        }, order)) or {
            Name = LANDING_ANIMATION_NAME,
            FilePath = LANDING_TEXTURE_PATH,
            EndFrame = 1,
            NumFrames = 1,
            StartFrame = 1,
            Material = "Unlit",
        }
        sjson.hook(animFile, function(data)
            table.insert(data.Animations, entry)
        end)
    end)
    if not ok then
        logWarn("could not register the landing marker art: " .. tostring(err))
        return false
    end
    return true
end

-- =============================================================================
-- Goal 1 -- the identifier
-- =============================================================================

-- EnemyData_Eris.lua:3103's ObjectTypes = {"Eris","NPC_Eris_01"} matches both
-- units by name alone, so this scopes to the boss specifically.
local function isEris(enemy)
    return enemy ~= nil and enemy.Name == "Eris"
end

local function isDreamRun(game)
    local run = game.CurrentRun
    return run ~= nil and run.IsDreamRun == true
end

local function attachOutline(game, enemy)
    if not settings.values.Outline then return end
    if isDreamRun(game) and not settings.values.OutlineInDreamDives then return end
    game.AddOutline(CONFIG.resolvedOutline(enemy.ObjectId))
end

-- No detachOutline: she is marked once per fight and the outline stays on for
-- the whole fight. See DESIGN.md.

local function attachGroundFx(game, enemy)
    if not settings.values.GroundFx then return end
    local args = {
        Name = GROUND_FX,
        DestinationId = enemy.ObjectId,
        Scale = clamp(settings.values.GroundFxScale, 0.1, 12.0, 3.0),
    }
    local tint = CONFIG.resolvedGroundColor()
    if tint ~= nil then args.Color = tint end
    game.CreateAnimation(args)
end

local function detachGroundFx(game, enemy)
    game.StopAnimation({
        Name = GROUND_FX,
        DestinationId = enemy.ObjectId,
        IncludeCreatedAnimations = true,
    })
end

-- Polls for as long as Eris is alive, purely to detach on death -- there is no
-- other clean signal for "the fight ended." Generation guard retires a
-- superseded watcher (one per fight: O_Boss01 and O_Boss02 each get their own).
local function watchIdentifier(game, enemy, generation)
    while true do
        if enemy[GENERATION_FIELD] ~= generation then return end
        if game.ActiveEnemies == nil or game.ActiveEnemies[enemy.ObjectId] == nil then
            enemy[MARKED_FIELD] = false
            return
        end
        game.wait(IDENTIFIER_POLL_INTERVAL)
    end
end

-- Called after SetupUnit returns (ActivatePrePlaced threads it,
-- EventLogic.lua:127, once per fight).
function CONFIG.attachIdentifier(game, enemy)
    if not isEris(enemy) or enemy.ObjectId == nil then return end
    if not settings.values.Enabled then return end

    local generation = (enemy[GENERATION_FIELD] or 0) + 1
    enemy[GENERATION_FIELD] = generation
    enemy[AIRBORNE_FIELD] = false

    -- Guards against a double SetupUnit stacking a second ground sprite --
    -- CreateAnimation is not idempotent the way AddOutline is.
    if not enemy[MARKED_FIELD] then
        attachOutline(game, enemy)
        attachGroundFx(game, enemy)
        enemy[MARKED_FIELD] = true
    end

    logAlways(("marked Eris (id %s); outline %s/%s, ground %s/%s")
        :format(tostring(enemy.ObjectId),
                tostring(settings.values.Outline), tostring(settings.values.OutlineColor),
                tostring(settings.values.GroundFx), tostring(settings.values.GroundFxColor)))

    game.thread(watchIdentifier, game, enemy, generation)
end

-- =============================================================================
-- Goal 2 -- the landing marker
-- =============================================================================

-- Matches the exact call shape HandleEnemyTeleportation uses for ErisFlyDown
-- (EnemyAILogic.lua:1105): RequireLoS/LoSTarget set, SpawnNearId aimed at the
-- hero. Her summons call SelectSpawnPoint too (HandleSpawnerBurst,
-- EnemyAILogic.lua:4869) but set neither, so they fall through untouched.
function CONFIG.isFlyDownTeleport(game, enemy, encounter, args)
    if not isEris(enemy) then return false end
    if type(args) ~= "table" or not args.RequireLoS or args.LoSTarget == nil then
        return false
    end
    local hero = game.CurrentRun and game.CurrentRun.Hero
    if hero == nil then return false end
    return type(encounter) == "table" and encounter.SpawnNearId == hero.ObjectId
end

-- Oath/Vow shrine active: restricts landing spots to EnemyPointSupport. Read
-- the same way ErisFlyDown's own ConditionalData reads it
-- (EnemyAILogic.lua:5956-5961), not re-derived.
local function isBossDifficultyActive(game, enemy)
    if type(game.IsGameStateEligible) ~= "function" then return false end
    local ok, result = pcall(game.IsGameStateEligible, enemy, { NamedRequirements = { "BossDifficultyActive" } })
    return ok and result == true
end

-- The candidate pool SelectSpawnPoint itself would shuffle from
-- (EncounterLogic.lua:1083-1110). See DESIGN.md for why PreferredSpawnPointGroup
-- does not also need handling here.
local function candidateIds(game, oath)
    local out = {}
    if oath then
        local ids = type(game.GetIdsByType) == "function"
            and game.GetIdsByType({ Name = "EnemyPointSupport" }) or nil
        for _, id in pairs(ids or {}) do out[#out + 1] = id end
    else
        local pts = game.MapState and game.MapState.SpawnPoints or nil
        for _, id in pairs(pts or {}) do out[#out + 1] = id end
    end
    return out
end

-- The eligibility args HandleEnemyTeleportation builds for ErisFlyDown
-- (EnemyAILogic.lua:1105-1106), reconstructed so this mod can ask the
-- question before the real teleport call happens.
local function eligibilityArgs(game, enemy, oath)
    local hero = game.CurrentRun and game.CurrentRun.Hero
    local heroId = hero and hero.ObjectId
    local encounter = { SpawnNearId = heroId, SpawnRadius = TELEPORT_RADIUS }
    local args = {
        RequiredSpawnPoint = oath and "EnemyPointSupport" or nil,
        AllowNoSpawnPoint = true,
        RequireLoS = true,
        LoSTarget = heroId,
    }
    return encounter, args
end

-- Real IsSpawnPointEligible only -- no RNG touched. Empty if nothing is
-- eligible right now (the summon-squeeze corner case).
local function eligibleSpots(game, enemy)
    local currentRoom = game.CurrentRun and game.CurrentRun.CurrentRoom
    if currentRoom == nil or type(game.IsSpawnPointEligible) ~= "function" then return {} end

    local oath = isBossDifficultyActive(game, enemy)
    local encounter, args = eligibilityArgs(game, enemy, oath)
    if encounter.SpawnNearId == nil then return {} end

    local eligible = {}
    for _, id in ipairs(candidateIds(game, oath)) do
        local ok, passes = pcall(game.IsSpawnPointEligible, id, encounter, currentRoom, args)
        if ok and passes then
            eligible[#eligible + 1] = id
        end
    end
    return eligible
end

-- Our own random source, never the game's global RNG -- picking here must not
-- move the seed the run's boons and rooms are drawn from.
local function pickSpot(game, enemy)
    local eligible = eligibleSpots(game, enemy)
    if #eligible == 0 then return nil end
    return eligible[math.random(#eligible)]
end

local function attachLandingMarker(game, spotId)
    local args = {
        Name = LANDING_ANIMATION_NAME,
        DestinationId = spotId,
        Scale = clamp(settings.values.LandingMarkerScale, 0.1, 12.0, 3.0),
        Color = CONFIG.resolvedLandingColor(),
    }
    game.CreateAnimation(args)
end

local function detachLandingMarker(game, spotId)
    if spotId == nil then return end
    game.StopAnimation({
        Name = LANDING_ANIMATION_NAME,
        DestinationId = spotId,
        IncludeCreatedAnimations = true,
    })
end

local function moveMarkerTo(game, enemy, newSpot)
    local old = enemy[LANDING_SPOT_FIELD]
    if old ~= nil and old ~= newSpot then
        detachLandingMarker(game, old)
    end
    enemy[LANDING_SPOT_FIELD] = newSpot
    if newSpot ~= nil and newSpot ~= old then
        attachLandingMarker(game, newSpot)
    end
    return newSpot
end

-- Runs from takeoff to landing. Leaves an eligible spot alone; moves an
-- ineligible one. Ends on landing (generation bump in onFlyDown), on death,
-- or when a newer takeoff supersedes it.
local function watchLanding(game, enemy, generation)
    while true do
        if enemy[LANDING_GENERATION_FIELD] ~= generation then return end
        if game.ActiveEnemies == nil or game.ActiveEnemies[enemy.ObjectId] == nil then
            moveMarkerTo(game, enemy, nil)
            return
        end
        if not enemy[AIRBORNE_FIELD] then return end

        local currentRoom = game.CurrentRun and game.CurrentRun.CurrentRoom
        local spot = enemy[LANDING_SPOT_FIELD]
        local stillGood = false
        if spot ~= nil and currentRoom ~= nil and type(game.IsSpawnPointEligible) == "function" then
            local oath = isBossDifficultyActive(game, enemy)
            local encounter, args = eligibilityArgs(game, enemy, oath)
            local ok, passes = pcall(game.IsSpawnPointEligible, spot, encounter, currentRoom, args)
            stillGood = ok and passes
        end
        if not stillGood then
            local newSpot = moveMarkerTo(game, enemy, pickSpot(game, enemy))
            logAlways(("landing marker moved: %s -> %s"):format(tostring(spot), tostring(newSpot)))
        end

        game.wait(LANDING_POLL_INTERVAL)
    end
end

function CONFIG.onFlyUp(game, enemy)
    enemy[AIRBORNE_FIELD] = true

    if settings.values.GroundFx then
        detachGroundFx(game, enemy)
    end

    if not settings.values.LandingMarker then return end

    local generation = (enemy[LANDING_GENERATION_FIELD] or 0) + 1
    enemy[LANDING_GENERATION_FIELD] = generation
    local spot = moveMarkerTo(game, enemy, pickSpot(game, enemy))
    logAlways(("takeoff: landing marker at spot %s"):format(tostring(spot)))
    game.thread(watchLanding, game, enemy, generation)
end

-- Freezes the landing marker (whatever it shows is the destination) by
-- retiring the watcher, and restores the ground marker.
function CONFIG.onFlyDown(game, enemy)
    enemy[AIRBORNE_FIELD] = false
    enemy[LANDING_GENERATION_FIELD] = (enemy[LANDING_GENERATION_FIELD] or 0) + 1

    -- She has landed; the marker has done its job. The generation bump above
    -- retires watchLanding, which was the only other thing that ever cleared
    -- it -- so without this line the portrait sat on the landing spot for the
    -- rest of the fight, and LANDING_SPOT_FIELD stayed set, which let later
    -- teleports be redirected to it. Both seen in the 2026-09-15 log.
    moveMarkerTo(game, enemy, nil)

    if settings.values.GroundFx then
        attachGroundFx(game, enemy)
    end
end

-- Vanilla found nowhere to send her either. Hide the marker rather than
-- leaving it somewhere she will not go.
function CONFIG.onNoLanding(game, enemy)
    moveMarkerTo(game, enemy, nil)
end

-- =============================================================================
-- Install
-- =============================================================================

local function installHooks(game)
    local ModUtil = game.ModUtil
    if ModUtil == nil or ModUtil.Path == nil or ModUtil.Path.Wrap == nil then
        logWarn("ModUtil.Path.Wrap unavailable; hooks not installed")
        return false
    end

    -- Goal 1: attach once, when she is set up (EventLogic.lua:127).
    ModUtil.Path.Wrap("SetupUnit", function(base, unit, currentRun, args)
        base(unit, currentRun, args)
        if not isEris(unit) or not settings.values.Enabled then return end
        local ok, err = pcall(CONFIG.attachIdentifier, game, unit)
        if not ok then
            logWarn("could not mark Eris, leaving her unmarked: " .. tostring(err))
        end
    end)

    -- Goals 1 (hide/restore) and 2 (pick/freeze), both keyed off which weapon
    -- fired via aiData.WeaponName.
    ModUtil.Path.Wrap("DoWeaponFire", function(base, enemy, aiData)
        base(enemy, aiData)
        if not isEris(enemy) or not settings.values.Enabled then return end

        local weaponName = aiData and aiData.WeaponName
        if FLY_UP_WEAPONS[weaponName] then
            local ok, err = pcall(CONFIG.onFlyUp, game, enemy)
            if not ok then logWarn("fly-up handling failed: " .. tostring(err)) end
        elseif FLY_DOWN_WEAPONS[weaponName] then
            local ok, err = pcall(CONFIG.onFlyDown, game, enemy)
            if not ok then logWarn("fly-down handling failed: " .. tostring(err)) end
        end
    end)

    -- RNG-parity substitution. base() runs FIRST and unconditionally, so it
    -- consumes exactly the draws vanilla would; see DESIGN.md.
    ModUtil.Path.Wrap("SelectSpawnPoint", function(base, currentRoom, enemy, encounter, args, depth)
        local real = base(currentRoom, enemy, encounter, args, depth)

        if not settings.values.Enabled or not settings.values.LandingMarker then return real end
        if not CONFIG.isFlyDownTeleport(game, enemy, encounter, args) then return real end

        if real == nil then
            -- Never substitute a spot where vanilla had none.
            logAlways("landing: vanilla found no legal spot, clearing the marker")
            local ok, err = pcall(CONFIG.onNoLanding, game, enemy)
            if not ok then logWarn("could not clear the landing marker: " .. tostring(err)) end
            return nil
        end

        -- Only while she is actually in a tracked flight. Three of her
        -- weapons pass isFlyDownTeleport (ErisFlyDown, ErisRelocateStrike2,
        -- ErisRelocate_Down); without this gate a stale marker from an
        -- earlier flight redirected a later teleport -- twice in one fight.
        local marked = enemy[AIRBORNE_FIELD] and enemy[LANDING_SPOT_FIELD] or nil
        if marked ~= nil then
            local ok, passes = pcall(game.IsSpawnPointEligible, marked, encounter, currentRoom, args)
            if ok and passes then
                logAlways(("landing: teleporting to marked spot %s (vanilla would have picked %s)")
                    :format(tostring(marked), tostring(real)))
                return marked
            end
        end

        -- Tracked spot missing or stale -- fall back to vanilla's real pick.
        logAlways(("landing: marker was stale, teleporting to vanilla's own pick %s"):format(tostring(real)))
        return real
    end)

    return true
end

-- =============================================================================
-- Overlay panel
-- =============================================================================

local function comboSetting(imgui, key, options, label)
    local current = tostring(settings.values[key])
    if imgui.BeginCombo(label .. "##WheresEris_" .. key, current) then
        for _, name in ipairs(options) do
            if imgui.Selectable(name .. "##WheresEris_" .. key .. "_" .. name) then
                saveSetting(key, name)
            end
        end
        imgui.EndCombo()
    end
end

local function checkSetting(imgui, key, label)
    local value, changed = imgui.Checkbox(label .. "##WheresEris_" .. key,
                                          settings.values[key] == true)
    if changed then saveSetting(key, value) end
end

local function sliderSetting(imgui, key, label, low, high, fmt)
    local value, changed = imgui.SliderFloat(label .. "##WheresEris_" .. key,
                                            tonumber(settings.values[key]) or low,
                                            low, high, fmt or "%.2f")
    if changed then saveSetting(key, value) end
end

-- rom.gui.add_imgui runs this EVERY frame the overlay is open, so without a
-- gate the window is always on screen -- and with several mods installed all
-- of their windows are stacked at once. Closed by default; the menu bar's
-- Settings item is the way in. See MODDING_HADES2.md.
local ui = { showWindow = false }

local function renderWindow()
    if not ui.showWindow then return end
    local imgui = rom.ImGui
    if imgui == nil then return end

    local cond = rom.ImGuiCond and rom.ImGuiCond.FirstUseEver or nil
    if cond ~= nil and type(imgui.SetNextWindowSize) == "function" then
        imgui.SetNextWindowSize(430, 480, cond)
    end

    -- Begin is OUTSIDE the pcall and End follows it unconditionally -- a raise
    -- in the body must not skip End and leave ImGui's window stack corrupted.
    local openState, shouldDraw = imgui.Begin("WheresEris###WheresEris", ui.showWindow)

    local ok, err = pcall(function()
        if shouldDraw then
            imgui.Text("Outlines Eris and marks where she is about to land.")
            imgui.TextDisabled("Applies at her next fight, no restart needed.")
            imgui.Separator()

            checkSetting(imgui, "Enabled", "Enabled")
            imgui.Spacing()
            imgui.Separator()

            imgui.Text("Outline")
            checkSetting(imgui, "Outline", "Outline Eris")
            comboSetting(imgui, "OutlineColor", CONFIG.colorOrder, "Outline color")
            sliderSetting(imgui, "OutlineThickness", "Thickness", 1, 10, "%.0f")
            sliderSetting(imgui, "OutlineOpacity", "Opacity", 0.0, 1.0)
            checkSetting(imgui, "OutlineInDreamDives", "Also outline in Dream Dives")

            imgui.Spacing()
            imgui.Separator()
            imgui.Text("Ground marker")
            checkSetting(imgui, "GroundFx", "Show the ground marker")
            comboSetting(imgui, "GroundFxColor", CONFIG.groundColorOrder, "Ground color")
            sliderSetting(imgui, "GroundFxScale", "Ground size", 0.1, 12.0)

            imgui.Spacing()
            imgui.Separator()
            imgui.Text("Landing marker")
            checkSetting(imgui, "LandingMarker", "Show where she will land")
            comboSetting(imgui, "LandingMarkerColor", CONFIG.colorOrder, "Landing marker color")
            sliderSetting(imgui, "LandingMarkerScale", "Landing marker size", 0.1, 12.0)

            if not settings.persistent then
                imgui.Spacing()
                imgui.Text("Settings are NOT being saved to disk.")
            end
        end
    end)

    imgui.End()
    if openState ~= nil then ui.showWindow = openState end

    if not ok then
        logWarn("overlay panel failed this frame: " .. tostring(err))
    end
end

local function renderMenuBar()
    pcall(function()
        local imgui = rom.ImGui
        if imgui == nil then return end
        if imgui.BeginMenu("WheresEris") then
            if imgui.MenuItem("Settings##WheresEris_menu_settings") then
                ui.showWindow = not ui.showWindow
            end
            imgui.EndMenu()
        end
    end)
end

local function installGui()
    if rom.gui == nil then
        logWarn("rom.gui unavailable; no overlay panel (the .cfg still works)")
        return false
    end
    local ok, err = pcall(function()
        if type(rom.gui.add_imgui) == "function" then
            rom.gui.add_imgui(renderWindow)
        end
        if type(rom.gui.add_to_menu_bar) == "function" then
            rom.gui.add_to_menu_bar(renderMenuBar)
        end
    end)
    if not ok then
        logWarn("overlay panel registration failed: " .. tostring(err))
        return false
    end
    return true
end

-- =============================================================================
-- Boot
-- =============================================================================

-- Seeds Lua's own math.random (never the game's global RNG) so pickSpot's
-- choice varies between sessions.
pcall(function() math.randomseed(os.time()) end)

loadSettings()

-- Runs ONCE. Anything here that ran twice would double up: a second wrap or a
-- second sjson.hook.
local function on_ready(game)
    local artOk = false
    if settings.values.Enabled and settings.values.LandingMarker then
        artOk = registerLandingArt()
    end

    local guiOk = installGui()

    if installHooks(game) then
        logAlways(("installed; overlay panel %s; mod is %s; landing marker art %s%s")
            :format(guiOk and "registered" or "unavailable",
                    settings.values.Enabled and "on" or "off",
                    artOk and "registered" or "not registered",
                    settings.persistent and "" or " (settings not persisted)"))
    end
end

-- Runs on load AND every hot reload; only re-reads settings, installs nothing.
-- sjson registration happens at load only, so a fresh Enabled/LandingMarker
-- toggle after reload will not retroactively register art skipped at boot.
local function on_reload()
    loadSettings()
    logAlways(("settings reloaded; outline %s/%s, ground %s/%s, landing marker %s/%s")
        :format(tostring(settings.values.Outline), tostring(settings.values.OutlineColor),
                tostring(settings.values.GroundFx), tostring(settings.values.GroundFxColor),
                tostring(settings.values.LandingMarker), tostring(settings.values.LandingMarkerColor)))
end

if reload ~= nil and type(reload.auto_single) == "function" then
    local loader = reload.auto_single()
    modutil.once_loaded.game(function()
        local ok, err = pcall(function()
            local game = rom.game
            if game == nil then
                logWarn("rom.game is nil; not installing")
                return
            end
            loader.load(function() on_ready(game) end, on_reload)
        end)
        if not ok then
            logWarn("install failed, plugin inactive: " .. tostring(err))
        end
    end)
else
    logWarn("SGG_Modding-ReLoad unavailable; installing without hot reload")
    modutil.once_loaded.game(function()
        local ok, err = pcall(function()
            local game = rom.game
            if game == nil then
                logWarn("rom.game is nil; not installing")
                return
            end
            on_ready(game)
        end)
        if not ok then
            logWarn("install failed, plugin inactive: " .. tostring(err))
        end
    end)
end

-- Exposed for the test suite only.
return {
    ui = ui,   -- overlay visibility, so tests can open the window
    CONFIG = CONFIG,
    settings = settings,
    saveSetting = saveSetting,
    LANDING_POLL_INTERVAL = LANDING_POLL_INTERVAL,
    IDENTIFIER_POLL_INTERVAL = IDENTIFIER_POLL_INTERVAL,
    TELEPORT_RADIUS = TELEPORT_RADIUS,
    LANDING_ANIMATION_NAME = LANDING_ANIMATION_NAME,
    GROUND_FX = GROUND_FX,
    MARKED_FIELD = MARKED_FIELD,
    LANDING_SPOT_FIELD = LANDING_SPOT_FIELD,
    AIRBORNE_FIELD = AIRBORNE_FIELD,
}
