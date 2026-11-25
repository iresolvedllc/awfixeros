#include "mango/bar/bar.h"

#include <cairo.h>
#include <dirent.h>
#include <drm_fourcc.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wlr/interfaces/wlr_buffer.h>

#include "mango/common/input-event-codes.h"
#include "mango/common/log.h"
#include "mango/common/scene_node.h"
#include "mango/common/server.h"
#include "mango/common/util.h"
#include "mango/config/parse.h"
#include "mango/draw/text-node.h"
#include "mango/manage/monitor.h"

/*
 * Minimal org.kde.StatusNotifierWatcher implementation for the built-in bar.
 *
 * Tray apps talk to us over the session bus: they call
 * RegisterStatusNotifierItem and export org.kde.StatusNotifierItem objects
 * (IconPixmap as raw ARGB32, or IconName resolved through the icon theme).
 * Icons are rendered into scene buffers of every live bar.
 *
 * The dbus connection is integrated into mango's wl_event_loop through its
 * fd. Without libsystemd (no HAVE_TRAY) everything below is a no-op, so the
 * bar keeps working and simply has no tray.
 */

#ifdef HAVE_TRAY
#include <systemd/sd-bus.h>

#define SNI_WATCHER_IFACE "org.kde.StatusNotifierWatcher"
#define SNI_WATCHER_PATH "/org/freedesktop/StatusNotifierWatcher"
/* same object exported here as well: some clients (tray-icon based apps)
 * register at the spec's pseudo-canonical path */
#define SNI_WATCHER_ALT_PATH "/StatusNotifierWatcher"
#define SNI_WATCHER_NAME "org.kde.StatusNotifierWatcher"
#define SNI_ITEM_IFACE "org.kde.StatusNotifierItem"
#define SNI_LISTEN_SIGNALS 5

struct TrayPixmap {
	int32_t width;
	int32_t height;
	uint32_t *data; /* ARGB32, premultiplied */
};

struct MangoTrayItem {
	char *name; /* sender bus name (registration service) */
	char *path; /* object path of the item */
	char *icon_name;
	char *theme_path;
	char status[32]; /* "" / "Active" / "Passive" / "NeedsAttention" */
	struct TrayPixmap *pixmaps;
	int32_t pixmap_count;
	/* match slots that die together with the item */
	sd_bus_slot *slots[SNI_LISTEN_SIGNALS];
	sd_bus_slot *props_slot;
	struct wl_list link;
};

static sd_bus *tray_bus = NULL;
static struct wl_event_source *tray_fd_source = NULL;
static struct wl_list items; /* struct MangoTrayItem::link */
static bool items_ready = false;

/* ---------------------------------------------------------------- buffers */

static void tray_buffer_destroy(struct wlr_buffer *wlr_buffer) {
	struct mango_text_buffer *buf = wl_container_of(wlr_buffer, buf, base);
	if (buf->surface) {
		cairo_surface_destroy(buf->surface);
	}
	free(buf);
}

static bool tray_buffer_begin_data_ptr_access(struct wlr_buffer *wlr_buffer,
											  uint32_t flags, void **data,
											  uint32_t *format,
											  size_t *stride) {
	if (flags & WLR_BUFFER_DATA_PTR_ACCESS_WRITE) {
		return false;
	}
	struct mango_text_buffer *buf = wl_container_of(wlr_buffer, buf, base);
	if (!buf->surface) {
		return false;
	}
	*data = cairo_image_surface_get_data(buf->surface);
	*format = DRM_FORMAT_ARGB8888;
	*stride = cairo_image_surface_get_stride(buf->surface);
	return true;
}

static void tray_buffer_end_data_ptr_access(struct wlr_buffer *wlr_buffer) {}

static const struct wlr_buffer_impl tray_buffer_impl = {
	.destroy = tray_buffer_destroy,
	.begin_data_ptr_access = tray_buffer_begin_data_ptr_access,
	.end_data_ptr_access = tray_buffer_end_data_ptr_access,
};

