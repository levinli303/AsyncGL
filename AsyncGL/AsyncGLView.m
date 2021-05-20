//
//  Copyright (c) Levin Li. All rights reserved.
//  Licensed under the MIT License.
//

#import "AsyncGLView+Private.h"

#if TARGET_OS_MACCATALYST
#ifndef USE_EGL
#define USE_EGL
#endif
#endif

#ifdef USE_EGL
#define GL_GLEXT_PROTOTYPES
#define GL_EXT_texture_border_clamp 0
#define GL_EXT_separate_shader_objects 0
#if TARGET_OS_OSX
@import QuartzCore.CAMetalLayer
#endif
#include "GLES2/gl2.h"
#include "GLES2/gl2ext.h"
#include "GLES3/gl3.h"
#include "EGL/egl.h"
#include "EGL/eglext.h"

/* EGL rendering API */
typedef enum EGLRenderingAPI : int
{
    kEGLRenderingAPIOpenGLES1 = 1,
    kEGLRenderingAPIOpenGLES2 = 2,
    kEGLRenderingAPIOpenGLES3 = 3,
} EGLRenderingAPI;

#else
#if TARGET_OS_IOS
@import OpenGLES.ES2;
@import OpenGLES.ES3;
#else
@import OpenGL.GL;
#endif
#endif

#ifndef USE_EGL
#if TARGET_OS_OSX
@interface PassthroughGLLayer : CAOpenGLLayer
@property (nonatomic) NSOpenGLContext *renderContext;
@property (nonatomic) NSOpenGLPixelFormat *pixelFormat;
@property (nonatomic) GLuint renderTex;
@property (nonatomic) GLuint renderProg;
@property (nonatomic) GLuint renderVShader;
@property (nonatomic) GLuint renderFShader;
@property (nonatomic) GLint renderProgTexLocation;
@property (nonatomic) GLint renderProgPositionLocation;
@property (nonatomic) GLint renderProgTexPositionLocation;
@property (nonatomic) GLuint renderProgVboId;
@property (nonatomic) GLsizei width;
@property (nonatomic) GLsizei height;
@end

@implementation PassthroughGLLayer
- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:(uint32_t)mask
{
    return _pixelFormat.CGLPixelFormatObj;
}

- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)pf
{
    return _renderContext.CGLContextObj;
}

- (BOOL)canDrawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)ts
{
    return ![NSThread isMainThread];
}

- (void)drawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)ts
{
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    glDisable(GL_DEPTH_TEST);

    glUseProgram(_renderProg);

    glEnableVertexAttribArray(_renderProgTexPositionLocation);
    glEnableVertexAttribArray(_renderProgPositionLocation);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, _renderTex);
    glUniform1i(_renderProgTexLocation, 0);

    glBindBuffer(GL_ARRAY_BUFFER, _renderProgVboId);
    glVertexAttribPointer(_renderProgPositionLocation, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), NULL);
    glVertexAttribPointer(_renderProgTexPositionLocation, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(2 * sizeof(float)));

    glDrawArrays(GL_TRIANGLES, 0, 6);

    glDisableVertexAttribArray(_renderProgTexPositionLocation);
    glDisableVertexAttribArray(_renderProgPositionLocation);

    glFlush();
}

- (void)clear
{
    if (_renderTex) {
        glDeleteTextures(1, &_renderTex);
        _renderTex = 0;
    }

    if (_renderProgVboId != 0) {
        glDeleteBuffers(1, &_renderProgVboId);
        _renderProgVboId = 0;
    }

    if (_renderProg != 0) {
        glDeleteProgram(_renderProg);
        _renderProg = 0;
    }

    if (_renderVShader != 0) {
        glDeleteShader(_renderVShader);
        _renderVShader = 0;
    }

    if (_renderFShader != 0) {
        glDeleteShader(_renderFShader);
        _renderFShader = 0;
    }
}
@end
#endif
#endif

@interface AsyncGLView ()
{
    BOOL _msaaEnabled;
}

