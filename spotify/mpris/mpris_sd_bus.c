// Thin sd-bus bridge for the MPRIS 2.0 service.
//
// The MPRIS interface is a vtable of methods, properties and signals. sd-bus
// builds that vtable with C bitfield macros that Odin cannot express, so the
// vtable lives here and Odin owns all playback state and control.
//
// All sd-bus calls happen on one worker thread; the main thread only touches
// the guarded state below. Remote commands are queued here and wake the UI.
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <systemd/sd-bus.h>

#define SPOTI_MPRIS_NAME "org.mpris.MediaPlayer2.spoti"
#define SPOTI_MPRIS_PATH "/org/mpris/MediaPlayer2"
#define SPOTI_MPRIS_ROOT "org.mpris.MediaPlayer2"
#define SPOTI_MPRIS_PLAYER "org.mpris.MediaPlayer2.Player"
#define SPOTI_MPRIS_QUEUE 16

typedef void (*spoti_mpris_wake)(void *userdata);

enum {
	SPOTI_MPRIS_PLAY = 0,
	SPOTI_MPRIS_PAUSE,
	SPOTI_MPRIS_PLAY_PAUSE,
	SPOTI_MPRIS_STOP,
	SPOTI_MPRIS_NEXT,
	SPOTI_MPRIS_PREVIOUS,
	SPOTI_MPRIS_SEEK,
	SPOTI_MPRIS_SET_POSITION,
	SPOTI_MPRIS_QUIT,
};

static sd_bus *mpris_bus;
static spoti_mpris_wake mpris_wake;
static void *mpris_wake_userdata;

static atomic_flag mpris_lock = ATOMIC_FLAG_INIT;

static void lock_state(void) {
	while (atomic_flag_test_and_set_explicit(&mpris_lock, memory_order_acquire)) {}
}

static void unlock_state(void) {
	atomic_flag_clear_explicit(&mpris_lock, memory_order_release);
}

static struct {
	char title[512];
	char artist[512];
	int64_t duration_us;
	int64_t position_us;
	int playing;
	int shuffle;
	int repeat;
	int can_seek;
	int can_next;
	int can_previous;
	double volume;
} state;

static int pending_commands[SPOTI_MPRIS_QUEUE];
static int64_t pending_values[SPOTI_MPRIS_QUEUE];
static int pending_head, pending_tail;
static int changed_pending;
static int seeked_pending;
static int64_t seeked_us;

