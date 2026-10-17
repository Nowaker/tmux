#!/bin/sh

# Status-origin drags retain their binding family, not their starting window.
PATH=/bin:/usr/bin
TERM=screen
export PATH TERM

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Lstatus-target-inner-$$ -f/dev/null"
OUTER="$TEST_TMUX -Lstatus-target-outer-$$ -f/dev/null"

cleanup()
{
	$OUTER kill-server >/dev/null 2>&1
	$TMUX kill-server >/dev/null 2>&1
}
trap cleanup 0 1 15

fail()
{
	echo "$*" >&2
	exit 1
}

equal()
{
	[ "$1" = "$2" ] || fail "got '$1', expected '$2'"
}

mouse()
{
	seq=$(printf '\033[<%s;%s;%s%s' "$1" "$2" "$3" "$4")
	$OUTER send-keys -t outer:0.0 -l "$seq" || exit 1
	sleep 0.1
}

$TMUX new-session -d -s inner -x 60 -y 20 'sleep 120' || exit 1
$TMUX new-window -d -t inner:1 'sleep 120' || exit 1
$TMUX set -g mouse on || exit 1
$TMUX unbind -n MouseDown1Status || exit 1
$TMUX bind -n MouseDrag1Status 'set -g @dispatch window; set -w -t= @drag-hit yes' || exit 1
$TMUX bind -n MouseDrag1Pane 'set -g @dispatch pane; set -g @pane-hit yes' || exit 1
$TMUX bind -n MouseDrag1StatusDefault set -g @dispatch default || exit 1
$TMUX bind -n MouseDrag1Control0 set -g @dispatch control || exit 1
$TMUX set -g status 2 || exit 1
$TMUX set -g 'status-format[0]' '#[range=window|0]AAAAAAAAAA#[range=window|1]BBBBBBBBBB#[norange] PLAIN    #[range=window|999]INVALID' || exit 1
$TMUX set -g 'status-format[1]' '#[range=control|0]CONTROL#[norange]' || exit 1
$OUTER new-session -d -s outer -x 60 -y 20 'sleep 120' || exit 1
$OUTER set -g status off || exit 1
$OUTER respawn-pane -k -t outer:0.0 "$TMUX attach -t inner" || exit 1
sleep 1

for position in top bottom; do
	$TMUX set -g status-position "$position" || exit 1
	if [ "$position" = top ]; then row=1; control=2; else row=19; control=20; fi
	sleep 0.3
	$TMUX set -w -t inner:0 -u @drag-hit || exit 1
	$TMUX set -w -t inner:1 -u @drag-hit || exit 1
	mouse 0 3 "$row" M
	mouse 32 4 "$row" M
	$TMUX set -g -u @dispatch || exit 1
	mouse 32 15 "$row" M
	equal "$($TMUX show -gqv @dispatch)" window
	equal "$($TMUX show -wqv -t inner:1 @drag-hit)" yes
	for destination in plain control invalid outside; do
		$TMUX set -w -t inner:0 -u @drag-hit || exit 1
		$TMUX set -g -u @dispatch || exit 1
		case "$destination" in
		plain) mouse 32 25 "$row" M ;;
		control) mouse 32 3 "$control" M ;;
		invalid) mouse 32 33 "$row" M ;;
		outside) mouse 32 15 10 M ;;
		esac
		equal "$($TMUX show -gqv @dispatch)" window
		equal "$($TMUX show -wqv -t inner:0 @drag-hit)" yes
	done
	equal "$($TMUX show -gqv @pane-hit)" ''
	mouse 0 15 10 m
	sleep 0.3
	$TMUX set -w -t inner:1 -u @drag-hit || exit 1

	# Plain and control status origins must not become window or pane bindings.
	mouse 0 25 "$row" M
	mouse 32 26 "$row" M
	$TMUX set -g -u @dispatch || exit 1
	mouse 32 15 "$row" M
	equal "$($TMUX show -gqv @dispatch)" default
	equal "$($TMUX show -wqv -t inner:1 @drag-hit)" ''
	mouse 0 15 "$row" m
	sleep 0.3
	mouse 0 3 "$control" M
	mouse 32 4 "$control" M
	$TMUX set -g -u @dispatch || exit 1
	mouse 32 15 "$row" M
	equal "$($TMUX show -gqv @dispatch)" control
	equal "$($TMUX show -wqv -t inner:1 @drag-hit)" ''
	mouse 0 15 "$row" m
	sleep 0.3
done

mouse 0 3 10 M
$TMUX set -g -u @dispatch || exit 1
mouse 32 4 10 M
equal "$($TMUX show -gqv @dispatch)" pane
equal "$($TMUX show -gqv @pane-hit)" yes
mouse 0 4 10 m
exit 0
