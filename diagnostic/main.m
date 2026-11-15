// SPDX-License-Identifier: GPL-3.0-only
#import <UIKit/UIKit.h>
#import "ILLUIKitExecutionGuard.h"
#import "LGAppModel.h"
#import "LGMapController.h"
#import "LGDiagnosticController.h"
#import "LGMoreController.h"
@interface LostGooseDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) LGAppModel *model;
@end
@implementation LostGooseDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    ILLDiagnosticSession *session = [[ILLDiagnosticSession alloc] initWithEngine:[ILLFixedLocationEngine new]
        guard:[ILLUIKitExecutionGuard new] directory:[documents URLByAppendingPathComponent:@"Diagnostics"]];
    self.model = [[LGAppModel alloc] initWithSession:session];
    NSArray *pages = @[[[LGMapController alloc] initWithModel:self.model], [[LGDiagnosticController alloc] initWithModel:self.model],
        [[LGMoreController alloc] initWithModel:self.model]];
    NSMutableArray *controllers = [NSMutableArray array];
    for (UIViewController *page in pages) {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
        nav.tabBarItem = page.tabBarItem;
        UINavigationBarAppearance *appearance = [UINavigationBarAppearance new]; [appearance configureWithOpaqueBackground];
        nav.navigationBar.standardAppearance = appearance; nav.navigationBar.scrollEdgeAppearance = appearance;
        [controllers addObject:nav];
    }
    UITabBarController *tabs = [UITabBarController new]; tabs.viewControllers = controllers;
    UITabBarAppearance *appearance = [UITabBarAppearance new]; [appearance configureWithOpaqueBackground];
    tabs.tabBar.standardAppearance = appearance; tabs.tabBar.scrollEdgeAppearance = appearance;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds]; self.window.tintColor = UIColor.systemOrangeColor;
    self.window.rootViewController = tabs; [self.window makeKeyAndVisible]; return YES;
}
- (void)applicationDidEnterBackground:(UIApplication *)application { (void)application; [self.model enteredBackground]; }
- (void)applicationDidBecomeActive:(UIApplication *)application { (void)application; [self.model becameActive]; }
- (void)applicationWillTerminate:(UIApplication *)application {
    (void)application; [self.model.session stopWithReason:@"termination_callback" completion:nil];
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(LostGooseDelegate.class)); }
}
