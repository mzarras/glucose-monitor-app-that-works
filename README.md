# Sensor (working name)

Open-source iOS app that pairs directly with a Dexcom G7 10-day sensor as its primary device,
stores and displays readings, runs its own alerts, hands readings to Trio, and uploads to
Nightscout for followers. Build-from-source only. GPL-3.0.

**Status:** under construction — see `PROGRESS.md`. Not for treatment decisions.

## Build

```sh
brew install xcodegen
cp Config/Signing.example.xcconfig Config/Signing.xcconfig   # fill in your Team ID
xcodegen generate
open Sensor.xcodeproj
```

Validation gates: `scripts/check.sh` (see `HANDOFF.md` §10).
