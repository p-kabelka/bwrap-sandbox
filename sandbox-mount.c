/*
 * sandbox-mount: inject a bind mount into a running sandbox's mount namespace.
 *
 * Uses open_tree() + move_mount() (Linux 5.2+) — the correct API for
 * cross-namespace mount injection. The naive setns() + mount(MS_BIND)
 * approach fails because the kernel enforces that source and target mounts
 * are both in the caller's mount namespace.
 *
 * See: https://people.kernel.org/brauner/mounting-into-mount-namespaces
 *
 * Build: gcc -Wall -O2 -o sandbox-mount sandbox-mount.c
 * Usage: sandbox-mount <pid> <host-path> <sandbox-path>
 *   Must be run as root (CAP_SYS_ADMIN in the initial user namespace).
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef OPEN_TREE_CLONE
#define OPEN_TREE_CLONE 1
#endif

#ifndef OPEN_TREE_CLOEXEC
#define OPEN_TREE_CLOEXEC O_CLOEXEC
#endif

#ifndef MOVE_MOUNT_F_EMPTY_PATH
#define MOVE_MOUNT_F_EMPTY_PATH 0x00000004
#endif

#ifndef AT_RECURSIVE
#define AT_RECURSIVE 0x8000
#endif

static int sys_open_tree(int dirfd, const char *path, unsigned int flags)
{
    return syscall(SYS_open_tree, dirfd, path, flags);
}

static int sys_move_mount(int from_dirfd, const char *from_path,
                          int to_dirfd, const char *to_path,
                          unsigned int flags)
{
    return syscall(SYS_move_mount, from_dirfd, from_path,
                   to_dirfd, to_path, flags);
}

int main(int argc, char *argv[])
{
    if (argc != 4) {
        fprintf(stderr, "Usage: %s <pid> <host-path> <sandbox-path>\n",
                argv[0]);
        return 1;
    }

    int pid = atoi(argv[1]);
    const char *host_path = argv[2];
    const char *sandbox_path = argv[3];

    if (pid <= 0) {
        fprintf(stderr, "Error: invalid PID '%s'\n", argv[1]);
        return 1;
    }

    /*
     * Step 1: Clone the source mount while in the host namespace.
     * The result is a "detached" mount not belonging to any namespace.
     */
    int fd_tree = sys_open_tree(AT_FDCWD, host_path,
                                OPEN_TREE_CLONE |
                                OPEN_TREE_CLOEXEC |
                                AT_RECURSIVE);
    if (fd_tree < 0) {
        fprintf(stderr, "open_tree(%s): %s\n",
                host_path, strerror(errno));
        return 1;
    }

    /*
     * Step 2: Enter the sandbox's mount namespace.
     * Requires CAP_SYS_ADMIN in the user namespace that owns the
     * target mount namespace. Root in the initial user namespace
     * satisfies this via ns_capable().
     *
     * We do NOT enter the user namespace — that would clear all
     * capabilities (root's UID 0 is unmapped in the sandbox's
     * user namespace).
     */
    char ns_path[256];
    snprintf(ns_path, sizeof(ns_path), "/proc/%d/ns/mnt", pid);

    int fd_mntns = open(ns_path, O_RDONLY | O_CLOEXEC);
    if (fd_mntns < 0) {
        fprintf(stderr, "open(%s): %s\n", ns_path, strerror(errno));
        if (errno == ENOENT)
            fprintf(stderr, "  (process %d does not exist)\n", pid);
        close(fd_tree);
        return 1;
    }

    if (setns(fd_mntns, CLONE_NEWNS) < 0) {
        fprintf(stderr, "setns(CLONE_NEWNS): %s\n", strerror(errno));
        if (errno == EPERM)
            fprintf(stderr,
                    "  Possible causes:\n"
                    "  - Not running as root\n"
                    "  - SELinux is blocking setns "
                    "(check: sudo ausearch -m avc -ts recent)\n");
        close(fd_mntns);
        close(fd_tree);
        return 1;
    }
    close(fd_mntns);

    /*
     * Step 3: Attach the detached mount at the target path.
     * The target directory must already exist (created by the caller
     * on the host-backed filesystem before invoking this helper).
     *
     * move_mount with MOVE_MOUNT_F_EMPTY_PATH uses the fd directly,
     * bypassing the cross-namespace source-mount check that
     * mount(MS_BIND) enforces.
     */
    if (sys_move_mount(fd_tree, "", AT_FDCWD, sandbox_path,
                       MOVE_MOUNT_F_EMPTY_PATH) < 0) {
        fprintf(stderr, "move_mount(%s): %s\n",
                sandbox_path, strerror(errno));
        if (errno == ENOENT)
            fprintf(stderr,
                    "  (target directory does not exist "
                    "in the sandbox)\n");
        close(fd_tree);
        return 1;
    }
    close(fd_tree);

    return 0;
}
