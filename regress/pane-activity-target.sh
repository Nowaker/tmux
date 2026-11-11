#!/bin/sh

# A pane event must target the newest owning session and its current link,
# even when a newer unrelated session exists or a window has duplicate links.

PATH=/bin:/usr/bin
TERM=screen
export TERM
[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Lvt-looprig-activity-$$ -f/dev/null"
DIR=$(mktemp -d) || exit 1
cleanup()
{
	$TMUX kill-server 2>/dev/null
	rm -rf "$DIR"
}
trap cleanup 0 1 15
fail()
{
	echo "$*" >&2
	exit 1
}

$TMUX new-session -d -s first 'sleep 100' || exit 1
$TMUX set -g automatic-rename off || exit 1
pane=$($TMUX display -pt first:0 '#{pane_id}') || exit 1
$TMUX new-session -d -s second 'sleep 100' || exit 1
$TMUX link-window -s first:0 -t second:3 || exit 1
$TMUX link-window -s first:0 -t second:7 || exit 1
$TMUX select-window -t second:7 || exit 1
$TMUX new-session -d -s unrelated 'sleep 100' || exit 1
$TMUX set-hook -p -t "$pane" pane-activity \
	'set -gF @activity-session "#{session_name}" ; set -gF @activity-link "#{window_index}" ; set -gF @activity-pane "#{pane_id}"' || exit 1
$TMUX respawn-pane -k -t "$pane" \
	"while [ ! -f '$DIR/go' ]; do sleep 0.01; done; printf 'activity'; sleep 100" || exit 1
: >"$DIR/go"
i=0
while [ "$i" -lt 100 ]; do
	got=$($TMUX show -gqv @activity-pane) || exit 1
	[ "$got" = "$pane" ] && break
	sleep 0.05
	i=$((i + 1))
done
[ "$got" = "$pane" ] || fail 'pane-activity hook did not run'
[ "$($TMUX show -gqv @activity-session)" = second ] ||
	fail 'pane event chose an unrelated or older session'
[ "$($TMUX show -gqv @activity-link)" = 7 ] ||
	fail 'pane event did not choose the current duplicate link'
exit 0