@property (nonatomic) BOOL contextsCreated;
#ifdef USE_EGL
@property (nonatomic) CAMetalLayer *metalLayer;
@property (nonatomic) EGLRenderingAPI api;
@property (nonatomic) EGLDisplay display;
@property (nonatomic) EGLSurface renderSurface;
@property (nonatomic) EGLConfig renderConfig;
@property (nonatomic) EGLContext renderContext;
#else
@property (nonatomic) GLuint framebuffer;
@property (nonatomic) GLuint depthBuffer;
@property (nonatomic) GLuint sampleFramebuffer;
@property (nonatomic) GLuint sampleDepthbuffer;
@property (nonatomic) GLuint sampleRenderbuffer;
@property (nonatomic) CGSize savedBufferSize;
#if TARGET_OS_IOS
@property (nonatomic) EAGLRenderingAPI api;
@property (nonatomic, strong) EAGLContext *renderContext;
@property (nonatomic, strong) EAGLContext *mainContext;
@property (nonatomic) GLuint renderbuffer;
#else
@property (nonatomic, strong) NSOpenGLContext *mainContext;
@property (nonatomic, strong) NSOpenGLContext *renderContext;
@property (nonatomic, strong) PassthroughGLLayer *glLayer;
#endif
#endif

#if TARGET_OS_IOS
@property (nonatomic) CADisplayLink *viewStateChecker;
#else
@property (nonatomic) CVDisplayLinkRef viewStateChecker;
#endif
@property (nonatomic) CGSize drawableSize;
@property (atomic) BOOL isUpdatingSize;
@property (atomic, getter=isPaused) BOOL paused;
@property (atomic) BOOL canRender;
@property (atomic) BOOL shouldRender;
@end

@implementation AsyncGLView

#if TARGET_OS_IOS
+ (Class)layerClass
{
#ifdef USE_EGL
    return [CAMetalLayer class];
#else
    return [CAEAGLLayer class];
#endif
}
#else
- (CALayer *)makeBackingLayer
{
#ifdef USE_EGL
    return [CAMetalLayer layer];
#else
    PassthroughGLLayer *layer = [[PassthroughGLLayer alloc] init];
    layer.backgroundColor = [[NSColor blackColor] CGColor];
    layer.asynchronous = YES;
    return layer;
#endif
}
#endif

#pragma mark - lifecycle/ui

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        [self commonSetup];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        [self commonSetup];
    }
    return self;
}

#if TARGET_OS_IOS
- (void)willMoveToWindow:(UIWindow *)newWindow
{
    [super willMoveToWindow:newWindow];

    if (newWindow && !_contextsCreated) {
        _contextsCreated = YES;
        [self createContexts];
    }
}
#else
- (void)viewWillMoveToWindow:(NSWindow *)newWindow
{
    [super viewWillMoveToWindow:newWindow];

    if (newWindow && !_contextsCreated) {
        _contextsCreated = YES;
        [self createContexts];
    }
}
#endif

- (void)pause
{
    [self setPaused:YES];
    [self setShouldRender:NO];
#ifndef USE_EGL
#if TARGET_OS_IOS
    [self makeMainContextCurrent];
    [self flush];
#endif
#endif

    dispatch_sync(_renderQueue, ^{
        [self makeRenderContextCurrent];
        [self flush];
    });

    [self pauseViewStateChecker];
}

- (void)resume
{
    _paused = NO;

    [self resumeViewStateChecker];
}

#pragma mark - properties
- (void)setMsaaEnabled:(BOOL)msaaEnabled
{
    if (!_contextsCreated)
        _msaaEnabled = msaaEnabled;
}

- (BOOL)msaaEnabled {
    return _msaaEnabled;
}


#pragma mark - interfaces
- (void)makeRenderContextCurrent
{
#ifdef USE_EGL
    eglMakeCurrent(_display, _renderSurface, _renderSurface, _renderContext);
#else
#if TARGET_OS_IOS
    [EAGLContext setCurrentContext:_renderContext];
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
#else
    [_renderContext makeCurrentContext];
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
#endif
#endif
}

- (void)flush
{
    glFlush();
}

- (void)clear
{
    [self clearGL];
}

