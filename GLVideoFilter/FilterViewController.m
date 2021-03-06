#import <CoreVideo/CVOpenGLESTextureCache.h>
#import "FilterViewController.h"


@implementation FilterViewController

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        // local initialization here
        
    }
    return self;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    if ([self respondsToSelector:@selector(setNeedsStatusBarAppearanceUpdate)])
    {
        [self prefersStatusBarHidden];
        [self performSelector:@selector(setNeedsStatusBarAppearanceUpdate)];
    }
    else
    {
        // iOS 6
        [[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationSlide];
    }

    
    [[UIApplication sharedApplication] setIdleTimerDisabled: YES];
    _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    
    
    if (!_context) {
        NSLog(@"Failed to create ES context");
    }
    
    _rgbConvolution = GLKMatrix3Make(  1       ,1          ,      1,
                                     0       ,-.18732    , 1.8556,
                                     1.57481 , -.46813   ,      0);
    
    _colorConvolution = GLKMatrix3Identity;
    
    
    _rgb2lms = GLKMatrix3MakeAndTranspose(17.8824,43.5161,4.11935,
                              3.45565,27.1554,3.86714,
                              0.0299566,0.184309,1.46709);
    /*
    _lms2rgb =  GLKMatrix3Make(0.0809444479, -0.0102485335, -0.000365296938,
                               -0.130504409, 0.0540193266, -0.00412161469,
                               0.116721066, -0.113614708, 0.693511405);
    */
    _lms2rgb = GLKMatrix3Invert(_rgb2lms, NULL);
    
    _cvdConvolutions[REGULAR] = GLKMatrix3Identity;
    _cvdConvolutions[PROTANOPE] = GLKMatrix3MakeAndTranspose(0.0, 2.02344, -2.52581,
                                                             0.0, 1.0,      0.0,
                                                             0.0, 0.0,      1.0);
    
    _cvdConvolutions[DEUTERANOPE] = GLKMatrix3MakeAndTranspose(1.0,      0.0, 0.0,
                                                               0.494207, 0.0, 1.24827,
                                                               0.0,      0.0, 1.0);
    
    _cvdConvolutions[TRITANOPE] = GLKMatrix3MakeAndTranspose(1.0,       0.0,      0.0,
                                                             0.0,       1.0,      0.0,
                                                             -0.395913, 0.801109, 0.0);
    
    _error = GLKMatrix3MakeAndTranspose(0.0, 0.0, 0.0,
                                        0.7, 1.0, 0.0,
                                        0.7, 0.0, 1.0);
    
    _colorConvolution = _cvdConvolutions[REGULAR];
    _blur = false;
    self.statusLabel.text = @"Blur: Off Filter: None";
    GLKView *view = (GLKView *)self.view;
    view.context = _context;
    self.preferredFramesPerSecond = 60;
    _mode = 0;
    _screenWidth = [UIScreen mainScreen].bounds.size.width;
    _screenHeight = [UIScreen mainScreen].bounds.size.height;
    view.contentScaleFactor = [UIScreen mainScreen].scale;
    
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
    {
        
        // Choosing bigger preset for bigger screen.
        _sessionPreset = AVCaptureSessionPreset1280x720;
    }
    else
    {
        // use a 640x480 video stream for iPhones
        // _sessionPreset = AVCaptureSessionPreset640x480;
        //_sessionPreset = AVCaptureSessionPreset1280x720;
        _sessionPreset = AVCaptureSessionPreset1280x720;
    }
    
    [self setupGL];
    
    [self setupAVCapture];
}

- (void)viewDidUnload
{
    [self setStatusLabel:nil];
    [super viewDidUnload];
    
    [self tearDownAVCapture];
    [self tearDownGL];
    
    if ([EAGLContext currentContext] == _context) {
        [EAGLContext setCurrentContext:nil];
    }
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Release any cached data, images, etc. that aren't in use.
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    // Camera image orientation on screen is fixed
    // with respect to the physical camera orientation.
    
    if (interfaceOrientation == UIInterfaceOrientationLandscapeRight)
        return YES;
    else
        return NO;
}

