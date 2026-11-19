#import "MDImportButton.h"
#import "MDDownloadManager.h"
#import "MDImporter.h"
#import "MDLog.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>

static MDImportButton *sharedButton;

static UIWindow *MDKeyWindow(void) {
	UIApplication *application = [UIApplication sharedApplication];

	if (@available(iOS 13.0, *)) {
		UIWindow *fallback = nil;
		for (UIScene *scene in application.connectedScenes) {
			if (![scene isKindOfClass:[UIWindowScene class]]) {
				continue;
			}
			UIWindowScene *windowScene = (UIWindowScene *)scene;
			for (UIWindow *window in windowScene.windows) {
				if (window.isKeyWindow) {
					if (window.windowLevel == UIWindowLevelNormal) {
						return window;
					}
					if (!fallback) {
						fallback = window;
					}
				}
			}
		}
		if (fallback) {
			return fallback;
		}
		for (UIScene *scene in application.connectedScenes) {
			if (![scene isKindOfClass:[UIWindowScene class]]) {
				continue;
			}
			UIWindowScene *windowScene = (UIWindowScene *)scene;
			if (windowScene.activationState == UISceneActivationStateForegroundActive &&
				windowScene.windows.count > 0) {
				for (UIWindow *window in windowScene.windows) {
					if (window.windowLevel == UIWindowLevelNormal) {
						return window;
					}
				}
				return windowScene.windows.firstObject;
			}
		}
	}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	return application.keyWindow;
#pragma clang diagnostic pop
}

static UIViewController *MDTopViewController(void) {
	UIWindow *window = MDKeyWindow();
	UIViewController *controller = window.rootViewController;
	if (!controller) {
		return nil;
	}

	for (NSInteger depth = 0; depth < 8; depth++) {
		UIViewController *next = controller.presentedViewController;
		if (next) {
			controller = next;
			continue;
		}
		if ([controller isKindOfClass:[UINavigationController class]]) {
			UIViewController *visible = ((UINavigationController *)controller).visibleViewController;
			if (visible && visible != controller) {
				controller = visible;
				continue;
			}
		}
		if ([controller isKindOfClass:[UITabBarController class]]) {
			UIViewController *selected = ((UITabBarController *)controller).selectedViewController;
			if (selected && selected != controller) {
				controller = selected;
				continue;
			}
		}
		break;
	}
	return controller;
}

@interface MDProgressHUD : UIView
- (void)showInWindow:(UIWindow *)window text:(NSString *)text;
- (void)updateText:(NSString *)text;
- (void)hide;
@end

@implementation MDProgressHUD {
	UIVisualEffectView *_blurView;
	UIActivityIndicatorView *_spinner;
	UILabel *_label;
}

- (instancetype)initWithFrame:(CGRect)frame {
	(void)frame;
	self = [super initWithFrame:CGRectMake(0, 0, 210, 120)];
	if (self) {
		self.backgroundColor = [UIColor clearColor];
		self.userInteractionEnabled = NO;

		UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
		_blurView = [[UIVisualEffectView alloc] initWithEffect:effect];
		_blurView.frame = self.bounds;
		_blurView.layer.cornerRadius = 20;
		_blurView.layer.cornerCurve = kCACornerCurveContinuous;
		_blurView.clipsToBounds = YES;
		[self addSubview:_blurView];

		_spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
		_spinner.color = [UIColor whiteColor];
		_spinner.center = CGPointMake(CGRectGetMidX(self.bounds), 44);
		[self addSubview:_spinner];

		_label = [[UILabel alloc] initWithFrame:CGRectMake(12, 76, self.bounds.size.width - 24, 32)];
		_label.textColor = [UIColor whiteColor];
		_label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
		_label.textAlignment = NSTextAlignmentCenter;
		_label.numberOfLines = 2;
		[self addSubview:_label];
	}
	return self;
}

