#import <Foundation/Foundation.h>

#define MDLogPath @"/var/mobile/Media/MusicDrop/musicdrop.log"

void MDLogv(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
#define MDLog(...) MDLogv(__VA_ARGS__)
