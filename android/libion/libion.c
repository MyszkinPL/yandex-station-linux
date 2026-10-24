// SPDX-License-Identifier: Apache-2.0
/*
 * libion for the Android 6 vendor userspace of the Yandex Station 1 on a
 * mainline kernel: the same entry points as the vendor libion.so, backed by
 * DMA-BUF heaps (/dev/dma_heap/system), the interface Android itself moved
 * to when ION left the kernel. Installed in place of /system/lib{,64}/libion.so
 * by the Android-mode ramdisk (bind mount), nothing on /system changes.
 *
 * "Handles" are small integers local to the process, each owning one dma-buf
 * fd; share/map hand out duplicates of that fd. Heaps: the vendor gralloc
 * asks for its contiguous heaps (masks 0x2 and 0x10) for buffers the display
 * scans out (GRALLOC_USAGE_HW_FB), which the display engine, having no IOMMU,
 * needs physically contiguous: those come from the CMA heap. Everything else
 * (textures, layers: the GPU has its own MMU) comes from the system heap.
 */
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <linux/dma-buf.h>
#include <linux/dma-heap.h>

typedef int ion_user_handle_t;

#define MAX_HANDLES 4096

/* vendor ION heap masks that mean "physically contiguous" */
#define ION_CONTIG_HEAPS 0x12

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int handle_fd[MAX_HANDLES];	/* 0 = free, else dma-buf fd + 1 */
static int cma_fd = -2;			/* -2: not looked for yet, -1: no CMA heap */

/* the CMA heap; its name follows the kernel's CMA area */
static int cma_heap(void)
{
	static const char *const names[] = {
		"/dev/dma_heap/linux,cma", "/dev/dma_heap/default_cma_region", "/dev/dma_heap/reserved",
	};

	pthread_mutex_lock(&lock);
	for (unsigned int i = 0; cma_fd == -2 && i < sizeof(names) / sizeof(names[0]); i++) {
		int fd = open(names[i], O_RDONLY | O_CLOEXEC);

		if (fd >= 0)
			cma_fd = fd;
	}
	if (cma_fd == -2)
		cma_fd = -1;
	pthread_mutex_unlock(&lock);
	return cma_fd;
}

static int heap_open(void)
{
	int fd = open("/dev/dma_heap/system", O_RDONLY | O_CLOEXEC);

	return fd < 0 ? -errno : fd;
}

static int handle_new(int buf_fd)
{
	int h;

	pthread_mutex_lock(&lock);
	for (h = 1; h < MAX_HANDLES; h++) {
		if (!handle_fd[h]) {
			handle_fd[h] = buf_fd + 1;
			pthread_mutex_unlock(&lock);
			return h;
		}
	}
	pthread_mutex_unlock(&lock);
	return -ENOMEM;
}

static int handle_get(ion_user_handle_t h)
{
	int fd = -EINVAL;

	if (h <= 0 || h >= MAX_HANDLES)
		return -EINVAL;
	pthread_mutex_lock(&lock);
	if (handle_fd[h])
		fd = handle_fd[h] - 1;
	pthread_mutex_unlock(&lock);
	return fd;
}

int ion_open(void)
{
	return heap_open();
}

int ion_close(int fd)
{
	return close(fd) ? -errno : 0;
}

int ion_alloc_fd(int fd, size_t len, size_t align, unsigned int heap_mask,
		 unsigned int flags, int *handle_fd_out)
{
	struct dma_heap_allocation_data data = {
		.len = len,
		.fd_flags = O_RDWR | O_CLOEXEC,
	};

	(void)align;
	(void)flags;
	if (!handle_fd_out || !len)
		return -EINVAL;
	/* scanout buffers from CMA; the system heap when there is no CMA heap */
	if ((heap_mask & ION_CONTIG_HEAPS) && cma_heap() >= 0 &&
	    ioctl(cma_heap(), DMA_HEAP_IOCTL_ALLOC, &data) == 0) {
		*handle_fd_out = data.fd;
		return 0;
	}
	if (ioctl(fd, DMA_HEAP_IOCTL_ALLOC, &data) < 0)
		return -errno;
	*handle_fd_out = data.fd;
	return 0;
}

int ion_alloc(int fd, size_t len, size_t align, unsigned int heap_mask,
	      unsigned int flags, ion_user_handle_t *handle)
{
	int buf_fd, h, ret;

	if (!handle)
		return -EINVAL;
	ret = ion_alloc_fd(fd, len, align, heap_mask, flags, &buf_fd);
	if (ret)
		return ret;
	h = handle_new(buf_fd);
	if (h < 0) {
		close(buf_fd);
		return h;
	}
	*handle = h;
	return 0;
}

int ion_free(int fd, ion_user_handle_t handle)
{
	int buf_fd;

	(void)fd;
	if (handle <= 0 || handle >= MAX_HANDLES)
		return -EINVAL;
	pthread_mutex_lock(&lock);
	buf_fd = handle_fd[handle] - 1;
	handle_fd[handle] = 0;
	pthread_mutex_unlock(&lock);
	if (buf_fd < 0)
		return -EINVAL;
	close(buf_fd);
	return 0;
}

int ion_share(int fd, ion_user_handle_t handle, int *share_fd)
{
	int buf_fd = handle_get(handle);

	(void)fd;
	if (buf_fd < 0)
		return buf_fd;
	if (!share_fd)
		return -EINVAL;
	*share_fd = fcntl(buf_fd, F_DUPFD_CLOEXEC, 0);
	return *share_fd < 0 ? -errno : 0;
}

int ion_map(int fd, ion_user_handle_t handle, size_t length, int prot,
	    int flags, off_t offset, unsigned char **ptr, int *map_fd)
{
	int ret, mfd;
	void *p;

	if (!ptr || !map_fd || !length)
		return -EINVAL;
	ret = ion_share(fd, handle, &mfd);
	if (ret)
		return ret;
	p = mmap(NULL, length, prot, flags, mfd, offset);
	if (p == MAP_FAILED) {
		ret = -errno;
		close(mfd);
		return ret;
	}
	*ptr = p;
	*map_fd = mfd;
	return 0;
}

int ion_import(int fd, int share_fd, ion_user_handle_t *handle)
{
	int buf_fd, h;

	(void)fd;
	if (!handle)
		return -EINVAL;
	buf_fd = fcntl(share_fd, F_DUPFD_CLOEXEC, 0);
	if (buf_fd < 0)
		return -errno;
	h = handle_new(buf_fd);
	if (h < 0) {
		close(buf_fd);
		return h;
	}
	*handle = h;
	return 0;
}

/* CPU caches to memory, so the GPU sees what the CPU wrote */
int ion_sync_fd(int fd, int handle_fd_arg)
{
	struct dma_buf_sync sync = { .flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW };

	(void)fd;
	if (ioctl(handle_fd_arg, DMA_BUF_IOCTL_SYNC, &sync) < 0)
		return -errno;
	sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW;
	if (ioctl(handle_fd_arg, DMA_BUF_IOCTL_SYNC, &sync) < 0)
		return -errno;
	return 0;
}

/*
 * Allwinner extension: the physical address of a contiguous buffer, for
 * hardware without an MMU (display engine, video decoder). System heap
 * buffers have none; 0 tells the caller there is no such address.
 */
unsigned int ion_getphyadr(int fd, ion_user_handle_t handle)
{
	(void)fd;
	(void)handle;
	return 0;
}
