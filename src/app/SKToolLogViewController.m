//
//  SKToolLogViewController.m
//  AppDump — 见 SKToolLogViewController.h
//

#import "SKToolLogViewController.h"

@interface SKToolLogViewController ()
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSMutableString *buffer;
@property (nonatomic, copy) NSString *taskTitle;
@end

@implementation SKToolLogViewController

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _taskTitle = [title copy];
        _buffer = [NSMutableString string];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = self.taskTitle ?: @"执行中";

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(closeTapped)];
    self.navigationItem.rightBarButtonItem.enabled = NO;

    _statusLabel = [UILabel new];
    _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    _statusLabel.numberOfLines = 0;
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_statusLabel];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.hidesWhenStopped = YES;
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_spinner];

    _textView = [UITextView new];
    _textView.editable = NO;
    _textView.alwaysBounceVertical = YES;
    _textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _textView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    _textView.layer.cornerRadius = 10;
    _textView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_textView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_spinner.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_spinner.centerYAnchor constraintEqualToAnchor:_statusLabel.centerYAnchor],
        [_spinner.widthAnchor constraintEqualToConstant:20],

        [_statusLabel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:_spinner.trailingAnchor constant:10],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [_textView.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:10],
        [_textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [_textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [_textView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
    ]];

    [_spinner startAnimating];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // 已经积累的行（可能在 viewDidLoad 之前就到了）一次性填进去
    [self flush];
}

- (void)closeTapped {
    if (self.navigationController && self.navigationController.viewControllers.firstObject == self) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

#pragma mark - 输出

- (void)appendLine:(NSString *)line {
    if (line.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.buffer appendString:line];
        if (![line hasSuffix:@"\n"]) [self.buffer appendString:@"\n"];
        if (self.isViewLoaded && self.view.window) [self flush];
    });
}

- (void)flush {
    if (!self.textView) return;
    self.textView.text = self.buffer;
    if (self.buffer.length) {
        NSRange end = NSMakeRange(self.buffer.length, 0);
        [self.textView scrollRangeToVisible:end];
    }
}

- (void)setStatusText:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = text;
    });
}

- (void)finishWithSuccess:(BOOL)success message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.spinner stopAnimating];
        self.statusLabel.text = message ?: (success ? @"完成" : @"失败");
        self.statusLabel.textColor = success ? UIColor.systemGreenColor : UIColor.systemRedColor;
        self.navigationItem.rightBarButtonItem.enabled = YES;
        if (message.length) {
            [self.buffer appendString:[NSString stringWithFormat:@"\n── %@ ──\n", message]];
            [self flush];
        }
    });
}

@end
