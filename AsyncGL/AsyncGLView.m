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
@import QuartzCore.CAMetalLayer;
@import libGLESv2;
@import libEGL;
@import Metal;

#ifndef EGL_METAL_TEXTURE_ANGLE
#define EGL_METAL_TEXTURE_ANGLE             0x34A7
#endif

#ifndef GL_OES_EGL_image
typedef void *GLeglImageOES;
#endif
typedef void (GL_APIENTRY *AsyncGLEGLImageTargetTexture2DOESProc)(GLenum target, GLeglImageOES image);
typedef void (GL_APIENTRY *AsyncGLBindMetalRasterizationRateMapANGLEProc)(void *rateMap);

#if DEBUG
typedef void (GL_APIENTRY *AsyncGLDebugMessageCallbackKHRProc)(GLDEBUGPROCKHR callback, const void *userParam);
typedef void (GL_APIENTRY *AsyncGLDebugMessageControlKHRProc)(GLenum source, GLenum type, GLenum severity, GLsizei count, const GLuint *ids, GLboolean enabled);
#endif

/* EGL rendering API */
typedef enum EGLRenderingAPI : int
{
    kEGLRenderingAPIOpenGLES2 = 2,
    kEGLRenderingAPIOpenGLES3 = 3,
} EGLRenderingAPI;

#if DEBUG
static void GL_APIENTRY AsyncGLKHRDebugCallback(GLenum source,
                                                GLenum type,
                                                GLuint id,
                                                GLenum severity,
                                                GLsizei length,
                                                const GLchar *message,
                                                const void *userParam) {
    const char *sourceStr;
    switch (source) {
        case GL_DEBUG_SOURCE_API_KHR:             sourceStr = "API"; break;
        case GL_DEBUG_SOURCE_WINDOW_SYSTEM_KHR:   sourceStr = "WINDOW_SYSTEM"; break;
        case GL_DEBUG_SOURCE_SHADER_COMPILER_KHR: sourceStr = "SHADER_COMPILER"; break;
        case GL_DEBUG_SOURCE_THIRD_PARTY_KHR:     sourceStr = "THIRD_PARTY"; break;
        case GL_DEBUG_SOURCE_APPLICATION_KHR:     sourceStr = "APPLICATION"; break;
        case GL_DEBUG_SOURCE_OTHER_KHR:           sourceStr = "OTHER"; break;
        default:                                  sourceStr = "UNKNOWN"; break;
    }
    const char *typeStr;
    switch (type) {
        case GL_DEBUG_TYPE_ERROR_KHR:               typeStr = "ERROR"; break;
        case GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR_KHR: typeStr = "DEPRECATED"; break;
        case GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR_KHR:  typeStr = "UNDEFINED"; break;
        case GL_DEBUG_TYPE_PORTABILITY_KHR:         typeStr = "PORTABILITY"; break;
        case GL_DEBUG_TYPE_PERFORMANCE_KHR:         typeStr = "PERFORMANCE"; break;
        case GL_DEBUG_TYPE_MARKER_KHR:              typeStr = "MARKER"; break;
        case GL_DEBUG_TYPE_PUSH_GROUP_KHR:          typeStr = "PUSH_GROUP"; break;
        case GL_DEBUG_TYPE_POP_GROUP_KHR:           typeStr = "POP_GROUP"; break;
        case GL_DEBUG_TYPE_OTHER_KHR:               typeStr = "OTHER"; break;
        default:                                    typeStr = "UNKNOWN"; break;
    }
    const char *severityStr;
    switch (severity) {
        case GL_DEBUG_SEVERITY_HIGH_KHR:         severityStr = "HIGH"; break;
        case GL_DEBUG_SEVERITY_MEDIUM_KHR:       severityStr = "MEDIUM"; break;
        case GL_DEBUG_SEVERITY_LOW_KHR:          severityStr = "LOW"; break;
        case GL_DEBUG_SEVERITY_NOTIFICATION_KHR: severityStr = "NOTIFICATION"; break;
        default:                                 severityStr = "UNKNOWN"; break;
    }
    NSLog(@"[GL_KHR_debug] source=%s type=%s id=%u severity=%s: %.*s",
          sourceStr, typeStr, id, severityStr, (int)length, message);
}
#endif

