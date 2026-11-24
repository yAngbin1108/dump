//
//  ADXJobViewController.m
//  App 扩展层 — 砸壳进度页（进度条 + 实时日志 + 取消 / 分享）
//
#import "ADXJobViewController.h"
#import "ADXFairPlayJob.h"
#import "ADXInternal.h"

@interface ADXJobViewController ()
@property (nonatomic, strong) ADXApp *app;
@property (nonatomic, assign) BOOL relax;
@property (nonatomic, strong) ADXFairPlayJob *job;
@property (nonatomic, strong) UIProgressView *bar;
@property (nonatomic, strong) UILabel *stageLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong, nullable) NSString *resultPath;
@property (nonatomic, assign) BOOL started;
@end

@implementation ADXJobViewController

- (instancetype)initWithApp:(ADXApp *)app relaxInstallRestrictions:(BOOL)relax {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _app = app;
        _relax = relax;
        self.title = app.name;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.bar.translatesAutoresizingMaskIntoConstraints = NO;

    self.stageLabel = [[UILabel alloc] init];
    self.stageLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.stageLabel.textColor = UIColor.secondaryLabelColor;
    self.stageLabel.text = @"准备中…";
    self.stageLabel.numberOfLines = 2;
    self.stageLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.logView = [[UITextView alloc] init];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.logView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.logView.layer.cornerRadius = 10;
    self.logView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    self.logView.text = @"";

    [self.view addSubview:self.bar];
    [self.view addSubview:self.stageLabel];
    [self.view addSubview:self.logView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.bar.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [self.bar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.bar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.stageLabel.topAnchor constraintEqualToAnchor:self.bar.bottomAnchor constant:8],
        [self.stageLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.stageLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.logView.topAnchor constraintEqualToAnchor:self.stageLabel.bottomAnchor constant:10],
        [self.logView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [self.logView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [self.logView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
    ]];

    UIBarButtonItem *cancel = [[UIBarButtonItem alloc] initWithTitle:@"取消"
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:@selector(cancelTapped)];
    self.navigationItem.rightBarButtonItem = cancel;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.started) {
        self.started = YES;
        [self startJob];
    }
}

- (void)appendLog:(NSString *)line {
    NSString *current = self.logView.text ?: @"";
    NSString *next = current.length ? [current stringByAppendingFormat:@"\n%@", line] : line;
    self.logView.text = next;
    if (next.length) {
        [self.logView scrollRangeToVisible:NSMakeRange(next.length - 1, 1)];
    }
}

- (void)startJob {
    ADXFairPlayJob *job = [ADXFairPlayJob new];
    job.appName = self.app.name;
    job.bundlePath = self.app.bundlePath;
    job.relaxInstallRestrictions = self.relax;

    __weak typeof(self) weakSelf = self;
    job.log = ^(NSString *line) { [weakSelf appendLog:line]; };
    job.progress = ^(double f, NSString *stage, NSString *detail) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.bar.progress = f;
        NSString *text = detail.length
            ? [NSString stringWithFormat:@"%@ · %@", stage, detail]
            : stage;
        strongSelf.stageLabel.text = [NSString stringWithFormat:@"%@  (%.0f%%)", text, f * 100.0];
    };
    job.completion = ^(NSString *ipaPath, NSString *error, NSString *summary) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.navigationItem.rightBarButtonItem = nil;
        if (ipaPath.length) {
            strongSelf.resultPath = ipaPath;
            strongSelf.stageLabel.text = @"完成";
            strongSelf.bar.progress = 1.0;
            UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                                   target:strongSelf
                                                                                   action:@selector(shareTapped)];
            strongSelf.navigationItem.rightBarButtonItem = share;
        } else {
            strongSelf.stageLabel.text = error.length ? error : @"失败";
            strongSelf.stageLabel.textColor = UIColor.systemRedColor;
        }
    };

    self.job = job;
    [job start];
}

- (void)cancelTapped {
    [self.job cancel];
    [self.navigationItem.rightBarButtonItem setEnabled:NO];
}

- (void)shareTapped {
    if (!self.resultPath.length) return;
    NSURL *url = [NSURL fileURLWithPath:self.resultPath];
    UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[ url ]
                                                                     applicationActivities:nil];
    vc.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:vc animated:YES completion:nil];
}

@end