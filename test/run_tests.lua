-- WheresEris test suite. Run from this directory:
--     lua run_tests.lua
--     luajit run_tests.lua
--
-- Both interpreters, always -- the game ships LuaJIT, and the two differ in
-- ways that have caught real bugs in sibling mods on this account.

local PLUGIN = "../src/main.lua"
local HARNESS = "./harness.lua"
local M = dofile("./mocks.lua")

local passed, failed = 0, 0
local failures = {}

-- Assertions must FAIL, not raise: a regression that makes a value nil must
-- read as one red line, not abort the run and hide every later section.
local function check(name, condition, detail)
  if condition then
    passed = passed + 1
  else
    failed = failed + 1
    detail = detail and tostring(detail) or nil
    if detail and #detail > 140 then
      detail = detail:sub(1, 137) .. "..."
    end
    failures[#failures + 1] = name .. (detail and ("  -- " .. detail) or "")
  end
end

local function at(t, k)
  if type(t) ~= "table" then return nil end
  return t[k]
end

local function logsContain(needle)
  for _, line in ipairs(M.logs or {}) do
    if tostring(line):find(needle, 1, true) then return true end
  end
  return false
end

-- Boots the plugin against fresh fakes. With no arguments this is EXACTLY the
-- shipping configuration: the mock config store starts empty, so every key
-- binds to the plugin's own default (rule 1: test the configuration that
-- actually ships).
local function boot(initial, opts)
  opts = opts or {}
  local G = dofile(HARNESS)
  local realSelectSpawnPoint = G.SelectSpawnPoint  -- captured before the plugin wraps it
  M.install(G, opts.configOpts, initial,
            { absent = opts.noSjson, throw = opts.sjsonThrows }, { noReload = opts.noReload, noGui = opts.noGui },
            opts.gui)
  if opts.noModUtil then G.ModUtil = nil end
  local plugin = dofile(PLUGIN)
  if M.pendingGameLoad then M.pendingGameLoad() end
  G.realSelectSpawnPoint = realSelectSpawnPoint
  return G, plugin
end

-- =============================================================================
-- 1. What actually ships
-- =============================================================================
do
  local G, plugin = boot()
  local v = at(at(plugin, "settings"), "values")

  check("1.1 ships enabled", at(v, "Enabled") == true)
  check("1.2 ships the outline on, Red, thickness 6, opacity 1.0",
        at(v, "Outline") == true and at(v, "OutlineColor") == "Red"
        and at(v, "OutlineThickness") == 6 and at(v, "OutlineOpacity") == 1.0)
  check("1.3 ships the ground marker on, Red, scale 3.0",
        at(v, "GroundFx") == true and at(v, "GroundFxColor") == "Red" and at(v, "GroundFxScale") == 3.0)
  check("1.4 ships OutlineInDreamDives on", at(v, "OutlineInDreamDives") == true)
  check("1.5 ships the landing marker on, Red",
        at(v, "LandingMarker") == true and at(v, "LandingMarkerColor") == "Red")
  check("1.6 settings persist when rom.config is available",
        at(at(plugin, "settings"), "persistent") == true)
  check("1.7 exactly three functions are wrapped, once each",
        at(G.wrapped, "SetupUnit") == 1 and at(G.wrapped, "DoWeaponFire") == 1
        and at(G.wrapped, "SelectSpawnPoint") == 1,
        ("SetupUnit=%s DoWeaponFire=%s SelectSpawnPoint=%s")
          :format(tostring(at(G.wrapped, "SetupUnit")), tostring(at(G.wrapped, "DoWeaponFire")),
                  tostring(at(G.wrapped, "SelectSpawnPoint"))))
  local extra = 0
  for k in pairs(G.wrapped) do
    if k ~= "SetupUnit" and k ~= "DoWeaponFire" and k ~= "SelectSpawnPoint" then extra = extra + 1 end
  end
  check("1.8 and nothing else", extra == 0, tostring(extra))
  check("1.9 the landing art is registered on GUI_Screens_VFX.sjson",
        M.hookedFile ~= nil and tostring(M.hookedFile):find("GUI_Screens_VFX.sjson", 1, true) ~= nil,
        tostring(M.hookedFile))
  check("1.10 the registered entry points at the real keepsake-face texture, unaltered",
        M.animations ~= nil and M.animations.Animations[1] ~= nil
        and M.animations.Animations[1].FilePath == [[GUI\Screens\AwardMenu\KeepsakeMaxGift\KeepsakeMaxGift_big\Eris]],
        M.animations and M.animations.Animations[1] and tostring(M.animations.Animations[1].FilePath))