#else
#if TARGET_OSX_OR_CATALYST
@import OpenGL.GL;
@import OpenGL.GL3;
#else
@import OpenGLES.ES2;
@import OpenGLES.ES3;
#endif
#endif

#ifndef USE_EGL
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
@property (nonatomic, strong) id<MTLDevice> metalDevice;
@property (nonatomic, strong) id<MTLCommandQueue> metalCommandQueue;
@property (nonatomic) EGLRenderingAPI internalAPI;
@property (nonatomic) EGLDisplay display;
@property (nonatomic) EGLConfig renderConfig;
@property (nonatomic) EGLContext renderContext;
@property (nonatomic, strong) id<MTLTexture> colorMTLTexture;
@property (nonatomic, strong) id<MTLRenderPipelineState> presentPipeline;
@property (nonatomic, strong) id<MTLRasterizationRateMap> rasterizationRateMap;
@property (nonatomic, strong) id<MTLBuffer> rasterizationRateMapParams;
@property (nonatomic) MTLSize rasterizationRatePhysicalSize;
@property (nonatomic) MTLSize rasterizationRateScreenSize;
@property (nonatomic) EGLImageKHR colorEGLImage;
@property (nonatomic) GLuint colorTexture;
@property (nonatomic) GLuint framebuffer;
@property (nonatomic) GLuint depthBuffer;
@property (nonatomic) GLuint sampleFramebuffer;
@property (nonatomic) GLuint sampleColorbuffer;
@property (nonatomic) GLuint sampleDepthbuffer;
@property (nonatomic) CGSize savedBufferSize;
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
    eglMakeCurrent(_display, EGL_NO_SURFACE, EGL_NO_SURFACE, _renderContext);
    glBindFramebuffer(GL_FRAMEBUFFER, _msaaEnabled ? _sampleFramebuffer : _framebuffer);
#else
#if !TARGET_OSX_OR_CATALYST
    [EAGLContext setCurrentContext:_renderContext];
    glBindFramebuffer(GL_FRAMEBUFFER, _msaaEnabled ? _sampleFramebuffer : _framebuffer);
#else
    CGLSetCurrentContext(_renderContext);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
#endif
#endif
}

- (void)prepareForDrawing:(void (NS_NOESCAPE ^)(void))draw resolve:(void (NS_NOESCAPE ^)(void))resolve {
    [self makeRenderContextCurrent];
    if (draw != nil)
        draw();
#ifdef USE_EGL
    if (_msaaEnabled) {
        GLint previousFramebuffer = 0;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previousFramebuffer);

        GLsizei width = (GLsizei)_savedBufferSize.width;
        GLsizei height = (GLsizei)_savedBufferSize.height;

        glBindFramebuffer(GL_READ_FRAMEBUFFER, _sampleFramebuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _framebuffer);
        glBlitFramebuffer(0, 0, width, height, 0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        GLenum attachments[] = { GL_COLOR_ATTACHMENT0, GL_DEPTH_ATTACHMENT };
        glInvalidateFramebuffer(GL_READ_FRAMEBUFFER, 2, attachments);
        glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
        if (resolve != nil)
            resolve();
        glBindFramebuffer(GL_FRAMEBUFFER, previousFramebuffer);
    } else {
        if (resolve != nil)
            resolve();
    }
#else
    if (_msaaEnabled) {
        // Save current framebuffer binding
        GLint previousFramebuffer = 0;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previousFramebuffer);

        GLsizei width = (GLsizei)_savedBufferSize.width;
        GLsizei height = (GLsizei)_savedBufferSize.height;
#if TARGET_OSX_OR_CATALYST
        // CAOpenGLLayer manages its own framebuffer, so here we need to create a framebuffer on our own
        GLuint tempFramebuffer;
        GLuint tempRenderbuffer;
        glGenFramebuffers(1, &tempFramebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, tempFramebuffer);
        glGenRenderbuffers(1, &tempRenderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, tempRenderbuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, width, height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, tempRenderbuffer);

        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            NSLog(@"framebuffer not complete %d", status);
        } else {
            glBindFramebuffer(GL_READ_FRAMEBUFFER, _framebuffer);
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, tempFramebuffer);
            glBlitFramebuffer(0, 0, width, height, 0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
            glBindFramebuffer(GL_FRAMEBUFFER, tempFramebuffer);
            if (resolve != nil)
                resolve();
        }
        glDeleteFramebuffers(1, &tempFramebuffer);
        glDeleteRenderbuffers(1, &tempRenderbuffer);
