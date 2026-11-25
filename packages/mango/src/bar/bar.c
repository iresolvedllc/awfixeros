#include "mango/bar/bar.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "mango/common/input-event-codes.h"
#include "mango/common/log.h"
#include "mango/common/scene_node.h"
#include "mango/common/server.h"
#include "mango/common/util.h"
#include "mango/config/parse.h"
#include "mango/dispatch/bind.h"
#include "mango/draw/text-node.h"
#include "mango/ipc/ipc.h"
#include "mango/manage/client.h"
#include "mango/manage/layer.h"
#include "mango/manage/monitor.h"

#if defined(__has_include) && __has_include(<scenefx/types/fx/clipped_region.h>)
#include <scenefx/types/fx/clipped_region.h>
#define BAR_CORNER_RADIUS 1
#else
#define BAR_CORNER_RADIUS 0
#endif

#define BAR_GAP 4 /* gap between widgets, px */

static void bar_destroy_internal(struct MangoBar *bar);

static struct wl_event_source *bar_clock_source = NULL;
static struct wl_event_source *bar_status_source = NULL;
static struct wl_listener bar_print_status_listener;

/* Cached status widget texts, shared by every monitor. */
static char bar_clock_text[96] = "";
static char bar_battery_text[64] = "";

/* Widget labels never use the jump-label bg/border: the floating bar provides
 * the one rounded surface. */
static void bar_plain_draw_data(DecorateDrawData *out) {
	*out = config.bardata;
	out->bg_color[3] = 0.0f;
	out->border_width = 0;
}

/* Status widgets are one level of abstraction above tag buttons: they never
 * render the focused palette; the floating-bar bg is drawn by bar->bg. */
static void bar_status_label_init(MangoJumpLabel **slot,
								  struct wlr_scene_tree *parent) {
	DecorateDrawData plain;
	bar_plain_draw_data(&plain);
	*slot = mango_jump_label_node_create(parent, plain);
	if (*slot)
		mango_jump_label_node_set_background(*slot, 0.0f, 0.0f, 0.0f, 0.0f);
}

static void bar_label_update(MangoJumpLabel *label, const char *text,
							 float scale) {
	if (!label)
		return;
	mango_jump_label_node_update(label, text, scale > 0.0f ? scale : 1.0f);
}

static void bar_label_move(MangoJumpLabel *label, int32_t x, int32_t y) {
	if (!label || !label->scene)
		return;
	wlr_scene_node_set_position(&label->scene->node, x, y);
}

/* Same as bar_label_move but clamps inside the strip. */
/* The bar is visible unless the session is locked or a fullscreen window
 * covers the monitor. */
static bool bar_visible_for(Monitor *m) {
	if (server.session_locked)
		return false;
	if (m->isoverview)
		return true;
	Client *c = NULL;
	uint32_t tagset = m->tagset[m->seltags];
	wl_list_for_each(c, &server.clients, link) {
		if (c->mon != m || c->iskilling || c->isminimized)
			continue;
		if (!c->isfullscreen)
			continue;
		if ((c->tags & tagset) || c->isglobal)
			return false;
	}
	return true;
}

