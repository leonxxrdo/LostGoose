# Changelog

## 0.3.7 (build 12) — prerelease

- Change in-app support email to contact@leonardx.wtf.
- Prepare the first GitHub source publication and IPA prerelease, including SHA256SUMS.
- Give the Sileo repository its own user-provided image and Leonardx identity; preserve the LostGoose application icon.

Simulation code and approved signing profiles are unchanged from 0.3.6. This exact IPA/deb build has not yet been device-tested.

## 0.3.6 (build 11)

Fix native rootless app storage with an explicit own-container binding. Retain whole-bundle signing and limited graphics permissions; remove the unsuccessful path-scoped exception and device-side signing. Normal Sileo update and a timed Tokyo/restoration cycle were confirmed in Witness and Apple Maps on the documented test device.
