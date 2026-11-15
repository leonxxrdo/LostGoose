# LostGoose

Free, open source fixed-location simulation for rootless jailbroken iOS 17 - 17.3.1

<p align="center"><img src="icon.png" alt="LostGoose icon" width="100"></p>

Apple MapKit selection and place search, manual coordinates, ON/OFF, and a separate 30-second diagnostic test. Jitter is not implemented (Its in the works i promise)

## Install

- **Sileo:** add https://repo.leonardx.wtf/ and install LostGoose, no respring needed.
- **IPA:** download from [Releases](https://github.com/leonxxrdo/LostGoose/releases) and install with TrollStore Lite while the jailbreak is active. The current 0.3.7 IPA has not yet been tested but it should work. If it does not let u install it, check the file extension and change it to .ipa instead of .zip, it should fix it.

Choose one format: both share a bundle identifier. Native 0.3.6 was tested on iPhone 14 Plus / iOS 17.3.1 (21D61) / Dopamine 3.0.12, including Tokyo and automatic restoration in Witness (test app) and Apple Maps. 
Turn OFF and confirm restoration before closing, updating or uninstalling. Force-quit can leave cleanup pending until the app is reopened; autonomous restoration is not guaranteed, just use common sense.

## Build

See [Linux build instructions](docs/BUILD.md), [installation](docs/INSTALLATION.md), [validation and test prerequisites](docs/VALIDATION.md), and [release notes](CHANGELOG.md).

[Website](https://leonardx.wtf) · [Repository](https://repo.leonardx.wtf/) · Support: contact@leonardx.wtf

## Extra

Yes, the icon is not symmetrical, i don't know how to use Illustrator and i did my best, feel free to submit your own icon idc.

This is for educational purposes only and no, i wont include a joystick to change location, who even plays Pokemon Go on 2026? that game is old af.

Don't use this to cheat on your wife or lie to your mom when u sneak out to go buy drugs.

Also most apps use a mix of GPS location + WiFi/Cells to get your location, this project only modifies the GPS location so good luck trying to bypass the other one.

It should work for iOS 16 and downwards but I cant test it and honestly i made this only for my use case, it wont work for iOS 18 and upwards.
