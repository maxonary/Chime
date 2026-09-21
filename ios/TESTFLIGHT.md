# iPhone and Watch TestFlight builds

Chime runs natively on iPhone (iOS 26.5+) and Apple Watch (watchOS 26.5+).
The shared **Chime** scheme archives the iPhone app, embedded Watch app, and Watch widgets.
The **chime Watch App** scheme remains available for direct Watch development.

## Identifiers and signing

- iPhone: `maxonary.chime`
- Watch: `maxonary.chime.watchkitapp`
- Watch widgets: `maxonary.chime.watchkitapp.widgets`
- Current team: `Q37KAF726J`; automatic signing.
- App Store Connect: [Chime — Voice Bubble](https://appstoreconnect.apple.com/apps/6814462529/testflight).

The App Store listing uses a longer name because “Chime” was already taken.
The installed app is named Chime and uses the detailed bubble icon on both devices.

## Archive and upload

Sign in to the paid developer team in **Xcode → Settings → Apple Accounts**.
Browser sign-in to App Store Connect is separate from Xcode's upload authentication.
Increase `CURRENT_PROJECT_VERSION` in all three targets before uploading a subsequent build.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project chime.xcodeproj -scheme Chime -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath .context/Chime.xcarchive -allowProvisioningUpdates archive
```

Open the archive in Xcode Organizer and choose **Distribute App → App Store Connect**.
Once Apple finishes processing, add the build and your own account to an internal
TestFlight group. External testing may require Apple's beta review.
This does not submit the app for public App Store release.

## Install and connect

1. Install Apple's TestFlight app on your iPhone and accept the tester invitation.
2. Install Chime in TestFlight. Install its companion Watch app from the build's
   details or the iPhone Watch app.
3. If Chime already works on your Watch, open it there and on the iPhone. The
   iPhone automatically imports the Watch's connection and opens the bubble.
   Both apps need build 2 or later for Watch-to-iPhone setup.
4. Tap the bubble and grant microphone permission.
5. Without a configured Watch, expand **Advanced connection** in Preferences
   and enter your HTTPS gateway and Chime service token once. The phone then
   sends that connection to its paired Watch.

Existing Watch credentials are preserved. A Watch can only bootstrap a phone
that has no saved connection; delayed Watch messages cannot replace credentials
set or rotated on the phone. The phone owns subsequent connection changes.
Application context provides durable delivery; reachable peers also receive an
immediate message. A queued transfer is not a delivery receipt. The phone and
Watch keep independent conversation memory and voice preferences. No credentials
are baked into the binary.

## Release checks

Run `scripts/check-watch.sh`, build the Chime scheme for an iPhone simulator, and
archive for a generic iOS device. Check fresh setup, invalid input, horizontal
navigation, microphone permission, an actual audible reply, stop/background handling,
and paired-device setup on hardware. Simulator builds cannot establish hardware
WatchConnectivity or validate microphone routing on a real iPhone.

PrivacyInfo.xcprivacy declares app-local UserDefaults usage. The encryption declaration
covers the system-provided HTTPS/TLS and hashing used by the app. App Store privacy
answers and a public privacy policy still need review before public distribution.

Apple references: [TestFlight installation](https://testflight.apple.com/),
[beta testing](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/),
[Watch companion configuration](https://developer.apple.com/documentation/technotes/tn3157-updating-your-watchos-project-for-swiftui-and-widgetkit).
