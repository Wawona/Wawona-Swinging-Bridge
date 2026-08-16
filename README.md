# Wawona Swinging Bridge

[![CI](https://github.com/Wawona/Wawona-Swinging-Bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/Wawona/Wawona-Swinging-Bridge/actions/workflows/ci.yml)

**Wawona Swinging Bridge** (formerly **anowaW**, “Wawona” reversed) is Wawona’s
**application bridge**: it turns running **macOS (Cocoa/AppKit)** and **Android**
apps into first-class **Wayland clients**, so they can tile inside a nested
compositor in Wawona **or** be forwarded with **waypipe-rs** (`wwn-waypipe`) onto
a **Linux** Wayland compositor with real resize, placement, and HID.

Future: **UIKit iOS** apps (Mode B / jailbreak only — not in the App Store IPA).

This repo is **only the bridge**. Compositor, Machines UI, and packaging live in
[`Wawona`](https://github.com/Wawona/Wawona).

## What it is (and is not)

- **Is:** Cocoa / Android / (future UIKit) → Wayland (+ waypipe to Linux).
- **Is not:** Desktop Replacement, LockScreen Replacement, or MediaProjection-as-desktop.
- Mode A (store/Play, stream-like) and Mode B (privileged) are **planned**; neither
  ships yet. iOS is **Mode B only**.

## Layout

```
flake.nix                              registryFragment + lib.mkAnowaw
dependencies/libs/anowaw/              per-platform recipes (legacy key `anowaw`)
core/                                  Rust core (Wayland client, C FFI `anowaw_*`)
platform/macos/                        ScreenCaptureKit + CGEvent
platform/android/                      VirtualDisplay + InputManager
```

Legacy C ABI / Nix recipe names (`anowaw`, `libanowaw`, `anowaw_*`) remain until
a follow-up rename; the product name is **Wawona Swinging Bridge**.

## Use

```nix
inputs.wwn-swinging-bridge.url = "github:Wawona/Wawona-Swinging-Bridge";

registry = wwn-toolchain.lib.baseRegistry // wwn-swinging-bridge.registryFragment;

anowaw = wwn-swinging-bridge.lib.mkAnowaw { inherit pkgs; platform = "macos"; };
```

## Standalone build

```sh
nix build .#anowaw-macos
nix build .#anowaw-ios
```

## Docs

- Product: [`Wawona/docs/swinging-bridge.md`](https://github.com/Wawona/Wawona/blob/development/docs/swinging-bridge.md)
- Public: https://wawona.io/docs/swinging-bridge/
