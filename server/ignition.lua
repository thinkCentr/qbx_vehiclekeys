local inventory = exports.ox_inventory
local temporaryAccess, attempts = {}, {}

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
    local player = exports.qbx_core:GetPlayer(source)
    if not player then return false end

    if HasJobVehicleKeys(source, vehicle) then
        return true
    end

    local grant = temporaryAccess[vehicle]
    return (grant and grant.citizenid == player.PlayerData.citizenid and grant.expires > GetGameTimer())
        or (GetResourceState('ox_inventory') == 'started' and inventory:HasIgnitionKey(vehicle))
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

lib.callback.register('qbx_vehiclekeys:ignition:beginHotwire', function(source, netId)
    local vehicle = driverVehicle(source)
    if not vehicle or NetworkGetNetworkIdFromEntity(vehicle) ~= netId
        or GetVehicleConfig(vehicle).lockpickImmune then return false end
    local now = GetGameTimer()
    if attempts[source] and attempts[source].expires > now then return false end
    if hasIgnitionAccess(source, vehicle) then return false end
    if driverVehicle(source) ~= vehicle or (attempts[source] and attempts[source].expires > now) then return false end
    local player = exports.qbx_core:GetPlayer(source)
    if not player then return false end

    local tool = inventory:GetItemCount(source, 'advancedlockpick') > 0 and 'advancedlockpick' or 'lockpick'
    if not inventory:RemoveItem(source, tool, 1) then return false end
    attempts[source] = { vehicle = vehicle, citizenid = player.PlayerData.citizenid, ready = now + 3000, expires = now + 30000 }
    return true
end)

function GrantTemporaryIgnition(source, vehicle)
    local player = exports.qbx_core:GetPlayer(source)
    if not player then return false end
    temporaryAccess[vehicle] = { citizenid = player.PlayerData.citizenid, expires = GetGameTimer() + 300000 }
    TriggerClientEvent('qbx_vehiclekeys:ignition:refresh', source, NetworkGetNetworkIdFromEntity(vehicle))
    return true
end

lib.callback.register('qbx_vehiclekeys:ignition:finishHotwire', function(source, netId)
    local attempt = attempts[source]
    if not attempt or attempt.used then return false end
    attempt.used = true
    local now = GetGameTimer()
    local vehicle = driverVehicle(source)
    local player = exports.qbx_core:GetPlayer(source)
    if not player or attempt.citizenid ~= player.PlayerData.citizenid or now < attempt.ready or now > attempt.expires or not vehicle or vehicle ~= attempt.vehicle
        or NetworkGetNetworkIdFromEntity(vehicle) ~= netId then return false end

    -- The visual skill check is client side. The server decides whether the paid attempt works.
    if math.random() > 0.65 then return false end
    return GrantTemporaryIgnition(source, vehicle)
end)

AddEventHandler('playerDropped', function() attempts[source] = nil end)
AddEventHandler('QBCore:Server:OnPlayerUnload', function(playerId) attempts[playerId] = nil end)
AddEventHandler('entityRemoved', function(vehicle)
    temporaryAccess[vehicle] = nil
    for playerId, attempt in pairs(attempts) do
        if attempt.vehicle == vehicle then attempts[playerId] = nil end
    end
end)

-- Only the garage creates these registrations, using the server-side Qbox record.
-- Keep them independently of both the garage and inventory resource.
local vehicleIds, vehicles = {}, {}

exports('RegisterGarageVehicle', function(vehicle, id)
    if GetInvokingResource() ~= 'tc_garages' then return false end
    if type(id) ~= 'number' or not DoesEntityExist(vehicle) then return false end
    if vehicleIds[vehicle] and vehicleIds[vehicle] ~= id then return false end
    if vehicles[id] and vehicles[id] ~= vehicle then return false end
    if not inventory:BindVehicleIgnition(vehicle, id) then return false end
    vehicleIds[vehicle], vehicles[id] = id, vehicle
    return true
end)

exports('GetGarageVehicleId', function(vehicle) return vehicleIds[vehicle] end)
exports('GetBoundVehicle', function(id)
    local vehicle = vehicles[id]
    return vehicle and DoesEntityExist(vehicle) and vehicle or nil
end)

AddEventHandler('entityRemoved', function(vehicle)
    local id = vehicleIds[vehicle]
    if not id then return end
    vehicleIds[vehicle], vehicles[id] = nil, nil
end)

-- When only vehicle keys restarts, recover from inventory's server-owned bindings.
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() or GetResourceState('ox_inventory') ~= 'started' then return end
    for _, vehicle in ipairs(GetAllVehicles()) do
        local id = inventory:GetIgnitionVehicleId(vehicle)
        if id then vehicleIds[vehicle], vehicles[id] = id, vehicle end
    end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= 'ox_inventory' then return end
    for vehicle, id in pairs(vehicleIds) do
        if DoesEntityExist(vehicle) and not inventory:BindVehicleIgnition(vehicle, id) then
            print(('[qbx_vehiclekeys:ignition] Failed to restore vehicle registration %d.'):format(id))
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
    if GetConvarInt('shift:ignition_test_keys', 0) ~= 1 or GetConvar('txAdminServerName', '') ~= 'ShiftLocal' then return end
    local vehicle = driverVehicle(source)
    local id = vehicle and vehicleIds[vehicle]
    if not id then return end
    local plate = string.strtrim(GetVehicleNumberPlateText(vehicle))
    local ok = inventory:AddItem(source, 'vehicle_key', 1, {
        vehicleId = id, plate = plate, description = ('Plaque : %s'):format(plate),
    })
    exports.qbx_core:Notify(source, ok and 'Clé de test taillée.' or 'Impossible de remettre la clé.')
end)
