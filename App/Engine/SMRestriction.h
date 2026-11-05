// Fail-soft wrapper around the private MenuBarClientCore assessment mode, which hides every
// menu bar item whose owner is not allow-listed. The framework is resolved at runtime and never linked.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const SMRestrictionErrorDomain;

typedef NS_ERROR_ENUM(SMRestrictionErrorDomain, SMRestrictionError) {
    /// The framework, a class, a selector or a type encoding is missing or changed (see unavailableReason).
    SMRestrictionErrorUnavailable = 1,
    /// alloc/init of the configuration or the assertion returned nil.
    SMRestrictionErrorAllocationFailed = 2,
    /// The private API raised an Objective-C exception.
    SMRestrictionErrorException = 3,
};

/// Owns at most one active assessment-mode assertion. Main thread only (not thread-safe).
///
/// Only synchronous failures are reported: the framework's completion handler carries no error and
/// only os_logs a failed restriction, so a caller that needs certainty confirms visibility through AX.
@interface SMRestriction : NSObject

/// Lazily (once) loads MenuBarClientCore and checks both classes, the three selectors and their type encodings.
+ (BOOL)isAvailable;

/// Which check failed, or nil when the API is available.
@property (class, nonatomic, readonly, nullable) NSString *unavailableReason;

/// Hides every non-system menu bar item whose owner is not in `ids`; all system items stay visible.
/// Activates the new assertion first, then invalidates the previous one (no visible flash).
/// On failure the previous assertion, if any, stays active.
- (BOOL)applyAllowedBundleIDs:(NSArray<NSString *> *)ids error:(NSError **)error;

/// Invalidates the current assertion, if any; the full bar returns ~130-190 ms later. Idempotent.
- (void)clear;

@end

NS_ASSUME_NONNULL_END
