#import "HandOffGuard.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

// Nothing in the test process may open another app on the user's screen, whoever asks: Lithium,
// WebKit, PDFKit or AppKit. Every NSWorkspace method that opens or shows something is replaced,
// as the test bundle loads, by one that only writes what was asked and from where.

static BOOL installed = NO;

NSString *LithiumHandOffLogPath(void) {
    NSString *path = NSProcessInfo.processInfo.environment[@"LITHIUM_HANDOFF_LOG"];
    return path.length ? path : [NSTemporaryDirectory() stringByAppendingPathComponent:@"lithium-test-handoffs.log"];
}

BOOL LithiumHandOffGuardInstalled(void) { return installed; }

static NSInteger count = 0;

NSInteger LithiumHandOffCount(void) { @synchronized ([NSWorkspace class]) { return count; } }

extern int sandbox_check(pid_t pid, const char *operation, int type, ...);

BOOL LithiumLaunchServicesDenied(void) { return sandbox_check(getpid(), "lsopen", 0) != 0; }

static void record(NSString *method, id what) {
    NSMutableString *entry = [NSMutableString stringWithFormat:@"%@ %@ %@\n", NSDate.date, method, what];
    for (NSString *frame in NSThread.callStackSymbols) [entry appendFormat:@"    %@\n", frame];
    [entry appendString:@"\n"];
    NSString *path = LithiumHandOffLogPath();
    @synchronized ([NSWorkspace class]) {
        count += 1;
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) [NSData.data writeToFile:path atomically:NO];
        NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
        [file seekToEndOfFile];
        [file writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
        [file closeFile];
    }
    fprintf(stderr, "LithiumTestGuard: refused NSWorkspace %s %s (stack in %s)\n", method.UTF8String, [[what description] UTF8String], path.UTF8String);
}

static NSError *refused(void) {
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:@{NSLocalizedDescriptionKey: @"Tests never open another app."}];
}

static void replace(NSString *name, id block) {
    Method method = class_getInstanceMethod(NSWorkspace.class, NSSelectorFromString(name));
    if (method) method_setImplementation(method, imp_implementationWithBlock(block));
}

__attribute__((constructor)) static void install(void) {
    replace(@"openURL:", ^BOOL(id _, NSURL *url) { record(@"openURL:", url); return NO; });
    replace(@"openURLs:withAppBundleIdentifier:options:additionalEventParamDescriptor:launchIdentifiers:",
            ^BOOL(id _, NSArray *urls, NSString *app, NSUInteger o, id d, id *l) { record(@"openURLs:withAppBundleIdentifier:…", @[urls, app ?: @"default"]); return NO; });
    replace(@"openURL:options:configuration:error:",
            ^id(id _, NSURL *url, NSUInteger o, id c, NSError **error) { record(@"openURL:options:configuration:error:", url); if (error) *error = refused(); return nil; });
    replace(@"openURLs:withApplicationAtURL:options:configuration:error:",
            ^id(id _, NSArray *urls, NSURL *app, NSUInteger o, id c, NSError **error) { record(@"openURLs:withApplicationAtURL:options:configuration:error:", @[urls, app]); if (error) *error = refused(); return nil; });
    replace(@"openURL:configuration:completionHandler:",
            ^(id _, NSURL *url, id c, void (^done)(id, NSError *)) { record(@"openURL:configuration:completionHandler:", url); if (done) done(nil, refused()); });
    replace(@"openURLs:withApplicationAtURL:configuration:completionHandler:",
            ^(id _, NSArray *urls, NSURL *app, id c, void (^done)(id, NSError *)) { record(@"openURLs:withApplicationAtURL:configuration:completionHandler:", @[urls, app]); if (done) done(nil, refused()); });
    replace(@"openApplicationAtURL:configuration:completionHandler:",
            ^(id _, NSURL *app, id c, void (^done)(id, NSError *)) { record(@"openApplicationAtURL:configuration:completionHandler:", app); if (done) done(nil, refused()); });
    replace(@"launchApplicationAtURL:options:configuration:error:",
            ^id(id _, NSURL *app, NSUInteger o, id c, NSError **error) { record(@"launchApplicationAtURL:options:configuration:error:", app); if (error) *error = refused(); return nil; });
    replace(@"openFile:", ^BOOL(id _, NSString *file) { record(@"openFile:", file); return NO; });
    replace(@"openFile:withApplication:", ^BOOL(id _, NSString *file, NSString *app) { record(@"openFile:withApplication:", @[file, app ?: @"default"]); return NO; });
    replace(@"openFile:withApplication:andDeactivate:",
            ^BOOL(id _, NSString *file, NSString *app, BOOL d) { record(@"openFile:withApplication:andDeactivate:", @[file, app ?: @"default"]); return NO; });
    replace(@"openFile:fromImage:at:inView:",
            ^BOOL(id _, NSString *file, id i, NSPoint p, id v) { record(@"openFile:fromImage:at:inView:", file); return NO; });
    replace(@"openTempFile:", ^BOOL(id _, NSString *file) { record(@"openTempFile:", file); return NO; });
    replace(@"launchApplication:", ^BOOL(id _, NSString *app) { record(@"launchApplication:", app); return NO; });
    replace(@"launchApplication:showIcon:autolaunch:",
            ^BOOL(id _, NSString *app, BOOL s, BOOL a) { record(@"launchApplication:showIcon:autolaunch:", app); return NO; });
    replace(@"launchAppWithBundleIdentifier:options:additionalEventParamDescriptor:launchIdentifier:",
            ^BOOL(id _, NSString *app, NSUInteger o, id d, id *l) { record(@"launchAppWithBundleIdentifier:…", app); return NO; });
    replace(@"activateFileViewerSelectingURLs:", ^(id _, NSArray *urls) { record(@"activateFileViewerSelectingURLs:", urls); });
    replace(@"selectFile:inFileViewerRootedAtPath:",
            ^BOOL(id _, NSString *file, NSString *root) { record(@"selectFile:inFileViewerRootedAtPath:", file ?: root); return NO; });
    installed = YES;
}
