#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#include "MPVPlayer.h"
#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdatomic.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurface.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>

struct MPVPlayer {
    mpv_handle *mpv;
    mpv_render_context *render_ctx;

    // Internal OpenGL context (headless)
    CGLContextObj gl_context;

    // FBO backed by IOSurface
    GLuint fbo;
    GLuint fbo_texture;
    int fbo_width;
    int fbo_height;
    IOSurfaceRef surface;

    // Cached properties
    double duration;
    double time_pos;
    int video_width;
    int video_height;
    int paused;
    int eof_reached;
    atomic_int frame_available;
};

static void *gl_get_proc_address(void *ctx, const char *name) {
    (void)ctx;
    CFStringRef sym = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII);
    CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengl"));
    void *ptr = NULL;
    if (bundle) {
        ptr = CFBundleGetFunctionPointerForName(bundle, sym);
    }
    CFRelease(sym);
    return ptr;
}

static void on_render_update(void *ctx) {
    MPVPlayer *p = (MPVPlayer *)ctx;
    atomic_store(&p->frame_available, 1);
}

MPVPlayer *mpv_player_create(void) {
    MPVPlayer *p = calloc(1, sizeof(MPVPlayer));
    if (!p) return NULL;

    p->mpv = mpv_create();
    if (!p->mpv) { free(p); return NULL; }

    mpv_set_option_string(p->mpv, "vo", "libmpv");
    mpv_set_option_string(p->mpv, "hwdec", "auto");
    mpv_set_option_string(p->mpv, "msg-level", "all=error");
    mpv_set_option_string(p->mpv, "keep-open", "yes");
    mpv_set_option_string(p->mpv, "idle", "yes");
    mpv_set_option_string(p->mpv, "input-default-bindings", "no");
    mpv_set_option_string(p->mpv, "input-vo-keyboard", "no");
    mpv_set_option_string(p->mpv, "osc", "no");
    mpv_set_option_string(p->mpv, "ytdl", "no");

    if (mpv_initialize(p->mpv) < 0) {
        mpv_destroy(p->mpv);
        free(p);
        return NULL;
    }

    mpv_observe_property(p->mpv, 1, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(p->mpv, 2, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(p->mpv, 3, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(p->mpv, 4, "video-params/w", MPV_FORMAT_INT64);
    mpv_observe_property(p->mpv, 5, "video-params/h", MPV_FORMAT_INT64);
    mpv_observe_property(p->mpv, 6, "eof-reached", MPV_FORMAT_FLAG);

    p->paused = 1;
    return p;
}

int mpv_player_init_gl(MPVPlayer *p) {
    if (!p || !p->mpv) return -1;

    // Create a headless CGL context (no window needed)
    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAColorSize, (CGLPixelFormatAttribute)24,
        kCGLPFAAlphaSize, (CGLPixelFormatAttribute)8,
        kCGLPFAAllowOfflineRenderers,
        (CGLPixelFormatAttribute)0
    };

    CGLPixelFormatObj pix;
    GLint npix;
    if (CGLChoosePixelFormat(attrs, &pix, &npix) != kCGLNoError) return -1;
    if (CGLCreateContext(pix, NULL, &p->gl_context) != kCGLNoError) {
        CGLDestroyPixelFormat(pix);
        return -1;
    }
    CGLDestroyPixelFormat(pix);
    CGLSetCurrentContext(p->gl_context);

    // Initialize mpv render context
    mpv_opengl_init_params gl_init = {
        .get_proc_address = gl_get_proc_address,
        .get_proc_address_ctx = NULL,
    };

    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init},
        {0}
    };

    if (mpv_render_context_create(&p->render_ctx, p->mpv, params) < 0) {
        CGLDestroyContext(p->gl_context);
        p->gl_context = NULL;
        return -1;
    }

    mpv_render_context_set_update_callback(p->render_ctx, on_render_update, p);

    // Create FBO
    glGenFramebuffers(1, &p->fbo);
    glGenTextures(1, &p->fbo_texture);

    return 0;
}

