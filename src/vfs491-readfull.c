#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>

typedef ssize_t (*read_fn)(int, void *, size_t);

static read_fn real_read;
static __thread int resolving;

static read_fn get_real_read(void)
{
    if (!real_read && !resolving) {
        resolving = 1;
        real_read = (read_fn)dlsym(RTLD_NEXT, "read");
        resolving = 0;
    }
    return real_read;
}

static int is_event_fifo(int fd)
{
    char proc[64], target[PATH_MAX];

    snprintf(proc, sizeof(proc), "/proc/self/fd/%d", fd);

    ssize_t n = readlink(proc, target, sizeof(target) - 1);
    if (n <= 0)
        return 0;

    target[n] = '\0';
    return strstr(target, "/tmp/CH_EVENT") != NULL;
}

ssize_t read(int fd, void *buf, size_t count)
{
    if (resolving)
        return syscall(SYS_read, fd, buf, count);

    read_fn fn = get_real_read();
    if (!fn) {
        errno = ENOSYS;
        return -1;
    }

    int event_fifo = is_event_fifo(fd);
    ssize_t first = fn(fd, buf, count);

    if (first <= 0 || !event_fifo ||
        count < 4096 || (size_t)first >= count)
        return first;

    size_t total = (size_t)first;

    while (total < count) {
        ssize_t n = fn(fd, (char *)buf + total, count - total);

        if (n > 0) {
            total += (size_t)n;
            continue;
        }

        if (n < 0 && errno == EINTR)
            continue;

        break;
    }

    return (ssize_t)total;
}
