#import "VCCRootViewController.h"
#import "VCCAppDelegate.h"
#import "VCCRec.h"
#import <notify.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <PhotosUI/PhotosUI.h>
#import <Photos/Photos.h>
#import <UserNotifications/UserNotifications.h>

// Recorder output (must match VCamRecorder.m in the tweak).
static NSString *const kRecDir        = @"/var/mobile/Media/DCIM/VCamRec";
static NSString *const kImportedPlist = @"/var/mobile/Media/DCIM/VCamRec/vcam_imported.plist";

// Must match VCamCore.m in the tweak.
static NSString *const kConfigPlist = @"/var/mobile/Media/DCIM/vcam_msd.plist";
static NSString *const kStatsFile   = @"/var/mobile/Media/DCIM/vcam_msd_stats.txt";
static NSString *const kScanDir     = @"/var/mobile/Media/DCIM";

static NSString *const kNoteEnable  = @"com.vcamplus.msd.enable";
static NSString *const kNoteDisable = @"com.vcamplus.msd.disable";
static NSString *const kNoteToggle  = @"com.vcamplus.msd.toggle";
static NSString *const kNoteReload  = @"com.vcamplus.msd.reload";

// NDI daemon stats (milestone 1): read-only status surfaced in the header.
static NSString *const kNDIStatsFile = @"/var/mobile/Media/DCIM/vcam_ndi_stats.txt";

@interface VCCRootViewController () <UITableViewDataSource, UITableViewDelegate,
                                     UIDocumentPickerDelegate, PHPickerViewControllerDelegate>
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UISegmentedControl *modeControl;
@property (nonatomic, strong) UIButton *recordButton;
@property (nonatomic, strong) UIButton *targetButton;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSString *> *clips;   // absolute paths
@property (nonatomic, copy)   NSString *currentSource;      // from kConfigPlist
@end

@implementation VCCRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"VCam Control";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(refresh)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Rotate 0°" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(tapRotate)];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"clip"];
    self.tableView.tableHeaderView = [self buildHeader];
    [self.view addSubview:self.tableView];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(recStateChanged)
                                               name:kRecStateDidChange object:nil];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)recStateChanged { [self updateRecordButton]; [self refreshStatusSoon]; }

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
    [self importRecordings:NO];   // silently pull any new clips into the camera roll
}

#pragma mark - Header (status + action buttons)

