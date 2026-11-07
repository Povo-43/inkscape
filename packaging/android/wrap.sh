#!/system/bin/sh
HERE="$(cd "$(dirname "$0")" && pwd)"
export LD_PRELOAD="$HERE/libpthread_fix.so"
exec "$@"
