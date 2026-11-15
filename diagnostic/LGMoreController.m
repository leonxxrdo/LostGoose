// SPDX-License-Identifier: GPL-3.0-only
#import "LGMoreController.h"
#import "LGUI.h"
static NSString *ProjectValue(NSString *key) {
    NSDictionary *branding = [NSDictionary dictionaryWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"Branding" ofType:@"plist"]];
    return branding[key] ?: @"";
}
@interface LGSettingsController : UITableViewController
@property(nonatomic, strong) LGAppModel *model;
@end
@implementation LGSettingsController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Settings"; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section == 0 ? 3 : 2; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; return @[@"Map style", @"Map controls"][section];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView; UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (path.section == 0) {
        cell.textLabel.text = @[@"Standard", @"Hybrid", @"Satellite"][path.row];
        if ([NSUserDefaults.standardUserDefaults integerForKey:@"map_style"] == path.row) cell.accessoryType = UITableViewCellAccessoryCheckmark;
    } else {
        cell.textLabel.text = path.row == 0 ? @"Show compass" : @"Show scale";
        UISwitch *toggle = [UISwitch new]; toggle.tag = path.row;
        toggle.on = ![NSUserDefaults.standardUserDefaults boolForKey:path.row == 0 ? @"hide_map_compass" : @"hide_map_scale"];
        [toggle addTarget:self action:@selector(controlChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.textLabel.numberOfLines = 0; return cell;
}
- (void)controlChanged:(UISwitch *)sender {
    [NSUserDefaults.standardUserDefaults setBool:!sender.on forKey:sender.tag == 0 ? @"hide_map_compass" : @"hide_map_scale"]; [self.model notify];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 0) {
        [NSUserDefaults.standardUserDefaults setInteger:path.row forKey:@"map_style"]; [self.model notify]; [tableView reloadData];
    }
}
@end
@interface LGMoreController ()
@property(nonatomic, strong) LGAppModel *model;
@property(nonatomic) BOOL linkCopied;
@end
@implementation LGMoreController
- (instancetype)initWithModel:(LGAppModel *)model {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _model = model; self.title = @"More";
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"More" image:[UIImage systemImageNamed:@"ellipsis.circle.fill"] tag:2]; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 184)];
    UIImageView *image = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"AppIcon60"]];
    image.contentMode = UIViewContentModeScaleAspectFit; image.clipsToBounds = YES; image.layer.cornerRadius = 16;
    [image.widthAnchor constraintEqualToConstant:72].active = YES; [image.heightAnchor constraintEqualToConstant:72].active = YES;
    UILabel *name = LGLabel(@"LostGoose", UIFontTextStyleTitle2); name.textAlignment = NSTextAlignmentCenter;
    UILabel *description = LGLabel(@"Fixed location for iOS", UIFontTextStyleFootnote); description.textColor = UIColor.secondaryLabelColor;
    UIStackView *stack = LGStack(@[image, name, description]); stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO; [header addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [stack.topAnchor constraintEqualToAnchor:header.topAnchor constant:16],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:header.widthAnchor constant:-32]]]; self.tableView.tableHeaderView = header;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section == 0 ? 5 : 2; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; return @[@"About", @"Help and preferences", @"Project"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? (self.linkCopied ? @"GitHub repository link copied to the clipboard." : @"Share copies the GitHub repository link to your clipboard.") : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView; UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (path.section == 0) {
        cell.textLabel.text = @[@"Version", @"Website", @"GitHub", @"Support email", @"Share"][path.row];
        if (path.row == 0) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@)",
                [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"], [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (path.row < 4) {
            cell.detailTextLabel.text = ProjectValue(@[@"", @"website_url", @"github_url", @"support_email"][path.row]);
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.textColor = self.view.tintColor;
            cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
            cell.detailTextLabel.text = self.linkCopied ? @"Copied" : @"Copy the GitHub repository link";
            cell.accessibilityHint = @"Copies the GitHub URL to the clipboard";
        }
    } else if (path.section == 1) {
        cell.textLabel.text = path.row == 0 ? @"Instructions" : @"Settings"; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.textLabel.text = path.row == 0 ? @"Open source" : @"Privacy";
        cell.detailTextLabel.text = path.row == 0 ? @"GPL-3.0-only" : nil; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0; return cell;
}
- (void)showText:(NSString *)text title:(NSString *)title {
    UIViewController *page = [UIViewController new]; page.title = title; page.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    (void)LGScroll(page, LGStack(@[LGCard(@[LGLabel(text, UIFontTextStyleBody)])]));
    [self.navigationController pushViewController:page animated:YES];
}
- (void)openLink:(NSURL *)url {
    if (!url) return;
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
        if (!success) LGAlert(self, @"Could not open link", @"Check the link or configure an app that can open it.");
    }];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 0) {
        if (path.row == 1) [self openLink:[NSURL URLWithString:ProjectValue(@"website_url")]];
        else if (path.row == 2) [self openLink:[NSURL URLWithString:ProjectValue(@"github_url")]];
        else if (path.row == 3) {
            NSURLComponents *url = [NSURLComponents new]; url.scheme = @"mailto"; url.path = ProjectValue(@"support_email"); [self openLink:url.URL];
        } else if (path.row == 4) {
            UIPasteboard.generalPasteboard.string = ProjectValue(@"github_url"); self.linkCopied = YES;
            [tableView reloadData];
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"GitHub repository link copied to the clipboard.");
        }
        return;
    }
    if (path.section == 1 && path.row == 1) { LGSettingsController *settings = [LGSettingsController new]; settings.model = self.model;
        [self.navigationController pushViewController:settings animated:YES]; return; }
    if (path.section == 1) {
        [self showText:@"1. Search for a city to move the map. Searching does not select a location or activate simulation.\n\n2. Tap the map or enter coordinates to select a destination. The orange pin marks your selection.\n\n3. Turn ON at the top right. Switching tabs does not stop the session.\n\n4. Turn OFF to request a stop, then check the location received.\n\nDiagnostics lets you read and copy coordinates, save a real location reference, and run a separate 30-second test. A saved reference is historical, not live real GPS while ON.\n\nTurn OFF before closing the app. If a session is interrupted, reopen LostGoose to request cleanup and check fresh readings. Force-quitting does not guarantee automatic or immediate restoration." title:@"Instructions"];
    } else if (path.row == 0) [self showText:@"LostGoose is open source under GPL-3.0-only. Source code is available from the GitHub link in More and the corresponding source archive in the Sileo repository. Apple frameworks and maps retain their own terms." title:@"Open source"];
    else [self showText:@"There are no accounts or app-owned backend services. Logs and references stay on this iPhone. Sharing diagnostics includes recorded coordinates.\n\nPlace search and maps use Apple services. Copy actions write to the system clipboard. Share in More copies only the repository URL. The real location reference stays in memory for the current run. The selected destination is remembered for the next launch without activating it." title:@"Privacy"];
}
@end
