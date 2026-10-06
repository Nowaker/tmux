#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/ioctl.h>
#include <sys/wait.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "tmux.h"

#define HANDOFF_MAGIC 0x50545931U
#define HANDOFF_LIMIT (1024 * 1024)
#define HANDOFF_TIMEOUT 2000

enum handoff_op { H_INIT = 1, H_READY, H_COMMIT, H_ACK, H_ADOPT,
    H_STATUS, H_CANCEL, H_ERROR };
enum handoff_state { H_PREPARED = 1, H_PARKED, H_ADOPTED };

struct handoff_msg {
	uint32_t magic, version, op, size;
	uint32_t state, bytes, snapshot, eof;
	uint32_t sx, sy, cx, cy, mode, alternate;
	uint32_t cstyle, rupper, rlower;
	int32_t pid, keeper, owner, ccolour;
	char tty[TTY_NAME_MAX];
	struct input_handoff input;
};

static enum cmd_retval cmd_handoff_exec(struct cmd *, struct cmdq_item *);

const struct cmd_entry cmd_park_pane_entry = {
	.name = "park-pane",
	.args = { "t:", 1, 1, NULL },
	.usage = CMD_TARGET_PANE_USAGE " directory",
	.target = { 't', CMD_FIND_PANE, 0 },
	.exec = cmd_handoff_exec
};
const struct cmd_entry cmd_adopt_pane_entry = {
	.name = "adopt-pane",
	.args = { "t:", 1, 1, NULL },
	.usage = CMD_TARGET_PANE_USAGE " directory",
	.target = { 't', CMD_FIND_PANE, 0 },
	.exec = cmd_handoff_exec
};
const struct cmd_entry cmd_handoff_status_entry = {
	.name = "handoff-status",
	.args = { "", 1, 1, NULL },
	.usage = "directory",
	.exec = cmd_handoff_exec
};
const struct cmd_entry cmd_handoff_cancel_entry = {
	.name = "handoff-cancel",
	.args = { "", 1, 1, NULL },
	.usage = "directory",
	.exec = cmd_handoff_exec
};

static uint64_t
handoff_milliseconds(void)
{
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &now);
	return ((uint64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000);
}

static int
handoff_io(int fd, void *data, size_t len, int writing)
{
	struct pollfd pfd = { fd, writing ? POLLOUT : POLLIN, 0 };
	u_char *bytes = data;
	ssize_t count;
	uint64_t deadline = handoff_milliseconds() + HANDOFF_TIMEOUT;
	uint64_t now;
	int remaining;

	while (len != 0) {
		now = handoff_milliseconds();
		if (now >= deadline)
			return (-1);
		remaining = deadline - now;
		if (poll(&pfd, 1, remaining) <= 0)
			return (-1);
		if (writing)
			count = send(fd, bytes, len, 0);
		else
			count = recv(fd, bytes, len, 0);
		if (count < 0 && (errno == EINTR || errno == EAGAIN))
			continue;
		if (count <= 0)
			return (-1);
		bytes += count;
		len -= count;
	}
	return (0);
}

static int
handoff_send(int fd, struct handoff_msg *msg, int master)
{
	struct msghdr header;
	struct iovec iov;
	union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int))]; } control;
	struct cmsghdr *cmsg;
	ssize_t count;

	msg->magic = HANDOFF_MAGIC;
	msg->version = 1;
	msg->size = sizeof *msg;
	memset(&header, 0, sizeof header);
	iov.iov_base = msg;
	iov.iov_len = sizeof *msg;
	header.msg_iov = &iov;
	header.msg_iovlen = 1;
	if (master != -1) {
		memset(&control, 0, sizeof control);
		header.msg_control = control.bytes;
		header.msg_controllen = sizeof control.bytes;
		cmsg = CMSG_FIRSTHDR(&header);
		cmsg->cmsg_level = SOL_SOCKET;
		cmsg->cmsg_type = SCM_RIGHTS;
		cmsg->cmsg_len = CMSG_LEN(sizeof(int));
		memcpy(CMSG_DATA(cmsg), &master, sizeof master);
	}
	count = sendmsg(fd, &header, 0);
	if (count <= 0)
		return (-1);
	return (handoff_io(fd, (u_char *)msg + count, sizeof *msg - count, 1));
}

