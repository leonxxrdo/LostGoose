// SPDX-License-Identifier: GPL-3.0-only
// Independent observer: public Core Location only; no engine or private API.
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#include <mach-o/dyld.h>
#include <math.h>

static id NumberOrNull(double value) {
    return isfinite(value) ? @(value) : NSNull.null;
}

static NSArray<NSString *> *RelatedImages(void) {
    NSMutableArray *images = [NSMutableArray array];
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path) continue;
        NSString *name = [NSString stringWithUTF8String:path].lastPathComponent;
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"gpsmaster"] || [lower containsString:@"ellekit"]
            || [lower containsString:@"substrate"] || [lower containsString:@"choicy"])
            [images addObject:name];
    }
    return images;
}

@interface WitnessController : UIViewController <CLLocationManagerDelegate>
@property(nonatomic, strong) CLLocationManager *manager;
@property(nonatomic, strong) UITextView *display;
@property(nonatomic, strong) NSURL *logURL;
@property(nonatomic) BOOL samplingRequested;
@property(nonatomic) BOOL updatesRunning;
@property(nonatomic, strong) CLLocation *lastLocation;
@property(nonatomic, strong) NSTimer *displayTimer;
@property(nonatomic, copy) NSString *lastLocationNotice;
- (void)pauseSampling;
@end

