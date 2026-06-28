// symcheck.m — authoritative "is this ObjC class symbol exported on THIS macOS?"
//
// Reads class names on stdin (one per line) and prints those whose
// _OBJC_CLASS_$_<name> symbol is NOT exported by any loaded image. This is the
// correct test for whether a static two-level bind will fail at launch — a class
// can still exist at runtime (NSClassFromString != nil) while its symbol is gone.
//
// Build for the architecture the app actually runs in (x86_64 for iPhoto/Aperture):
//   clang -arch x86_64 -framework Foundation -o symcheck symcheck.m
// Usage:
//   printf 'NSRegion\nNSView\n' | ./symcheck     # prints only the missing ones

#import <Foundation/Foundation.h>
#import <dlfcn.h>

int main(void) { @autoreleasepool {
  // Load Cocoa so AppKit/Foundation symbols are present to test against.
  dlopen("/System/Library/Frameworks/Cocoa.framework/Cocoa", RTLD_NOW | RTLD_GLOBAL);
  NSData *d = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
  NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
  for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
    NSString *n = [line stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!n.length) continue;
    NSString *sym = [@"OBJC_CLASS_$_" stringByAppendingString:n];
    if (!dlsym(RTLD_DEFAULT, sym.UTF8String))
      printf("%s\n", n.UTF8String);
  }
} return 0; }
