/*
 * Replacement stubs for the mpv standalone macOS app bridge objects removed
 * from the local Libmpv static framework for Xcode 14.2 compatibility.
 *
 * Important behavior:
 * player/main.c still creates a secondary mpv client named "mac" and passes it
 * to cocoa_set_mpv_handle(). The real upstream bridge destroys that client
 * when the host process is not mpv's own Application subclass. Marquee is a
 * SwiftUI/AppKit host, so the stub must do the same. Leaving it alive but never
 * serviced wedges mp_play_files() in mp_clients_all_initialized(), and no
 * start-file event is ever emitted after loadfile.
 */

#include <stdint.h>
#include <stddef.h>

struct ra_ctx_fns_stub {
    const char *type;
    const char *name;
    const char *description;
    void *fns[8];
};

const struct ra_ctx_fns_stub ra_ctx_vulkan_mac = {
    .type        = "removed-vk-mac",
    .name        = "removed-vk-mac",
    .description = "stub: standalone-mac vulkan ctx removed",
    .fns         = {0},
};

extern void mpv_destroy(void *handle);

int  cocoa_init_cocoa_cb(void *ctx)             { (void)ctx; return -1; }
void cocoa_init_media_keys(void *ictx)          { (void)ictx; }
void cocoa_uninit_media_keys(void *ictx)        { (void)ictx; }
void cocoa_set_input_context(void *ictx)        { (void)ictx; }
void cocoa_set_mpv_handle(void *handle)
{
    if (handle)
        mpv_destroy(handle);
}

struct fake_m_option { const char *name; char rest[256]; };
static const struct fake_m_option macos_conf_opts_end = { 0 };

struct fake_m_sub_options {
    const void *opts;
    size_t size;
    const void *defaults;
    int change_flags;
    void *get_sub_options;
    char pad[64];
};

const struct fake_m_sub_options macos_conf = {
    .opts = &macos_conf_opts_end,
    .size = 0,
    .defaults = 0,
    .change_flags = 0,
    .get_sub_options = 0,
};

struct clipboard_backend_stub {
    const char *name;
    const char *desc;
    void *fns[5];
};

const struct clipboard_backend_stub clipboard_backend_mac = {
    .name = "stub-mac",
    .desc = "stub: standalone-mac clipboard removed",
    .fns  = {0},
};
