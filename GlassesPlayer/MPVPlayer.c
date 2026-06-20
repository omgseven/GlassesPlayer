#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#include "MPVPlayer.h"
#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/clonefile.h>
#include <dirent.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurface.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>

struct MPVPlayer {
    mpv_handle *mpv;
    mpv_render_context *render_ctx;

    CGLContextObj gl_context;

    GLuint fbo;
    GLuint fbo_texture;
    int fbo_width;
    int fbo_height;
    IOSurfaceRef surface;

    double duration;
    double time_pos;
    int video_width;
    int video_height;
    int paused;
    int eof_reached;
    atomic_int frame_available;

    int *video_track_ids;
    int video_track_count;
    int current_track_index;

    char *temp_fixed_path;
};

// MARK: - Logging

static FILE *log_file = NULL;
static char log_dir_path[1024] = {0};
static char log_file_path[1280] = {0};

static void ensure_log_dir(void) {
    if (log_dir_path[0] != '\0') return;
    const char *home = getenv("HOME");
    if (!home) return;
    snprintf(log_dir_path, sizeof(log_dir_path), "%s/Library/Logs/GlassesPlayer", home);
    mkdir(log_dir_path, 0755);

    // Clean up leftover temp files from previous crashes
    DIR *dir = opendir(log_dir_path);
    if (dir) {
        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            if (strncmp(entry->d_name, "fixed_", 6) == 0) {
                char path[1280];
                snprintf(path, sizeof(path), "%s/%s", log_dir_path, entry->d_name);
                unlink(path);
            }
        }
        closedir(dir);
    }
}

static void init_log_file(void) {
    ensure_log_dir();
    if (log_dir_path[0] == '\0') return;

    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    char path[1280];
    snprintf(path, sizeof(path), "%s/GlassesPlayer_%04d-%02d-%02d_%02d%02d%02d.log",
             log_dir_path, t->tm_year + 1900, t->tm_mon + 1, t->tm_mday,
             t->tm_hour, t->tm_min, t->tm_sec);

    log_file = fopen(path, "w");
    if (log_file) {
        strncpy(log_file_path, path, sizeof(log_file_path) - 1);
    }
}

static void mpv_log(const char *fmt, ...) {
    if (!log_file) return;
    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    fprintf(log_file, "[%02d:%02d:%02d] ", t->tm_hour, t->tm_min, t->tm_sec);
    va_list args;
    va_start(args, fmt);
    vfprintf(log_file, fmt, args);
    va_end(args);
    fprintf(log_file, "\n");
    fflush(log_file);
}

const char *mpv_player_get_log_dir(void) {
    ensure_log_dir();
    return log_dir_path;
}

void mpv_player_log_message(const char *tag, const char *message) {
    if (!log_file) init_log_file();
    if (!log_file) return;
    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    fprintf(log_file, "[%02d:%02d:%02d] [%s] %s\n",
            t->tm_hour, t->tm_min, t->tm_sec, tag, message);
    fflush(log_file);
}

const char *mpv_player_get_log_path(void) {
    if (log_file_path[0] == '\0') return NULL;
    return log_file_path;
}

// MARK: - GL helpers

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

// MARK: - Track management

