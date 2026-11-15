// SPDX-License-Identifier: GPL-3.0-only
#import "LGMapController.h"
#import "LGSearchController.h"
#import "LGUI.h"
@interface LGMapController () <MKMapViewDelegate, UIGestureRecognizerDelegate, UISearchControllerDelegate>
@property(nonatomic, strong) LGAppModel *model;
@property(nonatomic, strong) MKMapView *map;
@property(nonatomic, strong) MKPointAnnotation *pin;
@property(nonatomic, strong) UISwitch *toggle;
@property(nonatomic, strong) UILabel *toggleState, *coordinates, *status, *recovery;
@property(nonatomic, strong) UITapGestureRecognizer *tap;
@property(nonatomic, strong) UISearchController *finder;
@property(nonatomic, strong) LGSearchController *results;
@property(nonatomic) BOOL centerWhenReady;
@property(nonatomic) NSInteger appliedStyle;
@end
@implementation LGMapController
- (instancetype)initWithModel:(LGAppModel *)model {
    if ((self = [super init])) { _model = model; self.title = @"LostGoose"; _appliedStyle = -1;
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Map" image:[UIImage systemImageNamed:@"map.fill"] tag:0]; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.systemBackgroundColor; self.edgesForExtendedLayout = UIRectEdgeNone;
    self.toggle = [UISwitch new]; self.toggle.accessibilityLabel = @"Fake location ON or OFF";
    [self.toggle addTarget:self action:@selector(toggleChanged) forControlEvents:UIControlEventValueChanged];
    self.toggleState = LGLabel(@"OFF", UIFontTextStyleCaption1);
    UIStackView *switchRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.toggleState, self.toggle]];
    switchRow.spacing = 6; switchRow.alignment = UIStackViewAlignmentCenter;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:switchRow];
    self.results = [LGSearchController new];
    self.finder = [[UISearchController alloc] initWithSearchResultsController:self.results];
    self.finder.searchResultsUpdater = self.results; self.finder.delegate = self;
    self.finder.searchBar.placeholder = @"Search for a city or place"; self.finder.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.finder; self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.map = [MKMapView new]; self.map.delegate = self;
    self.recovery = LGLabel(@"", UIFontTextStyleSubheadline); self.recovery.hidden = YES;
    self.recovery.backgroundColor = [UIColor.systemYellowColor colorWithAlphaComponent:0.18];
    UIStackView *area = LGStack(@[self.recovery, self.map]); area.spacing = 4; area.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:area];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[[area.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [area.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor], [area.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [area.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]]];
    self.pin = [MKPointAnnotation new]; self.pin.title = @"Selected location"; self.pin.coordinate = self.model.selected;
    [self.map addAnnotation:self.pin]; [self.map setRegion:MKCoordinateRegionMakeWithDistance(self.model.selected, 3500, 3500) animated:NO];
    self.tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(mapTapped:)];
    self.tap.delegate = self; self.tap.cancelsTouchesInView = NO; [self.map addGestureRecognizer:self.tap];
    self.coordinates = LGLabel(@"", UIFontTextStyleCaption1);
    self.coordinates.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    self.status = LGLabel(@"Tap the map to select a location", UIFontTextStyleCaption2); self.status.textColor = UIColor.secondaryLabelColor;
    UIButton *edit = LGButton(@"Coordinates", self, @selector(editCoordinates));
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[LGStack(@[self.coordinates, self.status]), edit]];
    row.spacing = 8; row.alignment = UIStackViewAlignmentCenter;
    UIView *card = LGCard(@[row]); card.translatesAutoresizingMaskIntoConstraints = NO; card.backgroundColor = UIColor.secondarySystemBackgroundColor;
    [self.view addSubview:card];
    // Keep MapKit's Apple attribution and legal link unobstructed below the card.
    [NSLayoutConstraint activateConstraints:@[[card.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [card.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [card.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-48]]];
    UIButton *received = LGButton(@"", self, @selector(centerReceived));
    [received setImage:[UIImage systemImageNamed:@"location.fill"] forState:UIControlStateNormal];
    received.accessibilityLabel = @"Center received location";
    UIButton *chosen = LGButton(@"", self, @selector(showSelectedPoint));
    [chosen setImage:[UIImage systemImageNamed:@"mappin"] forState:UIControlStateNormal]; chosen.accessibilityLabel = @"Center selected location";
    UIView *controls = LGCard(@[received, chosen]); controls.translatesAutoresizingMaskIntoConstraints = NO;
    controls.backgroundColor = UIColor.secondarySystemBackgroundColor; [self.view addSubview:controls];
    [NSLayoutConstraint activateConstraints:@[[controls.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [controls.bottomAnchor constraintEqualToAnchor:card.topAnchor constant:-12], [controls.widthAnchor constraintEqualToConstant:64]]];
    __weak LGMapController *weakSelf = self;
    self.results.onChoose = ^(MKMapItem *item, MKCoordinateRegion region) {
        (void)item; LGMapController *owner = weakSelf; if (!owner) return;
        owner.finder.active = NO; owner.map.userTrackingMode = MKUserTrackingModeNone;
        [owner.map setRegion:region animated:YES];
        // Search changes ONLY the viewport. Never select a point or call the engine here.
    };
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(render) name:LGModelChanged object:self.model];
    [self render];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)willPresentSearchController:(UISearchController *)searchController { (void)searchController; self.results.searchRegion = self.map.region; }
- (void)didDismissSearchController:(UISearchController *)searchController { (void)searchController; [self.results cancelSearch]; }
- (void)render {
    NSDictionary *state = self.model.snapshot; BOOL on = [state[@"active_request"] boolValue];
    self.toggle.on = on; self.toggleState.text = on ? @"ON" : @"OFF";
    self.toggle.enabled = ![state[@"stopping"] boolValue] && (on || [state[@"can_activate"] boolValue] || [state[@"needs_cleanup"] boolValue]);
    self.tap.enabled = [self.model canSelect]; self.coordinates.text = LGCoordinates(self.model.selected);
    self.status.text = self.model.issue ?: (on ? @"Fixed location requested" : @"Selected location · tap the map to change it");
    if ([state[@"storage_error"] length]) self.status.text = state[@"storage_error"];
    self.toggle.accessibilityHint = [state[@"storage_error"] length] ? state[@"storage_error"] : nil;
    if (!CLLocationCoordinate2DIsValid(self.pin.coordinate) || self.pin.coordinate.latitude != self.model.selected.latitude
        || self.pin.coordinate.longitude != self.model.selected.longitude) self.pin.coordinate = self.model.selected;
    self.pin.subtitle = LGCoordinates(self.model.selected);
    NSString *recovery = [self.model recoveryText]; self.recovery.text = recovery; self.recovery.hidden = !recovery.length;
    BOOL showReceived = self.model.wantsReadings && [self.model hasPermission];
    if (self.map.showsUserLocation != showReceived) self.map.showsUserLocation = showReceived;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger style = [defaults integerForKey:@"map_style"];
    if (style != self.appliedStyle) {
        self.appliedStyle = style;
        if (style == 1) self.map.preferredConfiguration = [[MKHybridMapConfiguration alloc] init];
        else if (style == 2) self.map.preferredConfiguration = [[MKImageryMapConfiguration alloc] init];
        else self.map.preferredConfiguration = [[MKStandardMapConfiguration alloc] init];
    }
    self.map.showsScale = ![defaults boolForKey:@"hide_map_scale"]; self.map.showsCompass = ![defaults boolForKey:@"hide_map_compass"];
    if (self.centerWhenReady && LGRecent(self.model.lastLocation)) {
        self.centerWhenReady = NO; CLLocation *location = self.model.lastLocation;
        double extent = MIN(20000000, MAX(700, location.horizontalAccuracy * 4));
        [self.map setRegion:MKCoordinateRegionMakeWithDistance(location.coordinate, extent, extent) animated:YES];
    }
}
- (void)toggleChanged {
    if (self.toggle.on && ![self.model.snapshot[@"needs_cleanup"] boolValue]) [self.model activateTimed:NO];
    else [self.model stop];
    [self render];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    (void)gesture; CGPoint point = [touch locationInView:self.map];
    if (point.y > self.map.bounds.size.height - 40) return NO;
    for (UIView *v = touch.view; v && v != self.map; v = v.superview)
        if ([v isKindOfClass:UIControl.class] || [v isKindOfClass:MKAnnotationView.class]) return NO;
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)other {
    return gesture == self.tap && [other isKindOfClass:UITapGestureRecognizer.class] && ((UITapGestureRecognizer *)other).numberOfTapsRequired > 1;
}
- (void)mapTapped:(UITapGestureRecognizer *)tap {
    if (![self.model canSelect]) return;
    CLLocationCoordinate2D point = [self.map convertPoint:[tap locationInView:self.map] toCoordinateFromView:self.map];
    if (CLLocationCoordinate2DIsValid(point)) [self.model selectLatitude:[NSString stringWithFormat:@"%.7f", point.latitude]
        longitude:[NSString stringWithFormat:@"%.7f", point.longitude]];
}
- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
    if ([annotation isKindOfClass:MKUserLocation.class]) return nil;
    MKMarkerAnnotationView *view = (MKMarkerAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:@"chosen"];
    if (!view) view = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:@"chosen"];
    view.annotation = annotation; view.markerTintColor = UIColor.systemOrangeColor; view.glyphImage = [UIImage systemImageNamed:@"mappin"];
    view.canShowCallout = YES; view.displayPriority = MKFeatureDisplayPriorityRequired; return view;
}
- (void)showSelectedPoint {
    [self loadViewIfNeeded]; [self.map setRegion:MKCoordinateRegionMakeWithDistance(self.model.selected, 2000, 2000) animated:YES];
    [self.map selectAnnotation:self.pin animated:YES];
}
- (void)centerReceived { self.centerWhenReady = YES; [self.model requestReadings]; [self render]; }
- (void)editCoordinates {
    if (![self.model canSelect]) { LGAlert(self, @"Session in progress", @"Switch OFF before selecting another location."); return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select coordinates" message:@"This selects a location. It does not activate simulation." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Latitude"; field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        field.text = [NSString stringWithFormat:@"%.7f", self.model.selected.latitude]; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Longitude"; field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        field.text = [NSString stringWithFormat:@"%.7f", self.model.selected.longitude]; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Select" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; if ([self.model selectLatitude:alert.textFields[0].text longitude:alert.textFields[1].text]) [self showSelectedPoint];
    }]]; [self presentViewController:alert animated:YES completion:nil];
}
@end