static void ensure_surface(MPVPlayer *p, int w, int h) {
    if (p->fbo_width == w && p->fbo_height == h && p->surface) return;

    // Release old surface
    if (p->surface) {
        CFRelease(p->surface);
        p->surface = NULL;
    }

    // Create IOSurface using CFDictionary
    int numKeys = 4;
    const void *keys[4] = {
        kIOSurfaceWidth,
        kIOSurfaceHeight,
        kIOSurfaceBytesPerElement,
        kIOSurfacePixelFormat,
    };
    int width_val = w, height_val = h, bpe_val = 4;
    unsigned int pixel_format = 'BGRA';
    CFNumberRef values_num[4] = {
        CFNumberCreate(NULL, kCFNumberIntType, &width_val),
        CFNumberCreate(NULL, kCFNumberIntType, &height_val),
        CFNumberCreate(NULL, kCFNumberIntType, &bpe_val),
        CFNumberCreate(NULL, kCFNumberIntType, &pixel_format),
    };
    const void *values[4] = { values_num[0], values_num[1], values_num[2], values_num[3] };

    CFDictionaryRef props = CFDictionaryCreate(NULL, keys, values, numKeys,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    p->surface = IOSurfaceCreate(props);
    CFRelease(props);
    for (int i = 0; i < 4; i++) CFRelease(values_num[i]);
    if (!p->surface) return;

    // Bind texture to IOSurface
    CGLSetCurrentContext(p->gl_context);
    glBindTexture(GL_TEXTURE_RECTANGLE, p->fbo_texture);
    CGLTexImageIOSurface2D(p->gl_context, GL_TEXTURE_RECTANGLE,
                           GL_RGBA8, w, h,
                           GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV,
                           p->surface, 0);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    // Attach to FBO
    glBindFramebuffer(GL_FRAMEBUFFER, p->fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, p->fbo_texture, 0);

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        fprintf(stderr, "FBO incomplete: 0x%x\n", status);
    }

    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    p->fbo_width = w;
    p->fbo_height = h;
}

void mpv_player_render_frame(MPVPlayer *p) {
    if (!p || !p->render_ctx || !p->gl_context) return;
    if (p->video_width <= 0 || p->video_height <= 0) return;

    CGLSetCurrentContext(p->gl_context);

    int rw = p->video_width;
    int rh = p->video_height;
    ensure_surface(p, rw, rh);
    if (!p->surface) return;

    int fbo_id = (int)p->fbo;
    mpv_opengl_fbo mpv_fbo = {
        .fbo = fbo_id,
        .w = rw,
        .h = rh,
        .internal_format = 0,
    };
    int flip_y = 0;

    mpv_render_param render_params[] = {
        {MPV_RENDER_PARAM_OPENGL_FBO, &mpv_fbo},
        {MPV_RENDER_PARAM_FLIP_Y, &flip_y},
        {0}
    };

    mpv_render_context_render(p->render_ctx, render_params);
    glFlush();
}

IOSurfaceRef mpv_player_get_surface(MPVPlayer *p) {
    if (!p) return NULL;
    return p->surface;
}

void mpv_player_report_swap(MPVPlayer *p) {
    if (!p || !p->render_ctx) return;
    mpv_render_context_report_swap(p->render_ctx);
}

void mpv_player_destroy(MPVPlayer *p) {
    if (!p) return;
    if (p->render_ctx) {
        mpv_render_context_set_update_callback(p->render_ctx, NULL, NULL);
        mpv_render_context_free(p->render_ctx);
    }
    if (p->gl_context) {
        CGLSetCurrentContext(p->gl_context);
        if (p->fbo) glDeleteFramebuffers(1, &p->fbo);
        if (p->fbo_texture) glDeleteTextures(1, &p->fbo_texture);
        CGLDestroyContext(p->gl_context);
    }
    if (p->surface) CFRelease(p->surface);
    if (p->mpv) mpv_terminate_destroy(p->mpv);
    free(p);
}

