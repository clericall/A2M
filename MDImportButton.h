#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MDImportButton : UIButton

/// Adds the floating Import button to Music's key window. Safe to call repeatedly.
+ (void)installIfNeeded;

@end

NS_ASSUME_NONNULL_END
