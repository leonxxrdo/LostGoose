// SPDX-License-Identifier: GPL-3.0-only
#import <UIKit/UIKit.h>
#import "LGAppModel.h"
@interface LGMapController : UIViewController
- (instancetype)initWithModel:(LGAppModel *)model;
- (void)showSelectedPoint;
@end
