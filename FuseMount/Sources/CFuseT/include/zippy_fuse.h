#ifndef ZIPPY_FUSE_H
#define ZIPPY_FUSE_H

#define FUSE_USE_VERSION 26
#define _FILE_OFFSET_BITS 64
#include "fuse/fuse.h"

/// Loads a libfuse 2 library: FUSE-T (/usr/local/lib/libfuse-t.dylib) or
/// macFUSE (/usr/local/lib/libfuse.2.dylib); both expose the same interface.
/// Returns 0 on success, -1 if it can't be loaded (see zf_load_error).
/// Only one library can be loaded per process.
int zf_load(const char *library_path);
const char *zf_load_error(void);

typedef struct zf_mount zf_mount;

/// Mounts the file system. options e.g. "volname=Name,rdonly". NULL on failure.
/// Note: success only means the library accepted the request, not that the
/// volume is mounted yet.
zf_mount *zf_mount_new(const char *mountpoint, const char *options,
                       const struct fuse_operations *ops, void *user_data);

/// Serves requests until the volume is unmounted (blocks).
int zf_mount_loop(zf_mount *m);

/// Unmounts through the FUSE library (only once, callable from any thread).
/// With macFUSE, its service then also removes the mount point under /Volumes.
void zf_mount_unmount(zf_mount *m);

/// Unmounts (if still needed) and frees everything.
void zf_mount_free(zf_mount *m);

/// user_data of the mount currently being served (only valid inside FUSE callbacks).
void *zf_private_data(void);

#endif