- (void)render
{
    if (![self shouldRender] || [self isUpdatingSize]) return;

    CGFloat width = _drawableSize.width;
    CGFloat height = _drawableSize.height;

    [self makeRenderContextCurrent];
    [self _drawGL:CGSizeMake(width, height)];
#ifdef USE_EGL
    eglSwapBuffers(_display, _renderSurface);
#else
    [self flush];
#if TARGET_OS_IOS
    glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffer);
    [_renderContext presentRenderbuffer:_renderbuffer];
#else
    [_glLayer display];
#endif
#endif
}

#if TARGET_OS_OSX
static CVReturn displayCallback(CVDisplayLinkRef displayLink,
    const CVTimeStamp *inNow, const CVTimeStamp *inOutputTime,
    CVOptionFlags flagsIn, CVOptionFlags *flagsOut,
    void *displayLinkContext)
{
    AsyncGLView *view = (__bridge AsyncGLView *)displayLinkContext;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view checkViewState];
    });
    return kCVReturnSuccess;
}
#endif

#pragma mark - private methods
- (void)commonSetup
{
    _drawableSize = CGSizeZero;
    _paused = YES;
    _canRender = YES;
    _shouldRender = NO;
    _contextsCreated = NO;
    _msaaEnabled = NO;
    _isUpdatingSize = NO;
#ifdef USE_EGL
    _api = kEGLRenderingAPIOpenGLES2;
    _display = EGL_NO_DISPLAY;
    _renderSurface = EGL_NO_SURFACE;
    _renderContext = EGL_NO_CONTEXT;
#else
#if TARGET_OS_IOS
    _api = kEAGLRenderingAPIOpenGLES2;
    _mainContext = nil;
    _renderContext = nil;
    _renderbuffer = 0;
#else
    _renderContext = nil;
#endif
    _framebuffer = 0;
    _depthBuffer = 0;
    _sampleFramebuffer = 0;
    _sampleDepthbuffer = 0;
    _sampleRenderbuffer = 0;
    _savedBufferSize = CGSizeZero;
#endif

    _renderQueue = dispatch_queue_create("AsyncGLRenderQueue", DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(_renderQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));

#if TARGET_OS_OSX
    self.wantsLayer = YES;
#endif
    self.layer.opaque = YES;

#ifdef USE_EGL
    _metalLayer = (CAMetalLayer *)self.layer;
#else
#if TARGET_OS_OSX
    _glLayer = (PassthroughGLLayer *)self.layer;
#endif
#endif

#if TARGET_OS_IOS
    _viewStateChecker = [CADisplayLink displayLinkWithTarget:self selector:@selector(checkViewState)];
#else
    CVDisplayLinkCreateWithActiveCGDisplays(&_viewStateChecker);
    CVDisplayLinkSetOutputCallback(_viewStateChecker, displayCallback, (__bridge void *)(self));
#endif
}

