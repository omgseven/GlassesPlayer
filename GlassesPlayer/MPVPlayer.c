#include "MPVPlayer.h"
#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdatomic.h>
#include <CoreFoundation/CoreFoundation.h>

#define GL_SILENCE_DEPRECATION
#include <OpenGL/gl3.h>

// GLSL Shaders
static const char *vert_src =
    "#version 330 core\n"
    "out vec2 ndc;\n"
    "void main() {\n"
    "    vec2 pos[4] = vec2[](vec2(-1,-1), vec2(1,-1), vec2(-1,1), vec2(1,1));\n"
    "    gl_Position = vec4(pos[gl_VertexID], 0, 1);\n"
    "    ndc = pos[gl_VertexID];\n"
    "}\n";

static const char *frag_src =
    "#version 330 core\n"
    "in vec2 ndc;\n"
    "out vec4 fragColor;\n"
    "uniform sampler2D videoTexture;\n"
    "uniform float cameraYaw;\n"
    "uniform float cameraPitch;\n"
    "uniform float tanHalfVFOV;\n"
    "uniform float aspectRatio;\n"
    "uniform int eyeIndex;\n"
    "uniform int sourceLayout;\n"
    "\n"
    "void main() {\n"
    "    vec3 camDir = normalize(vec3(ndc.x * tanHalfVFOV * aspectRatio,\n"
    "                                 ndc.y * tanHalfVFOV, 1.0));\n"
    "    float cp = cos(cameraPitch), sp = sin(cameraPitch);\n"
    "    vec3 p = vec3(camDir.x, camDir.y*cp + camDir.z*sp, -camDir.y*sp + camDir.z*cp);\n"
    "    float cy = cos(cameraYaw), sy = sin(cameraYaw);\n"
    "    vec3 dir = vec3(p.x*cy + p.z*sy, p.y, -p.x*sy + p.z*cy);\n"
    "    if (dir.z <= 0.0) { fragColor = vec4(0,0,0,1); return; }\n"
    "    float theta = atan(dir.x, dir.z);\n"
    "    float phi = acos(clamp(dir.y, -1.0, 1.0));\n"
    "    float rawU = theta / 3.14159265 + 0.5;\n"
    "    float rawV = phi / 3.14159265;\n"
    "    float texU, texV;\n"
    "    if (sourceLayout == 0) {\n"
    "        texU = rawU * 0.5 + float(eyeIndex) * 0.5;\n"
    "        texV = rawV;\n"
    "    } else {\n"
    "        texU = rawU;\n"
    "        texV = rawV * 0.5 + float(eyeIndex) * 0.5;\n"
    "    }\n"
    "    fragColor = texture(videoTexture, vec2(texU, texV));\n"
    "}\n";

struct MPVPlayer {
    mpv_handle *mpv;
    mpv_render_context *render_ctx;

    // OpenGL resources
    GLuint fbo;
    GLuint fbo_texture;
    int fbo_width;
    int fbo_height;
    GLuint shader_program;
    GLuint vao;
    GLint loc_yaw, loc_pitch, loc_fov, loc_aspect, loc_tex, loc_eye, loc_layout;

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

static GLuint compile_shader(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetShaderInfoLog(s, 512, NULL, log);
        fprintf(stderr, "Shader compile error: %s\n", log);
    }
    return s;
}

static GLuint create_program(void) {
    GLuint vs = compile_shader(GL_VERTEX_SHADER, vert_src);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, frag_src);
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glLinkProgram(prog);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint ok;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetProgramInfoLog(prog, 512, NULL, log);
        fprintf(stderr, "Program link error: %s\n", log);
    }
    return prog;
}

