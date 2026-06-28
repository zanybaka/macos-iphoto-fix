# Case study: iPhoto 9.6.1 on macOS Sequoia 15.7.5 (Apple Silicon)

A worked example of diagnosing and repairing a Retroactive-patched iPhoto that a
macOS upgrade broke. This is the investigation the tool in this repo automates.

## Symptom

iPhoto 9.6.1 quit immediately at launch. Crash report:

```
Termination Reason: Namespace DYLD, Code 4 Symbol missing
Symbol not found: _OBJC_CLASS_$_NSRegion
  Referenced from: .../iPhoto.app/Contents/Frameworks/ProKit.framework/Versions/A/ProKit
  Expected in:     .../iPhoto.app/Contents/Frameworks/AppKit.framework/Versions/C/AppKit
```

## Findings

1. **Already Retroactive-patched.** The bundle contained an injected
   `AppKit.framework` shim and `ApertureFixer.framework` (the runtime fixer,
   injected 3× into the main binary), Python 2.6, etc. — patched ~Oct 2023. It had
   worked on the previous OS.

2. **The shim was a re-exporter.** `ProKit` links
   `@executable_path/../Frameworks/AppKit.framework/...` (the shim), and the shim
   `LC_REEXPORT_DYLIB`s the system AppKit and itself defines stub classes
   (`NSFlippableView`, `NSToolbarClippedItemsIndicator`). It did **not** define
   `NSRegion`.

3. **`NSRegion` is a symbol problem, not a class problem.** On 15.7.5 the class
   still exists at runtime (`NSClassFromString(@"NSRegion") != nil`), but
   `dlsym("OBJC_CLASS_$_NSRegion")` returns NULL — the *symbol* is no longer
   exported, so ProKit's static two-level bind fails in dyld.

4. **Architecture matters.** The same probe in the **arm64** slice misreported
   QTKit classes as missing (QTKit has no arm64 slice), while in **x86_64** —
   the slice the app runs in under Rosetta — QTKit and its classes are present.
   Always probe in x86_64 for these apps.

5. **A second layer waited behind the first.** After stubbing `NSRegion`, iPhoto
   reached the UI and then crashed in
   `-[NSSegmentedControlAppearanceBasedVisualProvider updateSegmentItemConfiguration:]`
   (out-of-bounds `__NSArrayM objectAtIndexedSubscript:`) — the Sequoia
   segmented-control rework. The bundle's 2023 `ApertureFixer` had only a font
   swizzle; it lacked this fix. Retroactive **3.0**'s `ApertureFixer` adds
   `retro_updateSegmentItemConfiguration:` and a `_retro_osAtLeastSequoia` gate.

## Fix applied

- Rebuilt the bundled AppKit shim to additionally stub the classes whose symbol
  is unexported on 15.7.5: `NSRegion`, `NSFlippableView`,
  `NSToolbarClippedItemsIndicator`, `_NSControllerTreeProxy` (verified via
  `dlsym` in x86_64). Re-exports live system AppKit for everything else.
- Replaced the bundle's `ApertureFixer` binary with Retroactive 3.0's.
- Ad-hoc signed both (app is unsigned; x86_64/Rosetta is lenient).

## Result

iPhoto launches, is responsive, opens `~/Pictures/iPhoto Library.photolibrary`,
produces no crash, and survives quit + relaunch. Confirmed on macOS 15.7.5,
MacBookPro18,1 (M1 Pro).

## Generalization

The set of unexported symbols changes per macOS release, and the needed
`ApertureFixer` version tracks new AppKit internals. So the durable approach is:
**detect** the missing symbols on the running OS (x86_64, via `dlsym`), **stub
exactly those** in the shim, and **refresh** the fixer from the newest Retroactive.
That is what `fix-iphoto-sequoia.sh` does.