static int
handoff_recv(int fd, struct handoff_msg *msg, int *master)
{
	struct msghdr header;
	struct iovec iov;
	union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int))]; } control;
	struct cmsghdr *cmsg;
	struct pollfd pfd = { fd, POLLIN, 0 };
	ssize_t count;
	size_t descriptors, index;
	int descriptor, invalid = 0;

	*master = -1;
	memset(&header, 0, sizeof header);
	iov.iov_base = msg;
	iov.iov_len = sizeof *msg;
	header.msg_iov = &iov;
	header.msg_iovlen = 1;
	header.msg_control = control.bytes;
	header.msg_controllen = sizeof control.bytes;
	if (poll(&pfd, 1, HANDOFF_TIMEOUT) <= 0)
		return (-1);
	count = recvmsg(fd, &header, 0);
	if (count <= 0)
		return (-1);
	for (cmsg = CMSG_FIRSTHDR(&header); cmsg != NULL;
	    cmsg = CMSG_NXTHDR(&header, cmsg)) {
		if (cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS)
			continue;
		descriptors = (cmsg->cmsg_len - CMSG_LEN(0)) / sizeof(int);
		for (index = 0; index < descriptors; index++) {
			memcpy(&descriptor, (u_char *)CMSG_DATA(cmsg) +
			    index * sizeof(int), sizeof descriptor);
			if (*master == -1)
				*master = descriptor;
			else {
				close(descriptor);
				invalid = 1;
			}
		}
	}
	if (handoff_io(fd, (u_char *)msg + count, sizeof *msg - count, 0) == 0 &&
	    !invalid && !(header.msg_flags & (MSG_TRUNC|MSG_CTRUNC)) &&
	    msg->magic == HANDOFF_MAGIC && msg->version == 1 &&
	    msg->size == sizeof *msg && msg->bytes <= HANDOFF_LIMIT &&
	    msg->snapshot <= HANDOFF_LIMIT)
		return (0);
	if (*master != -1)
		close(*master);
	*master = -1;
	return (-1);
}

static int
handoff_peer(int fd)
{
	uid_t uid;
	gid_t gid;

	return (getpeereid(fd, &uid, &gid) == 0 && uid == getuid());
}

static int
handoff_address(const char *directory, struct sockaddr_un *address)
{
	struct stat st;

	if (*directory != '/' || lstat(directory, &st) != 0 || !S_ISDIR(st.st_mode) ||
	    st.st_uid != getuid() || (st.st_mode & 0777) != 0700)
		return (-1);
	memset(address, 0, sizeof *address);
	address->sun_family = AF_UNIX;
	if (snprintf(address->sun_path, sizeof address->sun_path, "%s/keeper",
	    directory) >= (int)sizeof address->sun_path)
		return (-1);
	return (0);
}

static int
handoff_connect(struct sockaddr_un *address)
{
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	int error;
	socklen_t length = sizeof error;
	struct pollfd pfd;

	if (fd == -1)
		return (-1);
	setblocking(fd, 0);
	if (connect(fd, (struct sockaddr *)address, sizeof *address) != 0) {
		pfd.fd = fd;
		pfd.events = POLLOUT;
		pfd.revents = 0;
		if (errno != EINPROGRESS || poll(&pfd, 1, HANDOFF_TIMEOUT) <= 0 ||
		    getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) != 0 ||
		    error != 0) {
			close(fd);
			return (-1);
		}
	}
	if (!handoff_peer(fd)) {
		close(fd);
		return (-1);
	}
	return (fd);
}

