<p align="center">
  <img src="assets/icon.png" width="160" alt="NovaShield icon">
</p>

<h1 align="center">NovaShield</h1>

<p align="center"><b>Performance and thermal rescue for lag, heat and memory pressure.</b><br>
Rootless tweak for iOS 15+ (Dopamine / palera1n rootless), made for the iPhone 7 Plus.</p>

<p align="center"><img src="assets/banner.png" alt="NovaShield banner"></p>

## What it does

| Feature | How it works |
| --- | --- |
| **Zero standby drain** | Listens to `com.apple.springboard.hasBlankedScreen`. When the screen turns off the sampling timer is cancelled, the HUD is removed and anything NovaShield paused is resumed. Nothing runs or is scheduled while locked. |
| **Live telemetry** | While the screen is on, every 2.5 s: CPU load from `host_statistics` tick deltas, memory saturation from `host_statistics64`, and `NSProcessInfo.thermalState`. The sampler runs on a utility queue so it never competes with a game. |
| **Glass warning HUD** | After 3 high checks in a row (about 8 s) a blurred, continuous-corner card springs in at the top or bottom. It follows the front app's orientation (landscape games), closes with a swipe, and leaves by itself when the load settles or after your chosen time. |
| **Boost & Cool** | One tap, with a haptic when finished. See below. |
| **Gaming Optimization Mode** | Boosts about 5 s after Mobile Legends, Telegram or FaceTime come to the front and keeps daemons paused while they stay in front. |
| **Settings pane** | Master switch, CPU threshold (60 to 95 %), memory warning, gaming mode, what Boost & Cool does, HUD position and time, Test HUD, reset and respring. |

### Boost & Cool

1. Clears memory caches in SpringBoard (`malloc_zone_pressure_relief`, URL cache, memory warning).
2. Closes background apps that are safe to close. It never closes the front app, calls, FaceTime, music or anything playing, navigation, Telegram, WhatsApp and similar chat apps, or most Apple apps.
3. Pauses background analysis and indexing daemons (`photoanalysisd`, `mediaanalysisd`, `parsecd`, `suggestd`, `searchd`, `duetexpertd` and a few more) with `SIGSTOP` for 90 s, then resumes them. Resumed on screen off, on disable, and on the next SpringBoard start if it ever crashed.
4. Tries to raise the foreground app's priority (`QOS_CLASS_USER_INTERACTIVE` for SpringBoard itself, `setpriority` for the app).

## Honest limits

- SpringBoard runs as the `mobile` user. NovaShield **cannot** touch root daemons such as `thermalmonitord`, change kernel thermal management or fix I2C bus hangs. It lowers the load that triggers them.
- Raising another app's priority is normally refused by iOS for unprivileged processes. The summary on the HUD says "priority raised" only when it actually worked.
- The memory warning level (92 % saturation) and the paused-daemon list are sensible defaults, not measurements from your device.
- It uses private SpringBoard APIs looked up at runtime, so an action may quietly do nothing on an iOS version where they changed.
- Mobile Legends and Telegram bundle IDs can differ by region. To change the list, write an array of bundle IDs to the `gamingApps` key in `com.kwarnu.novashield`.

## Install

Download the `.deb` from the **Releases** page (or the `NovaShield-deb` artifact in **Actions**), install it with Sileo, Zebra or Filza, and respring. Package: `com.kwarnu.novashield`, architecture `iphoneos-arm64`.

Requires iOS 15.0 or later, a rootless jailbreak, `mobilesubstrate` (ElleKit) and `preferenceloader`.

## Settings

Settings > NovaShield

| Setting | Default |
| --- | --- |
| Enable NovaShield | On |
| CPU Warning Threshold | 80 % |
| Warn on High Memory Use | On |
| Gaming Optimization Mode | On |
| Close Background Apps | On |
| Pause Background Daemons | On |
| HUD Position | Top |
| HUD Auto-dismiss | 8 s |

## Architecture

```
Tweak.m                       SpringBoard tweak (screen state, telemetry, HUD, rescue)
NovaShield.plist              MobileSubstrate filter (SpringBoard only)
prefs/                        PreferenceLoader bundle (Root.plist + list controller)
layout/                       PreferenceLoader entry and icons
depictions/native/            Sileo native depiction
.github/workflows/build.yml   macOS runner: Theos + SDKs, rootless build, release upload
```

Settings are stored with CFPreferences in `com.kwarnu.novashield` and applied live through the Darwin notification `com.kwarnu.novashield/prefschanged`.

## Build

Needs [Theos](https://theos.dev).

```sh
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

GitHub Actions builds the package on every push to `main` and attaches it to the `v<version>` release.

## License

MIT