static struct mango_text_buffer *tray_buffer_create(int32_t pixel_w,
													int32_t pixel_h) {
	uint32_t w = MANGO_MAX(pixel_w, 1), h = MANGO_MAX(pixel_h, 1);
	cairo_surface_t *surface =
		cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)w, (int)h);
	if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(surface);
		return NULL;
	}
	struct mango_text_buffer *buf = calloc(1, sizeof(*buf));
	if (!buf) {
		cairo_surface_destroy(surface);
		return NULL;
	}
	wlr_buffer_init(&buf->base, &tray_buffer_impl, (int)w, (int)h);
	buf->surface = surface;
	return buf;
}

static bool surface_load_png(const char *path, cairo_surface_t **out) {
	*out = cairo_image_surface_create_from_png(path);
	return *out && cairo_surface_status(*out) == CAIRO_STATUS_SUCCESS;
}

/* ---------------------------------------------------------------- items */

static struct MangoTrayItem *item_create(const char *name, const char *path) {
	struct MangoTrayItem *item = calloc(1, sizeof(*item));
	if (!item)
		return NULL;
	item->name = name ? strdup(name) : strdup("");
	item->path = path ? strdup(path) : strdup("");
	if (!item->name || !item->path) {
		free(item->name);
		free(item->path);
		free(item);
		return NULL;
	}
	wl_list_append(&items, &item->link);
	return item;
}

static void pixmap_list_free(struct MangoTrayItem *item) {
	for (int32_t i = 0; i < item->pixmap_count; i++)
		free(item->pixmaps[i].data);
	free(item->pixmaps);
	item->pixmaps = NULL;
	item->pixmap_count = 0;
}

static void item_destroy(struct MangoTrayItem *item) {
	wl_list_remove(&item->link);
	for (int32_t i = 0; i < SNI_LISTEN_SIGNALS; i++) {
		if (item->slots[i]) {
			sd_bus_slot_unref(item->slots[i]);
			item->slots[i] = NULL;
		}
	}
	if (item->props_slot) {
		sd_bus_slot_unref(item->props_slot);
		item->props_slot = NULL;
	}
	pixmap_list_free(item);
	free(item->name);
	free(item->path);
	free(item->icon_name);
	free(item->theme_path);
	free(item);
}

/* ------------------------------------------------- property refresh */

static int item_props_done(sd_bus_message *m, void *userdata,
						   sd_bus_error *ret_error);

static void item_refresh_async(struct MangoTrayItem *item) {
	if (item->props_slot) {
		sd_bus_slot_unref(item->props_slot);
		item->props_slot = NULL;
	}
	int r = sd_bus_call_method_async(
		tray_bus, &item->props_slot, item->name, item->path,
		"org.freedesktop.DBus.Properties", "GetAll", item_props_done, item, "s",
		SNI_ITEM_IFACE);
	if (r < 0) {
		/* item not reachable (yet): try to recover on its signals */
		if (item->props_slot) {
			sd_bus_slot_unref(item->props_slot);
			item->props_slot = NULL;
		}
	}
}

/* Reads "a(iiay)" pixmaps from an open "sv" variant container; the variant
 * container stays open for the caller (it exits after this returns). */
static int read_pixmap_variant(sd_bus_message *m, struct MangoTrayItem *item) {
	struct TrayPixmap *pixmaps = NULL;
	int32_t count = 0;

	int r = sd_bus_message_enter_container(m, SD_BUS_TYPE_ARRAY, "(iiay)");
	if (r < 0)
		return r;

	while (sd_bus_message_enter_container(m, SD_BUS_TYPE_STRUCT, "iiay") > 0) {
		int32_t w = 0, h = 0;
		r = sd_bus_message_read(m, "ii", &w, &h);
		if (r < 0)
			goto fail;

		if (w > 0 && h > 0 && w * h <= 4096 * 4096) {
			size_t bytes = (size_t)w * (size_t)h * 4;
			uint32_t *data = malloc(bytes);
			if (!data) {
				r = -ENOMEM;
				goto fail;
			}
			r = sd_bus_message_enter_container(m, SD_BUS_TYPE_ARRAY, "y");
			if (r < 0) {
				free(data);
				goto fail;
			}
			size_t got = 0;
			uint8_t byte;
			while (sd_bus_message_read(m, "y", &byte) > 0) {
				if (got < bytes)
					((uint8_t *)data)[got] = byte;
				got++;
			}
			sd_bus_message_exit_container(m);

			if (got == bytes) {
				struct TrayPixmap *next =
					realloc(pixmaps, sizeof(*pixmaps) * (count + 1));
				if (next) {
					pixmaps = next;
					pixmaps[count].width = w;
					pixmaps[count].height = h;
					pixmaps[count].data = data;
					count++;
				} else {
					free(data);
				}
			} else {
				free(data);
			}
		} else {
			/* pathological entry: skip the byte array */
			sd_bus_message_skip(m, NULL);
		}
		sd_bus_message_exit_container(m);
	}
	sd_bus_message_exit_container(m);

	pixmap_list_free(item);
	item->pixmaps = pixmaps;
	item->pixmap_count = count;
	return 0;

fail:
	for (int32_t i = 0; i < count; i++) {
		free(pixmaps[i].data);
	}
	free(pixmaps);
	return r;
}

