-- =============================================================================
-- WheresEris (v0.1.0) -- outlines Eris and marks where she is about to land.
-- =============================================================================
-- Goal 1: an outline and a ground marker on Eris, in RealHecate's own
-- vocabulary and palette. Goal 2: a bullseye on the spot she will land on,
-- from takeoff to touchdown. See WHERES_ERIS_SPEC.md (one level up, not
-- shipped) for the design brief; DESIGN.md (repo root, not shipped) for the
-- rationale below.
--
-- Eris exists twice in the scripts (EnemyData_Eris.lua's boss "Eris" and
-- NPCData_Eris.lua's "NPC_Eris_01"). Every hook is scoped to
-- `enemy.Name == "Eris"`, never a bare string match, the way RealHecate
-- guards with `hecate.Name ~= "Hecate"`.
--
-- Facts, verified against the shipped scripts, that force this file's shape:
--
--   * `ErisFlyUp`/`ErisFlyUp_P4` and `ErisFlyDown` are named weapons.
--     `DoWeaponFire` (EnemyAILogic.lua:3923) stamps `aiData.WeaponName` with
--     whichever fired (`GetWeaponAIData`, :5949-5970), so wrapping that one
--     function reports takeoff and landing directly -- no polling needed for
--     the transition itself.
--   * The landing spot does not exist until the instant of the teleport.
--     `HandleEnemyTeleportation` (:1086) calls `SelectSpawnPoint`
--     (EncounterLogic.lua:1071), which shuffles and takes the first id that
--     passes `IsSpawnPointEligible` (:1211). A spot can only be chosen from
--     that same eligible set, then substituted for vanilla's own pick.
--   * `SelectSpawnPoint` shuffles with the run's own seeded RNG, so it must
--     always run for real first -- consuming exactly vanilla's draws -- with
--     only its RESULT discarded. This mod's own picking touches
--     `IsSpawnPointEligible` only (no RNG) and chooses with Lua's own
--     `math.random`, never the game's global one. See DESIGN.md.
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

-- Namespaced fields stashed on the live enemy table, per MODDING_HADES2.md's
-- "namespace state on shared objects" rule -- these are the only things this
-- mod ever writes onto a game object, and none of them outlive the fight
-- (see DESIGN.md, "uninstall risk").
local MARKED_FIELD = "WheresEris_Marked"
local GENERATION_FIELD = "WheresEris_Generation"
local AIRBORNE_FIELD = "WheresEris_Airborne"
local LANDING_GENERATION_FIELD = "WheresEris_LandingGeneration"
local LANDING_SPOT_FIELD = "WheresEris_LandingSpotId"

-- The two takeoff weapons -- ErisFlyUp_P4 (WeaponData_Eris.lua:1520) is
-- ErisFlyUp with MaxUses = 1, used on her fourth phase; both stamp
-- aiData.WeaponName with their own key, not their InheritFrom base.
local FLY_UP_WEAPONS = { ErisFlyUp = true, ErisFlyUp_P4 = true }
local FLY_DOWN_WEAPON = "ErisFlyDown"

-- ErisFlyDown never sets TeleportMaxDistance, so HandleEnemyTeleportation's
-- own default applies (EnemyAILogic.lua:1105: `aiData.TeleportMaxDistance or
-- 1000`). Reproduced here rather than guessed at because it is the radius our
-- own candidate search must match exactly, or it disagrees with vanilla about
-- what is reachable.
local TELEPORT_RADIUS = 1000

-- How often the landing marker rechecks whether its current spot is still
-- eligible. RealHecate's proven cadence is 0.25s; this starts faster because
-- each poll here costs one IsSpawnPointEligible call (a distance and a line
-- of sight check), not a scan of every point -- see WHERES_ERIS_SPEC.md
-- section 6.6. Back off toward 0.25 if a playtest shows it costing frames.
local LANDING_POLL_INTERVAL = 0.1

-- How often the outline/ground-marker watcher checks whether Eris is still
-- alive, so it can detach on death. Matches RealHecate's own cadence; nothing
-- here is time-critical the way the landing poll is.
local IDENTIFIER_POLL_INTERVAL = 0.25

-- =============================================================================
-- Logging
-- =============================================================================

-- Deliberately rom.log.info for warnings too. In this ReturnOfModding build
-- rom.log.error RAISES rather than logs, so reporting a handled failure
-- through it turns that failure fatal. Severity is carried in the text
-- instead.
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

-- Lifted verbatim from Adicon-RealHecate's own palette (src/main.lua:101-112),
-- per WHERES_ERIS_SPEC.md section 5.1: same names, same numbers, so the two
-- mods' color pickers mean the same thing.
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

-- The ground marker additionally accepts None, meaning "leave the art its own
-- gold-orange" -- same convention as RealHecate's GroundFxColor.
CONFIG.groundColorOrder = { "None" }
for _, name in ipairs(CONFIG.colorOrder) do
    CONFIG.groundColorOrder[#CONFIG.groundColorOrder + 1] = name
end

local settings = {
    values = {
        Enabled = true,

        -- Goal 1: identify her.
        Outline = true,
        OutlineColor = "Red",
        OutlineThickness = 6,
        OutlineOpacity = 1.0,
        GroundFx = true,
        GroundFxColor = "Red",
        GroundFxScale = 3.0,
        -- Vanilla already outlines her in a Dream Dive (EnemyData_Eris.lua:281,
        -- gated PathTrue IsDreamRun). Caleb's decision: double up, behind its
        -- own setting, rather than replace vanilla's -- see DESIGN.md.
        OutlineInDreamDives = true,

        -- Goal 2: where she is landing.
        LandingMarker = true,
        LandingMarkerColor = "Red",
        LandingMarkerScale = 3.0,
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
    LandingMarkerScale = "Size of the landing marker, tuned against the arena's own scale.",
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

-- These are the primitives Chalk itself is built on: bind a key with a
-- default, read it with :get(), write it with :set(), flush with :save().
-- House style across all four mods in this family -- see
-- MODDING_HADES2.md section 0 item 4.
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

-- A hand-edited .cfg can hold anything. Resolve to a known preset rather than
-- letting a typo produce a nil color and an invisible marker.
local function resolveColor(chosen, label)
    local rgb = CONFIG.colors[chosen]
    if rgb == nil then
        logWarn("unknown " .. label .. " color " .. tostring(chosen) .. "; falling back to Red")
        rgb = CONFIG.colors.Red
    end
    return rgb
end

-- AddOutline takes 0-255 channels; the presets are stored in 0-1. The single
-- place the conversion happens, same as RealHecate.
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

-- Everything AddOutline needs, resolved from settings. Read fresh at each
-- attach rather than cached, so the dials are live.
function CONFIG.resolvedOutline(objectId)
    local r, g, b = colorTo255(resolveColor(settings.values.OutlineColor, "outline"))
    return {
        Id = objectId,
        R = r, G = g, B = b,
        Opacity = clamp(settings.values.OutlineOpacity, 0, 1, 1.0),
        Thickness = clamp(settings.values.OutlineThickness, 1, 10, 6),
        -- Left constant, matching RealHecate: every outline in the game uses
        -- 0.6 and there is no vanilla precedent for any other value.
        Threshold = 0.6,
    }
end

-- The ground marker's tint as {R, G, B, A} in 0-255, or nil to leave the art
-- its own color. Same mechanism as RealHecate's resolvedGroundColor.
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

-- The landing marker's tint. Unlike the ground marker there is no "None":
-- the keepsake-face art (see LANDING_ANIMATION_NAME below) is a single
-- portrait rather than a plate meant to carry a color, but the setting exists
-- and still tints it, in the same palette as the outline, so the family of
-- colors stays consistent across every dial in this mod.
function CONFIG.resolvedLandingColor()
    local r, g, b = colorTo255(resolveColor(settings.values.LandingMarkerColor, "landing marker"))
    return { r, g, b, 255 }
end

-- =============================================================================
-- Art
-- =============================================================================
-- Goal 1's ground marker reuses vanilla's own ApolloGroundGlow sprite, tinted
-- -- exactly RealHecate's technique (src/main.lua:385-389), no new art
-- registered. It is a ground SPRITE rather than a light for the same reason
-- RealHecate uses one: a light adds to whatever the floor already is and can
-- clip toward white, where a sprite carries its own art.
local GROUND_FX = "ApolloGroundGlow"

-- Goal 2's landing marker needs art vanilla never uses as a ground sprite:
-- her own keepsake face (WHERES_ERIS_SPEC.md section 6.7), already shipped
-- inside GUI.pkg at GUI\Screens\AwardMenu\KeepsakeMaxGift\KeepsakeMaxGift_big
-- \Eris and extracted only to look at, never to re-ship (see
-- _icon-candidates/README.md, "shipped game assets only").
--
-- Registering a NEW Animation entry that points at an existing shipped
-- texture is the same technique SelectFirstBoon ships and has published: its
-- custom tab icons are registered via sjson.hook on
-- Game/Animations/GUI_Screens_VFX.sjson with FilePath naming an existing GUI
-- texture, EndFrame/NumFrames/StartFrame = 1, Material = "Unlit" (a single
-- static frame, not a real animation). That path is confirmed working for
-- CreateScreenComponent (a 2D UI element). Using the SAME registered entry
-- with CreateAnimation to attach it in the 3D world, the way RealHecate
-- attaches ApolloGroundGlow, is the natural extension of a working technique
-- but is NOT independently confirmed -- no mod on this machine has attached a
-- GUI-atlas texture as a world sprite before. This is flagged in DESIGN.md as
-- the one piece of this mod that needs Caleb's playtest before anything else,
-- exactly the shape of risk RealHecate's own history warns about (section 3
-- rule 6: the harness cannot see whether art actually renders).
local LANDING_ANIMATION_NAME = "WheresEris_LandingMarker"
local LANDING_TEXTURE_PATH = [[GUI\Screens\AwardMenu\KeepsakeMaxGift\KeepsakeMaxGift_big\Eris]]
local LANDING_ANIMATIONS_FILE = "Game/Animations/GUI_Screens_VFX.sjson"

-- Registered once, at load, guarded the same way installHooks is (see Boot).
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
        -- Key order mirrors SelectFirstBoon's own registered entries, which
        -- mirror the vanilla ones in this same file.
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

-- True unless this mod should leave Eris untouched: master switch, and the
-- unit-identity guard from WHERES_ERIS_SPEC.md section 3 (never match on the
-- bare string "Eris" anywhere else -- EnemyData_Eris.lua:3103's
-- ObjectTypes = {"Eris","NPC_Eris_01"} matches both units by name alone).
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

-- No detachOutline: unlike RealHecate's clones, Eris is marked exactly once
-- per fight (attachIdentifier runs once, from SetupUnit) and the outline is
-- meant to stay on for the whole fight (WHERES_ERIS_SPEC.md section 5.2:
-- "should stay on throughout"). There is no re-marking cycle that would ever
-- need to strip it back off while she is alive, and on death the engine's own
-- cleanup applies -- same reasoning watchIdentifier already uses for why it
-- does not call StopAnimation there either.

-- Ground marker attach/detach. Called at setup (grounded), and again on every
-- landing/takeoff to hide it in flight -- see WHERES_ERIS_SPEC.md section 5.2:
-- a sprite parented to her would ride up and read as a floating disc; one
-- pinned to the floor sits under empty air while she bombards from Z=800.
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

-- Runs as a game thread for as long as Eris is alive, purely to detach the
-- markers on death -- there is no other clean signal for "the fight ended."
-- Same shape as RealHecate's watchClones: a generation guard retires a
-- superseded watcher (there is one of these per SetupUnit call, i.e. one per
-- fight -- O_Boss01 and O_Boss02 each get their own).
local function watchIdentifier(game, enemy, generation)
    while true do
        if enemy[GENERATION_FIELD] ~= generation then return end
        if game.ActiveEnemies == nil or game.ActiveEnemies[enemy.ObjectId] == nil then
            -- She is dead or the room is gone. DieWithOwner has already taken
            -- any attached art; nothing left to detach.
            enemy[MARKED_FIELD] = false
            return
        end
        game.wait(IDENTIFIER_POLL_INTERVAL)
    end
end

-- Called after SetupUnit has returned (ActivatePrePlaced threads it,
-- EventLogic.lua:127, once per fight -- O_Boss01 and O_Boss02 are separate
-- rooms with separate pre-placed instances).
function CONFIG.attachIdentifier(game, enemy)
    if not isEris(enemy) or enemy.ObjectId == nil then return end
    if not settings.values.Enabled then return end

    local generation = (enemy[GENERATION_FIELD] or 0) + 1
    enemy[GENERATION_FIELD] = generation
    enemy[AIRBORNE_FIELD] = false

    -- Guard against attaching twice onto the same live unit: attachGroundFx's
    -- CreateAnimation is NOT idempotent, so a second call would stack a
    -- second sprite rather than replacing the first -- the same "accumulates"
    -- hazard MODDING_HADES2.md section 2 warns about for re-run hooks.
    -- SetupUnit only fires once per fight in practice, but this costs nothing
    -- and RealHecate guards the equivalent case the same way.
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

-- True only for the exact call WHERES_ERIS_SPEC.md section 6.3 describes: the
-- fly-down teleport, not a spawn. Verified against the real call
-- (EnemyAILogic.lua:1105): args carries RequireLoS/LoSTarget, and the third
-- positional table's SpawnNearId is the hero. The summon path
-- (HandleSpawnerBurst's SpawnOnSpawnPoints branch, EnemyAILogic.lua:4869-4871)
-- sets neither -- its args table is only { RecursiveWait = 0.03 } -- so it
-- always falls through untouched.
function CONFIG.isFlyDownTeleport(game, enemy, encounter, args)
    if not isEris(enemy) then return false end
    if type(args) ~= "table" or not args.RequireLoS or args.LoSTarget == nil then
        return false
    end
    local hero = game.CurrentRun and game.CurrentRun.Hero
    if hero == nil then return false end
    return type(encounter) == "table" and encounter.SpawnNearId == hero.ObjectId
end

-- True when the Oath/Vow shrine is active, which restricts her landing spots
-- to EnemyPointSupport (WHERES_ERIS_SPEC.md section 4.2). Read with the same
-- interpreter GetWeaponAIData itself uses to resolve ErisFlyDown's own
-- ConditionalData (EnemyAILogic.lua:5956-5961: `IsGameStateEligible( enemy,
-- conditionalData.GameStateRequirements)` against
-- `{ NamedRequirements = { "BossDifficultyActive" } }`) -- not re-derived,
-- read the same way vanilla reads it.
local function isBossDifficultyActive(game, enemy)
    if type(game.IsGameStateEligible) ~= "function" then return false end
    local ok, result = pcall(game.IsGameStateEligible, enemy, { NamedRequirements = { "BossDifficultyActive" } })
    return ok and result == true
end

-- The candidate pool SelectSpawnPoint itself would shuffle from
-- (EncounterLogic.lua:1083-1110): GetIdsByType({Name="EnemyPointSupport"})
-- under the Oath shrine, or the room's whole MapState.SpawnPoints otherwise --
-- vanilla only narrows to a named type when RequiredSpawnPoint is set, which
-- happens only under BossDifficultyActive. Read from the live game rather
-- than hardcoded, so a map change moves this mod's pool exactly as it moves
-- vanilla's.
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

-- The exact eligibility args HandleEnemyTeleportation builds for ErisFlyDown
-- (EnemyAILogic.lua:1105-1106), reconstructed independently so this mod can
-- ask the question before the teleport itself happens. RequiredSpawnPoint is
-- included so a summon squeeze that empties EnemyPointSupport is judged the
-- same way vanilla would judge it (WHERES_ERIS_SPEC.md section 4.4/6.4).
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

-- Builds the eligible list with the REAL IsSpawnPointEligible (no RNG
-- touched, per WHERES_ERIS_SPEC.md section 6.2) and returns it, or an empty
-- table if nothing is eligible right now -- the §4.4/§6.4 corner case.
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

-- Our own random source, never the game's global RNG (WHERES_ERIS_SPEC.md
-- section 6.2) -- picking here must not move the seed the run's boons and
-- rooms are drawn from.
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

-- Moves the marker to a freshly picked spot, detaching the old one first.
-- Returns the new spot id, or nil if nothing is eligible right now (hides the
-- marker rather than leaving it on a spot that has gone illegal).
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

-- Runs as a game thread from takeoff to landing. Polls at
-- LANDING_POLL_INTERVAL; if the current spot still passes
-- IsSpawnPointEligible, it is left alone; otherwise a fresh spot is picked
-- and the marker moves. Ends on landing (the generation bump in onFlyDown),
-- on death, or when a newer takeoff supersedes it -- same belt-and-braces
-- shape as RealHecate's watchClones.
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
            moveMarkerTo(game, enemy, pickSpot(game, enemy))
        end

        game.wait(LANDING_POLL_INTERVAL)
    end
end

-- Called from the DoWeaponFire wrap when Eris fires ErisFlyUp/ErisFlyUp_P4.
function CONFIG.onFlyUp(game, enemy)
    enemy[AIRBORNE_FIELD] = true

    if settings.values.GroundFx then
        detachGroundFx(game, enemy)
    end

    if not settings.values.LandingMarker then return end

    local generation = (enemy[LANDING_GENERATION_FIELD] or 0) + 1
    enemy[LANDING_GENERATION_FIELD] = generation
    moveMarkerTo(game, enemy, pickSpot(game, enemy))
    game.thread(watchLanding, game, enemy, generation)
end

-- Called from the DoWeaponFire wrap when Eris fires ErisFlyDown. Freezes the
-- landing marker (WHERES_ERIS_SPEC.md section 6.1 step 4: whatever it shows
-- is the destination) by retiring the watcher, and restores the ground
-- marker now that she is grounded again.
function CONFIG.onFlyDown(game, enemy)
    enemy[AIRBORNE_FIELD] = false
    enemy[LANDING_GENERATION_FIELD] = (enemy[LANDING_GENERATION_FIELD] or 0) + 1

    if settings.values.GroundFx then
        attachGroundFx(game, enemy)
    end
end

-- Called when the wrapped SelectSpawnPoint's REAL result is nil for the
-- fly-down teleport -- vanilla found nowhere to send her
-- (WHERES_ERIS_SPEC.md section 6.4). Hides the marker rather than leaving it
-- somewhere she will not actually go.
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

    -- Goal 1: attach the outline/ground marker once, when she is set up.
    -- ActivatePrePlaced threads SetupUnit for every pre-placed unit it
    -- activates (EventLogic.lua:127), including Eris in both O_Boss01 and
    -- O_Boss02 -- one call per fight.
    ModUtil.Path.Wrap("SetupUnit", function(base, unit, currentRun, args)
        base(unit, currentRun, args)
        if not isEris(unit) or not settings.values.Enabled then return end
        local ok, err = pcall(CONFIG.attachIdentifier, game, unit)
        if not ok then
            logWarn("could not mark Eris, leaving her unmarked: " .. tostring(err))
        end
    end)

    -- Goal 1 (hide/restore) and goal 2 (pick/freeze): both keyed off which
    -- weapon just fired. DoWeaponFire stamps aiData.WeaponName
    -- (GetWeaponAIData, EnemyAILogic.lua:5970) with the exact weapon key, so
    -- one wrap here covers both takeoff and landing for both features.
    ModUtil.Path.Wrap("DoWeaponFire", function(base, enemy, aiData)
        base(enemy, aiData)
        if not isEris(enemy) or not settings.values.Enabled then return end

        local weaponName = aiData and aiData.WeaponName
        if FLY_UP_WEAPONS[weaponName] then
            local ok, err = pcall(CONFIG.onFlyUp, game, enemy)
            if not ok then logWarn("fly-up handling failed: " .. tostring(err)) end
        elseif weaponName == FLY_DOWN_WEAPON then
            local ok, err = pcall(CONFIG.onFlyDown, game, enemy)
            if not ok then logWarn("fly-down handling failed: " .. tostring(err)) end
        end
    end)

    -- Goal 2's RNG-parity substitution (WHERES_ERIS_SPEC.md section 6.2/6.3).
    -- base() runs FIRST and unconditionally, so it consumes exactly the
    -- draws vanilla would from the run's seeded RNG, whether or not this mod
    -- ends up using its result.
    ModUtil.Path.Wrap("SelectSpawnPoint", function(base, currentRoom, enemy, encounter, args, depth)
        local real = base(currentRoom, enemy, encounter, args, depth)

        if not settings.values.Enabled or not settings.values.LandingMarker then return real end
        if not CONFIG.isFlyDownTeleport(game, enemy, encounter, args) then return real end

        if real == nil then
            -- Vanilla found nowhere to send her either. Never substitute a
            -- spot where vanilla had none (section 6.4).
            local ok, err = pcall(CONFIG.onNoLanding, game, enemy)
            if not ok then logWarn("could not clear the landing marker: " .. tostring(err)) end
            return nil
        end

        local marked = enemy[LANDING_SPOT_FIELD]
        if marked ~= nil then
            local ok, passes = pcall(game.IsSpawnPointEligible, marked, encounter, currentRoom, args)
            if ok and passes then
                return marked
            end
        end

        -- Our own tracked spot is missing or went stale since the last poll.
        -- Fall back to vanilla's own real pick rather than inventing one --
        -- never worse than not having the mod installed.
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

local function renderWindow()
    local imgui = rom.ImGui
    if imgui == nil then return end

    local cond = rom.ImGuiCond and rom.ImGuiCond.FirstUseEver or nil
    if cond ~= nil and type(imgui.SetNextWindowSize) == "function" then
        imgui.SetNextWindowSize(430, 480, cond)
    end

    -- Begin is OUTSIDE the pcall and End follows it unconditionally -- a
    -- raise anywhere in the body must not skip End and leave ImGui with an
    -- unclosed window, corrupting the overlay for every mod, not just this
    -- one (see RealHecate's own comment and test 10c.7 on this exact shape).
    local shouldDraw = imgui.Begin("WheresEris")

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
                imgui.TextDisabled("settings are NOT being saved to disk")
            end
        end
    end)

    imgui.End()

    if not ok then
        logWarn("overlay panel failed this frame: " .. tostring(err))
    end
end

local function renderMenuBar()
    pcall(function()
        local imgui = rom.ImGui
        if imgui == nil then return end
        if imgui.BeginMenu("WheresEris") then
            if imgui.MenuItem("Marker enabled##WheresEris_menu_enabled") then
                saveSetting("Enabled", not settings.values.Enabled)
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

-- Seeds Lua's OWN math.random, never the game's global RNG (see the header
-- and WHERES_ERIS_SPEC.md section 6.2) -- pickSpot's choice among eligible
-- spots must vary between sessions without ever touching the run's seed.
-- Guarded because a sandboxed environment could plausibly remove os.time.
pcall(function() math.randomseed(os.time()) end)

loadSettings()

-- Runs ONCE. Anything here that ran twice would double up: a second
-- ModUtil.Path.Wrap would nest another wrapper around the same three
-- functions, and a second sjson.hook would register the landing art twice.
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

-- Runs on load AND on every hot reload, so it must be safe to repeat. Only
-- re-reads settings and reports them; it installs nothing. sjson
-- registration happens at load only (see CONTRIBUTING.md caveat on this),
-- so a color/scale change here is live but a fresh Enabled->true after
-- reload will not retroactively register art that was skipped at boot.
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
    -- ReLoad is a declared dependency, but a profile can be missing it.
    -- Falling back costs hot reload and nothing else.
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

-- Exposed for the test suite only. The game ignores the return value of a
-- plugin chunk, so this costs nothing at runtime.
return {
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
