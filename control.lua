-- imports

local entityUtils = require("libs/EntityUtils")
local mapUtils = require("libs/MapUtils")
local unitGroupUtils = require("libs/UnitGroupUtils")
local chunkProcessor = require("libs/ChunkProcessor")
local baseProcessor = require("libs/BaseProcessor")
local mapProcessor = require("libs/MapProcessor")
local constants = require("libs/Constants")
local pheromoneUtils = require("libs/PheromoneUtils")
local aiDefense = require("libs/AIDefense")
local aiAttack = require("libs/AIAttack")
local aiBuilding = require("libs/AIBuilding")
local aiPlanning = require("libs/AIPlanning")
local interop = require("libs/Interop")
local tests = require("tests")
local upgrade = require("Upgrade")
local baseUtils = require("libs/BaseUtils")
local mathUtils = require("libs/MathUtils")

-- constants

local INTERVAL_LOGIC = constants.INTERVAL_LOGIC
local INTERVAL_PROCESS = constants.INTERVAL_PROCESS

local MOVEMENT_PHEROMONE = constants.MOVEMENT_PHEROMONE

-- imported functions

local roundToNearest = mathUtils.roundToNearest

-- imported functions

local getChunkByPosition = mapUtils.getChunkByPosition

local processPendingChunks = chunkProcessor.processPendingChunks

local processMap = mapProcessor.processMap
local processPlayers = mapProcessor.processPlayers
local scanMap = mapProcessor.scanMap

local planning = aiPlanning.planning

local rallyUnits = aiBuilding.rallyUnits

local deathScent = pheromoneUtils.deathScent
local victoryScent = pheromoneUtils.victoryScent

local cleanSquads = unitGroupUtils.cleanSquads
local regroupSquads = unitGroupUtils.regroupSquads
local convertUnitGroupToSquad = unitGroupUtils.convertUnitGroupToSquad

local squadAttack = aiAttack.squadAttack
local squadBeginAttack = aiAttack.squadBeginAttack

local retreatUnits = aiDefense.retreatUnits

local addRemovePlayerEntity = entityUtils.addRemovePlayerEntity
local unregisterEnemyBaseStructure = baseUtils.unregisterEnemyBaseStructure
local registerEnemyBaseStructure = baseUtils.registerEnemyBaseStructure
local makeImmortalEntity = entityUtils.makeImmortalEntity

local processBases = baseProcessor.processBases

-- local references to global

local regionMap
local natives
local pendingChunks

-- hook functions

local function onLoad()
    regionMap = global.regionMap
    natives = global.natives
    pendingChunks = global.pendingChunks
end