@implementation WitnessController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.display = [UITextView new];
    self.display.editable = NO;
    self.display.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    self.display.text = @"Testigo independiente\n\nNo modifica la ubicación.\n\nDesactiva la inyección de tweaks para esta app antes de iniciar. Las lecturas se guardan solo en este dispositivo.";
    UIButton *start = [UIButton buttonWithType:UIButtonTypeSystem];
    [start setTitle:@"Iniciar lecturas" forState:UIControlStateNormal];
    [start addTarget:self action:@selector(startSampling) forControlEvents:UIControlEventTouchUpInside];
    UIButton *stop = [UIButton buttonWithType:UIButtonTypeSystem];
    [stop setTitle:@"Detener lecturas" forState:UIControlStateNormal];
    [stop addTarget:self action:@selector(pauseSampling) forControlEvents:UIControlEventTouchUpInside];
    UIButton *share = [UIButton buttonWithType:UIButtonTypeSystem];
    [share setTitle:@"Compartir registro" forState:UIControlStateNormal];
    [share addTarget:self action:@selector(shareLog:) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[start, stop, share]];
    buttons.axis = UILayoutConstraintAxisVertical;
    buttons.spacing = 8;
    UIStackView *layout = [[UIStackView alloc] initWithArrangedSubviews:@[self.display, buttons]];
    layout.axis = UILayoutConstraintAxisVertical;
    layout.spacing = 12;
    layout.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:layout];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [layout.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [layout.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [layout.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [layout.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16]
    ]];
    self.manager = [CLLocationManager new];
    self.manager.delegate = self;
    self.manager.desiredAccuracy = kCLLocationAccuracyBest;
    self.manager.distanceFilter = kCLDistanceFilterNone;
    __weak WitnessController *weakSelf = self;
    self.displayTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        WitnessController *controller = weakSelf;
        if (controller.samplingRequested && controller.lastLocation) [controller renderReading];
    }];
}
- (void)dealloc { [_displayTimer invalidate]; }
- (void)renderReading {
    CLLocation *location = self.lastLocation;
    if (!location || !self.samplingRequested) return;
    // Recompute from the fix timestamp, not the age saved when the callback arrived.
    double age = -location.timestamp.timeIntervalSinceNow;
    BOOL fresh = CLLocationCoordinate2DIsValid(location.coordinate)
        && isfinite(location.horizontalAccuracy) && location.horizontalAccuracy >= 0
        && isfinite(age) && age >= -1 && age <= 5;
    NSDateFormatter *format = [NSDateFormatter new]; format.dateFormat = @"HH:mm:ss.SSS";
    CLLocationSourceInformation *source = location.sourceInformation;
    self.display.text = [NSString stringWithFormat:
        @"Witness 0.1.1 · %@\n\nLatitud: %.7f\nLongitud: %.7f\n\nLectura: %@\nAntigüedad actual: %.2f s\nPrecisión: ±%.1f m\n\nsourceInformation.simulated: %@\n\n%@\nEste dato por sí solo no certifica el origen real de la lectura.",
        fresh ? @"LECTURA RECIENTE" : @"LECTURA ANTIGUA O INVÁLIDA",
        location.coordinate.latitude, location.coordinate.longitude,
        [format stringFromDate:location.timestamp], age, location.horizontalAccuracy,
        source ? (source.isSimulatedBySoftware ? @"sí" : @"no") : @"sin información",
        self.lastLocationNotice ?: @""];
}
- (BOOL)record:(NSDictionary *)entry {
    if (!self.logURL) {
        NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
            inDomains:NSUserDomainMask].firstObject;
        self.logURL = [documents URLByAppendingPathComponent:
            [NSString stringWithFormat:@"witness-%@.jsonl", NSUUID.UUID.UUIDString]];
        if (![NSFileManager.defaultManager createFileAtPath:self.logURL.path contents:nil attributes:nil]) {
            self.logURL = nil;
            self.display.text = @"No se pudo crear el registro local. Lecturas detenidas.";
            return NO;
        }
    }
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:entry options:NSJSONWritingSortedKeys error:&error];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:self.logURL error:&error];
    if (!data || !handle) {
        self.display.text = @"No se pudo guardar el registro local. Lecturas detenidas.";
        return NO;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (NSException *exception) {
        (void)exception;
        [handle closeFile];
        self.display.text = @"Error al escribir el registro. Lecturas detenidas.";
        return NO;
    }
    return YES;
}
- (void)startSampling {
    NSArray *images = RelatedImages();
    for (NSString *image in images) {
        if ([image.lowercaseString containsString:@"gpsmaster"]) {
            self.display.text = @"GPS Master está cargado en esta app.\n\nNo se iniciarán lecturas. Desactiva la inyección para Location Witness y vuelve a abrirla.";
            return;
        }
    }
    if (self.samplingRequested && self.updatesRunning) {
        [self renderReading];
        return; // Repeated Iniciar neither restarts Core Location nor hides the last fix.
    }
    if (![self record:@{@"event": @"sampling_requested", @"received_unix": @(NSDate.date.timeIntervalSince1970),
                       @"related_images": images, @"image_scan_exhaustive": @NO,
                       @"app_version": @"0.1.1", @"engine_linked": @NO}]) return;
    self.samplingRequested = YES;
    self.lastLocation = nil;
    if (self.manager.authorizationStatus == kCLAuthorizationStatusNotDetermined) {
        self.display.text = @"Permite la ubicación al usar la app y activa Ubicación precisa.";
        [self.manager requestWhenInUseAuthorization];
    } else [self updateAuthorization];
}
- (void)updateAuthorization {
    if (!self.samplingRequested) return;
    CLAuthorizationStatus status = self.manager.authorizationStatus;
    if (status == kCLAuthorizationStatusAuthorizedWhenInUse || status == kCLAuthorizationStatusAuthorizedAlways) {
        if (self.updatesRunning) { [self renderReading]; return; }
        self.display.text = @"Esperando lecturas nuevas…";
        self.updatesRunning = YES;
        [self.manager startUpdatingLocation];
    } else if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) {
        self.display.text = @"Sin permiso de ubicación. Puedes revisarlo en Ajustes → Privacidad y seguridad → Localización.";
        self.samplingRequested = NO;
        self.updatesRunning = NO;
        [self.manager stopUpdatingLocation];
    }
}
- (void)pauseSampling {
    if (!self.samplingRequested) return;
    self.samplingRequested = NO;
    self.updatesRunning = NO;
    [self.manager stopUpdatingLocation];
    [self record:@{@"event": @"sampling_stopped", @"received_unix": @(NSDate.date.timeIntervalSince1970)}];
    self.display.text = [@"LECTURAS DETENIDAS\n\n" stringByAppendingString:self.display.text ?: @""];
}
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    (void)manager;
    [self updateAuthorization];
}
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (!self.samplingRequested) return;
    for (CLLocation *location in locations) {
        NSDate *received = NSDate.date;
        double age = [received timeIntervalSinceDate:location.timestamp];
        BOOL fresh = CLLocationCoordinate2DIsValid(location.coordinate)
            && isfinite(location.horizontalAccuracy) && location.horizontalAccuracy >= 0
            && isfinite(age) && age >= -1 && age <= 5;
        CLLocationSourceInformation *source = location.sourceInformation;
        NSDictionary *entry = @{
            @"event": @"location", @"latitude": NumberOrNull(location.coordinate.latitude),
            @"longitude": NumberOrNull(location.coordinate.longitude),
            @"timestamp_unix": NumberOrNull(location.timestamp.timeIntervalSince1970),
            @"received_unix": NumberOrNull(received.timeIntervalSince1970),
            @"age_seconds": NumberOrNull(age), @"fresh": @(fresh),
            @"horizontal_accuracy_m": NumberOrNull(location.horizontalAccuracy),
            @"vertical_accuracy_m": NumberOrNull(location.verticalAccuracy),
            @"altitude_m": NumberOrNull(location.altitude),
            @"accuracy_authorization": @(manager.accuracyAuthorization),
            @"source_information": source ? @{
                @"simulated_by_software": @(source.isSimulatedBySoftware),
                @"produced_by_accessory": @(source.isProducedByAccessory)} : (id)NSNull.null
        };
        if (![self record:entry]) {
            self.samplingRequested = NO;
            self.updatesRunning = NO;
            [self.manager stopUpdatingLocation];
            return;
        }
        self.lastLocation = location;
    }
    [self renderReading];
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    (void)manager;
    [self record:@{@"event": @"error", @"domain": error.domain, @"code": @(error.code),
                  @"received_unix": @(NSDate.date.timeIntervalSince1970)}];
    self.display.text = [NSString stringWithFormat:@"Error de localización: %@ (%ld)", error.domain, (long)error.code];
    self.lastLocationNotice = [NSString stringWithFormat:@"Último aviso: %@ (%ld)", error.domain, (long)error.code];
    if ([error.domain isEqual:kCLErrorDomain] && error.code == kCLErrorDenied) {
        self.samplingRequested = NO; self.updatesRunning = NO;
        [self.manager stopUpdatingLocation];
    }
}
- (void)shareLog:(UIButton *)sender {
    if (!self.logURL) return;
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[self.logURL] applicationActivities:nil];
    share.popoverPresentationController.sourceView = sender;
    share.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:share animated:YES completion:nil];
}
@end

@interface WitnessAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) WitnessController *controller;
@end
@implementation WitnessAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.controller = [WitnessController new];
    self.window.rootViewController = self.controller;
    [self.window makeKeyAndVisible];
    return YES;
}
- (void)applicationDidEnterBackground:(UIApplication *)application {
    (void)application;
    [self.controller pauseSampling];
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(WitnessAppDelegate.class));
    }
}
