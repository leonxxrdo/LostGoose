# Architecture and validation

The reusable Objective-C engine checks CLSimulationManager availability, selectors and method signatures, then serializes backend calls off the main thread. The coordinator distinguishes point selection, configuration, request submission and location observation. A persisted marker records pending cleanup and supports recovery on relaunch; it cannot guarantee execution after process death.

The native app and the IPA use different signature profiles. The native profile adds Dopamine PMAP trust, application identity, limited GPU/IOSurface clients and an explicit own-container binding. Whole-bundle signing seals Info.plist, resources and executable pages. The IPA keeps the base simulation and Mach-lookup permissions for Lite installation.

For native 0.3.6, the user confirmed map rendering, writable diagnostics and enabled controls after normal Sileo installation. A fresh real-location baseline was established in Witness and Apple Maps; the user then reported Tokyo and real-location restoration in both after one timed test. Local events show start/stop requests off the main thread and a lease-expired stop request about 30.001 seconds after selection. That is request timing, not measured restoration latency. Accuracy and numeric freshness for that final cycle were not separately reported.

Earlier fixes for PMAP, whole-bundle signing and a path-scoped storage exception did not by themselves resolve the incident. Graphics access restored the map; explicit own-container binding restored storage. The unsuccessful path exception and on-device signing were removed in 0.3.6.

Earlier console/Lite trials covered additional scenarios, but do not prove all native lifecycle behavior. Continuous/background native sessions and force-quit recovery were not retested in the final cycle. No universal compatibility, indefinite execution or bit-for-bit reproducibility claim is made. Never treat a void backend return, an entitlement or a local status as proof of external location change.

## Tests

`test_app_distribution.py` exercises installer behavior using a simulated uicache. `test_native_signing.py` and `test_bundle_signature.py` exercise actual artifacts and reject broadened profiles or modified bundle content. They expect the 0.3.6 package and app under `build/lostgoose-0.3.7/`, plus `.tooling/ldid/ldid`.

`test_release_distribution.py` requires `build/release-repo-0.3.7/` and its manifest; it verifies HTTP content and rejects changed sources/HTML. `test_repo_distribution.py` targets the original canary fixture. `test_postinstall_scope.py` is skipped because that failed storage experiment was superseded. Device runners require deliberate setup and observation; they are not ordinary host tests.
