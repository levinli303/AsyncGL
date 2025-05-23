//
//  Copyright (c) Levin Li. All rights reserved.
//  Licensed under the MIT License.
//

#import <TargetConditionals.h>

#if !TARGET_OS_OSX
@import UIKit;
#else
@import Cocoa;
#endif

NS_ASSUME_NONNULL_BEGIN

#if !TARGET_OS_OSX
@interface AsyncGLView : UIView
#else
@interface AsyncGLView : NSView
#endif

#if TARGET_OS_OSX
@property (nonatomic) CGFloat contentScaleFactor;
#endif

@end

NS_ASSUME_NONNULL_END
