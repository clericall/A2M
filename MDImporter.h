#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^MDImportProgressBlock)(NSString *status);
typedef void (^MDImportCompletionBlock)(NSUInteger imported, NSArray<NSString *> *errors);

@interface MDImporter : NSObject

+ (instancetype)sharedImporter;

/// Copies, inspects, and enqueues each file. Completion runs on the main queue
/// after every file has been handed to Music's download queue.
- (void)importURLs:(NSArray<NSURL *> *)urls
		  progress:(nullable MDImportProgressBlock)progress
		completion:(MDImportCompletionBlock)completion;

@end

NS_ASSUME_NONNULL_END
