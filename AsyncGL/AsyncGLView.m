//
//  Copyright (c) Levin Li. All rights reserved.
//  Licensed under the MIT License.
//

#include <os/lock.h>

#import "AsyncGLView+Private.h"

static const NSUInteger kDrawableCount = 2;

typedef NS_OPTIONS(NSUInteger, AsyncGLViewEvent) {
    AsyncGLViewEventNone                = 0,
    AsyncGLViewEventCreateRenderContext = 1 << 0,
    AsyncGLViewEventDraw                = 1 << 1,
    AsyncGLViewEventPause               = 1 << 2,
};

typedef NS_ENUM(NSUInteger, AsyncGLViewContextState) {
    AsyncGLViewContextStateNone,
    AsyncGLViewContextStateCreationRequested,
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

#if TARGET_OS_OSX
@import QuartzCore.CATransaction;
#endif

#ifdef USE_EGL
@import libGLESv2;
@import libEGL;
@import Metal;

/* EGL rendering API */
typedef enum EGLRenderingAPI : int
{
    kEGLRenderingAPIOpenGLES2 = 2,
    kEGLRenderingAPIOpenGLES3 = 3,
} EGLRenderingAPI;

#else
@import IOSurface;
#if TARGET_OSX_OR_CATALYST
@import OpenGL.GL;
@import OpenGL.GL3;
#else
@import OpenGLES.ES2;
@import OpenGLES.ES3;
@import OpenGLES.EAGLIOSurface;
#endif
#endif

@interface AsyncGLDrawable : NSObject
@property (nonatomic) IOSurfaceRef ioSurface;
@property (nonatomic) GLuint screenColorTexture;
#ifdef USE_EGL
@property (nonatomic) EGLImageKHR screenColorImage;
#endif
@end

@implementation AsyncGLDrawable

#ifdef USE_EGL
- (instancetype)initWithIOSurface:(IOSurfaceRef)ioSurface screenColorTexture:(GLuint)screenColorTexture screenColorImage:(EGLImageKHR)screenColorImage {
    self = [super init];
    if (self) {
        _ioSurface = ioSurface;
        _screenColorTexture = screenColorTexture;
        _screenColorImage = screenColorImage;
    }
    return self;
}
#else
- (instancetype)initWithIOSurface:(IOSurfaceRef)ioSurface screenColorTexture:(GLuint)screenColorTexture {
    self = [super init];
    if (self) {
        _ioSurface = ioSurface;
        _screenColorTexture = screenColorTexture;
    }
    return self;
}
#endif

@end

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
@property (nonatomic) CGSize savedBufferSize;
@property (nonatomic) GLuint screenDepthBuffer;
@property (nonatomic) GLuint screenFrameBuffer;
@property (nonatomic) GLuint sampleColorBuffer;
@property (nonatomic) GLuint sampleDepthBuffer;
@property (nonatomic) GLuint sampleFrameBuffer;
@property (nonatomic) CALayer *glLayer;
@property (nonatomic) NSMutableArray<AsyncGLDrawable *> *availableDrawables;
@property (nonatomic) NSUInteger nextDrawableIndex;
#ifdef USE_EGL
@property (nonatomic) EGLRenderingAPI internalAPI;
@property (nonatomic) EGLDisplay display;
@property (nonatomic) EGLConfig renderConfig;
@property (nonatomic) EGLContext renderContext;
@property (nonatomic) id<MTLDevice> metalDevice;
#else
#if !TARGET_OSX_OR_CATALYST
@property (nonatomic) EAGLRenderingAPI internalAPI;
@property (nonatomic) EAGLContext *renderContext;
#else
@property (nonatomic) CGLOpenGLProfile internalAPI;
@property (nonatomic) CGLContextObj renderContext;
#endif
#endif

@property (nonatomic) CGSize drawableSize;
@property (nonatomic) BOOL shouldRender;
@property (nonatomic) BOOL isObservingNotifications;
@end

@implementation AsyncGLView

#if !TARGET_OS_OSX
+ (Class)layerClass {
    return [CALayer class];
}
#else
- (CALayer *)makeBackingLayer {
    return [CALayer layer];
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
    eglMakeCurrent(_display, EGL_NO_SURFACE, EGL_NO_SURFACE, _renderContext);
#else
#if !TARGET_OSX_OR_CATALYST
    [EAGLContext setCurrentContext:_renderContext];
#else
    CGLSetCurrentContext(_renderContext);
#endif
    glBindFramebuffer(GL_FRAMEBUFFER, _screenFrameBuffer);
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
        [self makeRenderContextCurrent];
        AsyncGLDrawable *drawable = [self _drawGL:size];
        glFlush();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.glLayer.contents = (__bridge id)(drawable.ioSurface);
        });
    }
}