end

-- =============================================================================
-- 2. Scoping -- never match on the bare name (WHERES_ERIS_SPEC.md section 3)
-- =============================================================================
do
  local G, plugin = boot()
  -- EnemyData_Eris.lua:3103's ObjectTypes = {"Eris","NPC_Eris_01"} means a
  -- unit named "NPC_Eris_01" exists and must never be marked.
  local npc = { ObjectId = 950000, Name = "NPC_Eris_01" }
  G.ActiveEnemies[npc.ObjectId] = npc
  G.SetupUnit(npc, G.CurrentRun, {})
  check("2.1 NPC_Eris_01 gets no outline", G.outlines[npc.ObjectId] == nil)
  check("2.2 NPC_Eris_01 gets no ground marker", G.attachedCount(plugin.GROUND_FX, npc.ObjectId) == 0)

  G.DoWeaponFire(npc, { WeaponName = "ErisFlyUp" })
  check("2.3 a non-Eris unit firing a same-named weapon is ignored",
        npc[plugin.LANDING_SPOT_FIELD] == nil)
end

-- =============================================================================
-- 3. Goal 1 -- the outline and ground marker
-- =============================================================================
do
  local G, plugin = boot()
  local eris = G.spawnEris()
  G.SetupUnit(eris, G.CurrentRun, {})
  check("3.1 outline attached on setup", G.outlines[eris.ObjectId] ~= nil)
  check("3.2 ground marker attached on setup", G.attachedCount(plugin.GROUND_FX, eris.ObjectId) == 1)
  check("3.3 outline color resolves to the Red preset (255,38,26)",
        G.outlines[eris.ObjectId].R == 255 and G.outlines[eris.ObjectId].G == 38
        and G.outlines[eris.ObjectId].B == 26,
        ("R=%s G=%s B=%s"):format(tostring(G.outlines[eris.ObjectId].R),
                                   tostring(G.outlines[eris.ObjectId].G), tostring(G.outlines[eris.ObjectId].B)))
end

do
  -- Fly up: ground marker hides, outline stays (unaffected by height).
  local G, plugin = boot()
  local eris = G.spawnEris()
  G.SetupUnit(eris, G.CurrentRun, {})
  G.DoWeaponFire(eris, G.flyUpAiData("ErisFlyUp"))
  check("3.4 ground marker hidden while airborne", G.attachedCount(plugin.GROUND_FX, eris.ObjectId) == 0)
  check("3.5 outline stays on through takeoff", G.outlines[eris.ObjectId] ~= nil)

  G.DoWeaponFire(eris, G.flyDownAiData())
  check("3.6 ground marker restored on landing", G.attachedCount(plugin.GROUND_FX, eris.ObjectId) == 1)
  check("3.7 outline stays on through landing", G.outlines[eris.ObjectId] ~= nil)
end

do
  -- ErisFlyUp_P4 (WeaponData_Eris.lua:1520, MaxUses=1 on phase 4) must be
  -- recognized as a takeoff exactly like ErisFlyUp.
  local G, plugin = boot()
  local eris = G.spawnEris()
  G.SetupUnit(eris, G.CurrentRun, {})
  G.DoWeaponFire(eris, G.flyUpAiData("ErisFlyUp_P4"))
  check("3.8 ErisFlyUp_P4 is treated as a takeoff", G.attachedCount(plugin.GROUND_FX, eris.ObjectId) == 0)
  check("3.9 and picks a landing marker", eris[plugin.LANDING_SPOT_FIELD] ~= nil)
end

do
  -- GroundFxColor = None leaves the art its own color: no Color arg passed.
  local G, plugin = boot({ GroundFxColor = "None" })
  local eris = G.spawnEris()
  G.SetupUnit(eris, G.CurrentRun, {})
  local create = G.created[1]
  check("3.10 GroundFxColor=None passes no Color argument",
        create ~= nil and create.Color == nil)