static void
handoff_keeper(int control, int listener, const char *path)
{
	struct handoff_msg state, request, response;
	u_char *fifo = xmalloc(HANDOFF_LIMIT), *snapshot = NULL;
	struct pollfd fds[2];
	int master = -1, received = -1, client, committed = 0;
	size_t used = 0;
	ssize_t count;
	char *cause = NULL;

	if (setsid() == -1)
		goto out;
	signal(SIGPIPE, SIG_IGN);
#if defined(HAVE_SYSTEMD) && defined(ENABLE_CGROUPS)
	if (systemd_move_to_new_cgroup(&cause) < 0)
		goto out;
#endif
	if (handoff_recv(control, &state, &master) != 0 || master == -1 ||
	    state.op != H_INIT)
		goto out;
	snapshot = xmalloc(state.snapshot);
	if (handoff_io(control, snapshot, state.snapshot, 0) != 0)
		goto out;
	state.keeper = getpid();
	state.state = H_PREPARED;
	state.op = H_READY;
	if (handoff_send(control, &state, -1) != 0 ||
	    handoff_recv(control, &request, &received) != 0 || received != -1 ||
	    request.op != H_COMMIT)
		goto out;
	state.state = H_PARKED;
	state.op = H_ACK;
	committed = 1;
	handoff_send(control, &state, -1);
	close(control);
	control = -1;
	for (;;) {
		fds[0].fd = listener;
		fds[0].events = POLLIN;
		fds[1].fd = master;
		fds[1].events = used < HANDOFF_LIMIT && !state.eof ? POLLIN : 0;
		if (fds[1].events == 0)
			fds[1].fd = -1;
		if (poll(fds, 2, -1) < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		if (fds[0].revents & POLLIN) {
			client = accept(listener, NULL, NULL);
			if (client == -1)
				continue;
			setblocking(client, 0);
			if (!handoff_peer(client) ||
			    handoff_recv(client, &request, &received) != 0) {
				close(client);
				continue;
			}
			if (received != -1) {
				close(received);
				close(client);
				continue;
			}
			state.bytes = used;
			response = state;
			response.op = H_ACK;
			if (request.op == H_CANCEL) {
				handoff_send(client, &response, -1);
				close(client);
				break;
			} else if (request.op == H_STATUS) {
				handoff_send(client, &response, -1);
			} else if (request.op == H_ADOPT && state.state == H_PARKED) {
				response.op = H_READY;
				if (handoff_send(client, &response, master) == 0 &&
				    handoff_io(client, snapshot, state.snapshot, 1) == 0 &&
				    handoff_io(client, fifo, used, 1) == 0 &&
				    handoff_recv(client, &request, &received) == 0 &&
				    request.op == H_COMMIT && received == -1) {
					state.state = H_ADOPTED;
					state.owner = request.owner;
					close(master);
					master = -1;
					state.op = H_ACK;
					handoff_send(client, &state, -1);
				}
			} else {
				response.op = H_ERROR;
				handoff_send(client, &response, -1);
			}
			if (received != -1) {
				close(received);
				received = -1;
			}
			close(client);
			continue;
		}
		if (master != -1 && fds[1].revents != 0) {
			count = read(master, fifo + used, HANDOFF_LIMIT - used);
			if (count > 0)
				used += count;
			else if (count == 0 || (count < 0 && errno == EIO))
				state.eof = 1;
			else if (errno != EINTR && errno != EAGAIN)
				break;
		}
	}
out:
	if (received != -1)
		close(received);
	if (master != -1)
		close(master);
	if (control != -1)
		close(control);
	close(listener);
	unlink(path);
	free(cause);
	free(fifo);
	free(snapshot);
	_exit(committed ? 0 : 1);
}

static int
handoff_snapshot(struct window_pane *wp, struct evbuffer *buffer)
{
	char *line, position[64];
	u_int row, column;
	struct grid_cell cell;
	struct screen *screen = &wp->base;

	evbuffer_add(buffer, "\033[?7l\033[2J", 9);
	for (row = 0; row < wp->sy; row++) {
		for (column = 0; column < wp->sx; column++) {
			grid_get_cell(screen->grid, column,
			    screen->grid->hsize + row, &cell);
			if (cell.link != 0)
				return (-1);
		}
		snprintf(position, sizeof position, "\033[%u;1H", row + 1);
		evbuffer_add(buffer, position, strlen(position));
		line = grid_string_cells(screen->grid, 0,
		    screen->grid->hsize + row, wp->sx, NULL,
		    GRID_STRING_WITH_SEQUENCES|GRID_STRING_TRIM_SPACES, screen);
		evbuffer_add(buffer, line, strlen(line));
		free(line);
		if (EVBUFFER_LENGTH(buffer) > HANDOFF_LIMIT)
			return (-1);
	}
	evbuffer_add(buffer, "\033[0m", 4);
	return (0);
}

static int
handoff_park(struct window_pane *wp, struct sockaddr_un *address,
    struct handoff_msg *reply)
{
	struct handoff_msg msg;
	struct evbuffer *snapshot;
	int listener = -1, pair[2], received = -1, control, copy, saved;
	pid_t child;
	u_int column;

	if (wp->flags & PANE_ADOPTING)
		return (-1);
	if (wp->flags & PANE_HANDOFF) {
		control = handoff_connect(address);
		memset(&msg, 0, sizeof msg);
		msg.op = H_STATUS;
		if (control == -1)
			return (-1);
		saved = handoff_send(control, &msg, -1) == 0 &&
		    handoff_recv(control, reply, &received) == 0 &&
		    received == -1 && reply->state == H_PARKED &&
		    reply->pid == wp->pid &&
		    strncmp(reply->tty, wp->tty, sizeof reply->tty) == 0;
		close(control);
		if (!saved)
			return (-1);
		snapshot = NULL;
		goto parked;
	}
	if (wp->fd == -1 || wp->event == NULL || wp->wait_item != NULL ||
	    wp->editor != NULL || wp->pipe_fd != -1 ||
	    (wp->flags & (PANE_EXITED|PANE_STATUSREADY)) ||
	    !TAILQ_EMPTY(&wp->modes) || !TAILQ_EMPTY(&wp->resize_queue) ||
	    wp->resize_sync_phase != WINDOW_PANE_RESIZE_SYNC_NONE ||
	    (wp->base.mode & MODE_SYNC) || !input_handoff_safe(wp->ictx) ||
	    EVBUFFER_LENGTH(wp->event->input) != 0 ||
	    EVBUFFER_LENGTH(wp->event->output) != 0 ||
	    wp->base.rupper != 0 || wp->base.rlower != wp->sy - 1 ||
	    wp->palette.palette != NULL || wp->palette.default_palette != NULL ||
	    wp->palette.fg != 8 || wp->palette.bg != 8 ||
	    wp->sx > 4096 || wp->sy > 4096)
		return (-1);
#ifdef ENABLE_SIXEL
	if (!TAILQ_EMPTY(&wp->base.images) || !TAILQ_EMPTY(&wp->base.saved_images))
		return (-1);
#endif
	for (column = 0; column < wp->sx; column++) {
		if (!!bit_test(wp->base.tabs, column) !=
		    (column != 0 && column % 8 == 0))
			return (-1);
	}
	snapshot = evbuffer_new();
	if (handoff_snapshot(wp, snapshot) != 0)
		goto fail_snapshot;
	listener = socket(AF_UNIX, SOCK_STREAM, 0);
	if (listener == -1 || bind(listener, (struct sockaddr *)address,
	    sizeof *address) != 0)
		goto fail_listener;
	if (chmod(address->sun_path, 0600) != 0 || listen(listener, 4) != 0 ||
	    socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0)
		goto fail_bound;
	bufferevent_disable(wp->event, EV_READ|EV_WRITE);
	child = fork();
	if (child == -1) {
		close(pair[0]);
		close(pair[1]);
		goto resume;
	}
	if (child == 0) {
		proc_clear_signals(server_proc, 1);
		control = fcntl(pair[1], F_DUPFD, 5);
		copy = fcntl(listener, F_DUPFD, 5);
		if (control == -1 || copy == -1 || dup2(control, 3) == -1 ||
		    dup2(copy, 4) == -1)
			_exit(1);
		closefrom(5);
		close(0);
		close(1);
		close(2);
		setblocking(3, 0);
		handoff_keeper(3, 4, address->sun_path);
	}
	close(pair[1]);
	close(listener);
	listener = -1;
	setblocking(pair[0], 0);
	memset(&msg, 0, sizeof msg);
	msg.op = H_INIT;
	msg.sx = wp->sx;
	msg.sy = wp->sy;
	msg.cx = wp->base.cx;
	msg.cy = wp->base.cy;
	msg.mode = wp->base.mode;
	msg.cstyle = wp->base.cstyle;
	msg.ccolour = wp->base.ccolour;
	msg.alternate = SCREEN_IS_ALTERNATE(&wp->base);
	msg.pid = wp->pid;
	msg.snapshot = EVBUFFER_LENGTH(snapshot);
	strlcpy(msg.tty, wp->tty, sizeof msg.tty);
	input_handoff_save(wp->ictx, &msg.input);
	if (handoff_send(pair[0], &msg, wp->fd) != 0 ||
	    handoff_io(pair[0], EVBUFFER_DATA(snapshot), msg.snapshot, 1) != 0 ||
	    handoff_recv(pair[0], reply, &received) != 0 ||
	    received != -1 || reply->op != H_READY || reply->keeper != child ||
	    reply->pid != wp->pid ||
	    strncmp(reply->tty, wp->tty, sizeof reply->tty) != 0) {
		close(pair[0]);
		waitpid(child, NULL, 0);
		goto resume;
	}
	msg.op = H_COMMIT;
	saved = handoff_send(pair[0], &msg, -1);
	if (saved != 0) {
		close(pair[0]);
		waitpid(child, NULL, 0);
		goto resume;
	}
	if (saved == 0 && handoff_recv(pair[0], reply, &received) == 0 &&
	    received == -1 && reply->op == H_ACK && reply->state == H_PARKED &&
	    reply->keeper == child && reply->pid == wp->pid &&
	    strncmp(reply->tty, wp->tty, sizeof reply->tty) == 0)
		saved = 1;
	else
		saved = 0;
	close(pair[0]);
	if (!saved) {
		control = handoff_connect(address);
		msg.op = H_STATUS;
		if (control == -1 || handoff_send(control, &msg, -1) != 0 ||
		    handoff_recv(control, reply, &received) != 0 ||
		    received != -1 || reply->state != H_PARKED ||
		    reply->keeper != child || reply->pid != wp->pid ||
		    strncmp(reply->tty, wp->tty, sizeof reply->tty) != 0) {
			if (control != -1)
				close(control);
			if (~wp->flags & PANE_INPUTOFF)
				wp->flags |= PANE_HANDOFF_INPUTOFF;
			wp->flags |= PANE_HANDOFF|PANE_INPUTOFF;
			evbuffer_free(snapshot);
			return (-1);
		}
		close(control);
	}
parked:
	input_free(wp->ictx);
	wp->ictx = NULL;
	bufferevent_free(wp->event);
	wp->event = NULL;
	close(wp->fd);
	wp->fd = -1;
	if (~wp->flags & PANE_INPUTOFF)
		wp->flags |= PANE_HANDOFF_INPUTOFF;
	wp->flags |= PANE_EMPTY|PANE_INPUTOFF;
	wp->flags &= ~PANE_HANDOFF;
	wp->pid = 0;
	window_pane_set_event(wp);
	if (snapshot != NULL)
		evbuffer_free(snapshot);
	return (0);
resume:
	bufferevent_enable(wp->event, EV_READ|EV_WRITE);
fail_bound:
	unlink(address->sun_path);
fail_listener:
	if (listener != -1)
		close(listener);
fail_snapshot:
	if (received != -1)
		close(received);
	evbuffer_free(snapshot);
	return (-1);
}

static enum cmd_retval
cmd_handoff_exec(struct cmd *self, struct cmdq_item *item)
{
	struct sockaddr_un address;
	struct handoff_msg request, reply;
	struct window_pane *wp = cmdq_get_target(item)->wp;
	const char *name = cmd_get_entry(self)->name;
	const char *directory = args_string(cmd_get_args(self), 0);
	u_char *data = NULL;
	int fd = -1, master = -1, extra = -1, installed = 0, sent_commit = 0;

	if (handoff_address(directory, &address) != 0) {
		cmdq_error(item, "handoff requires an owned 0700 directory (path too long?)");
		return (CMD_RETURN_ERROR);
	}
	if (strcmp(name, "park-pane") == 0) {
		if (handoff_park(wp, &address, &reply) != 0) {
			cmdq_error(item, "cannot park: unsafe checkpoint or keeper unavailable");
			return (CMD_RETURN_ERROR);
		}
		goto receipt;
	}
	memset(&request, 0, sizeof request);
	if (strcmp(name, "adopt-pane") == 0) {
		if (wp->flags & PANE_ADOPTING) {
			fd = handoff_connect(&address);
			request.op = H_STATUS;
			if (fd == -1 || handoff_send(fd, &request, -1) != 0 ||
			    handoff_recv(fd, &reply, &extra) != 0 || extra != -1 ||
			    reply.pid != wp->pid ||
			    strncmp(reply.tty, wp->tty, sizeof reply.tty) != 0)
				goto error;
			close(fd);
			fd = -1;
			if (reply.state == H_ADOPTED && reply.owner == getpid()) {
				wp->flags &= ~(PANE_HANDOFF|PANE_ADOPTING|PANE_INPUTOFF);
				bufferevent_enable(wp->event, EV_READ|EV_WRITE);
				goto receipt;
			}
			if (reply.state != H_PARKED)
				goto error;
			input_free(wp->ictx);
			wp->ictx = NULL;
			bufferevent_free(wp->event);
			wp->event = NULL;
			close(wp->fd);
			wp->fd = -1;
			wp->flags &= ~(PANE_HANDOFF|PANE_ADOPTING|PANE_EXTERNAL);
			wp->flags |= PANE_EMPTY;
			window_pane_set_event(wp);
		}
		if (wp->fd != -1 || !(wp->flags & PANE_EMPTY)) {
			cmdq_error(item, "adoption requires an empty pane");
			return (CMD_RETURN_ERROR);
		}
		request.op = H_ADOPT;
	} else if (strcmp(name, "handoff-cancel") == 0)
		request.op = H_CANCEL;
	else
		request.op = H_STATUS;
	fd = handoff_connect(&address);
	if (fd == -1 || handoff_send(fd, &request, -1) != 0 ||
	    handoff_recv(fd, &reply, &master) != 0 || reply.op == H_ERROR)
		goto error;
	if (request.op != H_ADOPT && (master != -1 || reply.op != H_ACK))
		goto error;
	if (request.op == H_ADOPT) {
		if (reply.op != H_READY || master == -1 || reply.sx == 0 ||
		    reply.sy == 0 || reply.sx > 4096 || reply.sy > 4096 ||
		    reply.sx != wp->sx || reply.sy != wp->sy ||
		    reply.cx > reply.sx || reply.cy >= reply.sy ||
		    reply.pid <= 0 || reply.keeper <= 0 || reply.alternate > 1 ||
		    reply.cstyle > SCREEN_CURSOR_BAR || (reply.mode & ~ALL_MODES) ||
		    reply.input.last.size > UTF8_SIZE ||
		    reply.input.last.have > reply.input.last.size ||
		    reply.tty[sizeof reply.tty - 1] != '\0')
			goto error;
		data = xmalloc(reply.snapshot + reply.bytes);
		if (handoff_io(fd, data, reply.snapshot + reply.bytes, 0) != 0)
			goto error;
		if (wp->ictx != NULL)
			input_free(wp->ictx);
		if (wp->event != NULL)
			bufferevent_free(wp->event);
		wp->fd = master;
		master = -1;
		wp->pid = reply.pid;
		strlcpy(wp->tty, reply.tty, sizeof wp->tty);
		wp->flags &= ~(PANE_EMPTY|PANE_EXITED|PANE_STATUSREADY|PANE_HANDOFF_INPUTOFF);
		wp->flags |= PANE_EXTERNAL|PANE_HANDOFF|PANE_ADOPTING|PANE_INPUTOFF;
		wp->base_offset = 0;
		memset(&wp->offset, 0, sizeof wp->offset);
		window_pane_resize(wp, reply.sx, reply.sy);
		window_pane_set_event(wp);
		bufferevent_disable(wp->event, EV_READ|EV_WRITE);
		installed = 1;
		if (reply.alternate)
			input_parse_buffer(wp, (const u_char *)"\033[?1049h", 8);
		input_parse_buffer(wp, data, reply.snapshot);
		wp->base.mode = reply.mode;
		wp->base.cx = reply.cx;
		wp->base.cy = reply.cy;
		wp->base.cstyle = reply.cstyle;
		wp->base.ccolour = reply.ccolour;
		input_handoff_restore(wp->ictx, &reply.input);
		input_parse_buffer(wp, data + reply.snapshot, reply.bytes);
		request.op = H_COMMIT;
		request.owner = getpid();
		if (handoff_send(fd, &request, -1) != 0)
			goto error;
		sent_commit = 1;
		if (handoff_recv(fd, &request, &extra) != 0 ||
		    request.op != H_ACK || request.state != H_ADOPTED ||
		    request.owner != getpid() || request.pid != reply.pid ||
		    request.keeper != reply.keeper ||
		    memcmp(request.tty, reply.tty, sizeof reply.tty) != 0 || extra != -1) {
			close(fd);
			fd = handoff_connect(&address);
			memset(&request, 0, sizeof request);
			request.op = H_STATUS;
			if (fd == -1 || handoff_send(fd, &request, -1) != 0 ||
			    handoff_recv(fd, &request, &extra) != 0 ||
			    request.state != H_ADOPTED || request.owner != getpid() ||
			    request.pid != reply.pid || request.keeper != reply.keeper ||
			    memcmp(request.tty, reply.tty, sizeof reply.tty) != 0 ||
			    extra != -1)
				goto error;
		}
		wp->flags &= ~(PANE_HANDOFF|PANE_ADOPTING|PANE_INPUTOFF);
		bufferevent_enable(wp->event, EV_READ|EV_WRITE);
		wp->flags |= PANE_REDRAW;
		server_redraw_window(wp->window);
		reply.state = H_ADOPTED;
		reply.owner = getpid();
	}
	close(fd);
	fd = -1;
	free(data);
receipt:
	cmdq_print(item, "state=%s keeper=%d owner=%d pid=%d tty=%s bytes=%u eof=%u",
	    reply.state == H_PARKED ? "parked" : "adopted", reply.keeper,
	    reply.owner, reply.pid, reply.tty, reply.bytes, reply.eof);
	return (CMD_RETURN_NORMAL);
error:
	if (installed && !sent_commit) {
		input_free(wp->ictx);
		wp->ictx = NULL;
		bufferevent_free(wp->event);
		wp->event = NULL;
		close(wp->fd);
		wp->fd = -1;
		wp->flags &= ~(PANE_HANDOFF|PANE_ADOPTING|PANE_EXTERNAL);
		wp->flags |= PANE_EMPTY;
		window_pane_set_event(wp);
	}
	if (fd != -1)
		close(fd);
	if (master != -1)
		close(master);
	if (extra != -1)
		close(extra);
	free(data);
	cmdq_error(item, "handoff failed%s; query handoff-status before retrying",
	    sent_commit ? " after commit (pane suspended; repeat adopt-pane to recover)" : "");
	return (CMD_RETURN_ERROR);
}
