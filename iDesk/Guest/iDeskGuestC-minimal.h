// Minimal Swift-visible surface of the guest ObjC layer (used by the SwiftPM build lane).
// The full headers pull UIKit into the Swift clang importer, whose arm_neon.h parse fails
// with the Linux host toolchain — keep them private to the ObjC target.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
@class UIWindow;
@class UIWindowScene;
@class UIScene;

NS_ASSUME_NONNULL_BEGIN
@interface GuestRuntime : NSObject
+ (nullable UIWindow *)launchBundleAtPath:(NSString *)bundlePath scene:(UIWindowScene *)scene error:(NSError **)error;
+ (NSArray<UIWindow *> *)windowsOfAppWithWindow:(UIWindow *)handle;
+ (UIWindow *)touchWindowAt:(CGPoint)point appWindow:(UIWindow *)handle;
+ (BOOL)appWantsLandscapeWithWindow:(UIWindow *)handle;
+ (BOOL)goBackInAppWithWindow:(UIWindow *)handle;
+ (void)activateAppWithWindow:(UIWindow *)handle;
+ (void)suspendAppWithWindow:(UIWindow *)handle;
+ (void)resumeAppWithWindow:(UIWindow *)handle;
+ (void)forwardSceneEvent:(SEL)selector scene:(UIScene *)scene;
@end
extern NSNotificationName const GuestRuntimeOpenURLNotification;
extern NSNotificationName const GuestRuntimeWindowsChangedNotification;
extern NSNotificationName const GuestRuntimeNotificationNotification;
@interface GuestTouch : NSObject
+ (void)beginAt:(CGPoint)point inWindow:(UIWindow *)window;
+ (void)moveTo:(CGPoint)point;
+ (void)end;
+ (void)cancel;
@property (class, nonatomic, readonly) BOOL isActive;
+ (BOOL)scrollAt:(CGPoint)point inWindow:(UIWindow *)window dx:(CGFloat)dx dy:(CGFloat)dy;
+ (BOOL)insertText:(NSString *)text inWindow:(UIWindow *)window;
+ (BOOL)deleteBackwardInWindow:(UIWindow *)window;
+ (BOOL)performEditAction:(SEL)action inWindow:(UIWindow *)window;
/// The guest window's current text input (its first responder when it is a UIKeyInput), else nil.
+ (nullable id)keyInputInWindow:(UIWindow *)window;
@end
@interface CrashReporter : NSObject
+ (void)install;
+ (void)setGuestName:(NSString *)name;
+ (nullable NSString *)takeLastReport;
@end
void CrashReporterRecordExit(int code, const void *caller);
NS_ASSUME_NONNULL_END
