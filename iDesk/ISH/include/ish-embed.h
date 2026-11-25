// iDesk local shell: public interface to the embedded iSH-ARM64 kernel.
// Boot runs a full Alpine Linux (aarch64) userland on a dedicated thread;
// the console tty is wired to these callbacks.

#ifndef IDESK_SHELL_H
#define IDESK_SHELL_H

#ifdef __cplusplus
extern "C" {
#endif

// Guest output (console bytes for the terminal).
typedef void (*idesk_shell_output_cb)(const void *buf, int len);
void idesk_shell_set_output_callback(idesk_shell_output_cb cb);

// Boots the Alpine rootfs (the fakefs directory containing data/ and meta.db) and runs
// /bin/sh on the CALLING thread. Returns only when the shell exits; a negative value is
// a boot error (kernel -errno).
int idesk_shell_boot(const char *rootfs);

// Keyboard input for the shell, and the terminal size (set before boot for the initial size).
void idesk_shell_input(const char *bytes, int len);
void idesk_shell_resize(int cols, int rows);

extern int idesk_shell_cols;
extern int idesk_shell_rows;

#ifdef __cplusplus
}
#endif

#endif