end

do
  -- Outline disabled entirely: no ground-marker behavior changes.
  local G, plugin = boot({ Outline = false })
  local eris = G.spawnEris()
  G.SetupUnit(eris, G.CurrentRun, {})
  check("3.11 Outline=false attaches no outline", G.outlines[eris.ObjectId] == nil)
  check("3.12 but the ground marker is unaffected", G.attachedCount(plugin.GROUND_FX, eris.ObjectId) == 1)
end

do
  -- SetupUnit firing twice on the same live unit must not stack a second
  -- ground sprite -- CreateAnimation is not idempotent the way AddOutline is.
  local G, plugin = boot()
  local eris = G.spawnEris()
  G.SetupUnit(eris, G.CurrentRun, {})
  G.SetupUnit(eris, G.CurrentRun, {})
  check("3.13 a second SetupUnit on the same unit does not stack the ground marker",
        G.attachedCount(plugin.GROUND_FX, eris.ObjectId) == 1)
  -- AddOutline is idempotent (an absolute set, not a stack -- see
  -- MODDING_HADES2.md section 2), so this is a survives-a-second-call sanity
  -- check rather than a count assertion: nothing here can observe whether
  -- AddOutline was called once or twice, only that the outline still exists.
  check("3.14 and the outline is still present", G.outlines[eris.ObjectId] ~= nil)
end

-- =============================================================================
-- 4. Dream Dive doubling (WHERES_ERIS_SPEC.md section 5.3)
-- =============================================================================
do
  local G, plugin = boot()
  G.CurrentRun.IsDreamRun = true
  local eris = G.spawnEris()
  G.SetupUnit(eris, G.CurrentRun, {})
  check("4.1 OutlineInDreamDives=true (default) still applies this mod's outline",
        G.outlines[eris.ObjectId] ~= nil)
end

do
  local G, plugin = boot({ OutlineInDreamDives = false })
  G.CurrentRun.IsDreamRun = true
  local eris = G.spawnEris()
  G.SetupUnit(eris, G.CurrentRun, {})
  check("4.2 OutlineInDreamDives=false leaves a Dream run with vanilla's outline only",
        G.outlines[eris.ObjectId] == nil)
end

do
  -- The Dream gate must not leak into a normal fight.
  local G, plugin = boot({ OutlineInDreamDives = false })
  G.CurrentRun.IsDreamRun = false
  local eris = G.spawnEris()
  G.SetupUnit(eris, G.CurrentRun, {})
  check("4.3 OutlineInDreamDives=false does not affect a normal fight",
        G.outlines[eris.ObjectId] ~= nil)
end

-- =============================================================================
-- 5. Goal 2 -- the landing marker: case 1 (lands on a real eligible spot)
-- =============================================================================
do
  local G, plugin = boot()
  local eris = G.spawnEris()
  G.DoWeaponFire(eris, G.flyUpAiData("ErisFlyUp"))
  local spot = eris[plugin.LANDING_SPOT_FIELD]
  check("5.1 a spot was picked", spot ~= nil)

  local encounter, args = G.flyDownSelectArgs()
  check("5.2 the picked spot passes the REAL IsSpawnPointEligible",
        spot ~= nil and G.IsSpawnPointEligible(spot, encounter, G.CurrentRun.CurrentRoom, args) == true)
  check("5.3 the marker sprite was actually created there",
        G.attachedCount(plugin.LANDING_ANIMATION_NAME, spot) == 1)
end

