//
//  Copyright (c) Levin Li. All rights reserved.
//  Licensed under the MIT License.
//

#include <os/lock.h>

#import "AsyncGLView+Private.h"

typedef NS_OPTIONS(NSUInteger, AsyncGLViewEvent) {
    AsyncGLViewEventNone                = 0,
    AsyncGLViewEventCreateRenderContext = 1 << 0,
    AsyncGLViewEventDraw                = 1 << 1,
    AsyncGLViewEventPause               = 1 << 2,
};

typedef NS_ENUM(NSUInteger, AsyncGLViewContextState) {
    AsyncGLViewContextStateNone,
    AsyncGLViewContextStateCreationRequested,
    AsyncGLViewContextStateMainContextCreated,
    AsyncGLViewContextStateRenderContextCreated,
    AsyncGLViewContextStateEnded,
    AsyncGLViewContextStateFailed,
};

#if TARGET_OS_MACCATALYST
#define TARGET_OSX_OR_CATALYST          1
#elif TARGET_OS_OSX
#define TARGET_OSX_OR_CATALYST          1
#endif

#if __has_include(<libEGL/libEGL.h>) && __has_include(<libGLESv2/libGLESv2.h>)
#define USE_EGL
#endif

#ifdef USE_EGL
#if TARGET_OS_OSX
@import QuartzCore.CAMetalLayer;
#endif
@import libGLESv2;
@import libEGL;
@import Metal;
@import MetalFX;

/* EGL rendering API */
typedef enum EGLRenderingAPI : int
{
    kEGLRenderingAPIOpenGLES1 = 1,
    kEGLRenderingAPIOpenGLES2 = 2,
    kEGLRenderingAPIOpenGLES3 = 3,
} EGLRenderingAPI;

#else
#if TARGET_OSX_OR_CATALYST
@import OpenGL.GL;
@import OpenGL.GL3;
#else
@import OpenGLES.ES2;
@import OpenGLES.ES3;
#endif
#endif

#ifdef USE_EGL
@interface AsyncGLRendererResources : NSObject

@property (nonatomic) EGLImageKHR eglColorImage;
@property (nonatomic) EGLImageKHR eglDepthImage;
@property (nonatomic) GLuint glColorRenderBuffer;
@property (nonatomic) GLuint glDepthRenderBuffer;
@property (nonatomic) GLuint glFrameBuffer;
@property (nonatomic) GLuint glSampleColorRenderBuffer;
@property (nonatomic) GLuint glSampleDepthRenderBuffer;
@property (nonatomic) GLuint glSampleFrameBuffer;
@property (nonatomic) id<MTLTexture> metalColorTexture;
@property (nonatomic) id<MTLTexture> metalDepthTexture;
@property (nonatomic) NSUInteger width;
@property (nonatomic) NSUInteger height;
@property (nonatomic) id<MTLEvent> metalSharedEvent;
@property (nonatomic) uint64_t signalValue;
@property (nonatomic) id<MTLFXSpatialScaler> spatialScaler;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithEGLColorImage:(EGLImageKHR)eglColorImage
                        eglDepthImage:(EGLImageKHR)eglDepthImage
                  glColorRenderBuffer:(GLuint)glColorRenderBuffer
                  glDepthRenderBuffer:(GLuint)glDepthRenderBuffer
                        glFrameBuffer:(GLuint)glFrameBuffer
            glSampleColorRenderBuffer:(GLuint)glSampleColorRenderBuffer
            glSampleDepthRenderBuffer:(GLuint)glSampleDepthRenderBuffer
                  glSampleFrameBuffer:(GLuint)glSampleFrameBuffer
                    metalColorTexture:(id<MTLTexture>)metalColorTexture
                    metalDepthTexture:(id<MTLTexture>)metalDepthTexture
                                width:(NSUInteger)width
                               height:(NSUInteger)height
                     metalSharedEvent:(id<MTLEvent>)metalSharedEvent
                          signalValue:(uint64_t)signalValue
                        spatialScaler:(id<MTLFXSpatialScaler>)spatialScaler;

@end

@implementation AsyncGLRendererResources

- (instancetype)initWithEGLColorImage:(EGLImageKHR)eglColorImage
                        eglDepthImage:(EGLImageKHR)eglDepthImage
                  glColorRenderBuffer:(GLuint)glColorRenderBuffer
                  glDepthRenderBuffer:(GLuint)glDepthRenderBuffer
                        glFrameBuffer:(GLuint)glFrameBuffer
            glSampleColorRenderBuffer:(GLuint)glSampleColorRenderBuffer
            glSampleDepthRenderBuffer:(GLuint)glSampleDepthRenderBuffer
                  glSampleFrameBuffer:(GLuint)glSampleFrameBuffer
                    metalColorTexture:(id<MTLTexture>)metalColorTexture
                    metalDepthTexture:(id<MTLTexture>)metalDepthTexture
                                width:(NSUInteger)width
                               height:(NSUInteger)height
                     metalSharedEvent:(id<MTLEvent>)metalSharedEvent
                          signalValue:(uint64_t)signalValue
                        spatialScaler:(id<MTLFXSpatialScaler>)spatialScaler {
    self = [super init];
    if (self) {
        _eglColorImage = eglColorImage;
        _eglDepthImage = eglDepthImage;
        _glColorRenderBuffer = glColorRenderBuffer;
        _glDepthRenderBuffer = glDepthRenderBuffer;
        _glSampleColorRenderBuffer = glSampleColorRenderBuffer;
        _glSampleDepthRenderBuffer = glSampleDepthRenderBuffer;
        _glSampleFrameBuffer = glSampleFrameBuffer;
        _metalColorTexture = metalColorTexture;
        _metalDepthTexture = metalDepthTexture;
        _glFrameBuffer = glFrameBuffer;
        _width = width;
        _height = height;
        _metalSharedEvent = metalSharedEvent;
        _signalValue = signalValue;
        _spatialScaler = spatialScaler;
    }
    return self;
}
@end
#else
#if TARGET_OSX_OR_CATALYST
@interface PassthroughGLLayer : CAOpenGLLayer
@property (nonatomic) CGLContextObj renderContext;
@property (nonatomic) CGLPixelFormatObj pixelFormat;
@property (nonatomic) GLuint sourceFramebuffer;
@property (nonatomic) GLsizei width;
@property (nonatomic) GLsizei height;
@property (nonatomic) NSThread *thread;
@end

