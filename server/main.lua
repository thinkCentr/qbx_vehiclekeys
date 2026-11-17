local config = require 'config.server'

---@param veh number
---@param state string
local function setLockState(veh, state)
	if type(state) ~= 'string' or not DoesEntityExist(veh) then return end
    local vehicleConfig = GetVehicleConfig(veh)
    if vehicleConfig.noLock or vehicleConfig.shared then return end
    Entity(veh).state:set('doorslockstate', state == 'lock' and 2 or 1, true)
end
exports('SetLockState', setLockState)

local function nearbyVehicle(source, netId)
    if type(netId) ~= 'number' or netId % 1 ~= 0 or netId <= 0 then return end
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if IsPlayerNearVehicle(source, vehicle) then return vehicle end
end

local searched, carjacked, lockpicked = {}, {}, {}

local function isTrafficVehicle(vehicle)
    return not exports.ox_inventory:GetIgnitionVehicleId(vehicle)
        and not Entity(vehicle).state.vehicleid and not Entity(vehicle).state.persisted
end

lib.callback.register('qbx_vehiclekeys:server:findKeys', function(source, netId)
    local vehicle = nearbyVehicle(source, netId)
    if not vehicle or not isTrafficVehicle(vehicle) or searched[vehicle]
        or GetPedInVehicleSeat(vehicle, -1) ~= GetPlayerPed(source) then return false end
    searched[vehicle] = true
    if math.random() > GetVehicleConfig(vehicle).findKeysChance then return false end
    GiveKeys(source, vehicle)
    return GrantTemporaryIgnition(source, vehicle)
end)

local function isPlayerPed(ped)
    for _, playerId in ipairs(GetPlayers()) do
        if GetPlayerPed(playerId) == ped then return true end
    end
    return false
end

local function trafficDriver(vehicle)
    if not isTrafficVehicle(vehicle) or GetVehicleConfig(vehicle).carjackingImmune then return end
    local driver = GetPedInVehicleSeat(vehicle, -1)
    if driver ~= 0 and not isPlayerPed(driver) then return driver end
end

lib.callback.register('qbx_vehiclekeys:server:carjack', function(source, netId, weaponTypeGroup)
    local vehicle = nearbyVehicle(source, netId)
    local driver = vehicle and trafficDriver(vehicle)
    local weapon = GetSelectedPedWeapon(GetPlayerPed(source))
    if not driver or GetEntityHealth(driver) <= 0 or carjacked[vehicle]
        or not weapon or weapon == 0 or weapon == joaat('WEAPON_UNARMED') then return false end
    carjacked[vehicle] = true
    -- The client's weapon group is presentation data. Use the server's default chance.
    if math.random() > (config.carjackChance.default or 0.5) then return false end
    GiveKeys(source, vehicle)
    setLockState(vehicle, 'unlock')
    return GrantTemporaryIgnition(source, vehicle)
end)

RegisterNetEvent('qbx_vehiclekeys:server:tookKeys', function(netId)
    local src = source
    local vehicle = nearbyVehicle(src, netId)
    local driver = vehicle and trafficDriver(vehicle)
    if not driver or GetEntityHealth(driver) > 0 or carjacked[vehicle] then return end
    carjacked[vehicle] = true
    GiveKeys(src, vehicle)
    setLockState(vehicle, 'unlock')
    GrantTemporaryIgnition(src, vehicle)
end)

lib.callback.register('qbx_vehiclekeys:server:hasPhysicalKey', function(source, netId)
    local vehicle = nearbyVehicle(source, netId)
    return vehicle ~= nil and HasKeys(source, vehicle)
end)

lib.callback.register('qbx_vehiclekeys:server:lockpickDoor', function(source, netId)
    local vehicle = nearbyVehicle(source, netId)
    if not vehicle or GetPedInVehicleSeat(vehicle, -1) ~= 0 or GetVehicleConfig(vehicle).lockpickImmune then
        return false
    end
    local now = GetGameTimer()
    if lockpicked[vehicle] and lockpicked[vehicle] > now then return false end
    lockpicked[vehicle] = now + 5000
    local inv = exports.ox_inventory
    local tool = inv:GetItemCount(source, 'advancedlockpick') > 0 and 'advancedlockpick' or 'lockpick'
    if not inv:RemoveItem(source, tool, 1) or math.random() > 0.75 then return false end
    setLockState(vehicle, 'unlock')
    return true
end)

RegisterNetEvent('qbx_vehiclekeys:server:initTrafficLock', function(netId)
    local vehicle = nearbyVehicle(source, netId)
    if not vehicle or not isTrafficVehicle(vehicle) or Entity(vehicle).state.doorslockstate then return end
    local driver = GetPedInVehicleSeat(vehicle, -1)
    if driver ~= 0 and isPlayerPed(driver) then return end
    local config = GetVehicleConfig(vehicle)
    local chance = driver ~= 0 and config.spawnLockedIfDriven or config.spawnLockedIfParked
    local locked = chance == true or (type(chance) == 'number' and math.random() < chance)
    setLockState(vehicle, locked and 'lock' or 'unlock')
end)

RegisterNetEvent('qb-vehiclekeys:server:setVehLockState', function(netId, state)
    local src = source
    if state ~= 1 and state ~= 2 then return end
    local vehicle = nearbyVehicle(src, netId)
    if not vehicle or not (HasKeys(src, vehicle) or HasJobVehicleKeys(src, vehicle)) then return end
    setLockState(vehicle, state == 2 and 'lock' or 'unlock')
end)

AddEventHandler('entityRemoved', function(vehicle)
    searched[vehicle], carjacked[vehicle], lockpicked[vehicle] = nil, nil, nil
end)