static void record_video_tracks(MPVPlayer *p) {
    free(p->video_track_ids);
    p->video_track_ids = NULL;
    p->video_track_count = 0;
    p->current_track_index = 0;

    int64_t count = 0;
    if (mpv_get_property(p->mpv, "track-list/count", MPV_FORMAT_INT64, &count) < 0) return;

    mpv_log("Track list (%lld tracks):", (long long)count);

    int video_count = 0;
    for (int i = 0; i < (int)count; i++) {
        char key[80];

        snprintf(key, sizeof(key), "track-list/%d/type", i);
        char *type = NULL;
        if (mpv_get_property(p->mpv, key, MPV_FORMAT_STRING, &type) < 0) continue;

        snprintf(key, sizeof(key), "track-list/%d/id", i);
        int64_t id = 0;
        mpv_get_property(p->mpv, key, MPV_FORMAT_INT64, &id);

        snprintf(key, sizeof(key), "track-list/%d/codec", i);
        char *codec = NULL;
        mpv_get_property(p->mpv, key, MPV_FORMAT_STRING, &codec);

        if (strcmp(type, "video") == 0) {
            snprintf(key, sizeof(key), "track-list/%d/demux-w", i);
            int64_t w = 0;
            mpv_get_property(p->mpv, key, MPV_FORMAT_INT64, &w);

            snprintf(key, sizeof(key), "track-list/%d/demux-h", i);
            int64_t h = 0;
            mpv_get_property(p->mpv, key, MPV_FORMAT_INT64, &h);

            snprintf(key, sizeof(key), "track-list/%d/demux-fps", i);
            double fps = 0;
            mpv_get_property(p->mpv, key, MPV_FORMAT_DOUBLE, &fps);

            mpv_log("  [vid %lld] %s  %lldx%lld  %.2f fps",
                    (long long)id, codec ? codec : "?",
                    (long long)w, (long long)h, fps);
            video_count++;
        } else {
            mpv_log("  [%s %lld] %s", type, (long long)id, codec ? codec : "?");
        }

        mpv_free(type);
        mpv_free(codec);
    }

    if (video_count <= 1) return;

    p->video_track_ids = calloc(video_count, sizeof(int));
    if (!p->video_track_ids) return;

    int vi = 0;
    for (int i = 0; i < (int)count; i++) {
        char key[80];
        snprintf(key, sizeof(key), "track-list/%d/type", i);
        char *type = NULL;
        if (mpv_get_property(p->mpv, key, MPV_FORMAT_STRING, &type) < 0) continue;
        int is_video = (strcmp(type, "video") == 0);
        mpv_free(type);
        if (!is_video) continue;

        snprintf(key, sizeof(key), "track-list/%d/id", i);
        int64_t id = 0;
        mpv_get_property(p->mpv, key, MPV_FORMAT_INT64, &id);
        p->video_track_ids[vi++] = (int)id;
    }
    p->video_track_count = video_count;
    mpv_log("  %d video tracks — will play sequentially", video_count);
}

static int try_next_video_track(MPVPlayer *p) {
    if (!p->video_track_ids || p->current_track_index + 1 >= p->video_track_count)
        return 0;

    p->current_track_index++;
    int64_t new_vid = p->video_track_ids[p->current_track_index];
    mpv_set_property(p->mpv, "vid", MPV_FORMAT_INT64, &new_vid);

    const char *cmd[] = {"seek", "0", "absolute", NULL};
    mpv_command(p->mpv, cmd);

    int flag = 0;
    mpv_set_property(p->mpv, "pause", MPV_FORMAT_FLAG, &flag);

    p->eof_reached = 0;

    mpv_log("Switched to video track %lld (%d/%d)",
            (long long)new_vid, p->current_track_index + 1, p->video_track_count);
    return 1;
}

// MARK: - MP4 timing fix (broken moov from hls.js recordings)

static uint32_t mp4_read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}

static void mp4_write_be32(uint8_t *p, uint32_t v) {
    p[0] = (v >> 24) & 0xFF;
    p[1] = (v >> 16) & 0xFF;
    p[2] = (v >> 8) & 0xFF;
    p[3] = v & 0xFF;
}

static long mp4_find_atom(const uint8_t *data, long len, const char *type) {
    long pos = 0;
    while (pos + 8 <= len) {
        uint32_t size = mp4_read_be32(data + pos);
        if (size < 8 || pos + (long)size > len) break;
        if (memcmp(data + pos + 4, type, 4) == 0) return pos;
        pos += size;
    }
    return -1;
}