static void item_free_strings(struct MangoTrayItem *item) {
	free(item->icon_name);
	free(item->theme_path);
	item->icon_name = NULL;
	item->theme_path = NULL;
	item->status[0] = '\0';
}

static int item_props_done(sd_bus_message *m, void *userdata,
						   sd_bus_error *ret_error) {
	struct MangoTrayItem *item = userdata;

	if (item->props_slot) {
		sd_bus_slot_unref(item->props_slot);
		item->props_slot = NULL;
	}

	if (sd_bus_message_is_method_error(m, NULL)) {
		const sd_bus_error *error = sd_bus_message_get_error(m);
		if (error && error->name &&
			strcmp(error->name, "org.freedesktop.DBus.Error.UnknownObject") ==
				0) {
			/* item is gone */
			item_destroy(item);
			bar_tray_sync_all();
		}
		return 1;
	}

	char *new_icon = NULL, *new_theme = NULL;
	char new_status[32] = "";
	bool has_status = false;
	struct TrayPixmap *pixmaps = NULL;
	int32_t pixmap_count = 0;

	int r = sd_bus_message_enter_container(m, SD_BUS_TYPE_ARRAY, "{sv}");
	if (r < 0)
		goto out;

	while (sd_bus_message_enter_container(m, SD_BUS_TYPE_DICT_ENTRY, "sv") >
		   0) {
		const char *key = NULL;
		r = sd_bus_message_read(m, "s", &key);
		if (r < 0)
			break;

		r = sd_bus_message_enter_container(m, SD_BUS_TYPE_VARIANT, NULL);
		if (r < 0)
			break;

		if (strcmp(key, "IconName") == 0) {
			const char *value = NULL;
			if (sd_bus_message_read(m, "s", &value) >= 0 && value) {
				free(new_icon);
				new_icon = strdup(value);
			}
		} else if (strcmp(key, "IconThemePath") == 0) {
			const char *value = NULL;
			if (sd_bus_message_read(m, "s", &value) >= 0 && value) {
				free(new_theme);
				new_theme = strdup(value);
			}
		} else if (strcmp(key, "Status") == 0) {
			const char *value = NULL;
			if (sd_bus_message_read(m, "s", &value) >= 0 && value) {
				snprintf(new_status, sizeof(new_status), "%s", value);
				has_status = true;
			}
		} else if (strcmp(key, "IconPixmap") == 0) {
			r = read_pixmap_variant(m, item);
			if (r >= 0) {
				/* steal the parsed pixmaps (item fields cleared inside) */
				pixmaps = item->pixmaps;
				pixmap_count = item->pixmap_count;
				item->pixmaps = NULL;
				item->pixmap_count = 0;
			}
		} else {
			sd_bus_message_skip(m, NULL);
		}

		if (r >= 0)
			r = sd_bus_message_exit_container(m); /* variant */
		if (r >= 0)
			r = sd_bus_message_exit_container(m); /* dict entry */
		if (r < 0)
			break;
	}
	(void)sd_bus_message_exit_container(m); /* array */

out:
	if (r >= 0 || pixmaps) {
		if (new_icon) {
			free(item->icon_name);
			item->icon_name = new_icon;
			new_icon = NULL;
		}
		if (new_theme) {
			free(item->theme_path);
			item->theme_path = new_theme;
			new_theme = NULL;
		}
		if (has_status)
			snprintf(item->status, sizeof(item->status), "%s", new_status);
		if (pixmaps) {
			pixmap_list_free(item);
			item->pixmaps = pixmaps;
			item->pixmap_count = pixmap_count;
			pixmaps = NULL;
		}
	}
	free(new_icon);
	free(new_theme);
	if (pixmaps) {
		for (int32_t i = 0; i < pixmap_count; i++)
			free(pixmaps[i].data);
		free(pixmaps);
	}

	bar_tray_sync_all();
	return 1;
}

