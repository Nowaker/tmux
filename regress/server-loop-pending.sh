#!/bin/sh

# Output and timers in an unattended window must survive until it is selected.

PATH=/bin:/usr/bin
TERM=screen
export TERM
[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
INNER="$TEST_TMUX -Lvt-looprig-pending-inner-$$ -f/dev/null"
OUTER="$TEST_TMUX -Lvt-looprig-pending-outer-$$ -f/dev/null"
DIR=$(mktemp -d) || exit 1
cleanup()
{
	$OUTER kill-server 2>/dev/null
	$INNER kill-server 2>/dev/null
	rm -rf "$DIR"
}
trap cleanup 0 1 15
fail()
{
	echo "$*" >&2
	exit 1
}
wait_capture()
{
	i=0
	while [ "$i" -lt 200 ]; do
		$OUTER capture-pane -pt outer:0 >"$DIR/capture" || exit 1
		grep -q "$1" "$DIR/capture" && return
		sleep 0.05
		i=$((i + 1))
	done
	fail "client did not receive $1"
}
wait_name()
{
	i=0
	while [ "$i" -lt 200 ]; do
		name=$($INNER display -pt inner:1 '#{window_name}') || exit 1
		[ "$name" = "$1" ] && return
		sleep 0.05
		i=$((i + 1))
	done
	fail "automatic rename timer did not produce $1 (got $name)"
}

$INNER new-session -d -s inner -x 100 -y 30 'sleep 100' || exit 1
$INNER set -g status off || exit 1
$INNER set -g status-interval 0 || exit 1
$INNER set -g automatic-rename off || exit 1
$INNER new-window -d -t inner:1 "
	printf '\033]2;before\007';
	while [ ! -f '$DIR/output' ]; do sleep 0.01; done;
	printf '\033]2;middle\007hidden-output';
	while [ ! -f '$DIR/rename' ]; do sleep 0.01; done;
	printf '\033]2;after\007';
	sleep 100
" || exit 1
$INNER set -w -t inner:1 automatic-rename-format '#{pane_title}' || exit 1
$INNER set -w -t inner:1 automatic-rename on || exit 1
wait_name before

$OUTER new-session -d -s outer -x 70 -y 20 'sleep 100' || exit 1
$OUTER set -g status off || exit 1
$OUTER set -g default-terminal screen || exit 1
$OUTER respawn-pane -k -t outer:0 "$INNER attach -t inner" || exit 1
i=0
while [ "$i" -lt 200 ]; do
	[ "$($INNER display -pt inner:0 '#{window_width}x#{window_height}')" = 70x20 ] && break
	sleep 0.05
	i=$((i + 1))
done
[ "$i" -lt 200 ] || fail 'nested client did not resize the current window'
[ "$($INNER display -pt inner:1 '#{window_width}x#{window_height}')" = 100x30 ] ||
	fail 'unattended window resized before being selected'
: >"$DIR/output"
wait_name middle
: >"$DIR/rename"
wait_name after
$INNER select-window -t inner:1 || exit 1
wait_capture hidden-output
[ "$($INNER display -pt inner:1 '#{window_width}x#{window_height}')" = 70x20 ] ||
	fail 'pending resize was lost when the unattended window was selected'
$OUTER capture-pane -pt outer:0 >"$DIR/before" || exit 1
$INNER refresh-client || exit 1
$OUTER capture-pane -pt outer:0 >"$DIR/after" || exit 1
diff -u "$DIR/before" "$DIR/after" || fail 'selection redraw differs from full redraw'

# No attached client visits this window when its subscribed theme changes.
$INNER select-window -t inner:0 || exit 1
$INNER set -w -t inner:1 window-style bg=black || exit 1
$INNER respawn-pane -k -t inner:1 "
	stty raw -echo;
	printf '\033[?2031h';
	: >'$DIR/theme-ready';
	dd bs=1 count=9 of='$DIR/theme-reply' 2>/dev/null;
	sleep 100
" || exit 1
i=0
while [ "$i" -lt 200 ]; do
	[ -f "$DIR/theme-ready" ] && break
	sleep 0.05
	i=$((i + 1))
done
[ "$i" -lt 200 ] || fail 'theme subscriber did not start'
$INNER set -w -t inner:1 window-style bg=white || exit 1
i=0
while [ "$i" -lt 200 ]; do
	[ -f "$DIR/theme-reply" ] && [ "$(wc -c <"$DIR/theme-reply")" -eq 9 ] && break
	sleep 0.05
	i=$((i + 1))
done
expected=$(printf '\033[?997;2n')
[ "$(cat "$DIR/theme-reply")" = "$expected" ] ||
	fail 'unattended pane did not receive its light theme update'
exit 0