@implementation PassthroughGLLayer
- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:(uint32_t)mask {
    return _pixelFormat;
}

- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)pf {
    return _renderContext;
}

- (BOOL)canDrawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)ts {
    return [[NSThread currentThread] isEqual:_thread];
}

- (void)drawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)ts {
    CGLSetCurrentContext(ctx);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, _sourceFramebuffer);
    glBlitFramebuffer(0, 0, _width, _height, 0, 0, _width, _height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glFlush();
}
@end
#endif
#endif

@interface AsyncGLView () {
    BOOL _msaaEnabled;
}

@property (nonatomic) NSCondition *condition;
@property (nonatomic) os_unfair_lock renderLock;
@property (nonatomic) BOOL suspendedFlag;
@property (nonatomic) AsyncGLViewEvent event;
@property (nonatomic) BOOL contextsCreated;
@property (nonatomic) NSMutableArray *tasks;
@property (nonatomic) AsyncGLViewContextState contextState;
@property (nonatomic) BOOL requestExitThread;
@property (nonatomic) GLsizei sampleCount;
#ifdef USE_EGL
@property (nonatomic) CAMetalLayer *metalLayer;
@property (nonatomic) id<MTLDevice> metalDevice;
@property (nonatomic) id<MTLCommandQueue> metalCommandQueue;
@property (nonatomic) EGLRenderingAPI internalAPI;
@property (nonatomic) EGLDisplay display;
@property (nonatomic) EGLSurface renderSurface;
@property (nonatomic) EGLConfig renderConfig;
@property (nonatomic) EGLContext renderContext;
@property (nonatomic) AsyncGLRendererResources *renderResources;
#else
@property (nonatomic) GLuint framebuffer;
@property (nonatomic) GLuint depthBuffer;
@property (nonatomic) CGSize savedBufferSize;
#if !TARGET_OSX_OR_CATALYST
@property (nonatomic) GLuint sampleFramebuffer;
@property (nonatomic) GLuint sampleDepthbuffer;
@property (nonatomic) GLuint sampleColorbuffer;
@property (nonatomic) GLuint mainColorbuffer;
@property (nonatomic) EAGLRenderingAPI internalAPI;
@property (nonatomic) EAGLContext *renderContext;
@property (nonatomic) EAGLContext *mainContext;
@property (nonatomic) CAEAGLLayer *eaglLayer;
#else
@property (nonatomic) GLuint renderColorbuffer;
@property (nonatomic) CGLOpenGLProfile internalAPI;
@property (nonatomic) CGLContextObj renderContext;
@property (nonatomic) PassthroughGLLayer *glLayer;
#endif
#endif

@property (nonatomic) CGSize drawableSize;
@property (nonatomic) CGSize lastRenderSize;
@property (nonatomic) BOOL shouldRender;
@property (nonatomic) BOOL isObservingNotifications;
@end

@implementation AsyncGLView

#if !TARGET_OS_OSX
+ (Class)layerClass {
#ifdef USE_EGL
    return [CAMetalLayer class];
#else
#if TARGET_OS_MACCATALYST
    return [PassthroughGLLayer class];
#else
    return [CAEAGLLayer class];
#endif
#endif
}
#else
- (CALayer *)makeBackingLayer {
#ifdef USE_EGL
    return [CAMetalLayer layer];
#else
    return [PassthroughGLLayer layer];
#endif
}
#endif

#pragma mark - lifecycle/ui

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    return self;
}

- (void)pause {
#ifndef USE_EGL
#if !TARGET_OSX_OR_CATALYST
    [self makeMainContextCurrent];
    glFlush();
#endif
#endif

    dispatch_semaphore_t semaphore = nil;

    [_condition lock];
    if (!_suspendedFlag) {
        _event = AsyncGLViewEventPause;
        semaphore = dispatch_semaphore_create(0);
        __weak typeof(self) weakSelf = self;
        [_tasks addObject:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf != nil) {
                [strongSelf makeRenderContextCurrent];
                glFlush();
            }
            dispatch_semaphore_signal(semaphore);
        }];
        [_condition signal];
    }
    [_condition unlock];

    if (semaphore != nil)
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
}

- (void)resume {
    [_condition lock];
    _suspendedFlag = NO;
    [_condition signal];
    [_condition unlock];

    if (_contextState == AsyncGLViewContextStateRenderContextCreated)
        [self _checkViewState];
}

#pragma mark - interfaces
- (void)makeRenderContextCurrent {
#ifdef USE_EGL
    eglMakeCurrent(_display, _renderSurface, _renderSurface, _renderContext);
#else
#if !TARGET_OSX_OR_CATALYST
    [EAGLContext setCurrentContext:_renderContext];
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
#else
    CGLSetCurrentContext(_renderContext);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
#endif
#endif
}

- (void)clear {
    [_condition lock];
    _requestExitThread = YES;
    [_condition signal];
    [_condition unlock];
}

- (void)requestRender {
    [_condition lock];
    _event |= AsyncGLViewEventDraw;
    [_condition signal];
    [_condition unlock];
}

- (void)enqueueTask:(void (^)(void))task {
    [_condition lock];
    [_tasks addObject:task];
    [_condition unlock];
}

- (void)render {
    if (@available(iOS 18.0, tvOS 18.0, macOS 15.0, *)) {
        os_unfair_lock_lock_with_flags(&_renderLock, OS_UNFAIR_LOCK_FLAG_ADAPTIVE_SPIN);
    } else {
        os_unfair_lock_lock(&_renderLock);
    }
    CGSize size = _drawableSize;
    BOOL shouldRender = _shouldRender;
    os_unfair_lock_unlock(&_renderLock);

    if (shouldRender) {
        if (!CGSizeEqualToSize(_lastRenderSize, size)) {
            _lastRenderSize = size;
            #ifndef USE_EGL
            #if !TARGET_OSX_OR_CATALYST
            [self makeMainContextCurrent];
            glBindRenderbuffer(GL_RENDERBUFFER, _mainColorbuffer);
            [_mainContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:_eaglLayer];
            #endif
            #endif
        }

        [self makeRenderContextCurrent];
        [self _drawGL:size];
    #ifdef USE_EGL
        if (!_renderToMetalTexture)
            eglSwapBuffers(_display, _renderSurface);
    #else
        glFlush();
    #if !TARGET_OSX_OR_CATALYST
        glBindRenderbuffer(GL_RENDERBUFFER, _mainColorbuffer);
        [_renderContext presentRenderbuffer:GL_RENDERBUFFER];
    #else
        [_glLayer display];
    #endif
    #endif
    }
}

