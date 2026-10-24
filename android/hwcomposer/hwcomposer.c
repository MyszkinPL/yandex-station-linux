// SPDX-License-Identifier: Apache-2.0
/*
 * Hardware composer for the Android 6 userspace of the Yandex Station 1 on a
 * mainline kernel: HWC 1.1 over DRM/KMS, in place of the vendor
 * hwcomposer.tulip (which drives the Allwinner display driver, /dev/disp).
 *
 * SurfaceFlinger composes every layer with the GPU into the framebuffer
 * target; this module puts that buffer on the display. The target is a
 * dma-buf from gralloc (ION, which android/libion serves from DMA-BUF
 * heaps); it is imported with PRIME, wrapped into a KMS framebuffer and
 * flipped to, waiting for the flip before set() returns so the previous
 * buffer is off screen when SurfaceFlinger takes it back. Vsync comes from
 * DRM vblank events, or from a timer when no display is connected.
 *
 * The gralloc buffer handle is the ARM Utgard private_handle_t (one fd,
 * then magic, flags, usage, size, width, height, format, stride in pixels).
 */
#define LOG_TAG "hwc-drm"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <android/log.h>
#include <drm/drm.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_mode.h>
#include <hardware/hwcomposer.h>

#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define ALOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* ARM Utgard gralloc buffer handle, as the vendor gralloc.default.so lays it out */
struct gralloc_handle {
	native_handle_t base;		/* version, numFds = 1, numInts */
	int share_fd;
	int magic;
	int flags;
	int usage;
	int size;
	int width;
	int height;
	int format;
	int stride;			/* pixels */
};
#define GRALLOC_MAGIC 0x3141592

#define NUM_FBS 4			/* SurfaceFlinger keeps 3 framebuffer targets */

struct fb_cache {
	ino_t ino;			/* the dma-buf, by inode */
	uint32_t gem, fb;
	unsigned int used;
};

struct hwc_ctx {
	hwc_composer_device_1_t device;
	const hwc_procs_t *procs;

	int drm;
	uint32_t crtc, connector;
	struct drm_mode_modeinfo mode;
	int have_display;
	int mode_set;
	unsigned int tick;
	struct fb_cache fbs[NUM_FBS];

	pthread_t vsync_thread;
	pthread_mutex_t lock;
	pthread_cond_t cond;
	int vsync_on;
	int stop;
};

static int drm_ioctl(int fd, unsigned long req, void *arg)
{
	int r;

	do {
		r = ioctl(fd, req, arg);
	} while (r == -1 && (errno == EINTR || errno == EAGAIN));
	return r;
}

static uint32_t drm_format(int hal)
{
	switch (hal) {
	case HAL_PIXEL_FORMAT_RGBA_8888: return DRM_FORMAT_ABGR8888;
	case HAL_PIXEL_FORMAT_RGBX_8888: return DRM_FORMAT_XBGR8888;
	case HAL_PIXEL_FORMAT_BGRA_8888: return DRM_FORMAT_ARGB8888;
	case HAL_PIXEL_FORMAT_RGB_565:   return DRM_FORMAT_RGB565;
	default:                         return 0;
	}
}