- (void)cleanUpTextures
{
    if (_lumaTexture)
    {
        CFRelease(_lumaTexture);
        _lumaTexture = NULL;
    }
    
    if (_chromaTexture)
    {
        CFRelease(_chromaTexture);
        _chromaTexture = NULL;
    }
    
    // Periodic texture cache flush every frame
    CVOpenGLESTextureCacheFlush(_videoTextureCache, 0);
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    CVReturn err;
	CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    
    if (!_videoTextureCache)
    {
        NSLog(@"No video texture cache");
        return;
    }
    
    if (_quad == nil ||
        width != _textureWidth ||
        height != _textureHeight)
    {
        _textureWidth = width;
        _textureHeight = height;
        
        _quad = [[QuadModel alloc] init];
        _texelSize = GLKVector2Divide(GLKVector2Make(1.0, 1.0), GLKVector2Make(_textureWidth, _textureHeight));
        
        // set up buffers only *after* you have a source video stream
        // This allows the texture sizes to be set to the same as the source video stream
        [self setupBuffers];
    }
    
    
    [self cleanUpTextures];
    
    // CVOpenGLESTextureCacheCreateTextureFromImage will create GLES texture
    // optimally from CVImageBufferRef.
    
    // Y-plane
    glActiveTexture(GL_TEXTURE0);
    
    err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                       _videoTextureCache,
                                                       pixelBuffer,
                                                       NULL,
                                                       GL_TEXTURE_2D,
                                                       GL_RED_EXT,
                                                       _textureWidth,
                                                       _textureHeight,
                                                       GL_RED_EXT,
                                                       GL_UNSIGNED_BYTE,
                                                       0,
                                                       &_lumaTexture);
    if (err)
    {
        NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
    }
    
    glBindTexture(CVOpenGLESTextureGetTarget(_lumaTexture), CVOpenGLESTextureGetName(_lumaTexture));
	glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    
    // UV-plane
    glActiveTexture(GL_TEXTURE1);
    err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                       _videoTextureCache,
                                                       pixelBuffer,
                                                       NULL,
                                                       GL_TEXTURE_2D,
                                                       GL_RG_EXT,
                                                       _textureWidth/2,
                                                       _textureHeight/2,
                                                       GL_RG_EXT,
                                                       GL_UNSIGNED_BYTE,
                                                       1,
                                                       &_chromaTexture);
    if (err)
    {
        NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
    }
    
    glBindTexture(CVOpenGLESTextureGetTarget(_chromaTexture), CVOpenGLESTextureGetName(_chromaTexture));
	glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    
    
    int fboNum;
    if (_mode)
        fboNum = FBO_PING;
    else
        fboNum = FBO_FINAL;
    
    // if the mode is either the Canny or Canny Composite edge detectors, execute a Sobel pass first
    

    // bind the Y'UV to RGB/Y shader
    if (_blur)
    {
        [self setProgram:_YUVtoRGBblur];
    } else {
        [self setProgram:_YUVtoRGB];
    }
    
    
    glActiveTexture(GL_TEXTURE0);
    

    glBindFramebuffer(GL_FRAMEBUFFER, _fbo[fboNum]);
    glViewport(0, 0, _textureHeight,_textureWidth);
    glClear(GL_COLOR_BUFFER_BIT);
    
    // Render the camera frame into intermediate texture
    glDrawElements(GL_TRIANGLE_STRIP, [_quad getIndexCount], GL_UNSIGNED_SHORT, 0);
    
    if (_mode == CANNY || _mode == CANNY_COMPOSITE)
    {
        [self drawIntoFBO:(!fboNum) WithShader:_cannySobel sourceTexture:fboNum];
        fboNum = !fboNum;
        [self drawIntoFBO:(FBO_FINAL) WithShader:_effect[_mode] sourceTexture:fboNum];
        
    } else if (_mode)
    {
        // process the last generated texture with selected effect
        [self drawIntoFBO:(FBO_FINAL) WithShader:_effect[_mode] sourceTexture:fboNum];
    }
    
}

