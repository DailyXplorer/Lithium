#import <Foundation/Foundation.h>

/// The file every NSWorkspace hand-off the test process attempted is written to, with its stack.
/// `LITHIUM_HANDOFF_LOG`, or `lithium-test-handoffs.log` in the temporary folder.
NSString *LithiumHandOffLogPath(void);

/// True once the guard has replaced NSWorkspace's opening methods, before any test ran.
BOOL LithiumHandOffGuardInstalled(void);

/// How many opens the guard has refused in this process.
NSInteger LithiumHandOffCount(void);

/// True when the process's sandbox refuses LaunchServices' opens (`scripts/test`'s `deny lsopen`),
/// asked of the sandbox without opening anything.
BOOL LithiumLaunchServicesDenied(void);