/* the first connected connector, its preferred mode and a CRTC for it */
static int find_display(struct hwc_ctx *c)
{
	struct drm_mode_card_res res = { 0 };
	uint32_t *conns = NULL, *crtcs = NULL, *encs = NULL;
	int ok = 0;

	if (drm_ioctl(c->drm, DRM_IOCTL_MODE_GETRESOURCES, &res))
		return 0;
	conns = calloc(res.count_connectors + 1, sizeof(*conns));
	crtcs = calloc(res.count_crtcs + 1, sizeof(*crtcs));
	encs = calloc(res.count_encoders + 1, sizeof(*encs));
	res.connector_id_ptr = (uintptr_t)conns;
	res.crtc_id_ptr = (uintptr_t)crtcs;
	res.encoder_id_ptr = (uintptr_t)encs;
	res.count_fbs = 0;
	if (drm_ioctl(c->drm, DRM_IOCTL_MODE_GETRESOURCES, &res))
		goto out;

	for (uint32_t i = 0; i < res.count_connectors && !ok; i++) {
		struct drm_mode_get_connector conn = { .connector_id = conns[i] };
		struct drm_mode_modeinfo *modes;
		uint32_t *conn_encs;

		if (drm_ioctl(c->drm, DRM_IOCTL_MODE_GETCONNECTOR, &conn) || conn.connection != 1 ||
		    !conn.count_modes)
			continue;
		modes = calloc(conn.count_modes, sizeof(*modes));
		conn_encs = calloc(conn.count_encoders + 1, sizeof(*conn_encs));
		conn.modes_ptr = (uintptr_t)modes;
		conn.encoders_ptr = (uintptr_t)conn_encs;
		conn.count_props = 0;
		if (!drm_ioctl(c->drm, DRM_IOCTL_MODE_GETCONNECTOR, &conn) && conn.count_modes) {
			uint32_t m = 0;

			for (uint32_t k = 0; k < conn.count_modes; k++)
				if (modes[k].type & DRM_MODE_TYPE_PREFERRED) {
					m = k;
					break;
				}
			for (uint32_t e = 0; e < conn.count_encoders && !ok; e++) {
				struct drm_mode_get_encoder enc = { .encoder_id = conn_encs[e] };

				if (drm_ioctl(c->drm, DRM_IOCTL_MODE_GETENCODER, &enc))
					continue;
				for (uint32_t k = 0; k < res.count_crtcs; k++)
					if (enc.possible_crtcs & (1u << k)) {
						c->crtc = crtcs[k];
						c->connector = conns[i];
						c->mode = modes[m];
						ok = 1;
						break;
					}
			}
		}
		free(modes);
		free(conn_encs);
	}
out:
	free(conns);
	free(crtcs);
	free(encs);
	return ok;
}

static void fb_drop(struct hwc_ctx *c, struct fb_cache *f)
{
	struct drm_gem_close gc = { .handle = f->gem };

	if (f->fb)
		drm_ioctl(c->drm, DRM_IOCTL_MODE_RMFB, &f->fb);
	if (f->gem)
		drm_ioctl(c->drm, DRM_IOCTL_GEM_CLOSE, &gc);
	memset(f, 0, sizeof(*f));
}

/* KMS framebuffer for a gralloc buffer, imported once and cached */
static uint32_t fb_for(struct hwc_ctx *c, buffer_handle_t handle)
{
	const struct gralloc_handle *h = (const struct gralloc_handle *)handle;
	struct drm_prime_handle prime = { 0 };
	struct drm_mode_fb_cmd2 cmd = { 0 };
	struct fb_cache *f, *victim = &c->fbs[0];
	struct stat st;

	if (!h || h->base.numFds < 1 || h->magic != GRALLOC_MAGIC || fstat(h->share_fd, &st)) {
		ALOGE("not a gralloc buffer handle");
		return 0;
	}
	c->tick++;
	for (f = c->fbs; f < c->fbs + NUM_FBS; f++) {
		if (f->fb && f->ino == st.st_ino) {
			f->used = c->tick;
			return f->fb;
		}
		if (f->used < victim->used)
			victim = f;
	}

	fb_drop(c, victim);
	cmd.pixel_format = drm_format(h->format);
	if (!cmd.pixel_format) {
		ALOGE("buffer format %d has no KMS equivalent", h->format);
		return 0;
	}
	prime.fd = h->share_fd;
	if (drm_ioctl(c->drm, DRM_IOCTL_PRIME_FD_TO_HANDLE, &prime)) {
		ALOGE("PRIME import of %dx%d buffer failed: %s (not physically contiguous?)",
		      h->width, h->height, strerror(errno));
		return 0;
	}
	cmd.width = h->width;
	cmd.height = h->height;
	cmd.handles[0] = prime.handle;
	cmd.pitches[0] = h->stride * (cmd.pixel_format == DRM_FORMAT_RGB565 ? 2 : 4);
	if (drm_ioctl(c->drm, DRM_IOCTL_MODE_ADDFB2, &cmd)) {
		struct drm_gem_close gc = { .handle = prime.handle };

		ALOGE("ADDFB2 %dx%d pitch %u format %d failed: %s", h->width, h->height,
		      cmd.pitches[0], h->format, strerror(errno));
		drm_ioctl(c->drm, DRM_IOCTL_GEM_CLOSE, &gc);
		return 0;
	}
	victim->ino = st.st_ino;
	victim->gem = prime.handle;
	victim->fb = cmd.fb_id;
	victim->used = c->tick;
	ALOGI("imported %dx%d format %d stride %d as fb %u", h->width, h->height, h->format,
	      h->stride, cmd.fb_id);
	return cmd.fb_id;
}