- (void)showInWindow:(UIWindow *)window text:(NSString *)text {
	if (!window) {
		return;
	}
	_label.text = text;
	if (self.superview != window) {
		[self removeFromSuperview];
		[window addSubview:self];
	}
	[window bringSubviewToFront:self];
	self.center = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds));
	[_spinner startAnimating];
	if (self.alpha < 1.0) {
		self.alpha = 0.0;
		[UIView animateWithDuration:0.2 animations:^{
			self.alpha = 1.0;
		}];
	}
}

- (void)updateText:(NSString *)text {
	_label.text = text;
}

- (void)hide {
	[UIView animateWithDuration:0.2 animations:^{
		self.alpha = 0.0;
	} completion:^(BOOL finished) {
		[self->_spinner stopAnimating];
		[self removeFromSuperview];
	}];
}

@end

@interface MDImportButton () <UIDocumentPickerDelegate>
@property (nonatomic, strong, nullable) UIDocumentPickerViewController *picker;
@property (nonatomic, strong) MDProgressHUD *hud;
@property (nonatomic, assign) BOOL importing;
@property (nonatomic, assign) BOOL downloading;
@property (nonatomic, assign) BOOL positionRestored;
- (void)layoutInWindow;
- (void)savePosition;
@end

@implementation MDImportButton

+ (void)installIfNeeded {
	if (![NSThread isMainThread]) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self installIfNeeded];
		});
		return;
	}

	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

		[center addObserverForName:UIApplicationDidBecomeActiveNotification
							object:nil
							 queue:[NSOperationQueue mainQueue]
						usingBlock:^(__unused NSNotification *note) {
			[MDImportButton installIfNeeded];
		}];

		[center addObserverForName:UIWindowDidBecomeKeyNotification
							object:nil
							 queue:[NSOperationQueue mainQueue]
						usingBlock:^(__unused NSNotification *note) {
			[MDImportButton installIfNeeded];
		}];

		[center addObserverForName:UIDeviceOrientationDidChangeNotification
							object:nil
							 queue:[NSOperationQueue mainQueue]
						usingBlock:^(__unused NSNotification *note) {
			[sharedButton layoutInWindow];
		}];
	});

	UIWindow *window = MDKeyWindow();
	if (!window) {
		static BOOL retryPending = NO;
		if (!retryPending) {
			retryPending = YES;
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
						   dispatch_get_main_queue(), ^{
				retryPending = NO;
				[MDImportButton installIfNeeded];
			});
		}
		return;
	}

	if (!sharedButton) {
		sharedButton = [[MDImportButton alloc] initWithFrame:CGRectZero];
	}
	if (sharedButton.superview != window) {
		[sharedButton removeFromSuperview];
		[window addSubview:sharedButton];
	}
	[sharedButton layoutInWindow];
	[window bringSubviewToFront:sharedButton];
}

- (instancetype)initWithFrame:(CGRect)frame {
	frame.size = CGSizeMake(56, 56);
	self = [super initWithFrame:frame];
	if (self) {
		self.backgroundColor = [UIColor colorWithRed:0.98 green:0.20 blue:0.35 alpha:1.0];
		self.tintColor = [UIColor whiteColor];
		self.layer.cornerRadius = 28;
		self.layer.cornerCurve = kCACornerCurveContinuous;
		self.layer.borderWidth = 0.5;
		self.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.25] CGColor];
		self.layer.shadowColor = [[UIColor blackColor] CGColor];
		self.layer.shadowOpacity = 0.30f;
		self.layer.shadowRadius = 12.0f;
		self.layer.shadowOffset = CGSizeMake(0, 6);

		UIImageSymbolConfiguration *configuration =
			[UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightSemibold];
		UIImage *icon = [UIImage systemImageNamed:@"music.note" withConfiguration:configuration];
		if (!icon) {
			icon = [UIImage systemImageNamed:@"plus" withConfiguration:configuration];
		}
		[self setImage:icon forState:UIControlStateNormal];
		self.imageView.contentMode = UIViewContentModeScaleAspectFit;

		self.accessibilityLabel = @"Add music";
		self.accessibilityHint = @"Import audio files or download from a URL";
		[self addTarget:self action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];

		UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(buttonPanned:)];
		[self addGestureRecognizer:pan];

		_hud = [[MDProgressHUD alloc] initWithFrame:CGRectZero];
	}
	return self;
}