/* ------------------------------------------------- watcher (dbus object) */

static void item_listen_signals(struct MangoTrayItem *item);

static int watcher_register_item(sd_bus_message *m, void *userdata,
								 sd_bus_error *ret_error) {
	if (!items_ready)
		return 0;
	const char *param = NULL;
	if (sd_bus_message_read(m, "s", &param) < 0 || !param || !param[0]) {
		return 0;
	}

	const char *fallback_service = sd_bus_message_get_sender(m);
	char *service = NULL, *path = NULL;

	const char *slash = strchr(param, '/');
	if (slash && slash != param) {
		/* "service/path" */
		service = strndup(param, (size_t)(slash - param));
		path = strdup(slash);
	} else {
		service = fallback_service ? strdup(fallback_service) : strdup("");
		path = strdup(param);
	}
	if (!service || !path) {
		free(service);
		free(path);
		return 0;
	}

	struct MangoTrayItem *item = NULL, *it = NULL;
	wl_list_for_each(it, &items, link) {
		if (strcmp(it->name, service) == 0 && it->path &&
			strcmp(it->path, path) == 0) {
			item = it;
			break;
		}
	}
	bool fresh = item == NULL;
	if (fresh) {
		item = item_create(service, path);
		item_listen_signals(item);
	}

	if (item) {
		pixmap_list_free(item);
		item_free_strings(item);
		item_refresh_async(item);
	}

	free(service);
	free(path);
	bar_tray_sync_all();
	return 0;
}

static int watcher_register_host(sd_bus_message *m, void *userdata,
								 sd_bus_error *ret_error) {
	return 0;
}

static int watcher_get_items(sd_bus *bus, const char *path, const char *iface,
							 const char *prop, sd_bus_message *reply,
							 void *userdata, sd_bus_error *ret_error) {
	int r = sd_bus_message_open_container(reply, SD_BUS_TYPE_ARRAY, "s");
	if (r < 0)
		return r;
	struct MangoTrayItem *item = NULL;
	wl_list_for_each(item, &items, link) {
		char *combined = string_printf("%s%s", item->name, item->path);
		if (combined) {
			r = sd_bus_message_append(reply, "s", combined);
			free(combined);
			if (r < 0)
				return r;
		}
	}
	return sd_bus_message_close_container(reply);
}

static int watcher_get_bool(sd_bus *bus, const char *path, const char *iface,
							const char *prop, sd_bus_message *reply,
							void *userdata, sd_bus_error *ret_error) {
	return sd_bus_message_append(reply, "b", 1);
}

static int watcher_get_version(sd_bus *bus, const char *path, const char *iface,
							   const char *prop, sd_bus_message *reply,
							   void *userdata, sd_bus_error *ret_error) {
	return sd_bus_message_append(reply, "i", 1);
}

static const sd_bus_vtable watcher_vtable[] = {
	SD_BUS_VTABLE_START(0),
	SD_BUS_METHOD("RegisterStatusNotifierItem", "s", "", watcher_register_item,
				  0),
	SD_BUS_METHOD("RegisterStatusNotifierHost", "s", "", watcher_register_host,
				  0),
	SD_BUS_PROPERTY("RegisteredStatusNotifierItems", "as", watcher_get_items, 0,
					0),
	SD_BUS_PROPERTY("IsStatusNotifierHostRegistered", "b", watcher_get_bool, 0,
					0),
	SD_BUS_PROPERTY("ProtocolVersion", "i", watcher_get_version, 0, 0),
	SD_BUS_VTABLE_END,
};

static int on_item_signal(sd_bus_message *m, void *userdata,
						  sd_bus_error *ret_error) {
	struct MangoTrayItem *item = userdata;
	item_refresh_async(item);
	return 0;
}

