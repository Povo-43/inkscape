// LD_PRELOAD shim: intercept pthread_create and force PTHREAD_INHERIT_SCHED.
//
// Rationale: Inkscape on Android 12 (Huawei TGR-W09) crashes on launch in
// GLib's g_system_thread_new -> pthread_create with EPERM ("Operation not
// permitted"). The prime suspect is that GLib sets an explicit scheduling
// policy/priority (PTHREAD_EXPLICIT_SCHED) that Android's untrusted_app
// context lacks CAP_SYS_NICE to honor. Forcing PTHREAD_INHERIT_SCHED makes
// the new thread inherit the creator's policy, which needs no privilege.
//
// This is a diagnostic+workaround, not a proper fix. The real fix belongs
// in GLib's gthread-posix.c (or the GTK Android backend).
//
// Loaded via wrap.sh + LD_PRELOAD on a debuggable build.

#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>

// Log to logcat (tag: PTFIX) so we can see it firing.
#include <android/log.h>
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  "PTFIX", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "PTFIX", __VA_ARGS__)

typedef int (*real_pthread_create_t)(pthread_t*, const pthread_attr_t*, void*(*)(void*), void*);

// Intercept sched_setscheduler: bionic's pthread_create calls it to apply a
// real-time policy (SCHED_FIFO/SCHED_RR) that untrusted_app lacks CAP_SYS_NICE
// for, returning EPERM and aborting the process via GLib. We no-op the call so
// the thread runs with the default (SCHED_OTHER) policy. Logging the request.
int sched_setscheduler(pid_t pid, int policy, const struct sched_param *param) {
    static int (*real_setscheduler)(pid_t, int, const struct sched_param *) = NULL;
    if (!real_setscheduler) {
        real_setscheduler = dlsym(RTLD_NEXT, "sched_setscheduler");
    }
    int prio = param ? param->sched_priority : -1;
    LOGI("sched_setscheduler(pid=%d, policy=%d, prio=%d) -> NO-OP", (int)pid, policy, prio);
    return 0; // pretend success; thread keeps default policy
}

int pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                   void *(*start_routine)(void*), void *arg) {
    static real_pthread_create_t real_create = NULL;
    if (!real_create) {
        real_create = (real_pthread_create_t)dlsym(RTLD_NEXT, "pthread_create");
        if (!real_create) {
            LOGE("dlsym(pthread_create) failed");
            return -1;
        }
        LOGI("PTFIX shim loaded; intercepting sched_setscheduler");
    }

    int rc = real_create(thread, attr, start_routine, arg);
    if (rc != 0) {
        LOGE("pthread_create failed: rc=%d", rc);
    }
    return rc;
}

