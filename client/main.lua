local config = require 'config.client'

---client uses key fob to toggle the door locks
---@param vehicle number The entity number of the vehicle.
local function toggleLock(vehicle)
    if not vehicle then return end
    local vehicleConfig = GetVehicleConfig(vehicle)
    if vehicleConfig.noLock or vehicleConfig.shared then return end
    if GetIsVehicleAccessible(vehicle) then
        Entity(cache.ped).state:set('qbx_vehiclekeys:keyFob', true, true)

        lib.playAnim(cache.ped, 'anim@mp_player_intmenu@key_fob@', 'fob_click', 3.0, 3.0, -1, 49)

        --- if the statebag is out of sync, rely on it as the source of truth and sync the client to the statebag's value
        local stateBagValue = Entity(vehicle).state.doorslockstate
        if GetVehicleDoorLockStatus(vehicle) ~= stateBagValue then
            SetVehicleDoorsLocked(vehicle, stateBagValue)
        end

        local lockstate = (GetVehicleDoorLockStatus(vehicle) % 2) + 1

        TriggerServerEvent('qb-vehiclekeys:server:setVehLockState', NetworkGetNetworkIdFromEntity(vehicle), lockstate)
        exports.qbx_core:Notify(locale(lockstate == 2 and 'notify.vehicle_locked' or 'notify.vehicle_unlocked'))

        qbx.playAudio({ audioName = 'Remote_Control_Fob', audioRef = 'PI_Menu_Sounds', source = vehicle })
        SetVehicleLights(vehicle, 2)
        Wait(250)
        SetVehicleLights(vehicle, 1)
        Wait(200)
        SetVehicleLights(vehicle, 0)
        Wait(300)
        ClearPedTasks(cache.ped)

        Entity(cache.ped).state:set('qbx_vehiclekeys:keyFob', false, true)
    else
        exports.qbx_core:Notify(locale('notify.no_keys'), 'error')
    end
end

local function canStart(vehicle)
    local ok, authorized = pcall(lib.callback.await, 'qbx_vehiclekeys:ignition:canStart', false, VehToNet(vehicle))
    return ok and authorized == true
end

local monitoredVehicle
local refreshIgnition = true

RegisterNetEvent('qbx_vehiclekeys:ignition:refresh', function(netId)
    if source ~= 65535 or not cache.vehicle or VehToNet(cache.vehicle) ~= netId then return end
    refreshIgnition = true
end)

local function onEnteringDriverSeat()
    local vehicle = cache.vehicle
    if not vehicle or monitoredVehicle == vehicle then return end
    monitoredVehicle = vehicle
    EngineBind:disable(false)

    CreateThread(function()
        local authorized = false
        local nextCheck = 0
        local checking = false
        local config = GetVehicleConfig(vehicle)
        if config.findKeysChance ~= 0.0 then EnableKeySearch() end

        while cache.seat == -1 and cache.vehicle == vehicle do
            if not checking and (refreshIgnition or GetGameTimer() >= nextCheck) then
                refreshIgnition = false
                checking = true
                CreateThread(function()
                    authorized = canStart(vehicle)
                    if authorized then DisableKeySearch() end
                    nextCheck = GetGameTimer() + 2500
                    checking = false
                end)
            end

            if not authorized then
                SetVehicleEngineOn(vehicle, false, true, true)
                DisableControlAction(0, 71, true)
            end

            if IsControlJustPressed(0, 23) then EngineBind:disable(true) end
            Wait(0)
        end
        if monitoredVehicle == vehicle then
            DisableKeySearch()
            monitoredVehicle = nil
        end
    end)
end

lib.onCache('seat', function(newSeat)
    if newSeat ~= -1 then return end
    Wait(0) -- needed to update cache.seat
    onEnteringDriverSeat()
end)

lib.onCache('vehicle', function(vehicle)
    if not vehicle then return end
    SetVehicleKeepEngineOnWhenAbandoned(vehicle, config.keepEngineOnWhenAbandoned)
end)

-----------------------
------ Key Binds ------
-----------------------

local togglelocksBind
togglelocksBind = lib.addKeybind({
    name = 'togglelocks',
    description = locale('info.toggle_locks'),
    defaultKey = 'L',
    onPressed = function()
        togglelocksBind:disable(true)
        local vehicle = lib.getClosestVehicle(GetEntityCoords(cache.ped), config.vehicleMaximumLockingDistance, true)
        toggleLock(vehicle)
        Wait(1000)
        togglelocksBind:disable(false)
    end
})

