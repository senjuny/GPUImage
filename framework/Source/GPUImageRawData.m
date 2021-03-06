#import "GPUImageRawData.h"

#import "GPUImageOpenGLESContext.h"
#import "GLProgram.h"
#import "GPUImageFilter.h"

@interface GPUImageRawData ()
{
    
    BOOL hasReadFromTheCurrentFrame;
    
	GLuint dataFramebuffer, dataRenderbuffer;

    GLuint inputTextureForDisplay;
    
    GLProgram *dataProgram;
    GLint dataPositionAttribute, dataTextureCoordinateAttribute;
    GLint dataInputTextureUniform;
    
    GLubyte *_rawBytesForImage;
}

// Frame rendering
- (void)createDataFBO;
- (void)destroyDataFBO;
- (void)setFilterFBO;

- (void)renderAtInternalSize;

@end

@implementation GPUImageRawData

@synthesize rawBytesForImage = _rawBytesForImage;
@synthesize delegate = _delegate;

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithImageSize:(CGSize)newImageSize;
{
    if (!(self = [super init]))
    {
		return nil;
    }

    imageSize = newImageSize;
    hasReadFromTheCurrentFrame = NO;
    _rawBytesForImage = NULL;

    [GPUImageOpenGLESContext useImageProcessingContext];
    dataProgram = [[GLProgram alloc] initWithVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImagePassthroughFragmentShaderString];
    
    [dataProgram addAttribute:@"position"];
	[dataProgram addAttribute:@"inputTextureCoordinate"];
    
    if (![dataProgram link])
	{
		NSString *progLog = [dataProgram programLog];
		NSLog(@"Program link log: %@", progLog); 
		NSString *fragLog = [dataProgram fragmentShaderLog];
		NSLog(@"Fragment shader compile log: %@", fragLog);
		NSString *vertLog = [dataProgram vertexShaderLog];
		NSLog(@"Vertex shader compile log: %@", vertLog);
		dataProgram = nil;
        NSAssert(NO, @"Filter shader link failed");
	}
    
    dataPositionAttribute = [dataProgram attributeIndex:@"position"];
    dataTextureCoordinateAttribute = [dataProgram attributeIndex:@"inputTextureCoordinate"];
    dataInputTextureUniform = [dataProgram uniformIndex:@"inputImageTexture"];
    
    [dataProgram use];    
	glEnableVertexAttribArray(dataPositionAttribute);
	glEnableVertexAttribArray(dataTextureCoordinateAttribute);

    return self;
}

- (void)dealloc
{
    [self destroyDataFBO];
    
    if (_rawBytesForImage != NULL)
    {
        free(_rawBytesForImage);
        _rawBytesForImage = NULL;
    }
}

#pragma mark -
#pragma mark Frame rendering