#else
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
        glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
        if (resolve != nil)
            resolve();
#endif

        // Restore previous framebuffer binding
        glBindFramebuffer(GL_FRAMEBUFFER, previousFramebuffer);
    } else {
        if (resolve != nil)
            resolve();
    }
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
        [self _presentToMetalLayer:size];
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
    _renderContext = EGL_NO_CONTEXT;
    _colorMTLTexture = nil;
    _rasterizationRateMap = nil;
    _rasterizationRateMapParams = nil;
    _colorEGLImage = EGL_NO_IMAGE_KHR;
    _colorTexture = 0;
    _framebuffer = 0;
    _depthBuffer = 0;
    _sampleFramebuffer = 0;
    _sampleColorbuffer = 0;
    _sampleDepthbuffer = 0;
    _savedBufferSize = CGSizeZero;
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
    _metalDevice = MTLCreateSystemDefaultDevice();
    _metalCommandQueue = [_metalDevice newCommandQueue];
    _metalLayer.device = _metalDevice;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalLayer.framebufferOnly = YES;
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
    EGLint attribs[] = {
        EGL_RENDERABLE_TYPE, api == kEGLRenderingAPIOpenGLES3 ? EGL_OPENGL_ES3_BIT : EGL_OPENGL_ES2_BIT,
        EGL_BLUE_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_RED_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, depthSize,
        EGL_NONE
    };

    EGLConfig configs[64];
    EGLint numConfigs;
    EGLint format;

    if (!eglChooseConfig(display, attribs, configs, sizeof(configs) / sizeof(EGLConfig), &numConfigs)) {
        NSLog(@"eglChooseConfig() returned error %d", eglGetError());
        return EGL_NO_CONTEXT;
    }

    for (EGLint i = 0; i < numConfigs; ++i) {
        if (eglGetConfigAttrib(display, configs[i], EGL_NATIVE_VISUAL_ID, &format)) {
            *config = configs[i];
            break;
        } else {
            NSLog(@"eglGetConfigAttrib() returned error %d", eglGetError());
        }
    }

    if (*config == EGL_NO_CONTEXT) {
        NSLog(@"No suitable EGLConfig found");
        return EGL_NO_CONTEXT;
    }

    // Init context
    int ctxMajorVersion = 2;
    int ctxMinorVersion = 0;
    switch (api)
    {
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
    EGLint ctxAttribs[] = {
        EGL_CONTEXT_MAJOR_VERSION, ctxMajorVersion,
        EGL_CONTEXT_MINOR_VERSION, ctxMinorVersion,
#if DEBUG
        EGL_CONTEXT_FLAGS_KHR, EGL_CONTEXT_OPENGL_DEBUG_BIT_KHR,
#endif
        EGL_NONE,
    };

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

    _renderContext = [self createEGLContextWithDisplay:_display api:_internalAPI sharedContext:EGL_NO_CONTEXT config:&_renderConfig depthSize:24 msaa:&_msaaEnabled];

    if (_renderContext == EGL_NO_CONTEXT)
        return NO;

    // ANGLE supports EGL_KHR_surfaceless_context, so no EGLSurface is needed.
    if (!eglMakeCurrent(_display, EGL_NO_SURFACE, EGL_NO_SURFACE, _renderContext)) {
        NSLog(@"eglMakeCurrent() returned error %d", eglGetError());
        return NO;
    }

    if (_msaaEnabled) {
        GLint numSamples = 0;
        glGetIntegerv(GL_MAX_SAMPLES, &numSamples);
        if (numSamples > 1)
            _sampleCount = MIN(numSamples, 4);
        else
            _msaaEnabled = NO;
    }

#if DEBUG
    const char *extensions = (const char *)glGetString(GL_EXTENSIONS);
    if (extensions != NULL && strstr(extensions, "GL_KHR_debug") != NULL) {
        AsyncGLDebugMessageCallbackKHRProc debugMessageCallback = (AsyncGLDebugMessageCallbackKHRProc)eglGetProcAddress("glDebugMessageCallbackKHR");
        AsyncGLDebugMessageControlKHRProc debugMessageControl = (AsyncGLDebugMessageControlKHRProc)eglGetProcAddress("glDebugMessageControlKHR");
        if (debugMessageCallback != NULL) {
            glEnable(GL_DEBUG_OUTPUT_KHR);
            glEnable(GL_DEBUG_OUTPUT_SYNCHRONOUS_KHR);
            debugMessageCallback(AsyncGLKHRDebugCallback, NULL);
            if (debugMessageControl != NULL)
                debugMessageControl(GL_DONT_CARE, GL_DONT_CARE, GL_DONT_CARE, 0, NULL, GL_TRUE);
        }
    }
#endif

    __block CGSize size;
    dispatch_sync(dispatch_get_main_queue(), ^{
        CGSize frameSize = self.frame.size;
        CGFloat scale = self.layer.contentsScale;
        size = CGSizeMake(frameSize.width * scale, frameSize.height * scale);
    });

    return [self createRenderBuffers:size];
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
    [_mainContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:_eaglLayer];
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

#ifdef USE_EGL
#pragma mark - MTLTexture / offscreen FBO

- (BOOL)createRenderBuffers:(CGSize)size {
    glGenFramebuffers(1, &_framebuffer);
    glGenTextures(1, &_colorTexture);

    if (_msaaEnabled) {
        glGenFramebuffers(1, &_sampleFramebuffer);
        glGenRenderbuffers(1, &_sampleColorbuffer);
        glGenRenderbuffers(1, &_sampleDepthbuffer);
    } else {
        glGenRenderbuffers(1, &_depthBuffer);
    }

    return [self _updateEGLBuffersSize:size];
}

- (BOOL)_createMetalBackingForSize:(CGSize)size {
    NSUInteger screenWidth = (NSUInteger)size.width;
    NSUInteger screenHeight = (NSUInteger)size.height;

    // Tear down any previously imported texture.
    if (_colorEGLImage != EGL_NO_IMAGE_KHR) {
        eglDestroyImageKHR(_display, _colorEGLImage);
        _colorEGLImage = EGL_NO_IMAGE_KHR;
    }
    _colorMTLTexture = nil;
    _rasterizationRateMap = nil;
    _rasterizationRateMapParams = nil;
    _rasterizationRateScreenSize   = MTLSizeMake(screenWidth, screenHeight, 0);
    _rasterizationRatePhysicalSize = MTLSizeMake(screenWidth, screenHeight, 0);

    // Build a foveated MTLRasterizationRateMap first so we can size the GL
    // color/depth attachments at the *physical* (compressed) resolution that
    // ANGLE will actually rasterize at.
    if (@available(macOS 10.15.4, macCatalyst 13.4, iOS 13.0, *)) {
        const NSUInteger zoneCount = 8;
        if ([_metalDevice supportsRasterizationRateMapWithLayerCount:1]) {
            MTLRasterizationRateLayerDescriptor *layer =
                [[MTLRasterizationRateLayerDescriptor alloc] initWithSampleCount:MTLSizeMake(zoneCount, zoneCount, 1)];
            // Bell-shaped rate profile, peaking at 1.0 in the center and
            // falling to ~0.25 at the edges. Same profile horizontally and
            // vertically.
            for (NSUInteger i = 0; i < zoneCount; i++) {
                double t = ((double)i + 0.5) / (double)zoneCount;
                double d = (t - 0.5) * 2.0;
                double rate = 1.0 - 0.75 * (d * d);
                layer.horizontalSampleStorage[i] = (float)rate;
                layer.verticalSampleStorage[i]   = (float)rate;
            }

            MTLRasterizationRateMapDescriptor *rateDesc =
                [MTLRasterizationRateMapDescriptor rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(screenWidth, screenHeight, 0)
                                                                                          layer:layer];
            rateDesc.label = @"AsyncGL foveated rate map";

            _rasterizationRateMap = [_metalDevice newRasterizationRateMapWithDescriptor:rateDesc];

            if (_rasterizationRateMap != nil) {
                _rasterizationRateScreenSize   = [_rasterizationRateMap screenSize];
                _rasterizationRatePhysicalSize = [_rasterizationRateMap physicalSizeForLayer:0];

                MTLSizeAndAlign paramSizeAlign = [_rasterizationRateMap parameterBufferSizeAndAlign];
                _rasterizationRateMapParams =
                    [_metalDevice newBufferWithLength:paramSizeAlign.size
                                              options:MTLResourceStorageModeShared];
                [_rasterizationRateMap copyParameterDataToBuffer:_rasterizationRateMapParams offset:0];
            }
        }
    }

    NSUInteger physicalWidth  = _rasterizationRatePhysicalSize.width;
    NSUInteger physicalHeight = _rasterizationRatePhysicalSize.height;

    // ANGLE's Metal backend renders GL_RGBA8 into MTLPixelFormatRGBA8Unorm.
    // Use default usage/storage; overriding usage to MTLTextureUsageRenderTarget
    // causes ANGLE to fall back to an internal RT. Size the texture at the
    // rate-map physical resolution.
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                    width:physicalWidth
                                                                                   height:physicalHeight
                                                                                mipmapped:NO];
    _colorMTLTexture = [_metalDevice newTextureWithDescriptor:desc];
    if (_colorMTLTexture == nil) {
        NSLog(@"newTextureWithDescriptor: failed");
        return NO;
    }

    // Import the MTLTexture into GL via EGL_ANGLE_metal_texture_client_buffer.
    const EGLint imageAttribs[] = { EGL_NONE };
    _colorEGLImage = eglCreateImageKHR(_display, EGL_NO_CONTEXT,
                                       EGL_METAL_TEXTURE_ANGLE,
                                       (__bridge EGLClientBuffer)_colorMTLTexture,
                                       imageAttribs);
    if (_colorEGLImage == EGL_NO_IMAGE_KHR) {
        NSLog(@"eglCreateImageKHR() returned error %d", eglGetError());
        return NO;
    }

    // Bind the EGLImage to a GL_TEXTURE_2D so it can be used as a color attachment.
    static AsyncGLEGLImageTargetTexture2DOESProc imageTargetTexture2D = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        imageTargetTexture2D = (AsyncGLEGLImageTargetTexture2DOESProc)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    });
    if (imageTargetTexture2D == NULL) {
        NSLog(@"glEGLImageTargetTexture2DOES not available");
        return NO;
    }

    glBindTexture(GL_TEXTURE_2D, _colorTexture);
    imageTargetTexture2D(GL_TEXTURE_2D, (GLeglImageOES)_colorEGLImage);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    // Bind the rate map to ANGLE so subsequent draws are foveated.
    if (_rasterizationRateMap != nil) {
        static AsyncGLBindMetalRasterizationRateMapANGLEProc bindRateMap = NULL;
        static dispatch_once_t rateMapOnce;
        dispatch_once(&rateMapOnce, ^{
            bindRateMap = (AsyncGLBindMetalRasterizationRateMapANGLEProc)eglGetProcAddress("glBindMetalRasterizationRateMapANGLE");
        });
        if (bindRateMap != NULL) {
            bindRateMap((__bridge void *)_rasterizationRateMap);
            glEnable(GL_VARIABLE_RASTERIZATION_RATE_ANGLE);
        } else {
            glDisable(GL_VARIABLE_RASTERIZATION_RATE_ANGLE);
        }
    } else {
        glDisable(GL_VARIABLE_RASTERIZATION_RATE_ANGLE);
    }

    return YES;
}

