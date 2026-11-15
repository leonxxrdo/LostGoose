// SPDX-License-Identifier: GPL-3.0-only
#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>
@interface LGSearchController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic) MKCoordinateRegion searchRegion;
@property(nonatomic, copy) void (^onChoose)(MKMapItem *item, MKCoordinateRegion region);
- (void)cancelSearch;
@end