#pragma mark - private methods
- (void)commonSetup {
    _drawableSize = CGSizeZero;
    _shouldRender = YES;
    _contextsCreated = NO;
    _contextState = AsyncGLViewContextStateNone;
    _requestExitThread = NO;
    _tasks = [NSMutableArray array];
    _isObservingNotifications = NO;
    _sampleCount = 0;
    _availableDrawables = nil;
    _nextDrawableIndex = 0;
#ifdef USE_EGL
    _internalAPI = _api == AsyncGLAPIOpenGLES3 ? kEGLRenderingAPIOpenGLES3 : kEGLRenderingAPIOpenGLES2;
    _display = EGL_NO_DISPLAY;
    _renderContext = EGL_NO_CONTEXT;
    _renderConfig = 0;
    _metalDevice = nil;
#else
#if !TARGET_OSX_OR_CATALYST
    _internalAPI = _api == AsyncGLAPIOpenGLES3 ? kEAGLRenderingAPIOpenGLES3 : kEAGLRenderingAPIOpenGLES2;
    _renderContext = nil;
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
#endif
    _savedBufferSize = CGSizeZero;
    _screenDepthBuffer = 0;
    _screenFrameBuffer = 0;
    _sampleColorBuffer = 0;
    _sampleDepthBuffer = 0;
    _sampleFrameBuffer = 0;
#endif

#if TARGET_OS_OSX
    self.wantsLayer = YES;
#endif

    // Set layer properties
    self.layer.opaque = YES;

    _glLayer = self.layer;
    _glLayer.transform = CATransform3DMakeScale(1, -1, 1);

    _event = AsyncGLViewEventNone;
    _condition = [[NSCondition alloc] init];
    _renderLock = OS_UNFAIR_LOCK_INIT;
    _renderThread = [[NSThread alloc] initWithTarget:self selector:@selector(renderThreadMain) object:nil];

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
- (void)createContexts {
    [_condition lock];
    _event = AsyncGLViewEventCreateRenderContext;
    [_condition signal];
    [_condition unlock];
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

    EGLint configAttribs[] = {
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_NONE,
    };

    EGLint numConfigs;
    if (!eglChooseConfig(_display, configAttribs, &_renderConfig, 1, &numConfigs)) {
        NSLog(@"eglChooseConfig() returned error %d", eglGetError());
        return NO;
    }

    // Init context
    int requestedMajorVersion = 2;
    int requestedMinorVersion = 0;
    switch (_internalAPI)
    {
    case kEGLRenderingAPIOpenGLES2:
        requestedMajorVersion = 2;
        requestedMinorVersion = 0;
        break;
    case kEGLRenderingAPIOpenGLES3:
        requestedMajorVersion = 3;
        requestedMinorVersion = 0;
        break;
    default:
        NSLog(@"Unknown GL ES API %d", _internalAPI);
        return NO;
    }

    EGLint ctxAttribs[] = { EGL_CONTEXT_MAJOR_VERSION, requestedMajorVersion, EGL_CONTEXT_MINOR_VERSION, requestedMinorVersion, EGL_NONE };
    _renderContext = eglCreateContext(_display, _renderConfig, NULL, ctxAttribs);
    if (_renderContext == EGL_NO_CONTEXT) {
        NSLog(@"eglCreateContext() returned error %d", eglGetError());
        return EGL_NO_CONTEXT;
    }
#elif !TARGET_OSX_OR_CATALYST
    _renderContext = [[EAGLContext alloc] initWithAPI:_internalAPI];
    if (_renderContext == nil)
        return NO;
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

    error = CGLCreateContext(pixelFormat, NULL, &_renderContext);
    CGLReleasePixelFormat(pixelFormat);
    if (!_renderContext)
        return NO;
#endif

    [self makeRenderContextCurrent];

#ifdef USE_EGL
    // Actual GLES version might be different than what is requested
    EGLint majorVersion = 0;
    eglQueryContext(_display, _renderContext, EGL_CONTEXT_CLIENT_VERSION, &majorVersion);

    switch (majorVersion)
    {
    case 2:
        _internalAPI = kEGLRenderingAPIOpenGLES2;
        break;
    case 3:
        _internalAPI = kEGLRenderingAPIOpenGLES2;
        break;
    default:
        NSLog(@"Unknown GL ES API Major Version %d", majorVersion);
        return NO;
    }

    EGLAttrib angleDevice = 0;
    if (eglQueryDisplayAttribEXT(_display, EGL_DEVICE_EXT, &angleDevice) != EGL_TRUE) {
        NSLog(@"eglQueryDisplayAttribEXT() returned error %d", eglGetError());
        return NO;
    }

    EGLAttrib device = 0;
    if (eglQueryDeviceAttribEXT((EGLDeviceEXT)angleDevice, EGL_METAL_DEVICE_ANGLE, &device) != EGL_TRUE) {
        NSLog(@"eglQueryDeviceAttribEXT() returned error %d", eglGetError());
        return NO;
    }

    _metalDevice = (__bridge id<MTLDevice>)(void *)device;
#endif

    if (_msaaEnabled) {
#if !defined(USE_EGL) && TARGET_OSX_OR_CATALYST
        glEnable(GL_MULTISAMPLE);
#endif
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
    return [self createRenderBuffers:size];
}

#pragma mark - buffer creation
- (BOOL)createRenderBuffers:(CGSize)size {
    glGenFramebuffers(1, &_screenFrameBuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _screenFrameBuffer);

    [self updateBuffersSize:size];
    [self bindNextDrawable];

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"framebuffer not complete %d", status);
        return NO;
    }

    return [self setupGL:size];
}