static int show(struct hwc_ctx *c, uint32_t fb)
{
	if (!c->mode_set) {
		struct drm_mode_crtc crtc = {
			.crtc_id = c->crtc,
			.fb_id = fb,
			.set_connectors_ptr = (uintptr_t)&c->connector,
			.count_connectors = 1,
			.mode = c->mode,
			.mode_valid = 1,
		};

		if (drm_ioctl(c->drm, DRM_IOCTL_MODE_SETCRTC, &crtc)) {
			ALOGE("SETCRTC %s failed: %s", c->mode.name, strerror(errno));
			return -errno;
		}
		c->mode_set = 1;
		ALOGI("display on: %s, crtc %u, connector %u", c->mode.name, c->crtc, c->connector);
		return 0;
	}

	struct drm_mode_crtc_page_flip flip = {
		.crtc_id = c->crtc,
		.fb_id = fb,
		.flags = DRM_MODE_PAGE_FLIP_EVENT,
	};
	char ev[1024];
	struct pollfd p = { .fd = c->drm, .events = POLLIN };

	if (drm_ioctl(c->drm, DRM_IOCTL_MODE_PAGE_FLIP, &flip)) {
		ALOGW("page flip failed (%s), setting the CRTC", strerror(errno));
		c->mode_set = 0;
		return show(c, fb);
	}
	/* the old buffer is off screen once the flip event is in */
	if (poll(&p, 1, 100) == 1)
		(void)read(c->drm, ev, sizeof(ev));
	return 0;
}

static void close_fences(hwc_display_contents_1_t *d)
{
	for (size_t i = 0; i < d->numHwLayers; i++) {
		hwc_layer_1_t *l = &d->hwLayers[i];

		if (l->acquireFenceFd >= 0)
			close(l->acquireFenceFd);
		l->acquireFenceFd = -1;
		l->releaseFenceFd = -1;
	}
	if (d->outbufAcquireFenceFd >= 0)
		close(d->outbufAcquireFenceFd);
	d->outbufAcquireFenceFd = -1;
	d->retireFenceFd = -1;
}

static int hwc_prepare(hwc_composer_device_1_t *dev, size_t num, hwc_display_contents_1_t **displays)
{
	(void)dev;
	for (size_t d = 0; d < num; d++) {
		if (!displays[d])
			continue;
		for (size_t i = 0; i < displays[d]->numHwLayers; i++) {
			hwc_layer_1_t *l = &displays[d]->hwLayers[i];

			if (l->compositionType != HWC_FRAMEBUFFER_TARGET)
				l->compositionType = HWC_FRAMEBUFFER;
		}
	}
	return 0;
}

static int hwc_set(hwc_composer_device_1_t *dev, size_t num, hwc_display_contents_1_t **displays)
{
	struct hwc_ctx *c = (struct hwc_ctx *)dev;
	int ret = 0;

	for (size_t d = 0; d < num; d++) {
		hwc_display_contents_1_t *disp = displays[d];
		hwc_layer_1_t *target = NULL;

		if (!disp)
			continue;
		if (d == HWC_DISPLAY_PRIMARY) {
			for (size_t i = 0; i < disp->numHwLayers; i++)
				if (disp->hwLayers[i].compositionType == HWC_FRAMEBUFFER_TARGET)
					target = &disp->hwLayers[i];
		}
		if (target && target->handle && c->have_display) {
			uint32_t fb;

			if (target->acquireFenceFd >= 0) {
				struct pollfd p = { .fd = target->acquireFenceFd, .events = POLLIN };

				if (poll(&p, 1, 3000) != 1)
					ALOGW("GPU fence not signalled in 3 s");
			}
			fb = fb_for(c, target->handle);
			if (fb)
				ret = show(c, fb);
		}
		close_fences(disp);
	}
	return ret;
}

