#ifndef _KERNEL_TIME_TIMEKEEPING_H
#define _KERNEL_TIME_TIMEKEEPING_H
/*
 * Internal interfaces for kernel/time/
 */
extern ktime_t ktime_get_update_offsets_now(ktime_t *offs_real,
						ktime_t *offs_boot,
						ktime_t *offs_tai);

extern int timekeeping_valid_for_hres(void);
extern u64 timekeeping_max_deferment(void);
extern int timekeeping_inject_offset(struct timespec *ts);
extern s32 timekeeping_get_tai_offset(void);
extern void timekeeping_set_tai_offset(s32 tai_offset);
extern void timekeeping_clocktai(struct timespec *ts);

#endif
