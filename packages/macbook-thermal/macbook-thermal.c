/*
 * macbook-thermal — MacBook9,1 (m3-6Y30) fanless RAPL/EPP governor
 *
 * Hardware facts (verified 2026-10-13, kernel 6.18.55, SMC key walk of all
 * 701 entries): the 12" Retina MacBook 2016 has NO fan. The SMC exposes
 * exactly one F* key — FNum = 0 — and no F0Ac/F0Mn/F0Mx/F0Tg. The old
 * SMC I/O-port fan-control half of this daemon was dead weight and is
 * gone. What actually keeps this chassis alive is power:
 *
 *   - intel_rapl firmware advertises PL1/PL2 = 49 W on a 4.5 W part.
 *     Idle on `performance` → chassis thermal shutdown in ~20 minutes.
 *     Cap package power at 15/22 W (datasheet is 4.5/7 W — 15/22 still
 *     leaves the m3 usable instead of pinned at ~600 MHz, and is far
 *     below the 49 W firmware lie).
 *   - EPP `balance_performance` normally; drop to `power` and kill turbo
 *     when the package gets hot (no fan exists to carry heat away, so
 *     the throttle margin is all we have; TJmax is 100 C).
 *   - constraint_*_max_power_uw is READ-ONLY on this SKU (EROFS): every
 *     poll would spam "Permission denied" into the journal. Max-raise is
 *     attempted once at startup; after that we only rewrite the power
 *     limits when a read-back shows they drifted (firmware/p-d churn).
 */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#include <dirent.h>

/* Firmware advertises 49 W; datasheet is 4.5 W (cTDP-up 7 W). */
#define PL1_UW 15000000	 /* sustained cap */
#define PL2_UW 22000000	 /* short burst */
#define PL2_WINDOW_US 10000000 /* 10 s turbo window */
#define EPP_COOL "balance_performance"
#define EPP_HOT "power"

#define NO_TURBO_C 85 /* single hot threshold: no fan mitigation exists */
#define POLL_MS 1000

static volatile sig_atomic_t g_stop;
static char g_coretemp_input[512];

static void die_log(int pri, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vsyslog(pri, fmt, ap);
	va_end(ap);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
}

/* Log a given condition once — EROFS/ENOENT states do not improve by
 * repeating them once a second, but they do clutter a 50 MB journal. */
