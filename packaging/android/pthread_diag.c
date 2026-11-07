// Diagnostik: test pthread_create dengan berbagai konfigurasi scheduling
// untuk isolasi penyebab EPERM di Android 12 (Huawei TGR-W09).
#include <stdio.h>
#include <pthread.h>
#include <errno.h>
#include <string.h>
#include <sched.h>

static void* noop(void* a){ (void)a; return NULL; }

static void try(const char* label, const pthread_attr_t* attr) {
    pthread_t t;
    int rc = pthread_create(&t, attr, noop, NULL);
    if (rc == 0) {
        printf("  [OK]     %s\n", label);
        pthread_join(t, NULL);
    } else {
        printf("  [FAIL %d:%s] %s\n", rc, strerror(rc), label);
    }
}

int main(void) {
    printf("=== pthread_create scheduling diagnostic ===\n\n");

    // 1. attr NULL (default) — control
    try("1. attr=NULL (default)", NULL);

    // 2. attr initialized, no sched settings
    { pthread_attr_t a; pthread_attr_init(&a);
      try("2. attr_init only (no sched)", &a);
      pthread_attr_destroy(&a); }

    // 3. EXPLICIT_SCHED + SCHED_OTHER + priority 0 (mirip default GLib)
    { pthread_attr_t a; pthread_attr_init(&a);
      struct sched_param sp = {0};
      pthread_attr_setschedpolicy(&a, SCHED_OTHER);
      pthread_attr_setschedparam(&a, &sp);
      pthread_attr_setinheritsched(&a, PTHREAD_EXPLICIT_SCHED);
      try("3. EXPLICIT_SCHED + SCHED_OTHER pri=0", &a);
      pthread_attr_destroy(&a); }

    // 4. INHERIT_SCHED (harusnya selalu work)
    { pthread_attr_t a; pthread_attr_init(&a);
      pthread_attr_setinheritsched(&a, PTHREAD_INHERIT_SCHED);
      try("4. INHERIT_SCHED", &a);
      pthread_attr_destroy(&a); }

    // 5. EXPLICIT_SCHED + SCHED_FIFO (butuh privilege — expect EPERM)
    { pthread_attr_t a; pthread_attr_init(&a);
      struct sched_param sp = {1};
      pthread_attr_setschedpolicy(&a, SCHED_FIFO);
      pthread_attr_setschedparam(&a, &sp);
      pthread_attr_setinheritsched(&a, PTHREAD_EXPLICIT_SCHED);
      try("5. EXPLICIT_SCHED + SCHED_FIFO pri=1 (expect EPERM)", &a);
      pthread_attr_destroy(&a); }

    printf("\n=== done ===\n");
    return 0;
}
