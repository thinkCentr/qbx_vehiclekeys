local inventory = exports.ox_inventory
local config = require 'config.server'
local attempts, vehicleIds, vehicleKinds, vehicles, revisions = {}, {}, {}, {}, {}
local temporarySequence = 0
-- Include the boot time and a random component so stale keys cannot match new traffic after restart.
local bootNonce = ('%d-%08x'):format(os.time(), math.random(0, 0x7fffffff))
local schemaReady = false
local restoring, retryRestoration = {}, {}

local function driverVehicle(source)
    local ped = GetPlayerPed(source)
    local vehicle = ped ~= 0 and GetVehiclePedIsIn(ped, false) or 0
    if vehicle ~= 0 and GetPedInVehicleSeat(vehicle, -1) == ped
        and GetEntityRoutingBucket(vehicle) == GetPlayerRoutingBucket(source) then return vehicle end
end

local jobModels = {
    police = { onDuty = true, models = { [joaat('police')] = true, [joaat('police2')] = true } },
    ambulance = { onDuty = true, models = { [joaat('ambulance')] = true } },
    mechanic = { models = { [joaat('towtruck')] = true } },
}

function HasJobVehicleKeys(source, vehicle)
    local player = exports.qbx_core:GetPlayer(source)
    local job = player and player.PlayerData.job
    local policy = job and jobModels[job.name]
    return policy and (not policy.onDuty or job.onduty) and policy.models[GetEntityModel(vehicle)] == true
end

local function hasIgnitionAccess(source, vehicle)
    if not vehicle or driverVehicle(source) ~= vehicle then return false end
    if not exports.qbx_core:GetPlayer(source) then return false end
    if HasJobVehicleKeys(source, vehicle) then return true end
    return GetResourceState('ox_inventory') == 'started' and inventory:HasIgnitionKey(vehicle) == true
end
exports('HasIgnitionAccess', hasIgnitionAccess)

lib.callback.register('qbx_vehiclekeys:ignition:canStart', function(source, netId)
    local vehicle = driverVehicle(source)
    return vehicle ~= nil and NetworkGetNetworkIdFromEntity(vehicle) == netId
        and hasIgnitionAccess(source, vehicle) == true
end)

function HasPhysicalKey(source, vehicle)
    if not vehicle or GetResourceState('ox_inventory') ~= 'started' then return false end
    local id = inventory:GetIgnitionVehicleId(vehicle)
    if not id then
        EnsureRestoredIgnition(vehicle)
        id = inventory:GetIgnitionVehicleId(vehicle)
    end
    if not id then return false end
    for _, item in pairs(inventory:Search(source, 'slots', 'vehicle_key') or {}) do
        if item.metadata and item.metadata.vehicleId == id then return true end
    end
    return false
end
exports('HasPhysicalKey', HasPhysicalKey)

local function ensureSchema()
    if schemaReady then return true end
    local ok, err = pcall(function()
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS shift_vehicle_security (
                vehicle_id INT NOT NULL PRIMARY KEY,
                revision INT NOT NULL DEFAULT 1
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]])
    end)
    if not ok then
        print(('[qbx_vehiclekeys:ignition] Security schema unavailable: %s'):format(tostring(err)))
        return false
    end
    schemaReady = true
    return true
end

local function readRevision(id)
    if not ensureSchema() then return end
    local ok, result = pcall(function()
        return MySQL.scalar.await('SELECT revision FROM shift_vehicle_security WHERE vehicle_id = ?', { id })
    end)
    if not ok then return end
    return tonumber(result) or 1
end

local function setPublicIdentity(vehicle, id, kind, revision)
    local state = Entity(vehicle).state
    state:set('shiftVehicleId', id, true)
    state:set('shiftVehicleType', kind, true)
    state:set('shiftSecurityRevision', revision, true)
end

local function validOwnedId(id)
    return type(id) == 'number' and id >= 1 and id % 1 == 0
end

