#import "VCCRootViewController.h"
#import <notify.h>

// Must match VCamCore.m in the tweak.
static NSString *const kConfigPlist = @"/var/mobile/Media/DCIM/vcam_msd.plist";
static NSString *const kStatsFile   = @"/var/mobile/Media/DCIM/vcam_msd_stats.txt";
static NSString *const kScanDir     = @"/var/mobile/Media/DCIM";

static NSString *const kNoteEnable  = @"com.vcamplus.msd.enable";
static NSString *const kNoteDisable = @"com.vcamplus.msd.disable";
static NSString *const kNoteToggle  = @"com.vcamplus.msd.toggle";
static NSString *const kNoteReload  = @"com.vcamplus.msd.reload";

@interface VCCRootViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UILabel *statusLabel;
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

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"clip"];
    self.tableView.tableHeaderView = [self buildHeader];
    [self.view addSubview:self.tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

#pragma mark - Header (status + action buttons)

- (UIView *)buildHeader {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 150)];

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

    [header addSubview:self.statusLabel];
    [header addSubview:buttons];

    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.topAnchor constraintEqualToAnchor:header.topAnchor constant:12],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],

        [buttons.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:14],
        [buttons.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [buttons.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [buttons.heightAnchor constraintEqualToConstant:46],
        [buttons.bottomAnchor constraintLessThanOrEqualToAnchor:header.bottomAnchor constant:-12],
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

- (void)selectClip:(NSString *)path {
    NSDictionary *cfg = @{ @"source": path };
    NSError *err = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:cfg
                                                             format:NSPropertyListXMLFormat_v1_0
                                                            options:0 error:&err];
    if (!data || ![data writeToFile:kConfigPlist atomically:YES]) {
        [self alert:@"Could not write config"
            message:[NSString stringWithFormat:@"%@\n\nPath: %@\n\nThe app must be unsandboxed "
                      "(platform-application) to write here.", err.localizedDescription ?: @"write failed", kConfigPlist]];
        return;
    }
    self.currentSource = path;
    notify_post(kNoteReload.UTF8String);
    [self flash:[NSString stringWithFormat:@"Source → %@", path.lastPathComponent]];
    [self.tableView reloadData];
}

#pragma mark - Refresh / status

- (void)refresh {
    // Current source from the shared plist.
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kConfigPlist];
    self.currentSource = [cfg[@"source"] isKindOfClass:NSString.class] ? cfg[@"source"] : nil;

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
    NSString *player  = [self valueFor:@"playerStarted=" in:stats] ?: @"?";
    NSString *src     = self.currentSource.lastPathComponent ?: @"(none)";
    BOOL statsSeen    = stats.length > 0;

    self.statusLabel.text = [NSString stringWithFormat:
        @"tweak stats: %@\nenabled=%@  playerStarted=%@\nsource: %@",
        statsSeen ? @"present" : @"not found (open Camera once)",
        enabled, player, src];
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