static int mp4_fix_moov(uint8_t *moov, uint32_t moov_size) {
    int fixed = 0;
    long mbody = 8;
    long mend = (long)moov_size;

    // Parse mvhd for movie-level timescale
    long mvhd_rel = mp4_find_atom(moov + mbody, mend - mbody, "mvhd");
    if (mvhd_rel < 0) return 0;
    long mvhd_off = mbody + mvhd_rel;
    uint8_t mvhd_ver = moov[mvhd_off + 8];
    uint32_t mvhd_ts;
    long mvhd_dur_off;
    if (mvhd_ver == 0) {
        mvhd_ts = mp4_read_be32(moov + mvhd_off + 20);
        mvhd_dur_off = mvhd_off + 24;
    } else {
        mvhd_ts = mp4_read_be32(moov + mvhd_off + 28);
        mvhd_dur_off = mvhd_off + 32;
    }
    if (mvhd_ts == 0) return 0;

    uint64_t max_mvhd_dur = 0;

    // Iterate tracks
    long tpos = mbody;
    while (tpos + 8 <= mend) {
        uint32_t tatom = mp4_read_be32(moov + tpos);
        if (tatom < 8 || tpos + (long)tatom > mend) break;
        if (memcmp(moov + tpos + 4, "trak", 4) != 0) { tpos += tatom; continue; }

        long trak_body = tpos + 8;
        long trak_end = tpos + (long)tatom;

        // tkhd — duration offset (in mvhd timescale)
        long tkhd_rel = mp4_find_atom(moov + trak_body, trak_end - trak_body, "tkhd");
        long tkhd_dur_off = -1;
        uint8_t tkhd_ver = 0;
        uint64_t tkhd_dur_raw = 0;
        if (tkhd_rel >= 0) {
            long tkhd_off = trak_body + tkhd_rel;
            tkhd_ver = moov[tkhd_off + 8];
            tkhd_dur_off = tkhd_off + (tkhd_ver == 0 ? 28 : 36);
            if (tkhd_ver == 0) {
                tkhd_dur_raw = mp4_read_be32(moov + tkhd_dur_off);
            } else {
                tkhd_dur_raw = ((uint64_t)mp4_read_be32(moov + tkhd_dur_off) << 32) |
                                mp4_read_be32(moov + tkhd_dur_off + 4);
            }
        }

        // mdia → mdhd (track timescale)
        long mdia_rel = mp4_find_atom(moov + trak_body, trak_end - trak_body, "mdia");
        if (mdia_rel < 0) { tpos += tatom; continue; }
        long mdia_off = trak_body + mdia_rel;
        uint32_t mdia_sz = mp4_read_be32(moov + mdia_off);
        long mdia_body = mdia_off + 8;
        long mdia_end = mdia_off + (long)mdia_sz;

        long mdhd_rel = mp4_find_atom(moov + mdia_body, mdia_end - mdia_body, "mdhd");
        if (mdhd_rel < 0) { tpos += tatom; continue; }
        long mdhd_off = mdia_body + mdhd_rel;
        uint8_t mdhd_ver = moov[mdhd_off + 8];
        uint32_t track_ts;
        long mdhd_dur_off;
        if (mdhd_ver == 0) {
            track_ts = mp4_read_be32(moov + mdhd_off + 20);
            mdhd_dur_off = mdhd_off + 24;
        } else {
            track_ts = mp4_read_be32(moov + mdhd_off + 28);
            mdhd_dur_off = mdhd_off + 32;
        }
        if (track_ts == 0) { tpos += tatom; continue; }

        // minf → stbl → stts, stsz
        long minf_rel = mp4_find_atom(moov + mdia_body, mdia_end - mdia_body, "minf");
        if (minf_rel < 0) { tpos += tatom; continue; }
        long minf_off = mdia_body + minf_rel;
        uint32_t minf_sz = mp4_read_be32(moov + minf_off);
        long minf_body_off = minf_off + 8;
        long minf_end_off = minf_off + (long)minf_sz;

        long stbl_rel = mp4_find_atom(moov + minf_body_off, minf_end_off - minf_body_off, "stbl");
        if (stbl_rel < 0) { tpos += tatom; continue; }
        long stbl_off = minf_body_off + stbl_rel;
        uint32_t stbl_sz = mp4_read_be32(moov + stbl_off);
        long stbl_body = stbl_off + 8;
        long stbl_len = (long)stbl_sz - 8;

        long stts_rel = mp4_find_atom(moov + stbl_body, stbl_len, "stts");
        long stsz_rel = mp4_find_atom(moov + stbl_body, stbl_len, "stsz");
        if (stts_rel < 0 || stsz_rel < 0) { tpos += tatom; continue; }

        long stts_off = stbl_body + stts_rel;
        long stsz_off = stbl_body + stsz_rel;
        uint32_t stts_atom_sz = mp4_read_be32(moov + stts_off);
        uint32_t stts_entry_count = mp4_read_be32(moov + stts_off + 12);
        uint32_t stsz_count = mp4_read_be32(moov + stsz_off + 16);

        uint64_t stts_total_dur = 0;
        uint32_t stts_total_samples = 0;
        for (uint32_t i = 0; i < stts_entry_count; i++) {
            long e = stts_off + 16 + (long)i * 8;
            if (e + 8 > stts_off + (long)stts_atom_sz) break;
            uint32_t cnt = mp4_read_be32(moov + e);
            uint32_t dur = mp4_read_be32(moov + e + 4);
            stts_total_samples += cnt;
            stts_total_dur += (uint64_t)cnt * dur;
        }

        double total_sec = (double)stts_total_dur / track_ts;
        double fps = (total_sec > 0 && stts_total_samples > 0) ? stts_total_samples / total_sec : 0;

        // Detect issues
        int needs_fix = 0;
        int stts_broken = 0;

        // Check: edts/elst with wrong segment_duration (HLS recordings)
        long edts_rel = mp4_find_atom(moov + trak_body, trak_end - trak_body, "edts");
        if (edts_rel >= 0) {
            long edts_off = trak_body + edts_rel;
            uint32_t edts_sz = mp4_read_be32(moov + edts_off);
            long elst_rel = mp4_find_atom(moov + edts_off + 8, (long)edts_sz - 8, "elst");
            if (elst_rel >= 0) {
                long elst_off = edts_off + 8 + elst_rel;
                uint8_t elst_ver = moov[elst_off + 8];
                uint32_t elst_cnt = mp4_read_be32(moov + elst_off + 12);
                int entry_sz = elst_ver == 0 ? 12 : 20;
                int has_bad_elst = 0;
                for (uint32_t ei = 0; ei < elst_cnt; ei++) {
                    long ee = elst_off + 16 + (long)ei * entry_sz;
                    uint64_t seg_dur, media_time;
                    if (elst_ver == 0) {
                        seg_dur = mp4_read_be32(moov + ee);
                        media_time = mp4_read_be32(moov + ee + 4);
                    } else {
                        seg_dur = ((uint64_t)mp4_read_be32(moov + ee) << 32) |
                                   mp4_read_be32(moov + ee + 4);
                        media_time = ((uint64_t)mp4_read_be32(moov + ee + 8) << 32) |
                                      mp4_read_be32(moov + ee + 12);
                    }
                    // elst segment_duration much shorter than tkhd → broken
                    if (seg_dur > 0 && seg_dur < tkhd_dur_raw / 2 &&
                        media_time != 0xFFFFFFFF && media_time != 0xFFFFFFFFFFFFFFFFULL) {
                        has_bad_elst = 1;
                    }
                }
                if (has_bad_elst) {
                    // Convert edts to free atom — removes edit list without changing offsets
                    mpv_log("  Fixing broken edts/elst (converting to free)");
                    memcpy(moov + edts_off + 4, "free", 4);
                    memset(moov + edts_off + 8, 0, edts_sz - 8);
                    needs_fix = 1;
                }
            }
        }

        // Check: stts has unreasonable fps
        if (stts_total_samples > 500 && total_sec > 0 && fps > 120) {
            needs_fix = 1;
            stts_broken = 1;
        }
        // Check: stts doesn't cover all samples
        if (stts_total_samples < stsz_count) {
            needs_fix = 1;
            stts_broken = 1;
        }
        // Check: tkhd duration doesn't match stts duration
        uint64_t dur_mvhd = stts_total_dur * mvhd_ts / track_ts;
        if (!needs_fix && tkhd_dur_off >= 0 && total_sec > 1) {
            double tkhd_sec = (double)tkhd_dur_raw / mvhd_ts;
            if (tkhd_sec > 0 && (tkhd_sec < total_sec * 0.5 || tkhd_sec > total_sec * 2.0)) {
                mpv_log("  tkhd duration mismatch (%.2fs vs stts %.2fs)", tkhd_sec, total_sec);
                needs_fix = 1;
            }
        }

        if (!needs_fix) {
            if (dur_mvhd > max_mvhd_dur) max_mvhd_dur = dur_mvhd;
            tpos += tatom;
            continue;
        }

        // Determine correct track duration
        uint32_t correct_dur = 0;
        uint64_t new_track_dur;
        if (stts_broken) {
            correct_dur = track_ts / 25;
            if (correct_dur == 0) correct_dur = 1;
            new_track_dur = (uint64_t)stsz_count * correct_dur;
            mpv_log("  Fixing stts: %u samples × dur=%u (%.2fs)", stsz_count, correct_dur,
                    (double)new_track_dur / track_ts);
        } else {
            new_track_dur = stts_total_dur;
        }

        // Patch stts if broken
        if (stts_broken && stts_atom_sz >= 24 && correct_dur > 0) {
            uint32_t new_sz = 24;
            mp4_write_be32(moov + stts_off, new_sz);
            mp4_write_be32(moov + stts_off + 12, 1);
            mp4_write_be32(moov + stts_off + 16, stsz_count);
            mp4_write_be32(moov + stts_off + 20, correct_dur);

            uint32_t pad = stts_atom_sz - new_sz;
            if (pad >= 8) {
                mp4_write_be32(moov + stts_off + 24, pad);
                memcpy(moov + stts_off + 28, "free", 4);
                if (pad > 8) memset(moov + stts_off + 32, 0, pad - 8);
            }

            // Update mdhd duration
            if (mdhd_ver == 0) {
                mp4_write_be32(moov + mdhd_dur_off, (uint32_t)new_track_dur);
            } else {
                mp4_write_be32(moov + mdhd_dur_off, (uint32_t)(new_track_dur >> 32));
                mp4_write_be32(moov + mdhd_dur_off + 4, (uint32_t)new_track_dur);
            }
        }

        // Update tkhd duration (in mvhd timescale)
        if (tkhd_dur_off >= 0) {
            uint64_t tkhd_new = new_track_dur * mvhd_ts / track_ts;
            if (tkhd_ver == 0) {
                mp4_write_be32(moov + tkhd_dur_off, (uint32_t)tkhd_new);
            } else {
                mp4_write_be32(moov + tkhd_dur_off, (uint32_t)(tkhd_new >> 32));
                mp4_write_be32(moov + tkhd_dur_off + 4, (uint32_t)tkhd_new);
            }
            if (tkhd_new > max_mvhd_dur) max_mvhd_dur = tkhd_new;
        }

        fixed++;
        tpos += tatom;
    }

    // Update mvhd duration
    if (fixed > 0 && max_mvhd_dur > 0) {
        if (mvhd_ver == 0) {
            mp4_write_be32(moov + mvhd_dur_off, (uint32_t)max_mvhd_dur);
        } else {
            mp4_write_be32(moov + mvhd_dur_off, (uint32_t)(max_mvhd_dur >> 32));
            mp4_write_be32(moov + mvhd_dur_off + 4, (uint32_t)max_mvhd_dur);
        }
    }

    return fixed;
}

