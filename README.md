# PowerFlow

A tiny macOS menu bar app that shows, live, where your MacBook's charging power goes:
**how much goes into the battery, how much the Mac itself uses, and how much goes out to
devices charging from its USB-C ports** (e.g. an iPhone).

一个小巧的 macOS 菜单栏工具，实时显示 MacBook 的充电功率去向：多少进了电池、多少被 Mac 自己用掉、
多少通过 USB-C 输出给了外接设备（比如 iPhone）。

## Features

- Menu bar readout: `⚡︎86W 🔋+62 📱12` (adapter in · battery · devices)
- Sankey-style flow diagram: adapter (and battery, when it has to help) → battery / Mac / each USB-C device
- Share of input going to each destination, plus Apple's adapter-loss estimate
- 10-minute history chart
- Shows the attached device's own battery % when it reports one (iPhone does)
- No root, no kernel extensions, no network — reads `AppleSmartBattery` from the IORegistry

## Install

1. Download `PowerFlow.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move `PowerFlow.app` to `/Applications`.
3. The app is not notarized by Apple, so the first launch is blocked. Either:
   - Right-click the app → **Open** → **Open**, or on newer macOS go to
     **System Settings → Privacy & Security** and click **Open Anyway**; or
   - run `xattr -dr com.apple.quarantine /Applications/PowerFlow.app`

## Build from source

Requires Xcode command line tools (Swift 5.9+), macOS 14+.

```bash
git clone https://github.com/<you>/PowerFlow.git
cd PowerFlow
./build.sh
open PowerFlow.app
```

## How it works / caveats

Values come from the undocumented `PowerTelemetryData`, `PowerOutDetails` and `FedDetails`
keys of `AppleSmartBattery`. They're what Apple's own firmware reports, but they aren't a
public API and may change between macOS versions.

- **Mac** is computed as `SystemLoad − USB-C output`.
- Best supported on Apple Silicon MacBooks. Intel Macs expose fewer keys; the app falls back
  to battery voltage × current, and per-port output may be missing.
- Independently sampled values don't always add up exactly; any gap is shown as
  "Unaccounted / conversion".

**Does charging a phone from the Mac wear the Mac's battery?** While the Mac is plugged in,
USB-C devices are fed from the system power rail, which the adapter supplies — the battery is
not discharged to charge them unless total demand exceeds what the adapter can deliver. When
that happens, PowerFlow shows the battery as a second source.

## License

MIT