- (void)setupAVCapture
{
    //-- Create CVOpenGLESTextureCacheRef for optimal CVImageBufferRef to GLES texture conversion.
#if COREVIDEO_USE_EAGLCONTEXT_CLASS_IN_API
    CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, _context, NULL, &_videoTextureCache);
#else
    CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, (__bridge void *)_context, NULL, &_videoTextureCache);
#endif
    if (err)
    {
        NSLog(@"Error at CVOpenGLESTextureCacheCreate %d", err);
        return;
    }
    
    //-- Setup Capture Session.
    _session = [[AVCaptureSession alloc] init];
    [_session beginConfiguration];
    
    //-- Set preset session size.
    [_session setSessionPreset:_sessionPreset];
    
    //-- Creata a video device and input from that Device.  Add the input to the capture session.
    AVCaptureDevice * videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if(videoDevice == nil)
        assert(0);
    
    //-- Add the device to the session.
    NSError *error;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];
    if(error)
        assert(0);
    
    [_session addInput:input];
    
    //-- Create the output for the capture session.
    AVCaptureVideoDataOutput * dataOutput = [[AVCaptureVideoDataOutput alloc] init];
    [dataOutput setAlwaysDiscardsLateVideoFrames:YES]; // Probably want to set this to NO when recording
    
    //-- Set to YUV420.
    [dataOutput setVideoSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)}]; // Necessary for manual preview
    
    // Set dispatch to be on the main thread so OpenGL can do things with the data
    [dataOutput setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
    
    [_session addOutput:dataOutput];
    [_session commitConfiguration];
    
    [_session startRunning];
}

- (void)tearDownAVCapture
{
    [self cleanUpTextures];
    
    CFRelease(_videoTextureCache);
}

- (void)setupBuffers
{
    // create frame vertex buffers
    glGenBuffers(1, &_indexVBO);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, _indexVBO);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, [_quad getIndexSize], [_quad getIndices], GL_STATIC_DRAW);
    
    glGenBuffers(1, &_positionVBO);
    glBindBuffer(GL_ARRAY_BUFFER, _positionVBO);
    glBufferData(GL_ARRAY_BUFFER, [_quad getVertexSize], [_quad getVertices], GL_STATIC_DRAW);
    
    glEnableVertexAttribArray(ATTRIB_VERTEX);
    glVertexAttribPointer(ATTRIB_VERTEX, 3, GL_FLOAT, GL_FALSE, 3*sizeof(GLfloat), 0);
    
    glGenBuffers(1, &_texcoordVBO);
    glBindBuffer(GL_ARRAY_BUFFER, _texcoordVBO);
    glBufferData(GL_ARRAY_BUFFER, [_quad getVertexSize], [_quad getTexCoords], GL_STATIC_DRAW);
    
    glEnableVertexAttribArray(ATTRIB_TEXCOORD);
    glVertexAttribPointer(ATTRIB_TEXCOORD, 2, GL_FLOAT, GL_FALSE, 2*sizeof(GLfloat), 0);
    
    // genereate textures and FBO's
    glGenTextures(NUM_FBOS, &_fboTextures[0]);
    glGenFramebuffers(NUM_FBOS, &_fbo[0]);
    
    for (int i = 0; i < NUM_FBOS; i++)
    {
        glBindFramebuffer(GL_FRAMEBUFFER, _fbo[i]);
        glBindTexture(GL_TEXTURE_2D, _fboTextures[i]);
        
        glTexImage2D( GL_TEXTURE_2D,
                     0,
                     GL_RGBA,
                     _textureHeight, _textureWidth,
                     0,
                     GL_RGBA,
                     GL_UNSIGNED_BYTE,
                     NULL);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        
        
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _fboTextures[i], 0);
        
        GLenum status;
        status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        switch(status) {
            case GL_FRAMEBUFFER_COMPLETE:
                NSLog(@"fbo complete");
                break;
                
            case GL_FRAMEBUFFER_UNSUPPORTED:
                NSLog(@"fbo unsupported");
                break;
                
            default:
                /* programming error; will fail on all hardware */
                NSLog(@"Framebuffer Error");
                break;
        }
    }
    
    glBindTexture(GL_TEXTURE_2D, 0);
}

