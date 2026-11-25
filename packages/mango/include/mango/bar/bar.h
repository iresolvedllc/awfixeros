#ifndef __MANGO_BAR_BAR_H__
#define __MANGO_BAR_BAR_H__

#include "mango/common/types.h"
#include <stdbool.h>
#include <stdint.h>
#if defined(__has_include) && __has_include(<scenefx/types/wlr_scene.h>)
#include <scenefx/types/wlr_scene.h>
#else
#include <wlr/types/wlr_scene.h>
#endif

/*
 * Built-in floating status bar (off by default, see bar_enable).
 *
 * One bar per monitor, rendered in-process as scene nodes. Widgets:
 * tag buttons (left), tray icons, battery and clock (right). Clicking a button
 * is routed like any other scene node: a payload with type BarNodeType* and
 * owner BarButton is attached to the button's node.
 *
 * BarNodeType* values live in their own range so they can never collide with
 * the Client/LayerSurface kinds stored in MangoSceneNode::type.
 */
enum {
	BarNodeTypeTag = 0x42415200, /* "BAR\0" */
	BarNodeTypeSpecial = 0x42415201,
	BarNodeTypeTray = 0x42415202,
};

typedef struct BarButton BarButton;

/* Kinds of clickable buttons owned by the bar. Tag buttons share one payload
 * each; tray buttons are payload-attached scene buffers. */
struct BarButton {
	uint32_t type; /* BarNodeType* */
	int32_t tag;   /* BarNodeTypeTag/Special: tag index (0 = special) */
	void *item;	   /* BarNodeTypeTray: struct MangoTrayItem* */
};

typedef struct BarTrayIcon {
	BarButton btn;
	struct MangoTrayItem *item;
	struct wlr_scene_buffer *node;
} BarTrayIcon;

struct MangoBar {
	Monitor *mon;
	struct wlr_scene_tree *tree; /* server.layers[LyrBar] child */
	struct wlr_scene_rect *bg;

	/* tag_num + 1 buttons; the last one is the special-workspace button */
	MangoJumpLabel **tags;
	BarButton *tag_btns;
	int32_t tag_count;

	MangoJumpLabel *battery;
	MangoJumpLabel *clock;

	BarTrayIcon *tray_icons;
	int32_t tray_icon_count;
	int32_t tray_icon_capacity;
};

/* Lifecycle */
void bar_init(struct wl_event_loop *loop);
void bar_cleanup(void);
void bar_monitor_create(Monitor *m);
void bar_monitor_destroy(Monitor *m);
/* Recreates the bars of every monitor from the current config; also updates
 * the reservation strips (call arrange_layers() afterwards internally). */
void bar_config_reload(void);

/* Status / refresh */
void bar_update_status(void); /* clock + battery labels of all bars */
void bar_refresh_tags(void);  /* tag buttons of all bars */
void bar_update_lock(void);	  /* enable/disable bars for session locks */

/* Input (consumes clicks inside the bar strip) */
bool bar_handle_button_press(double x, double y, uint32_t button);

/* Usable-area reservation; call before arrange_layers() applies exclusives. */
int32_t bar_strip_height(void);

/* Positions/resizes one bar to its monitor's current geometry (cheap: no work
 * when the geometry is unchanged). Called from arrange_layers(). */
void bar_monitor_layout(Monitor *m);

/* Tray integration (implemented in tray.c; no-ops without libsystemd) */
struct MangoTrayItem;
void tray_init(struct wl_event_loop *loop);
void tray_cleanup(void);
void tray_reload(void);
void tray_sync_bar(struct MangoBar *bar);
void tray_detach_bar(struct MangoBar *bar);
void tray_click(struct MangoTrayItem *item, uint32_t button);

/* Called by tray.c whenever the item set changed: re-creates the icon nodes of
 * every live bar and re-runs the bar layout. */
void bar_tray_sync_all(void);

#endif
