#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#define TOTAL 8192
#define CHUNK 2048

int main(int argc, char **argv)
{
    signal(SIGPIPE, SIG_IGN);
    unsigned char buffer[TOTAL];
    if (argc != 2) {
        fprintf(stderr, "usage: %s FIFO\n", argv[0]);
        return 2;
    }

    pid_t child = fork();
    if (child < 0) {
        perror("fork");
        return 2;
    }

    if (child == 0) {
        int out = open(argv[1], O_WRONLY);
        if (out < 0) {
            perror("writer open");
            _exit(3);
        }
        unsigned char chunk[CHUNK];
        memset(chunk, 0x5a, sizeof(chunk));
        for (int i = 0; i < TOTAL / CHUNK; i++) {
            ssize_t n = write(out, chunk, sizeof(chunk));
            if (n < 0 && errno == EPIPE)
                break;
            if (n != (ssize_t)sizeof(chunk)) {
                perror("writer write");
                _exit(4);
            }
            usleep(250000);
        }
        close(out);
        _exit(0);
    }

    int in = open(argv[1], O_RDONLY);
    if (in < 0) {
        perror("reader open");
        kill(child, SIGKILL);
        waitpid(child, NULL, 0);
        return 5;
    }

    ssize_t got;
    do {
        got = read(in, buffer, sizeof(buffer));
    } while (got < 0 && errno == EINTR);
    if (got < 0) {
        perror("read");
        close(in);
        waitpid(child, NULL, 0);
        return 6;
    }
    close(in);

    int status = 0;
    waitpid(child, &status, 0);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
        return 7;
    printf("%zd\n", got);
    return 0;
}