- (CGPoint)clampedCenter:(CGPoint)center {
	UIWindow *window = self.window;
	if (!window) {
		return center;
	}
	CGRect bounds = window.bounds;
	UIEdgeInsets safe = window.safeAreaInsets;
	CGFloat radius = CGRectGetWidth(self.bounds) / 2.0;

	CGFloat minX = safe.left + radius + 8.0;
	CGFloat maxX = CGRectGetWidth(bounds) - safe.right - radius - 8.0;
	CGFloat minY = safe.top + radius + 8.0;
	CGFloat maxY = CGRectGetHeight(bounds) - safe.bottom - radius - 8.0;

	center.x = MIN(MAX(center.x, minX), MAX(minX, maxX));
	center.y = MIN(MAX(center.y, minY), MAX(minY, maxY));
	return center;
}

- (void)layoutInWindow {
	UIWindow *window = self.window ?: MDKeyWindow();
	if (!window) {
		return;
	}

	if (!self.positionRestored) {
		NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
		double savedX = [defaults doubleForKey:@"MusicDropButtonX"];
		double savedY = [defaults doubleForKey:@"MusicDropButtonY"];
		CGFloat width = CGRectGetWidth(window.bounds);
		CGFloat height = CGRectGetHeight(window.bounds);

		if (savedX > 0.0 && savedY > 0.0 && savedX <= 1.0 && savedY <= 1.0 && width > 0 && height > 0) {
			self.center = CGPointMake(savedX * width, savedY * height);
		} else {
			UIEdgeInsets safe = window.safeAreaInsets;
			CGFloat radius = CGRectGetWidth(self.bounds) / 2.0;
			self.center = CGPointMake(width - safe.right - radius - 16.0,
									  height - safe.bottom - 49.0 - radius - 18.0);
		}
		self.positionRestored = YES;
	}

	self.center = [self clampedCenter:self.center];
}

- (void)savePosition {
	UIWindow *window = self.window;
	if (!window || CGRectGetWidth(window.bounds) <= 0 || CGRectGetHeight(window.bounds) <= 0) {
		return;
	}
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	[defaults setDouble:self.center.x / CGRectGetWidth(window.bounds) forKey:@"MusicDropButtonX"];
	[defaults setDouble:self.center.y / CGRectGetHeight(window.bounds) forKey:@"MusicDropButtonY"];
}

- (void)buttonPanned:(UIPanGestureRecognizer *)gesture {
	if (!self.superview) {
		return;
	}

	if (gesture.state == UIGestureRecognizerStateChanged ||
		gesture.state == UIGestureRecognizerStateEnded) {
		CGPoint translation = [gesture translationInView:self.superview];
		CGPoint center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
		self.center = [self clampedCenter:center];
		[gesture setTranslation:CGPointZero inView:self.superview];

		if (gesture.state == UIGestureRecognizerStateEnded) {
			[self savePosition];
		}
	}
}

- (void)buttonTapped {
	if (self.importing || self.downloading) {
		return;
	}

	UIViewController *presenter = MDTopViewController();
	if (!presenter) {
		MDLog(@"No view controller available to present the source menu.");
		return;
	}

	UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Add Music"
														 message:nil
												  preferredStyle:UIAlertControllerStyleActionSheet];
	__weak MDImportButton *weakSelf = self;
	[menu addAction:[UIAlertAction actionWithTitle:@"Import Files"
										 style:UIAlertActionStyleDefault
									   handler:^(__unused UIAlertAction *action) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf showDocumentPicker];
		});
	}]];
	[menu addAction:[UIAlertAction actionWithTitle:@"Download URL"
										 style:UIAlertActionStyleDefault
									   handler:^(__unused UIAlertAction *action) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf showDownloadPrompt];
		});
	}]];
	[menu addAction:[UIAlertAction actionWithTitle:@"Cancel"
										 style:UIAlertActionStyleCancel
									   handler:nil]];

	UIPopoverPresentationController *popover = menu.popoverPresentationController;
	if (popover) {
		popover.sourceView = self;
		popover.sourceRect = self.bounds;
	}
	[presenter presentViewController:menu animated:YES completion:nil];
}