int mpv_player_open_file(MPVPlayer *p, const char *path) {
    if (!p || !p->mpv) return -1;
    const char *cmd[] = {"loadfile", path, NULL};
    return mpv_command(p->mpv, cmd);
}

void mpv_player_play(MPVPlayer *p) {
    if (!p || !p->mpv) return;
    int flag = 0;
    mpv_set_property(p->mpv, "pause", MPV_FORMAT_FLAG, &flag);
}

void mpv_player_pause(MPVPlayer *p) {
    if (!p || !p->mpv) return;
    int flag = 1;
    mpv_set_property(p->mpv, "pause", MPV_FORMAT_FLAG, &flag);
}

void mpv_player_seek(MPVPlayer *p, double time) {
    if (!p || !p->mpv) return;
    char timestr[64];
    snprintf(timestr, sizeof(timestr), "%.3f", time);
    const char *cmd[] = {"seek", timestr, "absolute", NULL};
    mpv_command(p->mpv, cmd);
}

void mpv_player_stop(MPVPlayer *p) {
    if (!p || !p->mpv) return;
    const char *cmd[] = {"stop", NULL};
    mpv_command(p->mpv, cmd);
}

void mpv_player_frame_step(MPVPlayer *p) {
    if (!p || !p->mpv) return;
    const char *cmd[] = {"frame-step", NULL};
    mpv_command(p->mpv, cmd);
}

void mpv_player_frame_back_step(MPVPlayer *p) {
    if (!p || !p->mpv) return;
    const char *cmd[] = {"frame-back-step", NULL};
    mpv_command(p->mpv, cmd);
}

double mpv_player_get_duration(MPVPlayer *p) { return p ? p->duration : 0; }
double mpv_player_get_time_pos(MPVPlayer *p) { return p ? p->time_pos : 0; }
int mpv_player_get_video_width(MPVPlayer *p) { return p ? p->video_width : 0; }
int mpv_player_get_video_height(MPVPlayer *p) { return p ? p->video_height : 0; }
int mpv_player_is_paused(MPVPlayer *p) { return p ? p->paused : 1; }

int mpv_player_has_new_frame(MPVPlayer *p) {
    if (!p) return 0;
    return atomic_exchange(&p->frame_available, 0);
}

int mpv_player_poll_events(MPVPlayer *p) {
    if (!p || !p->mpv) return 0;
    int changed = 0;

    while (1) {
        mpv_event *event = mpv_wait_event(p->mpv, 0);
        if (event->event_id == MPV_EVENT_NONE) break;

        if (event->event_id == MPV_EVENT_PROPERTY_CHANGE) {
            mpv_event_property *prop = event->data;
            if (prop->data == NULL) continue;

            if (strcmp(prop->name, "duration") == 0 && prop->format == MPV_FORMAT_DOUBLE) {
                p->duration = *(double *)prop->data;
                changed |= MPV_PROP_DURATION;
            } else if (strcmp(prop->name, "time-pos") == 0 && prop->format == MPV_FORMAT_DOUBLE) {
                p->time_pos = *(double *)prop->data;
                changed |= MPV_PROP_TIME_POS;
            } else if (strcmp(prop->name, "pause") == 0 && prop->format == MPV_FORMAT_FLAG) {
                p->paused = *(int *)prop->data;
                changed |= MPV_PROP_PAUSE;
            } else if (strcmp(prop->name, "video-params/w") == 0 && prop->format == MPV_FORMAT_INT64) {
                p->video_width = (int)(*(int64_t *)prop->data);
                changed |= MPV_PROP_VIDEO_SIZE;
            } else if (strcmp(prop->name, "video-params/h") == 0 && prop->format == MPV_FORMAT_INT64) {
                p->video_height = (int)(*(int64_t *)prop->data);
                changed |= MPV_PROP_VIDEO_SIZE;
            } else if (strcmp(prop->name, "eof-reached") == 0 && prop->format == MPV_FORMAT_FLAG) {
                p->eof_reached = *(int *)prop->data;
                if (p->eof_reached) changed |= MPV_PROP_EOF;
            }
        }
    }

    return changed;
}
