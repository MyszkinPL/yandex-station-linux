Заголовки HAL из AOSP (Android 6.0.1_r81, Apache-2.0), без изменений: `hardware/hardware.h`,
`hardware/hwcomposer.h`, `hardware/hwcomposer_defs.h`, `cutils/native_handle.h`, `system/graphics.h`.
`hardware/gralloc.h` — своя заглушка: hwcomposer.h нужен из него только `buffer_handle_t`.