local function toggleEngine(vehicle)
    local engineOn = GetIsVehicleEngineRunning(vehicle)

    local vehicleModel = GetEntityModel(vehicle)
    local vehicleClass = GetVehicleClass(vehicle)
    local anim = config.anims.toggleEngine.model[vehicleModel]
        or config.anims.toggleEngine.class[vehicleClass]
        or config.anims.toggleEngine.default
    if next(anim) then
        lib.playAnim(cache.ped, anim.dict, anim.clip, 8.0, 8.0,-1, 48, 0)
        Wait(0)
        CreateThread(function()
            while IsEntityPlayingAnim(cache.ped, anim.dict, anim.clip, 3) do
                if IsControlJustPressed(0, 23) then -- enter/exit vehicle input
                    ClearPedTasks(cache.ped)
                    return
                end
                Wait(0)
            end
        end)

        --- aethestic wait so that the engine toggles when the player appears to touch the button/key
        Wait(anim.delay or 0)
    end

    if cache.vehicle == vehicle and cache.seat == -1 and (engineOn or canStart(vehicle)) then
        SetVehicleEngineOn(vehicle, not engineOn, false, true)
    end
end

EngineBind = lib.addKeybind({
    name = 'toggleengine',
    description = locale('info.engine'),
    defaultKey = config.keySearchBind,
    onPressed = function()
        if cache.seat == -1 then
            EngineBind:disable(true)
            toggleEngine(cache.vehicle)
            Wait(1000)
            EngineBind:disable(false)
        end
    end
})

-----------------------
---- Client Events ----
-----------------------

local isTakingKeys = false
RegisterNetEvent('QBCore:Client:VehicleInfo', function(data)
    if not LocalPlayer.state.isLoggedIn or data.event ~= 'Entering' then return end
    local vehicleConfig = GetVehicleConfig(data.vehicle)
    if vehicleConfig.noLock or isTakingKeys then return end
    isTakingKeys = true
    local driver = GetPedInVehicleSeat(data.vehicle, -1)

    if driver ~= 0 and IsEntityDead(driver) and not (vehicleConfig.carjackingImmune or IsPedAPlayer(driver)) then
        if lib.progressCircle({
            duration = 2500,
            label = locale('progress.takekeys'),
            position = 'bottom',
            useWhileDead = false,
            canCancel = true,
            disable = {
                car = true,
            },
        }) then
            TriggerServerEvent('qbx_vehiclekeys:server:tookKeys', VehToNet(data.vehicle))
        end
    end
    isTakingKeys = false
end)

RegisterNetEvent('lockpicks:UseLockpick', function(isAdvanced)
    local vehicle = cache.vehicle
    if vehicle then
        if GetKeySearchEnabled() then
            DisableKeySearch()
            Hotwire(vehicle, isAdvanced)
            EnableKeySearch()
        else
            Hotwire(vehicle, isAdvanced)
        end
    else
        LockpickDoor(isAdvanced)
    end
end)

RegisterNetEvent('qbx_vehiclekeys:client:OnLostKeys', function()
    if cache.seat == -1 then
        onEnteringDriverSeat()
    end
end)

qbx.entityStateHandler('doorslockstate', function(entity, _, value)
    if entity == 0 then return end
    SetVehicleDoorsLocked(entity, value)
end)

AddEventHandler('onResourceStart', function(resourceName)
    if (GetCurrentResourceName() ~= resourceName) then return end
    if cache.seat == -1 then
        onEnteringDriverSeat()
    end
end)

local lastTrafficLockRequest
local function onVehicleAttemptToEnter(vehicle)
    if Entity(vehicle).state.doorslockstate then return end
    local netId = VehToNet(vehicle)
    if lastTrafficLockRequest == netId then return end
    lastTrafficLockRequest = netId
    TriggerServerEvent('qbx_vehiclekeys:server:initTrafficLock', netId)
    SetTimeout(1000, function()
        if lastTrafficLockRequest == netId then lastTrafficLockRequest = nil end
    end)
end

local isLoggedIn = false

local function playerEnterVehLoop()
    CreateThread(function()
        while isLoggedIn do
            local vehicle = GetVehiclePedIsTryingToEnter(cache.ped)
            if vehicle ~= 0 then
                onVehicleAttemptToEnter(vehicle)
            end
            Wait(100)
        end
    end)
end

CreateThread(function()
    if LocalPlayer.state.isLoggedIn then
        playerEnterVehLoop()
    end
end)

AddStateBagChangeHandler('isLoggedIn', ('player:%s'):format(cache.serverId), function(_, _, value)
    isLoggedIn = value
    if not value then return end
    playerEnterVehLoop()
end)