#pragma mark - context creation
#ifdef USE_EGL
- (EGLContext)createEGLContextWithDisplay:(EGLDisplay)display api:(EGLRenderingAPI)api sharedContext:(EGLContext)sharedContext config:(EGLConfig*)config depthSize:(EGLint)depthSize msaa:(BOOL)msaa
{
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
    if (msaa) {
        // Try to enable multisample but fallback if not available
        if (!eglChooseConfig(display, multisampleAttribs, config, 1, &numConfigs) && !eglChooseConfig(display, attribs, config, 1, &numConfigs)) {
            NSLog(@"eglChooseConfig() returned error %d", eglGetError());
            return EGL_NO_CONTEXT;
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

- (void)createContexts
{
#ifdef USE_EGL
    dispatch_async(_renderQueue, ^{
        [self createRenderContext];
    });
#else
#if TARGET_OS_IOS
    _mainContext = [[EAGLContext alloc] initWithAPI:_api];
    if (_mainContext == nil) {
        [self setCanRender:NO];
        return;
    }
    dispatch_async(_renderQueue, ^{
        [self createRenderContext];
    });
#else
    const NSOpenGLPixelFormatAttribute attr[] = {
        NSOpenGLPFADoubleBuffer, 0
    };
    NSOpenGLPixelFormat *pixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes:attr];
    if (!pixelFormat) {
        [self setCanRender:NO];
        return;
    }
    _mainContext = [[NSOpenGLContext alloc] initWithFormat:pixelFormat shareContext:nil];
    _glLayer.pixelFormat = pixelFormat;
    _glLayer.renderContext = _mainContext;
    if (!_mainContext) {
        [self setCanRender:NO];
        return;
    }
    dispatch_async(_renderQueue, ^{
        [self createRenderContext];
    });
#endif
#endif
}

- (void)createRenderContext
{
#ifdef USE_EGL
    EGLAttrib displayAttribs[] = { EGL_NONE };
    _display = eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, NULL, displayAttribs);
    if (_display == EGL_NO_DISPLAY) {
        [self setCanRender:NO];
        NSLog(@"eglGetPlatformDisplay() returned error %d", eglGetError());
        return;
    }

    if (!eglInitialize(_display, NULL, NULL)) {
        [self setCanRender:NO];
        NSLog(@"eglInitialize() returned error %d", eglGetError());
        return;
    }

    eglSwapInterval(_display, 0);

    _renderContext = [self createEGLContextWithDisplay:_display api:_api sharedContext:EGL_NO_CONTEXT config:&_renderConfig depthSize:24 msaa:_msaaEnabled];

    if (_renderContext == EGL_NO_CONTEXT) {
        [self setCanRender:NO];
        return;
    }

    _renderSurface = eglCreateWindowSurface(_display, _renderConfig, (__bridge EGLNativeWindowType)(_metalLayer), NULL);

    if (_renderSurface == EGL_NO_SURFACE) {
        [self setCanRender:NO];
        NSLog(@"eglCreateWindowSurface() returned error %d", eglGetError());
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect rect = self.frame;
        [self resumeViewStateChecker];
        self.paused = NO;
        dispatch_async(self.renderQueue, ^{
            [self makeRenderContextCurrent];
            [self setupGL:rect.size];
        });
    });
#else
#if TARGET_OS_IOS
    _renderContext = [[EAGLContext alloc] initWithAPI:_mainContext.API sharegroup:_mainContext.sharegroup];
    if (_renderContext == nil) {
        [self setCanRender:NO];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect rect = self.frame;
        [self createBuffers:rect.size];
    });
#else
    const NSOpenGLPixelFormatAttribute attr[] = {
        NSOpenGLPFADepthSize, 32,
        0
    };
    const NSOpenGLPixelFormatAttribute msaaAttr[] = {
        NSOpenGLPFADepthSize, 32,
        NSOpenGLPFASampleBuffers, 1,
        NSOpenGLPFASamples, 4,
        0
    };
    NSOpenGLPixelFormat *pixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes:_msaaEnabled ? msaaAttr : attr];
    if (!pixelFormat) {
        [self setCanRender:NO];
        return;
    }
    _renderContext = [[NSOpenGLContext alloc] initWithFormat:pixelFormat shareContext:_mainContext];
    if (!_renderContext) {
        [self setCanRender:NO];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect rect = self.frame;
        [self resumeViewStateChecker];
        self.paused = NO;
        dispatch_async(self.renderQueue, ^{
            [self makeRenderContextCurrent];
            if (![self setupShaders]) return;
            [self createRenderBuffers:rect.size];
        });
    });
#endif
#endif
}

#ifndef USE_EGL
#pragma mark shaders
#ifndef USE_EGL
#if TARGET_OS_OSX
- (GLuint)compileShader:(const GLchar*)shaderString shaderType:(GLenum)shaderType
{
    GLuint shader = glCreateShader(shaderType);
    glShaderSource(shader, 1, &shaderString, NULL);
    glCompileShader(shader);
    GLint logLength, status;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &logLength);
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetShaderInfoLog(shader, logLength, &logLength, log);
        NSLog(@"Shader compile log:\n%s", log);
        free(log);
    }
    if (status == GL_FALSE) {
        glDeleteShader(shader);
        shader = 0;
    }
    return shader;
}