static void bar_layout(Monitor *m) {
	struct MangoBar *bar = m->bar;
	if (!bar || !bar->tree)
		return;

	bool visible = bar_visible_for(m);
	if (bar->tree->node.enabled != visible)
		wlr_scene_node_set_enabled(&bar->tree->node, visible);
	if (!visible)
		return;

	int32_t pad = (int32_t)config.bardata.padding_x;
	if (pad <= 0)
		pad = 6;
	int32_t width = m->m.width - 2 * (int32_t)config.bar_lr_gap;
	int32_t height = (int32_t)config.bar_height;
	if (width < 0)
		width = 0;

	if (bar->bg)
		wlr_scene_rect_set_size(bar->bg, width, height);

#if BAR_CORNER_RADIUS
	if (bar->bg) {
		int32_t radius = (int32_t)config.bar_corner_radius;
		radius = MANGO_MIN(radius, MANGO_MIN(width, height) / 2);
		if (radius < 0)
			radius = 0;
		wlr_scene_rect_set_corner_radii(bar->bg, corner_radii_all(radius));
	}
#else
	(void)config.bar_corner_radius;
#endif

	wlr_scene_node_set_position(&bar->tree->node,
								m->m.x + (int32_t)config.bar_lr_gap,
								m->m.y + (int32_t)config.bar_top_gap);

	/* Left group: tag buttons */
	int32_t cx = pad;
	for (int32_t i = 0; i < bar->tag_count; i++) {
		MangoJumpLabel *label = bar->tags[i];
		if (!label)
			continue;
		int32_t y = MANGO_MAX(0, (height - label->logical_height) / 2);
		bar_label_move(label, cx, y);
		cx += label->logical_width + BAR_GAP;
		if (cx < 0)
			cx = 0;
	}

	/* Right group, right-aligned: tray icons, battery, clock */
	int32_t rx = width - pad;
	if (rx < 0)
		rx = 0;

	for (int32_t i = bar->tray_icon_count - 1; i >= 0; i--) {
		struct wlr_scene_buffer *node = bar->tray_icons[i].node;
		if (!node)
			continue;
		rx -= (int32_t)config.bar_tray_icon_size;
		if (rx < 0)
			rx = 0;
		wlr_scene_node_set_position(
			&node->node, rx,
			MANGO_MAX(0, (height - (int32_t)config.bar_tray_icon_size) / 2));
		rx -= BAR_GAP;
	}

	if (bar->battery) {
		rx -= bar->battery->logical_width;
		if (rx < 0)
			rx = 0;
		bar_label_move(
			bar->battery, rx,
			MANGO_MAX(0, (height - bar->battery->logical_height) / 2));
		rx -= BAR_GAP;
	}
	if (bar->clock) {
		rx -= bar->clock->logical_width;
		if (rx < 0)
			rx = 0;
		bar_label_move(bar->clock, rx,
					   MANGO_MAX(0, (height - bar->clock->logical_height) / 2));
	}
}

int32_t bar_strip_height(void) {
	if (!config.bar_enable)
		return 0;
	return (int32_t)config.bar_top_gap + (int32_t)config.bar_height;
}

/* ---------------- tag buttons ---------------- */

static void bar_tag_text(int tag, char *buf, size_t len) {
	snprintf(buf, len, "%d", tag);
}

void bar_refresh_tags(void) {
	Monitor *m = NULL;

	wl_list_for_each(m, &server.monitors, link) {
		struct MangoBar *bar = m->bar;
		if (!bar)
			continue;

		float scale = m->wlr_output->scale > 0.0f ? m->wlr_output->scale : 1.0f;
		uint32_t active = get_monitor_active_tagset(m);
		bool special_active = is_special_active(m);
		bool special_used = special_active || special_has_clients(m);
		char text[16];

		for (int32_t i = 0; i < bar->tag_count; i++) {
			MangoJumpLabel *label = bar->tags[i];
			if (!label)
				continue;
			if (i < config.tag_num) {
				uint32_t tag_bit = 1u << i;
				bool is_active = (tag_bit & active) != 0;
				uint32_t status = get_tag_status(i + 1, m);
				wlr_scene_node_set_enabled(&label->scene->node, true);
				bar_tag_text(i + 1, text, sizeof(text));
				/* focused palette drives the text color */
				bar_label_update(label, text, scale);
				mango_jump_label_node_set_focus(label, is_active);
				/* the bg rect is set explicitly, so state transitions
				 * (urgent / active / idle) always end up with the right
				 * color */
				if (status == 2) {
					mango_jump_label_node_set_background(
						label, config.urgentcolor[0], config.urgentcolor[1],
						config.urgentcolor[2], config.urgentcolor[3]);
				} else if (is_active) {
					mango_jump_label_node_set_background(
						label, config.bardata.focus_bg_color[0],
						config.bardata.focus_bg_color[1],
						config.bardata.focus_bg_color[2],
						config.bardata.focus_bg_color[3]);
				} else {
					mango_jump_label_node_set_background(
						label, config.bardata.bg_color[0],
						config.bardata.bg_color[1], config.bardata.bg_color[2],
						0.0f); /* idle tags are transparent */
				}
			} else {
				/* special-workspace button */
				wlr_scene_node_set_enabled(&label->scene->node, special_used);
				bar_label_update(label, "S", scale);
				mango_jump_label_node_set_focus(label, special_active);
			}
		}

		/* 10+ tag digits change button widths */
		bar_layout(m);
	}
}

