#!/bin/sh

# A real client must paint and route input into the reclaimed separator row.
PATH=/bin:/usr/bin
TERM=screen
export PATH TERM

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
INNER="$TEST_TMUX -Lcollapse-inner-$$ -f/dev/null"
OUTER="$TEST_TMUX -Lcollapse-outer-$$ -f/dev/null"

cleanup()
{
	$OUTER kill-server 2>/dev/null
	$INNER kill-server 2>/dev/null
}
trap cleanup 0 1 15

fail()
{
	echo "$*" >&2
	exit 1
}

must_equal()
{
	[ "$1" = "$2" ] || fail "got '$1', expected '$2'"
}

wait_for_text()
{
	i=0
	while [ "$i" -lt 50 ]; do
		text=$($INNER capture-pane -p -t "$BODY")
		case "$text" in
		*"$1"*) return 0 ;;
		esac
		sleep 0.1
		i=$((i + 1))
	done
	fail "pane did not print '$1'"
}

TITLE=$($INNER new-session -dPF '#{pane_id}' -s inner -x 80 -y 24 \
	"printf TITLE; exec sleep 100") || exit 1
$INNER set-option -g status off || exit 1
must_equal "$($INNER display-message -p '#{pane_border_collapse_safe}')" 1
$INNER set-option -g mouse on || exit 1
$INNER set-option -g default-terminal screen || exit 1
BODY=$($INNER split-window -v -l 22 -t "$TITLE" -PF '#{pane_id}' \
	'printf "BODY\n"; while IFS= read -r line; do if [ "$line" = size ]; then stty size; else printf "INPUT:%s\n" "$line"; fi; done') || exit 1
layout=$($INNER display-message -p -t "$BODY" '#{window_layout}')
$INNER set-option -p -t "$BODY" pane-border-collapse top || exit 1
must_equal "$($INNER display-message -p -t "$BODY" '#{pane_top} #{pane_height}')" '1 23'
must_equal "$($INNER display-message -p -t "$BODY" '#{window_layout}')" "$layout"
$INNER select-pane -t "$BODY" -U || exit 1
must_equal "$($INNER display-message -p -t inner '#{pane_id}')" "$TITLE"
$INNER select-pane -t "$TITLE" -D || exit 1
must_equal "$($INNER display-message -p -t inner '#{pane_id}')" "$BODY"

VIEW=$($OUTER new-session -dPF '#{pane_id}' -s outer -x 80 -y 24 \
	"$INNER attach-session -t inner") || exit 1
$OUTER set-option -g status off || exit 1
i=0
while [ "$i" -lt 50 ]; do
	CLIENT=$($INNER list-clients -F '#{client_name}' 2>/dev/null)
	[ -n "$CLIENT" ] && break
	sleep 0.1
	i=$((i + 1))
done
[ -n "$CLIENT" ] || fail 'inner client did not attach'
sleep 0.5
must_equal "$($OUTER capture-pane -p -t "$VIEW" -S 0 -E 1)" "$(printf 'TITLE\nBODY')"

# Click the first reclaimed body row through the real client's mouse decoder.
$INNER select-pane -t "$TITLE" || exit 1
$OUTER send-keys -t "$VIEW" -H 1b 5b 3c 30 3b 32 3b 32 4d || exit 1
$OUTER send-keys -t "$VIEW" -H 1b 5b 3c 30 3b 32 3b 32 6d || exit 1
sleep 0.2
must_equal "$($INNER display-message -p -t inner '#{pane_id}')" "$BODY"
$OUTER send-keys -t "$VIEW" hello Enter || exit 1
wait_for_text INPUT:hello
$OUTER send-keys -t "$VIEW" size Enter || exit 1
wait_for_text '23 80'

# Copy mode includes the reclaimed first row, without a synthetic blank row.
$INNER copy-mode -t "$BODY" || exit 1
$INNER send-keys -t "$BODY" -X history-top || exit 1
$INNER send-keys -t "$BODY" -X start-of-line || exit 1
$INNER send-keys -t "$BODY" -X begin-selection || exit 1
$INNER send-keys -t "$BODY" -X end-of-line || exit 1
$INNER send-keys -t "$BODY" -X copy-selection-and-cancel || exit 1
must_equal "$($INNER show-buffer)" BODY

# Changing the client's PTY size retains adjacency and updates the pane PTY.
$OUTER resize-window -t outer -x 100 -y 30 || exit 1
sleep 0.5
$INNER resize-pane -t "$TITLE" -y 1 || exit 1
must_equal "$($INNER display-message -p -t "$BODY" '#{pane_top} #{pane_height} #{pane_width}')" '1 29 100'
$OUTER send-keys -t "$VIEW" size Enter || exit 1
wait_for_text '29 100'
SIDE=$($INNER split-window -h -b -l 20 -t "$BODY" -PF '#{pane_id}' \
	'printf SIDEBAR; exec sleep 100') || exit 1
$INNER set-option -p -t "$SIDE" pane-border-collapse top || exit 1
$INNER select-pane -t "$SIDE" -R || exit 1
must_equal "$($INNER display-message -p -t inner '#{pane_id}')" "$BODY"
sleep 0.3
$OUTER send-keys -t "$VIEW" -H 1b 5b 3c 30 3b 32 31 3b 35 4d || exit 1
$OUTER send-keys -t "$VIEW" -H 1b 5b 3c 33 32 3b 32 36 3b 35 4d || exit 1
$OUTER send-keys -t "$VIEW" -H 1b 5b 3c 30 3b 32 36 3b 35 6d || exit 1
sleep 0.3
must_equal "$($INNER display-message -p -t "$SIDE" '#{pane_width}')" 25
if $INNER set-option -p -t "$BODY" pane-border-collapse invalid 2>/dev/null; then
	fail 'invalid collapse choice accepted'
fi
exit 0