static void *vsync_loop(void *arg)
{
	struct hwc_ctx *c = arg;
	int64_t period = 16666667;

	if (c->have_display && c->mode.htotal && c->mode.vtotal)
		period = (int64_t)c->mode.htotal * c->mode.vtotal * 1000000 / c->mode.clock;

	for (;;) {
		int64_t ts;

		pthread_mutex_lock(&c->lock);
		while (!c->vsync_on && !c->stop)
			pthread_cond_wait(&c->cond, &c->lock);
		pthread_mutex_unlock(&c->lock);
		if (c->stop)
			break;

		union drm_wait_vblank vb = { .request = { .type = _DRM_VBLANK_RELATIVE, .sequence = 1 } };

		if (c->have_display && !drm_ioctl(c->drm, DRM_IOCTL_WAIT_VBLANK, &vb)) {
			ts = (int64_t)vb.reply.tval_sec * 1000000000 + (int64_t)vb.reply.tval_usec * 1000;
		} else {
			/* no display (or no vblank yet): a steady software beat */
			struct timespec now;

			clock_gettime(CLOCK_MONOTONIC, &now);
			ts = (int64_t)now.tv_sec * 1000000000 + now.tv_nsec;
			ts += period - ts % period;
			struct timespec at = { .tv_sec = ts / 1000000000, .tv_nsec = ts % 1000000000 };
			clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &at, NULL);
		}
		if (c->procs && c->procs->vsync)
			c->procs->vsync(c->procs, HWC_DISPLAY_PRIMARY, ts);
	}
	return NULL;
}

static int hwc_event_control(hwc_composer_device_1_t *dev, int disp, int event, int enabled)
{
	struct hwc_ctx *c = (struct hwc_ctx *)dev;

	if (disp != HWC_DISPLAY_PRIMARY || event != HWC_EVENT_VSYNC)
		return -EINVAL;
	pthread_mutex_lock(&c->lock);
	c->vsync_on = !!enabled;
	pthread_cond_signal(&c->cond);
	pthread_mutex_unlock(&c->lock);
	return 0;
}

static int hwc_blank(hwc_composer_device_1_t *dev, int disp, int blank)
{
	struct hwc_ctx *c = (struct hwc_ctx *)dev;

	if (disp != HWC_DISPLAY_PRIMARY)
		return -EINVAL;
	if (blank && c->have_display && c->mode_set) {
		struct drm_mode_crtc crtc = { .crtc_id = c->crtc };

		drm_ioctl(c->drm, DRM_IOCTL_MODE_SETCRTC, &crtc);
	}
	c->mode_set = 0;	/* the next frame sets the mode again */
	return 0;
}

static int hwc_query(hwc_composer_device_1_t *dev, int what, int *value)
{
	struct hwc_ctx *c = (struct hwc_ctx *)dev;

	switch (what) {
	case HWC_BACKGROUND_LAYER_SUPPORTED:
		*value = 0;
		return 0;
	case HWC_VSYNC_PERIOD:
		*value = c->have_display && c->mode.clock ?
			(int)((int64_t)c->mode.htotal * c->mode.vtotal * 1000000 / c->mode.clock) : 16666667;
		return 0;
	case HWC_DISPLAY_TYPES_SUPPORTED:
		*value = HWC_DISPLAY_PRIMARY_BIT;
		return 0;
	default:
		return -EINVAL;
	}
}

static void hwc_register_procs(hwc_composer_device_1_t *dev, hwc_procs_t const *procs)
{
	((struct hwc_ctx *)dev)->procs = procs;
}

static int hwc_get_display_configs(hwc_composer_device_1_t *dev, int disp, uint32_t *configs, size_t *num)
{
	(void)dev;
	if (disp != HWC_DISPLAY_PRIMARY)
		return -EINVAL;
	if (*num > 0)
		configs[0] = 0;
	*num = 1;
	return 0;
}

static int hwc_get_display_attributes(hwc_composer_device_1_t *dev, int disp, uint32_t config,
				      const uint32_t *attributes, int32_t *values)
{
	struct hwc_ctx *c = (struct hwc_ctx *)dev;
	int w = c->have_display ? c->mode.hdisplay : 1920;
	int h = c->have_display ? c->mode.vdisplay : 1080;

	if (disp != HWC_DISPLAY_PRIMARY || config != 0)
		return -EINVAL;
	for (int i = 0; attributes[i] != HWC_DISPLAY_NO_ATTRIBUTE; i++) {
		switch (attributes[i]) {
		case HWC_DISPLAY_VSYNC_PERIOD:
			hwc_query(dev, HWC_VSYNC_PERIOD, &values[i]);
			break;
		case HWC_DISPLAY_WIDTH:
			values[i] = w;
			break;
		case HWC_DISPLAY_HEIGHT:
			values[i] = h;
			break;
		case HWC_DISPLAY_DPI_X:
		case HWC_DISPLAY_DPI_Y:
			values[i] = 160000;	/* a TV: the density comes from ro.sf.lcd_density */
			break;
		default:
			values[i] = 0;
			break;
		}
	}
	return 0;
}