-- =============================================================================
-- 6. Case 2/3 -- the poll: moves on invalidation, holds still otherwise
-- =============================================================================
do
  local G, plugin = boot()
  local eris = G.spawnEris()
  G.DoWeaponFire(eris, G.flyUpAiData("ErisFlyUp"))
  local before = eris[plugin.LANDING_SPOT_FIELD]

  -- Case 3: player does not move, nothing changes -- no new create/stop.
  local createdBefore, stoppedBefore = #G.created, #G.stopped
  G.tick()
  check("6.1 an unchanged spot is left alone (case 3)", eris[plugin.LANDING_SPOT_FIELD] == before)
  check("6.2 and nothing was re-created or stopped",
        #G.created == createdBefore and #G.stopped == stoppedBefore)

  -- Case 2: the player's movement invalidates the CURRENT spot specifically
  -- (modeled here as a line-of-sight break, the same effect a wall crossing
  -- would have), while other candidates stay in range -- a real
  -- IsSpawnPointEligible check must confirm both halves, not this mod's own
  -- say-so. The real IsSpawnPointEligible itself calls wait(0.02) on a failed
  -- LoS check (EncounterLogic.lua:1311), which yields mid-check inside the
  -- coroutine -- so settling one full poll iteration can cost more than one
  -- tick when a candidate fails LoS. tick(50) is generous against a 30-point
  -- candidate pool.
  G.blockedLoS[before] = true
  G.tick(50)
  local after = eris[plugin.LANDING_SPOT_FIELD]
  check("6.3 an invalidated spot moves (case 2)", after ~= before)
  local encounter, args = G.flyDownSelectArgs()
  check("6.4 the new spot is ALSO really eligible",
        after ~= nil and G.IsSpawnPointEligible(after, encounter, G.CurrentRun.CurrentRoom, args) == true)
  check("6.5 the old marker was detached and the new one created",
        G.attachedCount(plugin.LANDING_ANIMATION_NAME, before) == 0
        and G.attachedCount(plugin.LANDING_ANIMATION_NAME, after) == 1)
end

-- =============================================================================
-- 7. Case 4 -- real SelectSpawnPoint returns nil -> we return nil, no marker
-- =============================================================================
do
  local G, plugin = boot()
  local eris = G.spawnEris()
  G.DoWeaponFire(eris, G.flyUpAiData("ErisFlyUp"))
  check("7.1 a marker exists after takeoff (sanity)", eris[plugin.LANDING_SPOT_FIELD] ~= nil)

  -- Block line of sight to EVERY candidate so the real fallback ladder has
  -- nothing left (WHERES_ERIS_SPEC.md section 6.4: RequiredSpawnPoint and
  -- SpawnRadius are never relaxed, so this weapon has no rescue path).
  for _, id in ipairs(G.MapState.SpawnPoints) do G.blockedLoS[id] = true end

  local encounter, args = G.flyDownSelectArgs()
  local result = G.SelectSpawnPoint(G.CurrentRun.CurrentRoom, eris, encounter, args)
  check("7.2 the wrap returns nil when the real function does",
        result == nil)
  check("7.3 the marker is cleared, not left on a stale spot",
        eris[plugin.LANDING_SPOT_FIELD] == nil)
end

-- =============================================================================
-- 8. Case 5 -- a summon call passes through unchanged
-- =============================================================================
do
  local G, plugin = boot()
  local eris = G.spawnEris()

  local encounter, args = G.summonSelectArgs(eris)
  local encounter2, args2 = G.summonSelectArgs(eris)

  G.resetRngDrawCount()
  local wrapped = G.SelectSpawnPoint(G.CurrentRun.CurrentRoom, eris, encounter, args)
  local wrappedDraws = G.rngDrawCount

  G.resetRngDrawCount()
  local real = G.realSelectSpawnPoint(G.CurrentRun.CurrentRoom, eris, encounter2, args2)
  local realDraws = G.rngDrawCount

  check("8.1 the summon call is not recognized as the fly-down teleport",
        plugin.CONFIG.isFlyDownTeleport({ CurrentRun = G.CurrentRun }, eris, encounter, args) == false)
  check("8.2 the wrapped result equals the real, unwrapped result",
        wrapped == real, ("wrapped=%s real=%s"):format(tostring(wrapped), tostring(real)))
  check("8.3 and it consumed the same number of RNG draws",
        wrappedDraws == realDraws, ("wrapped=%s real=%s"):format(tostring(wrappedDraws), tostring(realDraws)))
  check("8.4 a summon call never touches the landing-marker field",
        eris[plugin.LANDING_SPOT_FIELD] == nil)
end

-- =============================================================================
-- 8b. isFlyDownTeleport's SpawnNearId clause, exercised directly -- section 8
-- above proves the summon shape is rejected via its missing RequireLoS/
-- LoSTarget, which does not by itself prove the SEPARATE SpawnNearId check
-- does anything (a sabotage that deletes only that clause left section 8
-- green, because the earlier RequireLoS check already rejects the summon
-- shape for its own reason). This is rule 7 in miniature: a guard is not
-- proven until something reaches it and is turned back BY IT specifically.
-- =============================================================================
do
  local G, plugin = boot()
  local eris = G.spawnEris()
  local fakeGame = { CurrentRun = G.CurrentRun }

  check("8b.1 the real fly-down shape matches",
        plugin.CONFIG.isFlyDownTeleport(fakeGame, eris, G.flyDownSelectArgs()) == true)

  -- Same RequireLoS/LoSTarget shape as the real call, but aimed at something
  -- other than the hero -- must NOT match, or a future call with a coincidental
  -- LoS check would be treated as the landing teleport.
  local otherEncounter = { SpawnNearId = 999999, SpawnRadius = 1000 }
  local sameArgs = { AllowNoSpawnPoint = true, RequireLoS = true, LoSTarget = G.CurrentRun.Hero.ObjectId }
  check("8b.2 the same LoS shape aimed at someone other than the hero does not match",
        plugin.CONFIG.isFlyDownTeleport(fakeGame, eris, otherEncounter, sameArgs) == false)

  -- LoSTarget missing entirely, everything else matching.
  local encounter3, args3 = G.flyDownSelectArgs()
  args3.LoSTarget = nil
  check("8b.3 a missing LoSTarget does not match", plugin.CONFIG.isFlyDownTeleport(fakeGame, eris, encounter3, args3) == false)

  -- Not Eris.
  local other = { ObjectId = 700001, Name = "Charybdis" }
  local encounter4, args4 = G.flyDownSelectArgs()
  check("8b.4 the same shape on a different enemy does not match",
        plugin.CONFIG.isFlyDownTeleport(fakeGame, other, encounter4, args4) == false)
end

-- =============================================================================
-- 9. Case 6 -- RNG draw count is identical with the mod on and off
-- =============================================================================
do
  local encounterOn, argsOn = nil, nil
  local G1, plugin1 = boot({ Enabled = true, LandingMarker = true })
  local eris1 = G1.spawnEris()
  encounterOn, argsOn = G1.flyDownSelectArgs()
  G1.resetRngDrawCount()
  G1.SelectSpawnPoint(G1.CurrentRun.CurrentRoom, eris1, encounterOn, argsOn)
  local drawsOn = G1.rngDrawCount

  local G2, plugin2 = boot({ Enabled = false })
  local eris2 = G2.spawnEris()
  local encounterOff, argsOff = G2.flyDownSelectArgs()
  G2.resetRngDrawCount()
  G2.SelectSpawnPoint(G2.CurrentRun.CurrentRoom, eris2, encounterOff, argsOff)
  local drawsOff = G2.rngDrawCount

  check("9.1 the run's RNG draws the same number of times whether the mod is on or off",
        drawsOn == drawsOff and drawsOn > 0,
        ("on=%s off=%s"):format(tostring(drawsOn), tostring(drawsOff)))
end

do
  -- Same claim, under the Oath shrine, where the candidate pool is the six
  -- EnemyPointSupport ids rather than the whole map (a different draw count
  -- than the case above, which is the point: it must still match on vs off).
  local G1 = boot({ Enabled = true, LandingMarker = true })
  G1.OathActive = true
  local eris1 = G1.spawnEris()
  local encounterOn, argsOn = G1.flyDownSelectArgs()
  G1.resetRngDrawCount()
  G1.SelectSpawnPoint(G1.CurrentRun.CurrentRoom, eris1, encounterOn, argsOn)
  local drawsOn = G1.rngDrawCount

  local G2 = boot({ Enabled = false })
  G2.OathActive = true
  local eris2 = G2.spawnEris()
  local encounterOff, argsOff = G2.flyDownSelectArgs()
  G2.resetRngDrawCount()
  G2.SelectSpawnPoint(G2.CurrentRun.CurrentRoom, eris2, encounterOff, argsOff)
  local drawsOff = G2.rngDrawCount

  check("9.2 same claim under the Oath shrine's smaller candidate pool",
        drawsOn == drawsOff and drawsOn > 0 and drawsOn == 6,
        ("on=%s off=%s"):format(tostring(drawsOn), tostring(drawsOff)))
end

-- =============================================================================
-- 10. The corner case -- Oath shrine, every EnemyPointSupport point occupied
-- =============================================================================
do
  -- WHERES_ERIS_SPEC.md section 4.4/6.4/12.6: six adds on six points can leave
  -- her no legal spot at all under the Oath shrine.
  local G, plugin = boot()
  G.OathActive = true
  local eris = G.spawnEris()
  for _, id in ipairs(G.SUPPORT_IDS) do
    G.SessionMapState.SpawnPointsUsed[id] = 123456  -- occupied by a summoned add
  end

  local eligible = {}
  for _, id in ipairs(G.SUPPORT_IDS) do
    local encounter, args = G.flyDownSelectArgs()
    if G.IsSpawnPointEligible(id, encounter, G.CurrentRun.CurrentRoom, args) then
      eligible[#eligible + 1] = id
    end
  end
  check("10.1 sanity: the real function agrees nothing is eligible", #eligible == 0)

  local encounter, args = G.flyDownSelectArgs()
  local result = G.SelectSpawnPoint(G.CurrentRun.CurrentRoom, eris, encounter, args)
  check("10.2 no teleport: the real function returns nil", result == nil)

  -- Drive it through the actual takeoff/landing hook, not just the raw call.
  G.DoWeaponFire(eris, G.flyUpAiData("ErisFlyUp"))
  check("10.3 no bullseye: takeoff with a fully-occupied support set picks nothing",
        eris[plugin.LANDING_SPOT_FIELD] == nil)
end

-- =============================================================================
-- 11. Case 7 -- ground marker hidden while airborne, restored on landing
--     (also covered in section 3; repeated here against the spec's own
--     numbering so the mapping from spec to test is traceable)
-- =============================================================================
do
  local G, plugin = boot()
  local eris = G.spawnEris()
  G.SetupUnit(eris, G.CurrentRun, {})
  G.DoWeaponFire(eris, G.flyUpAiData("ErisFlyUp"))
  check("11.1 hidden on takeoff", G.attachedCount(plugin.GROUND_FX, eris.ObjectId) == 0)
  G.DoWeaponFire(eris, G.flyDownAiData())
  check("11.2 restored on landing", G.attachedCount(plugin.GROUND_FX, eris.ObjectId) == 1)
end

-- =============================================================================
-- 11b. Case 4/step 4 -- landing FREEZES the marker: the watcher stops, and the
-- marker stays showing exactly where she landed rather than being cleared.
-- =============================================================================
do
  local G, plugin = boot()
  local eris = G.spawnEris()
  G.DoWeaponFire(eris, G.flyUpAiData("ErisFlyUp"))
  local landedSpot = eris[plugin.LANDING_SPOT_FIELD]
  check("11.3 a spot exists before landing (sanity)", landedSpot ~= nil)

  G.DoWeaponFire(eris, G.flyDownAiData())
  check("11.4 landing does not clear the marker", eris[plugin.LANDING_SPOT_FIELD] == landedSpot)
  check("11.5 the sprite is still attached at the landing spot",
        G.attachedCount(plugin.LANDING_ANIMATION_NAME, landedSpot) == 1)

  -- The watcher must be retired, not merely coincidentally quiet: invalidate
  -- the frozen spot and prove ticking no longer moves it.
  G.blockedLoS[landedSpot] = true
  G.tick(50)
  check("11.6 the frozen marker does not move even when its spot goes ineligible",
        eris[plugin.LANDING_SPOT_FIELD] == landedSpot)
  check("11.7 and no thread is still polling for it", G.liveThreadCount() == 0)
end

-- =============================================================================
-- 12. Case 9 -- every setting off: every wrap passes through, fight untouched
-- =============================================================================
do
  local G, plugin = boot({ Enabled = false })
  local eris = G.spawnEris()

  G.SetupUnit(eris, G.CurrentRun, {})
  check("12.1 no outline when disabled", G.outlines[eris.ObjectId] == nil)
  check("12.2 no ground marker when disabled", G.attachedCount(plugin.GROUND_FX, eris.ObjectId) == 0)

  G.DoWeaponFire(eris, G.flyUpAiData("ErisFlyUp"))
  check("12.3 no landing marker when disabled", eris[plugin.LANDING_SPOT_FIELD] == nil)

  local encounter, args = G.flyDownSelectArgs()
  local encounter2, args2 = G.flyDownSelectArgs()
  local wrapped = G.SelectSpawnPoint(G.CurrentRun.CurrentRoom, eris, encounter, args)
  local real = G.realSelectSpawnPoint(G.CurrentRun.CurrentRoom, eris, encounter2, args2)
  check("12.4 SelectSpawnPoint is byte-identical to vanilla when disabled",
        wrapped == real, ("wrapped=%s real=%s"):format(tostring(wrapped), tostring(real)))
end

-- =============================================================================
-- 13. Robustness
-- =============================================================================
do
  local G, plugin = boot()
  M.onReload()
  M.onReload()
  M.onReload()
  check("13.1 repeated reloads do not nest the SetupUnit wrap", at(G.wrapped, "SetupUnit") == 1)
  check("13.2 or the DoWeaponFire wrap", at(G.wrapped, "DoWeaponFire") == 1)
  check("13.3 or the SelectSpawnPoint wrap", at(G.wrapped, "SelectSpawnPoint") == 1)
end

do
  local G = boot(nil, { noModUtil = true })
  check("13.4 no ModUtil is reported, not raised", logsContain("ModUtil.Path.Wrap unavailable"))
  check("13.5 and nothing was wrapped", next(G.wrapped) == nil)
end

do
  local G = boot(nil, { noSjson = true })
  check("13.6 no SGG_Modding-SJSON is reported, not raised",
        logsContain("SGG_Modding-SJSON unavailable"))
  check("13.7 and the other hooks still install", at(G.wrapped, "SetupUnit") == 1)
end

do
  -- A failure while marking Eris must not take the fight down with it.
  local G, plugin = boot()
  local eris = G.spawnEris()
  local realAddOutline = G.AddOutline
  G.AddOutline = function() error("simulated AddOutline failure") end
  local ok = pcall(G.SetupUnit, eris, G.CurrentRun, {})
  check("13.8 a failure attaching the identifier does not raise", ok == true)
  check("13.9 and it is logged", logsContain("could not mark Eris"))
  G.AddOutline = realAddOutline
end

-- =============================================================================
-- 14. Overlay panel
-- =============================================================================
do
  local G, plugin = boot()
  check("14.1 the panel registers", M.guiCallbacks.window ~= nil)
  check("14.2 the menu bar entry registers", M.guiCallbacks.menuBar ~= nil)
end

do
  boot()
  M.guiCallbacks.window()
  check("14.3 Begin and End balance on a normal frame", at(M.depth, "window") == 0)
end

do
  boot(nil, { gui = { errorInBody = true } })
  local ok = pcall(M.guiCallbacks.window)
  check("14.4 a failure in the body does not escape the panel", ok == true)
  check("14.5 and the window is still closed", at(M.depth, "window") == 0)
  check("14.6 and it is logged", logsContain("overlay panel failed"))
end

do
  local G, plugin = boot()
  M.guiCallbacks.window()
  M.guiCallbacks.menuBar()
  local values = at(at(plugin, "settings"), "values")
  local orphans, seen = {}, {}
  for _, l in ipairs(M.labels) do
    local key = tostring(l):match("##WheresEris_([A-Za-z]+)")
    if key and not seen[key] then
      seen[key] = true
      if values[key] == nil then orphans[#orphans + 1] = key end
    end
  end
  check("14.7 every panel widget names a real setting", #orphans == 0, table.concat(orphans, ", "))

  local missing = {}
  for key in pairs(values) do
    if not seen[key] then missing[#missing + 1] = key end
  end
  table.sort(missing)
  check("14.8 and every setting has a widget", #missing == 0, table.concat(missing, ", "))
end

do
  local G, plugin = boot(nil, { gui = { toggle = "Enabled##WheresEris_Enabled" } })
  check("14.9 starts enabled", at(at(plugin, "settings"), "values").Enabled == true)
  M.guiCallbacks.window()
  check("14.10 the checkbox flips the setting", at(at(plugin, "settings"), "values").Enabled == false)
  check("14.11 and persists it to the config store", M.store.Enabled == false)
end

do
  local G, plugin = boot(nil, { noGui = true })
  check("14.12 a missing rom.gui is reported, not raised", logsContain("rom.gui unavailable"))
  check("14.13 and the hooks still install", at(G.wrapped, "SetupUnit") == 1)
end

do
  local _, plugin = boot()
  local values = at(at(plugin, "settings"), "values")
  local missing = {}
  for key in pairs(values) do
    if M.bound[key] == nil or M.bound[key].description == "" then
      missing[#missing + 1] = key
    end
  end
  table.sort(missing)
  check("14.14 every setting has a description in the .cfg", #missing == 0, table.concat(missing, ", "))
end

-- =============================================================================
-- 15. Packaging -- the files that ship
-- =============================================================================
local function readFile(path)
  local f = io.open(path, "r")
  if f == nil then return nil end
  local t = f:read("*a"); f:close(); return t
end

do
  local toml = readFile("../thunderstore.toml")
  local mf = readFile("../src/manifest.json")
  check("15.1 thunderstore.toml exists", toml ~= nil)
  check("15.2 src/manifest.json exists", mf ~= nil)

  local tv = toml and toml:match('versionNumber%s*=%s*"([^"]+)"') or nil
  local mv = mf and mf:match('"version_number"%s*:%s*"([^"]+)"') or nil
  check("15.3 both declare a version", tv ~= nil and mv ~= nil)
  check("15.4 and the versions agree", tv == mv, "toml=" .. tostring(tv) .. " manifest=" .. tostring(mv))

  check("15.5 namespace matches the manifest", toml and toml:match('namespace%s*=%s*"([^"]+)"') == "Adicon")
  check("15.6 name matches the manifest", toml and toml:match('\nname%s*=%s*"([^"]+)"') == "WheresEris")
end

do
  local toml = readFile("../thunderstore.toml") or ""
  local mf = readFile("../src/manifest.json") or ""
  local tomlDeps = {}
  for name, ver in toml:gmatch('\n([%w_]+%-[%w_]+)%s*=%s*"([%d%.]+)"') do
    tomlDeps[name] = ver
  end
  local missing = {}
  for full in mf:gmatch('"([%w_]+%-[%w_]+%-[%d%.]+)"') do
    local name, ver = full:match("^(.-)%-([%d%.]+)$")
    if name and tomlDeps[name] ~= ver then
      missing[#missing + 1] = full .. " vs " .. tostring(tomlDeps[name])
    end
  end
  check("15.7 every manifest dependency matches the toml", #missing == 0, table.concat(missing, ", "))
end

do
  local cl = readFile("../CHANGELOG.md") or ""
  check("15.8 CHANGELOG has an ## [Unreleased] heading, brackets included",
        cl:match("##%s*%[Unreleased%]") ~= nil)
end

do
  local toml = readFile("../thunderstore.toml") or ""
  local sources = {}
  for src in toml:gmatch('source%s*=%s*"([^"]+)"') do
    sources[#sources + 1] = src
  end
  check("15.9 the build copies exactly three things", #sources == 3, table.concat(sources, ", "))

  local allowed = { ["./CHANGELOG.md"] = true, ["./LICENSE"] = true, ["./src"] = true }
  local unexpected = {}
  for _, src in ipairs(sources) do
    if not allowed[src] then unexpected[#unexpected + 1] = src end
  end
  check("15.10 and nothing beyond CHANGELOG, LICENSE and src", #unexpected == 0, table.concat(unexpected, ", "))
end

do
  for _, f in ipairs({ "../icon.png", "../README.md", "../CHANGELOG.md",
                       "../LICENSE", "../src/main.lua", "../guard.sh", "../CONTRIBUTING.md" }) do
    check("15.11 build input exists: " .. f, readFile(f) ~= nil)
  end
end

-- =============================================================================

print(("WheresEris: %d passed, %d failed"):format(passed, failed))
for _, f in ipairs(failures) do print("  FAIL  " .. f) end
if failed > 0 then os.exit(1) end
