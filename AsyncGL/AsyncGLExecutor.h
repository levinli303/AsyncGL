//
//  AsyncGLExecutor.h
//  AsyncGL
//
//  Created by Levin Li on 2023/1/10.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AsyncGLExecutor : NSObject

- (instancetype)init;

- (void)runTaskAsynchronously:(void(NS_SWIFT_SENDABLE ^)(void))task;
- (void)runTaskSynchronously:(void(NS_SWIFT_SENDABLE ^)(void))task;
- (void)makeRenderContextCurrent;
- (void)prepareForDrawing:(void (NS_NOESCAPE ^ _Nullable)(void))draw resolve:(void (NS_NOESCAPE ^ _Nullable)(void))resolve;

@end

NS_ASSUME_NONNULL_END