local function bindOwned(vehicle, id)
    if not validOwnedId(id) or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2
        or GetResourceState('ox_inventory') ~= 'started' then return false end
    if vehicleIds[vehicle] then
        return vehicleKinds[vehicle] == 'owned' and vehicleIds[vehicle] == id
    end
    local existing = vehicles[id]
    if existing and existing ~= vehicle then
        if DoesEntityExist(existing) then return false end
        vehicles[id] = nil
    end
    local revision = readRevision(id)
    if not revision or not inventory:BindVehicleIgnition(vehicle, id, 'owned', revision) then return false end
    vehicleIds[vehicle], vehicleKinds[vehicle], vehicles[id], revisions[vehicle] = id, 'owned', vehicle, revision
    setPublicIdentity(vehicle, id, 'owned', revision)
    return true
end

-- Garage spawns remain explicitly authorized by tc_garages.
exports('RegisterGarageVehicle', function(vehicle, id)
    if GetInvokingResource() ~= 'tc_garages' then return false end
    return bindOwned(vehicle, id)
end)

local function normalizePlate(plate)
    return type(plate) == 'string' and plate:match('^%s*(.-)%s*$'):upper() or nil
end

-- Qbox persistence recreates vehicles without tc_garages. Require Qbox's
-- server-side vehicleid and persistence flag, plus an OUT DB record, model and plate.
-- Never establish owned identity from a matching plate alone.
local function validateRestoredVehicle(vehicle, id)
    local state = Entity(vehicle).state
    if state.vehicleid ~= id or state.persisted ~= true then return false end
    if GetResourceState('qbx_vehicles') ~= 'started' then return false end
    local ok, record = pcall(function()
        return exports.qbx_vehicles:GetPlayerVehicle(id)
    end)
    if not ok or type(record) ~= 'table' or tonumber(record.id) ~= id
        or tonumber(record.state) ~= 0 or type(record.props) ~= 'table' then return false end
    local plate = normalizePlate(record.props.plate)
    if not plate or plate == '' or plate ~= normalizePlate(GetVehicleNumberPlateText(vehicle)) then return false end
    local model = GetEntityModel(vehicle)
    local propsModel = tonumber(record.props.model)
    local namedModel = type(record.modelName) == 'string' and joaat(record.modelName) or nil
    return propsModel == model or namedModel == model
end