#define GETTER(name)                                                                     \
	static int name(                                                                     \
		sd_bus *bus, const char *path, const char *interface, const char *property,      \
		sd_bus_message *reply, void *userdata, sd_bus_error *error                       \
	) {                                                                                  \
		(void)bus;                                                                       \
		(void)path;                                                                      \
		(void)interface;                                                                 \
		(void)property;                                                                  \
		(void)userdata;                                                                  \
		(void)error;

#define GETTER_END return r; }

GETTER(get_identity)
	int r = sd_bus_message_append(reply, "s", "spoti");
	GETTER_END

GETTER(get_desktop_entry)
	int r = sd_bus_message_append(reply, "s", "spoti");
	GETTER_END

GETTER(get_true)
	int r = sd_bus_message_append(reply, "b", 1);
	GETTER_END

GETTER(get_false)
	int r = sd_bus_message_append(reply, "b", 0);
	GETTER_END

GETTER(get_empty_strv)
	int r = sd_bus_message_append(reply, "as", 0);
	GETTER_END

GETTER(get_playback_status)
	lock_state();
	int r = sd_bus_message_append(reply, "s", state.playing ? "Playing" : "Paused");
	unlock_state();
	GETTER_END

GETTER(get_loop_status)
	lock_state();
	int r = sd_bus_message_append(reply, "s", state.repeat ? "Track" : "None");
	unlock_state();
	GETTER_END

GETTER(get_rate)
	int r = sd_bus_message_append(reply, "d", 1.0);
	GETTER_END

GETTER(get_shuffle)
	lock_state();
	int r = sd_bus_message_append(reply, "b", state.shuffle ? 1 : 0);
	unlock_state();
	GETTER_END

GETTER(get_volume)
	lock_state();
	int r = sd_bus_message_append(reply, "d", state.volume);
	unlock_state();
	GETTER_END

GETTER(get_position)
	lock_state();
	int r = sd_bus_message_append(reply, "x", state.position_us);
	unlock_state();
	GETTER_END

GETTER(get_can_seek)
	lock_state();
	int r = sd_bus_message_append(reply, "b", state.can_seek ? 1 : 0);
	unlock_state();
	GETTER_END

GETTER(get_can_next)
	lock_state();
	int r = sd_bus_message_append(reply, "b", state.can_next ? 1 : 0);
	unlock_state();
	GETTER_END

GETTER(get_can_previous)
	lock_state();
	int r = sd_bus_message_append(reply, "b", state.can_previous ? 1 : 0);
	unlock_state();
	GETTER_END

GETTER(get_metadata)
	lock_state();
	int r = sd_bus_message_append(
		reply, "a{sv}", 4,
		"mpris:trackid", "o", "/org/spoti/track",
		"mpris:length", "x", state.duration_us,
		"xesam:title", "s", state.title,
		"xesam:artist", "as", 1, state.artist
	);
	unlock_state();
	GETTER_END

static void enqueue_command(int command, int64_t value) {
	lock_state();
	int next = (pending_tail + 1) % SPOTI_MPRIS_QUEUE;
	if (next != pending_head) {
		pending_commands[pending_tail] = command;
		pending_values[pending_tail] = value;
		pending_tail = next;
	}
	unlock_state();
	if (mpris_wake != NULL) {mpris_wake(mpris_wake_userdata);}
}

static int method_simple(sd_bus_message *message, int command) {
	enqueue_command(command, 0);
	return sd_bus_reply_method_return(message, NULL);
}

#define METHOD(name, command)                                                            \
	static int name(sd_bus_message *message, void *userdata, sd_bus_error *error) {      \
		(void)userdata;                                                                  \
		(void)error;                                                                     \
		return method_simple(message, command);                                          \
	}

METHOD(method_play, SPOTI_MPRIS_PLAY)
METHOD(method_pause, SPOTI_MPRIS_PAUSE)
METHOD(method_play_pause, SPOTI_MPRIS_PLAY_PAUSE)
METHOD(method_stop, SPOTI_MPRIS_STOP)
METHOD(method_next, SPOTI_MPRIS_NEXT)
METHOD(method_previous, SPOTI_MPRIS_PREVIOUS)
METHOD(method_quit, SPOTI_MPRIS_QUIT)

static int method_raise(sd_bus_message *message, void *userdata, sd_bus_error *error) {
	(void)userdata;
	(void)error;
	return sd_bus_reply_method_return(message, NULL);
}

static int method_seek(sd_bus_message *message, void *userdata, sd_bus_error *error) {
	(void)userdata;
	(void)error;
	int64_t offset = 0;
	int r = sd_bus_message_read(message, "x", &offset);
	if (r < 0) {return r;}
	enqueue_command(SPOTI_MPRIS_SEEK, offset);
	return sd_bus_reply_method_return(message, NULL);
}

static int method_set_position(sd_bus_message *message, void *userdata, sd_bus_error *error) {
	(void)userdata;
	(void)error;
	const char *track;
	int64_t position = 0;
	int r = sd_bus_message_read(message, "ox", &track, &position);
	if (r < 0) {return r;}
	enqueue_command(SPOTI_MPRIS_SET_POSITION, position);
	return sd_bus_reply_method_return(message, NULL);
}

static int method_open_uri(sd_bus_message *message, void *userdata, sd_bus_error *error) {
	(void)userdata;
	(void)error;
	const char *uri;
	int r = sd_bus_message_read(message, "s", &uri);
	if (r < 0) {return r;}
	return sd_bus_reply_method_return(message, NULL);
}

static const sd_bus_vtable root_vtable[] = {
	SD_BUS_VTABLE_START(0),
	SD_BUS_PROPERTY("CanQuit", "b", get_true, 0, SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_PROPERTY("CanRaise", "b", get_false, 0, SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_PROPERTY("HasTrackList", "b", get_false, 0, SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_PROPERTY("Identity", "s", get_identity, 0, SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_PROPERTY("DesktopEntry", "s", get_desktop_entry, 0, SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_PROPERTY("SupportedUriSchemes", "as", get_empty_strv, 0, SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_PROPERTY("SupportedMimeTypes", "as", get_empty_strv, 0, SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_METHOD("Raise", "", "", method_raise, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("Quit", "", "", method_quit, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_VTABLE_END
};

static const sd_bus_vtable player_vtable[] = {
	SD_BUS_VTABLE_START(0),
	SD_BUS_PROPERTY(
		"PlaybackStatus", "s", get_playback_status, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE
	),
	SD_BUS_PROPERTY("LoopStatus", "s", get_loop_status, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
	SD_BUS_PROPERTY("Rate", "d", get_rate, 0, SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_PROPERTY("Shuffle", "b", get_shuffle, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
	SD_BUS_PROPERTY("Metadata", "a{sv}", get_metadata, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
	SD_BUS_PROPERTY("Volume", "d", get_volume, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
	SD_BUS_PROPERTY("Position", "x", get_position, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
	SD_BUS_PROPERTY("MinimumRate", "d", get_rate, 0, SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_PROPERTY("MaximumRate", "d", get_rate, 0, SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_PROPERTY("CanGoNext", "b", get_can_next, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
	SD_BUS_PROPERTY(
		"CanGoPrevious", "b", get_can_previous, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE
	),
	SD_BUS_PROPERTY("CanPlay", "b", get_true, 0, SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_PROPERTY("CanPause", "b", get_true, 0, SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_PROPERTY("CanSeek", "b", get_can_seek, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
	SD_BUS_PROPERTY("CanControl", "b", get_true, 0, SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_METHOD("Next", "", "", method_next, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("Previous", "", "", method_previous, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("Pause", "", "", method_pause, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("PlayPause", "", "", method_play_pause, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("Stop", "", "", method_stop, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("Play", "", "", method_play, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("Seek", "x", "", method_seek, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("SetPosition", "ox", "", method_set_position, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("OpenUri", "s", "", method_open_uri, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_VTABLE_END
};

int spoti_mpris_start(void) {
	int r = sd_bus_default_user(&mpris_bus);
	if (r < 0) {return r;}
	r = sd_bus_add_object_vtable(
		mpris_bus, NULL, SPOTI_MPRIS_PATH, SPOTI_MPRIS_ROOT, root_vtable, NULL
	);
	if (r < 0) {return r;}
	r = sd_bus_add_object_vtable(
		mpris_bus, NULL, SPOTI_MPRIS_PATH, SPOTI_MPRIS_PLAYER, player_vtable, NULL
	);
	if (r < 0) {return r;}
	return sd_bus_request_name(mpris_bus, SPOTI_MPRIS_NAME, 0);
}

void spoti_mpris_set_wake(spoti_mpris_wake wake, void *userdata) {
	mpris_wake = wake;
	mpris_wake_userdata = userdata;
}

void spoti_mpris_stop(void) {
	mpris_bus = sd_bus_flush_close_unref(mpris_bus);
	mpris_wake = NULL;
}

// Runs on the worker thread: process inbound calls, then emit queued changes.
void spoti_mpris_service(void) {
	if (mpris_bus == NULL) {return;}
	for (;;) {
		int r = sd_bus_process(mpris_bus, NULL);
		if (r < 0) {return;}
		if (r == 0) {break;}
	}
	lock_state();
	int changed = changed_pending;
	int seeked = seeked_pending;
	int64_t position = seeked_us;
	changed_pending = 0;
	seeked_pending = 0;
	unlock_state();
	if (changed) {
		sd_bus_emit_properties_changed(
			mpris_bus, SPOTI_MPRIS_PATH, SPOTI_MPRIS_PLAYER,
			"PlaybackStatus", "Metadata", "Shuffle", "LoopStatus", "Volume", "CanSeek",
			"CanGoNext", "CanGoPrevious", NULL
		);
	}
	if (seeked) {
		sd_bus_emit_signal(
			mpris_bus, SPOTI_MPRIS_PATH, SPOTI_MPRIS_PLAYER, "Seeked", "x", position
		);
	}
}

int spoti_mpris_wait(int64_t timeout_us) {
	if (mpris_bus == NULL) {return -1;}
	return sd_bus_wait(mpris_bus, (uint64_t)timeout_us);
}

int spoti_mpris_take_command(int *command, int64_t *value) {
	lock_state();
	if (pending_head == pending_tail) {
		unlock_state();
		return 0;
	}
	*command = pending_commands[pending_head];
	*value = pending_values[pending_head];
	pending_head = (pending_head + 1) % SPOTI_MPRIS_QUEUE;
	unlock_state();
	return 1;
}

void spoti_mpris_set_track(const char *title, const char *artist, int64_t duration_us) {
	lock_state();
	snprintf(state.title, sizeof state.title, "%s", title != NULL ? title : "");
	snprintf(state.artist, sizeof state.artist, "%s", artist != NULL ? artist : "");
	state.duration_us = duration_us;
	changed_pending = 1;
	unlock_state();
}

void spoti_mpris_set_status(
	int playing, int shuffle, int repeat, int can_seek, int can_next, int can_previous,
	double volume
) {
	lock_state();
	state.playing = playing;
	state.shuffle = shuffle;
	state.repeat = repeat;
	state.can_seek = can_seek;
	state.can_next = can_next;
	state.can_previous = can_previous;
	state.volume = volume;
	changed_pending = 1;
	unlock_state();
}

void spoti_mpris_set_position(int64_t position_us) {
	lock_state();
	state.position_us = position_us;
	unlock_state();
}

void spoti_mpris_seeked(int64_t position_us) {
	lock_state();
	seeked_us = position_us;
	seeked_pending = 1;
	unlock_state();
}