MPVPlayer *mpv_player_create(void) {
    MPVPlayer *p = calloc(1, sizeof(MPVPlayer));
    if (!p) return NULL;

    p->mpv = mpv_create();
    if (!p->mpv) { free(p); return NULL; }

    mpv_set_option_string(p->mpv, "vo", "libmpv");
    mpv_set_option_string(p->mpv, "hwdec", "auto");
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
        return -1;
    }

    mpv_render_context_set_update_callback(p->render_ctx, on_render_update, p);

    // Create projection shader
    p->shader_program = create_program();
    p->loc_yaw = glGetUniformLocation(p->shader_program, "cameraYaw");
    p->loc_pitch = glGetUniformLocation(p->shader_program, "cameraPitch");
    p->loc_fov = glGetUniformLocation(p->shader_program, "tanHalfVFOV");
    p->loc_aspect = glGetUniformLocation(p->shader_program, "aspectRatio");
    p->loc_tex = glGetUniformLocation(p->shader_program, "videoTexture");
    p->loc_eye = glGetUniformLocation(p->shader_program, "eyeIndex");
    p->loc_layout = glGetUniformLocation(p->shader_program, "sourceLayout");

    // Create VAO (needed for core profile)
    glGenVertexArrays(1, &p->vao);

    // Create FBO for mpv render target
    glGenFramebuffers(1, &p->fbo);
    glGenTextures(1, &p->fbo_texture);

    return 0;
}

static void ensure_fbo(MPVPlayer *p, int w, int h) {
    if (p->fbo_width == w && p->fbo_height == h) return;

    glBindTexture(GL_TEXTURE_2D, p->fbo_texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    glBindFramebuffer(GL_FRAMEBUFFER, p->fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, p->fbo_texture, 0);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    p->fbo_width = w;
    p->fbo_height = h;
}

void mpv_player_render(MPVPlayer *p, int width, int height,
                       float yaw, float pitch, float tanHalfFOV, float aspect,
                       int displayMode, int sourceLayout) {
    if (!p || !p->render_ctx) return;

    // Determine render size (use video dimensions or viewport)
    int rw = p->video_width > 0 ? p->video_width : width;
    int rh = p->video_height > 0 ? p->video_height : height;
    ensure_fbo(p, rw, rh);

    // Step 1: mpv renders decoded frame to FBO
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

    // Step 2: Render with projection shader to screen
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glClearColor(0, 0, 0, 1);
    glViewport(0, 0, width, height);
    glClear(GL_COLOR_BUFFER_BIT);
    glDisable(GL_BLEND);

    glUseProgram(p->shader_program);
    glUniform1f(p->loc_yaw, yaw);
    glUniform1f(p->loc_pitch, pitch);
    glUniform1f(p->loc_fov, tanHalfFOV);
    glUniform1i(p->loc_tex, 0);
    glUniform1i(p->loc_layout, sourceLayout);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, p->fbo_texture);
    glBindVertexArray(p->vao);

    if (displayMode == 2) {
        // Both eyes side-by-side: two passes with half-width viewports
        int hw = width / 2;
        float halfAspect = (float)hw / (float)height;

        glViewport(0, 0, hw, height);
        glUniform1f(p->loc_aspect, halfAspect);
        glUniform1i(p->loc_eye, 0);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

        glViewport(hw, 0, hw, height);
        glUniform1i(p->loc_eye, 1);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    } else {
        // Single eye: 0=left, 1=right
        glViewport(0, 0, width, height);
        glUniform1f(p->loc_aspect, aspect);
        glUniform1i(p->loc_eye, displayMode);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }

    glBindVertexArray(0);
}

void mpv_player_destroy(MPVPlayer *p) {
    if (!p) return;
    if (p->render_ctx) {
        mpv_render_context_set_update_callback(p->render_ctx, NULL, NULL);
        mpv_render_context_free(p->render_ctx);
    }
    if (p->fbo) glDeleteFramebuffers(1, &p->fbo);
    if (p->fbo_texture) glDeleteTextures(1, &p->fbo_texture);
    if (p->shader_program) glDeleteProgram(p->shader_program);
    if (p->vao) glDeleteVertexArrays(1, &p->vao);
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

double mpv_player_get_duration(MPVPlayer *p) { return p ? p->duration : 0; }
double mpv_player_get_time_pos(MPVPlayer *p) { return p ? p->time_pos : 0; }
int mpv_player_get_video_width(MPVPlayer *p) { return p ? p->video_width : 0; }
int mpv_player_get_video_height(MPVPlayer *p) { return p ? p->video_height : 0; }
int mpv_player_is_paused(MPVPlayer *p) { return p ? p->paused : 1; }

int mpv_player_has_new_frame(MPVPlayer *p) {
    if (!p) return 0;
    return atomic_exchange(&p->frame_available, 0);
}

void mpv_player_report_swap(MPVPlayer *p) {
    if (!p || !p->render_ctx) return;
    mpv_render_context_report_swap(p->render_ctx);
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
