// iDesk local shell: boots the iSH-ARM64 kernel (Alpine Linux, aarch64 guest) and wires its
// console to the app through callbacks instead of stdio. Modeled on iSH's main.c / xX_main_Xx.h,
// but the console tty is ours, so SwiftTerm in iDesk shows the shell and keyboard input reaches it.

#include <pthread.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>

#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/fs.h"
#include "fs/devices.h"
#include "fs/dev.h"
#include "fs/path.h"
#include "fs/tty.h"
#include "fs/real.h"
#include "misc.h"

#include "ish-embed.h"

// MARK: - Console driver: guest output goes to the app's callback

int idesk_shell_cols = 80;
int idesk_shell_rows = 24;

static idesk_shell_output_cb output_cb;
static struct tty *console_tty;

void idesk_shell_set_output_callback(idesk_shell_output_cb cb) {
    output_cb = cb;
}

static int idesk_tty_open(struct tty *tty) {
    console_tty = tty;
    lock(&tty->lock);
    tty->winsize.col = idesk_shell_cols;
    tty->winsize.row = idesk_shell_rows;
    unlock(&tty->lock);
    return 0;
}

static int idesk_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    (void) tty;
    if (output_cb != NULL && len > 0)
        output_cb(buf, (int) len);
    return (int) len;
}

static struct tty_driver_ops idesk_tty_ops = {
    .open = idesk_tty_open,
    .write = idesk_tty_write,
};
DEFINE_TTY_DRIVER(idesk_tty_driver, &idesk_tty_ops, TTY_CONSOLE_MAJOR, 64);

// MARK: - App → guest

void idesk_shell_input(const char *bytes, int len) {
    struct tty *tty = console_tty;
    if (tty == NULL || len <= 0)
        return;
    tty_input(tty, bytes, len, false);
}

void idesk_shell_resize(int cols, int rows) {
    idesk_shell_cols = cols;
    idesk_shell_rows = rows;
    struct tty *tty = console_tty;
    if (tty == NULL)
        return;
    lock(&tty->lock);
    struct winsize_ ws = { .row = rows, .col = cols };
    // tty_set_winsize also sends SIGWINCH to the foreground process group, so TUI apps redraw.
    tty_set_winsize(tty, ws);
    unlock(&tty->lock);
}

// MARK: - Boot

// Default DNS for apk etc. (the Alpine minirootfs has an empty resolv.conf).
static void write_resolv_conf(void) {
    struct fd *f = generic_open("/etc/resolv.conf", O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0644);
    if (IS_ERR(f))
        return;
    static const char config[] = "nameserver 1.1.1.1\nnameserver 8.8.8.8\n";
    f->ops->write(f, config, sizeof(config) - 1);
    fd_close(f);
}

static void make_dev_nodes(void) {
    generic_mknodat(AT_PWD, "/dev/null", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/console", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));
}

// Runs the Alpine shell on the CALLING thread; returns only when the shell exits.
// rootfs: the fakefs directory (the one containing data/ and meta.db).
int idesk_shell_boot(const char *rootfs) {
    char root[MAX_PATH];
    strcpy(root, rootfs);
    strcat(root, "/data");
    int err = mount_root(&fakefs, root);
    if (err < 0)
        return err;

    become_first_process();
    current->thread = pthread_self();
    make_dev_nodes();
    write_resolv_conf();

    static char argv_buf[] = "/bin/sh\0-l\0";
    static char envp_buf[] =
        "TERM=xterm-256color\0"
        "HOME=/root\0"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"
        "PYTHONMALLOC=malloc\0";
    err = do_execve("/bin/sh", 2, argv_buf, envp_buf);
    if (err < 0)
        return err;

    tty_drivers[TTY_CONSOLE_MAJOR] = &idesk_tty_driver;
    err = create_stdio("/dev/tty1", TTY_CONSOLE_MAJOR, 1);
    if (err < 0)
        return err;

    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    task_run_current();
    return 0;
}