- (void)createDataFBO;
{
    glActiveTexture(GL_TEXTURE1);
    glGenFramebuffers(1, &dataFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, dataFramebuffer);

    if ([GPUImageOpenGLESContext supportsFastTextureUpload])
    {
        CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, (__bridge void *)[[GPUImageOpenGLESContext sharedImageProcessingOpenGLESContext] context], NULL, &rawDataTextureCache);
        if (err) 
        {
            NSAssert(NO, @"Error at CVOpenGLESTextureCacheCreate %d");
        }
        
        // Code originally sourced from http://allmybrain.com/2011/12/08/rendering-to-a-texture-with-ios-5-texture-cache-api/
        
        CFDictionaryRef empty; // empty value for attr value.
        CFMutableDictionaryRef attrs;
        empty = CFDictionaryCreate(kCFAllocatorDefault, // our empty IOSurface properties dictionary
                                   NULL,
                                   NULL,
                                   0,
                                   &kCFTypeDictionaryKeyCallBacks,
                                   &kCFTypeDictionaryValueCallBacks);
        attrs = CFDictionaryCreateMutable(kCFAllocatorDefault,
                                          1,
                                          &kCFTypeDictionaryKeyCallBacks,
                                          &kCFTypeDictionaryValueCallBacks);
        
        CFDictionarySetValue(attrs,
                             kCVPixelBufferIOSurfacePropertiesKey,
                             empty);
        
        //CVPixelBufferPoolCreatePixelBuffer (NULL, [assetWriterPixelBufferInput pixelBufferPool], &renderTarget);
        
        CVPixelBufferCreate(kCFAllocatorDefault, 
                            (int)imageSize.width, 
                            (int)imageSize.height,
                            kCVPixelFormatType_32BGRA,
                            attrs,
                            &renderTarget);
        
        CVOpenGLESTextureRef renderTexture;
        CVOpenGLESTextureCacheCreateTextureFromImage (kCFAllocatorDefault,
                                                      rawDataTextureCache, renderTarget,
                                                      NULL, // texture attributes
                                                      GL_TEXTURE_2D,
                                                      GL_RGBA, // opengl format
                                                      (int)imageSize.width, 
                                                      (int)imageSize.height,
                                                      GL_BGRA, // native iOS format
                                                      GL_UNSIGNED_BYTE,
                                                      0,
                                                      &renderTexture);
        CFRelease(attrs);
        CFRelease(empty);
        glBindTexture(CVOpenGLESTextureGetTarget(renderTexture), CVOpenGLESTextureGetName(renderTexture));
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, CVOpenGLESTextureGetName(renderTexture), 0);
    }
    else
    {
        
        glGenRenderbuffers(1, &dataRenderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, dataRenderbuffer);
        
        glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8_OES, (int)imageSize.width, (int)imageSize.height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, dataRenderbuffer);	
	}
	GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    
    NSAssert(status == GL_FRAMEBUFFER_COMPLETE, @"Incomplete filter FBO: %d", status);
}

- (void)destroyDataFBO;
{
    if (dataFramebuffer)
	{
		glDeleteFramebuffers(1, &dataFramebuffer);
		dataFramebuffer = 0;
	}	

    if (dataRenderbuffer)
	{
		glDeleteRenderbuffers(1, &dataRenderbuffer);
		dataRenderbuffer = 0;
	}	
}

- (void)setFilterFBO;
{
    if (!dataFramebuffer)
    {
        [self createDataFBO];
    }
    
    glBindFramebuffer(GL_FRAMEBUFFER, dataFramebuffer);
    
    glViewport(0, 0, (int)imageSize.width, (int)imageSize.height);
}

#pragma mark -
#pragma mark Data access