- (UIView *)buildHeader {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 480)];

    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"File clip", @"NDI stream"]];
    self.modeControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.modeControl addTarget:self action:@selector(modeChanged:)
               forControlEvents:UIControlEventValueChanged];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *on  = [self actionButton:@"Enable"  sel:@selector(tapEnable)  color:UIColor.systemGreenColor];
    UIButton *off = [self actionButton:@"Disable" sel:@selector(tapDisable) color:UIColor.systemRedColor];
    UIButton *tog = [self actionButton:@"Toggle"  sel:@selector(tapToggle)  color:UIColor.systemGrayColor];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[on, off, tog]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.distribution = UIStackViewDistributionFillEqually;
    buttons.spacing = 10;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *pick = [self actionButton:@"Select File…" sel:@selector(tapSelectFile)
                                  color:UIColor.systemBlueColor];
    pick.translatesAutoresizingMaskIntoConstraints = NO;

    // Recorder row: a direct Record/Stop toggle, plus a button that posts the interactive
    // notification so recording can be controlled from the lock screen / Notification Center.
    self.recordButton = [self actionButton:@"● Record" sel:@selector(tapRecord)
                                     color:UIColor.systemRedColor];
    UIButton *importBtn = [self actionButton:@"Import to Photos" sel:@selector(tapImportPhotos)
                                       color:UIColor.systemIndigoColor];
    UIStackView *recRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.recordButton, importBtn]];
    recRow.axis = UILayoutConstraintAxisHorizontal;
    recRow.distribution = UIStackViewDistributionFillEqually;
    recRow.spacing = 10;
    recRow.translatesAutoresizingMaskIntoConstraints = NO;

    // Which pipeline geometry to record (parsed from the tweak's geometry report). Auto = largest.
    self.targetButton = [self actionButton:@"Rec res: Auto (largest)" sel:@selector(tapChooseTarget)
                                      color:UIColor.systemTealColor];
    self.targetButton.translatesAutoresizingMaskIntoConstraints = NO;

    [header addSubview:self.modeControl];
    [header addSubview:self.statusLabel];
    [header addSubview:buttons];
    [header addSubview:pick];
    [header addSubview:recRow];
    [header addSubview:self.targetButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.modeControl.topAnchor constraintEqualToAnchor:header.topAnchor constant:12],
        [self.modeControl.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [self.modeControl.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],

        [self.statusLabel.topAnchor constraintEqualToAnchor:self.modeControl.bottomAnchor constant:12],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],

        [buttons.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:14],
        [buttons.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [buttons.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [buttons.heightAnchor constraintEqualToConstant:46],

        [pick.topAnchor constraintEqualToAnchor:buttons.bottomAnchor constant:10],
        [pick.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [pick.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [pick.heightAnchor constraintEqualToConstant:46],

        [recRow.topAnchor constraintEqualToAnchor:pick.bottomAnchor constant:10],
        [recRow.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [recRow.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [recRow.heightAnchor constraintEqualToConstant:46],

        [self.targetButton.topAnchor constraintEqualToAnchor:recRow.bottomAnchor constant:10],
        [self.targetButton.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [self.targetButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [self.targetButton.heightAnchor constraintEqualToConstant:46],
        [self.targetButton.bottomAnchor constraintLessThanOrEqualToAnchor:header.bottomAnchor constant:-12],
    ]];
    return header;
}

- (UIButton *)actionButton:(NSString *)title sel:(SEL)sel color:(UIColor *)color {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    b.backgroundColor = color;
    b.layer.cornerRadius = 10;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - Actions

- (void)tapEnable  { notify_post(kNoteEnable.UTF8String);  [self flash:@"Enabled"];  [self refreshStatusSoon]; }
- (void)tapDisable { notify_post(kNoteDisable.UTF8String); [self flash:@"Disabled"]; [self refreshStatusSoon]; }
- (void)tapToggle  { notify_post(kNoteToggle.UTF8String);  [self flash:@"Toggled"];  [self refreshStatusSoon]; }

// Record / Stop. Reads the current tweak state so the button maps to an explicit start or stop.
- (void)tapRecord {
    BOOL recording = VCCRecIsRecording();
    notify_post((recording ? kNoteRecStop : kNoteRecStart).UTF8String);
    [self flash:recording ? @"Recording stopped" : @"Recording…"];
    // Keep the lock-screen control in sync with the new intent.
    [VCCAppDelegate presentRecordingNotificationRecording:!recording];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self updateRecordButton]; });
    [self refreshStatusSoon];
}

- (void)tapImportPhotos { [self importRecordings:YES]; }

#pragma mark - Camera-roll import

- (NSMutableSet<NSString *> *)importedSet {
    NSArray *a = [NSArray arrayWithContentsOfFile:kImportedPlist];
    return a ? [NSMutableSet setWithArray:a] : [NSMutableSet set];
}

- (NSArray<NSString *> *)recordingFilenames {
    NSMutableArray *movs = [NSMutableArray array];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:kRecDir error:nil])
        if ([f.pathExtension.lowercaseString isEqualToString:@"mov"]) [movs addObject:f];
    [movs sortUsingSelector:@selector(localizedStandardCompare:)];
    return movs;
}

// Copy any not-yet-imported .mov clips from DCIM/VCamRec into the Photos camera roll, tracking
// imported filenames so each is added once. `announce` shows UI feedback; silent on auto-runs.
- (void)importRecordings:(BOOL)announce {
    NSMutableSet<NSString *> *imported = [self importedSet];
    NSMutableArray<NSString *> *toImport = [NSMutableArray array];
    for (NSString *f in [self recordingFilenames])
        if (![imported containsObject:f]) [toImport addObject:f];
    if (toImport.count == 0) { if (announce) [self flash:@"No new recordings"]; return; }

    void (^doImport)(void) = ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            for (NSString *f in toImport) {
                NSURL *u = [NSURL fileURLWithPath:[kRecDir stringByAppendingPathComponent:f]];
                [PHAssetCreationRequest creationRequestForAssetFromVideoAtFileURL:u];
            }
        } completionHandler:^(BOOL ok, NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ok) {
                    [imported addObjectsFromArray:toImport];
                    [imported.allObjects writeToFile:kImportedPlist atomically:YES];
                    if (announce) [self flash:[NSString stringWithFormat:@"Imported %lu to camera roll",
                                               (unsigned long)toImport.count]];
                } else if (announce) {
                    [self alert:@"Import failed" message:e.localizedDescription ?: @"Photos refused the add"];
                }
                [self updateStatusLabel];
            });
        }];
    };

    PHAuthorizationStatus st = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    if (st == PHAuthorizationStatusAuthorized) { doImport(); return; }
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
                                               handler:^(PHAuthorizationStatus s2) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (s2 == PHAuthorizationStatusAuthorized) doImport();
            else if (announce) [self alert:@"Photos access needed"
                                   message:@"Allow adding to Photos in Settings → VCam Control → Photos."];
        });
    }];
}

