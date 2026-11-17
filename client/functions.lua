local config = require 'config.client'

--- Checks if the vehicle is shared for the player's current job and if the player meets the requirements to use shared keys.
---@param vehicle number The entity number of the vehicle.
---@param skipNotification? boolean
---@return boolean? `true` if the vehicle is shared for the player's current job, `nil` if the player has no job or is off duty.
function AreKeysJobShared(vehicle, skipNotification)
    if not config.sharedKeys then return end
    local job = QBX.PlayerData.job
    if not job then return end
    local jobProfile = config.sharedKeys[job.name]
    if not jobProfile then return end

    if jobProfile.requireOnDuty and not job.onduty then
        if not skipNotification then
            exports.qbx_core:Notify(locale('notify.require_on_duty'), 'error')
        end
        return
    end

    local isSharedVehicleClass = jobProfile.classes
        and jobProfile.classes[GetVehicleClass(vehicle)]

    return isSharedVehicleClass
        or (jobProfile.vehicles
       and jobProfile.vehicles[GetEntityModel(vehicle)])
end

---Checks if player has vehicle keys
---@param vehicle number
---@return boolean `true` if player has vehicle keys, `false` otherwise.
function HasKeys(vehicle)
    vehicle = vehicle or cache.vehicle
    if not vehicle then return false end
    local ok, allowed = pcall(lib.callback.await, 'qbx_vehiclekeys:server:hasPhysicalKey', false, VehToNet(vehicle))
    return ok and allowed == true
end

exports('HasKeys', HasKeys)

---Checks if player has vehicle keys of or access to the vehicle is provided as part of his job.
---@param vehicle number The entity number of the vehicle.
---@return boolean? `true` if player has access to the vehicle, `nil` otherwise.
function GetIsVehicleAccessible(vehicle)
    return HasKeys(vehicle) or AreKeysJobShared(vehicle)
end

local alertSend = false --Variable strictly related to sendPoliceAlertAttempt, not used elsewhere
function SendPoliceAlertAttempt(crime, vehicle)
    if alertSend then return end
    alertSend = true

    local hoursOffset = (24 + GetClockHours() - config.policeAlertNightStartHour) % 24; --Hour from the start of the night hours
    local chance = hoursOffset > config.policeAlertNightDuration
        and config.policeAlertChance
        or config.policeNightAlertChance

    if math.random() <= chance then
        config.alertPolice(crime, vehicle)
    end

    SetTimeout(config.alertCooldown, function()
        alertSend = false
    end)
end

---Gets bone coords
---@param entity number The entity index.
---@param boneName string The entity bone name.
---@return vector3 `Bone coords` if exists, `entity coords` otherwise.
local function getBoneCoords(entity, boneName)
    local boneIndex = GetEntityBoneIndexByName(entity, boneName)

    return boneIndex ~= -1
        and GetWorldPositionOfEntityBone(entity, boneIndex)
        or GetEntityCoords(entity)
end

---Checks if any of the bones are close enough to the coords
---@param coords vector3
---@param entity number
---@param bones table
---@param maxDistance number
---@return boolean? `true` if bone exists, `nil` otherwise.
local function getIsCloseToAnyBone(coords, entity, bones, maxDistance)
    for i = 1, #bones do
        local boneCoords = getBoneCoords(entity, bones[i])
        if #(coords - boneCoords) < maxDistance then
            return true
        end
    end
end

local doorBones = {'door_dside_f', 'door_dside_r', 'door_pside_f', 'door_pside_r'}

---Checking whether the character is close enough to the vehicle driver door.
---@param vehicle number The entity number of the vehicle.
---@param maxDistance number The max distance to check.
---@return boolean? `true` if the player ped is next to an open vehicle, `nil` otherwise.
local function getIsVehicleInRange(vehicle, maxDistance)
    local vehicles = GetGamePool('CVehicle')
    local pedCoords = GetEntityCoords(cache.ped)
    for i = 1, #vehicles do
        local v = vehicles[i]
        if not cache.vehicle or v ~= cache.vehicle then
            if vehicle == v and getIsCloseToAnyBone(pedCoords, vehicle, doorBones, maxDistance) then
                return true
            end
        end
    end
end

-- Lation minigames return a boolean. Fail closed if the UI is missing or errors.
local function runPatternLock(title, difficulty)
    if GetResourceState('lation_ui') ~= 'started' then return false end
    local ok, result = pcall(function()
        return exports.lation_ui:patternLock(title, difficulty)
    end)
    if not ok then
        print(('[qbx_vehiclekeys] Lation patternLock error: %s'):format(tostring(result)))
    end
    return ok and result == true
end

local function runSignalBreach(title, profile)
    if GetResourceState('lation_ui') ~= 'started' or not profile then return false end
    local ok, result = pcall(function()
        return exports.lation_ui:signalBreach(
            title, profile.difficulty, profile.inputs, profile.options
        )
    end)
    if not ok then
        print(('[qbx_vehiclekeys] Lation signalBreach error: %s'):format(tostring(result)))
    end
    return ok and result == true
end

local function lockpickCallback(vehicle, isSuccess)
    if isSuccess then
        TriggerServerEvent('hud:server:GainStress', math.random(1, 4))
        exports.qbx_core:Notify(locale('notify.vehicle_lockedpick'), 'success')
    else
        SendPoliceAlertAttempt('carjack', vehicle)
        SetVehicleAlarm(vehicle, false)
        SetVehicleAlarmTimeLeft(vehicle, config.vehicleAlarmDuration)
        TriggerServerEvent('hud:server:GainStress', math.random(1, 4))
        exports.qbx_core:Notify(locale('notify.failed_lockedpick'), 'error')
    end
