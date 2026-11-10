#import "SNRootViewController.h"
#import "SNProbe.h"

#pragma mark - padded pill label (tier badge)

@interface SNPill : UILabel
@end
@implementation SNPill
- (CGSize)intrinsicContentSize {
    CGSize s = [super intrinsicContentSize];
    return CGSizeMake(s.width + 14, s.height + 6);
}
- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(3, 7, 3, 7))];
}
@end

#pragma mark - cell

@interface SNCell : UITableViewCell
@property (nonatomic, strong) UILabel *keyLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UILabel *noteLabel;
@property (nonatomic, strong) SNPill  *pill;
- (void)configureWithRow:(NSDictionary *)row;
@end

@implementation SNCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
        self.selectionStyle = UITableViewCellSelectionStyleDefault;

        _keyLabel = [UILabel new];
        _keyLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        _keyLabel.textColor = UIColor.secondaryLabelColor;
        _keyLabel.numberOfLines = 0;

        _pill = [SNPill new];
        _pill.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
        _pill.textColor = UIColor.whiteColor;
        _pill.textAlignment = NSTextAlignmentCenter;
        _pill.layer.cornerRadius = 8;
        _pill.layer.masksToBounds = YES;
        [_pill setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_pill setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        _valueLabel = [UILabel new];
        _valueLabel.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
        _valueLabel.textColor = UIColor.labelColor;
        _valueLabel.numberOfLines = 0;

        _noteLabel = [UILabel new];
        _noteLabel.font = [UIFont systemFontOfSize:11];
        _noteLabel.textColor = UIColor.tertiaryLabelColor;
        _noteLabel.numberOfLines = 0;

        for (UIView *v in @[_keyLabel, _pill, _valueLabel, _noteLabel]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:v];
        }
        UILayoutGuide *g = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [_keyLabel.topAnchor constraintEqualToAnchor:g.topAnchor],
            [_keyLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
            [_pill.leadingAnchor constraintGreaterThanOrEqualToAnchor:_keyLabel.trailingAnchor constant:8],
            [_pill.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
            [_pill.centerYAnchor constraintEqualToAnchor:_keyLabel.centerYAnchor],

            [_valueLabel.topAnchor constraintEqualToAnchor:_keyLabel.bottomAnchor constant:3],
            [_valueLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
            [_valueLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],

            [_noteLabel.topAnchor constraintEqualToAnchor:_valueLabel.bottomAnchor constant:3],
            [_noteLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
            [_noteLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
            [_noteLabel.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
        ]];
    }
    return self;
}

- (void)configureWithRow:(NSDictionary *)row {
    _keyLabel.text = row[@"k"];
    _valueLabel.text = row[@"v"];
    NSString *note = row[@"note"];
    _noteLabel.text = note;
    _noteLabel.hidden = (note.length == 0);

    SNTier tier = [row[@"tier"] integerValue];
    switch (tier) {
        case SNTierPublic:
            _pill.text = @"SANDBOX OK"; _pill.backgroundColor = UIColor.systemGreenColor; break;
        case SNTierPublicRandomized:
            _pill.text = @"RANDOMIZED"; _pill.backgroundColor = UIColor.systemOrangeColor; break;
        case SNTierRoot:
            _pill.text = @"ROOT ONLY"; _pill.backgroundColor = UIColor.systemRedColor; break;
        case SNTierInfo:
        default:
            _pill.text = @"INFO"; _pill.backgroundColor = UIColor.systemGrayColor; break;
    }
}

@end

#pragma mark - view controller

@interface SNRootViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSDictionary *> *sections;
@end

@implementation SNRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SIM Probe";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(reload)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                      target:self action:@selector(copyAll)];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 72;
    [_tableView registerClass:SNCell.class forCellReuseIdentifier:@"cell"];
    _tableView.tableHeaderView = [self makeHeader];
    [self.view addSubview:_tableView];

    [self reload];
}

- (UIView *)makeHeader {
    UILabel *l = [UILabel new];
    l.numberOfLines = 0;
    l.font = [UIFont systemFontOfSize:12.5];
    l.textColor = UIColor.secondaryLabelColor;
    NSString *t =
        @"What a normal SANDBOXED App Store app can see of your SIM / mobile network, on this device.\n\n"
        @"🟢 SANDBOX OK — any app gets the real value.\n"
        @"🟠 RANDOMIZED — any app can call it, but iOS 16 returns a fixed placeholder to EVERYONE "
        @"(including root). Hidden at the API level, not by the sandbox.\n"
        @"🔴 ROOT ONLY — a sandboxed app is blocked. Shown here only because this build runs "
        @"unsandboxed on your jailbreak. The real identifiers live here.\n"
        @"⚪️ INFO — context / a device setting, not a SIM value.\n\n"
        @"Tap any row to copy its value.";
    l.text = t;

    UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 0)];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [wrap addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.topAnchor constraintEqualToAnchor:wrap.topAnchor constant:4],
        [l.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:20],
        [l.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor constant:-20],
        [l.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor constant:-8],
    ]];
    CGFloat w = self.view.bounds.size.width;
    CGSize fit = [wrap systemLayoutSizeFittingSize:CGSizeMake(w, 0)
                     withHorizontalFittingPriority:UILayoutPriorityRequired
                           verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    wrap.frame = CGRectMake(0, 0, w, fit.height);
    return wrap;
}

- (void)reload {
    self.sections = [SNProbe collectSections];
    [self.tableView reloadData];
}

- (void)copyAll {
    UIPasteboard.generalPasteboard.string = [SNProbe plainTextDump:self.sections];
    [self flash:@"Copied full report"];
}

- (void)flash:(NSString *)msg {
    NSString *old = self.title;
    self.title = msg;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ self.title = old; });
}

#pragma mark table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return self.sections.count; }

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return [self.sections[s][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return self.sections[s][@"title"];
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    SNCell *cell = [t dequeueReusableCellWithIdentifier:@"cell" forIndexPath:ip];
    [cell configureWithRow:self.sections[ip.section][@"rows"][ip.row]];
    return cell;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *row = self.sections[ip.section][@"rows"][ip.row];
    UIPasteboard.generalPasteboard.string = row[@"v"];
    [self flash:@"Copied ✓"];
}

@end