#pragma mark - private methods
- (void)commonSetup {
    _drawableSize = CGSizeZero;
    _lastRenderSize = CGSizeZero;
    _shouldRender = YES;
    _contextsCreated = NO;
    _contextState = AsyncGLViewContextStateNone;
    _requestExitThread = NO;
    _tasks = [NSMutableArray array];
    _isObservingNotifications = NO;
    _sampleCount = 0;
#ifdef USE_EGL
    _internalAPI = _api == AsyncGLAPIOpenGLES3 ? kEGLRenderingAPIOpenGLES3 : kEGLRenderingAPIOpenGLES2;
    _display = EGL_NO_DISPLAY;
    _renderSurface = EGL_NO_SURFACE;
    _renderContext = EGL_NO_CONTEXT;
    _metalDevice = nil;
    _metalCommandQueue = nil;
    _renderResources = nil;
#else
#if !TARGET_OSX_OR_CATALYST
    _internalAPI = _api == AsyncGLAPIOpenGLES3 ? kEAGLRenderingAPIOpenGLES3 : kEAGLRenderingAPIOpenGLES2;
    _mainContext = nil;
    _renderContext = nil;
    _mainColorbuffer = 0;
    _sampleFramebuffer = 0;
    _sampleDepthbuffer = 0;
    _sampleColorbuffer = 0;
#else
    switch (_api)
    {
    case AsyncGLAPIOpenGLCore32:
        _internalAPI = kCGLOGLPVersion_GL3_Core;
        break;
    case AsyncGLAPIOpenGLCore41:
        _internalAPI = kCGLOGLPVersion_GL4_Core;
        break;
    case AsyncGLAPIOpenGLLegacy:
    default:
        _internalAPI = kCGLOGLPVersion_Legacy;
    }
    _renderContext = NULL;
    _renderColorbuffer = 0;
#endif
    _framebuffer = 0;
    _depthBuffer = 0;
    _savedBufferSize = CGSizeZero;
#endif

#if TARGET_OS_OSX
    self.wantsLayer = YES;
#endif

    // Set layer properties
    self.layer.opaque = YES;
#if !TARGET_OS_OSX
    self.layer.backgroundColor = [[UIColor blackColor] CGColor];
#else
    self.layer.backgroundColor = [[NSColor blackColor] CGColor];
#endif

#ifdef USE_EGL
    _metalLayer = (CAMetalLayer *)self.layer;
    _renderToMetalTexture = YES;
#elif TARGET_OSX_OR_CATALYST
    _glLayer = (PassthroughGLLayer *)self.layer;
    _glLayer.asynchronous = YES;
#else
    _eaglLayer = (CAEAGLLayer *)self.layer;
    if ([_eaglLayer respondsToSelector:NSSelectorFromString(@"setLowLatency:")])
        [_eaglLayer setValue:@(YES) forKey:@"lowLatency"];
#endif

    _event = AsyncGLViewEventNone;
    _condition = [[NSCondition alloc] init];
    _renderLock = OS_UNFAIR_LOCK_INIT;
    _renderThread = [[NSThread alloc] initWithTarget:self selector:@selector(renderThreadMain) object:nil];
#ifndef USE_EGL
#if TARGET_OSX_OR_CATALYST
    _glLayer.thread = _renderThread;
#endif
#endif
    [_renderThread setThreadPriority:1.0];
    [_renderThread setQualityOfService:NSOperationQualityOfServiceUserInteractive];
    [_renderThread start];
}

- (void)renderThreadMain {
    while (YES) {
        @autoreleasepool {
            AsyncGLViewEvent event = AsyncGLViewEventNone;
            BOOL needsDrawn = NO;

            [_condition lock];
            while (!_requestExitThread && (_suspendedFlag || _event == AsyncGLViewEventNone))
                [_condition wait];

            BOOL requestExitThread = _requestExitThread;
            event = _event;
            _event = AsyncGLViewEventNone;

            NSArray *tasks = nil;
            if ([_tasks count] > 0) {
                tasks = [_tasks copy];
                [_tasks removeAllObjects];
            }

            [_condition unlock];

            if (requestExitThread) {
                [self clearGL];
                dispatch_sync(dispatch_get_main_queue(), ^{
                    self.contextState = AsyncGLViewContextStateEnded;
                });
                break;
            }

            if ((event & AsyncGLViewEventCreateRenderContext) != 0) {
                if ([self createRenderContext]) {
                    _contextsCreated = YES;
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        self.contextState = AsyncGLViewContextStateRenderContextCreated;
                        [self _startObservingViewStateNotifications];
                        [self _checkViewState];
                    });
                }
                else {
                    [self clearGL];
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        self.contextState = AsyncGLViewContextStateFailed;
                    });
                    break;
                }
            }

            BOOL paused = (event & AsyncGLViewEventPause) != 0;
            if (paused) {
                [_condition lock];
                _suspendedFlag = YES;
                [_condition unlock];
            }

            if (_contextsCreated) {
                if ((event & AsyncGLViewEventDraw) != 0 && !paused)
                    needsDrawn = YES;

                for (void (^task)(void) in tasks)
                    task();
            }

            if (needsDrawn)
                [self render];
        }
    }
}