/*
 * The vendor SurfaceFlinger (Allwinner) calls reserved_proc[0] as
 * setParameter(dev, cmd, disp, para0, para1), without a NULL check: output
 * mode, margins, 3D and picture enhancement of the Allwinner display driver.
 * DRM has no such driver; accept them, as the vendor hwcomposer does with
 * the commands it does not know.
 */
static int hwc_set_parameter(hwc_composer_device_1_t *dev, int cmd, int disp, int para0, int para1)
{
	(void)dev;
	ALOGI("display parameter %d (%d, %d, %d) ignored", cmd, disp, para0, para1);
	return 0;
}

static void hwc_dump(hwc_composer_device_1_t *dev, char *buff, int len)
{
	struct hwc_ctx *c = (struct hwc_ctx *)dev;

	snprintf(buff, len, "hwc-drm: %s, %s, crtc %u, connector %u, vsync %s\n",
		 c->have_display ? c->mode.name : "no display", c->mode_set ? "on" : "off",
		 c->crtc, c->connector, c->vsync_on ? "on" : "off");
}

static int hwc_device_close(hw_device_t *dev)
{
	struct hwc_ctx *c = (struct hwc_ctx *)dev;

	pthread_mutex_lock(&c->lock);
	c->stop = 1;
	pthread_cond_signal(&c->cond);
	pthread_mutex_unlock(&c->lock);
	pthread_join(c->vsync_thread, NULL);
	for (int i = 0; i < NUM_FBS; i++)
		fb_drop(c, &c->fbs[i]);
	if (c->drm >= 0)
		close(c->drm);
	free(c);
	return 0;
}

static int hwc_device_open(const hw_module_t *module, const char *name, hw_device_t **device)
{
	struct hwc_ctx *c;

	if (strcmp(name, HWC_HARDWARE_COMPOSER))
		return -EINVAL;
	c = calloc(1, sizeof(*c));
	if (!c)
		return -ENOMEM;

	c->drm = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (c->drm < 0)
		ALOGE("/dev/dri/card0: %s", strerror(errno));
	else
		c->have_display = find_display(c);
	if (c->have_display)
		ALOGI("display %s %dx%d@%d on crtc %u", c->mode.name, c->mode.hdisplay,
		      c->mode.vdisplay, c->mode.vrefresh, c->crtc);
	else
		ALOGW("no connected display: frames are dropped, vsync from a timer");

	pthread_mutex_init(&c->lock, NULL);
	pthread_cond_init(&c->cond, NULL);
	if (pthread_create(&c->vsync_thread, NULL, vsync_loop, c)) {
		if (c->drm >= 0)
			close(c->drm);
		free(c);
		return -ENOMEM;
	}

	c->device.common.tag = HARDWARE_DEVICE_TAG;
	c->device.common.version = HWC_DEVICE_API_VERSION_1_1;
	c->device.common.module = (hw_module_t *)module;
	c->device.common.close = hwc_device_close;
	c->device.prepare = hwc_prepare;
	c->device.set = hwc_set;
	c->device.eventControl = hwc_event_control;
	c->device.blank = hwc_blank;
	c->device.query = hwc_query;
	c->device.registerProcs = hwc_register_procs;
	c->device.dump = hwc_dump;
	c->device.getDisplayConfigs = hwc_get_display_configs;
	c->device.getDisplayAttributes = hwc_get_display_attributes;
	c->device.reserved_proc[0] = (void *)hwc_set_parameter;
	*device = &c->device.common;
	return 0;
}

static struct hw_module_methods_t hwc_module_methods = {
	.open = hwc_device_open,
};

__attribute__((visibility("default")))
hwc_module_t HAL_MODULE_INFO_SYM = {
	.common = {
		.tag = HARDWARE_MODULE_TAG,
		.module_api_version = HWC_MODULE_API_VERSION_0_1,
		.hal_api_version = HARDWARE_HAL_API_VERSION,
		.id = HWC_HARDWARE_MODULE_ID,
		.name = "DRM/KMS hardware composer (Yandex Station mainline)",
		.author = "yandex-station-linux",
		.methods = &hwc_module_methods,
	},
};
