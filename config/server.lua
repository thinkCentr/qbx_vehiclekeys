return {
    runClearCronMinutes = 5,
    -- Gameplay profiles, not real-world model years. Model overrides win over class defaults.
    -- Level 1: lockpick; level 2: lockpick + ECU programmer;
    -- level 3/4: advanced lockpick + ECU programmer and harder checks.
    ignitionSecurity = {
        default = 1,
        classes = {
            [6] = 2,  -- sports
            [7] = 3,  -- super
            [18] = 4, -- emergency
            [19] = 4, -- military
            [22] = 3, -- open-wheel
        },
        models = {
            [joaat('police')] = 4,
            [joaat('police2')] = 4,
            [joaat('adder')] = 3,
        },
    },

    distanceToHandKeys = 3,
    distanceToVehicle = 7.5,             -- Max distance (m) between a player and a vehicle for server-side key-grant events to be honored. Prevents granting keys to vehicles the player isn't actually next to.
    ---@type table<WeaponTypeGroup, number>
    carjackChance = {                    -- Probability of successful carjacking based on weapon used
        [WeaponTypeGroup.MELEE] = 0.0,
        [WeaponTypeGroup.HANDGUN] = 0.5,
        [WeaponTypeGroup.SMG] = 0.75,
        [WeaponTypeGroup.SHOTGUN] = 0.90,
        [WeaponTypeGroup.RIFLE] = 0.90,
        [WeaponTypeGroup.LMG] = 0.99,
        [WeaponTypeGroup.SNIPER] = 0.99,
        [WeaponTypeGroup.HEAVY] = 0.99,
        [WeaponTypeGroup.THROWABLE] = 0.0,
        [WeaponTypeGroup.MISC] = 0.0,
    },
}