#pragma mark - context creation
#ifdef USE_EGL
- (EGLContext)createEGLContextWithDisplay:(EGLDisplay)display api:(EGLRenderingAPI)api sharedContext:(EGLContext)sharedContext config:(EGLConfig*)config depthSize:(EGLint)depthSize msaa:(BOOL*)msaa {
    EGLint multisampleAttribs[] = {
        EGL_BLUE_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_RED_SIZE, 8,
        EGL_DEPTH_SIZE, depthSize,
        EGL_SAMPLES, 4,
        EGL_SAMPLE_BUFFERS, 1,
        EGL_NONE
    };
    EGLint attribs[] = {
        EGL_BLUE_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_RED_SIZE, 8,
        EGL_DEPTH_SIZE, depthSize,
        EGL_NONE
    };

    EGLint numConfigs;
    if (*msaa) {
        // Try to enable multisample but fallback if not available
        if (!eglChooseConfig(display, multisampleAttribs, config, 1, &numConfigs)) {
            *msaa = NO;
            NSLog(@"eglChooseConfig() returned error %d", eglGetError());
            if (!eglChooseConfig(display, attribs, config, 1, &numConfigs)) {
                NSLog(@"eglChooseConfig() returned error %d", eglGetError());
                return EGL_NO_CONTEXT;
            }
        }
    } else {
        if (!eglChooseConfig(display, attribs, config, 1, &numConfigs)) {
            NSLog(@"eglChooseConfig() returned error %d", eglGetError());
            return EGL_NO_CONTEXT;
        }
    }

    // Init context
    int ctxMajorVersion = 2;
    int ctxMinorVersion = 0;
    switch (api)
    {
        case kEGLRenderingAPIOpenGLES1:
            ctxMajorVersion = 1;
            ctxMinorVersion = 0;
            break;
        case kEGLRenderingAPIOpenGLES2:
            ctxMajorVersion = 2;
            ctxMinorVersion = 0;
            break;
        case kEGLRenderingAPIOpenGLES3:
            ctxMajorVersion = 3;
            ctxMinorVersion = 0;
            break;
        default:
            NSLog(@"Unknown GL ES API %d", api);
            return EGL_NO_CONTEXT;
    }
    EGLint ctxAttribs[] = { EGL_CONTEXT_MAJOR_VERSION, ctxMajorVersion, EGL_CONTEXT_MINOR_VERSION, ctxMinorVersion, EGL_NONE };

    EGLContext eglContext = eglCreateContext(display, *config, sharedContext, ctxAttribs);
    if (eglContext == EGL_NO_CONTEXT) {
        NSLog(@"eglCreateContext() returned error %d", eglGetError());
        return EGL_NO_CONTEXT;
    }
    return eglContext;
}
#endif

- (void)createContexts {
#ifdef USE_EGL
    _contextState = AsyncGLViewContextStateMainContextCreated;

    [_condition lock];
    _event |= AsyncGLViewEventCreateRenderContext;
    [_condition signal];
    [_condition unlock];
#else
#if !TARGET_OSX_OR_CATALYST
    _mainContext = [[EAGLContext alloc] initWithAPI:_internalAPI];
    if (_mainContext == nil) {
        _contextState = AsyncGLViewContextStateFailed;
        return;
    }

    _contextState = AsyncGLViewContextStateMainContextCreated;
    [_condition lock];
    _event = AsyncGLViewEventCreateRenderContext;
    [_condition signal];
    [_condition unlock];
#else
    const CGLPixelFormatAttribute attr[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)_internalAPI,
        kCGLPFADoubleBuffer, 0
    };
    CGLPixelFormatObj pixelFormat = NULL;
    GLint npix;
    CGLError error = CGLChoosePixelFormat(attr, &pixelFormat, &npix);
    if (pixelFormat == NULL) {
        _contextState = AsyncGLViewContextStateFailed;
        return;
    }

    CGLContextObj mainContext = NULL;
    error = CGLCreateContext(pixelFormat, NULL, &mainContext);
    if (mainContext == NULL) {
        CGLReleasePixelFormat(pixelFormat);
        _contextState = AsyncGLViewContextStateFailed;
        return;
    }

    _glLayer.pixelFormat = pixelFormat;
    _glLayer.renderContext = mainContext;

    _contextState = AsyncGLViewContextStateMainContextCreated;
    [_condition lock];
    _event = AsyncGLViewEventCreateRenderContext;
    [_condition signal];
    [_condition unlock];
#endif
#endif
}

- (BOOL)createRenderContext {
#ifdef USE_EGL
    EGLAttrib displayAttribs[] = { EGL_NONE };
    _display = eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, NULL, displayAttribs);
    if (_display == EGL_NO_DISPLAY) {
        NSLog(@"eglGetPlatformDisplay() returned error %d", eglGetError());
        return NO;
    }

    if (!eglInitialize(_display, NULL, NULL)) {
        NSLog(@"eglInitialize() returned error %d", eglGetError());
        return NO;
    }

    if (_renderToMetalTexture) {
        BOOL msaaEnabled = NO;
        _renderContext = [self createEGLContextWithDisplay:_display api:_internalAPI sharedContext:EGL_NO_CONTEXT config:&_renderConfig depthSize:24 msaa:&msaaEnabled];
    } else {
        _renderContext = [self createEGLContextWithDisplay:_display api:_internalAPI sharedContext:EGL_NO_CONTEXT config:&_renderConfig depthSize:24 msaa:&_msaaEnabled];

        if (_msaaEnabled) {
            EGLint numSamples;
            if (eglGetConfigAttrib(_display, _renderConfig, EGL_SAMPLES, &numSamples) && numSamples > 1)
                _sampleCount = (GLsizei)numSamples;
        }
    }

    if (_renderContext == EGL_NO_CONTEXT)
        return NO;

    if (_renderToMetalTexture) {
        EGLAttrib angleDevice = 0;
       if (eglQueryDisplayAttribEXT(_display, EGL_DEVICE_EXT, &angleDevice) != EGL_TRUE)
           return NO;

       EGLAttrib device = 0;
       if (eglQueryDeviceAttribEXT((EGLDeviceEXT)angleDevice, EGL_METAL_DEVICE_ANGLE, &device) != EGL_TRUE)
           return NO;

       _metalDevice = (__bridge id<MTLDevice>)(void *)device;

        if (_metalDevice == nil) {
            NSLog(@"Unable to get device from ANGLE");
            return NO;
        }

        _metalCommandQueue = [_metalDevice newCommandQueue];

        if (_metalCommandQueue == nil) {
            NSLog(@"[MTLDevice newCommandQueue] returned nil");
            return NO;
        }

        _metalLayer.device = _metalDevice;
    } else {
        _renderSurface = eglCreateWindowSurface(_display, _renderConfig, (__bridge EGLNativeWindowType)(_metalLayer), NULL);

        if (_renderSurface == EGL_NO_SURFACE) {
            NSLog(@"eglCreateWindowSurface() returned error %d", eglGetError());
            return NO;
        }
    }

    __block CGSize size;
    dispatch_sync(dispatch_get_main_queue(), ^{
        size = self.frame.size;
    });

    [self makeRenderContextCurrent];

    if (_msaaEnabled && _renderToMetalTexture) {
        GLint numSamples;
        glGetIntegerv(GL_MAX_SAMPLES, &numSamples);
        if (numSamples > 1)
            _sampleCount = MIN(numSamples, 4);
        else
            _msaaEnabled = NO;
    }

    eglSwapInterval(_display, 0);

    return [self setupGL:size];
