#pragma once

// Counts the file system calls the GUI thread makes under a watched path.
//
// A removable drive that is unplugged under an automount makes every stat,
// open or directory read of its paths block until the device times out. The
// GUI thread must therefore never touch such a path, and Qt Quick's image
// loading is as able to do so as any model: this probe sees every caller,
// because it replaces the C library's entry points for the whole test process
// rather than listening to one class.
//
// The test executable defines these functions itself, so the dynamic linker
// resolves Qt's calls to them first; each one records the call when the path
// is under the watched prefix and the thread is the process's main thread (the
// GUI thread of a Qt Test), then forwards to the C library. Include this
// header from exactly one translation unit of a test executable. Where the
// calls cannot be intercepted (a statically linked Qt) the probe sees nothing,
// so a test that relies on it first watches a path and stats it itself, as
// `tst_unavailable_root` does, rather than read silence as a pass.

#include <QString>
#include <QStringList>

#ifdef __linux__

#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

namespace gui_thread_io
{
struct State
{
    std::mutex mutex;
    std::string prefix;
    std::vector<std::string> mainThreadHits;
    int otherThreadHits{0};
};

inline State &state()
{
    static State instance;
    return instance;
}

inline bool onMainThread()
{
    return ::syscall(SYS_gettid) == ::getpid();
}

// Records `call` on `path` when `path` is the watched prefix or below it. The
// guard keeps the bookkeeping's own allocations out of the count.
inline void note(const char *call, const char *path)
{
    thread_local bool inside = false;
    if (inside || path == nullptr) {
        return;
    }
    inside = true;
    {
        State &s = state();
        const std::lock_guard<std::mutex> lock(s.mutex);
        const std::string &prefix = s.prefix;
        if (!prefix.empty() && std::string_view(path).substr(0, prefix.size()) == prefix
            && (path[prefix.size()] == '\0' || path[prefix.size()] == '/')) {
            if (onMainThread()) {
                s.mainThreadHits.push_back(std::string(call) + " " + path);
            } else {
                ++s.otherThreadHits;
            }
        }
    }
    inside = false;
}

template <typename Function>
inline Function next(const char *name)
{
    return reinterpret_cast<Function>(::dlsym(RTLD_NEXT, name));
}
}

#define MARQUEE_PROBE_CALL(Type, name) \
    static const auto real = gui_thread_io::next<Type>(name)

extern "C"
{
int open(const char *path, int flags, ...)
{
    gui_thread_io::note("open", path);
    MARQUEE_PROBE_CALL(int (*)(const char *, int, ...), "open");
    mode_t mode = 0;
    if ((flags & O_CREAT) != 0 || (flags & O_TMPFILE) == O_TMPFILE) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }
    return real(path, flags, mode);
}

int open64(const char *path, int flags, ...)
{
    gui_thread_io::note("open64", path);
    MARQUEE_PROBE_CALL(int (*)(const char *, int, ...), "open64");
    mode_t mode = 0;
    if ((flags & O_CREAT) != 0 || (flags & O_TMPFILE) == O_TMPFILE) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }
    return real(path, flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...)
{
    gui_thread_io::note("openat", path);
    MARQUEE_PROBE_CALL(int (*)(int, const char *, int, ...), "openat");
    mode_t mode = 0;
    if ((flags & O_CREAT) != 0 || (flags & O_TMPFILE) == O_TMPFILE) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }
    return real(dirfd, path, flags, mode);
}

int openat64(int dirfd, const char *path, int flags, ...)
{
    gui_thread_io::note("openat64", path);
    MARQUEE_PROBE_CALL(int (*)(int, const char *, int, ...), "openat64");
    mode_t mode = 0;
    if ((flags & O_CREAT) != 0 || (flags & O_TMPFILE) == O_TMPFILE) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }
    return real(dirfd, path, flags, mode);
}

int stat(const char *__restrict path, struct stat *__restrict buffer) __THROW
{
    gui_thread_io::note("stat", path);
    MARQUEE_PROBE_CALL(int (*)(const char *, struct stat *), "stat");
    return real(path, buffer);
}

int stat64(const char *__restrict path, struct stat64 *__restrict buffer) __THROW
{
    gui_thread_io::note("stat64", path);
    MARQUEE_PROBE_CALL(int (*)(const char *, struct stat64 *), "stat64");
    return real(path, buffer);
}