- (void)updateRecordButton {
    BOOL recording = VCCRecIsRecording();
    [self.recordButton setTitle:recording ? @"■ Stop" : @"● Record" forState:UIControlStateNormal];
    self.recordButton.backgroundColor = recording ? UIColor.systemGrayColor : UIColor.systemRedColor;
}

#pragma mark - Record resolution target

// Read the chosen record geometry from the plist; returns a short label ("Auto (largest)" or
// "1920x1080 420v").
- (NSString *)currentTargetLabel {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kConfigPlist];
    long w = [cfg[@"recW"] longValue], h = [cfg[@"recH"] longValue];
    NSString *fmt = [cfg[@"recFmt"] isKindOfClass:NSString.class] ? cfg[@"recFmt"] : nil;
    if (w > 0 && h > 0 && fmt.length == 4) return [NSString stringWithFormat:@"%ldx%ld %@", w, h, fmt];
    return @"Auto (largest)";
}

- (void)updateTargetButton {
    [self.targetButton setTitle:[NSString stringWithFormat:@"Rec res: %@", [self currentTargetLabel]]
                       forState:UIControlStateNormal];
}

// Parse the "--- dst geometries seen ---" lines from the tweak stats into {w,h,fmt,emits}.
- (NSArray<NSDictionary *> *)parseGeometries {
    NSString *stats = [NSString stringWithContentsOfFile:kStatsFile encoding:NSUTF8StringEncoding error:nil];
    if (!stats.length) return @[];
    NSError *e = nil;
    NSRegularExpression *re =
        [NSRegularExpression regularExpressionWithPattern:@"(\\d+)x(\\d+) '([^']+)': emits=(\\d+)"
                                                  options:0 error:&e];
    NSMutableArray *out = [NSMutableArray array];
    [re enumerateMatchesInString:stats options:0 range:NSMakeRange(0, stats.length)
                      usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
        if (m.numberOfRanges < 5) return;
        NSInteger w = [[stats substringWithRange:[m rangeAtIndex:1]] integerValue];
        NSInteger h = [[stats substringWithRange:[m rangeAtIndex:2]] integerValue];
        NSString *fmt = [stats substringWithRange:[m rangeAtIndex:3]];
        NSInteger emits = [[stats substringWithRange:[m rangeAtIndex:4]] integerValue];
        if (fmt.length == 4) [out addObject:@{@"w":@(w), @"h":@(h), @"fmt":fmt, @"emits":@(emits)}];
    }];
    // Busiest feed first — most-emitted is the most useful default to eyeball.
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"emits"] compare:a[@"emits"]];
    }];
    return out;
}