#else
#if !TARGET_OSX_OR_CATALYST
    _renderContext = [[EAGLContext alloc] initWithAPI:_mainContext.API sharegroup:_mainContext.sharegroup];
    if (_renderContext == nil)
        return NO;

    __block CGSize size;
    dispatch_sync(dispatch_get_main_queue(), ^{
        CGSize frameSize = self.frame.size;
        CGFloat scale = self.layer.contentsScale;
        size = CGSizeMake(frameSize.width * scale, frameSize.height * scale);

        [self makeMainContextCurrent];
        [self createMainBuffers];
    });

    [self makeRenderContextCurrent];

    if (_msaaEnabled) {
        GLint numSamples;
        glGetIntegerv(GL_MAX_SAMPLES, &numSamples);
        if (numSamples > 1)
            _sampleCount = MIN(numSamples, 4);
        else
            _msaaEnabled = NO;
    }

    return [self createRenderBuffers:size];
#else
    const CGLPixelFormatAttribute attr[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)_internalAPI,
        0
    };
    CGLPixelFormatObj pixelFormat = NULL;
    GLint npix;
    CGLError error = CGLChoosePixelFormat(attr, &pixelFormat, &npix);
    if (!pixelFormat)
        return NO;

    error = CGLCreateContext(pixelFormat, _glLayer.renderContext, &_renderContext);
    CGLReleasePixelFormat(pixelFormat);
    if (!_renderContext)
        return NO;

    [self makeRenderContextCurrent];

    if (_msaaEnabled) {
        glEnable(GL_MULTISAMPLE);
        GLint numSamples;
        glGetIntegerv(GL_MAX_SAMPLES, &numSamples);
        if (numSamples > 1)
            _sampleCount = MIN(numSamples, 4);
        else
            _msaaEnabled = NO;
    }

    __block CGSize size;
    dispatch_sync(dispatch_get_main_queue(), ^{
        CGSize frameSize = self.frame.size;
        CGFloat scale = self.layer.contentsScale;
        size = CGSizeMake(frameSize.width * scale, frameSize.height * scale);
    });
    glGenRenderbuffers(1, &_renderColorbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _renderColorbuffer);
    return [self createRenderBuffers:size];
#endif
#endif
}

#ifndef USE_EGL
#pragma mark - buffer creation
#if !TARGET_OSX_OR_CATALYST
- (void)createMainBuffers {
    glGenRenderbuffers(1, &_mainColorbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _mainColorbuffer);
    [_mainContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer];
}
#endif

- (BOOL)createRenderBuffers:(CGSize)size {
    glGenFramebuffers(1, &_framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);

#if TARGET_OSX_OR_CATALYST
    glGenRenderbuffers(1, &_depthBuffer);

    [self updateBuffersSize:size];

    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _renderColorbuffer);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _depthBuffer);
#else
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _mainColorbuffer);

    if (_msaaEnabled) {
        glGenRenderbuffers(1, &_sampleColorbuffer);
        glGenRenderbuffers(1, &_sampleDepthbuffer);

        [self updateBuffersSize:size];

        glGenFramebuffers(1, &_sampleFramebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, _sampleFramebuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _sampleColorbuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _sampleDepthbuffer);

        // Check sampleFramebuffer
        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            NSLog(@"framebuffer not complete %d", status);
            return NO;
        }

        // Bind back
        glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    } else {
        glGenRenderbuffers(1, &_depthBuffer);

        [self updateBuffersSize:size];

        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _depthBuffer);
    }
#endif

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"framebuffer not complete %d", status);
        return NO;
    }

#if TARGET_OSX_OR_CATALYST
    _glLayer.sourceFramebuffer = _framebuffer;
#endif

    return [self setupGL:size];
}

#if !TARGET_OSX_OR_CATALYST
- (void)makeMainContextCurrent {
    [EAGLContext setCurrentContext:_mainContext];
}
#endif
#endif

- (void)updateBuffersSize:(CGSize)size {
#ifndef USE_EGL
    if (CGSizeEqualToSize(_savedBufferSize, size))
        return;

    _savedBufferSize = size;

    GLsizei width = (GLsizei)size.width;
    GLsizei height = (GLsizei)size.height;

#if TARGET_OSX_OR_CATALYST
    if (_msaaEnabled) {
        glBindRenderbuffer(GL_RENDERBUFFER, _renderColorbuffer);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, _sampleCount, GL_RGBA8, width, height);
        glBindRenderbuffer(GL_RENDERBUFFER, _depthBuffer);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, _sampleCount, GL_DEPTH_COMPONENT24, width, height);
    } else {
        glBindRenderbuffer(GL_RENDERBUFFER, _renderColorbuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, width, height);
        glBindRenderbuffer(GL_RENDERBUFFER, _depthBuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, width, height);
    }

    _glLayer.width = width;
    _glLayer.height = height;
#else
    if (_msaaEnabled) {
        glBindRenderbuffer(GL_RENDERBUFFER, _sampleColorbuffer);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, _sampleCount, GL_RGBA8_OES, width, height);
        glBindRenderbuffer(GL_RENDERBUFFER, _sampleDepthbuffer);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, _sampleCount, GL_DEPTH_COMPONENT24, width, height);
    } else {
        glBindRenderbuffer(GL_RENDERBUFFER, _depthBuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, width, height);
    }
