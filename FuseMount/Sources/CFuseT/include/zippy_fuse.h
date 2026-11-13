#ifndef ZIPPY_FUSE_H
#define ZIPPY_FUSE_H

#define FUSE_USE_VERSION 26
#define _FILE_OFFSET_BITS 64
#include "fuse/fuse.h"

/// Lädt eine libfuse-2-Bibliothek: FUSE-T (/usr/local/lib/libfuse-t.dylib) oder
/// macFUSE (/usr/local/lib/libfuse.2.dylib). Beide haben dieselbe Schnittstelle.
/// 0 = ok, -1 = nicht ladbar (Meldung über zf_load_error). Nur eine pro Prozess.
int zf_load(const char *library_path);
const char *zf_load_error(void);

typedef struct zf_mount zf_mount;

/// Mountet mit FUSE-T. options z. B. "volname=Name,rdonly". NULL bei Fehler.
/// Achtung: Erfolg heißt nur, dass FUSE-T den Auftrag angenommen hat.
zf_mount *zf_mount_new(const char *mountpoint, const char *options,
                       const struct fuse_operations *ops, void *user_data);

/// Bedient Anfragen, bis das Volume ausgehängt wird (blockiert).
int zf_mount_loop(zf_mount *m);

/// Hängt über die FUSE-Bibliothek aus (einmalig, aus jedem Thread). Bei macFUSE
/// räumt dessen Dienst dann auch den Mountpunkt unter /Volumes weg.
void zf_mount_unmount(zf_mount *m);

/// Hängt aus (falls noch nötig) und gibt alles frei.
void zf_mount_free(zf_mount *m);

/// user_data des gerade bedienten Mounts (nur in FUSE-Callbacks gültig).
void *zf_private_data(void);

#endif
