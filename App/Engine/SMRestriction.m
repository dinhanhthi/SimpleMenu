#import "SMRestriction.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/log.h>

NSErrorDomain const SMRestrictionErrorDomain = @"SMRestrictionErrorDomain";

static const char *const SMFrameworkPath =
    "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore";

// Declarations of the private selectors, so that plain message sends get the right ARC semantics
// (init family). They are only sent after +isAvailable has checked every selector and its type encoding.
@protocol SMAssessmentModeConfiguration <NSObject>
- (nullable instancetype)initWithAllowedSystemItems:(NSArray<NSNumber *> *)systemItems
                           allowedBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers;
@end

@protocol SMAssessmentModeAssertion <NSObject>
- (void)activateWithConfiguration:(id)configuration completionHandler:(void (^)(void))completionHandler;
- (void)invalidate;
@end

static Class SMConfigurationClass;
static Class SMAssertionClass;
static NSString *SMUnavailableReason;

static os_log_t SMLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.math2it.simplemenu", "Restriction");
    });
    return log;
}

/// nil when `cls` implements `name` with exactly the encoding measured on macOS 27.2, else the reason.
static NSString *_Nullable SMCheckMethod(Class cls, NSString *name, const char *expected) {
    SEL sel = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(cls, sel);
    if (![cls instancesRespondToSelector:sel] || method == NULL) {
        return [NSString stringWithFormat:@"-[%@ %@] is missing", NSStringFromClass(cls), name];
    }
    const char *encoding = method_getTypeEncoding(method);
    if (encoding == NULL || strcmp(encoding, expected) != 0) {
        return [NSString stringWithFormat:@"-[%@ %@] has encoding %s, expected %s", NSStringFromClass(cls), name,
                                          encoding ?: "(none)", expected];
    }
    return nil;
}

/// nil when the API is usable, else the first failed check. Sets the class statics on success.
static NSString *_Nullable SMResolve(void) {
    // Never dlclose: the classes live as long as the process.
    if (dlopen(SMFrameworkPath, RTLD_NOW) == NULL) {
        const char *message = dlerror();
        return [NSString stringWithFormat:@"MenuBarClientCore could not be loaded: %s", message ?: "unknown error"];
    }
    Class configuration = NSClassFromString(@"MBAssessmentModeConfiguration");
    if (configuration == Nil) {
        return @"Class MBAssessmentModeConfiguration is missing";
    }
    Class assertion = NSClassFromString(@"MBAssessmentModeAssertion");
    if (assertion == Nil) {
        return @"Class MBAssessmentModeAssertion is missing";
    }
    NSString *reason = SMCheckMethod(configuration, @"initWithAllowedSystemItems:allowedBundleIdentifiers:",
                                     "@32@0:8@16@24");
    if (reason == nil) {
        reason = SMCheckMethod(assertion, @"activateWithConfiguration:completionHandler:", "v32@0:8@16@?24");
    }
    if (reason == nil) {
        reason = SMCheckMethod(assertion, @"invalidate", "v16@0:8");
    }
    if (reason == nil) {
        SMConfigurationClass = configuration;
        SMAssertionClass = assertion;
    }
    return reason;
}

static void SMResolveOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            SMUnavailableReason = SMResolve();
        } @catch (NSException *exception) {
            SMUnavailableReason = [NSString stringWithFormat:@"Checking MenuBarClientCore raised %@: %@",
                                                             exception.name, exception.reason];
        }
        if (SMUnavailableReason != nil) {
            os_log_error(SMLog(), "Menu bar restriction unavailable: %{public}@", SMUnavailableReason);
        }
    });
}

/// NSNumber 0...8: every system item (battery, Bluetooth, clock, displays, keyboard, sound, Wi-Fi, 7, Control Center)
/// stays visible. An empty or nil list would hide them all.
static NSArray<NSNumber *> *SMAllSystemItems(void) {
    return @[ @0, @1, @2, @3, @4, @5, @6, @7, @8 ];
}

static BOOL SMFail(NSError **error, SMRestrictionError code, NSString *description) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:SMRestrictionErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey : description}];
    }
    return NO;
}

/// -invalidate that never throws: an exception is logged and ignored.
static void SMInvalidate(id<SMAssessmentModeAssertion> assertion) {
    @try {
        [assertion invalidate];
    } @catch (NSException *exception) {
        os_log_error(SMLog(), "invalidate raised %{public}@: %{public}@", exception.name, exception.reason);
    }
}

@implementation SMRestriction {
    // Kept strong: the assertion must stay alive while it restricts the bar.
    id<SMAssessmentModeAssertion> _Nullable _current;
}

+ (BOOL)isAvailable {
    SMResolveOnce();
    return SMUnavailableReason == nil;
}

+ (NSString *)unavailableReason {
    SMResolveOnce();
    return SMUnavailableReason;
}

- (void)dealloc {
    [self clear];
}

- (BOOL)applyAllowedBundleIDs:(NSArray<NSString *> *)ids error:(NSError **)error {
    if (![SMRestriction isAvailable]) {
        return SMFail(error, SMRestrictionErrorUnavailable, SMUnavailableReason);
    }
    // Declared outside @try: ARC does not release locals of a scope an exception unwinds (no -fobjc-arc-exceptions).
    id configuration = nil;
    id<SMAssessmentModeAssertion> assertion = nil;
    @try {
        configuration = [[SMConfigurationClass alloc] initWithAllowedSystemItems:SMAllSystemItems()
                                                         allowedBundleIdentifiers:[ids copy]];
        if (configuration == nil) {
            return SMFail(error, SMRestrictionErrorAllocationFailed, @"MBAssessmentModeConfiguration init returned nil");
        }
        assertion = [[SMAssertionClass alloc] init];
        if (assertion == nil) {
            return SMFail(error, SMRestrictionErrorAllocationFailed, @"MBAssessmentModeAssertion init returned nil");
        }
        // The completion carries no error (failures are only os_logged by the framework).
        [assertion activateWithConfiguration:configuration completionHandler:^{}];
    } @catch (NSException *exception) {
        if (assertion != nil) {
            SMInvalidate(assertion);
        }
        NSString *description = [NSString stringWithFormat:@"Menu bar restriction raised %@: %@",
                                                           exception.name, exception.reason];
        return SMFail(error, SMRestrictionErrorException, description);
    }
    // New first, then the old one: the bar never passes through an unrestricted layout.
    id<SMAssessmentModeAssertion> previous = _current;
    _current = assertion;
    if (previous != nil) {
        SMInvalidate(previous);
    }
    return YES;
}

- (void)clear {
    id<SMAssessmentModeAssertion> current = _current;
    _current = nil;
    if (current != nil) {
        SMInvalidate(current);
    }
}

@end