#endif
#else
    if (!_renderToMetalTexture)
        return;

    const EGLint emptyAttributes[] = { EGL_NONE };

    GLuint glFrameBuffer;
    id<MTLTexture> metalColorTexture;
    id<MTLTexture> metalDepthTexture;
    EGLImageKHR eglColorImage;
    EGLImageKHR eglDepthImage;
    GLuint glColorRenderBuffer;
    GLuint glDepthRenderBuffer;
    uint64_t signalValue;
    id<MTLEvent> sharedEvent;
    GLuint glSampleColorRenderBuffer;
    GLuint glSampleDepthRenderBuffer;
    GLuint glSampleFrameBuffer;
    id<MTLFXSpatialScaler> spatialScaler;

    if (_renderResources == nil) {
        glGenFramebuffers(1, &glFrameBuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, glFrameBuffer);
        glFramebufferParameteriMESA(GL_FRAMEBUFFER, GL_FRAMEBUFFER_FLIP_Y_MESA, 1);

        if (_msaaEnabled) {
            glGenFramebuffers(1, &glSampleFrameBuffer);
            glBindFramebuffer(GL_FRAMEBUFFER, glSampleFrameBuffer);
            glFramebufferParameteriMESA(GL_FRAMEBUFFER, GL_FRAMEBUFFER_FLIP_Y_MESA, 1);
        } else {
            glSampleFrameBuffer = 0;
        }

        sharedEvent = [_metalDevice newEvent];
        signalValue = 1;
    } else {
        sharedEvent = _renderResources.metalSharedEvent;
        uint64_t currentSignalValue = _renderResources.signalValue;
        EGLAttrib syncAttribs[] = {
            EGL_SYNC_METAL_SHARED_EVENT_OBJECT_ANGLE,
            (EGLAttrib)sharedEvent,
            EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_HI_ANGLE,
            (EGLAttrib)(currentSignalValue >> 32),
            EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_LO_ANGLE,
            (EGLAttrib)(currentSignalValue & 0xFFFFFFFF),
            EGL_SYNC_CONDITION,
            EGL_SYNC_METAL_SHARED_EVENT_SIGNALED_ANGLE,
            EGL_NONE
        };

        EGLSync sync = eglCreateSync(_display, EGL_SYNC_METAL_SHARED_EVENT_ANGLE, syncAttribs);
        eglWaitSync(_display, sync, 0);
        eglDestroySync(_display, sync);

        glFrameBuffer = _renderResources.glFrameBuffer;
        glSampleFrameBuffer = _renderResources.glSampleFrameBuffer;

        signalValue = currentSignalValue + 1;
    }

    NSUInteger width = (NSUInteger)size.width;
    NSUInteger height = (NSUInteger)size.height;

    if (_renderResources == nil || _renderResources.width != width || _renderResources.height != height) {
        _metalLayer.drawableSize = CGSizeMake(width, height);

        // Regenerate textures for offscreen rendering
        if (_renderResources != nil) {
            GLuint renderBuffers[] = { _renderResources.glColorRenderBuffer, _renderResources.glDepthRenderBuffer };
            glDeleteRenderbuffers(2, renderBuffers);
            eglDestroyImageKHR(_display, _renderResources.eglColorImage);
            eglDestroyImageKHR(_display, _renderResources.eglDepthImage);
        }

        MTLFXSpatialScalerDescriptor *scalerDescriptor = [[MTLFXSpatialScalerDescriptor alloc] init];
        [scalerDescriptor setOutputWidth:width];
        [scalerDescriptor setOutputHeight:height];
        [scalerDescriptor setInputWidth:width / 2];
        [scalerDescriptor setInputHeight:height / 2];
        [scalerDescriptor setColorTextureFormat:MTLPixelFormatBGRA8Unorm];
        [scalerDescriptor setOutputTextureFormat:MTLPixelFormatBGRA8Unorm];
        [scalerDescriptor setColorProcessingMode:MTLFXSpatialScalerColorProcessingModeLinear];
        spatialScaler = [scalerDescriptor newSpatialScalerWithDevice:_metalDevice];

        NSUInteger inputWidth = [spatialScaler inputWidth];
        NSUInteger inputHeight = [spatialScaler inputHeight];

        MTLTextureDescriptor *texDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:inputWidth height:inputHeight mipmapped:NO];
        texDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        texDescriptor.storageMode = MTLStorageModePrivate;
        metalColorTexture = [_metalDevice newTextureWithDescriptor:texDescriptor];
        texDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:inputWidth height:inputHeight mipmapped:NO];
        texDescriptor.usage = MTLTextureUsageRenderTarget;
        texDescriptor.storageMode = MTLStorageModePrivate;
        metalDepthTexture = [_metalDevice newTextureWithDescriptor:texDescriptor];

        eglColorImage = eglCreateImageKHR(_display, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE, (__bridge EGLClientBuffer)metalColorTexture, emptyAttributes);
        eglDepthImage = eglCreateImageKHR(_display, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE, (__bridge EGLClientBuffer)metalDepthTexture, emptyAttributes);

        glGenRenderbuffers(1, &glColorRenderBuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, glColorRenderBuffer);
        glEGLImageTargetRenderbufferStorageOES(GL_RENDERBUFFER, eglColorImage);

        glGenRenderbuffers(1, &glDepthRenderBuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, glDepthRenderBuffer);
        glEGLImageTargetRenderbufferStorageOES(GL_RENDERBUFFER, eglDepthImage);

        if (_msaaEnabled) {
            glSampleColorRenderBuffer = _renderResources.glSampleColorRenderBuffer;
            if (glSampleColorRenderBuffer == 0)
                glGenRenderbuffers(1, &glSampleColorRenderBuffer);
            glBindRenderbuffer(GL_RENDERBUFFER, glSampleColorRenderBuffer);
            glRenderbufferStorageMultisample(GL_RENDERBUFFER, 4, GL_RGBA8, (GLsizei)inputWidth, (GLsizei)inputHeight);

            glSampleDepthRenderBuffer = _renderResources.glSampleDepthRenderBuffer;
            if (glSampleDepthRenderBuffer == 0)
                glGenRenderbuffers(1, &glSampleDepthRenderBuffer);
            glBindRenderbuffer(GL_RENDERBUFFER, glSampleDepthRenderBuffer);
            glRenderbufferStorageMultisample(GL_RENDERBUFFER, 4, GL_DEPTH_COMPONENT24, (GLsizei)inputWidth, (GLsizei)inputHeight);

            glBindFramebuffer(GL_FRAMEBUFFER, glSampleFrameBuffer);

            glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, glSampleColorRenderBuffer);
            glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, glSampleDepthRenderBuffer);
        } else {
            glSampleColorRenderBuffer = 0;
            glSampleDepthRenderBuffer = 0;
        }
        glBindFramebuffer(GL_FRAMEBUFFER, glFrameBuffer);

        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, glColorRenderBuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, glDepthRenderBuffer);
    } else {
        eglColorImage = _renderResources.eglColorImage;
        eglDepthImage = _renderResources.eglDepthImage;
        glColorRenderBuffer = _renderResources.glColorRenderBuffer;
        glDepthRenderBuffer = _renderResources.glDepthRenderBuffer;
        glSampleColorRenderBuffer = _renderResources.glSampleColorRenderBuffer;
        glSampleDepthRenderBuffer = _renderResources.glSampleDepthRenderBuffer;
        metalColorTexture = _renderResources.metalColorTexture;
        metalDepthTexture = _renderResources.metalDepthTexture;
        spatialScaler = _renderResources.spatialScaler;
    }

    _renderResources = [[AsyncGLRendererResources alloc] initWithEGLColorImage:eglColorImage eglDepthImage:eglDepthImage glColorRenderBuffer:glColorRenderBuffer glDepthRenderBuffer:glDepthRenderBuffer glFrameBuffer:glFrameBuffer glSampleColorRenderBuffer:glSampleColorRenderBuffer glSampleDepthRenderBuffer:glSampleDepthRenderBuffer glSampleFrameBuffer:glSampleFrameBuffer metalColorTexture:metalColorTexture metalDepthTexture:metalDepthTexture width:width height:height metalSharedEvent:sharedEvent signalValue:signalValue spatialScaler:spatialScaler];
