#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Loopback port used by the Music app to reach the unsandboxed helper daemon.
static uint16_t const MDHelperPort = 45454;

static NSString *const MDHelperOperationKey = @"op";
static NSString *const MDHelperOperationYouTube = @"youtube";
static NSString *const MDHelperOperationLyrics = @"lyrics";
static NSString *const MDHelperURLKey = @"url";
static NSString *const MDHelperPathKey = @"path";
static NSString *const MDHelperTitleKey = @"title";
static NSString *const MDHelperArtistKey = @"artist";
static NSString *const MDHelperAlbumKey = @"album";
static NSString *const MDHelperDurationKey = @"duration";
static NSString *const MDHelperResultPathKey = @"resultPath";

NS_ASSUME_NONNULL_END
