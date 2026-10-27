/*
 * Chain-loader for vendor "boota": it jumps here with its own (vendor) FDT in x0.
 * We hand the mainline kernel our DTB instead (Documentation/arch/arm64/booting.rst):
 *  - the DTB is copied to its own 2 MiB block, away from the BL31 no-map region;
 *  - the Image is moved, if needed, to a 2 MiB boundary (its text_offset is 0).
 * MMU and D-cache are off here (vendor U-Boot), so every access is 16-byte aligned.
 *
 * This file builds only the loader (shim.bin). boot/pack.py appends the DTB at
 * 0x10000, the Image at 0x180000 and the initramfs after the kernel's memory,
 * fills in the sizes below and points /chosen linux,initrd-* at the initramfs.
 */
#define DTB_DST	0x4e000000

/* A64 WDOG0, sun6i-a31-wdt layout (drivers/watchdog/sunxi_wdt.c) */
#define WDT_BASE	0x01c20ca0
#define WDT_CTRL	0x10
#define WDT_CFG		0x14
#define WDT_MODE	0x18
#define WDT_16S		0xb
#define WDT_CTRL_RELOAD	((1 << 0) | (0x0a57 << 1))

/*
 * DE2 top: bit 0 of sel_cfg swaps the mixer -> TCON routing. Vendor U-Boot
 * leaves mixer0 on TCON1 (HDMI); mainline Linux drives HDMI from mixer1 and
 * expects the default routing that mainline U-Boot restores
 * (drivers/video/sunxi/sunxi_de2.c: clrbits_le32(&de_clk_regs->sel_cfg, 1)).
 */
#define DE2_SEL_CFG	0x01000010

/*
 * Wi-Fi VDDIO (AXP803 DLDO4, 3.0 V) is left OFF by vendor U-Boot (its
 * power_sply entry has no "on" flag; the vendor Wi-Fi driver enables it).
 * After U-Boot the SCP owns the RSB bus, so do the enable here, in a few
 * hundred nanoseconds, with every precondition checked first. Register
 * layout and commands follow drivers/bus/sunxi-rsb.c and
 * drivers/regulator/axp20x-regulator.c. GLOBAL_INT_ENB is never set, so the
 * SCP sees no RSB interrupt; CTRL/INTE are restored afterwards.
 */
#define RSB_BASE	0x01f03400
#define RSB_CTRL	0x00
#define RSB_INTE	0x08
#define RSB_INTS	0x0c
#define RSB_ADDR	0x10
#define RSB_DATA	0x1c
#define RSB_CMD		0x2c
#define RSB_DAR		0x30
#define RSB_CTRL_START	(1 << 7)
#define RSB_CTRL_ABORT	(1 << 6)
#define RSB_CTRL_GIE	(1 << 1)
#define RSB_INT_MASK	0x7		/* LOAD_BSY | TRANS_ERR | TRANS_OVER */
#define RSB_TRANS_OVER	0x1
#define RSB_CMD_RD8	0x8b
#define RSB_CMD_WR8	0x4e
#define RSB_POLL_LIMIT	2000000
#define AXP_RTA		0x2d		/* primary PMIC runtime address */
#define AXP_IC_TYPE	0x03
#define AXP803_ID	0x51
#define AXP_PWR_CTRL2	0x12
#define AXP_DLDO4_EN	(1 << 6)
#define AXP_DLDO4_V	0x18
#define AXP_DLDO4_3V0	0x17		/* 700 mV + 23 * 100 mV */
#define AXP_DCDC2_V	0x21		/* CPU */
#define AXP_DCDC5_V	0x24		/* DRAM */

/*
 * Started from the boot partition (pack.py --slot boot) instead of recovery,
 * the Station would come back to us after every reset, a broken kernel too.
 * So this shim counts the boots that did not come up, in an RTC
 * general-purpose register (kept across the watchdog reset, cleared by a
 * power cut; boot0 reads GP0-5 only, U-Boot, BL31, the SCP and Android's
 * kernel none of 6-7), and init clears the count once our system is up.
 * After BOOTW_MAX_TRIES of them, or when Linux asks for Android
 * (BOOTW_CMD_ANDROID), it sets the PMIC's one-shot flag (vendor U-Boot then
 * boots recovery, where Android is) and resets at once.
 */
