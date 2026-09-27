/*
 * ckm_input.c - tiny native helper for customkeymapper.koplugin.
 *
 * The plugin must run on a jailbroken Kindle whose kernel does not have the
 * USB HID modules built in. Historically the user loaded them at boot via the
 * KindleLazy extension. To drop that runtime dependency the plugin self-loads
 * the matching hid.ko / usbhid.ko / mousedev.ko from its own lib/modules/ by
 * calling ckm_load_hid() during init.
 *
 * This DSO intentionally links against libc only (no LibreMouse / no C++), so
 * it stays small and easy to audit. It is cross-compiled with Zig for the same
 * ABI as the rime plugin (kindlepw2: arm-linux-gnueabi.2.12, softfp,
 * cortex_a9); the Zig wrapper and the target definitions come from the pinned
 * librime_koreader submodule. Only ckm_* symbols are exported (see ckm.map).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define CKM_ABI_VERSION 1

/* Keep buffers small: this runs on an e-ink device with limited RAM. */
#define PATH_CAP 512
#define NAME_CAP 128

/*
 * Run a module-management utility (insmod / rmmod).  Try the usual absolute
 * locations first (BusyBox on Kindle installs them in /sbin or /bin), then
 * fall back to the PATH lookup.  Returns the child's exit status, or -1 on
 * fork/wait failure, or 127 when the utility could not be executed at all.
 */
static int run_mod_cmd(const char *cmd, const char *arg)
{
    /* Build absolute candidate paths in the parent (before fork). The child
     * must not touch malloc/snprintf (async-signal-safety), so it only execs a
     * pre-built path. */
    char candidates[4][PATH_CAP];
    int n = 0;
    snprintf(candidates[n++], sizeof(candidates[0]), "/sbin/%s", cmd);
    snprintf(candidates[n++], sizeof(candidates[0]), "/bin/%s", cmd);
    snprintf(candidates[n++], sizeof(candidates[0]), "/usr/sbin/%s", cmd);
    snprintf(candidates[n++], sizeof(candidates[0]), "/usr/bin/%s", cmd);

    pid_t pid = fork();
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        for (int i = 0; i < n; ++i) {
            execl(candidates[i], cmd, arg, (char *)NULL);
        }
        _exit(127);
    }

    int status = -1;
    if (waitpid(pid, &status, 0) < 0) {
        return -1;
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return -1;
}

/* Report whether a kernel module is already loaded (see /proc/modules). */
static int module_loaded(const char *name)
{
    FILE *f = fopen("/proc/modules", "r");
    if (!f) {
        return 0;
    }

    char line[PATH_CAP];
    int found = 0;
    while (fgets(line, sizeof(line), f)) {
        char mod[NAME_CAP];
        if (sscanf(line, "%127s", mod) == 1 && strcmp(mod, name) == 0) {
            found = 1;
            break;
        }
    }
    fclose(f);
    return found;
}

/* Return the ABI version compiled into this DSO. */
__attribute__((visibility("default")))
int ckm_abi_version(void)
{
    return CKM_ABI_VERSION;
}

/*
 * Load the USB HID kernel modules from ko_dir, in dependency order:
 *   hid.ko -> usbhid.ko -> mousedev.ko (mousedev is optional).
 * Idempotent: already-loaded modules are skipped.  Returns 0 on success,
 * a negative errno value on a hard failure, or a positive insmod exit status.
 *
 * Note that usbhid depends on hid, so hid must load first.  The kernel
 * enumerates any already-attached HID device asynchronously after usbhid
 * binds, so the caller waits a beat before rescanning /dev/input.
 */
__attribute__((visibility("default")))
int ckm_load_hid(const char *ko_dir)
{
    if (!ko_dir || !ko_dir[0]) {
        return -EINVAL;
    }

    struct stat st;
    if (stat(ko_dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        fprintf(stderr, "ckm: module dir not found: %s\n", ko_dir);
        return -ENOENT;
    }

    static const char *modules[] = { "hid.ko", "usbhid.ko", "mousedev.ko" };
    static const char *names[]   = { "hid",    "usbhid",    "mousedev" };

    for (int i = 0; i < 3; ++i) {
        if (module_loaded(names[i])) {
            continue; /* already in the kernel */
        }

        char path[PATH_CAP];
        snprintf(path, sizeof(path), "%s/%s", ko_dir, modules[i]);
        if (access(path, R_OK) != 0) {
            if (i == 2) {
                /* mousedev is optional: a mouse-less page-turner still works. */
                fprintf(stderr, "ckm: optional module not present: %s\n", path);
                continue;
            }
            fprintf(stderr, "ckm: module not present: %s\n", path);
            return -ENOENT;
        }

        int rc = run_mod_cmd("insmod", path);
        if (rc == 127) {
            fprintf(stderr, "ckm: insmod utility not found\n");
            return -ENOENT;
        }
        if (rc != 0) {
            /* A race could have loaded it meanwhile; treat that as success. */
            if (module_loaded(names[i])) {
                fprintf(stderr, "ckm: %s already loaded\n", names[i]);
                continue;
            }
            fprintf(stderr, "ckm: insmod %s failed (rc=%d)\n", path, rc);
            return rc;
        }

        /* Let the kernel register the module and any associated device. */
        usleep(200000);
    }

    return 0;
}

/*
 * Unload the USB HID modules in reverse dependency order.  Optional: the
 * plugin currently only calls this from an explicit debug hook, so that a
 * reloaded module set lines up with a fresh KOReader run.
 */
__attribute__((visibility("default")))
int ckm_unload_hid(void)
{
    static const char *names[] = { "mousedev", "usbhid", "hid" };

    for (int i = 0; i < 3; ++i) {
        if (!module_loaded(names[i])) {
            continue;
        }
        int rc = run_mod_cmd("rmmod", names[i]);
        if (rc != 0 && rc != 127) {
            /* Not fatal: report and keep going. */
            fprintf(stderr, "ckm: rmmod %s failed (rc=%d)\n", names[i], rc);
        }
    }
    return 0;
}
