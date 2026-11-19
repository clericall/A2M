#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

@interface MDServer : NSObject

+ (instancetype)sharedServer;

@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// Serves a specific file at a random URL such as
/// http://127.0.0.1:12345/media/<token>.mp3
- (nullable NSURL *)registerFilePath:(NSString *)path extension:(nullable NSString *)extension;
- (void)unregisterToken:(NSString *)token;

@end

NS_ASSUME_NONNULL_END