- (void)tapChooseTarget {
    NSArray<NSDictionary *> *geoms = [self parseGeometries];
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"Record which feed?"
                                            message:(geoms.count ? @"Pipeline geometries seen this session (open the Camera first if empty)."
                                                                 : @"No geometries reported yet — open the Camera, then try again.")
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Auto (largest feed)"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self setTargetW:0 h:0 fmt:@""]; }]];
    for (NSDictionary *g in geoms) {
        NSString *title = [NSString stringWithFormat:@"%@x%@ %@  (emits=%@)",
                           g[@"w"], g[@"h"], g[@"fmt"], g[@"emits"]];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            [self setTargetW:[g[@"w"] longValue] h:[g[@"h"] longValue] fmt:g[@"fmt"]];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.targetButton;
    sheet.popoverPresentationController.sourceRect = self.targetButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// Writes recW/recH/recFmt (0/empty = auto). The recorder reads these on the next Record.
- (void)setTargetW:(long)w h:(long)h fmt:(NSString *)fmt {
    if (![self writeConfigMerging:@{ @"recW": @(w), @"recH": @(h), @"recFmt": fmt ?: @"" }]) return;
    [self updateTargetButton];
    [self flash:(w > 0 ? [NSString stringWithFormat:@"Rec res → %ldx%ld %@", w, h, fmt] : @"Rec res → Auto")];
}

// Offer both sources: Photos (AirDropped / camera-roll clips live here, invisible to the
// Files picker) and Files (iCloud Drive / On My iPhone / other providers).
- (void)tapSelectFile {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Select source clip"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Photos Library" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self openPhotosPicker]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Files…" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self openFilesPicker]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    // iPhone-only target, but anchor the popover anyway so it never asserts.
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)openFilesPicker {
    NSArray<UTType *> *types = @[ UTTypeMovie, UTTypeQuickTimeMovie, UTTypeMPEG4Movie, UTTypeVideo ];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)openPhotosPicker {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = [PHPickerFilter videosFilter];
    cfg.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark Files picker

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *src = urls.firstObject;
    if (!src) return;
    NSError *err = nil;
    NSString *dest = [self importClipAtURL:src suggestedName:nil error:&err];
    if (dest) { [self selectClip:dest]; [self refresh]; }
    else [self alert:@"Could not import file" message:err.localizedDescription ?: @"copy failed"];
}

#pragma mark Photos picker

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSItemProvider *ip = results.firstObject.itemProvider;
    if (!ip) return;

    NSString *typeId = UTTypeMovie.identifier;
    if (![ip hasItemConformingToTypeIdentifier:typeId]) typeId = UTTypeMPEG4Movie.identifier;
    NSString *suggested = ip.suggestedName;

    // The provided URL is a temp copy valid only for the duration of this handler, so copy
    // it into DCIM synchronously here before returning, then update UI on the main thread.
    [ip loadFileRepresentationForTypeIdentifier:typeId
                              completionHandler:^(NSURL *url, NSError *loadErr) {
        if (!url) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self alert:@"Could not load from Photos"
                    message:loadErr.localizedDescription ?: @"no file representation"];
            });
            return;
        }
        NSError *copyErr = nil;
        NSString *ext = url.pathExtension.length ? url.pathExtension : @"mov";
        NSString *name = suggested.length ? [suggested stringByAppendingPathExtension:ext]
                                          : url.lastPathComponent;
        NSString *dest = [self importClipAtURL:url suggestedName:name error:&copyErr];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (dest) { [self selectClip:dest]; [self refresh]; }
            else [self alert:@"Could not import from Photos"
                     message:copyErr.localizedDescription ?: @"copy failed"];
        });
    }];
}

#pragma mark Shared import

// Copies src into DCIM (daemon-readable), overwriting a same-named existing import.
// Returns the destination path, or nil (with *err set) on failure.
- (NSString *)importClipAtURL:(NSURL *)src suggestedName:(NSString *)name error:(NSError **)err {
    NSString *base = name.length ? name.lastPathComponent : src.lastPathComponent;
    if (!base.length) base = @"vcam_import.mov";
    NSString *dest = [kScanDir stringByAppendingPathComponent:base];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:dest error:nil];
    if (![fm copyItemAtURL:src toURL:[NSURL fileURLWithPath:dest] error:err]) return nil;
    return dest;
}

