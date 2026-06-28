// probe.m — class-EXISTENCE check (informational).
//
// Reads class names on stdin and prints those that do NOT exist at runtime
// (NSClassFromString == nil) after loading the common frameworks below.
//
// NOTE: this is NOT the test that predicts a launch crash. A removed *symbol*
// crashes dyld even while the class still exists at runtime (e.g. NSRegion on
// Sequoia). For the authoritative symbol-export test, use symcheck.m. This tool
// is kept to illustrate the difference and to spot genuinely-vanished classes
// (e.g. QTKit's QTMovie on arm64 — run it per-arch to see arch differences).
//
// Build:  clang -arch x86_64 -framework Foundation -o probe probe.m

#import <Foundation/Foundation.h>
#import <dlfcn.h>

int main(void) { @autoreleasepool {
  const char *fw[] = {
    "/System/Library/Frameworks/Cocoa.framework/Cocoa",
    "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
    "/System/Library/Frameworks/Quartz.framework/Quartz",
    "/System/Library/Frameworks/WebKit.framework/WebKit",
    "/System/Library/Frameworks/QTKit.framework/QTKit",
    "/System/Library/Frameworks/AddressBook.framework/AddressBook",
    "/System/Library/Frameworks/ImageCaptureCore.framework/ImageCaptureCore",
    "/System/Library/Frameworks/AVFoundation.framework/AVFoundation",
    "/System/Library/Frameworks/ScreenSaver.framework/ScreenSaver",
    "/System/Library/Frameworks/DiscRecording.framework/DiscRecording",
    0 };
  for (int i = 0; fw[i]; i++) dlopen(fw[i], RTLD_NOW | RTLD_GLOBAL);
  NSData *d = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
  NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
  for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
    NSString *n = [line stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (n.length && NSClassFromString(n) == nil) printf("%s\n", n.UTF8String);
  }
} return 0; }