local function onChunkGenerated(event)
    -- queue generated chunk for delayed processing, queuing is required because some mods (RSO) mess with chunk as they
    -- are generated, which messes up the scoring.
    if (event.surface.index == 1) then
        pendingChunks[#pendingChunks+1] = event
    end
end

local function rebuildRegionMap()
    game.surfaces[1].print("Rampant - Reindexing chunks, please wait.")
    -- clear old regionMap processing Queue
    -- prevents queue adding duplicate chunks
    -- chunks are by key, so should overwrite old

    global.regionMap = {}
    regionMap = global.regionMap
    regionMap.processQueue = {}
    regionMap.processPointer = 1
    regionMap.scanPointer = 1

    -- switched over to tick event
    regionMap.logicTick = roundToNearest(game.tick + INTERVAL_LOGIC, INTERVAL_LOGIC)
    regionMap.processTick = roundToNearest(game.tick + INTERVAL_PROCESS, INTERVAL_PROCESS)
    
    -- clear pending chunks, will be added when loop runs below
    pendingChunks = {}

    -- queue all current chunks that wont be generated during play
    local surface = game.surfaces[1]
    local tick = game.tick
    for chunk in surface.get_chunks() do
	onChunkGenerated({ tick = tick,
			   surface = surface, 
			   area = { left_top = { x = chunk.x * 32,
						 y = chunk.y * 32 }}})
    end
end

local function onModSettingsChange(event)
    
    if event and (string.sub(event.setting, 1, 7) ~= "rampant") then
	return false
    end
    
    upgrade.compareTable(natives, "safeBuildings", settings.global["rampant-safeBuildings"].value)   
    
    upgrade.compareTable(natives.safeEntities, "curved-rail", settings.global["rampant-safeBuildings-curvedRail"].value)
    upgrade.compareTable(natives.safeEntities, "straight-rail", settings.global["rampant-safeBuildings-straightRail"].value)
    upgrade.compareTable(natives.safeEntities, "rail-signal", settings.global["rampant-safeBuildings-railSignals"].value)
    upgrade.compareTable(natives.safeEntities, "rail-chain-signal", settings.global["rampant-safeBuildings-railChainSignals"].value)
    upgrade.compareTable(natives.safeEntities, "train-stop", settings.global["rampant-safeBuildings-trainStops"].value)

    local changed, newValue = upgrade.compareTable(natives.safeEntityName,
						   "big-electric-pole",
						   settings.global["rampant-safeBuildings-bigElectricPole"].value)
    if changed then
	natives.safeEntityName["big-electric-pole"] = newValue
	natives.safeEntityName["big-electric-pole-2"] = newValue
	natives.safeEntityName["big-electric-pole-3"] = newValue
	natives.safeEntityName["big-electric-pole-4"] = newValue
    end
    
    upgrade.compareTable(natives, "attackUsePlayer", settings.global["rampant-attackWaveGenerationUsePlayerProximity"].value)
    upgrade.compareTable(natives, "attackUsePollution", settings.global["rampant-attackWaveGenerationUsePollution"].value)
    
    upgrade.compareTable(natives, "attackThresholdMin", settings.global["rampant-attackWaveGenerationThresholdMin"].value)
    upgrade.compareTable(natives, "attackThresholdMax", settings.global["rampant-attackWaveGenerationThresholdMax"].value)
    upgrade.compareTable(natives, "attackThresholdRange", natives.attackThresholdMax - natives.attackThresholdMin)
    upgrade.compareTable(natives, "attackWaveMaxSize", settings.global["rampant-attackWaveMaxSize"].value)
    upgrade.compareTable(natives, "attackPlayerThreshold", settings.global["rampant-attackPlayerThreshold"].value)
    upgrade.compareTable(natives, "aiNocturnalMode", settings.global["rampant-permanentNocturnal"].value)
    upgrade.compareTable(natives, "aiPointsScaler", settings.global["rampant-aiPointsScaler"].value)

    changed, newValue = upgrade.compareTable(natives, "useCustomAI", settings.startup["rampant-useCustomAI"].value)
    if natives.useCustomAI then
	game.forces.enemy.ai_controllable = false
    else
	game.forces.enemy.ai_controllable = true
    end
    if changed and newValue then
	rebuildRegionMap()
	return false
    end
    return true
end

local function onConfigChanged()
    if upgrade.attempt(natives, regionMap) and onModSettingsChange(nil) then
	rebuildRegionMap()
    end
end

local function onTick(event)
    local tick = event.tick
    if (tick == regionMap.processTick) then
	regionMap.processTick = regionMap.processTick + INTERVAL_PROCESS
	local surface = game.surfaces[1]

	processPendingChunks(natives, regionMap, surface, pendingChunks, tick)
	scanMap(regionMap, surface, natives)

	if (tick == regionMap.logicTick) then
	    regionMap.logicTick = regionMap.logicTick + INTERVAL_LOGIC

	    local players = game.players

	    planning(natives,
		     game.forces.enemy.evolution_factor,
		     tick,
		     surface)
	    
	    cleanSquads(natives)
	    --	    regroupSquads(natives)
	    
	    processPlayers(players, regionMap, surface, natives, tick)

	    -- if (natives.useCustomAI) then
	    -- 	processBases(regionMap, surface, natives, tick)
	    -- end
	    
	    squadBeginAttack(natives, players)
	    squadAttack(regionMap, surface, natives)
	end

	processMap(regionMap, surface, natives, tick)
    end
end

local function onBuild(event)
    local entity = event.created_entity
    addRemovePlayerEntity(regionMap, entity, natives, true, false)
    if natives.safeBuildings then
	if natives.safeEntities[entity.type] or natives.safeEntityName[entity.name] then
	    entity.destructible = false
	end
    end
end

local function onPickUp(event)
    addRemovePlayerEntity(regionMap, event.entity, natives, false, false)
end

local function onDeath(event)
    local entity = event.entity
    local surface = entity.surface
    if (surface.index == 1) then
        if (entity.force.name == "enemy") then
            if (entity.type == "unit") then
		local entityPosition = entity.position
		local deathChunk = getChunkByPosition(regionMap, entityPosition.x, entityPosition.y)
		
		if deathChunk then
		    -- drop death pheromone where unit died
		    deathScent(deathChunk)
		    
		    if event.force and (event.force.name == "player") and (deathChunk[MOVEMENT_PHEROMONE] < natives.retreatThreshold) then
			local tick = event.tick
			
			retreatUnits(deathChunk, 
				     convertUnitGroupToSquad(natives, 
							     entity.unit_group),
				     regionMap, 
				     surface, 
				     natives,
				     tick)
			if (math.random() < natives.rallyThreshold) and not surface.peaceful_mode then
			    local tempNeighbors = {false, false, false, false, false, false, false, false}
			    rallyUnits(deathChunk,
				       regionMap,
				       surface,
				       natives,
				       tick,
				       tempNeighbors)
			end
		    end
                end
                
            elseif (entity.type == "unit-spawner") or (entity.type == "turret") then
                unregisterEnemyBaseStructure(regionMap, entity)
            end
        elseif (entity.force.name == "player") then
	    local creditNatives = false
	    local entityPosition = entity.position
	    if (event.force ~= nil) and (event.force.name == "enemy") then
		creditNatives = true
		local victoryChunk = getChunkByPosition(regionMap, entityPosition.x, entityPosition.y)
		if victoryChunk then
		    victoryScent(victoryChunk, entity.type)
		end
	    end
	    if creditNatives and natives.safeBuildings and (natives.safeEntities[entity.type] or natives.safeEntityName[entity.name]) then
		makeImmortalEntity(surface, entity)
	    else
		addRemovePlayerEntity(regionMap, entity, natives, false, creditNatives)
	    end
        end
    end
end

local function onEnemyBaseBuild(event)
    local entity = event.entity
    registerEnemyBaseStructure(regionMap, entity, nil)
end

local function onSurfaceTileChange(event)
    local player = game.players[event.player_index]
    if (player.surface.index == 1) then
	aiBuilding.fillTunnel(regionMap, player.surface, natives, event.positions)
    end
end

local function onInit()
    global.regionMap = {}
    global.pendingChunks = {}
    global.natives = {}
    
    regionMap = global.regionMap
    natives = global.natives
    pendingChunks = global.pendingChunks
    
    onConfigChanged()
end

-- hooks

script.on_init(onInit)
script.on_load(onLoad)
script.on_event(defines.events.on_runtime_mod_setting_changed,
		onModSettingsChange)
script.on_configuration_changed(onConfigChanged)

script.on_event(defines.events.on_player_built_tile, onSurfaceTileChange)

script.on_event(defines.events.on_biter_base_built,
		onEnemyBaseBuild)
script.on_event({defines.events.on_preplayer_mined_item,
                 defines.events.on_robot_pre_mined}, 
    onPickUp)
script.on_event({defines.events.on_built_entity,
                 defines.events.on_robot_built_entity}, 
    onBuild)

script.on_event(defines.events.on_entity_died, onDeath)
script.on_event(defines.events.on_tick, onTick)
script.on_event(defines.events.on_chunk_generated, onChunkGenerated)

remote.add_interface("rampantTests",
		     {
			 pheromoneLevels = tests.pheromoneLevels,
			 activeSquads = tests.activeSquads,
			 entitiesOnPlayerChunk = tests.entitiesOnPlayerChunk,
			 findNearestPlayerEnemy = tests.findNearestPlayerEnemy,
			 aiStats = tests.aiStats,
			 fillableDirtTest = tests.fillableDirtTest,
			 tunnelTest = tests.tunnelTest,
			 createEnemy = tests.createEnemy,
			 attackOrigin = tests.attackOrigin,
			 cheatMode = tests.cheatMode,
			 gaussianRandomTest = tests.gaussianRandomTest,
			 reveal = tests.reveal,
			 showMovementGrid = tests.showMovementGrid,
			 baseStats = tests.baseStats,
			 baseTiles = tests.baseTiles,
			 mergeBases = tests.mergeBases,
			 clearBases = tests.clearBases,
			 getOffsetChunk = tests.getOffsetChunk,
			 registeredNest = tests.registeredNest
		     }
)

remote.add_interface("rampant", interop)