// Merge keys into vcam_msd.plist (preserving e.g. "mode" when setting "source" and vice
// versa). Returns NO (with an alert) if the write fails.
- (BOOL)writeConfigMerging:(NSDictionary *)updates {
    NSMutableDictionary *cfg =
        [[NSDictionary dictionaryWithContentsOfFile:kConfigPlist] mutableCopy] ?: [NSMutableDictionary dictionary];
    [cfg addEntriesFromDictionary:updates];
    NSError *err = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:cfg
                                                             format:NSPropertyListXMLFormat_v1_0
                                                            options:0 error:&err];
    if (!data || ![data writeToFile:kConfigPlist atomically:YES]) {
        [self alert:@"Could not write config"
            message:[NSString stringWithFormat:@"%@\n\nPath: %@\n\nThe app must be unsandboxed "
                      "(platform-application) to write here.", err.localizedDescription ?: @"write failed", kConfigPlist]];
        return NO;
    }
    return YES;
}

- (void)selectClip:(NSString *)path {
    if (![self writeConfigMerging:@{ @"source": path }]) return;
    self.currentSource = path;
    notify_post(kNoteReload.UTF8String);
    [self flash:[NSString stringWithFormat:@"Source → %@", path.lastPathComponent]];
    [self.tableView reloadData];
}

// Cycle rotation 0 → 90 → 180 → 270 → 0, write it, and reload the tweak.
- (void)tapRotate {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kConfigPlist];
    NSInteger deg = (([cfg[@"rotation"] integerValue] / 90 + 1) % 4) * 90;
    if (![self writeConfigMerging:@{ @"rotation": @(deg) }]) return;
    self.navigationItem.leftBarButtonItem.title = [NSString stringWithFormat:@"Rotate %ld°", (long)deg];
    notify_post(kNoteReload.UTF8String);
    [self flash:[NSString stringWithFormat:@"Rotation → %ld°", (long)deg]];
}

// File clip (0) vs NDI stream (1). Writes "mode" and reloads the tweak.
- (void)modeChanged:(UISegmentedControl *)sender {
    BOOL ndi = (sender.selectedSegmentIndex == 1);
    if (![self writeConfigMerging:@{ @"mode": ndi ? @"ndi" : @"file" }]) return;
    notify_post(kNoteReload.UTF8String);
    [self flash:ndi ? @"Mode → NDI stream" : @"Mode → File clip"];
}

#pragma mark - Refresh / status

- (void)refresh {
    // Current source + mode from the shared plist.
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kConfigPlist];
    self.currentSource = [cfg[@"source"] isKindOfClass:NSString.class] ? cfg[@"source"] : nil;
    BOOL ndi = [[cfg[@"mode"] description] caseInsensitiveCompare:@"ndi"] == NSOrderedSame;
    self.modeControl.selectedSegmentIndex = ndi ? 1 : 0;
    self.navigationItem.leftBarButtonItem.title =
        [NSString stringWithFormat:@"Rotate %ld°", (long)([cfg[@"rotation"] integerValue])];

    // Scan for candidate clips.
    NSMutableArray *found = [NSMutableArray array];
    NSArray *exts = @[@"mp4", @"mov", @"m4v"];
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:kScanDir error:nil];
    for (NSString *name in [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        if ([exts containsObject:name.pathExtension.lowercaseString])
            [found addObject:[kScanDir stringByAppendingPathComponent:name]];
    }
    // Make sure a current source outside the scan dir still shows up.
    if (self.currentSource.length && ![found containsObject:self.currentSource])
        [found insertObject:self.currentSource atIndex:0];
    self.clips = found;

    [self updateRecordButton];
    [self updateTargetButton];
    [self updateStatusLabel];
    [self.tableView reloadData];
}

- (void)refreshStatusSoon {
    // Stats file is rewritten every 5s by the tweak; re-read shortly after an action.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self updateStatusLabel]; });
}