- (BOOL)_updateEGLBuffersSize:(CGSize)size {
    if (CGSizeEqualToSize(_savedBufferSize, size))
        return YES;

    _savedBufferSize = size;

    GLsizei screenWidth = (GLsizei)size.width;
    GLsizei screenHeight = (GLsizei)size.height;

    if (screenWidth <= 0 || screenHeight <= 0)
        return YES;

    if (![self _createMetalBackingForSize:size])
        return NO;

    // GL renders into the rate-map *physical* extents; the drawable still
    // matches the screen (logical) size.
    GLsizei width  = (GLsizei)_rasterizationRatePhysicalSize.width;
    GLsizei height = (GLsizei)_rasterizationRatePhysicalSize.height;

    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _colorTexture, 0);

    if (_msaaEnabled) {
        glBindRenderbuffer(GL_RENDERBUFFER, _sampleColorbuffer);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, _sampleCount, GL_RGBA8, width, height);
        glBindRenderbuffer(GL_RENDERBUFFER, _sampleDepthbuffer);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, _sampleCount, GL_DEPTH_COMPONENT24, width, height);

        glBindFramebuffer(GL_FRAMEBUFFER, _sampleFramebuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _sampleColorbuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _sampleDepthbuffer);

        GLenum sampleStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (sampleStatus != GL_FRAMEBUFFER_COMPLETE) {
            NSLog(@"sample framebuffer not complete %d", sampleStatus);
            return NO;
        }
    } else {
        glBindRenderbuffer(GL_RENDERBUFFER, _depthBuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, width, height);
        glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _depthBuffer);
    }

    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"framebuffer not complete %d", status);
        return NO;
    }

    glBindFramebuffer(GL_FRAMEBUFFER, _msaaEnabled ? _sampleFramebuffer : _framebuffer);

    CGSize drawableSize = CGSizeMake(screenWidth, screenHeight);
    dispatch_sync(dispatch_get_main_queue(), ^{
        self->_metalLayer.drawableSize = drawableSize;
    });

    if (!_contextsCreated)
        return [self setupGL:size];
    return YES;
}

