/*
 * Stand-in for AOSP's hardware/gralloc.h: hwcomposer.h only needs the
 * buffer handle type from it, and the real header pulls in most of the
 * Android system headers. Android 6.0.1 definitions.
 */
#ifndef ANDROID_GRALLOC_INTERFACE_H
#define ANDROID_GRALLOC_INTERFACE_H

#include <cutils/native_handle.h>
#include <hardware/hardware.h>

typedef const native_handle_t *buffer_handle_t;

#endif