static char *fix_broken_mp4(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;

    // Scan top-level atoms to find moov (within first 20MB)
    long moov_file_off = -1;
    uint32_t moov_size = 0;
    long scan_pos = 0;
    uint8_t hdr[8];

    while (scan_pos < 20L * 1024 * 1024) {
        if (fseek(f, scan_pos, SEEK_SET) != 0) break;
        if (fread(hdr, 8, 1, f) != 1) break;
        uint32_t asize = mp4_read_be32(hdr);
        if (asize < 8) break;
        if (memcmp(hdr + 4, "moov", 4) == 0) {
            moov_file_off = scan_pos;
            moov_size = asize;
            break;
        }
        scan_pos += asize;
    }

    if (moov_file_off < 0 || moov_size < 16 || moov_size > 10 * 1024 * 1024) {
        fclose(f);
        return NULL;
    }

    uint8_t *moov = malloc(moov_size);
    if (!moov) { fclose(f); return NULL; }
    fseek(f, moov_file_off, SEEK_SET);
    if (fread(moov, moov_size, 1, f) != 1) { free(moov); fclose(f); return NULL; }
    fclose(f);

    int fixed = mp4_fix_moov(moov, moov_size);
    if (fixed == 0) {
        free(moov);
        return NULL;
    }

    mpv_log("Patched %d track(s) with broken timing", fixed);

    char temp_path[1280];
    ensure_log_dir();
    snprintf(temp_path, sizeof(temp_path), "%s/fixed_%d.mp4", log_dir_path, (int)getpid());
    unlink(temp_path);

    if (clonefile(path, temp_path, 0) == 0) {
        FILE *dst = fopen(temp_path, "r+b");
        if (!dst) { free(moov); unlink(temp_path); return NULL; }
        fseek(dst, moov_file_off, SEEK_SET);
        fwrite(moov, moov_size, 1, dst);
        fflush(dst);
        fsync(fileno(dst));
        fclose(dst);
    } else {
        // Fallback: full file copy
        FILE *src = fopen(path, "rb");
        if (!src) { free(moov); return NULL; }
        FILE *dst = fopen(temp_path, "wb");
        if (!dst) { fclose(src); free(moov); return NULL; }

        uint8_t buf[65536];
        long remaining = moov_file_off;
        while (remaining > 0) {
            size_t chunk = remaining < (long)sizeof(buf) ? (size_t)remaining : sizeof(buf);
            size_t n = fread(buf, 1, chunk, src);
            if (n == 0) break;
            fwrite(buf, 1, n, dst);
            remaining -= (long)n;
        }
        fwrite(moov, moov_size, 1, dst);
        fseek(src, moov_file_off + (long)moov_size, SEEK_SET);
        while (1) {
            size_t n = fread(buf, 1, sizeof(buf), src);
            if (n == 0) break;
            fwrite(buf, 1, n, dst);
        }
        fclose(src);
        fclose(dst);
    }

    free(moov);
    return strdup(temp_path);
}