static void item_listen_signals(struct MangoTrayItem *item) {
	static const char *const members[SNI_LISTEN_SIGNALS] = {
		"NewIcon", "NewAttentionIcon", "NewStatus", "NewPixmap", "NewTitle",
	};
	if (!item || item->slots[0])
		return; /* slots already installed */
	for (int32_t i = 0; i < SNI_LISTEN_SIGNALS; i++) {
		(void)sd_bus_match_signal(tray_bus, &item->slots[i], item->name,
								  item->path, SNI_ITEM_IFACE, members[i],
								  on_item_signal, item);
	}
}

static int on_name_owner_changed(sd_bus_message *m, void *userdata,
								 sd_bus_error *ret_error) {
	if (!items_ready)
		return 0;
	const char *name = NULL, *old = NULL, *new = NULL;
	if (sd_bus_message_read(m, "sss", &name, &old, &new) < 0)
		return 0;
	if (!name || !new || new[0] != '\0')
		return 0;

	bool removed = false;
	struct MangoTrayItem *item = NULL, *tmp = NULL;
	wl_list_for_each_safe(item, tmp, &items, link) {
		if (strcmp(item->name, name) == 0) {
			item_destroy(item);
			removed = true;
		}
	}
	if (removed)
		bar_tray_sync_all();
	return 0;
}

/* ---------------------------------------------------------------- icons */

static bool pixmap_find_best(struct MangoTrayItem *item, int32_t target,
							 struct TrayPixmap **best) {
	*best = NULL;
	for (int32_t i = 0; i < item->pixmap_count; i++) {
		struct TrayPixmap *cur = &item->pixmaps[i];
		if (cur->width <= 0 || cur->height <= 0 || !cur->data)
			continue;
		if (!*best || abs(cur->width - target) < abs((*best)->width - target))
			*best = cur;
	}
	return *best != NULL;
}

static bool paint_surface_scaled(cairo_t *cr, cairo_surface_t *src,
								 int32_t pix) {
	double sw = (double)cairo_image_surface_get_width(src);
	double sh = (double)cairo_image_surface_get_height(src);
	if (sw <= 0 || sh <= 0)
		return false;
	cairo_save(cr);
	cairo_scale(cr, (double)pix / sw, (double)pix / sh);
	cairo_set_source_surface(cr, src, 0, 0);
	cairo_paint(cr);
	cairo_restore(cr);
	return true;
}

#define THEME_LOOKUP_DIRS 5

static bool theme_lookup(const char *dirs[], const char *rel_icon,
						 int32_t target, cairo_surface_t **out) {
	for (int i = 0; i < THEME_LOOKUP_DIRS; i++) {
		const char *base = dirs[i];
		if (!base || !base[0])
			continue;
		DIR *d = opendir(base);
		if (!d)
			continue;
		struct dirent *ent;
		int32_t best_diff = -1;
		char best_name[300] = "";
		while ((ent = readdir(d))) {
			const char *s = ent->d_name;
			if (s[0] < '0' || s[0] > '9')
				continue;
			int32_t num = atoi(s);
			if (num <= 0)
				continue;
			int32_t diff = abs(num - target);
			if (best_diff < 0 || diff < best_diff) {
				best_diff = diff;
				snprintf(best_name, sizeof(best_name), "%s", s);
			}
		}
		closedir(d);
		if (best_name[0] == '\0')
			continue;

		char path[512];
		snprintf(path, sizeof(path), "%s/%s/apps/%s.png", base, best_name,
				 rel_icon);
		if (surface_load_png(path, out))
			return true;
		snprintf(path, sizeof(path), "%s/%s/status/%s.png", base, best_name,
				 rel_icon);
		if (surface_load_png(path, out))
			return true;
	}
	return false;
}