int lstat(const char *__restrict path, struct stat *__restrict buffer) __THROW
{
    gui_thread_io::note("lstat", path);
    MARQUEE_PROBE_CALL(int (*)(const char *, struct stat *), "lstat");
    return real(path, buffer);
}

int lstat64(const char *__restrict path, struct stat64 *__restrict buffer) __THROW
{
    gui_thread_io::note("lstat64", path);
    MARQUEE_PROBE_CALL(int (*)(const char *, struct stat64 *), "lstat64");
    return real(path, buffer);
}

int fstatat(int dirfd, const char *__restrict path, struct stat *__restrict buffer,
            int flags) __THROW
{
    gui_thread_io::note("fstatat", path);
    MARQUEE_PROBE_CALL(int (*)(int, const char *, struct stat *, int), "fstatat");
    return real(dirfd, path, buffer, flags);
}

int fstatat64(int dirfd, const char *__restrict path, struct stat64 *__restrict buffer,
              int flags) __THROW
{
    gui_thread_io::note("fstatat64", path);
    MARQUEE_PROBE_CALL(int (*)(int, const char *, struct stat64 *, int), "fstatat64");
    return real(dirfd, path, buffer, flags);
}

int statx(int dirfd, const char *__restrict path, int flags, unsigned int mask,
          struct statx *__restrict buffer) __THROW
{
    gui_thread_io::note("statx", path);
    MARQUEE_PROBE_CALL(int (*)(int, const char *, int, unsigned int, struct statx *), "statx");
    return real(dirfd, path, flags, mask, buffer);
}

int access(const char *path, int mode) __THROW
{
    gui_thread_io::note("access", path);
    MARQUEE_PROBE_CALL(int (*)(const char *, int), "access");
    return real(path, mode);
}

int faccessat(int dirfd, const char *path, int mode, int flags) __THROW
{
    gui_thread_io::note("faccessat", path);
    MARQUEE_PROBE_CALL(int (*)(int, const char *, int, int), "faccessat");
    return real(dirfd, path, mode, flags);
}

DIR *opendir(const char *path)
{
    gui_thread_io::note("opendir", path);
    MARQUEE_PROBE_CALL(DIR * (*)(const char *), "opendir");
    return real(path);
}

char *realpath(const char *__restrict path, char *__restrict resolved) __THROW
{
    gui_thread_io::note("realpath", path);
    MARQUEE_PROBE_CALL(char *(*)(const char *, char *), "realpath");
    return real(path, resolved);
}

ssize_t readlink(const char *__restrict path, char *__restrict buffer, size_t size) __THROW
{
    gui_thread_io::note("readlink", path);
    MARQUEE_PROBE_CALL(ssize_t (*)(const char *, char *, size_t), "readlink");
    return real(path, buffer, size);
}

FILE *fopen(const char *__restrict path, const char *__restrict mode)
{
    gui_thread_io::note("fopen", path);
    MARQUEE_PROBE_CALL(FILE * (*)(const char *, const char *), "fopen");
    return real(path, mode);
}

FILE *fopen64(const char *__restrict path, const char *__restrict mode)
{
    gui_thread_io::note("fopen64", path);
    MARQUEE_PROBE_CALL(FILE * (*)(const char *, const char *), "fopen64");
    return real(path, mode);
}
}

#undef MARQUEE_PROBE_CALL

namespace gui_thread_io
{
/// Starts counting calls under `path` (the path itself and anything below it).
inline void watch(const QString &path)
{
    State &s = state();
    const std::lock_guard<std::mutex> lock(s.mutex);
    s.prefix = path.toStdString();
    s.mainThreadHits.clear();
    s.otherThreadHits = 0;
}

inline void unwatch()
{
    watch(QString());
}

/// The calls the GUI thread made under the watched path since `watch`, each as
/// "call path".
inline QStringList mainThreadHits()
{
    State &s = state();
    const std::lock_guard<std::mutex> lock(s.mutex);
    QStringList hits;
    for (const std::string &hit : s.mainThreadHits) {
        hits.push_back(QString::fromStdString(hit));
    }
    return hits;
}

/// The calls worker threads made under the watched path since `watch`, which
/// a scan of a missing root is expected to make.
inline int otherThreadHits()
{
    State &s = state();
    const std::lock_guard<std::mutex> lock(s.mutex);
    return s.otherThreadHits;
}
}

#endif
