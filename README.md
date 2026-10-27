# Amazon Music with Timbre

Standalone project for the **non-jailbroken iOS IPA**. This is not the system-wide jailbreak tweak.

## Current baseline

Imported from `soum91/timbre`, branch `amazon-native-eq-test`, GUI Build 7.
The user's iPhone verified Amazon sign-in, track playback, and Timbre processing at 48 kHz.
The current interface has an EQ response graph, band frequency/gain/Q sliders, filter selection, presets, effects toggles, and a Diagnostics tab.
The floating launcher hides while the editor is presented so it does not cover Done.
GUI Build 7 passed compilation and DSP tests; its layout still requires on-device verification.

## Build

GitHub Actions builds the arm64 iOS 16+ embedded library on pushes to main and manual dispatches.
Artifacts contain the compiled `TimbreNative-FlareStore.dylib`.
The repository includes the DSP, HRTF tables, fishhook source/license, GUI, and packaging script. It has no dependency on the old Timbre repository.

To produce a complete IPA in Actions:
1. In this private repository, create a release with tag `source-ipa`.
2. Upload your original decrypted Amazon Music IPA as an asset named `Amazon-Music-source.ipa`.
3. Run **Build Amazon Music with Timbre** manually with **Package source IPA** enabled.
4. Download the resulting unsigned IPA artifact and sign it with FlareStore.

The Amazon app binary and signing certificates are not committed to Git. A source IPA is required for packaging; building the library alone does not require one.

Local packaging after building the library:
```sh
python3 Jailed/package_ipa.py Amazon-Music-source.ipa build/TimbreNative-FlareStore.dylib build/Amazon-Music-Timbre.ipa
```

Set `TIMBRE_BUILD_VERSION` to override the default `26.37.1.412778`.
Keep the same signer and install over the existing modified app to retain its app data. Preserve the bundle ID `com.amazon.mp3.AmazonCloudPlayer`.

## Login compatibility

The embedded library retries only the confirmed unavailable app keychain group
`J7P34ALZ5R.com.amazon.mp3.AmazonCloudPlayer` in this signed app's own permitted default group.
It discovers that default group using an empty temporary keychain item, then removes the probe.
It does not inspect or export credentials or session values, grant Amazon entitlements, or disable server authentication.

Two additional keychain groups were still denied during successful playback:
- `group.amazonmusic.prod.notificationlocale`
- `J7P34ALZ5R.com.amazon.mp3.AmazonCloudPlayer.Shared`

Their errors remain visible under Diagnostics. Do not assume all Amazon features work.

## Audio scope

The original app handles authentication, playback licensing and decoding.
Timbre processes supported stereo PCM output from its native dmengine AUGraph callback.
This does not decrypt protected streams or export audio. Other playback routes are not verified.
EQ supports up to 64 bands; effects support stereo up to 96 kHz. The response plot represents EQ and preamp, not the post-EQ effects.
Use increasing processed-frame counts plus the audible -12 dB test to verify a route.

## Layout

- `Jailed/TimbreNative.mm`: embedded GUI, private keychain compatibility and callback adapter
- `Jailed/fishhook.*`: import rebinding (license retained in source headers)
- `NativeDSP/`: DSP engine and HRTF tables
- `NativeDSP/tests/test.cpp`: audio processing tests
- `Jailed/package_ipa.py`: unsigned IPA packager
- `.github/workflows/build.yml`: standalone build and optional packaging

Source provenance and third-party notices remain in the imported files. No blanket relicensing of Amazon software is implied.

## EmberSign / FlareStore source

Feed path: `source.json`

```text
https://raw.githubusercontent.com/soum91/amazon-music-with-timbre/main/source.json
```

The repository is private. Anonymous raw/release requests will fail; importing this
feed and downloading its IPA require a sideloader capable of authenticated GitHub
access. Do not embed a personal token in the feed URL. A public feed/asset host is
needed for sideloaders that cannot authenticate.

The feed intentionally lists no app until a packaged IPA has been published.
A successful manual packaging run publishes the IPA to a GitHub release and then
updates the feed with the exact version, byte size, release URL and minimum iOS
version read from that IPA. Workflow run numbers increase the build version
automatically. Both the legacy app fields and `versions` are maintained.

## Head tracking and shared-storage experiment (Build 9)

The embedded adapter now connects Apple's CMHeadphoneMotionManager to the existing
Timbre head-yaw renderer. The Effects tab has head tracking, invert direction and
recenter controls. Both Timbre and immersive spatial must be enabled. Compatible
motion-capable headphones and Motion & Fitness authorization are required.
Stale motion older than half a second is discarded. No jailbreak daemon or
SpringBoard injection is used. Motion permission wording is added by the packager.
On-device tracking behavior and background delivery require verification.

The two additional groups observed in diagnostics are retried only for generic
password queries with an explicit service. Their services receive distinct prefixes
inside this app's permitted private group. This preserves the working primary login
namespace and does not grant access to Amazon's original shared keychain groups.
It is an experiment for Home/Profile loading, not a confirmed resolution. Other
query shapes remain unchanged and visible in Diagnostics.

`build-output/build.json` identifies the exact source commit and outcome of the
latest Actions build; a successful build also stores the embedded library as base64
for retrieving and packaging without relying on expiring artifact URLs.


## Original Timbre interface port (GUI 10)

`Jailed/TimbreEmbeddedUI.m` adapts `soum91/timbre`, branch `timbre-rootless`, commit `4f856379b9eaf2c55e6d44c0e7dac3eb816ca2e0`, `Tweak/TimbreControl/main.m`. It preserves the original graph gestures, fader controls, five pages, detailed effects, saved/imported presets and route rules. The controller is embedded in Amazon Music with a dedicated Done button. The purple launcher stays hidden while the editor is open. The earlier band list remains available through the menu.

The storage adapter uses app-local preferences. Every effects parameter is connected to the existing native DSP; the jailbreak helper, daemon diagnostics and system Chromecast daemon are excluded. AirPlay uses the standard system route picker. Head tracking uses this app's CoreMotion manager. No jailbreak project files are changed.

Home/Profile are still unresolved. The diagnostic view records request host, HTTP status and NSError domain/code for covered URLSession requests, plus failed Amazon app-group container lookups. It never records full URL paths, query strings, headers, bodies or credential values. Missing observations do not prove requests succeeded. GUI and Home/Profile behavior require on-device verification.