static void cleanup_temp_file(MPVPlayer *p) {
    if (p->temp_fixed_path) {
        unlink(p->temp_fixed_path);
        free(p->temp_fixed_path);
        p->temp_fixed_path = NULL;
    }
}

// MARK: - Create / Destroy

MPVPlayer *mpv_player_create(void) {
    MPVPlayer *p = calloc(1, sizeof(MPVPlayer));
    if (!p) return NULL;

    init_log_file();
    mpv_log("Creating player");

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

    glGenFramebuffers(1, &p->fbo);
    glGenTextures(1, &p->fbo_texture);

    return 0;
}

static void ensure_surface(MPVPlayer *p, int w, int h) {
    if (p->fbo_width == w && p->fbo_height == h && p->surface) return;

    if (p->surface) {
        CFRelease(p->surface);
        p->surface = NULL;
    }

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

    CGLSetCurrentContext(p->gl_context);
    glBindTexture(GL_TEXTURE_RECTANGLE, p->fbo_texture);
    CGLTexImageIOSurface2D(p->gl_context, GL_TEXTURE_RECTANGLE,
                           GL_RGBA8, w, h,
                           GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV,
                           p->surface, 0);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

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
    mpv_log("Player destroyed");
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
    free(p->video_track_ids);
    cleanup_temp_file(p);
    if (p->mpv) mpv_terminate_destroy(p->mpv);
    free(p);

    if (log_file) { fclose(log_file); log_file = NULL; }
}