- (GLuint)linkProgramWithVertexShader:(GLuint)vShader fragmentShader:(GLuint)fShader
{
    GLuint program = glCreateProgram();
    glAttachShader(program, vShader);
    glAttachShader(program, fShader);
    glLinkProgram(program);

    GLint logLength, status;
    glGetProgramiv(program, GL_INFO_LOG_LENGTH, &logLength);
    glGetProgramiv(program, GL_LINK_STATUS, &status);
    if (logLength > 0)
    {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(program, logLength, &logLength, log);
        NSLog(@"Program link log:\n%s", log);
        free(log);
    }
    if (status == GL_FALSE) {
        glDeleteProgram(program);
        program = 0;
    }
    return program;
}

- (BOOL)setupShaders
{
    const GLchar* vs = "\
    #version 120\n\
    attribute vec2 in_Position;\n\
    attribute vec2 in_TexCoord0;\n\
    varying vec2 texCoord;\n\
    void main()\n\
    {\n\
        gl_Position = vec4(in_Position.xy, 0.0, 1.0);\n\
        texCoord = in_TexCoord0.st;\n\
    }";

    const GLchar* fs = "\
    #version 120\n\
    varying vec2 texCoord;\n\
    uniform sampler2D tex;\n\
    void main()\n\
    {\n\
        gl_FragColor = texture2D(tex, texCoord);\n\
    }";

    GLuint renderVShader = [self compileShader:vs shaderType:GL_VERTEX_SHADER];
    if (renderVShader == 0) {
        return NO;
    }
    GLuint renderFShader = [self compileShader:fs shaderType:GL_FRAGMENT_SHADER];
    if (renderFShader == 0) {
        glDeleteShader(renderVShader);
        return NO;
    }
    GLuint renderProg = [self linkProgramWithVertexShader:renderVShader fragmentShader:renderFShader];
    if (renderProg == 0) {
        glDeleteShader(renderVShader);
        glDeleteShader(renderFShader);
        return NO;
    }

    GLint renderProgTexLocation = glGetUniformLocation(renderProg, "tex");
    GLint renderProgPositionLocation = glGetAttribLocation(renderProg, "in_Position");
    GLint renderProgTexPositionLocation = glGetAttribLocation(renderProg, "in_TexCoord0");

    static float quadVertices[] = {
        // positions   // texCoords
        -1.0f,  1.0f,  0.0f, 1.0f,
        -1.0f, -1.0f,  0.0f, 0.0f,
         1.0f, -1.0f,  1.0f, 0.0f,

        -1.0f,  1.0f,  0.0f, 1.0f,
         1.0f, -1.0f,  1.0f, 0.0f,
         1.0f,  1.0f,  1.0f, 1.0f
    };

    GLuint renderProgVboId;

    glGenBuffers(1, &renderProgVboId);
    glBindBuffer(GL_ARRAY_BUFFER, renderProgVboId);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quadVertices), quadVertices, GL_STATIC_DRAW);

    _glLayer.renderVShader = renderVShader;
    _glLayer.renderFShader = renderFShader;
    _glLayer.renderProg = renderProg;
    _glLayer.renderProgVboId = renderProgVboId;
    _glLayer.renderProgPositionLocation = renderProgPositionLocation;
    _glLayer.renderProgTexLocation = renderProgTexLocation;
    _glLayer.renderProgTexPositionLocation = renderProgTexPositionLocation;

    return YES;
}
#endif
#endif

#pragma mark - buffer creation
#if TARGET_OS_IOS
- (void)createBuffers:(CGSize)size
{
    [self makeMainContextCurrent];

    glGenRenderbuffers(1, &_renderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffer);

    [self resumeViewStateChecker];
    self.paused = NO;

    dispatch_async(_renderQueue, ^{
        [self makeRenderContextCurrent];
        [self createRenderBuffers:size];
    });
}
#endif

