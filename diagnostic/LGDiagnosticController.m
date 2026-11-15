// SPDX-License-Identifier: GPL-3.0-only
#import "LGDiagnosticController.h"
#import "LGUI.h"
@interface LGDiagnosticController ()
@property(nonatomic, strong) LGAppModel *model;
@property(nonatomic, strong) UILabel *state, *chosen, *sent, *reference, *received, *clipboardNotice;
@property(nonatomic, strong) UIButton *test, *stop, *saveReference, *referenceCopyButton, *receivedCopyButton, *sentCopyButton, *share;
@end
@implementation LGDiagnosticController
- (instancetype)initWithModel:(LGAppModel *)model {
    if ((self = [super init])) { _model = model; self.title = @"Diagnostics";
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Diagnostics" image:[UIImage systemImageNamed:@"stethoscope"] tag:1]; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.state = LGLabel(@"", UIFontTextStyleBody); self.chosen = LGLabel(@"", UIFontTextStyleBody);
    self.sent = LGLabel(@"", UIFontTextStyleBody); self.reference = LGLabel(@"", UIFontTextStyleBody);
    self.received = LGLabel(@"", UIFontTextStyleBody); self.clipboardNotice = LGLabel(@"", UIFontTextStyleFootnote);
    self.clipboardNotice.textColor = UIColor.secondaryLabelColor;
    self.test = LGButton(@"30-second test", self, @selector(testTapped));
    self.stop = LGButton(@"Request stop", self, @selector(stopTapped)); self.stop.tintColor = UIColor.systemRedColor;
    self.saveReference = LGButton(@"Save as real location reference", self, @selector(saveReferenceTapped));
    self.referenceCopyButton = LGButton(@"Copy reference", self, @selector(copyReferenceTapped));
    self.receivedCopyButton = LGButton(@"Copy received location", self, @selector(copyReceivedTapped));
    self.sentCopyButton = LGButton(@"Copy sent location", self, @selector(copySentTapped));
    self.share = LGButton(@"Share diagnostics", self, @selector(shareTapped:));
    UIStackView *content = LGStack(@[
        LGCard(@[LGLabel(@"Status and tests", UIFontTextStyleHeadline), self.state, self.test, self.stop,
            LGLabel(@"The timed test is separate from continuous mode. It may end early if iOS interrupts execution.", UIFontTextStyleFootnote)]),
        LGCard(@[LGLabel(@"Selected fake location", UIFontTextStyleHeadline), self.chosen,
            LGButton(@"Copy selected location", self, @selector(copyChosenTapped))]),
        LGCard(@[LGLabel(@"Last location sent to the engine", UIFontTextStyleHeadline), self.sent, self.sentCopyButton]),
        LGCard(@[LGLabel(@"Real location reference", UIFontTextStyleHeadline), self.reference,
            LGLabel(@"While OFF, check that the reading matches your real position before saving it. While ON, this is a historical reference, not live real GPS.", UIFontTextStyleFootnote),
            self.saveReference, self.referenceCopyButton]),
        LGCard(@[LGLabel(@"Location received from iOS", UIFontTextStyleHeadline), self.received,
            LGButton(@"Read location", self, @selector(readTapped)), self.receivedCopyButton,
            LGLabel(@"This reading may be simulated. Accuracy and sourceInformation alone do not establish its physical origin.", UIFontTextStyleFootnote)]),
        self.clipboardNotice,
        LGCard(@[LGButton(@"Inspect engine", self, @selector(inspectTapped)), self.share,
            LGLabel(@"Logs stay on this iPhone. Sharing them includes the recorded coordinates.", UIFontTextStyleFootnote)])]);
    (void)LGScroll(self, content);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(render) name:LGModelChanged object:self.model]; [self render];
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; if ([self.model hasPermission]) [self.model requestReadings]; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)render {
    NSString *recovery = [self.model recoveryText];
    self.state.text = recovery.length ? [[self.model statusText] stringByAppendingFormat:@"\n%@", recovery] : [self.model statusText];
    self.chosen.text = LGCoordinates(self.model.selected);
    NSDictionary *sent = self.model.snapshot[@"selected"];
    BOOL hasSent = [sent isKindOfClass:NSDictionary.class]; self.sentCopyButton.enabled = hasSent;
    self.sent.text = hasSent ? LGCoordinates(CLLocationCoordinate2DMake([sent[@"latitude"] doubleValue], [sent[@"longitude"] doubleValue])) : @"No location has been sent during this run.";
    CLLocation *reference = self.model.realReference;
    if (reference) {
        NSDateFormatter *format = [NSDateFormatter new]; format.dateStyle = NSDateFormatterShortStyle; format.timeStyle = NSDateFormatterMediumStyle;
        self.reference.text = [NSString stringWithFormat:@"%@\n%@ · %@\nSaved accuracy: ±%.1f m",
            LGCoordinates(reference.coordinate), self.model.referenceConfirmed ? @"Confirmed by you" : @"Unconfirmed reference from before ON",
            [format stringFromDate:reference.timestamp], reference.horizontalAccuracy];
    } else self.reference.text = @"No saved reference. Read your location while OFF.";
    self.received.text = [self.model readingText];
    if (self.model.lastLocation.sourceInformation) self.received.text = [self.received.text stringByAppendingFormat:@"\nMarked as simulated: %@",
        self.model.lastLocation.sourceInformation.isSimulatedBySoftware ? @"yes" : @"no"];
    self.saveReference.enabled = [self.model canSaveReference]; self.referenceCopyButton.enabled = reference != nil;
    self.receivedCopyButton.enabled = self.model.lastLocation && CLLocationCoordinate2DIsValid(self.model.lastLocation.coordinate);
    self.test.enabled = [self.model.snapshot[@"can_activate"] boolValue]; self.stop.enabled = ![self.model.snapshot[@"stopping"] boolValue];
    self.share.enabled = ![self.model.snapshot[@"needs_execution"] boolValue];
}
- (void)copyPoint:(CLLocationCoordinate2D)point {
    if (!CLLocationCoordinate2DIsValid(point)) return;
    UIPasteboard.generalPasteboard.string = LGCoordinates(point); self.clipboardNotice.text = @"Coordinates copied to the clipboard.";
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, self.clipboardNotice.text);
}
- (void)copyChosenTapped { [self copyPoint:self.model.selected]; }
- (void)copyReceivedTapped { if (self.model.lastLocation) [self copyPoint:self.model.lastLocation.coordinate]; }
- (void)copyReferenceTapped { if (self.model.realReference) [self copyPoint:self.model.realReference.coordinate]; }
- (void)copySentTapped {
    NSDictionary *sent = self.model.snapshot[@"selected"]; if ([sent isKindOfClass:NSDictionary.class])
        [self copyPoint:CLLocationCoordinate2DMake([sent[@"latitude"] doubleValue], [sent[@"longitude"] doubleValue])];
}
- (void)saveReferenceTapped { [self.model saveRealReference]; }
- (void)readTapped { [self.model requestReadings]; }
- (void)testTapped { [self.model activateTimed:YES]; }
- (void)stopTapped { [self.model stop]; }
- (void)inspectTapped {
    NSMutableDictionary *inspection = [ILLInspectSimulationAPI() mutableCopy];
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSString *directory = [[documents URLByAppendingPathComponent:@"Diagnostics"] path];
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    inspection[@"app_version"] = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    inspection[@"startup_safe_mode"] = @([environment[@"_SafeMode"] isEqual:@"1"] || [environment[@"_MSSafeMode"] isEqual:@"1"]);
    inspection[@"storage_directory_exists"] = @([NSFileManager.defaultManager fileExistsAtPath:directory]);
    inspection[@"storage_directory_writable"] = @([NSFileManager.defaultManager isWritableFileAtPath:directory]);
    inspection[@"storage_error"] = self.model.snapshot[@"storage_error"] ?: @"";
    inspection[@"can_activate"] = self.model.snapshot[@"can_activate"] ?: @NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:inspection options:NSJSONWritingPrettyPrinted error:nil];
    LGAlert(self, @"Engine inspection", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
}
- (void)shareTapped:(UIButton *)sender {
    [self.model.session exportLogWithCompletion:^(NSURL *file) {
        if (!file) { LGAlert(self, @"Diagnostics", @"Could not prepare the file."); return; }
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
        share.popoverPresentationController.sourceView = sender; share.popoverPresentationController.sourceRect = sender.bounds;
        [self presentViewController:share animated:YES completion:nil];
    }];
}
@end