void bar_monitor_layout(Monitor *m) { bar_layout(m); }

/* ---------------- clock ---------------- */

static void bar_clock_refresh(bool relayout) {
	char buf[96];
	time_t now = time(NULL);
	struct tm tmnow;
	const char *fmt =
		config.bar_clock_format ? config.bar_clock_format : "%H:%M";

	localtime_r(&now, &tmnow);
	buf[0] = '\0';
	strftime(buf, sizeof(buf), fmt, &tmnow);

	/* Diffs are handled inside the jump label; only the text matters here. */
	if (buf[0] && strcmp(buf, bar_clock_text) != 0)
		snprintf(bar_clock_text, sizeof(bar_clock_text), "%s", buf);

	Monitor *m = NULL;
	wl_list_for_each(m, &server.monitors, link) {
		if (!m->bar)
			continue;
		float scale = m->wlr_output->scale > 0.0f ? m->wlr_output->scale : 1.0f;
		bar_label_update(m->bar->clock, bar_clock_text, scale);
		if (relayout)
			bar_layout(m);
	}
}

static int bar_clock_tick(void *data) {
	(void)data;

	bar_clock_refresh(true);

	/* Seconds format -> 1 Hz; otherwise sleep until the next minute. */
	int32_t delay_ms;
	if (config.bar_clock_format && strstr(config.bar_clock_format, "%S")) {
		delay_ms = 1000;
	} else {
		time_t now = time(NULL);
		struct tm tmnow;
		localtime_r(&now, &tmnow);
		delay_ms = (60 - tmnow.tm_sec) * 1000;
	}
	if (bar_clock_source)
		wl_event_source_timer_update(bar_clock_source, delay_ms);
	return 0;
}

/* ---------------- battery ---------------- */

static bool bar_read_file(const char *path, char *buf, size_t len) {
	FILE *fd = fopen(path, "r");
	if (!fd)
		return false;
	bool ok = fgets(buf, (int)len, fd) != NULL;
	fclose(fd);
	if (!ok)
		return false;
	buf[strcspn(buf, "\n")] = '\0';
	return true;
}

static void bar_battery_refresh(bool relayout) {
	DIR *dir = opendir("/sys/class/power_supply");

	if (dir) {
		struct dirent *ent;
		int total = 0, count = 0, count_ac = 0;
		char path[320], buf[64];

		while ((ent = readdir(dir))) {
			if (strncmp(ent->d_name, "BAT", 3) == 0) {
				snprintf(path, sizeof(path),
						 "/sys/class/power_supply/%s/capacity", ent->d_name);
				if (bar_read_file(path, buf, sizeof(buf))) {
					total += atoi(buf);
					count++;
				}
			} else if (strncmp(ent->d_name, "AC", 2) == 0) {
				snprintf(path, sizeof(path),
						 "/sys/class/power_supply/%s/online", ent->d_name);
				if (bar_read_file(path, buf, sizeof(buf)) && atoi(buf) == 1)
					count_ac++;
			}
		}
		closedir(dir);

		char text[64] = "";
		if (count > 0 && count_ac > 0) /* charging */
			snprintf(text, sizeof(text), "+%d%%", count ? total / count : 0);
		else if (count > 0)
			snprintf(text, sizeof(text), "%d%%", count ? total / count : 0);
		else if (count_ac > 0)
			snprintf(text, sizeof(text), "AC");

		if (strcmp(text, bar_battery_text) != 0)
			snprintf(bar_battery_text, sizeof(bar_battery_text), "%s", text);
	}

	/* Jump labels detect unchanged text internally, so unconditional
	 * re-rendering here is essentially free. */
	Monitor *m = NULL;
	wl_list_for_each(m, &server.monitors, link) {
		if (!m->bar)
			continue;
		float scale = m->wlr_output->scale > 0.0f ? m->wlr_output->scale : 1.0f;
		bar_label_update(m->bar->battery, bar_battery_text, scale);
		if (relayout)
			bar_layout(m);
	}
}

