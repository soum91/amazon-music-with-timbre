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