- (void)createRenderBuffers:(CGSize)size
{
    glGenFramebuffers(1, &_framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _framebuffer);

    if (_msaaEnabled) {
        glGenRenderbuffers(1, &_sampleRenderbuffer);
        glGenRenderbuffers(1, &_sampleDepthbuffer);

        [self updateBuffersSize:size];

        glGenFramebuffers(1, &_sampleFramebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, _sampleFramebuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _sampleRenderbuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _sampleDepthbuffer);

        // Check sampleFramebuffer
        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            NSLog(@"framebuffer not complete %d", status);
            [self setCanRender:NO];
            return;
        }

        // Bind back
        glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    } else {
        glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
        glGenRenderbuffers(1, &_depthBuffer);

        [self updateBuffersSize:size];

        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _depthBuffer);
    }

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"framebuffer not complete %d", status);
        [self setCanRender:NO];
        return;
    }

    [self setupGL:size];
}

- (void)updateBuffersSize:(CGSize)size
{
    if (CGSizeEqualToSize(_savedBufferSize, size))
        return;

    _savedBufferSize = size;

    CGFloat width = size.width;
    CGFloat height = size.height;

    if (_msaaEnabled) {
        GLint samples;
        glGetIntegerv(GL_MAX_SAMPLES, &samples);

        glBindRenderbuffer(GL_RENDERBUFFER, _sampleRenderbuffer);
#if TARGET_OS_IOS
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, samples, GL_RGBA8_OES, width, height);
#else
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, samples, GL_RGBA8, width, height);
#endif

        glBindRenderbuffer(GL_RENDERBUFFER, _sampleDepthbuffer);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, samples, GL_DEPTH_COMPONENT24, width, height);
    } else {
        glBindRenderbuffer(GL_RENDERBUFFER, _depthBuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, width, height);
    }

#if TARGET_OS_OSX
    GLuint renderTex = _glLayer.renderTex;
    if (renderTex) {
        glDeleteTextures(1, &renderTex);
        _glLayer.renderTex = 0;
    }
    glGenTextures(1, &renderTex);

    glBindTexture(GL_TEXTURE_2D, renderTex);

    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    // Clamp to edge
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB8, size.width, size.height, 0, GL_RGB, GL_UNSIGNED_BYTE, NULL);
    glBindTexture(GL_TEXTURE_2D, 0);

    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, renderTex, 0);
    _glLayer.renderTex = renderTex;
    _glLayer.width = size.width;
    _glLayer.height = size.height;
#endif
}

#if TARGET_OS_IOS
- (void)makeMainContextCurrent
{
    [EAGLContext setCurrentContext:_mainContext];
}
#endif
#endif

#pragma mark - internal implementation
- (void)setupGL:(CGSize)size
{
    if ([_delegate respondsToSelector:@selector(_prepareGL:)])
        [_delegate _prepareGL:size];
}

