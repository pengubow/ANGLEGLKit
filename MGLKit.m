#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <GLES3/gl3.h>

const NSString* kEAGLDrawablePropertyColorFormat = @"EAGLDrawablePropertyColorFormat";
const NSString* kEAGLDrawablePropertyRetainedBacking = @"EAGLDrawablePropertyRetainedBacking";
const NSString* kEAGLColorFormatRGB565 = @"EAGLColorFormatRGB565";
const NSString* kEAGLColorFormatRGBA8 = @"EAGLColorFormatRGBA8";
const NSString* kEAGLColorFormatSRGBA8 = @"EAGLColorFormatSRGBA8";

@class MGLLayer;
@interface MGLContext : NSObject
+ (MGLContext *)currentContext;
+ (MGLLayer *)currentLayer;
+ (BOOL)setCurrentContext:(MGLContext *)context forLayer:(MGLLayer *)layer;
@end
@interface EAGLContext : MGLContext
@end
@implementation EAGLContext
@end

@interface MGLSharegroup : NSObject
@end
@interface EAGLSharegroup : MGLSharegroup
@end
@implementation EAGLSharegroup
@end

@interface MGLLayer : NSObject
// MGLDrawableDepthFormat and MGLDrawableStencilFormat, their values are the bit counts
@property(nonatomic) int drawableDepthFormat;
@property(nonatomic) int drawableStencilFormat;
@end
@interface CAEAGLLayer : MGLLayer
@end
/*
@implementation CAEAGLLayer
@end
*/

@interface MGLKView : NSObject
@end
@interface GLKView : MGLKView
@end
@implementation GLKView
@end

@interface MGLKViewController : NSObject
@end
@interface GLKViewController : MGLKViewController
@end
@implementation GLKViewController
@end

@implementation CAEAGLLayer(hook)
+ (Class)class {
    return MGLLayer.class;
}
@end

// Finds ANGLE's implementation of a function overridden here. RTLD_NEXT isn't enough, it
// finds Apple's OpenGLES instead when that's loaded too (e.g. by geode-sdk/ios-launcher)
static void *angleSymbol(const char *name) {
    static void *libGLESv2;
    if (!libGLESv2) {
        // glBindRenderbuffer isn't overridden, so it points into ANGLE's libGLESv2
        Dl_info info;
        if (dladdr((void *)glBindRenderbuffer, &info)) {
            libGLESv2 = dlopen(info.dli_fname, RTLD_LAZY | RTLD_NOLOAD);
        }
    }
    return dlsym(libGLESv2, name);
}

void (*orig_glGenFramebuffers)(GLsizei n, GLuint *framebuffers);
void (*orig_glGenRenderbuffers)(GLsizei n, GLuint *renderbuffers);

void glGenFramebuffers(GLsizei n, GLuint *framebuffers) {
    if (!orig_glGenFramebuffers) {
        // The very first call is used to init default buffer
        // ANGLE does this internally, so return 0 to use it instead
        orig_glGenFramebuffers = angleSymbol("glGenFramebuffers");
        for (int i = 0; i < n; i++) {
            framebuffers[i] = 0;
        }
    } else {
        orig_glGenFramebuffers(n, framebuffers);
    }
}

void glGenRenderbuffers(GLsizei n, GLuint *renderbuffers) {
    if (!orig_glGenRenderbuffers) {
        // The very first call is used to init default buffer
        // ANGLE does this internally, so return 0 to use it instead
        orig_glGenRenderbuffers = angleSymbol("glGenRenderbuffers");
        for (int i = 0; i < n; i++) {
            renderbuffers[i] = 0;
        }
    } else {
        orig_glGenRenderbuffers(n, renderbuffers);
    }
}

static GLint boundFramebuffer(GLenum target) {
    GLint framebuffer = 0;
    glGetIntegerv(target == GL_READ_FRAMEBUFFER ? GL_READ_FRAMEBUFFER_BINDING : GL_FRAMEBUFFER_BINDING, &framebuffer);
    return framebuffer;
}

