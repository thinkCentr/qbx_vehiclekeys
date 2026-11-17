-- Lazy registration: only vehicles observed near players receive a temporary Contact.
-- Ambient identities live in server memory; no Qbox or inventory database rows are created.
local inventory = exports.ox_inventory
local npcDrivers, issued, preserved = {}, {}, {}

local function isPlayerPed(ped)
    if ped == 0 then return false end
    for _, playerId in ipairs(GetPlayers()) do
        if GetPlayerPed(playerId) == ped then return true end
    end
    return false
end

local function npcDriver(vehicle)
    local ped = GetPedInVehicleSeat(vehicle, -1)
    if ped == 0 or isPlayerPed(ped) then return end
    return ped
end

function EnsureAmbientIgnition(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then return end
    local id, kind = GetIgnitionIdentity(vehicle)
    if kind == 'owned' then return end
    if not id then
        if Entity(vehicle).state.vehicleid or Entity(vehicle).state.persisted then return end
        id = RegisterTemporaryIgnition(vehicle)
        if not id then return end
    end
    local driver = npcDriver(vehicle)
    if driver and not issued[vehicle] then
        if inventory:InsertAmbientIgnitionKey(vehicle, id) then
            issued[vehicle] = true
            npcDrivers[vehicle] = driver
        end
    end
    return id
end

-- A successful carjacking (or taking keys from a dead NPC) leaves the key in Contact.
function PreserveAmbientIgnition(vehicle)
    if not EnsureAmbientIgnition(vehicle) then return false end
    preserved[vehicle] = true
    return true
end

local function nearbyVehicle(source, netId)
    if type(netId) ~= 'number' or netId % 1 ~= 0 or netId <= 0 then return end
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if IsPlayerNearVehicle(source, vehicle) then return vehicle end
end

RegisterNetEvent('qbx_vehiclekeys:ignition:observeVehicle', function(netId)
    local vehicle = nearbyVehicle(source, netId)
    if vehicle then EnsureAmbientIgnition(vehicle) end
end)

lib.callback.register('qbx_vehiclekeys:ignition:ensureAmbient', function(source, netId)
    local vehicle = nearbyVehicle(source, netId)
    return vehicle and EnsureAmbientIgnition(vehicle) ~= nil or false
end)

-- When an NPC parks and leaves normally, remove only the original ambient key.
-- Explicit carjack/dead-driver events preserve it. This is not a general NPC panic detector.
CreateThread(function()
    while true do
        Wait(1500)
        for vehicle, originalDriver in pairs(npcDrivers) do
            if not DoesEntityExist(vehicle) then
                npcDrivers[vehicle], issued[vehicle], preserved[vehicle] = nil, nil, nil
            else
                local driver = GetPedInVehicleSeat(vehicle, -1)
                if driver ~= originalDriver then
                    if not preserved[vehicle] then
                        inventory:RemoveAmbientIgnitionKey(vehicle)
                        issued[vehicle] = nil
                    end
                    npcDrivers[vehicle] = nil
                elseif GetEntityHealth(originalDriver) <= 0 then
                    preserved[vehicle] = true
                end
            end
        end
    end
end)

AddEventHandler('entityRemoved', function(vehicle)
    npcDrivers[vehicle], issued[vehicle], preserved[vehicle] = nil, nil, nil
end)