- (BOOL)_ensurePresentPipelineForPixelFormat:(MTLPixelFormat)pixelFormat {
    if (_presentPipeline != nil)
        return YES;

    // The fragment shader samples the ANGLE-rendered texture. ANGLE drew the
    // image with the bound MTLRasterizationRateMap, so the pixels are laid out
    // in *physical* (compressed) coordinates. To present, we walk the drawable
    // in screen-space UV and use rasterization_rate_map_decoder to translate
    // each screen-space coordinate to the corresponding physical sample.
    // Reference: https://developer.apple.com/documentation/metal/scaling-variable-rasterization-rate-content
    NSString *source = @"#include <metal_stdlib>\n"
                       "using namespace metal;\n"
                       "struct AGLOut { float4 position [[position]]; float2 uv; };\n"
                       "struct AGLPresentParams {\n"
                       "    float2 screenSize;\n"
                       "    float2 physicalSize;\n"
                       "    uint   useRateMap;\n"
                       "};\n"
                       "vertex AGLOut asyncgl_present_vs(uint vid [[vertex_id]]) {\n"
                       "    float2 pos[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
                       "    float2 uv[4]  = { float2(0,0),   float2(1,0),  float2(0,1),  float2(1,1) };\n"
                       "    AGLOut o;\n"
                       "    o.position = float4(pos[vid], 0.0, 1.0);\n"
                       "    o.uv = uv[vid];\n"
                       "    return o;\n"
                       "}\n"
                       "fragment float4 asyncgl_present_fs(AGLOut in [[stage_in]],\n"
                       "                                   texture2d<float> tex [[texture(0)]],\n"
                       "                                   constant AGLPresentParams &params [[buffer(0)]],\n"
                       "                                   constant rasterization_rate_map_data &rateData [[buffer(1)]]) {\n"
                       "    constexpr sampler s(mag_filter::linear, min_filter::linear);\n"
                       "    float2 sampleUV;\n"
                       "    if (params.useRateMap != 0u) {\n"
                       "        rasterization_rate_map_decoder decoder(rateData);\n"
                       "        float2 screenCoord = in.uv * params.screenSize;\n"
                       "        float2 physicalCoord = decoder.map_screen_to_physical_coordinates(screenCoord);\n"
                       "        sampleUV = physicalCoord / params.physicalSize;\n"
                       "    } else {\n"
                       "        sampleUV = in.uv;\n"
                       "    }\n"
                       "    return tex.sample(s, sampleUV);\n"
                       "}\n";

    NSError *error = nil;
    id<MTLLibrary> library = [_metalDevice newLibraryWithSource:source options:nil error:&error];
    if (library == nil) {
        NSLog(@"newLibraryWithSource failed: %@", error);
        return NO;
    }

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [library newFunctionWithName:@"asyncgl_present_vs"];
    desc.fragmentFunction = [library newFunctionWithName:@"asyncgl_present_fs"];
    desc.colorAttachments[0].pixelFormat = pixelFormat;

    _presentPipeline = [_metalDevice newRenderPipelineStateWithDescriptor:desc error:&error];
    if (_presentPipeline == nil) {
        NSLog(@"newRenderPipelineStateWithDescriptor failed: %@", error);
        return NO;
    }
    return YES;
}

