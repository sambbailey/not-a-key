# Hardware checkpoint — 2026-10-19

Car: 2026 Model Y LR AWD. Phone: iPhone 17 Pro Max. Official Tesla app installed with phone key active.

| Check | Result |
|---|---|
| Pairing (key card tap + confirm on car) | ✅ works |
| Refresh / Toggle Boot from debug screen | ✅ works |
| Action Button "Toggle Boot", phone locked | ✅ works |
| Out of range → "Car not in range" | ✅ works |
| Asleep car (15+ min) | ✅ works |
| Latency per toggle | not recorded |
| Haptic on intent result | not recorded |

## Fix found at the car
- **"Car not in range" while sitting in the car.** Root cause: scan was filtered on the vehicle service UUID (0211); the car doesn't advertise it, so iOS never reported the car. Fix (dba471a): unfiltered scan matched on local name (as the Go reference and other Swift libs do), plus remembered peripheral identifier → `retrievePeripherals` connect (needed for locked/background Action Button use), falling back to a scan after 3 s.