static GLint renderbufferParameter(GLuint renderbuffer, GLenum pname) {
    if (!renderbuffer) {
        return 0;
    }
    GLint prevRenderbuffer = 0, value = 0;
    glGetIntegerv(GL_RENDERBUFFER_BINDING, &prevRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, pname, &value);
    glBindRenderbuffer(GL_RENDERBUFFER, prevRenderbuffer);
    return value;
}

void (*orig_glFramebufferRenderbuffer)(GLenum target, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer);
void (*orig_glDiscardFramebufferEXT)(GLenum target, GLsizei numAttachments, const GLenum *attachments);

void glFramebufferRenderbuffer(GLenum target, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer) {
    if (!orig_glFramebufferRenderbuffer) {
        orig_glFramebufferRenderbuffer = angleSymbol("glFramebufferRenderbuffer");
    }
    if (boundFramebuffer(target) != 0) {
        orig_glFramebufferRenderbuffer(target, attachment, renderbuffertarget, renderbuffer);
        return;
    }

    // The app is attaching to its "default" framebuffer, which is ANGLE's framebuffer 0
    // and can't have attachments. Give the layer's surface matching depth/stencil instead
    MGLContext *context = [MGLContext currentContext];
    MGLLayer *layer = [MGLContext currentLayer];
    if (!context || !layer) {
        return;
    }
    int depthFormat = layer.drawableDepthFormat;
    int stencilFormat = layer.drawableStencilFormat;
    if (attachment == GL_DEPTH_ATTACHMENT || attachment == GL_DEPTH_STENCIL_ATTACHMENT) {
        GLint depthBits = renderbufferParameter(renderbuffer, GL_RENDERBUFFER_DEPTH_SIZE);
        depthFormat = depthBits == 0 ? 0 : depthBits <= 16 ? 16 : 24;
    }
    if (attachment == GL_STENCIL_ATTACHMENT || attachment == GL_DEPTH_STENCIL_ATTACHMENT) {
        GLint stencilBits = renderbufferParameter(renderbuffer, GL_RENDERBUFFER_STENCIL_SIZE);
        stencilFormat = stencilBits ? 8 : 0;
    }
    if (depthFormat == layer.drawableDepthFormat && stencilFormat == layer.drawableStencilFormat) {
        return;
    }

    // Changing the formats destroys the surface and unbinds the context,
    // binding it again creates a new surface with the new formats
    layer.drawableDepthFormat = depthFormat;
    layer.drawableStencilFormat = stencilFormat;
    [MGLContext setCurrentContext:context forLayer:layer];
}

void glDiscardFramebufferEXT(GLenum target, GLsizei numAttachments, const GLenum *attachments) {
    if (!orig_glDiscardFramebufferEXT) {
        orig_glDiscardFramebufferEXT = angleSymbol("glDiscardFramebufferEXT");
    }
    GLenum defaultAttachments[3];
    if (boundFramebuffer(target) != 0 || numAttachments <= 0 || numAttachments > 3) {
        orig_glDiscardFramebufferEXT(target, numAttachments, attachments);
        return;
    }

    // Framebuffer 0 names its buffers GL_COLOR_EXT etc. instead of attachment points
    for (GLsizei i = 0; i < numAttachments; i++) {
        switch (attachments[i]) {
            case GL_COLOR_ATTACHMENT0:
                defaultAttachments[i] = GL_COLOR_EXT;
                break;
            case GL_DEPTH_ATTACHMENT:
                defaultAttachments[i] = GL_DEPTH_EXT;
                break;
            case GL_STENCIL_ATTACHMENT:
                defaultAttachments[i] = GL_STENCIL_EXT;
                break;
            default:
                defaultAttachments[i] = attachments[i];
                break;
        }
    }
    orig_glDiscardFramebufferEXT(target, numAttachments, defaultAttachments);
}
