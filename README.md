# LostGoose

Free, open source fixed-location simulation for rootless jailbroken iOS 17 - 17.3.1

<p align="center"><img src="icon.png" alt="LostGoose icon" width="100"></p>

Apple MapKit selection and place search, manual coordinates, ON/OFF, and a separate 30-second diagnostic test. English interface; no accounts or application backend. Jitter is not implemented.

## Install

- **Sileo:** add https://repo.leonardx.wtf/ and install LostGoose, no respring needed.
- **IPA:** download from [Releases](https://github.com/leonxxrdo/LostGoose/releases) and install with TrollStore Lite while the jailbreak is active. The current 0.3.7 IPA has not yet been device-tested but it should work.

Choose one format: both share a bundle identifier. Native 0.3.6 was tested on iPhone 14 Plus / iOS 17.3.1 (21D61) / Dopamine 3.0.12, including Tokyo and automatic restoration in Witness (test app) and Apple Maps. 0.3.7 just changes the support email and preserves that engine/signing profile; this exact build is untested on-device but it should work regardless.

Turn OFF and confirm restoration before closing, updating or uninstalling. Force-quit can leave cleanup pending until the app is reopened; autonomous restoration is not guaranteed.

## Build

See [Linux build instructions](docs/BUILD.md), [installation](docs/INSTALLATION.md), [validation and test prerequisites](docs/VALIDATION.md), and [release notes](CHANGELOG.md). SDK, credentials and device logs are excluded.

[Website](https://leonardx.wtf) · [Sileo repository](https://repo.leonardx.wtf/) · Support: contact@leonardx.wtf

## Extra

Yes, the icon is not symmetrical, i dont know how to use Illustrator and i did my best, feel free to submit your own icon idc.

This is for educational purposes only and no, i wont include a joystick to change location, who even plays Pokemon Go on 2026? that game is old af.

Dont use this to cheat on ur wife or lie to ur mom when u sneak out to go buy drugs.

Also most apps use a mix of GPS location + WiFi/Cells to get ur location, this project only modifies the GPS location so good luck trying to bypass the other one.