- (void)setupGL
{
    [EAGLContext setCurrentContext:_context];
    
    
    [self loadShader:&_YUVtoRGB withVertex:@"quadInvertY" withFragment:@"yuv2rgb"];
    [self loadShader:&_YUVtoRGBblur withVertex:@"quadInvertY" withFragment:@"yuv2rgbBlur"];
    [self loadShader:&_effect[SOBEL] withVertex:@"quadKernel" withFragment:@"Sobel"];
    [self loadShader:&_effect[SOBEL_BW] withVertex:@"quadKernel" withFragment:@"SobelBW"];
    [self loadShader:&_effect[SOBEL_COMPOSITE] withVertex:@"quadKernel" withFragment:@"SobelBWComposite"];
    [self loadShader:&_effect[SOBEL_COMPOSITE_RGB] withVertex:@"quadKernel" withFragment:@"SobelRGBComposite"];
    [self loadShader:&_effect[SOBEL_BLEND] withVertex:@"quadKernel" withFragment:@"SobelBlend"];
    [self loadShader:&_effect[CANNY] withVertex:@"quadKernel" withFragment:@"Canny"];
    [self loadShader:&_effect[CANNY_COMPOSITE] withVertex:@"quadKernel" withFragment:@"CannyComposite"];
    [self loadShader:&_cannySobel withVertex:@"quadKernel" withFragment:@"SobelCanny"];
    [self loadShader:&_passthrough withVertex:@"quadPassthrough" withFragment:@"passthrough"];
}

- (void)tearDownGL
{
    [EAGLContext setCurrentContext:_context];
    
    glDeleteBuffers(1, &_positionVBO);
    glDeleteBuffers(1, &_texcoordVBO);
    glDeleteBuffers(1, &_indexVBO);
    
    if (_YUVtoRGB.handle) {
        glDeleteProgram(_YUVtoRGB.handle);
        _YUVtoRGB.handle = 0;
    }
    
    if (_YUVtoRGBblur.handle) {
        glDeleteProgram(_YUVtoRGBblur.handle);
        _YUVtoRGBblur.handle = 0;
    }
    
    if (_passthrough.handle) {
        glDeleteProgram(_passthrough.handle);
        _passthrough.handle = 0;
    }
    
    if (_cannySobel.handle) {
        glDeleteProgram(_cannySobel.handle);
        _cannySobel.handle = 0;
    }
    
    for (int i = 0; i < NUM_EFFECTS; i++)
    {
        if (_effect[i].handle) {
            glDeleteProgram(_effect[i].handle);
            _effect[i].handle = 0;
        }
    }
    glDeleteTextures(NUM_FBOS, &_fboTextures[0]);
    glDeleteFramebuffers(NUM_FBOS, &_fbo[0]);
}

#pragma mark - GLKView and GLKViewController delegate methods


// Render from one texture into another FBO
- (BOOL)drawIntoFBO: (int) fboNum WithShader:(shader_t) shader sourceTexture:(int)texNum
{
    if (fboNum >= 0 && fboNum < NUM_FBOS && texNum >= 0 && texNum < NUM_FBOS)
    {
        glBindFramebuffer(GL_FRAMEBUFFER, _fbo[fboNum]);
        glViewport(0, 0, _textureHeight, _textureWidth);
        [self setProgram:shader];
        
        glBindTexture(GL_TEXTURE_2D, _fboTextures[texNum]);
        glClear(GL_COLOR_BUFFER_BIT);
        
        glDrawElements(GL_TRIANGLE_STRIP, [_quad getIndexCount], GL_UNSIGNED_SHORT, 0);
        
        return YES;
    }
    return NO;
}

- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect
{
    
    // draw the texture to the screen
    [self setProgram:_passthrough];
    [view bindDrawable];
    glViewport(0, 0, view.drawableWidth, view.drawableHeight);
    glBindTexture(GL_TEXTURE_2D, _fboTextures[FBO_FINAL]);
    glClear(GL_COLOR_BUFFER_BIT);
    
    glDrawElements(GL_TRIANGLE_STRIP, [_quad getIndexCount], GL_UNSIGNED_SHORT, 0);
    glBindTexture(GL_TEXTURE_2D, 0);
}