#define RTC_GP7		0x01f0011c
#define BOOTW_MAGIC	0x5354		/* "ST", the word's top half */
#define BOOTW_CMD_ANDROID 1		/* bits 15:8 */
#define BOOTW_MAX_TRIES	3		/* bits 7:0 */
#define AXP_BOOT_FLAG	0x0f
#define AXP_BOOT_RECOVERY 0x10
#define WDT_MODE_INTV	0xf0		/* interval field; 0 = 0.5 s */

/* results for init to log; reserved (no-map) in the DTS, own 2 MiB block */
#define SHIMLOG		0x4e400000
#define SHIMLOG_MAGIC	0x324d4853	/* "SHM2" */
#define LOG_CTRL	0x08
#define LOG_INTE	0x0c
#define LOG_ID		0x10
#define LOG_PWR2	0x14
#define LOG_DLDO4V	0x18
#define LOG_DCDC2	0x1c
#define LOG_DCDC5	0x20
#define LOG_WRITE	0x24
#define LOG_PWR2_NEW	0x28
#define LOG_DCDC2_NEW	0x2c
#define LOG_DCDC5_NEW	0x30
#define LOG_RESULT	0x34
#define LOG_RB_ADDR	0x38		/* transfer registers read back before the write */
#define LOG_RB_DATA	0x3c
#define LOG_RB_DAR	0x40
#define LOG_RB_CMD	0x44
#define LOG_SLOT	0x48		/* 1: started from the boot partition */
#define LOG_BOOTW	0x4c		/* the boot word as found */
#define LOG_BOOTW_NEW	0x50		/* as left for this boot */
#define LOG_TO_ANDROID	0x54		/* the flag write's result, if it was tried */
#define LOG_SIZE	0x58
#define RES_ENABLED	1
#define RES_ALREADY_ON	2
#define RES_MISMATCH	3		/* not an AXP803 or DLDO4 not at 3.0 V */
#define RES_BUS_ERROR	4

