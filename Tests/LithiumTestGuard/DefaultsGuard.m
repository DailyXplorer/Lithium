#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// UserDefaults.standard is the test helper's own domain, which cfprefsd keeps in the user's real
// Library/Preferences whatever CFFIXED_USER_HOME says. Test processes running side by side
// (scripts/test-fast) would share every setting through it: one turning agent access on starts
// a hub in the other's next Browser. With LITHIUM_DEFAULTS_SUITE set, the standard defaults are
// that suite instead, one per process.

__attribute__((constructor)) static void isolateDefaults(void) {
    NSString *suite = NSProcessInfo.processInfo.environment[@"LITHIUM_DEFAULTS_SUITE"];
    if (!suite.length) return;
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    Method method = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
    if (defaults && method) method_setImplementation(method, imp_implementationWithBlock(^NSUserDefaults *(id _) { return defaults; }));
}