- (void)showDocumentPicker {
	if (self.importing || self.downloading) {
		return;
	}

	NSMutableOrderedSet<UTType *> *types = [NSMutableOrderedSet orderedSet];
	if (UTTypeAudio) {
		[types addObject:UTTypeAudio];
	}
	if (UTTypeMovie) {
		[types addObject:UTTypeMovie];
	}
	NSArray<NSString *> *extensions = @[
		@"mp3", @"m4a", @"m4r", @"m4b", @"aac", @"wav", @"aif", @"aiff", @"caf", @"flac",
		@"mp4", @"m4v", @"mov",
	];
	for (NSString *extension in extensions) {
		UTType *type = [UTType typeWithFilenameExtension:extension];
		if (type) {
			[types addObject:type];
		}
	}

	if (types.count == 0) {
		[self showMessage:@"This iOS version did not report any audio file types."];
		return;
	}

	UIDocumentPickerViewController *picker =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types.array
																  asCopy:YES];
	picker.delegate = self;
	picker.allowsMultipleSelection = YES;
	self.picker = picker;

	UIViewController *presenter = MDTopViewController();
	if (!presenter) {
		MDLog(@"No view controller available to present the document picker.");
		return;
	}
	self.hidden = YES;
	[presenter presentViewController:picker animated:YES completion:nil];
}

- (void)showDownloadPrompt {
	if (self.importing || self.downloading) {
		return;
	}

	UIViewController *presenter = MDTopViewController();
	if (!presenter) {
		MDLog(@"No view controller available to present the URL prompt.");
		return;
	}

	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Download Music"
		message:@"Paste a direct audio or YouTube HTTPS URL. Only download media you own or have permission to save. Spotify full tracks are not available for download."
		preferredStyle:UIAlertControllerStyleAlert];
	[alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
		textField.placeholder = @"https://…";
		textField.keyboardType = UIKeyboardTypeURL;
		textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
		textField.autocorrectionType = UITextAutocorrectionTypeNo;
		textField.clearButtonMode = UITextFieldViewModeWhileEditing;
	}];

	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
										  style:UIAlertActionStyleCancel
										handler:nil]];
	__weak UIAlertController *weakAlert = alert;
	__weak MDImportButton *weakSelf = self;
	[alert addAction:[UIAlertAction actionWithTitle:@"Download"
										  style:UIAlertActionStyleDefault
										handler:^(__unused UIAlertAction *action) {
		NSString *input = weakAlert.textFields.firstObject.text ?: @"";
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf beginDownloadURLString:input];
		});
	}]];
	[presenter presentViewController:alert animated:YES completion:nil];
}

