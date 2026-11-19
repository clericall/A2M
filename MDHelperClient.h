#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MDHelperClient : NSObject

/// Sends a request to the MusicDrop helper daemon and returns its response dict.
/// Blocks the calling thread; progress is reported synchronously to the block.
+ (nullable NSDictionary *)runOperation:(NSDictionary *)operation
							   progress:(nullable void (^)(NSString *status))progress
								  error:(NSError **)error;

/// Convenience wrapper that runs on a background queue and returns on main.
+ (void)runOperation:(NSDictionary *)operation
			progress:(nullable void (^)(NSString *status))progress
		  completion:(void (^)(NSDictionary * _Nullable response, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
