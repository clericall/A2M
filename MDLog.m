#import "MDLog.h"
#import <stdarg.h>

static dispatch_queue_t MDLogQueue(void) {
	static dispatch_queue_t queue;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		queue = dispatch_queue_create("com.musiccc.musicdrop.log", DISPATCH_QUEUE_SERIAL);
	});
	return queue;
}

void MDLogv(NSString *format, ...) {
	if (!format) {
		return;
	}

	va_list args;
	va_start(args, format);
	NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
	va_end(args);

	NSLog(@"[MusicDrop] %@", message);

	dispatch_async(MDLogQueue(), ^{
		static NSDateFormatter *formatter;
		static dispatch_once_t once;
		dispatch_once(&once, ^{
			formatter = [NSDateFormatter new];
			formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
			formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
		});

		NSString *line = [NSString stringWithFormat:@"%@ %@\n", [formatter stringFromDate:[NSDate date]], message];
		NSFileManager *fm = [NSFileManager defaultManager];
		NSString *directory = [MDLogPath stringByDeletingLastPathComponent];
		[fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];

		NSDictionary *attributes = [fm attributesOfItemAtPath:MDLogPath error:nil];
		if ([attributes fileSize] > 1024 * 1024) {
			NSString *oldPath = [MDLogPath stringByAppendingString:@".old"];
			[fm removeItemAtPath:oldPath error:nil];
			[fm moveItemAtPath:MDLogPath toPath:oldPath error:nil];
		}

		NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:MDLogPath];
		if (!handle) {
			[fm createFileAtPath:MDLogPath
						 contents:nil
					   attributes:@{NSFileProtectionKey: NSFileProtectionNone}];
			handle = [NSFileHandle fileHandleForWritingAtPath:MDLogPath];
		}

		@try {
			[handle seekToEndOfFile];
			[handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
			[handle closeFile];
		} @catch (__unused NSException *exception) {
			// Logging must never crash the host app.
		}
	});
}