/* w1 <- (RSB status << 16) | data; w0 <- RSB status (RSB_TRANS_OVER on success) */
.macro	rsb_read reg
	mov	w1, #\reg
	str	w1, [x20, #RSB_ADDR]
	mov	w1, #(AXP_RTA << 16)
	str	w1, [x20, #RSB_DAR]
	mov	w1, #RSB_CMD_RD8
	str	w1, [x20, #RSB_CMD]
	bl	rsb_xfer
	ldr	w1, [x20, #RSB_DATA]
	and	w1, w1, #0xff
	bfi	w1, w0, #16, #16
.endm

	.text
	.global	_start
_start:
	b	entry				/* code0 */
	.long	0				/* code1 */
	.quad	0x80000				/* text_offset, same as the vendor Image */
	.quad	0				/* image_size, set by pack.py */
	.quad	0xa				/* LE, 4K pages, anywhere in RAM */
	.quad	0, 0, 0
	.ascii	"ARM\x64"			/* arm64 Image magic */
	.long	0

entry:
	msr	daifset, #0xf

	/*
	 * Arm the SoC watchdog (16 s, whole-system reset) the way mainline
	 * sunxi_wdt_start() does, so any hang - even inside a firmware call -
	 * falls back to vendor U-Boot. The kernel keeps feeding it from probe
	 * (WATCHDOG_HANDLE_BOOT_ENABLED) until userspace opens /dev/watchdog.
	 */
	ldr	x1, =WDT_BASE
	ldr	w2, [x1, #WDT_MODE]
	bic	w2, w2, #0xf0
	mov	w4, #(WDT_16S << 4)
	orr	w2, w2, w4
	str	w2, [x1, #WDT_MODE]
	ldr	w3, =WDT_CTRL_RELOAD
	str	w3, [x1, #WDT_CTRL]
	ldr	w2, [x1, #WDT_CFG]
	bic	w2, w2, #0x3
	orr	w2, w2, #0x1			/* reset the whole system */
	str	w2, [x1, #WDT_CFG]
	ldr	w2, [x1, #WDT_MODE]
	orr	w2, w2, #0x1			/* enable */
	str	w2, [x1, #WDT_MODE]

	ldr	x1, =DE2_SEL_CFG		/* mixer0 -> TCON0, mixer1 -> TCON1 */
	ldr	w2, [x1]
	bic	w2, w2, #0x1
	str	w2, [x1]
	dsb	sy

	/* --- AXP803 DLDO4 on (Wi-Fi VDDIO), see the comment at RSB_BASE --- */
	ldr	x20, =RSB_BASE
	ldr	x21, =SHIMLOG
	mov	x1, x21				/* clear the log page header */
	mov	x2, #LOG_SIZE
3:	str	xzr, [x1], #8
	subs	x2, x2, #8
	b.ne	3b
	ldr	w1, =SHIMLOG_MAGIC
	str	w1, [x21]

	/* --- started from the boot partition: the boot word, see RTC_GP7 --- */
	ldr	w22, slot
	str	w22, [x21, #LOG_SLOT]
	cbz	w22, bootw_done
	ldr	x19, =RTC_GP7
	ldr	w1, [x19]
	str	w1, [x21, #LOG_BOOTW]
	lsr	w2, w1, #16
	mov	w3, #BOOTW_MAGIC
	cmp	w2, w3
	b.eq	1f
	mov	w1, #(BOOTW_MAGIC << 16)	/* not ours (a power cut): a fresh count */
1:	ubfx	w2, w1, #8, #8
	cmp	w2, #BOOTW_CMD_ANDROID
	b.eq	to_android
	and	w2, w1, #0xff
	cmp	w2, #BOOTW_MAX_TRIES
	b.hs	to_android
	add	w1, w1, #1			/* one more try; init clears it */
	str	w1, [x19]
	str	w1, [x21, #LOG_BOOTW_NEW]
	dsb	sy
	b	bootw_done
to_android:
	mov	w1, #(BOOTW_MAGIC << 16)
	str	w1, [x19]
	str	w1, [x21, #LOG_BOOTW_NEW]
	mov	w27, #AXP_BOOT_FLAG
	mov	w26, #AXP_BOOT_RECOVERY
	bl	axp_write
	str	w25, [x21, #LOG_TO_ANDROID]
	dsb	sy
	cmp	w25, #RES_ENABLED
	b.ne	bootw_done			/* the flag did not take: ours, not a reset back into ours */
	ldr	x1, =WDT_BASE			/* reset now: the watchdog armed above, cut to 0.5 s */
	ldr	w2, [x1, #WDT_MODE]
	bic	w2, w2, #WDT_MODE_INTV
	str	w2, [x1, #WDT_MODE]
	ldr	w3, =WDT_CTRL_RELOAD
	str	w3, [x1, #WDT_CTRL]
	dsb	sy
2:	wfi
	b	2b
bootw_done:

	ldr	w23, [x20, #RSB_CTRL]
	str	w23, [x21, #LOG_CTRL]
	ldr	w24, [x20, #RSB_INTE]
	str	w24, [x21, #LOG_INTE]
	mov	w25, #RES_BUS_ERROR
	tbnz	w23, #7, rsb_out		/* SCP transfer in flight: leave the bus alone */

	rsb_read AXP_IC_TYPE
	str	w1, [x21, #LOG_ID]
	cmp	w0, #RSB_TRANS_OVER
	b.ne	rsb_restore
	mov	w25, #RES_MISMATCH
	and	w2, w1, #0xff
	cmp	w2, #AXP803_ID
	b.ne	rsb_restore

	rsb_read AXP_DLDO4_V
	str	w1, [x21, #LOG_DLDO4V]
	mov	w25, #RES_BUS_ERROR
	cmp	w0, #RSB_TRANS_OVER
	b.ne	rsb_restore
	mov	w25, #RES_MISMATCH
	and	w2, w1, #0x1f
	cmp	w2, #AXP_DLDO4_3V0
	b.ne	rsb_restore

	mov	w25, #RES_BUS_ERROR
	rsb_read AXP_DCDC2_V
	str	w1, [x21, #LOG_DCDC2]
	cmp	w0, #RSB_TRANS_OVER
	b.ne	rsb_restore
	rsb_read AXP_DCDC5_V
	str	w1, [x21, #LOG_DCDC5]
	cmp	w0, #RSB_TRANS_OVER
	b.ne	rsb_restore

	rsb_read AXP_PWR_CTRL2
	str	w1, [x21, #LOG_PWR2]
	cmp	w0, #RSB_TRANS_OVER
	b.ne	rsb_restore
	and	w26, w1, #0xff
	mov	w25, #RES_ALREADY_ON
	tbnz	w26, #6, rsb_restore

	/* the one PMIC write: PWR_CTRL2 |= DLDO4_EN */
	orr	w26, w26, #AXP_DLDO4_EN
	mov	w25, #RES_BUS_ERROR
	mov	w1, #AXP_PWR_CTRL2
	str	w1, [x20, #RSB_ADDR]
	str	w26, [x20, #RSB_DATA]
	mov	w1, #(AXP_RTA << 16)
	str	w1, [x20, #RSB_DAR]
	mov	w1, #RSB_CMD_WR8
	str	w1, [x20, #RSB_CMD]
	/*
	 * Refuse to start if the fields that define the transfer (target
	 * register, command, runtime address) no longer hold our values; an
	 * SCP transfer would have to rewrite them. Everything read back is
	 * logged: in test B3 one full-word compare tripped on plain hardware
	 * behaviour.
	 */
	ldr	w1, [x20, #RSB_ADDR]
	str	w1, [x21, #LOG_RB_ADDR]
	ldr	w2, [x20, #RSB_DATA]
	str	w2, [x21, #LOG_RB_DATA]
	ldr	w3, [x20, #RSB_DAR]
	str	w3, [x21, #LOG_RB_DAR]
	ldr	w4, [x20, #RSB_CMD]
	str	w4, [x21, #LOG_RB_CMD]
	and	w1, w1, #0xff
	cmp	w1, #AXP_PWR_CTRL2
	b.ne	rsb_restore
	ubfx	w3, w3, #16, #8
	cmp	w3, #AXP_RTA
	b.ne	rsb_restore
	and	w4, w4, #0xff
	cmp	w4, #RSB_CMD_WR8
	b.ne	rsb_restore
	bl	rsb_xfer
	str	w0, [x21, #LOG_WRITE]

	rsb_read AXP_PWR_CTRL2			/* read everything back for the log */
	str	w1, [x21, #LOG_PWR2_NEW]
	mov	w27, w1
	rsb_read AXP_DCDC2_V
	str	w1, [x21, #LOG_DCDC2_NEW]
	rsb_read AXP_DCDC5_V
	str	w1, [x21, #LOG_DCDC5_NEW]
	lsr	w1, w27, #16
	cmp	w1, #RSB_TRANS_OVER
	b.ne	rsb_restore
	tbz	w27, #6, rsb_restore
	mov	w25, #RES_ENABLED

rsb_restore:
	str	w24, [x20, #RSB_INTE]
	and	w1, w23, #RSB_CTRL_GIE		/* never START/ABORT/reset here */
	str	w1, [x20, #RSB_CTRL]
rsb_out:
	str	w25, [x21, #LOG_RESULT]
	dsb	sy

	adr	x4, dtb				/* copy DTB to DTB_DST */
	ldr	x5, =DTB_DST
	ldr	x6, dtb_size
	mov	x7, x5
2:	ldp	x15, x16, [x4], #16
	stp	x15, x16, [x7], #16
	subs	x6, x6, #16
	b.ne	2b

	adr	x9, _start
	ldr	x10, image_off
	add	x10, x9, x10			/* src = runtime address of Image */
	ldr	x11, image_size		/* Image size, multiple of 16 */
	ldr	x13, =0x1fffff
	add	x12, x10, x13
	bic	x12, x12, x13			/* dst = src rounded up to 2 MiB */
	cmp	x12, x10
	b.eq	go
	add	x13, x10, x11			/* copy backwards: dst > src, regions overlap */
	add	x14, x12, x11
1:	ldp	x15, x16, [x13, #-16]!
	stp	x15, x16, [x14, #-16]!
	cmp	x13, x10
	b.hi	1b
go:
	dsb	sy
	ic	iallu
	dsb	sy
	isb
	mov	x0, x5
	mov	x1, xzr
	mov	x2, xzr
	mov	x3, xzr
	br	x12
	.ltorg

/*
 * Run the transfer set up in ADDR/DATA/DAR/CMD, polled (no global interrupt).
 * w0 <- RSB_INTS: RSB_TRANS_OVER on success, 0 on timeout, 0xffff if busy.
 * Clobbers w1, x2.
 */
rsb_xfer:
	ldr	w1, [x20, #RSB_CTRL]
	tbz	w1, #7, 1f
	mov	w0, #0xffff
	ret
1:	ldr	w1, [x20, #RSB_INTS]
	str	w1, [x20, #RSB_INTS]		/* drop stale status */
	mov	w1, #RSB_INT_MASK
	str	w1, [x20, #RSB_INTE]
	mov	w1, #RSB_CTRL_START
	str	w1, [x20, #RSB_CTRL]
	ldr	x2, =RSB_POLL_LIMIT
2:	ldr	w0, [x20, #RSB_INTS]
	tst	w0, #RSB_INT_MASK
	b.ne	3f
	subs	x2, x2, #1
	b.ne	2b
	mov	w1, #RSB_CTRL_ABORT
	str	w1, [x20, #RSB_CTRL]
	ldr	w1, [x20, #RSB_INTS]
	str	w1, [x20, #RSB_INTS]
	mov	w0, wzr
	ret
3:	str	w0, [x20, #RSB_INTS]		/* ack */
	ret

/*
 * One PMIC register write, w27 = register, w26 = value, under the checks of
 * the DLDO4 write (no SCP transfer in flight, an AXP803, the transfer
 * registers still ours) and read back. w25 <- RES_ENABLED if it took.
 * Clobbers w0-w4, x2, w13, w14, x28.
 */
axp_write:
	mov	x28, x30
	mov	w25, #RES_BUS_ERROR
	ldr	w13, [x20, #RSB_CTRL]
	ldr	w14, [x20, #RSB_INTE]
	tbnz	w13, #7, 9f			/* SCP transfer in flight: nothing touched */
	rsb_read AXP_IC_TYPE
	cmp	w0, #RSB_TRANS_OVER
	b.ne	8f
	mov	w25, #RES_MISMATCH
	and	w2, w1, #0xff
	cmp	w2, #AXP803_ID
	b.ne	8f
	mov	w25, #RES_BUS_ERROR
	str	w27, [x20, #RSB_ADDR]
	str	w26, [x20, #RSB_DATA]
	mov	w1, #(AXP_RTA << 16)
	str	w1, [x20, #RSB_DAR]
	mov	w1, #RSB_CMD_WR8
	str	w1, [x20, #RSB_CMD]
	ldr	w1, [x20, #RSB_ADDR]
	and	w1, w1, #0xff
	cmp	w1, w27
	b.ne	8f
	ldr	w3, [x20, #RSB_DAR]
	ubfx	w3, w3, #16, #8
	cmp	w3, #AXP_RTA
	b.ne	8f
	ldr	w4, [x20, #RSB_CMD]
	and	w4, w4, #0xff
	cmp	w4, #RSB_CMD_WR8
	b.ne	8f
	bl	rsb_xfer
	cmp	w0, #RSB_TRANS_OVER
	b.ne	8f
	str	w27, [x20, #RSB_ADDR]		/* read it back */
	mov	w1, #(AXP_RTA << 16)
	str	w1, [x20, #RSB_DAR]
	mov	w1, #RSB_CMD_RD8
	str	w1, [x20, #RSB_CMD]
	bl	rsb_xfer
	cmp	w0, #RSB_TRANS_OVER
	b.ne	8f
	ldr	w1, [x20, #RSB_DATA]
	and	w1, w1, #0xff
	cmp	w1, w26
	b.ne	8f
	mov	w25, #RES_ENABLED
8:	str	w14, [x20, #RSB_INTE]
	and	w1, w13, #RSB_CTRL_GIE		/* never START/ABORT/reset here */
	str	w1, [x20, #RSB_CTRL]
9:	mov	x30, x28
	ret
	.ltorg

	.balign	8
/* filled in by pack.py, which finds them by the marker */
	.ascii	"STATIONSHIMLIT01"
dtb_size:	.quad	0			/* DTB size, multiple of 16 */
image_off:	.quad	0x180000		/* lands on 0x40200000 when loaded at 0x40080000 */
image_size:	.quad	0			/* Image size, multiple of 16 */
slot:		.quad	0			/* 1: built for the boot partition (pack.py --slot boot) */
shim_end:

	.equ	dtb, _start + 0x10000
