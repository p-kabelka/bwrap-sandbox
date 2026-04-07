/*
 * sandbox-mount: inject a bind mount into a running sandbox's mount namespace.
 *
 * Uses open_tree() + move_mount() (Linux 5.2+) — the correct API for
 * cross-namespace mount injection. The naive setns() + mount(MS_BIND)
 * approach fails because the kernel enforces that source and target mounts
 * are both in the caller's mount namespace.
 *
 * Supports read-only mounts via mount_setattr() (Linux 5.12+) and
 * path hiding via fsopen("tmpfs") + fsmount() + move_mount().
 *
 * See: https://people.kernel.org/brauner/mounting-into-mount-namespaces
 *
 * Build: gcc -Wall -O2 -o sandbox-mount sandbox-mount.c
 * Usage: sandbox-mount [-r] [-H path]... <pid> <host-path> <sandbox-path>
 *   Must be run as root (CAP_SYS_ADMIN in the initial user namespace).
 *
 * Note: hide operations (-H) are applied immediately after the main mount.
 * The sandbox process is frozen with SIGSTOP during the mount+hide sequence
 * to prevent it from observing hidden paths before they are masked.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <limits.h>
#include <linux/mount.h>
#include <sched.h>
#include <sys/mount.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <signal.h>
#include <sys/syscall.h>
#include <unistd.h>

static int sys_open_tree(int dirfd, const char *path, unsigned int flags)
{
    return syscall(SYS_open_tree, dirfd, path, flags);
}

static int sys_move_mount(int from_dirfd, const char *from_path, int to_dirfd, const char *to_path, unsigned int flags)
{
    return syscall(SYS_move_mount, from_dirfd, from_path, to_dirfd, to_path, flags);
}

static int sys_mount_setattr(int dirfd, const char *path, unsigned int flags, struct mount_attr *attr, size_t size)
{
    return syscall(SYS_mount_setattr, dirfd, path, flags, attr, size);
}

static int sys_fsopen(const char *fsname, unsigned int flags)
{
    return syscall(SYS_fsopen, fsname, flags);
}

static int sys_fsconfig(int fd, unsigned int cmd, const char *key, const void *value, int aux)
{
    return syscall(SYS_fsconfig, fd, cmd, key, value, aux);
}

static int sys_fsmount(int fd, unsigned int flags, unsigned int attr_flags)
{
    return syscall(SYS_fsmount, fd, flags, attr_flags);
}

static int sys_pidfd_open(pid_t pid, unsigned int flags)
{
    return syscall(SYS_pidfd_open, pid, flags);
}

/*
 * Set a detached mount's propagation to MS_PRIVATE.
 * Prevents mount events from propagating to peer mounts,
 * which can cause duplicate mounts when the target is
 * under a shared mount.
 * Returns 0 on success, -1 on error.
 */
static int set_mount_private(int fd_mount)
{
    struct mount_attr attr = {
        .propagation = MS_PRIVATE,
    };
    if (sys_mount_setattr(fd_mount, "", AT_EMPTY_PATH, &attr, sizeof(attr)) < 0) {
        fprintf(stderr, "mount_setattr(MS_PRIVATE): %s\n", strerror(errno));
        return -1;
    }
    return 0;
}

/*
 * Create a detached clone of /dev/null.
 * Used to hide regular files — reads return EOF.
 * Returns an fd for the mount, or -1 on error.
 */
static int create_devnull_clone(void)
{
    int fd = sys_open_tree(AT_FDCWD, "/dev/null", OPEN_TREE_CLONE | OPEN_TREE_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "open_tree(/dev/null): %s\n", strerror(errno));
    }
    return fd;
}

/*
 * Create a detached empty tmpfs mount.
 * Used to hide directories — appears as empty directory.
 * Returns an fd for the mount, or -1 on error.
 */
static int create_empty_tmpfs(void)
{
    int fd_fs = sys_fsopen("tmpfs", FSMOUNT_CLOEXEC);
    if (fd_fs < 0) {
        fprintf(stderr, "fsopen(tmpfs): %s\n", strerror(errno));
        return -1;
    }

    if (sys_fsconfig(fd_fs, FSCONFIG_CMD_CREATE, NULL, NULL, 0) < 0) {
        fprintf(stderr, "fsconfig(CMD_CREATE): %s\n", strerror(errno));
        close(fd_fs);
        return -1;
    }

    int fd_mnt = sys_fsmount(fd_fs, FSMOUNT_CLOEXEC, 0);
    if (fd_mnt < 0) {
        fprintf(stderr, "fsmount: %s\n", strerror(errno));
        close(fd_fs);
        return -1;
    }

    close(fd_fs);
    return fd_mnt;
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s [-r] [-H path]... <pid> <host-path> <sandbox-path>\n"
            "\n"
            "  -r           Mount read-only\n"
            "  -H path      Hide a relative path within the mounted directory\n"
            "               (can be specified multiple times)\n",
            prog);
}

