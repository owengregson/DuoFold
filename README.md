<div align="center">

# Duo Fold

**Wish you could bring the iPhone Duo effect to your MacBook?**

https://github.com/user-attachments/assets/3ea3b098-c6d2-4398-8f3a-e9087bbb33f2

Close the lid and watch your screen content tilt, blur, and fade as it moves.  
Duo Fold adds this effect to your MacBook, with controls in the menu bar.

**Available in:** English and Simplified Chinese (简体中文).

<img src="./assets/menu.png" width="340" alt="Duo Fold settings">

</div>

<hr>

With the default settings, it's recommended to view the effect in front of your MacBook.

- **Window server rendering:** The macOS window server blurs, dims and leans back the live screen itself: sharp at the hinge, rising toward the far edge as the lid closes, its edges fading into black. Nothing is captured, so no Screen Recording permission is needed.
- **Low power:** The lid sensor pushes its readings, so the app sleeps until the lid moves.
- **Metal fallback:** If macOS cannot draw the effect itself, Duo Fold captures the screen with ScreenCaptureKit and renders it with Metal instead, with the same settings. The blur is a stack of true Gaussian blurs half an octave apart: exact at the hinge, smooth at full strength, and dithered against banding.
- **Presets:** Start from Balanced, Subtle, Deep, Flat or Classic, then fine-tune any value; Revert takes you back to the preset.
- **Adjustable perspective:** Tweak the lean and perspective to suit your viewing position.
- **Preview:** Play the effect from the settings without closing the lid. A live gauge shows the lid angle against where the effect starts and where it reaches full strength.
- **Haptics:** The trackpad taps as the lid closes, in a pattern of your choice: even detents, tiny taps that come faster and faster, taps that swell, or one at the start and one at full effect.
- **Out of the way:** Hide the menu bar icon if you like; open Duo Fold again to bring up its settings.

## Download

[Download DMG](https://github.com/owengregson/mac-duo-rebirth/releases/download/dev/Duo-Fold-dev.dmg) | [Download ZIP](https://github.com/owengregson/mac-duo-rebirth/releases/download/dev/Duo-Fold-dev.zip)

These downloads contain the latest [development build](https://github.com/owengregson/mac-duo-rebirth/releases/tag/dev) for Apple Silicon and Intel Macs.

Requires macOS 14 or later and a MacBook with a compatible lid angle sensor.
Screen Recording permission is only needed if macOS cannot draw the effect itself and Duo Fold falls back to capturing the screen.

## Build

Requires Xcode with Swift 6.0 or later. Run from the project directory:

```sh
./build.sh
```

The script creates `build/Duo Fold.app` with an ad-hoc signature. Open it from Finder, or build and launch with:

```sh
./build.sh --run
```

macOS may require Screen Recording permission again after rebuilding with ad-hoc signing.

## Known limitations

- Only MacBooks with a compatible lid angle sensor can use the effect. The app reports when no sensor is available.
- The sensor must be one macOS marks as built-in. An external display with a similar sensor is ignored.
- The effect applies only to the built-in display.
- The effect stops when macOS sleeps as the lid closes.
- Clicks pass through the effect to the apps underneath. Press Escape to end the effect at once; Duo Fold only takes the key while the effect covers the screen.
- The window server effect relies on private Core Animation classes. If a macOS release removes them, the app captures the screen instead.
- The lid sensor's report rate is shared by the whole system and outlives the app. Duo Fold puts it back whenever it quits or the Mac sleeps, but cannot when it is force quit; `build/lidprobe reset` puts it back then, as does the next normal quit.

## Acknowledgements

This project is built with AI assistance.

## License

Licensed under the [Apache License 2.0](LICENSE). Copyright 2026 owengregson.

See [NOTICE](NOTICE) for attribution.