- (void)_drawGL:(CGSize)size
{
#ifdef USE_EGL
    if ([_delegate respondsToSelector:@selector(_drawGL:)])
        [_delegate _drawGL:size];
#else
    [self updateBuffersSize:size];
    if (_msaaEnabled) {
        glBindFramebuffer(GL_FRAMEBUFFER, _sampleFramebuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, _sampleDepthbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, _sampleRenderbuffer);

#if TARGET_OS_OSX
        glEnable(GL_MULTISAMPLE);
#endif
        if ([_delegate respondsToSelector:@selector(_drawGL:)])
            [_delegate _drawGL:size];
#if TARGET_OS_OSX
        glDisable(GL_MULTISAMPLE);
#endif

        glBindFramebuffer(GL_READ_FRAMEBUFFER, _sampleFramebuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _framebuffer);

#if TARGET_OS_IOS
        if (_api == kEAGLRenderingAPIOpenGLES2) {
            glDiscardFramebufferEXT(GL_READ_FRAMEBUFFER, 1, (GLenum[]){GL_DEPTH_ATTACHMENT});
            glResolveMultisampleFramebufferAPPLE();
            glDiscardFramebufferEXT(GL_READ_FRAMEBUFFER, 1, (GLenum[]){GL_COLOR_ATTACHMENT0});
        } else {
            glInvalidateFramebuffer(GL_READ_FRAMEBUFFER, 1, (GLenum[]){GL_DEPTH_ATTACHMENT});
            glBlitFramebuffer(0, 0, size.width, size.height, 0, 0, size.width, size.height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
            glInvalidateFramebuffer(GL_READ_FRAMEBUFFER, 1, (GLenum[]){GL_COLOR_ATTACHMENT0});
        }
#else
        glBlitFramebuffer(0, 0, size.width, size.height, 0, 0, size.width, size.height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
#endif
    } else {
        glBindRenderbuffer(GL_RENDERBUFFER, _depthBuffer);
        if ([_delegate respondsToSelector:@selector(_drawGL:)])
            [_delegate _drawGL:size];
    }
#endif
}

#pragma mark - clear
- (void)clearGL
{
    [self setCanRender:NO];

#ifndef USE_EGL
    if (_depthBuffer != 0) {
        glDeleteRenderbuffers(1, &_depthBuffer);
        _depthBuffer = 0;
    }

    if (_sampleFramebuffer != 0) {
        glDeleteFramebuffers(1, &_sampleFramebuffer);
        _sampleFramebuffer = 0;
    }

    if (_sampleDepthbuffer != 0) {
        glDeleteFramebuffers(1, &_sampleDepthbuffer);
        _sampleDepthbuffer = 0;
    }

    if (_sampleRenderbuffer != 0) {
        glDeleteFramebuffers(1, &_sampleRenderbuffer);
        _sampleRenderbuffer = 0;
    }

    if (_framebuffer != 0) {
        glDeleteFramebuffers(1, &_framebuffer);
        _framebuffer = 0;
    }

#if TARGET_OS_OSX
    [_glLayer clear];
#endif
#endif

    [self destroyRenderContext];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self destroyMain];
    });
}

- (void)destroyMain
{
    [self pauseViewStateChecker];
#if TARGET_OS_OSX
    CVDisplayLinkRelease(_viewStateChecker);
    _viewStateChecker = NULL;
#else
    _viewStateChecker = nil;
#endif
#ifndef USE_EGL
#if TARGET_OS_IOS
    [self makeMainContextCurrent];
    if (_renderbuffer != 0) {
        glDeleteRenderbuffers(1, &_renderbuffer);
        _renderbuffer = 0;
    }
    [self destroyMainContext];
#endif
#endif
}

#ifndef USE_EGL
#if TARGET_OS_IOS
- (void)destroyMainContext
{
    _mainContext = nil;
}
#endif
#endif

- (void)destroyRenderContext
{
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
    _renderContext = nil;
#endif
}

#pragma mark - view checker
- (void)resumeViewStateChecker
{
#if TARGET_OS_IOS
    [_viewStateChecker addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
#else
    CVDisplayLinkStart(_viewStateChecker);
#endif
    [self checkViewState];
}

- (void)pauseViewStateChecker
{
#if TARGET_OS_IOS
    [_viewStateChecker removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
#else
    CVDisplayLinkStop(_viewStateChecker);
#endif
}

- (void)checkViewState
{
    BOOL shouldRender = ![self isPaused] && [self canRender] && self.frame.size.width > 0.0f && self.frame.size.height > 0.0f && !self.isHidden && self.superview;
#if TARGET_OS_IOS
    shouldRender = shouldRender && ([UIApplication sharedApplication].applicationState != UIApplicationStateBackground);
#else
    shouldRender = shouldRender && ![NSApplication sharedApplication].isHidden;
#endif
    [self setShouldRender:shouldRender];

    CGFloat scale = self.layer.contentsScale;

    CGSize newSize = CGSizeMake(self.frame.size.width * scale, self.frame.size.height * scale);

    if (!CGSizeEqualToSize(_drawableSize, newSize))
    {
        [self setIsUpdatingSize:YES];
        _isUpdatingSize = YES;
#ifndef USE_EGL
#if TARGET_OS_IOS
        [self makeMainContextCurrent];
        glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffer);
        [_mainContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer];
#endif
#endif
        _drawableSize = newSize;
        [self setIsUpdatingSize:NO];
    }
}

@end
