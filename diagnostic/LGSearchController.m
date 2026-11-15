// SPDX-License-Identifier: GPL-3.0-only
#import "LGSearchController.h"
#include <math.h>
@interface LGSearchController ()
@property(nonatomic, strong) MKLocalSearch *search;
@property(nonatomic, strong) NSArray<MKMapItem *> *items;
@property(nonatomic) MKCoordinateRegion resultRegion;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, copy) NSString *notice;
@end
@implementation LGSearchController
- (void)viewDidLoad { [super viewDidLoad]; self.notice = @"Enter a city or place."; self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag; }
- (void)cancelSearch { ++self.generation; [self.search cancel]; self.search = nil; }
- (void)updateSearchResultsForSearchController:(UISearchController *)controller {
    [self cancelSearch]; NSUInteger generation = self.generation;
    if (!controller.active) return;
    NSString *query = [controller.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.items = @[]; self.notice = query.length < 2 ? @"Enter at least two letters." : @"Searching…"; [self.tableView reloadData];
    if (query.length < 2) return;
    __weak LGSearchController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LGSearchController *results = weakSelf; if (!results || generation != results.generation) return;
        MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] init]; request.naturalLanguageQuery = query;
        request.resultTypes = MKLocalSearchResultTypeAddress; request.region = results.searchRegion;
        MKLocalSearch *search = [[MKLocalSearch alloc] initWithRequest:request]; results.search = search;
        [search startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
            LGSearchController *current = weakSelf; if (!current || generation != current.generation) return;
            current.search = nil; current.items = response.mapItems ?: @[];
            current.resultRegion = response ? response.boundingRegion : MKCoordinateRegionMake(CLLocationCoordinate2DMake(0, 0), MKCoordinateSpanMake(0, 0));
            current.notice = error ? @"Search failed. Check your connection and try again." : @"No results for this search.";
            [current.tableView reloadData];
        }];
    });
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section; return MAX((NSInteger)self.items.count, 1);
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"result"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"result"];
    if (!self.items.count) { cell.textLabel.text = self.notice; cell.detailTextLabel.text = nil; cell.accessoryType = UITableViewCellAccessoryNone; }
    else { MKMapItem *item = self.items[indexPath.row]; cell.textLabel.text = item.name; cell.detailTextLabel.text = item.placemark.title;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES]; if ((NSUInteger)indexPath.row >= self.items.count) return;
    MKMapItem *item = self.items[indexPath.row]; if (!CLLocationCoordinate2DIsValid(item.placemark.coordinate)) return;
    MKCoordinateRegion region = self.items.count == 1 ? self.resultRegion : MKCoordinateRegionMakeWithDistance(item.placemark.coordinate, 20000, 20000);
    if (!isfinite(region.span.latitudeDelta) || !isfinite(region.span.longitudeDelta))
        region = MKCoordinateRegionMakeWithDistance(item.placemark.coordinate, 20000, 20000);
    region.center = item.placemark.coordinate;
    region.span.latitudeDelta = MIN(3, MAX(0.04, region.span.latitudeDelta));
    region.span.longitudeDelta = MIN(3, MAX(0.04, region.span.longitudeDelta));
    if (self.onChoose) self.onChoose(item, region);
}
@end