static int bar_status_tick(void *data) {
	(void)data;

	bar_battery_refresh(true);
	tray_reload(); /* keeps the dbus connection healthy and reconnects */

	if (bar_status_source && config.bar_battery_interval > 0)
		wl_event_source_timer_update(bar_status_source,
									 (int32_t)config.bar_battery_interval);
	return 0;
}

static void bar_ensure_timers(void) {
	if (!bar_clock_source) {
		bar_clock_source =
			wl_event_loop_add_timer(server.event_loop, bar_clock_tick, NULL);
	}
	if (!bar_status_source) {
		bar_status_source =
			wl_event_loop_add_timer(server.event_loop, bar_status_tick, NULL);
	}
	if (bar_clock_source)
		wl_event_source_timer_update(bar_clock_source, 1);
	if (bar_status_source)
		wl_event_source_timer_update(bar_status_source, 1);
}

static void bar_stop_timers(void) {
	if (bar_clock_source) {
		wl_event_source_timer_update(bar_clock_source, 0);
	}
	if (bar_status_source) {
		wl_event_source_timer_update(bar_status_source, 0);
	}
}

/* ---------------- creation / destruction ---------------- */

static bool bar_create(Monitor *m) {
	struct MangoBar *bar = calloc(1, sizeof(*bar));
	if (!bar)
		return false;

	bar->mon = m;
	bar->tree = wlr_scene_tree_create(server.layers[LyrBar]);
	if (!bar->tree) {
		bar_destroy_internal(bar);
		return false;
	}
	bar->bg = wlr_scene_rect_create(bar->tree, 0, 0, config.bar_bg_color);
	if (!bar->bg) {
		bar_destroy_internal(bar);
		return false;
	}

	bar->tag_count = config.tag_num + 1; /* + special button */
	bar->tags = calloc(bar->tag_count, sizeof(MangoJumpLabel *));
	bar->tag_btns = calloc(bar->tag_count, sizeof(BarButton));
	if (!bar->tags || !bar->tag_btns) {
		bar_destroy_internal(bar);
		return false;
	}

	for (int32_t i = 0; i < bar->tag_count; i++) {
		DecorateDrawData data;
		bar_plain_draw_data(&data);

		bar->tags[i] = mango_jump_label_node_create(bar->tree, data);
		if (!bar->tags[i])
			continue;

		bar->tag_btns[i].type =
			i < config.tag_num ? BarNodeTypeTag : BarNodeTypeSpecial;
		bar->tag_btns[i].tag = i < config.tag_num ? i + 1 : 0;
		bar->tag_btns[i].item = NULL;
		mango_scene_node_set(&bar->tags[i]->scene->node, bar->tag_btns[i].type,
							 &bar->tag_btns[i]);
	}

	bar_status_label_init(&bar->battery, bar->tree);
	bar_status_label_init(&bar->clock, bar->tree);

	tray_sync_bar(bar);
	m->bar = bar;
	return true;
}

void bar_monitor_create(Monitor *m) {
	if (!config.bar_enable || m->bar || m->iscleanuping)
		return;

	if (bar_create(m)) {
		bar_ensure_timers();
		tray_reload();
		bar_battery_refresh(true);
		bar_clock_refresh(true);
		bar_refresh_tags();
		bar_layout(m);
	}
}

