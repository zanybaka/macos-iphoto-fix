// appkit_shim.example.m
//
// Reference for the AppKit shim that fix-iphoto-sequoia.sh generates dynamically.
// The script writes one of these (with the exact classes missing on YOUR macOS)
// and compiles it into the bundle at:
//   <App>.app/Contents/Frameworks/AppKit.framework/Versions/C/AppKit
//
// How it works:
//   * It is named/placed so the app's (Retroactive-redirected) ProKit loads it
//     as "AppKit".
//   * It RE-EXPORTS the live system AppKit, so every still-present class
//     (NSButton, NSView, ...) resolves normally.
//   * It DEFINES empty stub classes only for the private AppKit classes whose
//     _OBJC_CLASS_$_ symbol the current macOS no longer exports, satisfying the
//     app's static two-level binds. (Stubbing a class that still exists would
//     shadow the real one, so the script stubs ONLY genuinely-missing symbols.)
//
// Build (what the script does):
//   clang -arch x86_64 -dynamiclib -o AppKit appkit_shim.m \
//     -install_name /System/Library/Frameworks/AppKit.framework/Versions/A/AppKit \
//     -compatibility_version 45.0.0 -current_version 9999.0.0 \
//     -Wl,-reexport_framework,AppKit -framework Foundation
//   codesign --force --sign - AppKit
//
// The classes below are the set observed on macOS 15.7.5 (Sequoia) for a
// 2023-era Retroactive-patched iPhoto 9.6.1. Yours may differ — let the script
// detect them.

#import <Cocoa/Cocoa.h>

@interface NSRegion : NSObject @end
@implementation NSRegion @end

@interface _NSControllerTreeProxy : NSObject @end
@implementation _NSControllerTreeProxy @end

@interface NSFlippableView : NSView @end
@implementation NSFlippableView @end

@interface NSToolbarClippedItemsIndicator : NSView @end
@implementation NSToolbarClippedItemsIndicator
+ (void)setCellClass:(Class)cellClass {}
@end