static bool tray_render_icon_pixmap(cairo_surface_t *dst,
									struct MangoTrayItem *item,
									int32_t target_size, float scale) {
	int32_t pix = (int32_t)(target_size * scale + 0.5f);
	if (pix < 1)
		pix = 1;

	cairo_t *cr = cairo_create(dst);
	cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
	cairo_set_source_rgba(cr, 0, 0, 0, 0);
	cairo_paint(cr);

	bool drawn = false;
	struct TrayPixmap *pm = NULL;
	if (pixmap_find_best(item, target_size, &pm) && pm->data) {
		int32_t sw = pm->width, sh = pm->height;
		cairo_surface_t *src = cairo_image_surface_create_for_data(
			(unsigned char *)pm->data, CAIRO_FORMAT_ARGB32, sw, sh, sw * 4);
		if (src && cairo_surface_status(src) == CAIRO_STATUS_SUCCESS)
			drawn = paint_surface_scaled(cr, src, pix);
		if (src)
			cairo_surface_destroy(src);
	}

	if (!drawn && item->icon_name && item->icon_name[0]) {
		/* icon-name fallback: nearest-size png in the standard theme dirs */
		static char home_icons[256];
		static char data_icons[256];
		char stripped[128];
		const char *rel = item->icon_name;
		if (strchr(rel, '/')) { /* never treat icon names as paths */
			rel = strrchr(rel, '/') + 1;
		}
		const char *dot = strrchr(rel, '.');
		if (dot && (strcmp(dot, ".png") == 0 || strcmp(dot, ".svg") == 0)) {
			snprintf(stripped, sizeof(stripped), "%.*s", (int)(dot - rel), rel);
			rel = stripped;
		}
		const char *home = getenv("HOME");
		if (home) {
			snprintf(home_icons, sizeof(home_icons), "%s/.icons", home);
			snprintf(data_icons, sizeof(data_icons), "%s/.local/share/icons",
					 home);
		}
		const char *dirs[THEME_LOOKUP_DIRS] = {
			home ? home_icons : NULL,	home ? data_icons : NULL,
			"/usr/share/icons/hicolor", "/usr/share/pixmaps",
			item->theme_path,
		};
		cairo_surface_t *src = NULL;
		if (theme_lookup(dirs, rel, target_size, &src)) {
			drawn = paint_surface_scaled(cr, src, pix);
			cairo_surface_destroy(src);
		}
	}

	cairo_destroy(cr);
	return drawn;
}

/* ---------------------------------------------------------------- bars */

void tray_sync_bar(struct MangoBar *bar) {
	if (!bar || !items_ready)
		return;
	tray_detach_bar(bar);

	int32_t count = 0;
	struct MangoTrayItem *item = NULL;
	wl_list_for_each(item, &items, link) {
		if (strcmp(item->status, "Passive") == 0)
			continue;
		count++;
	}
	if (count == 0)
		return;

	bar->tray_icons = calloc(count, sizeof(BarTrayIcon));
	if (!bar->tray_icons)
		return;
	bar->tray_icon_capacity = count;
	bar->tray_icon_count = 0;

	wl_list_for_each(item, &items, link) {
		if (strcmp(item->status, "Passive") == 0)
			continue;
		BarTrayIcon *icon = &bar->tray_icons[bar->tray_icon_count];
		icon->item = item;

		float scale = bar->mon && bar->mon->wlr_output->scale > 0.0f
						  ? bar->mon->wlr_output->scale
						  : 1.0f;
		int32_t pix = (int32_t)(config.bar_tray_icon_size * scale + 0.5f);
		if (pix < 1)
			pix = 1;

		struct mango_text_buffer *buf = tray_buffer_create(pix, pix);
		if (!buf)
			continue;
		tray_render_icon_pixmap(buf->surface, item, config.bar_tray_icon_size,
								scale);

		icon->node = wlr_scene_buffer_create(bar->tree, NULL);
		if (!icon->node) {
			wlr_buffer_drop(&buf->base);
			continue;
		}
		wlr_scene_buffer_set_buffer(icon->node, &buf->base);
		wlr_buffer_drop(&buf->base); /* the scene buffer holds its own ref */
		wlr_scene_buffer_set_dest_size(icon->node,
									   (int32_t)config.bar_tray_icon_size,
									   (int32_t)config.bar_tray_icon_size);

		icon->btn.type = BarNodeTypeTray;
		icon->btn.tag = 0;
		icon->btn.item = item;
		mango_scene_node_set(&icon->node->node, BarNodeTypeTray, &icon->btn);

		bar->tray_icon_count++;
	}
}