void bar_destroy_internal(struct MangoBar *bar) {
	if (!bar)
		return;

	tray_detach_bar(bar);

	if (bar->tags) {
		for (int32_t i = 0; i < bar->tag_count; i++) {
			if (bar->tags[i])
				mango_jump_label_node_destroy(bar->tags[i]);
		}
		free(bar->tags);
	}
	free(bar->tag_btns);

	if (bar->battery)
		mango_jump_label_node_destroy(bar->battery);
	if (bar->clock)
		mango_jump_label_node_destroy(bar->clock);

	if (bar->tree)
		wlr_scene_node_destroy(&bar->tree->node);
	free(bar);
}

void bar_monitor_destroy(Monitor *m) {
	if (!m || !m->bar)
		return;
	struct MangoBar *bar = m->bar;
	m->bar = NULL;
	bar_destroy_internal(bar);
}

void bar_config_reload(void) {
	Monitor *m = NULL;

	/* Re-create to pick up tag_num / fonts / colors / geometry changes. */
	wl_list_for_each(m, &server.monitors, link) bar_monitor_destroy(m);
	wl_list_for_each(m, &server.monitors, link) {
		if (config.bar_enable)
			bar_monitor_create(m);
		arrange_layers(m);
	}

	tray_reload();

	if (!config.bar_enable) {
		/* no bar left: stop draining CPU. The next bar creation restarts. */
		bar_stop_timers();
		tray_cleanup();
	}
}

/* ---------------- visibility ---------------- */

void bar_update_lock(void) {
	Monitor *m = NULL;
	wl_list_for_each(m, &server.monitors, link) {
		if (m->bar)
			bar_layout(m); /* visibility is computed inside the layout */
	}
}

/* ---------------- click handling ---------------- */

bool bar_handle_button_press(double x, double y, uint32_t button) {
	if (!config.bar_enable)
		return false;

	struct wlr_scene_node *node = mango_scene_node_at(
		&server.layers_wrap[LyrBar]->node, x, y, NULL, NULL);
	if (!node)
		return false;

	MangoSceneNode *data = mango_scene_node_find(node);
	if (data && data->owner) {
		BarButton *btn = data->owner;

		switch (btn->type) {
		case BarNodeTypeTag:
			bind_to_view(&(Arg){.ui = 1u << (btn->tag - 1)});
			return true;
		case BarNodeTypeSpecial:
			bind_to_view(&(Arg){.ui = TAG0_MASK});
			return true;
		case BarNodeTypeTray:
			tray_click(btn->item, button);
			return true;
		}
	}

	/* Click landed on bare bar chrome: swallow it. */
	return true;
}

/* ---------------- print hook ---------------- */

static void bar_handle_print_status(struct wl_listener *listener, void *data) {
	enum ipc_watch_type type = *(enum ipc_watch_type *)data;
	if (type & (IPC_WATCH_TAGS | IPC_WATCH_ALL_TAGS | IPC_WATCH_MONITOR |
				IPC_WATCH_CLIENT | IPC_WATCH_FOCUSING_CLIENT)) {
		bar_refresh_tags();
	}
}

/* ---------------- init / cleanup ---------------- */

void bar_init(struct wl_event_loop *loop) {
	tray_init(loop);
	LISTEN(&server.print_status_signal, &bar_print_status_listener,
		   bar_handle_print_status);
}

void bar_tray_sync_all(void) {
	Monitor *m = NULL;
	wl_list_for_each(m, &server.monitors, link) {
		if (!m->bar)
			continue;
		tray_sync_bar(m->bar);
		bar_layout(m);
	}
}

void bar_cleanup(void) {
	wl_list_remove(&bar_print_status_listener.link);

	Monitor *m = NULL, *tmp = NULL;
	wl_list_for_each_safe(m, tmp, &server.monitors, link)
		bar_monitor_destroy(m);

	if (bar_clock_source) {
		wl_event_source_remove(bar_clock_source);
		bar_clock_source = NULL;
	}
	if (bar_status_source) {
		wl_event_source_remove(bar_status_source);
		bar_status_source = NULL;
	}
	tray_cleanup();
}
