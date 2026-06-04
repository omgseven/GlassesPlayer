#ifndef MPVPlayer_h
#define MPVPlayer_h

#include <stdint.h>

typedef struct MPVPlayer MPVPlayer;

#define MPV_PROP_DURATION   (1 << 0)
#define MPV_PROP_TIME_POS   (1 << 1)
#define MPV_PROP_PAUSE      (1 << 2)
#define MPV_PROP_VIDEO_SIZE (1 << 3)
#define MPV_PROP_EOF        (1 << 4)

// Create player. Call before GL init.
MPVPlayer *mpv_player_create(void);
void mpv_player_destroy(MPVPlayer *p);

// Initialize OpenGL rendering. Must be called with a valid GL context current.
int mpv_player_init_gl(MPVPlayer *p);

// Playback control
int mpv_player_open_file(MPVPlayer *p, const char *path);
void mpv_player_play(MPVPlayer *p);
void mpv_player_pause(MPVPlayer *p);
void mpv_player_seek(MPVPlayer *p, double time);
void mpv_player_stop(MPVPlayer *p);

// Properties
double mpv_player_get_duration(MPVPlayer *p);
double mpv_player_get_time_pos(MPVPlayer *p);
int mpv_player_get_video_width(MPVPlayer *p);
int mpv_player_get_video_height(MPVPlayer *p);
int mpv_player_is_paused(MPVPlayer *p);

// Render one frame with equirectangular projection.
// Must be called with GL context current. Renders to the currently bound framebuffer.
// displayMode: 0=left eye only, 1=right eye only, 2=both side-by-side
// sourceLayout: 0=left-right SBS, 1=top-bottom SBS
void mpv_player_render(MPVPlayer *p, int width, int height,
                       float yaw, float pitch, float tanHalfFOV, float aspect,
                       int displayMode, int sourceLayout);

// Check if a new frame is available
int mpv_player_has_new_frame(MPVPlayer *p);

// Notify mpv that the frame was presented (call after buffer swap)
void mpv_player_report_swap(MPVPlayer *p);

// Poll pending events. Returns bitmask of MPV_PROP_* for changed properties.
int mpv_player_poll_events(MPVPlayer *p);

#endif