#pragma mark - Touch handling methods


- (IBAction)tapGestureRecgonizer:(UITapGestureRecognizer *)sender {
    
    
    if (sender.numberOfTouches == 1)
    {
        // if one finger tap, change effect
        _mode++;
        if (_mode == NUM_EFFECTS)
            _mode = 0;
    } else if (sender.numberOfTouches == 2) {
        // if two finger tap turn blur on/off
        _blur = !_blur;
    }
    
    // update the overlay
    NSString *filter = @"Filter: ";
    switch (_mode) {
        case NONE:
            filter = [filter stringByAppendingString:@"None"];
            break;
        case SOBEL:
            filter = [filter stringByAppendingString:@"Sobel RGB"];
            break;
        case SOBEL_BW:
            filter = [filter stringByAppendingString:@"Sobel BW"];
            break;
        case SOBEL_COMPOSITE:
            filter = [filter stringByAppendingString:@"Sobel BW Composite"];
            break;
        case SOBEL_COMPOSITE_RGB:
            filter = [filter stringByAppendingString:@"Sobel RGB Composite"];
            break;
        case SOBEL_BLEND:
            filter = [filter stringByAppendingString:@"Sobel Blended"];
            break;
        case CANNY_COMPOSITE:
            filter = [filter stringByAppendingString:@"Canny Composite"];
            break;
        case CANNY:
            filter = [filter stringByAppendingString:@"Canny BW"];
            break;
    }
    NSString *blur = @"Blur: ";
    if (_blur)
        blur = [blur stringByAppendingString:@"On "];
    else
        blur = [blur stringByAppendingString:@"Off "];
    
    self.statusLabel.text = [blur stringByAppendingString:filter];
}

#pragma mark - OpenGL ES 2 shader compilation

- (BOOL)loadShader: (shader_t *) program withVertex: (NSString *) vertexName withFragment: (NSString *) fragmentName
{
    GLuint vertShader, fragShader;
    NSString *vertShaderPathname, *fragShaderPathname;
    
    // Create shader program.
    program->handle = glCreateProgram();
    
    // Create and compile vertex shader.
    vertShaderPathname = [[NSBundle mainBundle] pathForResource:vertexName ofType:@"vsh"];
    if (![self compileShader:&vertShader type:GL_VERTEX_SHADER file:vertShaderPathname]) {
        NSLog(@"Failed to compile vertex shader");
        return NO;
    }
    
    // Create and compile fragment shader.
    fragShaderPathname = [[NSBundle mainBundle] pathForResource:fragmentName ofType:@"fsh"];
    if (![self compileShader:&fragShader type:GL_FRAGMENT_SHADER file:fragShaderPathname]) {
        NSLog(@"Failed to compile fragment shader");
        return NO;
    }
    
    // Attach vertex shader to program.
    glAttachShader(program->handle, vertShader);
    
    // Attach fragment shader to program.
    glAttachShader(program->handle, fragShader);
    
    // Bind attribute locations.
    // This needs to be done prior to linking.
    glBindAttribLocation(program->handle, ATTRIB_VERTEX, "position");
    glBindAttribLocation(program->handle, ATTRIB_TEXCOORD, "texCoord");
    
    // Link program.
    if (![self linkProgram:program->handle]) {
        NSLog(@"Failed to link program: %d", program->handle);
        
        if (vertShader) {
            glDeleteShader(vertShader);
            vertShader = 0;
        }
        if (fragShader) {
            glDeleteShader(fragShader);
            fragShader = 0;
        }
        if (_YUVtoRGB.handle) {
            glDeleteProgram(program->handle);
            program->handle = 0;
        }
        
        return NO;
    }
    
    // Get program locations.
    program->uniforms[UNIFORM_Y] = glGetUniformLocation(program->handle, "SamplerY");
    program->uniforms[UNIFORM_UV] = glGetUniformLocation(program->handle, "SamplerUV");
    program->uniforms[UNIFORM_RGB] = glGetUniformLocation(program->handle, "SamplerRGB");
    program->uniforms[UNIFORM_TEXELSIZE] = glGetUniformLocation(program->handle, "texelSize");
    program->uniforms[UNIFORM_RGBCONVOLUTION] = glGetUniformLocation(program->handle, "rgbConvolution");
    program->uniforms[UNIFORM_COLORCONVOLUTION] = glGetUniformLocation(program->handle, "colorConvolution");
    program->uniforms[UNIFORM_RGB2LMS] = glGetUniformLocation(program->handle, "rgb2lms");
    program->uniforms[UNIFORM_LMS2RGB] = glGetUniformLocation(program->handle, "lms2rgb");
    program->uniforms[UNIFORM_ERROR] = glGetUniformLocation(program->handle, "error");
    
    // Release vertex and fragment shaders.
    if (vertShader) {
        glDetachShader(program->handle, vertShader);
        glDeleteShader(vertShader);
    }
    if (fragShader) {
        glDetachShader(program->handle, fragShader);
        glDeleteShader(fragShader);
    }
    
    return YES;
}