- (void)_presentToMetalLayer:(CGSize)size {
    if (_colorMTLTexture == nil)
        return;

    // Ensure all GL/ANGLE writes to the imported MTLTexture are completed before
    // Metal samples it on a different command queue.
    glFlush();
    glFinish();

    id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
    if (drawable == nil)
        return;

    if (![self _ensurePresentPipelineForPixelFormat:drawable.texture.pixelFormat])
        return;

    MTLRenderPassDescriptor *renderPass = [MTLRenderPassDescriptor renderPassDescriptor];
    renderPass.colorAttachments[0].texture = drawable.texture;
    renderPass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;

    struct {
        float screenSize[2];
        float physicalSize[2];
        uint32_t useRateMap;
        uint32_t _pad[3];
    } params = {0};

    BOOL useRateMap = (_rasterizationRateMap != nil && _rasterizationRateMapParams != nil);
    if (useRateMap) {
        params.screenSize[0]   = (float)_rasterizationRateScreenSize.width;
        params.screenSize[1]   = (float)_rasterizationRateScreenSize.height;
        params.physicalSize[0] = (float)_rasterizationRatePhysicalSize.width;
        params.physicalSize[1] = (float)_rasterizationRatePhysicalSize.height;
        params.useRateMap = 1;
    } else {
        params.useRateMap = 0;
    }

    id<MTLCommandBuffer> commandBuffer = [_metalCommandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPass];
    [encoder setRenderPipelineState:_presentPipeline];
    [encoder setFragmentTexture:_colorMTLTexture atIndex:0];
    [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
    if (useRateMap) {
        [encoder setFragmentBuffer:_rasterizationRateMapParams offset:0 atIndex:1];
    } else {
        // Bind a tiny placeholder so Metal's resource validation passes even
        // though the shader skips reading rateData when useRateMap == 0.
        uint8_t placeholder[16] = {0};
        [encoder setFragmentBytes:placeholder length:sizeof(placeholder) atIndex:1];
    }
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}
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
#endif
}