- (AsyncGLDrawable *)bindNextDrawable {
    AsyncGLDrawable *drawable = [_availableDrawables objectAtIndex:_nextDrawableIndex];

#if defined(USE_EGL) || !TARGET_OSX_OR_CATALYST
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, drawable.screenColorTexture, 0);
#else
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE_ARB, drawable.screenColorTexture, 0);
#endif

    _nextDrawableIndex = (_nextDrawableIndex + 1) % kDrawableCount;
    return drawable;
}

- (AsyncGLDrawable *)createDrawable:(CGSize)size {
    GLuint screenColorTexture;
    glGenTextures(1, &screenColorTexture);
#if defined(USE_EGL) || !TARGET_OSX_OR_CATALYST
    glBindTexture(GL_TEXTURE_2D, screenColorTexture);
#else
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, screenColorTexture);
#endif

    NSDictionary *desc = @{
        (NSString *)kIOSurfaceWidth: @((NSUInteger)size.width),
        (NSString *)kIOSurfaceHeight: @((NSUInteger)size.height),
        (NSString *)kIOSurfaceBytesPerElement: @4,
        (NSString *)kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA),
    };

    IOSurfaceRef ioSurface = IOSurfaceCreate((__bridge CFDictionaryRef)desc);

#ifdef USE_EGL
    MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:(NSUInteger)size.width height:(NSUInteger)size.height mipmapped:NO];
    id<MTLTexture> metalTexture = [_metalDevice newTextureWithDescriptor:textureDescriptor iosurface:ioSurface plane:0];

    const EGLint imageAttributes[] = { EGL_NONE };
    EGLImageKHR screenColorImage = eglCreateImageKHR(_display, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE, (__bridge EGLClientBuffer)metalTexture, imageAttributes);
    glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, screenColorImage);
