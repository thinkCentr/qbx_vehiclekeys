# Shift Phase 4 — first development checkpoint (not production-ready)

## Branches

- `thinkCentr/qbx_vehiclekeys`: `feature/vehicle-ignition-phase4`
- `thinkCentr/ox_inventory`: `feature/vehicle-ignition-phase4`
- `tc_garages`: **keep the tested ShiftLocal version**. GitHub's `feature/garage-ignition` branch still lacks the locally tested parking/exit fixes.

Back up ShiftLocal resources and its database. Do not deploy this checkpoint to production.

## What is implemented

1. Garage vehicles retain their Qbox integer identity, database Contact, and physical key checks. Statebags `shiftVehicleId`, `shiftVehicleType=owned`, `shiftSecurityRevision` mirror server-owned identity.
2. NPC traffic is registered lazily when approached, carjacked or driven. Temporary identity is `temp:<boot nonce>:<sequence>`, with `shiftVehicleType=temporary`. Temporary Contact inventories use memory only and are never saved to the database.
3. NPC driving when observed gets an ambient key in Contact. A normal NPC departure removes that original ambient key. A successful qbx carjack or taking a dead driver's key preserves it. A generic panic abandonment not handled by those events is **not yet reliably distinguished**.
4. Parked traffic has empty Contact. Insert an unbound `lockpick` or `advancedlockpick`, then use the normal engine key to attempt bypass. A successful pick becomes a vehicle-bound "Clé improvisée" and remains usable only for that vehicle/security revision.
5. Security levels are configurable in `qbx_vehiclekeys/config/server.lua`. Level 2+ needs `ecu_programmer` in player inventory; levels 3+ also need `advancedlockpick`. ECU inventory port is **not yet implemented**; this is the electronic-tool prerequisite only.
6. Player-owned vehicle security revisions persist in `shift_vehicle_security`, created automatically by qbx_vehiclekeys. The `ResetIgnitionSecurity(vehicleId)` server export is reserved for future `tc_mechanic`. It invalidates bypass picks, not legitimate vehicle keys.
7. `/shiftresetignition` is a temporary admin test command while driving an owned vehicle, gated by `set shift:ignition_test_keys 1`. Disable that convar after testing.

## Startup

Start `oxmysql`, `ox_lib`, `qbx_core`, `qbx_vehicles`, the **built** ox_inventory fork, qbx_vehiclekeys fork, then the locally tested tc_garages. Preserve local items/images and existing Shift-specific inventory changes when updating ox_inventory. The inventory web UI must be built from this branch, as in Phase 3.

## Supervised ShiftLocal tests

1. Regression: retrieve an owned vehicle, insert correct physical key, drive, park, retrieve, restart; ensure Contact and door/engine behavior remain unchanged.
2. Parked NPC: empty Contact, engine blocked. Insert unbound lockpick; attempt ignition using engine bind. Successful tool binds to this vehicle, removal kills engine, reinsertion allows restart without another minigame.
3. Another NPC vehicle: bound pick must be rejected by Contact.
4. NPC carjack: key already in Contact before NPC leaves; player can drive immediately. Removing key kills engine.
5. Observe an NPC driver who parks and leaves normally: Contact key should be removed.
6. Owned vehicle: lockpick can bypass. On a level 2+ vehicle the `ecu_programmer` item is required. Test wrong key rejection and the physical key still working afterward.
7. Owned security reset: enable test convar, drive the owned vehicle and use `/shiftresetignition`; bound bypass pick stops working, legitimate physical key still works, and reset persists across garage storage/server restart.
8. Restart only qbx_vehiclekeys and then ox_inventory while observing a temporary vehicle; report any Contact loss or desync. Temporary identities intentionally do not survive a full server restart.

## Limitations / next checkpoint

- The separate ECU/OBD inventory slot, mechanic diagnostics, ECU tuning and tc_mechanic authorization UI are **not** included yet.
- A real panic-abandonment signal (without qbx carjack) needs a trusted NPC-driver lifecycle source.
- Temporary-to-owned vehicle promotion is not implemented; registration must be server-authorized when a vehicle is legitimately acquired.
- Vehicle security profiles need tuning after real-world tests; GTA classes are only a starting point.
- Client-side skill checks are not trusted alone: the server enforces seating, inserted tool, time, equipment, identity, revision, cooldown and independent success chance.
- The code has been committed to development branches, but no ShiftLocal runtime or ox_inventory frontend build has been performed here.