- (void)beginDownloadURLString:(NSString *)input {
	if (self.importing || self.downloading) {
		return;
	}

	NSString *value = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (value.length == 0) {
		[self showMessage:@"Enter a direct audio or YouTube HTTPS URL."];
		return;
	}
	if ([value rangeOfString:@"://"].location == NSNotFound) {
		value = [@"https://" stringByAppendingString:value];
	}
	NSURL *url = [NSURL URLWithString:value];
	if (!url) {
		[self showMessage:@"That URL is not valid."];
		return;
	}

	self.downloading = YES;
	self.enabled = NO;
	self.alpha = 0.55;
	[self.hud showInWindow:MDKeyWindow() text:@"Checking URL…"];

	__weak MDImportButton *weakSelf = self;
	[[MDDownloadManager sharedManager] downloadURL:url
									 progress:^(NSString *status) {
		[weakSelf.hud updateText:status];
	} completion:^(NSURL *localFileURL, NSError *error) {
		MDImportButton *strongSelf = weakSelf;
		if (!strongSelf) {
			return;
		}

		strongSelf.downloading = NO;
		strongSelf.enabled = YES;
		strongSelf.alpha = 1.0;
		if (localFileURL && !error) {
			[strongSelf beginImport:@[localFileURL]];
		} else {
			[strongSelf.hud hide];
			[strongSelf showMessage:error.localizedDescription ?: @"The download failed."];
		}
	}];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
	didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
	[self.picker dismissViewControllerAnimated:YES completion:^{
		self.picker = nil;
		self.hidden = NO;
		if (urls.count > 0) {
			[self beginImport:urls];
		}
	}];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
	self.picker = nil;
	self.hidden = NO;
	[MDImportButton installIfNeeded];
}

- (void)beginImport:(NSArray<NSURL *> *)urls {
	if (self.importing || self.downloading || urls.count == 0) {
		return;
	}
	self.importing = YES;
	self.enabled = NO;
	self.alpha = 0.55;

	UIWindow *window = MDKeyWindow();
	[self.hud showInWindow:window text:@"Preparing import…"];

	__weak MDImportButton *weakSelf = self;
	[[MDImporter sharedImporter] importURLs:urls
								   progress:^(NSString *status) {
		[weakSelf.hud updateText:status];
	} completion:^(NSUInteger imported, NSArray<NSString *> *errors) {
		MDImportButton *strongSelf = weakSelf;
		if (!strongSelf) {
			return;
		}
		[strongSelf.hud hide];
		strongSelf.importing = NO;
		strongSelf.enabled = YES;
		strongSelf.alpha = 1.0;
		[MDImportButton installIfNeeded];
		[strongSelf showResultWithImported:imported errors:errors];
	}];
}

- (void)showResultWithImported:(NSUInteger)imported errors:(NSArray<NSString *> *)errors {
	NSString *message = nil;

	if (imported > 0) {
		NSString *items = imported == 1 ? @"item" : @"items";
		message = [NSString stringWithFormat:@"Queued %lu %@ in Music.\n\nKeep Music open while the download finishes.",
				   (unsigned long)imported, items];
		if (errors.count > 0) {
			NSArray<NSString *> *shown = errors;
			NSString *extra = @"";
			if (shown.count > 5) {
				extra = [NSString stringWithFormat:@"\n• …and %lu more",
						 (unsigned long)(shown.count - 5)];
				shown = [shown subarrayWithRange:NSMakeRange(0, 5)];
			}
			message = [message stringByAppendingFormat:@"\n\n%lu file%@ could not be imported:\n• %@%@",
					   (unsigned long)errors.count, errors.count == 1 ? @"" : @"s",
					   [shown componentsJoinedByString:@"\n• "], extra];
		}
	} else {
		NSString *details = @"No files were selected.";
		if (errors.count > 0) {
			NSArray<NSString *> *shown = errors;
			NSString *extra = @"";
			if (shown.count > 5) {
				extra = [NSString stringWithFormat:@"\n\n• …and %lu more",
						 (unsigned long)(shown.count - 5)];
				shown = [shown subarrayWithRange:NSMakeRange(0, 5)];
			}
			details = [NSString stringWithFormat:@"• %@%@",
					   [shown componentsJoinedByString:@"\n\n• "], extra];
		}
		message = [NSString stringWithFormat:@"Nothing was imported.\n\n%@\n\nLog: %@",
				   details, MDLogPath];
	}

	[self showMessage:message];
}

- (void)showMessage:(NSString *)message {
	UIViewController *presenter = MDTopViewController();
	if (!presenter) {
		MDLog(@"Cannot show message, no presenter: %@", message);
		return;
	}

	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"MusicDrop"
																   message:message
															preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[presenter presentViewController:alert animated:YES completion:nil];
}

@end