int main(int argc, char *argv[])
{
    int rc = 0;
    int readonly = 0;
    int hide_count = 0;
    int fd_path = -1;
    int fd_tree = -1;
    int fd_mntns = -1;
    int pidfd = -1;
    int stopped = 0;

    /* Allocate upfront — can't have more -H flags than argc entries */
    const char **hide_paths = calloc(argc, sizeof(*hide_paths));
    if (!hide_paths) {
        fprintf(stderr, "calloc: %s\n", strerror(errno));
        return 1;
    }

    int opt;
    while ((opt = getopt(argc, argv, "rH:")) != -1) {
        switch (opt) {
        case 'r':
            readonly = 1;
            break;
        case 'H':
            hide_paths[hide_count++] = optarg;
            break;
        default:
            usage(argv[0]);
            rc = 1;
            goto cleanup;
        }
    }

    if (argc - optind != 3) {
        usage(argv[0]);
        rc = 1;
        goto cleanup;
    }

    char *endptr;
    errno = 0;
    long pid_long = strtol(argv[optind], &endptr, 10);
    if (errno || *endptr != '\0' || pid_long <= 0 || pid_long > INT_MAX) {
        fprintf(stderr, "Error: invalid PID '%s'\n", argv[optind]);
        rc = 1;
        goto cleanup;
    }
    int pid = (int)pid_long;
    const char *host_path = argv[optind + 1];
    const char *sandbox_path = argv[optind + 2];

    /*
     * Pin the PID to prevent recycling between our check and setns().
     * pidfd_open() returns an fd that holds a reference to the process.
     * Requires Linux 5.3+.
     */
    pidfd = sys_pidfd_open(pid, 0);
    if (pidfd < 0) {
        if (errno == ENOSYS) {
            fprintf(stderr, "pidfd_open: not supported (kernel < 5.3)\n");
        } else {
            fprintf(stderr, "pidfd_open(%d): %s (process gone?)\n", pid, strerror(errno));
        }
        rc = 1;
        goto cleanup;
    }

    /*
     * Step 1: Clone the source mount while in the host namespace.
     * The result is a "detached" mount not belonging to any namespace.
     *
     * Open the path with O_PATH first to resolve symlinks atomically
     * in the kernel, then clone from the resulting fd. This prevents
     * a TOCTOU race where the path could be swapped between a shell-side
     * realpath() and the open_tree() call.
     */
    fd_path = open(host_path, O_PATH | O_CLOEXEC);
    if (fd_path < 0) {
        fprintf(stderr, "open(%s): %s\n", host_path, strerror(errno));
        rc = 1;
        goto cleanup;
    }
    fd_tree = sys_open_tree(fd_path, "", OPEN_TREE_CLONE | OPEN_TREE_CLOEXEC | AT_RECURSIVE | AT_EMPTY_PATH);
    close(fd_path);
    fd_path = -1;
    if (fd_tree < 0) {
        fprintf(stderr, "open_tree(%s): %s\n", host_path, strerror(errno));
        rc = 1;
        goto cleanup;
    }

    /*
     * Step 2 (optional): Make the mount read-only.
     */
    if (readonly) {
        struct mount_attr attr = {
            .attr_set = MOUNT_ATTR_RDONLY,
        };
        if (sys_mount_setattr(fd_tree, "", AT_EMPTY_PATH, &attr, sizeof(attr)) < 0) {
            fprintf(stderr, "mount_setattr(RDONLY): %s\n", strerror(errno));
            rc = 1;
            goto cleanup;
        }
    }

    /*
     * Step 3: Enter the sandbox's mount namespace.
     * Requires CAP_SYS_ADMIN in the user namespace that owns the
     * target mount namespace. Root in the initial user namespace
     * satisfies this via ns_capable().
     *
     * We do NOT enter the user namespace — that would clear all
     * capabilities (root's UID 0 is unmapped in the sandbox's
     * user namespace).
     */
    char ns_path[PATH_MAX];
    snprintf(ns_path, sizeof(ns_path), "/proc/%d/ns/mnt", pid);

    fd_mntns = open(ns_path, O_RDONLY | O_CLOEXEC);
    if (fd_mntns < 0) {
        fprintf(stderr, "open(%s): %s\n", ns_path, strerror(errno));
        if (errno == ENOENT) {
            fprintf(stderr, "  (process %d does not exist)\n", pid);
        }
        rc = 1;
        goto cleanup;
    }

    if (setns(fd_mntns, CLONE_NEWNS) < 0) {
        fprintf(stderr, "setns(CLONE_NEWNS): %s\n", strerror(errno));
        if (errno == EPERM) {
            fprintf(stderr,
                    "  Possible causes:\n"
                    "  - Not running as root\n"
                    "  - SELinux is blocking setns "
                    "(check: sudo ausearch -m avc -ts recent)\n");
        }
        rc = 1;
        goto cleanup;
    }
    close(fd_mntns);
    fd_mntns = -1;
    close(pidfd);
    pidfd = -1;

    /*
     * Step 3.5: Make all mounts in the sandbox recursively private.
     * bwrap's bind mounts inherit shared propagation from the host
     * filesystem, causing move_mount() to create duplicate mounts
     * in peer mounts. Making the tree private prevents this.
     * This is idempotent — already-private mounts are unaffected.
     */
    if (mount("none", "/", NULL, MS_REC | MS_PRIVATE, NULL) < 0) {
        fprintf(stderr, "mount(MS_REC|MS_PRIVATE): %s\n", strerror(errno));
        rc = 1;
        goto cleanup;
    }

    /*
     * Step 4: Attach the detached mount at the target path.
     * The target directory must already exist (created by the caller
     * on the host-backed filesystem before invoking this helper).
     *
     * Set propagation to private first — shared propagation from the
     * parent mount would cause duplicate mounts in peer mounts.
     */
    if (set_mount_private(fd_tree) < 0) {
        rc = 1;
        goto cleanup;
    }

    /* Freeze the sandbox process during mount+hide to eliminate the
     * race window where hidden paths are briefly visible. */
    if (hide_count > 0) {
        if (kill(pid, SIGSTOP) < 0) {
            fprintf(stderr, "kill(%d, SIGSTOP): %s\n", pid, strerror(errno));
            rc = 1;
            goto cleanup;
        }
        stopped = 1;
    }

    if (sys_move_mount(fd_tree, "", AT_FDCWD, sandbox_path, MOVE_MOUNT_F_EMPTY_PATH) < 0) {
        fprintf(stderr, "move_mount(%s): %s\n", sandbox_path, strerror(errno));
        if (errno == ENOENT) {
            fprintf(stderr, "  (target directory does not exist in the sandbox)\n");
        }
        rc = 1;
        goto cleanup;
    }
    close(fd_tree);
    fd_tree = -1;

    /*
     * Step 5: Hide paths by mounting over them.
     * Each -H path is relative to sandbox_path.
     *   Directories: mount an empty tmpfs (appears as empty dir).
     *   Files: mount a clone of /dev/null (reads return EOF).
     *
     * The concatenated path cannot exceed PATH_MAX — the kernel
     * rejects any path >= PATH_MAX in syscalls anyway.
     *
     * The sandbox process is frozen (SIGSTOP) during the mount+hide
     * sequence to prevent observing hidden paths before they are masked.
     */
    char hide_target[PATH_MAX];
    for (int i = 0; i < hide_count; i++) {
        int n = snprintf(hide_target, sizeof(hide_target), "%s/%s", sandbox_path, hide_paths[i]);
        if (n < 0 || (size_t)n >= sizeof(hide_target)) {
            fprintf(stderr, "Error: hide path too long: %s/%s\n", sandbox_path, hide_paths[i]);
            rc = 1;
            goto cleanup;
        }

        struct stat st;
        if (stat(hide_target, &st) < 0) {
            fprintf(stderr, "stat(%s): %s\n", hide_target, strerror(errno));
            rc = 1;
            goto cleanup;
        }

        int fd_mask = S_ISDIR(st.st_mode) ? create_empty_tmpfs() : create_devnull_clone();
        if (fd_mask < 0) {
            rc = 1;
            goto cleanup;
        }

        if (set_mount_private(fd_mask) < 0) {
            close(fd_mask);
            rc = 1;
            goto cleanup;
        }
        if (sys_move_mount(fd_mask, "", AT_FDCWD, hide_target, MOVE_MOUNT_F_EMPTY_PATH) < 0) {
            fprintf(stderr, "move_mount(hide %s): %s\n", hide_target, strerror(errno));
            if (errno == ENOENT) {
                fprintf(stderr, "  (path '%s' does not exist under '%s')\n", hide_paths[i], sandbox_path);
            }
            close(fd_mask);
            rc = 1;
            goto cleanup;
        }
        close(fd_mask);
    }

    if (stopped) {
        kill(pid, SIGCONT);
        stopped = 0;
    }

cleanup:
    if (stopped) {
        kill(pid, SIGCONT);
    }
    if (fd_path >= 0) {
        close(fd_path);
    }
    if (fd_tree >= 0) {
        close(fd_tree);
    }
    if (fd_mntns >= 0) {
        close(fd_mntns);
    }
    if (pidfd >= 0) {
        close(pidfd);
    }
    free(hide_paths);
    return rc;
}