- (BOOL)compileShader:(GLuint *)shader type:(GLenum)type file:(NSString *)file
{
    GLint status;
    const GLchar *source;
    
    source = (GLchar *)[[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] UTF8String];
    if (!source) {
        NSLog(@"Failed to load shader");
        return NO;
    }
    
    *shader = glCreateShader(type);
    glShaderSource(*shader, 1, &source, NULL);
    glCompileShader(*shader);
    
#if defined(DEBUG)
    GLint logLength;
    glGetShaderiv(*shader, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetShaderInfoLog(*shader, logLength, &logLength, log);
        NSLog(@"Shader compile log:\n%s", log);
        free(log);
    }
#endif
    
    glGetShaderiv(*shader, GL_COMPILE_STATUS, &status);
    if (status == 0) {
        glDeleteShader(*shader);
        return NO;
    }
    
    return YES;
}

- (BOOL)linkProgram:(GLuint)prog
{
    GLint status;
    glLinkProgram(prog);
    
#if defined(DEBUG)
    GLint logLength;
    glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(prog, logLength, &logLength, log);
        NSLog(@"Program link log:\n%s", log);
        free(log);
    }
#endif
    
    glGetProgramiv(prog, GL_LINK_STATUS, &status);
    if (status == 0) {
        return NO;
    }
    
    return YES;
}

- (void)setProgram:(shader_t)program
{
    glUseProgram(program.handle);
    
    // bind appropriate uniforms
    if (program.uniforms[UNIFORM_Y] > -1)
    {
        glUniform1i(program.uniforms[UNIFORM_Y], 0);
        glUniform1i(program.uniforms[UNIFORM_UV], 1);
    } else {
        glUniform1i(program.uniforms[UNIFORM_RGB], 0);
    }
    if (program.uniforms[UNIFORM_TEXELSIZE] > -1)
        glUniform2fv(program.uniforms[UNIFORM_TEXELSIZE], 1, (GLfloat *) &_texelSize);
    if (program.uniforms[UNIFORM_RGBCONVOLUTION] > -1)
        glUniformMatrix3fv(program.uniforms[UNIFORM_RGBCONVOLUTION], 1, GL_FALSE, _rgbConvolution.m);
    if (program.uniforms[UNIFORM_COLORCONVOLUTION] > -1)
        glUniformMatrix3fv(program.uniforms[UNIFORM_COLORCONVOLUTION], 1, GL_FALSE, _colorConvolution.m);
    if (program.uniforms[UNIFORM_RGB2LMS] > -1)
        glUniformMatrix3fv(program.uniforms[UNIFORM_RGB2LMS], 1, GL_FALSE, _rgb2lms.m);
    if (program.uniforms[UNIFORM_LMS2RGB] > -1)
        glUniformMatrix3fv(program.uniforms[UNIFORM_LMS2RGB], 1, GL_FALSE, _lms2rgb.m);
    if (program.uniforms[UNIFORM_ERROR] > -1)
        glUniformMatrix3fv(program.uniforms[UNIFORM_ERROR], 1, GL_FALSE, _error.m);
}

@end
