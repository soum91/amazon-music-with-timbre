# Home/Profile investigation

Build 13 device report: all six legacy hooks installed; no exceptions or JS-load
notifications; 31 JSON dictionaries inspected; no explicit API errors; 33 HTTP
successes; no unresolved keychain errors. This does not prove frontend startup
failed: the host uses bridgeless React Native.

Static verification against original 26.37.1 decrypted IPA:
AlcatrazReactNativeCore.framework/AlcatrazReactNativeCore arm64:
- AlcatrazReactNativeAppDelegate bridgelessEnabled at 0xc42e4 returns true.
- fabricEnabled 0xc42dc and turboModuleEnabled 0xc42d4 also return true.
- bundleURL 0xc4208 calls resolver 0xc3e24. Resolver prefers configured remote
  location, then NSBundle for app delegate class and main.jsbundle resource.
- RCTHost.start 0x2c0fac, RCTInstance._start 0x2c3a68.
- RCTInstance._loadJSBundle: 0x2c587c; _loadScriptFromSource: 0x2c5af8.
- RCTInstance.handleBundleLoadingError: 0x2c5648.
- RCTHost instance:didReceiveJSErrorStack:message:originalMessage:name:
  componentStack:exceptionId:isFatal:extraData: at 0x2c165c, ABI
  BOOL(id,id,id,id,id,id,NSUInteger,BOOL,id), Objective-C encoding
  B84@0:8@16@24@32@40@48@56Q64B72@76.
- Bundled notification string: RCTInstanceDidLoadBundle.

Build 14 observes these Objective-C boundaries. Runtime method encodings must
match before installing hooks; original callbacks, arguments, and return values
are preserved. No Swift actor internals, C++ exception structs, authentication
state or startup-ready flags are patched. Only actual object ivars with @ type
encoding are inspected for presence/class. No initial props are exported.

Expected discrimination:
- No app-delegate setup or root view calls: caller/setup gate is earlier.
- Setup/root-view entered but host.start absent: factory configuration path.
- Host starts but no bundle request: runtime setup path.
- Bundle URL nil/missing file: bundle selection/resource failure.
- Bundle failure: actual NSError and domain/code.
- Bundle loaded but view absent: surface/navigation/provider path.
- Bridgeless JS error: actual message and bounded JS stack.

No Home/Profile root cause has yet been established. A new diagnostic build must
not be described as a functional fix. Report hook availability explicitly.

Build 14 device report confirmed root-view creation, valid 33,130,948-byte local
main.jsbundle, RCTInstanceDidLoadBundle, and no captured errors. Startup did not
stop at bundle resolution/loading. Native viewDidLoad also returned.

Hermes bytecode 96 was decoded without modification. AppNavigator function
28633 calls NotificationModule.navigationSystemReady from navigation onReady.
Wrapper function 76727 invokes NotificationModule.onPropsReceived for a supplied
prop ID. Objective-C implementation methods verified in
AlcatrazReactNativeModules are navigationSystemReady (v16@0:8) and
onPropsReceived: (v24@0:8@16). Build 15 observes those exact boundaries, not
assumed legacy callbacks. No prop IDs or initial-prop values are exported.

Build 15 additionally preserves four main-thread active-app view-hierarchy
snapshots before the Timbre sheet opens. Class/frame/hidden/alpha/opaque and
spinner state only; no labels or identifiers. Frontmost siblings are visited
first with a 220-node/14-depth limit so overlays appear before large content
trees. This diagnoses visibility rather than forcibly removing loading views.

Build 15: native navigationSystemReady callback ran. No props acknowledgement
was captured; that alone is not evidence of failure for a native page. Snapshot
shows an Amazon activity indicator visible, WKWebView hidden, and a native
AlcatrazCurate gallery with widgets in the same screen hierarchy. Audible and
Podcasts reportedly work; music Explore fails.

Static AMLicensedMusicBaseViewController webView:didFinishNavigation: at
0x1000d9240 calls loadingSpinner.stopAnimating then webView.setHidden:NO.
The request path includes startLoadingWebViewWithNonce: and cookies. This is
a candidate controller path, not yet proven to own the failing page.

Build 16 records WebKit delegate completion/failure and native nonce-callback
presence, and adds WK URL host/loading/progress/navigationDelegate/owning
controller to view snapshots. No URL paths, cookies, nonce values or request
headers are exported.

The optional 'Reveal gallery for 30 seconds' action is an explicit reversible
visibility probe. Requires a visible native gallery/widget and a later sibling
covering at least 70% of its common parent, containing a hidden WKWebView and a
visible Amazon spinner. It hides only that sibling, restores after 30 seconds
or an early second tap, records the override, and never sends auth/navigation
callbacks. This is not a functional fix and may expose placeholder content.

## GUI 17: device-authorization loading repair

GUI 16 report confirms repeated reloads of AMLicensedMusicDeviceAuthorizationViewController without either cookie/nonce loading call. Static inspection confirms its webViewAuth returns 0; the base reload hides the web view and animates its spinner but starts requests only for modes 1 and 2. GUI 17 maps only mode 0 on that exact class, with an HTTPS music.amazon regional URL, to the original mode-1 cookie refresh flow. Existing modes, other classes, non-Amazon destinations and all server authorization callbacks are unchanged. No successful authorization is fabricated and no dismissal is forced. On-device completion remains to be verified.

Tests exercise stalled-to-cookie dispatch, existing cookie/nonce routes, nil/unsafe destinations, base/other subclasses and secret redaction.

## GUI 18: scoped bundled-domain compatibility

GUI 17 device report confirms cookie requests now start but navigation never commits; the recording shows Exception #160. Original en-CA localization maps this to licensed_music_webview_error_redirection_desc. In AMLicensedMusicBaseViewController's navigation policy, code 4 is raised when isTrustedDomain or the secure-scheme check fails. NSURL's isTrustedDomain reads licensed_trusted_domains; the original bundled configuration includes music.amazon.com through .amazon.com.

GUI 18 restores only the bundled Amazon domain entries while the exact device-authorization controller runs its original synchronous navigation policy, and only for the URL currently being checked. HTTPS, no URL credentials, and default/443 port are mandatory for fallback. Original successful trust results, native decision callbacks, cookie refresh and server authorization handlers are preserved. No blanket delegate allow, TLS exception or success/dismiss callback is introduced. This is a targeted compatibility repair; actual server completion still needs device verification.

Tests simulate an empty runtime trust result, exercise bundled Amazon redirects and callback routes, reject lookalike hosts, insecure schemes, URL credentials and unexpected ports, ignore non-Amazon bundled entries, and verify the scoped fallback does not affect other delegates/calls.

## GUI 19: audio format support and durable authorization decisions

Adds signed little-endian PCM 24-bit packed/24-in-32 and 32-bit integer conversion alongside float32/PCM16. Processing still applies only to supported decoded stereo buffers. Disabled processing preserves original buffers. Invalid layouts and big-endian formats are bypassed. PCM unit tests cover alignment, clipping, NaN and guard bytes with sanitizers.

Diagnostics now show observed DSP format separately from actual AVAudioSession rate, preferred rate and output port type/channel count. Source codec/bit depth and endpoint DAC depth remain explicitly unverified. A user-triggered 48 kHz preference calls setPreferredSampleRate without forcing session activation, replacing Amazon's decoder, or selecting a Bluetooth codec. No lossless AirPods or Atmos reconstruction is claimed.

Home remains unresolved in GUI 18. GUI 19 retains a separate bounded navigation decision/trust buffer so reload spam cannot erase the policy result; URL query strings, credentials and port names are omitted. No further auth behavior change is made.