-- Server-only restoration; no client-provided identity, plate lookup, or owner claim.
function EnsureRestoredIgnition(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then return end
    if vehicleIds[vehicle] then
        return vehicleKinds[vehicle] == 'owned' and vehicleIds[vehicle] or nil
    end
    local state = Entity(vehicle).state
    local id = state.vehicleid
    if not validOwnedId(id) or state.persisted ~= true then return end
    if restoring[vehicle] then
        local timeout = GetGameTimer() + 2000
        repeat Wait(25) until not restoring[vehicle] or GetGameTimer() >= timeout
        return vehicleKinds[vehicle] == 'owned' and vehicleIds[vehicle] or nil
    end
    local retry = retryRestoration[vehicle]
    if retry and retry.id == id and retry.untilTime > GetGameTimer() then return end
    restoring[vehicle] = true
    local ok = validateRestoredVehicle(vehicle, id)
        and DoesEntityExist(vehicle) and Entity(vehicle).state.vehicleid == id
        and bindOwned(vehicle, id)
    restoring[vehicle] = nil
    if not ok then
        retryRestoration[vehicle] = { id = id, untilTime = GetGameTimer() + 5000 }
        return
    end
    retryRestoration[vehicle] = nil
    return id
end

exports('EnsureRestoredIgnition', function(vehicle)
    return EnsureRestoredIgnition(vehicle) ~= nil
end)

-- Server-internal entry point. Ambient registration never uses a client-supplied identity.
function RegisterTemporaryIgnition(vehicle)
    if not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then return end
    if vehicleIds[vehicle] then
        return vehicleKinds[vehicle] == 'temporary' and vehicleIds[vehicle] or nil
    end
    if Entity(vehicle).state.vehicleid or Entity(vehicle).state.persisted then return end
    temporarySequence += 1
    local id = ('temp:%s:%d'):format(bootNonce, temporarySequence)
    if not inventory:BindVehicleIgnition(vehicle, id, 'temporary', 1) then return end
    vehicleIds[vehicle], vehicleKinds[vehicle], vehicles[id], revisions[vehicle] = id, 'temporary', vehicle, 1
    setPublicIdentity(vehicle, id, 'temporary', 1)
    return id
end

function GetIgnitionIdentity(vehicle)
    if vehicle and not vehicleIds[vehicle] then EnsureRestoredIgnition(vehicle) end
    return vehicleIds[vehicle], vehicleKinds[vehicle]
end

exports('GetGarageVehicleId', function(vehicle)
    return vehicleKinds[vehicle] == 'owned' and vehicleIds[vehicle] or nil
end)
exports('GetBoundVehicle', function(id)
    local vehicle = vehicles[id]
    return vehicle and DoesEntityExist(vehicle) and vehicle or nil
end)

-- The trusted mechanic export and gated admin test command share this operation.
local function resetIgnitionSecurity(id)
    if type(id) ~= 'number' or id < 1 or id % 1 ~= 0 or not ensureSchema() then return false end
    local ok = pcall(function()
        MySQL.update.await([[
            INSERT INTO shift_vehicle_security (vehicle_id, revision) VALUES (?, 2)
            ON DUPLICATE KEY UPDATE revision = revision + 1
        ]], { id })
    end)
    if not ok then return false end
    local revision = readRevision(id)
    if not revision then return false end
    local vehicle = vehicles[id]
    if vehicle and DoesEntityExist(vehicle) and vehicleKinds[vehicle] == 'owned' then
        revisions[vehicle] = revision
        inventory:SetIgnitionSecurityRevision(vehicle, revision)
        setPublicIdentity(vehicle, id, 'owned', revision)
        TriggerClientEvent('qbx_vehiclekeys:ignition:refresh', -1, NetworkGetNetworkIdFromEntity(vehicle))
    end
    return revision
end

exports('ResetIgnitionSecurity', function(id)
    if GetInvokingResource() ~= 'tc_mechanic' then return false end
    return resetIgnitionSecurity(id)
end)

lib.addCommand('shiftresetignition', {
    help = 'Test: invalider les crochets liés au véhicule conduit',
    restricted = 'group.admin',
}, function(source)
    if GetConvarInt('shift:ignition_test_keys', 0) ~= 1 then return end
    local vehicle = driverVehicle(source)
    local id = vehicle and vehicleKinds[vehicle] == 'owned' and vehicleIds[vehicle]
    if not id then return end
    local revision = resetIgnitionSecurity(id)
    exports.qbx_core:Notify(source, revision and ('Antidémarrage réinitialisé (révision %d).'):format(revision)
        or 'Échec de la réinitialisation.', revision and 'success' or 'error')
end)

local function securityLevel(vehicle)
    local security = config.ignitionSecurity or {}
    local model = GetEntityModel(vehicle)
    local class = GetVehicleClass and GetVehicleClass(vehicle) or 0
    return (security.models and security.models[model])
        or (security.classes and security.classes[class])
        or security.default or 1
end

lib.callback.register('qbx_vehiclekeys:ignition:beginHotwire', function(source, netId)
    local vehicle = driverVehicle(source)
    if not vehicle or NetworkGetNetworkIdFromEntity(vehicle) ~= netId
        or not vehicleIds[vehicle] or GetVehicleConfig(vehicle).lockpickImmune
        or hasIgnitionAccess(source, vehicle) then return false end
    local now = GetGameTimer()
    local prior = attempts[source]
    if prior and (prior.expires or prior.cooldown or 0) > now then return false end
    local player = exports.qbx_core:GetPlayer(source)
    if not player then return false end
    local tool = inventory:GetIgnitionTool(vehicle)
    if not tool or (tool.name ~= 'lockpick' and tool.name ~= 'advancedlockpick')
        or tool.metadata.vehicleId ~= nil then return false end
    local level = securityLevel(vehicle)
    if level >= 3 and tool.name ~= 'advancedlockpick' then return false end
    if level >= 2 and not inventory:HasInsertedEcuProgrammer(vehicle) then return false end
    attempts[source] = {
        vehicle = vehicle, id = vehicleIds[vehicle], revision = revisions[vehicle],
        citizenid = player.PlayerData.citizenid, ready = now + 3000, expires = now + 120000,
        level = level
    }
    return { level = level }
end)

lib.callback.register('qbx_vehiclekeys:ignition:finishHotwire', function(source, netId, clientSuccess)
    local attempt = attempts[source]
    if not attempt or attempt.used then return false end
    attempt.used = true
    local now = GetGameTimer()
    attempts[source] = { cooldown = now + 5000 }
    local vehicle = driverVehicle(source)
    local player = exports.qbx_core:GetPlayer(source)
    if not player or attempt.citizenid ~= player.PlayerData.citizenid
        or now < attempt.ready or now > attempt.expires or vehicle ~= attempt.vehicle
        or not vehicle or NetworkGetNetworkIdFromEntity(vehicle) ~= netId
        or vehicleIds[vehicle] ~= attempt.id or revisions[vehicle] ~= attempt.revision then return false end

    local tool = inventory:GetIgnitionTool(vehicle)
    if not tool or (tool.name ~= 'lockpick' and tool.name ~= 'advancedlockpick')
        or tool.metadata.vehicleId ~= nil then return false end
    if attempt.level >= 2 and not inventory:HasInsertedEcuProgrammer(vehicle) then return false end

    -- Lation Pattern Lock (+ Signal Breach for level 2+) is client-side.
    -- A passed minigame succeeds deterministically once all server checks pass.
    -- No extra random failure roll after completing both stages.
    if clientSuccess ~= true then
        inventory:DamageIgnitionPick(vehicle, 30)
        return false
    end
    if not inventory:BindIgnitionPick(vehicle, attempt.revision) then return false end
    TriggerClientEvent('qbx_vehiclekeys:ignition:refresh', source, netId)
    return true
end)

-- Admin diagnostic also works OUTSIDE a locked persisted vehicle.
lib.addCommand('shiftcontactdebug', {
    help = 'Diagnostic du Contact et ECU : au volant ou à côté du véhicule',
    restricted = 'group.admin',
}, function(source)
    local ped = GetPlayerPed(source)
    if ped == 0 then return end
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then
        local coords = GetEntityCoords(ped)
        local distance = 6.0
        for _, candidate in ipairs(GetAllVehicles()) do
            if DoesEntityExist(candidate) and GetEntityRoutingBucket(candidate) == GetPlayerRoutingBucket(source) then
                local candidateDistance = #(GetEntityCoords(candidate) - coords)
                if candidateDistance < distance then
                    vehicle, distance = candidate, candidateDistance
                end
            end
        end
    end
    if vehicle == 0 then
        exports.qbx_core:Notify(source, 'Approche-toi du véhicule ou assieds-toi au volant.', 'error')
        return
    end
    local id, kind = GetIgnitionIdentity(vehicle)
    local invId = inventory:GetIgnitionVehicleId(vehicle)
    local invKind = inventory:GetIgnitionVehicleKind(vehicle)
    local state = Entity(vehicle).state
    local ecuInserted = inventory:HasInsertedEcuProgrammer(vehicle)
    local hasKey = HasPhysicalKey(source, vehicle)
    local message = ('Contact: %s (%s) | Inventaire: %s (%s) | Qbox: %s | Persisté: %s | Clé: %s | ECU: %s')
        :format(tostring(id), tostring(kind), tostring(invId), tostring(invKind),
            tostring(state.vehicleid), tostring(state.persisted),
            hasKey and 'oui' or 'non', ecuInserted and 'branché' or 'vide')
    print(('[qbx_vehiclekeys] Diagnostic joueur %d: %s'):format(source, message))
    exports.qbx_core:Notify(source, message, id and 'inform' or 'error', 12000)
end)

AddEventHandler('playerDropped', function() attempts[source] = nil end)
AddEventHandler('QBCore:Server:OnPlayerUnload', function(playerId) attempts[playerId] = nil end)

AddEventHandler('entityRemoved', function(vehicle)
    restoring[vehicle], retryRestoration[vehicle] = nil, nil
    local id = vehicleIds[vehicle]
    if not id then return end
    vehicleIds[vehicle], vehicleKinds[vehicle], revisions[vehicle] = nil, nil, nil
    if vehicles[id] == vehicle then vehicles[id] = nil end
    for playerId, attempt in pairs(attempts) do
        if attempt.vehicle == vehicle then attempts[playerId] = nil end
    end
end)

-- Qbox sets vehicleid after recreating a persisted vehicle.
-- The entity and persisted state may not yet be available in the same tick.
AddStateBagChangeHandler('vehicleid', '', function(bagName, _, value)
    if not validOwnedId(value) then return end
    CreateThread(function()
        for _ = 1, 30 do
            local vehicle = GetEntityFromStateBagName(bagName)
            if vehicle ~= 0 and DoesEntityExist(vehicle) and GetEntityType(vehicle) == 2 then
                local state = Entity(vehicle).state
                if state.vehicleid ~= value then return end
                if state.persisted == true then
                    EnsureRestoredIgnition(vehicle)
                    return
                end
            end
            Wait(100)
        end
    end)
end)

-- On a keys-resource restart, restore trusted inventory bindings and discover
-- persisted Qbox vehicles which never passed through tc_garages.
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() or GetResourceState('ox_inventory') ~= 'started' then return end
    CreateThread(function()
        Wait(250)
        for _, vehicle in ipairs(GetAllVehicles()) do
            local id = inventory:GetIgnitionVehicleId(vehicle)
            local kind = inventory:GetIgnitionVehicleKind(vehicle)
            if id and kind then
                vehicleIds[vehicle], vehicleKinds[vehicle], vehicles[id] = id, kind, vehicle
                revisions[vehicle] = inventory:GetIgnitionSecurityRevision(vehicle) or 1
                setPublicIdentity(vehicle, id, kind, revisions[vehicle])
            else
                EnsureRestoredIgnition(vehicle)
            end
        end
    end)
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= 'ox_inventory' then return end
    for vehicle, id in pairs(vehicleIds) do
        if DoesEntityExist(vehicle)
            and not inventory:BindVehicleIgnition(vehicle, id, vehicleKinds[vehicle], revisions[vehicle]) then
            print(('[qbx_vehiclekeys:ignition] Could not restore Contact for %s.'):format(tostring(id)))
        end
    end
end)

AddEventHandler('ox_inventory:ignitionUpdated', function(source, vehicle)
    if vehicle and driverVehicle(source) == vehicle then
        TriggerClientEvent('qbx_vehiclekeys:ignition:refresh', source, NetworkGetNetworkIdFromEntity(vehicle))
    end
end)

lib.addCommand('shiftcuttestkey', {
    help = 'Tailler une clé de test pour le véhicule conduit',
    restricted = 'group.admin',
}, function(source)
    if GetConvarInt('shift:ignition_test_keys', 0) ~= 1 then return end
    local vehicle = driverVehicle(source)
    local id = vehicle and vehicleKinds[vehicle] == 'owned' and vehicleIds[vehicle]
    if not id then return end
    local plate = string.strtrim(GetVehicleNumberPlateText(vehicle))
    local ok = inventory:AddItem(source, 'vehicle_key', 1, {
        vehicleId = id, plate = plate, description = ('Plaque : %s'):format(plate),
    })
    exports.qbx_core:Notify(source, ok and 'Clé de test taillée.' or 'Impossible de remettre la clé.')
end)