- (void)renderAtInternalSize;
{
    [GPUImageOpenGLESContext useImageProcessingContext];
    [self setFilterFBO];
    
    [dataProgram use];
    
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    static const GLfloat squareVertices[] = {
        -1.0f, -1.0f,
        1.0f, -1.0f,
        -1.0f,  1.0f,
        1.0f,  1.0f,
    };
    
    static const GLfloat textureCoordinates[] = {
        0.0f, 1.0f,
        1.0f, 1.0f,
        0.0f, 0.0f,
        1.0f, 0.0f,
    };
    
	glActiveTexture(GL_TEXTURE4);
	glBindTexture(GL_TEXTURE_2D, inputTextureForDisplay);
	glUniform1i(dataInputTextureUniform, 4);	
    
    glVertexAttribPointer(dataPositionAttribute, 2, GL_FLOAT, 0, 0, squareVertices);
	glVertexAttribPointer(dataTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, textureCoordinates);
    
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

- (GPUByteColorVector)colorAtLocation:(CGPoint)locationInImage;
{
    GPUByteColorVector *imageColorBytes = (GPUByteColorVector *)self.rawBytesForImage;
//    NSLog(@"Row start");
//    for (unsigned int currentXPosition = 0; currentXPosition < (imageSize.width * 2.0); currentXPosition++)
//    {
//        GPUByteColorVector byteAtPosition = imageColorBytes[currentXPosition];
//        NSLog(@"%d - %d, %d, %d", currentXPosition, byteAtPosition.red, byteAtPosition.green, byteAtPosition.blue);
//    }
//    NSLog(@"Row end");
    
//    GPUByteColorVector byteAtOne = imageColorBytes[1];
//    GPUByteColorVector byteAtWidth = imageColorBytes[(int)imageSize.width - 3];
//    GPUByteColorVector byteAtHeight = imageColorBytes[(int)(imageSize.height - 1) * (int)imageSize.width];
//    NSLog(@"Byte 1: %d, %d, %d, byte 2: %d, %d, %d, byte 3: %d, %d, %d", byteAtOne.red, byteAtOne.green, byteAtOne.blue, byteAtWidth.red, byteAtWidth.green, byteAtWidth.blue, byteAtHeight.red, byteAtHeight.green, byteAtHeight.blue);
    
    CGPoint locationToPickFrom = CGPointZero;
    locationToPickFrom.x = MIN(MAX(locationInImage.x, 0.0), (imageSize.width - 1.0));
    locationToPickFrom.y = MIN(MAX((imageSize.height - locationInImage.y), 0.0), (imageSize.height - 1.0));
    
    if ([GPUImageOpenGLESContext supportsFastTextureUpload])    
    {
        // When reading directly from the texture using the fast texture cache, values are in BGRA, not RGBA
        
        GPUByteColorVector flippedColor = imageColorBytes[(int)(round((locationToPickFrom.y * imageSize.width) + locationToPickFrom.x))];
        GLubyte temporaryRed = flippedColor.red;
        
        flippedColor.red = flippedColor.blue;
        flippedColor.blue = temporaryRed;

        return flippedColor;
    }
    else
    {
        return imageColorBytes[(int)(round((locationToPickFrom.y * imageSize.width) + locationToPickFrom.x))];
    }
}

#pragma mark -
#pragma mark GPUImageInput protocol

- (void)newFrameReadyAtTime:(CMTime)frameTime;
{
    hasReadFromTheCurrentFrame = NO;
    [self.delegate newImageFrameAvailableFromDataSource:self];
}

- (NSInteger)nextAvailableTextureIndex;
{
    return 0;
}

- (void)setInputTexture:(GLuint)newInputTexture atIndex:(NSInteger)textureIndex;
{
    inputTextureForDisplay = newInputTexture;
}

- (void)setInputSize:(CGSize)newSize;
{
}

- (CGSize)maximumOutputSize;
{
    return imageSize;
}

- (void)endProcessing;
{
}

- (BOOL)shouldIgnoreUpdatesToThisTarget;
{
    return NO;
}

#pragma mark -
#pragma mark Accessors

- (GLubyte *)rawBytesForImage;
{
    if ( (_rawBytesForImage == NULL) && (![GPUImageOpenGLESContext supportsFastTextureUpload]) )
    {
        _rawBytesForImage = (GLubyte *) calloc(imageSize.width * imageSize.height * 4, sizeof(GLubyte));
        hasReadFromTheCurrentFrame = NO;
    }
 
    if (hasReadFromTheCurrentFrame)
    {
        return _rawBytesForImage;
    }
    else
    {
        // Note: the fast texture caches speed up 640x480 frame reads from 9.6 ms to 3.1 ms on iPhone 4S
        
        [GPUImageOpenGLESContext useImageProcessingContext];
        if ([GPUImageOpenGLESContext supportsFastTextureUpload]) 
        {
            CVPixelBufferUnlockBaseAddress(renderTarget, 0);
//            CVOpenGLESTextureCacheFlush(rawDataTextureCache, 0);
        }
        
        [self renderAtInternalSize];
        
        if ([GPUImageOpenGLESContext supportsFastTextureUpload]) 
        {
            CVPixelBufferLockBaseAddress(renderTarget, 0);
            _rawBytesForImage = (GLubyte *)CVPixelBufferGetBaseAddress(renderTarget);
        } 
        else 
        {
            glReadPixels(0, 0, imageSize.width, imageSize.height, GL_RGBA, GL_UNSIGNED_BYTE, _rawBytesForImage);
        }
        
        return _rawBytesForImage;
    }
    
}

@end