end

local islockpickingProcessLocked = false

-- Door entry: Lation Pattern Lock. The server validates the selected tool and
-- reserves a single attempt before the UI starts, then revalidates on completion.
function LockpickDoor(_isAdvancedLockedpick, maxDistance, _customChallenge, selectedSlot)
    maxDistance = maxDistance or 2
    local pedCoords = GetEntityCoords(cache.ped)
    local vehicle = lib.getClosestVehicle(pedCoords, maxDistance * 2, false)
    if not vehicle then return end
    if GetVehicleDoorLockStatus(vehicle) < 2 then
        exports.qbx_core:Notify(locale('notify.vehicle_is_unlocked'), 'error')
        return
    end
    if not IsVehicleSeatFree(vehicle, -1)
        or not getIsCloseToAnyBone(pedCoords, vehicle, doorBones, maxDistance)
        or GetVehicleConfig(vehicle).lockpickImmune then return end

    if islockpickingProcessLocked then return end
    if GetResourceState('lation_ui') ~= 'started' then
        exports.qbx_core:Notify('Lation UI est indisponible.', 'error')
        return
    end

    islockpickingProcessLocked = true
    CreateThread(function()
        local netId = VehToNet(vehicle)
        local ok, attempt = pcall(lib.callback.await, 'qbx_vehiclekeys:server:beginDoorLockpick', false, netId, selectedSlot)
        if not ok or type(attempt) ~= 'table' then
            exports.qbx_core:Notify('Crochetage impossible : crochet manquant ou serrure inaccessible.', 'error')
            islockpickingProcessLocked = false
            return
        end

        local profile = config.minigames.door[attempt.advanced and 'advancedLockpick' or 'lockpick']
        local difficulty = profile.model[GetEntityModel(vehicle)]
            or profile.class[GetVehicleClass(vehicle)] or profile.default
        if not difficulty or #difficulty == 0 then
            lib.callback.await('qbx_vehiclekeys:server:finishDoorLockpick', false, netId, false)
            islockpickingProcessLocked = false
            return
        end

        local anim = config.anims.lockpick.model[GetEntityModel(vehicle)]
            or config.anims.lockpick.class[GetVehicleClass(vehicle)]
            or config.anims.lockpick.default
        lib.playAnim(cache.ped, anim.dict, anim.clip, 3.0, 3.0, -1, 16, 0, false, false, false)

        local passed = runPatternLock('Crochetage de serrure', difficulty)
        local inRange = getIsVehicleInRange(vehicle, maxDistance) == true
        local finished, unlocked = pcall(lib.callback.await,
            'qbx_vehiclekeys:server:finishDoorLockpick', false, netId, passed and inRange)
        if inRange then lockpickCallback(vehicle, finished and unlocked == true) end

        Wait(config.lockpickCooldown)
        islockpickingProcessLocked = false
    end)
end

local isHotwiringProcessLocked = false

-- Contact: Pattern Lock for the mechanical stage, then Signal Breach for levels 2+.
-- Never accept a customChallenge override as proof of a completed minigame.
function Hotwire(vehicle, _isAdvanced, _customChallenge)
    if cache.seat ~= -1 or isHotwiringProcessLocked then return end
    if GetResourceState('lation_ui') ~= 'started' then
        exports.qbx_core:Notify('Lation UI est indisponible.', 'error')
        return
    end
    isHotwiringProcessLocked = true
    CreateThread(function()
        local netId = VehToNet(vehicle)
        local ok, attempt = pcall(lib.callback.await, 'qbx_vehiclekeys:ignition:beginHotwire', false, netId)
        if not ok or type(attempt) ~= 'table' then
            exports.qbx_core:Notify('Contact invalide ou équipement ECU requis.', 'error')
            isHotwiringProcessLocked = false
            return
        end

        local level = math.min(4, math.max(1, tonumber(attempt.level) or 1))
        local minigames = config.minigames.ignition
        local started = GetGameTimer()
        local anim = config.anims.hotwire.model[GetEntityModel(vehicle)]
            or config.anims.hotwire.class[GetVehicleClass(vehicle)]
            or config.anims.hotwire.default
        lib.playAnim(cache.ped, anim.dict, anim.clip, 3.0, 3.0, -1, 16, 0, false, false, false)

        local passed = runPatternLock('Crochetage du contact', minigames.pattern[level])
        if passed and level >= 2 and cache.vehicle == vehicle and cache.seat == -1 then
            passed = runSignalBreach('Contournement électronique', minigames.signal[level])
        end

        -- A successful UI animation is not authorization: the server validates
        -- identity, Contact item, security revision, equipment, and elapsed time.
        Wait(math.max(0, 3100 - (GetGameTimer() - started)))
        if cache.vehicle ~= vehicle or cache.seat ~= -1 then passed = false end
        local finished, success = pcall(lib.callback.await,
            'qbx_vehiclekeys:ignition:finishHotwire', false, netId, passed == true)
        if finished and success == true then
            exports.qbx_core:Notify(
                'Contact contourné. Crochet lié au véhicule. Appuie à nouveau pour démarrer.',
                'success'
            )
        else
            SendPoliceAlertAttempt('carjack', vehicle)
            exports.qbx_core:Notify('Le contournement du Contact a échoué.', 'error')
        end

        Wait(config.hotwireCooldown)
        isHotwiringProcessLocked = false
    end)
end
