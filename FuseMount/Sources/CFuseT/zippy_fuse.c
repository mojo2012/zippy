#include "zippy_fuse.h"
#include <dlfcn.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>

static struct {
    struct fuse_chan *(*mount)(const char *, struct fuse_args *);
    struct fuse *(*new_fs)(struct fuse_chan *, struct fuse_args *, const struct fuse_operations *, size_t, void *);
    int (*loop)(struct fuse *);
    void (*unmount)(const char *, struct fuse_chan *);
    void (*destroy)(struct fuse *);
    struct fuse_context *(*get_context)(void);
} api;

static const char *load_error = NULL;

int zf_load(const char *library_path) {
    if (api.mount) return 0;
    // FUSE-T schreibt nach dem Aushängen eines Volumes noch auf die Verbindung zum
    // beendeten NFS-Hilfsprozess. Ohne das würde SIGPIPE den ganzen Prozess beenden,
    // samt aller anderen Volumes.
    signal(SIGPIPE, SIG_IGN);
    void *lib = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
    if (!lib) { load_error = dlerror(); return -1; }
    api.mount = dlsym(lib, "fuse_mount");
    api.new_fs = dlsym(lib, "fuse_new");
    api.loop = dlsym(lib, "fuse_loop");
    api.unmount = dlsym(lib, "fuse_unmount");
    api.destroy = dlsym(lib, "fuse_destroy");
    api.get_context = dlsym(lib, "fuse_get_context");
    if (!api.mount || !api.new_fs || !api.loop || !api.unmount || !api.destroy || !api.get_context) {
        load_error = "FUSE-Bibliothek ist unvollständig";
        memset(&api, 0, sizeof api);
        return -1;
    }
    return 0;
}

const char *zf_load_error(void) { return load_error ? load_error : "unbekannter Fehler"; }

struct zf_mount {
    volatile int unmounted;
    char *mountpoint;
    struct fuse_chan *chan;
    struct fuse *fs;
};

zf_mount *zf_mount_new(const char *mountpoint, const char *options,
                       const struct fuse_operations *ops, void *user_data) {
    if (!api.mount) return NULL;
    char *argv[] = { "zippy", "-o", (char *)options, NULL };
    struct fuse_args args = FUSE_ARGS_INIT(3, argv);

    struct fuse_chan *chan = api.mount(mountpoint, &args);
    if (!chan) return NULL;
    struct fuse *fs = api.new_fs(chan, &args, ops, sizeof *ops, user_data);
    if (!fs) { api.unmount(mountpoint, chan); return NULL; }

    zf_mount *m = calloc(1, sizeof *m);
    m->mountpoint = strdup(mountpoint);
    m->chan = chan;
    m->fs = fs;
    return m;
}

// Bewusst die einfache Schleife: fuse_loop_mt von FUSE-T 1.2.9 kehrt nach dem
// Aushängen nicht zurück (wartet ewig auf ein Semaphor). ZipArchive ist trotzdem
// thread-sicher, falls später mehrfädig gearbeitet wird.
int zf_mount_loop(zf_mount *m) { return api.loop(m->fs); }

void zf_mount_unmount(zf_mount *m) {
    if (__sync_bool_compare_and_swap(&m->unmounted, 0, 1)) {
        api.unmount(m->mountpoint, m->chan);
    }
}

void zf_mount_free(zf_mount *m) {
    if (!m) return;
    zf_mount_unmount(m);
    api.destroy(m->fs);
    free(m->mountpoint);
    free(m);
}

void *zf_private_data(void) {
    struct fuse_context *ctx = api.get_context();
    return ctx ? ctx->private_data : NULL;
}