#define LOG_ONCE(pri, what, fmt, ...)                                          \
	do {                                                                   \
		static bool seen_##what;                                       \
		if (!seen_##what) {                                            \
			seen_##what = true;                                    \
			die_log(pri, fmt, ##__VA_ARGS__);                      \
		}                                                              \
	} while (0)

static void on_signal(int sig)
{
	(void)sig;
	g_stop = 1;
}

static void msleep(unsigned int ms)
{
	struct timespec ts = {
		.tv_sec = ms / 1000,
		.tv_nsec = (long)(ms % 1000) * 1000000L,
	};
	while (nanosleep(&ts, &ts) == -1 && errno == EINTR)
		;
}

static int write_sysfs(const char *path, const char *value)
{
	int fd = open(path, O_WRONLY | O_CLOEXEC);
	if (fd < 0)
		return -errno;
	size_t n = strlen(value);
	ssize_t w = write(fd, value, n);
	int err = (w < 0) ? -errno : 0;
	close(fd);
	if (w >= 0 && (size_t)w != n)
		return -EIO;
	return err;
}

static int read_sysfs_long(const char *path, long *out)
{
	char buf[64];
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -errno;
	ssize_t n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return n < 0 ? -errno : -EIO;
	buf[n] = '\0';
	char *end = NULL;
	long v = strtol(buf, &end, 10);
	if (end == buf)
		return -EINVAL;
	*out = v;
	return 0;
}

/* Set the same EPP on every core; missing files (1 cpufreq per cluster) are
 * expected on some kernels and are not interesting to log. */
static void apply_epp(const char *pref)
{
	DIR *d = opendir("/sys/devices/system/cpu");
	if (!d)
		return;
	struct dirent *de;
	while ((de = readdir(d))) {
		if (strncmp(de->d_name, "cpu", 3) != 0)
			continue;
		if (de->d_name[3] < '0' || de->d_name[3] > '9')
			continue;
		char path[512];
		if (snprintf(path, sizeof(path),
			     "/sys/devices/system/cpu/%s/cpufreq/energy_performance_preference",
			     de->d_name) >= (int)sizeof(path))
			continue;
		write_sysfs(path, pref);
	}
	closedir(d);
}

/* ---- coretemp ---------------------------------------------------------- */

static int find_coretemp(void)
{
	DIR *d = opendir("/sys/class/hwmon");
	if (!d)
		return -errno;
	struct dirent *de;
	int found = 0;
	while ((de = readdir(d))) {
		if (de->d_name[0] == '.')
			continue;
		char namep[512], name[64];
		if (snprintf(namep, sizeof(namep), "/sys/class/hwmon/%s/name", de->d_name) >=
		    (int)sizeof(namep))
			continue;
		int fd = open(namep, O_RDONLY | O_CLOEXEC);
		if (fd < 0)
			continue;
		ssize_t n = read(fd, name, sizeof(name) - 1);
		close(fd);
		if (n <= 0)
			continue;
		name[n] = '\0';
		if (strncmp(name, "coretemp", 8) != 0)
			continue;
		if (snprintf(g_coretemp_input, sizeof(g_coretemp_input),
			     "/sys/class/hwmon/%s/temp1_input", de->d_name) >=
		    (int)sizeof(g_coretemp_input))
			continue;
		found = 1;
		break;
	}
	closedir(d);
	return found ? 0 : -ENOENT;
}

static int package_temp_c(void)
{
	long mdeg = 0;
	if (!g_coretemp_input[0] && find_coretemp() != 0)
		return -1;
	if (read_sysfs_long(g_coretemp_input, &mdeg) != 0)
		return -1;
	return (int)(mdeg / 1000);
}

/* ---- RAPL -------------------------------------------------------------- */

static void apply_rapl_max_once(void)
{
	/* Some SKU trees refuse (EROFS) a limit above max, and max itself is
	 * read-only here; raising max is best-effort, exactly once. */
	write_sysfs("/sys/class/powercap/intel-rapl:0/constraint_0_max_power_uw",
		    "15000000");
	write_sysfs("/sys/class/powercap/intel-rapl:0/constraint_1_max_power_uw",
		    "22000000");
}

/* Reapply the caps only when the live values drifted — firmware and
 * power-profiles-daemon both rewrite these, and rewriting per-second for
 * no reason burned CPU + journal space for ~zero effect. */
static void apply_rapl_if_drifted(void)
{
	static const char *const pl1 =
		"/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw";
	static const char *const pl2 =
		"/sys/class/powercap/intel-rapl:0/constraint_1_power_limit_uw";
	static const char *const pl2w =
		"/sys/class/powercap/intel-rapl:0/constraint_1_time_window_us";
	static const char *const en =
		"/sys/class/powercap/intel-rapl:0/enabled";

	long v = 0;
	if (read_sysfs_long(en, &v) == 0 && v != 1) {
		int r = write_sysfs(en, "1");
		if (r)
			LOG_ONCE(LOG_WARNING, rapl_en,
				 "rapl enable: %s", strerror(-r));
	}

	v = 0;
	if (read_sysfs_long(pl1, &v) != 0 || v != PL1_UW) {
		char buf[32];
		snprintf(buf, sizeof(buf), "%d", PL1_UW);
		int r = write_sysfs(pl1, buf);
		if (r)
			LOG_ONCE(LOG_ERR, pl1, "PL1 write: %s", strerror(-r));
		if (!r) {
			long rb = 0;
			if (read_sysfs_long(pl1, &rb) == 0 && rb != PL1_UW)
				LOG_ONCE(LOG_WARNING, pl1_rb,
					 "PL1 read-back = %ld (wanted %d)",
					 rb, PL1_UW);
		}
	}

	v = 0;
	if (read_sysfs_long(pl2, &v) != 0 || v != PL2_UW) {
		char buf[32];
		snprintf(buf, sizeof(buf), "%d", PL2_UW);
		int r = write_sysfs(pl2, buf);
		if (r)
			LOG_ONCE(LOG_WARNING, pl2, "PL2 write: %s", strerror(-r));
	}

	v = 0;
	if (read_sysfs_long(pl2w, &v) != 0 || v != PL2_WINDOW_US) {
		char buf[32];
		snprintf(buf, sizeof(buf), "%d", PL2_WINDOW_US);
		int r = write_sysfs(pl2w, buf);
		if (r)
			LOG_ONCE(LOG_WARNING, pl2w_op,
				 "PL2 window write: %s", strerror(-r));
	}
}

static void apply_no_turbo(int on)
{
	static int last = -1;
	if (on == last)
		return;
	int r = write_sysfs("/sys/devices/system/cpu/intel_pstate/no_turbo",
			    on ? "1" : "0");
	if (r)
		LOG_ONCE(LOG_WARNING, noturbo, "no_turbo write: %s",
			 strerror(-r));
	else
		last = on;
}

int main(void)
{
	openlog("macbook-thermal", LOG_PID | LOG_PERROR, LOG_DAEMON);
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);

	apply_rapl_max_once();
	apply_rapl_if_drifted();
	apply_no_turbo(0);
	apply_epp(EPP_COOL);

	die_log(LOG_INFO,
		"fanless governor ready: RAPL PL1=%d mW PL2=%d mW, EPP=%s",
		PL1_UW / 1000, PL2_UW / 1000, EPP_COOL);

	int last_logged = -100;
	int epp_hot = 0;
	while (!g_stop) {
		int c = package_temp_c();
		if (c < 0) {
			find_coretemp();
			msleep(POLL_MS);
			continue;
		}

		apply_rapl_if_drifted();

		int want_hot = c >= NO_TURBO_C;
		if (want_hot != epp_hot) {
			apply_no_turbo(want_hot);
			apply_epp(want_hot ? EPP_HOT : EPP_COOL);
			epp_hot = want_hot;
			die_log(want_hot ? LOG_WARNING : LOG_INFO,
				"pkg %d C -> %s",
				c, want_hot ? "no_turbo + EPP power" : "EPP balance_performance");
		}

		if (abs(c - last_logged) >= 2) {
			die_log(LOG_INFO, "pkg %d C", c);
			last_logged = c;
		}
		msleep(POLL_MS);
	}

	die_log(LOG_INFO, "stopped");
	closelog();
	return 0;
}
