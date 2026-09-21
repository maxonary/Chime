# Chime screenshots

These are direct captures of Chime running in the Apple Watch Series 11 (46 mm),
watchOS 26.5 simulator. They are app screenshots, not generated mockups.

- `bubble-idle.png`: microphone off, small bubble, no reminder or visible controls.
- `memory.png`: left page with the automatic-memory empty state and forget action.
- `preferences.png`: right page with voice selection and web search.

Captured with `xcrun simctl io DEVICE_ID screenshot PATH` after navigating the app.
The memory screen uses an empty simulator store and contains no personal conversation data.
Refresh all three captures when their appearance or navigation changes.

The bubble surface itself uses generated artwork; its full prompt and provenance are in
[watch/ARTWORK.md](../../watch/ARTWORK.md).

`iphone-bubble.png`, `iphone-memory.png`, and `iphone-setup.png` are direct
iPhone 17 Pro / iOS 26.5 simulator captures of the idle bubble, Memory empty
state, and automatic connection setup. They contain
no private credentials or personal conversation data.

For repeatable empty Memory captures, a Debug build accepts `--preview-memory`
as a launch argument. This navigation override is excluded from Release builds.
