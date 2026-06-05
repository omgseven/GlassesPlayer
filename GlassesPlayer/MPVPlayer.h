#ifndef MPVPlayer_h
#define MPVPlayer_h

#include <stdint.h>
#include <IOSurface/IOSurface.h>

typedef struct MPVPlayer MPVPlayer;

#define MPV_PROP_DURATION   (1 << 0)
#define MPV_PROP_TIME_POS   (1 << 1)
#define MPV_PROP_PAUSE      (1 << 2)
#define MPV_PROP_VIDEO_SIZE (1 << 3)
#define MPV_PROP_EOF        (1 << 4)

MPVPlayer *mpv_player_create(void);
void mpv_player_destroy(MPVPlayer *p);

// Initialize internal OpenGL context and render setup. No external GL context needed.
int mpv_player_init_gl(MPVPlayer *p);

// Render current video frame to the IOSurface. Call with no GL context requirements.
void mpv_player_render_frame(MPVPlayer *p);

// Get the IOSurface containing the latest rendered frame. Returns NULL if no video.
IOSurfaceRef mpv_player_get_surface(MPVPlayer *p);

// Notify mpv that the frame was presented
void mpv_player_report_swap(MPVPlayer *p);

// Playback control
int mpv_player_open_file(MPVPlayer *p, const char *path);
void mpv_player_play(MPVPlayer *p);
void mpv_player_pause(MPVPlayer *p);
void mpv_player_seek(MPVPlayer *p, double time);
void mpv_player_stop(MPVPlayer *p);

// Frame stepping
void mpv_player_frame_step(MPVPlayer *p);
void mpv_player_frame_back_step(MPVPlayer *p);

// Properties
double mpv_player_get_duration(MPVPlayer *p);
double mpv_player_get_time_pos(MPVPlayer *p);
int mpv_player_get_video_width(MPVPlayer *p);
int mpv_player_get_video_height(MPVPlayer *p);
int mpv_player_is_paused(MPVPlayer *p);

// Volume (0-100)
void mpv_player_set_volume(MPVPlayer *p, double volume);
double mpv_player_get_volume(MPVPlayer *p);

// Speed
void mpv_player_set_speed(MPVPlayer *p, double speed);

// Check if a new frame is available
int mpv_player_has_new_frame(MPVPlayer *p);

// Poll pending events. Returns bitmask of MPV_PROP_* for changed properties.
int mpv_player_poll_events(MPVPlayer *p);

#endif