#pragma mark - internal implementation
- (BOOL)setupGL:(CGSize)size {
    return [_delegate _prepareGL:size samples:(NSInteger)_sampleCount];
}

- (void)_drawGL:(CGSize)size
{
#ifdef USE_EGL
    [self _updateEGLBuffersSize:size];
#else
    [self updateBuffersSize:size];
#endif

#ifdef USE_EGL
    CGSize physicalSize = CGSizeMake((CGFloat)_rasterizationRatePhysicalSize.width,
                                     (CGFloat)_rasterizationRatePhysicalSize.height);
    if (physicalSize.width <= 0 || physicalSize.height <= 0)
        physicalSize = size;
#else
    CGSize physicalSize = size;
#endif

#if TARGET_OSX_OR_CATALYST
    [_delegate _drawGL:size physicalSize:physicalSize];
#elif defined(USE_EGL)
    if (_msaaEnabled) {
        GLsizei width  = (GLsizei)_rasterizationRatePhysicalSize.width;
        GLsizei height = (GLsizei)_rasterizationRatePhysicalSize.height;
        glBindFramebuffer(GL_FRAMEBUFFER, _sampleFramebuffer);

        [_delegate _drawGL:size physicalSize:physicalSize];

        glBindFramebuffer(GL_READ_FRAMEBUFFER, _sampleFramebuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _framebuffer);
        glBlitFramebuffer(0, 0, width, height, 0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        GLenum attachments[] = { GL_COLOR_ATTACHMENT0, GL_DEPTH_ATTACHMENT };
        glInvalidateFramebuffer(GL_READ_FRAMEBUFFER, 2, attachments);
    } else {
        glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
        [_delegate _drawGL:size physicalSize:physicalSize];
    }
#else
    if (_msaaEnabled) {
        GLsizei width = (GLsizei)size.width;
        GLsizei height = (GLsizei)size.height;
        glBindFramebuffer(GL_FRAMEBUFFER, _sampleFramebuffer);

        [_delegate _drawGL:size physicalSize:physicalSize];

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
        [_delegate _drawGL:size physicalSize:physicalSize];
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
#ifdef USE_EGL
    if (_sampleFramebuffer != 0) {
        glDeleteFramebuffers(1, &_sampleFramebuffer);
        _sampleFramebuffer = 0;
    }
    if (_sampleColorbuffer != 0) {
        glDeleteRenderbuffers(1, &_sampleColorbuffer);
        _sampleColorbuffer = 0;
    }
    if (_sampleDepthbuffer != 0) {
        glDeleteRenderbuffers(1, &_sampleDepthbuffer);
        _sampleDepthbuffer = 0;
    }
    if (_depthBuffer != 0) {
        glDeleteRenderbuffers(1, &_depthBuffer);
        _depthBuffer = 0;
    }
    if (_framebuffer != 0) {
        glDeleteFramebuffers(1, &_framebuffer);
        _framebuffer = 0;
    }
    if (_colorTexture != 0) {
        glDeleteTextures(1, &_colorTexture);
        _colorTexture = 0;
    }
    if (_colorEGLImage != EGL_NO_IMAGE_KHR) {
        eglDestroyImageKHR(_display, _colorEGLImage);
        _colorEGLImage = EGL_NO_IMAGE_KHR;
    }
    _colorMTLTexture = nil;
    _rasterizationRateMap = nil;
    _rasterizationRateMapParams = nil;
#else
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
