#!/bin/sh
# Entrypoint for the CockroachDB runtime image.
#
# Accepts the same arguments as the official cockroachdb/cockroach image, so
# Kubernetes manifests, the CockroachDB Helm chart and docker-compose files
# written for that image work unchanged:
#
#   shell [ARGS...]   run /bin/sh ARGS...   (the Helm chart starts nodes with
#                     `shell -ecx "exec /cockroach/cockroach start ..."`)
#   bash [ARGS...]    run /bin/bash ARGS...
#   anything else     run /cockroach/cockroach with those arguments
#
# If COCKROACH_ARGS is set, it replaces the arguments (split on whitespace).
#
# Not included: the official image's first-run helper for `start-single-node`
# (generated certificates, COCKROACH_DATABASE / COCKROACH_USER /
# COCKROACH_PASSWORD, /docker-entrypoint-initdb.d). Pass --insecure or mount
# certificates instead.
set -eu

if [ -n "${COCKROACH_ARGS:-}" ]; then
  # COCKROACH_ARGS holds a whole command line: split it, but don't glob it.
  set -f
  # shellcheck disable=SC2086
  set -- $COCKROACH_ARGS
  set +f
fi

case "${1:-}" in
  "")
    echo "usage: <cockroach command> [flags...] | shell [args...] | bash [args...]" >&2
    exit 2
    ;;
  shell)
    shift
    exec /bin/sh "$@"
    ;;
  bash)
    shift
    exec /bin/bash "$@"
    ;;
  *)
    exec "${COCKROACH:-/cockroach/cockroach}" "$@"
    ;;
esac
