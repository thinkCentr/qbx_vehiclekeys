local inventory = exports.ox_inventory
local config = require 'config.server'
local attempts, vehicleIds, vehicleKinds, vehicles, revisions = {}, {}, {}, {}, {}
local temporarySequence = 0
-- Include the boot time and a random component so stale keys cannot match new traffic after restart.
local bootNonce = ('%d-%08x'):format(os.time(), math.random(0, 0x7fffffff))
local schemaReady = false

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

-- Only tc_garages may register an owned vehicle, using its trusted Qbox ID.
exports('RegisterGarageVehicle', function(vehicle, id)
    if GetInvokingResource() ~= 'tc_garages' then return false end
    if type(id) ~= 'number' or id < 1 or id % 1 ~= 0
        or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then return false end
    if vehicleIds[vehicle] and vehicleIds[vehicle] ~= id then return false end
    if vehicles[id] and vehicles[id] ~= vehicle then return false end
    local revision = readRevision(id)
    if not revision or not inventory:BindVehicleIgnition(vehicle, id, 'owned', revision) then return false end
    vehicleIds[vehicle], vehicleKinds[vehicle], vehicles[id], revisions[vehicle] = id, 'owned', vehicle, revision
    setPublicIdentity(vehicle, id, 'owned', revision)
    return true
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
    return vehicleIds[vehicle], vehicleKinds[vehicle]
end

exports('GetGarageVehicleId', function(vehicle)
    return vehicleKinds[vehicle] == 'owned' and vehicleIds[vehicle] or nil
end)
exports('GetBoundVehicle', function(id)
    local vehicle = vehicles[id]
    return vehicle and DoesEntityExist(vehicle) and vehicle or nil
end)

-- Reserved for tc_mechanic. Never callable directly by clients.
exports('ResetIgnitionSecurity', function(id)
    if GetInvokingResource() ~= 'tc_mechanic' or type(id) ~= 'number'
        or id < 1 or id % 1 ~= 0 or not ensureSchema() then return false end
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
    if level >= 2 and inventory:GetItemCount(source, 'ecu_programmer') < 1 then return false end
    attempts[source] = {
        vehicle = vehicle, id = vehicleIds[vehicle], revision = revisions[vehicle],
        citizenid = player.PlayerData.citizenid, ready = now + 3000, expires = now + 30000,
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
    if attempt.level >= 2 and inventory:GetItemCount(source, 'ecu_programmer') < 1 then return false end

    -- The skill check is visual/client-side. The server also enforces a probability.
    local chance = ({ 0.85, 0.70, 0.50, 0.30 })[math.min(attempt.level, 4)] or 0.30
    if clientSuccess ~= true or math.random() > chance then
        inventory:DamageIgnitionPick(vehicle, clientSuccess and 20 or 30)
        return false
    end
    if not inventory:BindIgnitionPick(vehicle, attempt.revision) then return false end
    TriggerClientEvent('qbx_vehiclekeys:ignition:refresh', source, netId)
    return true
end)

AddEventHandler('playerDropped', function() attempts[source] = nil end)
AddEventHandler('QBCore:Server:OnPlayerUnload', function(playerId) attempts[playerId] = nil end)

AddEventHandler('entityRemoved', function(vehicle)
    local id = vehicleIds[vehicle]
    if not id then return end
    vehicleIds[vehicle], vehicleKinds[vehicle], revisions[vehicle], vehicles[id] = nil, nil, nil, nil
    for playerId, attempt in pairs(attempts) do
        if attempt.vehicle == vehicle then attempts[playerId] = nil end
    end
end)

-- Rebuild only from the inventory's trusted bindings after a keys-resource restart.
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() or GetResourceState('ox_inventory') ~= 'started' then return end
    for _, vehicle in ipairs(GetAllVehicles()) do
        local id = inventory:GetIgnitionVehicleId(vehicle)
        local kind = inventory:GetIgnitionVehicleKind(vehicle)
        if id and kind then
            vehicleIds[vehicle], vehicleKinds[vehicle], vehicles[id] = id, kind, vehicle
            revisions[vehicle] = inventory:GetIgnitionSecurityRevision(vehicle) or 1
            setPublicIdentity(vehicle, id, kind, revisions[vehicle])
        end
    end
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