- (void)updateStatusLabel {
    NSString *stats = [NSString stringWithContentsOfFile:kStatsFile encoding:NSUTF8StringEncoding error:nil];
    NSString *enabled = [self valueFor:@"enabled=" in:stats] ?: @"?";
    NSString *src     = self.currentSource.lastPathComponent ?: @"(none)";
    BOOL statsSeen    = stats.length > 0;

    // NDI daemon status (milestone 1): state=, frame=, fps= from its stats file.
    NSString *ndi = [NSString stringWithContentsOfFile:kNDIStatsFile encoding:NSUTF8StringEncoding error:nil];
    NSString *ndiLine;
    if (ndi.length) {
        NSString *fps = [self valueFor:@"publishFps=" in:ndi] ?: [self valueFor:@"fps=" in:ndi] ?: @"?";
        ndiLine = [NSString stringWithFormat:@"NDI: %@ %@ %@fps",
                   [self valueFor:@"state=" in:ndi] ?: @"?",
                   [self valueFor:@"frame=" in:ndi] ?: @"",
                   fps];
        NSString *drop = [self valueFor:@"droppedThisSec=" in:ndi];
        if (drop) {  // milestone-2 diagnostics present
            ndiLine = [ndiLine stringByAppendingFormat:@"\n  drop/s=%@ q=%@ gap=%@ms %@",
                       drop,
                       [self valueFor:@"queueDepth=" in:ndi] ?: @"?",
                       [self valueFor:@"maxArrivalGapMs=" in:ndi] ?: @"?",
                       [self valueFor:@"thermalState=" in:ndi] ?: @""];
        }
    } else {
        ndiLine = @"NDI: daemon not running";
    }

    NSString *emit  = [self valueFor:@"emitFps=" in:stats];
    NSString *fresh = [self valueFor:@"freshFps=" in:stats];
    NSString *rateLine = (emit || fresh)
        ? [NSString stringWithFormat:@"\nemitFps=%@ freshFps=%@ (real update rate)", emit ?: @"?", fresh ?: @"?"]
        : @"";

    // Recorder line from the tweak's dedicated status file: state + the detail line under it.
    NSString *recRaw = [NSString stringWithContentsOfFile:kRecStatusFile
                                                 encoding:NSUTF8StringEncoding error:nil];
    NSString *recLine = @"rec: idle";
    if (recRaw.length) {
        NSString *recState = [self valueFor:@"state=" in:recRaw] ?: @"?";
        NSArray *lines = [recRaw componentsSeparatedByString:@"\n"];
        NSString *detail = lines.count > 1 ? lines[1] : @"";
        recLine = detail.length ? [NSString stringWithFormat:@"rec: %@ — %@", recState, detail]
                                : [NSString stringWithFormat:@"rec: %@", recState];
    }

    NSUInteger total = [self recordingFilenames].count;
    NSUInteger done = 0;
    NSMutableSet *imp = [self importedSet];
    for (NSString *f in [self recordingFilenames]) if ([imp containsObject:f]) done++;
    NSString *recFiles = [NSString stringWithFormat:@"recordings: %lu  (%lu in camera roll)",
                          (unsigned long)total, (unsigned long)done];

    self.statusLabel.text = [NSString stringWithFormat:
        @"tweak: %@  enabled=%@  mode=%@%@\nsource: %@\n%@\n%@\n%@",
        statsSeen ? @"present" : @"not found (open Camera once)",
        enabled, [self valueFor:@"mode=" in:stats] ?: @"?", rateLine, src, ndiLine, recLine, recFiles];
}

// Pulls the token immediately after `key` up to whitespace from the stats text.
- (NSString *)valueFor:(NSString *)key in:(NSString *)text {
    if (!text) return nil;
    NSRange r = [text rangeOfString:key];
    if (r.location == NSNotFound) return nil;
    NSString *rest = [text substringFromIndex:NSMaxRange(r)];
    NSRange ws = [rest rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return ws.location == NSNotFound ? rest : [rest substringToIndex:ws.location];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return self.clips.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    return self.clips.count ? @"Source clip (tap to select)" : @"No .mp4/.mov/.m4v found in DCIM";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"clip" forIndexPath:ip];
    NSString *path = self.clips[ip.row];
    cell.textLabel.text = path.lastPathComponent;
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    cell.accessoryType = [path isEqualToString:self.currentSource]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    [self selectClip:self.clips[ip.row]];
}

#pragma mark - UI helpers

- (void)flash:(NSString *)msg {
    self.title = msg;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ self.title = @"VCam Control"; });
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
