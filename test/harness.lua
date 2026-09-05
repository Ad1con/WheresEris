-- Fake game globals for WheresEris. Per MODDING_HADES2.md section 3 rule 5,
-- this pulls the REAL bodies of SelectSpawnPoint and IsSpawnPointEligible out
-- of Content\Scripts rather than writing simplified stand-ins, plus a
-- cooperative thread scheduler (copied from Adicon-RealHecate's own harness)
-- so the suite can drive the landing-marker poll deterministically instead of
-- sleeping.
--
-- Ported verbatim, with citations (current as of 2026-09-05; re-check against
-- the live scripts if a patch has moved things -- WHERES_ERIS_SPEC.md says the
-- same):
--
--   SelectSpawnPoint         EncounterLogic.lua:1071
--   IsSpawnPointEligible     EncounterLogic.lua:1211
--   FYShuffle                UtilityLogic.lua:1016
--
-- One requirement is deliberately NOT ported to the depth AlwaysChaosGates
-- ported IsGameStateEligible: BossDifficultyActive resolves through
-- IsBossDifficultyShrineUpgradeActive (ShrineLogic.lua:939), which reads
-- CurrentRun.EnteredBiomes, GameState.ShrineUpgrades and a Dream-run biome
-- map. This mod's own logic does not reimplement that decision -- it only
-- asks the real game for the answer and routes on it. The harness therefore
-- models the ORACLE directly as a settable flag (G.OathActive) rather than
-- porting vanilla's own shrine-upgrade bookkeeping, which is not this mod's
-- correctness surface. See DESIGN.md, "What is deliberately not ported."

local unpack = table.unpack or unpack

local G = {}

-- ---------------------------------------------------------------- state ----

G.ActiveEnemies = {}
G.CurrentRun = {
  IsDreamRun = false,
  CurrentRoom = { Name = "O_Boss01", SpawnPoints = {} },
  Hero = { ObjectId = 500000 },
}
G.GameState = {}

-- The real O_Boss01 EnemyPointSupport ids and coordinates, decoded with
-- HadesMapper (WHERES_ERIS_SPEC.md section 4.5) -- a diagonal line spanning
-- ~1194 units. Used verbatim rather than invented, per section 8: "exact
-- distances; a stub with different geometry would let wrong logic pass."
G.SUPPORT_IDS = { 744265, 744267, 744272, 744330, 744331, 744332 }
local SUPPORT_POS = {
  [744265] = { X = 6188, Y = 9585 },
  [744267] = { X = 6477, Y = 9420 },
  [744272] = { X = 6684, Y = 9261 },
  [744330] = { X = 6857, Y = 9156 },
  [744331] = { X = 7009, Y = 9022 },
  [744332] = { X = 7177, Y = 8916 },
}

-- A generic ring of ordinary EnemyPoint ids around the same neighborhood, far
-- enough apart that the 1000-unit teleport radius (WHERES_ERIS_SPEC.md
-- section 4.3/6.1) actually includes some and excludes others -- the property
-- the eligibility tests need, not the real O_Boss01 EnemyPoint layout itself.
G.ENEMY_POINT_IDS = {}
local ENEMY_POINT_POS = {}
for i = 1, 24 do
  local id = 800000 + i
  G.ENEMY_POINT_IDS[i] = id
  local angle = (i - 1) * (2 * math.pi / 24)
  -- Half the ring within 1000 units of the hero's spawn (below), half beyond
  -- it, so "median ~half eligible" (section 4.5's own measurement) is a
  -- property the fixture actually has, not just the real map.
  local radius = (i % 2 == 0) and 600 or 1400
  ENEMY_POINT_POS[id] = { X = 6600 + radius * math.cos(angle), Y = 9200 + radius * math.sin(angle) }
end

G.Positions = { [G.CurrentRun.Hero.ObjectId] = { X = 6600, Y = 9200 } }
for id, pos in pairs(SUPPORT_POS) do G.Positions[id] = pos end
for id, pos in pairs(ENEMY_POINT_POS) do G.Positions[id] = pos end

G.MapState = {
  SpawnPoints = (function()
    local all = {}
    for _, id in ipairs(G.ENEMY_POINT_IDS) do all[#all + 1] = id end
    for _, id in ipairs(G.SUPPORT_IDS) do all[#all + 1] = id end
    return all
  end)(),
  RewardPointsUsed = {},
  CyclingSpawnPoints = {},
}

G.SessionMapState = { SpawnPointsUsed = {}, DistanceCache = {} }

-- Whether the Oath/Vow shrine is active, per the DESIGN.md note above: a
-- direct stand-in for IsBossDifficultyShrineUpgradeActive's return value, not
-- a port of its own bookkeeping.
G.OathActive = false

-- Spot ids currently blocked from line of sight, controllable per test.
G.blockedLoS = {}

G.wrapped = {}
G.logs = {} -- filled by mocks.lua's rom.log.info; read here too for convenience

-- ------------------------------------------------------------- threading ----
-- The game runs these as coroutines and resumes them on its own clock. Here
-- the suite is the clock: thread() starts the body immediately (matching the
-- game, which runs a threaded function up to its first wait), and tick()
-- advances it. Copied from Adicon-RealHecate's test/harness.lua, which this
-- mod's own watcher threads are modeled on.

G.threads = {}
G.threadErrors = {}

function G.thread(fn, ...)
  local args = { ... }
  local co = coroutine.create(function() fn(unpack(args)) end)
  G.threads[#G.threads + 1] = { co = co }
  local ok, err = coroutine.resume(co)
  if not ok then G.threadErrors[#G.threadErrors + 1] = tostring(err) end
  return co
end

-- Faithful enough for logic tests: yields when called from inside a game
-- thread (so the suite's tick() can pace it), and is a no-op otherwise. Real
-- IsSpawnPointEligible calls wait(0.02) on a failed line-of-sight check
-- (EncounterLogic.lua:1311) even when invoked synchronously (this mod's own
-- onFlyUp is not itself threaded), and the real engine tolerates that; a bare
-- Lua coroutine.yield would not, so this guards on coroutine.isyieldable()
-- rather than assuming every caller is a thread.
function G.wait(seconds)
  if coroutine.isyieldable() then
    coroutine.yield(seconds)
  end
end
wait = G.wait

-- Resume every suspended thread once per tick. Returns how many were resumed.
function G.tick(count)
  local resumed = 0
  for _ = 1, (count or 1) do
    for _, t in ipairs(G.threads) do
      if coroutine.status(t.co) == "suspended" then
        resumed = resumed + 1
        local ok, err = coroutine.resume(t.co)
        if not ok then G.threadErrors[#G.threadErrors + 1] = tostring(err) end
      end
    end
  end
  return resumed
end

function G.liveThreadCount()
  local n = 0
  for _, t in ipairs(G.threads) do
    if coroutine.status(t.co) == "suspended" then n = n + 1 end
  end
  return n
end

-- --------------------------------------------------------------- ModUtil ----

G.ModUtil = {
  Path = {
    Wrap = function(name, wrapper)
      local base = G[name]
      if base == nil then
        error("ModUtil.Path.Wrap called on a global the harness does not define: " .. tostring(name))
      end
      G.wrapped[name] = (G.wrapped[name] or 0) + 1
      G[name] = function(...) return wrapper(base, ...) end
    end,
  },
}

-- ------------------------------------------------------------ animations ----

G.created = {}
G.stopped = {}
G.events = {}
G.outlines = {}

function G.CreateAnimation(args)
  G.created[#G.created + 1] = args
  G.events[#G.events + 1] = { kind = "create", Name = args.Name, DestinationId = args.DestinationId }
  return 700000 + #G.created
end

function G.StopAnimation(args)
  G.stopped[#G.stopped + 1] = args
  G.events[#G.events + 1] = { kind = "stop", Name = args.Name, DestinationId = args.DestinationId }
end

-- Any copy of `name` currently attached to `objectId`, replaying the
-- interleaved event stream (one stop clears any number of stacked creates).
function G.attachedCount(name, objectId)
  local n = 0
  for _, e in ipairs(G.events) do
    if e.Name == name and e.DestinationId == objectId then
      if e.kind == "create" then n = n + 1 else n = 0 end
    end
  end
  return n
end

function G.AddOutline(args)
  G.outlines[args.Id] = args
end

function G.RemoveOutline(args)
  G.outlines[args.Id] = nil
end

-- -------------------------------------------------------------- SetupUnit ----
-- Minimal on purpose: this mod's own SetupUnit wrap does not depend on
-- vanilla's body (unlike RealHecate's dependence on UnitSplit's SplitIds), it
-- only needs to run AFTER whatever vanilla does. Real signature,
-- RoomLogic.lua:3214.
function G.SetupUnit(unit, currentRun, args)
  unit.IsSetUp = true
end

-- ------------------------------------------------------------ DoWeaponFire ----
-- Also minimal: this mod's wrap reads aiData.WeaponName, which the test sets
-- directly (matching how GetWeaponAIData really stamps it,
-- EnemyAILogic.lua:5970), not something DoWeaponFire's own body computes.
-- Real signature, EnemyAILogic.lua:3923.
G.weaponFireCalls = {}
function G.DoWeaponFire(enemy, aiData)
  G.weaponFireCalls[#G.weaponFireCalls + 1] = { enemy = enemy, weaponName = aiData and aiData.WeaponName }
end

-- --------------------------------------------------------- ported reals ----

-- Bare globals: the pasted bodies below reference these unprefixed, exactly
-- as the game's own scripts do.
CurrentRun = G.CurrentRun
GameState = G.GameState
ActiveEnemies = G.ActiveEnemies
MapState = G.MapState
SessionMapState = G.SessionMapState

function ShallowCopyTable(t)
  local copy = {}
  for k, v in pairs(t or {}) do copy[k] = v end
  return copy
end

function Contains(t, v)
  for _, item in pairs(t or {}) do
    if item == v then return true end
  end
  return false
end

function GetIdsByType(args)
  if args and args.Name == "EnemyPointSupport" then
    return ShallowCopyTable(G.SUPPORT_IDS)
  end
  if args and args.Name == "EnemyPoint" then
    return ShallowCopyTable(G.ENEMY_POINT_IDS)
  end
  return {}
end
G.GetIdsByType = GetIdsByType

function GetDistance(args)
  local a, b = G.Positions[args.Id], G.Positions[args.DestinationId]
  if a == nil or b == nil then return 0 end
  local dx, dy = a.X - b.X, a.Y - b.Y
  return math.sqrt(dx * dx + dy * dy)
end

-- MinPlayerArc/MaxPlayerArc are never set on either table this mod passes
-- (WHERES_ERIS_SPEC.md section 6.3's own args), so IsSpawnPointEligible's arc
-- branch is always skipped in every test here. These exist only so the ported
-- body has something callable if that ever changes.
function GetAngle() return 0 end
function GetAngleBetween() return 0 end
function CalcArcDistance() return 0 end
function GetClosest() return 0 end
function GetClosestIds() return {} end

function HasLineOfSight(args)
  if G.blockedLoS[args.Id] then return false end
  return true
end

function RemoveValueAndCollapse(t, v)
  for i, item in ipairs(t) do
    if item == v then table.remove(t, i); return end
  end
end

-- A deterministic fake RNG: no real randomness, just a draw counter. Its
-- return values are irrelevant to the test that matters (case 6: the DRAW
-- COUNT must be identical with the mod on and off) -- what the shuffle
-- produces is not asserted on, only how many times it drew.
G.rngDrawCount = 0
local FakeRng = {}
function FakeRng:Random(a, b)
  G.rngDrawCount = G.rngDrawCount + 1
  if a ~= nil and b ~= nil then return a end
  if a ~= nil then return a end
  return 0.5
end
function GetGlobalRng() return FakeRng end
function RandomNumber(number, rng)
  rng = rng or GetGlobalRng()
  return rng:Random(number)
end
G.GetGlobalRng = GetGlobalRng
G.RandomNumber = RandomNumber
function G.resetRngDrawCount() G.rngDrawCount = 0 end

-- FYShuffle, UtilityLogic.lua:1016, verbatim.
function FYShuffle(tInput)
    local tReturn = {}
    for i = #tInput, 1, -1 do
        local j = RandomNumber(i)
        tInput[i], tInput[j] = tInput[j], tInput[i]
        table.insert(tReturn, tInput[i])
    end
    return tReturn
end
G.FYShuffle = FYShuffle

local function isEmptyImpl(t)
  if t == nil then return true end
  if type(t) ~= "table" then return false end
  return next(t) == nil
end
IsEmpty = isEmptyImpl

-- BossDifficultyActive is modeled as a direct oracle, not ported -- see the
-- file header and DESIGN.md.
function IsGameStateEligible(source, requirements, args)
  if type(requirements) == "table" and requirements.NamedRequirements ~= nil then
    for _, name in ipairs(requirements.NamedRequirements) do
      if name == "BossDifficultyActive" then
        if not G.OathActive then return false end
      else
        error("harness IsGameStateEligible: unmodeled NamedRequirement " .. tostring(name))
      end
    end
    return true
  end
  return true
end
G.IsGameStateEligible = IsGameStateEligible

-- IsSpawnPointEligible, EncounterLogic.lua:1211, verbatim.
function IsSpawnPointEligible( spawnPointId, encounter, currentRoom, args )

	if SessionMapState.SpawnPointsUsed[spawnPointId] ~= nil then
		return false
	end

	if args.CheckRewardPointsUsed and MapState.RewardPointsUsed[spawnPointId] ~= nil then
		return false
	end

	if args.IgnoreIds ~= nil and Contains(args.IgnoreIds, spawnPointId) then
		return false
	end

	if encounter.SpawnNearId ~= nil and encounter.SpawnRadius ~= nil then
		SessionMapState.DistanceCache[spawnPointId] = SessionMapState.DistanceCache[spawnPointId] or {}
		if encounter.ForceDistanceCalculation or encounter.SpawnNearId == CurrentRun.Hero.ObjectId or ActiveEnemies[encounter.SpawnNearId] ~= nil then
			SessionMapState.DistanceCache[spawnPointId][encounter.SpawnNearId] = GetDistance({ Id = spawnPointId, DestinationId = encounter.SpawnNearId })
		end
		local distance = SessionMapState.DistanceCache[spawnPointId][encounter.SpawnNearId] or GetDistance({ Id = spawnPointId, DestinationId = encounter.SpawnNearId })
		SessionMapState.DistanceCache[spawnPointId][encounter.SpawnNearId] = distance
		if distance > encounter.SpawnRadius then
			return false
		end
		if encounter.SpawnRadiusMin ~= nil and distance < encounter.SpawnRadiusMin then
			return false
		end
	end

	if args.SpawnNearId ~= nil and args.SpawnRadius ~= nil then
		local distance = GetDistance({ Id = spawnPointId, DestinationId = args.SpawnNearId })
		if distance > args.SpawnRadius then
			return false
		end
		if args.SpawnRadiusMin ~= nil and distance < args.SpawnRadiusMin then
			return false
		end
	end

	local minPlayerArc = args.MinPlayerArc or encounter.MinPlayerArc
	local maxPlayerArc = args.MaxPlayerArc or encounter.MaxPlayerArc
	if minPlayerArc ~= nil or maxPlayerArc ~= nil then
		local arcDistance = CalcArcDistance( GetAngle({ Id = CurrentRun.Hero.ObjectId }), GetAngleBetween({ Id = CurrentRun.Hero.ObjectId, DestinationId = spawnPointId }) )
		if minPlayerArc ~= nil and arcDistance < minPlayerArc then
			return false
		end

		if maxPlayerArc ~= nil and arcDistance > maxPlayerArc then
			return false
		end
	end

	if args.RequireMinEndPointDistance ~= nil then
		local endPoint = currentRoom.HeroEndPoint or GetClosest({ Id = CurrentRun.Hero.ObjectId, DestinationIds = GetIdsByType({ Name = "HeroEnd" }) }) or CurrentRun.Hero.ObjectId
		local closestEndPoint = GetClosest({ Id = spawnPointId, DestinationId = endPoint, Distance = args.RequireMinEndPointDistance })
		if closestEndPoint ~= 0 then
			return false
		end
	end

	local distanceToHero = nil
	if encounter.RequireMinPlayerDistance ~= nil and currentRoom.HeroEndPoint ~= nil then
		distanceToHero = distanceToHero or GetDistance({ Id = CurrentRun.Hero.ObjectId, DestinationId = spawnPointId })
		if distanceToHero < encounter.RequireMinPlayerDistance then
			return false
		end
	end

	if encounter.RequireNearPlayerDistance ~= nil then
		distanceToHero = distanceToHero or GetDistance({ Id = CurrentRun.Hero.ObjectId, DestinationId = spawnPointId })
		if distanceToHero > encounter.RequireNearPlayerDistance then
			return false
		end
	end

	if encounter.EligibleSpawnPoints ~= nil then
		if not Contains(encounter.EligibleSpawnPoints, spawnPointId) then
			return false
		end
	end

	if args.SpawnAwayFromTypes ~= nil then
		local typeIds = GetClosestIds({ Id = spawnPointId, DestinationIds = GetIdsByType({ Names = args.SpawnAwayFromTypes }), Distance = args.SpawnAwayFromTypesDistance or 300 })
		if #typeIds > 0 then
			return false
		end
	end

	if args.SpawnCloseToGroup ~= nil then
		local typeIds = GetClosestIds({ Id = spawnPointId, DestinationIds = GetIds({ Name = args.SpawnCloseToGroup }), Distance = args.SpawnCloseToGroupDistance or 300 })
		if #typeIds == 0 then
			return false
		end
	end

	if args.RequireLoS then
		local hasLoS = HasLineOfSight({ Id = spawnPointId, DestinationId = args.LoSTarget, StopsUnits = true,
							LineOfSightBuffer = args.LoSBuffer or 50,
							LineOfSightEndBuffer = args.LoSEndBuffer or 50,  })
		if not hasLoS then
			wait( 0.02 ) -- Distribute workload
			return false
		end
	end

	return true
end
G.IsSpawnPointEligible = IsSpawnPointEligible

-- SelectSpawnPoint, EncounterLogic.lua:1071, verbatim.
function SelectSpawnPoint( currentRoom, enemy, encounter, args, depth )

	args = args or {}
	enemy = enemy or {}
	encounter = encounter or {}
	depth = (depth or 0) + 1

	if encounter.SpawnOnProximitySpawnTrigger then
		return encounter.ProximitySpawnTriggerId
	end

	local shuffledSpawnPointIds = {}
	local requiredSpawnPointType = args.RequiredSpawnPoint or enemy.RequiredSpawnPoint or encounter.RequiredSpawnPoint
	if requiredSpawnPointType ~= nil then
		if currentRoom.SpawnPoints[requiredSpawnPointType] == nil then
			local ids = GetIdsByType({ Name = requiredSpawnPointType })
			table.sort( ids )
			currentRoom.SpawnPoints[requiredSpawnPointType] = ShallowCopyTable( ids )
		end
		shuffledSpawnPointIds = FYShuffle( currentRoom.SpawnPoints[requiredSpawnPointType] or MapState.SpawnPoints )
	elseif args.CycleSpawnPoints then
		if IsEmpty( MapState.CyclingSpawnPoints ) then
			MapState.CyclingSpawnPoints = FYShuffle( MapState.SpawnPoints )
		end
		shuffledSpawnPointIds = MapState.CyclingSpawnPoints
	elseif args.PreferredSpawnPointGroup then
		shuffledSpawnPointIds = FYShuffle( GetIds({ Name = args.PreferredSpawnPointGroup }) )
	elseif args.PreferredSpawnPoint then
		local ids = GetIdsByType({ Name = args.PreferredSpawnPoint })
		table.sort( ids )
		shuffledSpawnPointIds = FYShuffle( ids )
	elseif enemy.PreferredSpawnPoint ~= nil then
		if currentRoom.SpawnPoints[enemy.PreferredSpawnPoint] == nil then
			currentRoom.SpawnPoints[enemy.PreferredSpawnPoint] = ShallowCopyTable( GetIdsByType({ Name = enemy.PreferredSpawnPoint }) )
		end
		shuffledSpawnPointIds = FYShuffle( currentRoom.SpawnPoints[enemy.PreferredSpawnPoint] or MapState.SpawnPoints )
	else
		shuffledSpawnPointIds = FYShuffle( encounter.NearbySpawnPoints or MapState.SpawnPoints )
	end

	args.SpawnAwayFromTypes = args.SpawnAwayFromTypes or enemy.SpawnAwayFromTypes
	args.SpawnAwayFromTypesDistance = args.SpawnAwayFromTypesDistance or enemy.SpawnAwayFromTypesDistance
	args.SpawnCloseToGroup = args.SpawnCloseToGroup or enemy.SpawnCloseToGroup

	for k, id in ipairs( shuffledSpawnPointIds ) do
		if IsSpawnPointEligible( id, encounter, currentRoom, args ) then
			if args.CycleSpawnPoints then
				RemoveValueAndCollapse( MapState.CyclingSpawnPoints, id )
			end
			return id
		end
	end

	-- Nothing eligible
	if args.SpawnCloseToGroup ~= nil then
		args.SpawnCloseToGroup = nil
		enemy.SpawnCloseToGroup = nil
		wait( args.RecursiveWait )
		local id = SelectSpawnPoint( currentRoom, enemy, encounter, args, depth )
		return id
	end
	if args.PreferredSpawnPointGroup ~= nil then
		args.PreferredSpawnPointGroup = nil
		wait( args.RecursiveWait )
		local id = SelectSpawnPoint( currentRoom, enemy, encounter, args, depth )
		return id
	end
	if args.PreferredSpawnPoint ~= nil then
		args.PreferredSpawnPoint = nil
		wait( args.RecursiveWait )
		local id = SelectSpawnPoint( currentRoom, enemy, encounter, args, depth )
		return id
	end
	if enemy.PreferredSpawnPoint ~= nil then
		enemy.PreferredSpawnPoint = nil
		wait( args.RecursiveWait )
		local id = SelectSpawnPoint( currentRoom, enemy, encounter, args, depth )
		return id
	end

	if args.RequireMinEndPointDistance ~= nil and args.RequireMinEndPointDistance > 100 then
		args.RequireMinEndPointDistance = args.RequireMinEndPointDistance * 0.5
		wait( args.RecursiveWait )
		local id = SelectSpawnPoint( currentRoom, enemy, encounter, args, depth )
		return id
	end

	if encounter.RequireNearPlayerDistance ~= nil and encounter.RequireNearPlayerDistance < 50000 then
		encounter.RequireNearPlayerDistance = encounter.RequireNearPlayerDistance * 1.5
		wait( args.RecursiveWait )
		local id = SelectSpawnPoint( currentRoom, enemy, encounter, args, depth )
		return id
	end

	if encounter.RequireMinPlayerDistance ~= nil and encounter.RequireMinPlayerDistance > 100 then
		encounter.RequireMinPlayerDistance = encounter.RequireMinPlayerDistance * 0.5
		wait( args.RecursiveWait )
		local id = SelectSpawnPoint( currentRoom, enemy, encounter, args, depth )
		return id
	end

	if encounter.MinPlayerArc ~= nil then
		encounter.MinPlayerArc = nil
		wait( args.RecursiveWait )
		local id = SelectSpawnPoint( currentRoom, enemy, encounter, args, depth )
		return id
	end

	if args.AllowNoSpawnPoint then
		return
	end

	if encounter.Name ~= nil then
		SessionMapState.SpawnPointsUsed = {}
	end
end
G.SelectSpawnPoint = SelectSpawnPoint

-- ---------------------------------------------------------------- helpers ----

-- Spawns the real Eris into ActiveEnemies, the way ActivatePrePlaced's
-- SetupUnit thread would (EventLogic.lua:127).
function G.spawnEris()
  local id = 900001
  local eris = { ObjectId = id, Name = "Eris" }
  G.ActiveEnemies[id] = eris
  G.Positions[id] = { X = G.Positions[G.CurrentRun.Hero.ObjectId].X, Y = G.Positions[G.CurrentRun.Hero.ObjectId].Y }
  return eris
end

function G.killUnit(unit)
  G.ActiveEnemies[unit.ObjectId] = nil
end

-- WeaponData_Eris.lua-shaped aiData for the two weapons this mod cares about,
-- matching what GetWeaponAIData really stamps (EnemyAILogic.lua:5949-5970).
function G.flyUpAiData(weaponName)
  return { WeaponName = weaponName or "ErisFlyUp", TargetId = G.CurrentRun.Hero.ObjectId }
end

function G.flyDownAiData()
  return { WeaponName = "ErisFlyDown", TargetId = G.CurrentRun.Hero.ObjectId }
end

-- The exact encounter/args shape HandleEnemyTeleportation builds for
-- ErisFlyDown (EnemyAILogic.lua:1105-1106), for tests that call
-- SelectSpawnPoint directly rather than through onFlyDown.
function G.flyDownSelectArgs()
  local encounter = { SpawnNearId = G.CurrentRun.Hero.ObjectId, SpawnRadius = 1000 }
  local args = {
    RequiredSpawnPoint = G.OathActive and "EnemyPointSupport" or nil,
    AllowNoSpawnPoint = true,
    RequireLoS = true,
    LoSTarget = G.CurrentRun.Hero.ObjectId,
  }
  return encounter, args
end

-- The summon path's shape (HandleSpawnerBurst's SpawnOnSpawnPoints branch,
-- EnemyAILogic.lua:4869-4871): no RequireLoS at all, which is exactly what
-- must make it fall through this mod's wrap untouched.
function G.summonSelectArgs(enemy)
  local encounter = { ForceDistanceCalculation = true, SpawnNearId = enemy.ObjectId, SpawnRadius = 900 }
  local args = { RecursiveWait = 0.03 }
  return encounter, args
end

return G