void tray_detach_bar(struct MangoBar *bar) {
	if (!bar)
		return;
	for (int32_t i = 0; i < bar->tray_icon_count; i++) {
		if (bar->tray_icons[i].node) {
			wlr_scene_node_destroy(&bar->tray_icons[i].node->node);
			bar->tray_icons[i].node = NULL;
		}
	}
	free(bar->tray_icons);
	bar->tray_icons = NULL;
	bar->tray_icon_count = 0;
	bar->tray_icon_capacity = 0;
}

void tray_click(struct MangoTrayItem *item, uint32_t button) {
	if (!item || !tray_bus)
		return;
	const char *method = button == BTN_RIGHT ? "SecondaryActivate" : "Activate";
	sd_bus_call_method_async(tray_bus, NULL, item->name, item->path,
							 SNI_ITEM_IFACE, method, NULL, NULL, "ii", 0, 0);
	sd_bus_flush(tray_bus);
}

/* ---------------------------------------------------------------- bus */

static int tray_dispatch_ready(int fd, uint32_t mask, void *data) {
	(void)fd;
	(void)mask;
	(void)data;
	if (!tray_bus)
		return 0;

	while (true) {
		int r = sd_bus_process(tray_bus, NULL);
		if (r < 0) {
			/* connection broke: drop it, reconnect on the next tick */
			wl_event_source_remove(tray_fd_source);
			tray_fd_source = NULL;
			tray_bus = sd_bus_flush_close_unref(tray_bus);
			return 0;
		}
		if (r == 0)
			break;
	}
	sd_bus_flush(tray_bus);
	return 0;
}

void tray_reload(void) {
	if (tray_bus || !config.bar_enable)
		return;

	int r = sd_bus_default_user(&tray_bus);
	if (r < 0)
		r = sd_bus_default_system(&tray_bus);
	if (r < 0) {
		tray_bus = NULL;
		return;
	}

	(void)sd_bus_add_object_vtable(tray_bus, NULL, SNI_WATCHER_PATH,
								   SNI_WATCHER_IFACE, watcher_vtable, NULL);
	/* clients disagree on the canonical path: the SNI spec uses
	 * "/StatusNotifierWatcher", while many hosts sit at the freedesktop
	 * path. Export the same object at both so either style works. */
	(void)sd_bus_add_object_vtable(tray_bus, NULL, SNI_WATCHER_ALT_PATH,
								   SNI_WATCHER_IFACE, watcher_vtable, NULL);
	(void)sd_bus_request_name(tray_bus, SNI_WATCHER_NAME, 0);

	(void)sd_bus_match_signal(tray_bus, NULL, NULL, "/org/freedesktop/DBus",
							  "org.freedesktop.DBus", "NameOwnerChanged",
							  on_name_owner_changed, NULL);

	if (tray_fd_source) {
		wl_event_source_remove(tray_fd_source);
		tray_fd_source = NULL;
	}
	tray_fd_source =
		wl_event_loop_add_fd(server.event_loop, sd_bus_get_fd(tray_bus),
							 WL_EVENT_READABLE, tray_dispatch_ready, NULL);

	/* Drain the fresh connection (initial items, name responses). */
	tray_dispatch_ready(0, 0, NULL);
}

void tray_init(struct wl_event_loop *loop) {
	(void)loop;
	wl_list_init(&items);
	items_ready = true;
}

void tray_cleanup(void) {
	if (tray_fd_source) {
		wl_event_source_remove(tray_fd_source);
		tray_fd_source = NULL;
	}
	tray_bus = sd_bus_flush_close_unref(tray_bus);
	if (items_ready) {
		while (!wl_list_empty(&items)) {
			struct MangoTrayItem *item =
				wl_container_of(items.next, item, link);
			item_destroy(item);
		}
		items_ready = false;
	}
}

#else /* !HAVE_TRAY */

void tray_init(struct wl_event_loop *loop) { (void)loop; }
void tray_cleanup(void) {}
void tray_reload(void) {}
void tray_sync_bar(struct MangoBar *bar) { (void)bar; }
void tray_detach_bar(struct MangoBar *bar) { (void)bar; }
void tray_click(struct MangoTrayItem *item, uint32_t button) {
	(void)item;
	(void)button;
}

#endif