#else
#if TARGET_OSX_OR_CATALYST
    CGLTexImageIOSurface2D(_renderContext, GL_TEXTURE_RECTANGLE_ARB, GL_RGBA, (GLsizei)size.width, (GLsizei)size.height, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, ioSurface, 0);
#else
    [_renderContext texImageIOSurface:ioSurface target:GL_TEXTURE_2D internalFormat:GL_RGBA width:(GLsizei)size.width height:(GLsizei)size.height format:GL_BGRA type:GL_UNSIGNED_BYTE plane:0];
#endif
#endif

#ifdef USE_EGL
    AsyncGLDrawable *drawable = [[AsyncGLDrawable alloc] initWithIOSurface:ioSurface screenColorTexture:screenColorTexture screenColorImage:screenColorImage];
#else
    AsyncGLDrawable *drawable = [[AsyncGLDrawable alloc] initWithIOSurface:ioSurface screenColorTexture:screenColorTexture];
#endif
    return drawable;
}

- (void)updateBuffersSize:(CGSize)size {
    if (CGSizeEqualToSize(_savedBufferSize, size))
        return;

    _savedBufferSize = size;

    GLsizei width = (GLsizei)size.width;
    GLsizei height = (GLsizei)size.height;

    NSArray *obsoleteDrawables = _availableDrawables;
    _availableDrawables = [NSMutableArray arrayWithCapacity:2];

    for (AsyncGLDrawable *drawable in obsoleteDrawables)
    {
        GLuint screenColorTexture = drawable.screenColorTexture;
        if (screenColorTexture != 0) {
            glDeleteTextures(1, &screenColorTexture);
        }

#ifdef USE_EGL
        EGLImageKHR screenColorImage = drawable.screenColorImage;
        if (screenColorImage != 0) {
            eglDestroyImageKHR(_display, &screenColorImage);
        }
#endif
    }

    dispatch_sync(dispatch_get_main_queue(), ^{
        id contents = self.layer.contents;
        if (contents != nil && CFGetTypeID((__bridge CFTypeRef)contents) == IOSurfaceGetTypeID()) {
            IOSurfaceRef surface = (__bridge IOSurfaceRef)contents;
            self.layer.contents = [[CIImage alloc] initWithIOSurface:surface];
        } else {
            self.layer.contents = nil;
        }
    });

    for (AsyncGLDrawable *drawable in obsoleteDrawables) {
        CFRelease(drawable.ioSurface);
    }

    for (NSUInteger i = 0; i < kDrawableCount; ++i)
    {
        [_availableDrawables addObject:[self createDrawable:size]];
    }

    if (_msaaEnabled) {
        if (_sampleFrameBuffer == 0)
            glGenFramebuffers(1, &_sampleFrameBuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, _sampleFrameBuffer);
        if (_sampleColorBuffer == 0)
            glGenRenderbuffers(1, &_sampleColorBuffer);
        if (_sampleDepthBuffer == 0)
            glGenRenderbuffers(1, &_sampleDepthBuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, _sampleColorBuffer);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, _sampleCount, GL_RGBA8, width, height);
        glBindRenderbuffer(GL_RENDERBUFFER, _sampleDepthBuffer);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, _sampleCount, GL_DEPTH_COMPONENT24, width, height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _sampleColorBuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _sampleDepthBuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, _screenFrameBuffer);
    } else {
        if (_screenDepthBuffer == 0)
            glGenRenderbuffers(1, &_screenDepthBuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, _screenDepthBuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, width, height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _screenDepthBuffer);
    }
}