#endif
}

#pragma mark - internal implementation
- (BOOL)setupGL:(CGSize)size {
    return [_delegate _prepareGL:size samples:(NSInteger)_sampleCount];
}

- (void)_drawGL:(CGSize)size
{
    [self updateBuffersSize:size];

#ifdef USE_EGL
    if (_renderToMetalTexture) {
        size = CGSizeMake([[_renderResources spatialScaler] inputWidth], [[_renderResources spatialScaler] inputHeight]);
        if (_msaaEnabled) {
            GLsizei width = (GLsizei)size.width;
            GLsizei height = (GLsizei)size.height;
            glBindFramebuffer(GL_FRAMEBUFFER, [_renderResources glSampleFrameBuffer]);

            [_delegate _drawGL:size];

            glBindFramebuffer(GL_READ_FRAMEBUFFER, [_renderResources glSampleFrameBuffer]);
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, [_renderResources glFrameBuffer]);

            GLenum attachments[] = { GL_COLOR_ATTACHMENT0, GL_DEPTH_COMPONENT };
            glBlitFramebuffer(0, 0, width, height, 0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
            glInvalidateFramebuffer(GL_READ_FRAMEBUFFER, 2, attachments);
        } else {
            glBindFramebuffer(GL_FRAMEBUFFER, [_renderResources glFrameBuffer]);
            [_delegate _drawGL:size];
        }
    } else {
        [_delegate _drawGL:size];
    }
#elif TARGET_OSX_OR_CATALYST
    [_delegate _drawGL:size];
#else
    if (_msaaEnabled) {
        GLsizei width = (GLsizei)size.width;
        GLsizei height = (GLsizei)size.height;
        glBindFramebuffer(GL_FRAMEBUFFER, _sampleFramebuffer);

        [_delegate _drawGL:size];

        glBindFramebuffer(GL_READ_FRAMEBUFFER, _sampleFramebuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _framebuffer);

        GLenum attachments[] = { GL_COLOR_ATTACHMENT0, GL_DEPTH_ATTACHMENT };
        if (_internalAPI == kEAGLRenderingAPIOpenGLES2) {
            glResolveMultisampleFramebufferAPPLE();
            glDiscardFramebufferEXT(GL_READ_FRAMEBUFFER, 2, attachments);
        } else {
            glBlitFramebuffer(0, 0, width, height, 0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
            glInvalidateFramebuffer(GL_READ_FRAMEBUFFER, 2, attachments);
        }
    } else {
        [_delegate _drawGL:size];
    }
#endif
#ifdef USE_EGL
    if (_renderToMetalTexture) {
        glFlush();

        id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
        id<MTLCommandBuffer> commandBuffer = [_metalCommandQueue commandBuffer];

        id<MTLEvent> sharedEvent = [_renderResources metalSharedEvent];
        uint64_t signalValue = [_renderResources signalValue];
        EGLAttrib syncAttribs[] = {
            EGL_SYNC_METAL_SHARED_EVENT_OBJECT_ANGLE,
            (EGLAttrib)sharedEvent,
            EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_HI_ANGLE,
            (EGLAttrib)(signalValue >> 32),
            EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_LO_ANGLE,
            (EGLAttrib)(signalValue & 0xFFFFFFFF),
            EGL_NONE
        };

        EGLSync sync = eglCreateSync(_display, EGL_SYNC_METAL_SHARED_EVENT_ANGLE, syncAttribs);

        [commandBuffer encodeWaitForEvent:sharedEvent value:signalValue];
//
//        id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
//        [blitEncoder copyFromTexture:[_renderResources metalColorTexture] toTexture:drawable.texture];
//        [blitEncoder endEncoding];

        [[_renderResources spatialScaler] setColorTexture:[_renderResources metalColorTexture]];
        [[_renderResources spatialScaler] setOutputTexture:[drawable texture]];
        [[_renderResources spatialScaler] encodeToCommandBuffer:commandBuffer];

        signalValue += 1;

        [commandBuffer encodeSignalEvent:sharedEvent value:signalValue];
        _renderResources.signalValue = signalValue;

        eglDestroySync(_display, sync);

        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
    }
#endif
}

#pragma mark - clear
- (void)clearGL {
    [_delegate _clearGL];

    [self _clearGL];
}

- (void)_clearGL {
    glFlush();

    [self clearResources];
    [self destroyRenderContext];

    dispatch_sync(dispatch_get_main_queue(), ^{
        [self _stopObservingViewStateNotifications];
        [self destroyMainContext];
    });
}

- (void)clearResources {
#ifndef USE_EGL
    if (_depthBuffer != 0) {
        glDeleteRenderbuffers(1, &_depthBuffer);
        _depthBuffer = 0;
    }

#if !TARGET_OSX_OR_CATALYST
    if (_sampleFramebuffer != 0) {
        glDeleteFramebuffers(1, &_sampleFramebuffer);
        _sampleFramebuffer = 0;
    }

    if (_sampleDepthbuffer != 0) {
        glDeleteFramebuffers(1, &_sampleDepthbuffer);
        _sampleDepthbuffer = 0;
    }

    if (_sampleColorbuffer != 0) {
        glDeleteFramebuffers(1, &_sampleColorbuffer);
        _sampleColorbuffer = 0;
    }
#endif

    if (_framebuffer != 0) {
        glDeleteFramebuffers(1, &_framebuffer);
        _framebuffer = 0;
    }

#if TARGET_OSX_OR_CATALYST
    if (_renderColorbuffer != 0) {
        glDeleteRenderbuffers(1, &_renderColorbuffer);
        _renderColorbuffer = 0;
    }
#endif
#endif
}

- (void)destroyMainContext {
#ifndef USE_EGL
#if !TARGET_OSX_OR_CATALYST
    [self makeMainContextCurrent];
    glFlush();

    if (_mainColorbuffer != 0) {
        glDeleteRenderbuffers(1, &_mainColorbuffer);
        _mainColorbuffer = 0;
    }

    _mainContext = nil;
#endif
#endif
}

- (void)destroyRenderContext {
#ifdef USE_EGL
    if (_renderSurface != EGL_NO_SURFACE) {
        eglDestroySurface(_display, _renderSurface);
        _renderSurface = EGL_NO_SURFACE;
    }

    if (_renderContext != EGL_NO_CONTEXT) {
        eglMakeCurrent(_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroyContext(_display, _renderContext);
        _renderContext = EGL_NO_CONTEXT;
    }

    if (_display != EGL_NO_DISPLAY) {
        eglTerminate(_display);
        _display = EGL_NO_DISPLAY;
    }
#else
#if TARGET_OSX_OR_CATALYST
    CGLReleaseContext(_renderContext);
    _renderContext = NULL;
#else
    _renderContext = nil;
#endif
#endif
}

#pragma mark - view checker
- (void)_startObservingViewStateNotifications {
    if (_isObservingNotifications)
        return;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
#if TARGET_OS_OSX
    [center addObserver:self selector:@selector(_checkViewState) name:NSViewFrameDidChangeNotification object:self];
    [center addObserver:self selector:@selector(_handleWindowOcclusionStateChanged:) name:NSWindowDidChangeOcclusionStateNotification object:nil];
#else
    [center addObserver:self selector:@selector(_checkViewState) name:UIApplicationWillEnterForegroundNotification object:nil];
    [center addObserver:self selector:@selector(_checkViewState) name:UIApplicationDidEnterBackgroundNotification object:nil];
#endif
    _isObservingNotifications = YES;
}

- (void)_stopObservingViewStateNotifications {
    if (!_isObservingNotifications)
        return;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
#if TARGET_OS_OSX
    [center removeObserver:self name:NSViewFrameDidChangeNotification object:self];
    [center removeObserver:self name:NSWindowDidChangeOcclusionStateNotification object:self];
#else
    [center removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
    [center removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
#endif
    _isObservingNotifications = NO;
}

- (void)_checkViewState {
    if (_contextState != AsyncGLViewContextStateRenderContextCreated)
        return;

    CGSize frameSize = self.frame.size;
    BOOL shouldRender = frameSize.width > 0.0f && frameSize.height > 0.0f && !self.isHidden && self.window;
#if !TARGET_OS_OSX
    shouldRender = shouldRender && ([[UIApplication sharedApplication] applicationState] != UIApplicationStateBackground);
#else
    shouldRender = shouldRender && ([[self window] occlusionState] & NSWindowOcclusionStateVisible);
#endif

    CGFloat scale = self.layer.contentsScale;
    CGSize newSize = CGSizeMake(frameSize.width * scale, frameSize.height * scale);

    if (@available(iOS 18.0, tvOS 18.0, macOS 15.0, *)) {
        os_unfair_lock_lock_with_flags(&_renderLock, OS_UNFAIR_LOCK_FLAG_ADAPTIVE_SPIN);
    } else {
        os_unfair_lock_lock(&_renderLock);
    }
    _drawableSize = newSize;
    _shouldRender = shouldRender;
    os_unfair_lock_unlock(&_renderLock);
}

#if !TARGET_OS_OSX
- (void)layoutSubviews {
    [super layoutSubviews];

    [self _checkViewState];
}
#endif

- (void)setContentScaleFactor:(CGFloat)contentScaleFactor {
#if TARGET_OS_OSX
    self.layer.contentsScale = contentScaleFactor;
#else
    [super setContentScaleFactor:contentScaleFactor];
#endif

    [self _checkViewState];
}

#if TARGET_OS_OSX
- (void)_handleWindowOcclusionStateChanged:(NSNotification *)notification
{
    if ([notification object] != [self window]) return;

    [self _checkViewState];
}
#endif

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];

    [self _checkViewState];
}

#if !TARGET_OS_OSX
- (void)willMoveToWindow:(UIWindow *)newWindow {
    [super willMoveToWindow:newWindow];
#else
- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    [super viewWillMoveToWindow:newWindow];
#endif
    if (newWindow && _contextState == AsyncGLViewContextStateNone) {
        _contextState = AsyncGLViewContextStateCreationRequested;
        [self createContexts];
    }

    [self _checkViewState];
    [_delegate _viewWillMoveToWindow:newWindow];
}

@end
