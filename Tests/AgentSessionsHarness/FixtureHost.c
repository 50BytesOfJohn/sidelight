// A test-only inert process named codex, to exercise kernel-based writer-lock discovery.
// No vendor CLI, agent prompts, network, auth, shell commands or history writes.
#include <fcntl.h>
#include <unistd.h>
#include <sys/file.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    for (int i = 1; i < argc; i++) {
        int fd = open(argv[i], O_RDONLY);
        if (fd < 0 || flock(fd, LOCK_EX | LOCK_NB) != 0) return 3;
    }
    for (;;) pause();
}