#pragma mark - internal implementation
- (BOOL)setupGL:(CGSize)size {
    return [_delegate _prepareGL:size samples:(NSInteger)_sampleCount];
}

- (AsyncGLDrawable *)_drawGL:(CGSize)size
{
    [self updateBuffersSize:size];
    AsyncGLDrawable *drawable = [self bindNextDrawable];

    if (_msaaEnabled) {
        GLsizei width = (GLsizei)size.width;
        GLsizei height = (GLsizei)size.height;
        glBindFramebuffer(GL_FRAMEBUFFER, _sampleFrameBuffer);

        [_delegate _drawGL:size];

        glBindFramebuffer(GL_READ_FRAMEBUFFER, _sampleFrameBuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _screenFrameBuffer);

#if defined(USE_EGL)
        GLenum attachments[] = { GL_COLOR_ATTACHMENT0, GL_DEPTH_ATTACHMENT };
        glBlitFramebuffer(0, 0, width, height, 0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        if (_internalAPI == kEGLRenderingAPIOpenGLES3)
            glInvalidateFramebuffer(GL_READ_FRAMEBUFFER, 2, attachments);
#else
#if TARGET_OSX_OR_CATALYST || defined(USE_EGL)
        glBlitFramebuffer(0, 0, width, height, 0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
#else
        GLenum attachments[] = { GL_COLOR_ATTACHMENT0, GL_DEPTH_ATTACHMENT };
        if (_internalAPI == kEAGLRenderingAPIOpenGLES2) {
            glResolveMultisampleFramebufferAPPLE();
            glDiscardFramebufferEXT(GL_READ_FRAMEBUFFER, 2, attachments);
        } else {
            glBlitFramebuffer(0, 0, width, height, 0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
            glInvalidateFramebuffer(GL_READ_FRAMEBUFFER, 2, attachments);
        }
#endif
#endif
    } else {
        [_delegate _drawGL:size];
    }
    return drawable;
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
    });
}

- (void)clearResources {
    if (_sampleFrameBuffer != 0) {
        glDeleteFramebuffers(1, &_sampleFrameBuffer);
        _sampleFrameBuffer = 0;
    }

    if (_sampleDepthBuffer != 0) {
        glDeleteFramebuffers(1, &_sampleDepthBuffer);
        _sampleDepthBuffer = 0;
    }

    if (_sampleColorBuffer != 0) {
        glDeleteFramebuffers(1, &_sampleColorBuffer);
        _sampleColorBuffer = 0;
    }

    if (_screenFrameBuffer != 0) {
        glDeleteFramebuffers(1, &_screenFrameBuffer);
        _screenFrameBuffer = 0;
    }

    if (_screenDepthBuffer != 0) {
        glDeleteRenderbuffers(1, &_screenDepthBuffer);
        _screenDepthBuffer = 0;
    }

    NSArray *obsoleteDrawables = _availableDrawables;
    _availableDrawables = nil;

    for (AsyncGLDrawable *drawable in obsoleteDrawables)
    {
        GLuint screenColorTexture = drawable.screenColorTexture;
        if (screenColorTexture != 0) {
            glDeleteTextures(1, &screenColorTexture);
        }

#ifdef USE_EGL
        EGLImageKHR screenColorImage = drawable.screenColorImage;
        if (screenColorImage != 0) {
            eglDestroyImageKHR(_display, &screenColorImage);
        }
#endif
    }

    dispatch_sync(dispatch_get_main_queue(), ^{
        self.layer.contents = nil;
    });

    for (AsyncGLDrawable *drawable in obsoleteDrawables) {
        CFRelease(drawable.ioSurface);
    }
}

- (void)destroyRenderContext {
#ifdef USE_EGL
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