// MARK: - Playback control

int mpv_player_open_file(MPVPlayer *p, const char *path) {
    if (!p || !p->mpv) return -1;

    cleanup_temp_file(p);

    const char *actual_path = path;

    // Fix broken MP4 edit lists (HLS recordings)
    mpv_set_option_string(p->mpv, "demuxer-lavf-o", "use_editlist=0");
    char *fixed = fix_broken_mp4(path);
    if (fixed) {
        p->temp_fixed_path = fixed;
        actual_path = fixed;
    }

    const char *cmd[] = {"loadfile", actual_path, NULL};
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
    free(p->video_track_ids);
    p->video_track_ids = NULL;
    p->video_track_count = 0;
    p->current_track_index = 0;
    cleanup_temp_file(p);
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

void mpv_player_set_volume(MPVPlayer *p, double volume) {
    if (!p || !p->mpv) return;
    mpv_set_property(p->mpv, "volume", MPV_FORMAT_DOUBLE, &volume);
}

double mpv_player_get_volume(MPVPlayer *p) {
    if (!p || !p->mpv) return 100;
    double vol = 100;
    mpv_get_property(p->mpv, "volume", MPV_FORMAT_DOUBLE, &vol);
    return vol;
}

void mpv_player_set_speed(MPVPlayer *p, double speed) {
    if (!p || !p->mpv) return;
    mpv_set_property(p->mpv, "speed", MPV_FORMAT_DOUBLE, &speed);
}

// Stereo 3D mode
static char stereo_mode_buf[64] = {0};

const char *mpv_player_get_stereo_mode(MPVPlayer *p) {
    if (!p || !p->mpv) return NULL;
    char *val = NULL;
    if (mpv_get_property(p->mpv, "video-params/stereo-in", MPV_FORMAT_STRING, &val) >= 0 && val) {
        snprintf(stereo_mode_buf, sizeof(stereo_mode_buf), "%s", val);
        mpv_free(val);
        return stereo_mode_buf;
    }
    return NULL;
}

// MARK: - Event polling

int mpv_player_poll_events(MPVPlayer *p) {
    if (!p || !p->mpv) return 0;
    int changed = 0;

    while (1) {
        mpv_event *event = mpv_wait_event(p->mpv, 0);
        if (event->event_id == MPV_EVENT_NONE) break;

        if (event->event_id == MPV_EVENT_FILE_LOADED) {
            record_video_tracks(p);
        }

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
                int eof = *(int *)prop->data;
                if (eof && !p->eof_reached) {
                    mpv_log("EOF at %.2f s (duration=%.2f)", p->time_pos, p->duration);
                    if (try_next_video_track(p)) {
                        // switched to next track, continue playback
                    } else {
                        p->eof_reached = 1;
                        changed |= MPV_PROP_EOF;
                        mpv_log("Playback finished");
                    }
                } else {
                    p->eof_reached = eof;
                }
            }
        }
    }

    return changed;
}
