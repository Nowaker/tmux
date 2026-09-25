#!/bin/sh
# Build ./tmux the way vibeterm runs it: in-tree, with systemd support.
#
# --enable-systemd (and --enable-cgroups, which follows it) compiles in
# compat/systemd.c, so spawn.c moves every new pane into its own
# tmux-spawn-<uuid>.scope inside the server's slice. Each tab and tool window
# is then a separate cgroup leaf: systemd-oomd or a kernel memcg OOM takes one
# pane, never the server and all of its panes (incident #16, dotfiles
# crash-reports 2026-09-24). A build without it keeps every pane in the
# server's own cgroup.
#
# Always a clean build: configure changes the -D flags in the Makefile, and
# automake's dependency tracking does not rebuild objects for that. Reusing a
# tree configured without systemd links libsystemd through compat/systemd.o
# while spawn.o still has the pane-scope call compiled out, so the check below
# looks at spawn.o, not only at what the binary links.
#
# Extra arguments go to ./configure. The linker unlinks ./tmux before writing
# the new one, so a server already running from it keeps its old code until it
# restarts.
set -eu
cd "$(dirname "$0")"
[ -x configure ] || sh autogen.sh
./configure --enable-systemd "$@"
make clean
make -j"$(nproc)"
if ! nm -u spawn.o | grep -q systemd_move_to_new_cgroup; then
	echo "vibeterm-build: spawn.o does not move panes into scopes; per-pane scopes are compiled out" >&2
	exit 1
fi
if ! ldd ./tmux | grep -q libsystemd; then
	echo "vibeterm-build: ./tmux does not link libsystemd; per-pane scopes are compiled out" >&2
	exit 1
fi
echo "vibeterm-build: $(./tmux -V) with systemd pane scopes: $(pwd)/tmux"
