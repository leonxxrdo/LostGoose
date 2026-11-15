# Installation

## Sileo / rootless deb

Add `https://repo.leonardx.wtf/`, refresh, and install LostGoose. An active, compatible jailbreak is required. The native package was tested on Dopamine 3.0.12 / iOS 17.3.1 on an iPhone 14 Plus. It registers the app with uicache; no respring is requested.

For the tested Choicy setup, LostGoose uses Custom Tweak Configuration, Allow with an empty allowed list, and Disable Tweak Injection off so Dopamine support remains available. Leave independent consumers isolated from location tweaks. Do not change global settings to troubleshoot blindly.

## IPA / TrollStore Lite

Use TrollStore Lite while the jailbreak is active. The 0.3.7 IPA retains the base signature profile; Lite handles installation and its signing adjustments. Earlier IPA builds worked on the test device, but the exact 0.3.7 IPA has not been tested. It should work tho, if not, open an issue and i will fix it.
## Switching formats

Both formats share one bundle identifier. Do not install duplicates. Before migrating, turn OFF, confirm your real location in independent apps, and back up anything you need. Exported diagnostics are not a complete app backup. Removal through Lite may remove data. The deb's pre-install check blocks conflicts without deleting the Lite app or migrating data.

## First check

Grant location access, check the map and diagnostics, and establish real-location readings in Apple Maps and a public Core Location witness. Select a destination, run the separate 30-second test, then check both the simulated destination and return to your real location. Re-start witness readings when returning to that app. If restoration fails, reopen LostGoose and request stop. Do not use service restarts or global location toggles as the normal stop mechanism.
