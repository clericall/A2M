#import <UIKit/UIKit.h>
#import <unistd.h>
#import "MDImportButton.h"
#import "MDLog.h"

%ctor {
	@autoreleasepool {
		MDLog(@"MusicDrop loaded in pid %d", getpid());
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
					   dispatch_get_main_queue(), ^{
			[MDImportButton installIfNeeded];
		});
	}
}
