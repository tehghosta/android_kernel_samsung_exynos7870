/*
 * Low Level Interrupts/Traps/Exceptions(non-TLB) Handling for ARC
 *
 * Copyright (C) 2004, 2007-2010, 2011-2012 Synopsys, Inc. (www.synopsys.com)
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 *
 * vineetg: May 2011
 *  -Userspace unaligned access emulation
 *
 * vineetg: Feb 2011 (ptrace low level code fixes)
 *  -traced syscall return code (r0) was not saved into pt_regs for restoring
 *   into user reg-file when traded task rets to user space.
 *  -syscalls needing arch-wrappers (mainly for passing sp as pt_regs)
 *   were not invoking post-syscall trace hook (jumping directly into
 *   ret_from_system_call)
 *
 * vineetg: Nov 2010:
 *  -Vector table jumps (@8 bytes) converted into branches (@4 bytes)
 *  -To maintain the slot size of 8 bytes/vector, added nop, which is
 *   not executed at runtime.
 *
 * vineetg: Nov 2009 (Everything needed for TIF_RESTORE_SIGMASK)
 *  -do_signal()invoked upon TIF_RESTORE_SIGMASK as well
 *  -Wrappers for sys_{,rt_}sigsuspend() nolonger needed as they don't
 *   need ptregs anymore
 *
 * Vineetg: Oct 2009
 *  -In a rare scenario, Process gets a Priv-V exception and gets scheduled
 *   out. Since we don't do FAKE RTIE for Priv-V, CPU excpetion state remains
 *   active (AE bit enabled).  This causes a double fault for a subseq valid
 *   exception. Thus FAKE RTIE needed in low level Priv-Violation handler.
 *   Instr Error could also cause similar scenario, so same there as well.
 *
 * Vineetg: March 2009 (Supporting 2 levels of Interrupts)
 *
 * Vineetg: Aug 28th 2008: Bug #94984
 *  -Zero Overhead Loop Context shd be cleared when entering IRQ/EXcp/Trap
 *   Normally CPU does this automatically, however when doing FAKE rtie,
 *   we need to explicitly do this. The problem in macros
 *   FAKE_RET_FROM_EXCPN and FAKE_RET_FROM_EXCPN_LOCK_IRQ was that this bit
 *   was being "CLEARED" rather then "SET". Since it is Loop INHIBIT Bit,
 *   setting it and not clearing it clears ZOL context
 *
 * Vineetg: May 16th, 2008
 *  - r25 now contains the Current Task when in kernel
 *
 * Vineetg: Dec 22, 2007
 *    Minor Surgery of Low Level ISR to make it SMP safe
 *    - MMU_SCRATCH0 Reg used for freeing up r9 in Level 1 ISR
 *    - _current_task is made an array of NR_CPUS
 *    - Access of _current_task wrapped inside a macro so that if hardware
 *       team agrees for a dedicated reg, no other code is touched
 *
 * Amit Bhor, Rahul Trivedi, Kanika Nema, Sameer Dhavale : Codito Tech 2004
 */

/*------------------------------------------------------------------
 *    Function                            ABI
 *------------------------------------------------------------------
 *
 *  Arguments                           r0 - r7
 *  Caller Saved Registers              r0 - r12
 *  Callee Saved Registers              r13- r25
 *  Global Pointer (gp)                 r26
 *  Frame Pointer (fp)                  r27
 *  Stack Pointer (sp)                  r28
 *  Interrupt link register (ilink1)    r29
 *  Interrupt link register (ilink2)    r30
 *  Branch link register (blink)        r31
 *------------------------------------------------------------------
 */

	.cpu A7

;############################ Vector Table #################################

.macro VECTOR  lbl
#if 1   /* Just in case, build breaks */
	j   \lbl
#else
	b   \lbl
	nop
#endif
.endm

	.section .vector, "ax",@progbits
	.align 4

/* Each entry in the vector table must occupy 2 words. Since it is a jump
 * across sections (.vector to .text) we are gauranteed that 'j somewhere'
 * will use the 'j limm' form of the intrsuction as long as somewhere is in
 * a section other than .vector.
 */

; ********* Critical System Events **********************
VECTOR   res_service             ; 0x0, Restart Vector  (0x0)
VECTOR   mem_service             ; 0x8, Mem exception   (0x1)
VECTOR   instr_service           ; 0x10, Instrn Error   (0x2)

; ******************** Device ISRs **********************
#ifdef CONFIG_ARC_IRQ3_LV2
VECTOR   handle_interrupt_level2
#else
VECTOR   handle_interrupt_level1
#endif

VECTOR   handle_interrupt_level1

#ifdef CONFIG_ARC_IRQ5_LV2
VECTOR   handle_interrupt_level2
#else
VECTOR   handle_interrupt_level1
#endif

#ifdef CONFIG_ARC_IRQ6_LV2
VECTOR   handle_interrupt_level2
#else
VECTOR   handle_interrupt_level1
#endif

.rept   25
VECTOR   handle_interrupt_level1 ; Other devices
.endr

/* FOR ARC600: timer = 0x3, uart = 0x8, emac = 0x10 */

; ******************** Exceptions **********************
VECTOR   EV_MachineCheck         ; 0x100, Fatal Machine check   (0x20)
VECTOR   EV_TLBMissI             ; 0x108, Intruction TLB miss   (0x21)
VECTOR   EV_TLBMissD             ; 0x110, Data TLB miss         (0x22)
VECTOR   EV_TLBProtV             ; 0x118, Protection Violation  (0x23)
				 ;         or Misaligned Access
VECTOR   EV_PrivilegeV           ; 0x120, Privilege Violation   (0x24)
VECTOR   EV_Trap                 ; 0x128, Trap exception        (0x25)
VECTOR   EV_Extension            ; 0x130, Extn Intruction Excp  (0x26)

.rept   24
VECTOR   reserved                ; Reserved Exceptions
.endr

#include <linux/linkage.h>   /* {EXTRY,EXIT} */
#include <asm/entry.h>       /* SAVE_ALL_{INT1,INT2,SYS...} */
#include <asm/errno.h>
#include <asm/arcregs.h>
#include <asm/irqflags.h>

;##################### Scratch Mem for IRQ stack switching #############

ARCFP_DATA int1_saved_reg
	.align 32
	.type   int1_saved_reg, @object
	.size   int1_saved_reg, 4
int1_saved_reg:
	.zero 4

/* Each Interrupt level needs its own scratch */
#ifdef CONFIG_ARC_COMPACT_IRQ_LEVELS

ARCFP_DATA int2_saved_reg
	.type   int2_saved_reg, @object
	.size   int2_saved_reg, 4
int2_saved_reg:
	.zero 4

#endif

; ---------------------------------------------
	.section .text, "ax",@progbits

res_service:		; processor restart
	flag    0x1     ; not implemented
	nop
	nop

reserved:		; processor restart
	rtie            ; jump to processor initializations

;##################### Interrupt Handling ##############################

#ifdef CONFIG_ARC_COMPACT_IRQ_LEVELS
; ---------------------------------------------
;  Level 2 ISR: Can interrupt a Level 1 ISR
; ---------------------------------------------
ENTRY(handle_interrupt_level2)

	; TODO-vineetg for SMP this wont work
	; free up r9 as scratchpad
	st  r9, [@int2_saved_reg]

	;Which mode (user/kernel) was the system in when intr occured
	lr  r9, [status32_l2]

	SWITCH_TO_KERNEL_STK
	SAVE_ALL_INT2

	;------------------------------------------------------
	; if L2 IRQ interrupted a L1 ISR, disable preemption
	;------------------------------------------------------

	ld r9, [sp, PT_status32]        ; get statu32_l2 (saved in pt_regs)
	bbit0 r9, STATUS_A1_BIT, 1f     ; L1 not active when L2 IRQ, so normal

	; A1 is set in status32_l2
	; bump thread_info->preempt_count (Disable preemption)
	GET_CURR_THR_INFO_FROM_SP   r10
	ld      r9, [r10, THREAD_INFO_PREEMPT_COUNT]
	add     r9, r9, 1
	st      r9, [r10, THREAD_INFO_PREEMPT_COUNT]

1:
	;------------------------------------------------------
	; setup params for Linux common ISR and invoke it
	;------------------------------------------------------
	lr  r0, [icause2]
	and r0, r0, 0x1f

	bl.d  @arch_do_IRQ
	mov r1, sp

	mov r8,0x2
	sr r8, [AUX_IRQ_LV12]       ; clear bit in Sticky Status Reg

	b   ret_from_exception

END(handle_interrupt_level2)

#endif

; ---------------------------------------------
;  Level 1 ISR
; ---------------------------------------------
ENTRY(handle_interrupt_level1)

	/* free up r9 as scratchpad */
#ifdef CONFIG_SMP
	sr  r9, [ARC_REG_SCRATCH_DATA0]
#else
	st   r9, [@int1_saved_reg]
#endif

	;Which mode (user/kernel) was the system in when intr occured
	lr  r9, [status32_l1]

	SWITCH_TO_KERNEL_STK
	SAVE_ALL_INT1

	lr  r0, [icause1]
	and r0, r0, 0x1f

#ifdef CONFIG_TRACE_IRQFLAGS
	; icause1 needs to be read early, before calling tracing, which
	; can clobber scratch regs, hence use of stack to stash it
	push r0
	TRACE_ASM_IRQ_DISABLE
	pop  r0
#endif

	bl.d  @arch_do_IRQ
	mov r1, sp

	mov r8,0x1
	sr r8, [AUX_IRQ_LV12]       ; clear bit in Sticky Status Reg

	b   ret_from_exception
END(handle_interrupt_level1)

;################### Non TLB Exception Handling #############################

; ---------------------------------------------
; Instruction Error Exception Handler
; ---------------------------------------------

ENTRY(instr_service)

	EXCEPTION_PROLOGUE

	lr  r0, [efa]
	mov r1, sp

	FAKE_RET_FROM_EXCPN r9

	bl  do_insterror_or_kprobe
	b   ret_from_exception
END(instr_service)

; ---------------------------------------------
; Memory Error Exception Handler
; ---------------------------------------------

ENTRY(mem_service)

	EXCEPTION_PROLOGUE

	lr  r0, [efa]
	mov r1, sp

	FAKE_RET_FROM_EXCPN r9

	bl  do_memory_error
	b   ret_from_exception
END(mem_service)

; ---------------------------------------------
; Machine Check Exception Handler
; ---------------------------------------------

ENTRY(EV_MachineCheck)

	EXCEPTION_PROLOGUE

	lr  r2, [ecr]
	lr  r0, [efa]
	mov r1, sp

	; hardware auto-disables MMU, re-enable it to allow kernel vaddr
	; access for say stack unwinding of modules for crash dumps
	lr	r3, [ARC_REG_PID]
	or	r3, r3, MMU_ENABLE
	sr	r3, [ARC_REG_PID]

	lsr  	r3, r2, 8
	bmsk 	r3, r3, 7
	brne    r3, ECR_C_MCHK_DUP_TLB, 1f

	bl      do_tlb_overlap_fault
	b       ret_from_exception

1:
	; DEAD END: can't do much, display Regs and HALT
	SAVE_CALLEE_SAVED_USER

	GET_CURR_TASK_FIELD_PTR   TASK_THREAD, r10
	st  sp, [r10, THREAD_CALLEE_REG]

	j  do_machine_check_fault

END(EV_MachineCheck)

; ---------------------------------------------
; Protection Violation Exception Handler
; ---------------------------------------------

ENTRY(EV_TLBProtV)

	EXCEPTION_PROLOGUE

	;---------(3) Save some more regs-----------------
	;  vineetg: Mar 6th: Random Seg Fault issue #1
	;  ecr and efa were not saved in case an Intr sneaks in
	;  after fake rtie

	lr  r2, [ecr]
	lr  r0, [efa]	; Faulting Data address

	; --------(4) Return from CPU Exception Mode ---------
	;  Fake a rtie, but rtie to next label
	;  That way, subsequently, do_page_fault ( ) executes in pure kernel
	;  mode with further Exceptions enabled

	FAKE_RET_FROM_EXCPN r9

	mov   r1, sp

	;------ (5) Type of Protection Violation? ----------
	;
	; ProtV Hardware Exception is triggered for Access Faults of 2 types
	;   -Access Violaton	: 00_23_(00|01|02|03)_00
	;			         x  r  w  r+w
	;   -Unaligned Access	: 00_23_04_00
	;
	bbit1 r2, ECR_C_BIT_PROTV_MISALIG_DATA, 4f

	;========= (6a) Access Violation Processing ========
	bl  do_page_fault
	b   ret_from_exception

	;========== (6b) Non aligned access ============
4:

	SAVE_CALLEE_SAVED_USER
	mov r2, sp              ; callee_regs

	bl  do_misaligned_access

	; TBD: optimize - do this only if a callee reg was involved
	; either a dst of emulated LD/ST or src with address-writeback
	RESTORE_CALLEE_SAVED_USER

	b   ret_from_exception

END(EV_TLBProtV)

; ---------------------------------------------
; Privilege Violation Exception Handler
; ---------------------------------------------
ENTRY(EV_PrivilegeV)

	EXCEPTION_PROLOGUE

	lr  r0, [efa]
	mov r1, sp

	FAKE_RET_FROM_EXCPN r9

	bl  do_privilege_fault
	b   ret_from_exception
END(EV_PrivilegeV)

; ---------------------------------------------
; Extension Instruction Exception Handler
; ---------------------------------------------
ENTRY(EV_Extension)

	EXCEPTION_PROLOGUE

	lr  r0, [efa]
	mov r1, sp

	FAKE_RET_FROM_EXCPN r9

	bl  do_extension_fault
	b   ret_from_exception
END(EV_Extension)

;######################### System Call Tracing #########################

tracesys:
	; save EFA in case tracer wants the PC of traced task
	; using ERET won't work since next-PC has already committed
	lr  r12, [efa]
	GET_CURR_TASK_FIELD_PTR   TASK_THREAD, r11
	st  r12, [r11, THREAD_FAULT_ADDR]	; thread.fault_address

	; PRE Sys Call Ptrace hook
	mov r0, sp			; pt_regs needed
	bl  @syscall_trace_entry

	; Tracing code now returns the syscall num (orig or modif)
	mov r8, r0

	; Do the Sys Call as we normally would.
	; Validate the Sys Call number
	cmp     r8,  NR_syscalls - 1
	mov.hi  r0, -ENOSYS
	bhi     tracesys_exit

	; Restore the sys-call args. Mere invocation of the hook abv could have
	; clobbered them (since they are in scratch regs). The tracer could also
	; have deliberately changed the syscall args: r0-r7
	ld  r0, [sp, PT_r0]
	ld  r1, [sp, PT_r1]
	ld  r2, [sp, PT_r2]
	ld  r3, [sp, PT_r3]
	ld  r4, [sp, PT_r4]
	ld  r5, [sp, PT_r5]
	ld  r6, [sp, PT_r6]
	ld  r7, [sp, PT_r7]
	ld.as   r9, [sys_call_table, r8]
	jl      [r9]        ; Entry into Sys Call Handler

tracesys_exit:
	st  r0, [sp, PT_r0]     ; sys call return value in pt_regs

	;POST Sys Call Ptrace Hook
	mov r0, sp		; pt_regs needed
	bl  @syscall_trace_exit
	b   ret_from_exception ; NOT ret_from_system_call at is saves r0 which
	; we'd done before calling post hook above

;################### Break Point TRAP ##########################

	; ======= (5b) Trap is due to Break-Point =========

trap_with_param:

	; stop_pc info by gdb needs this info
	lr  r0, [efa]
	mov r1, sp

	; Now that we have read EFA, it is safe to do "fake" rtie
	;   and get out of CPU exception mode
	FAKE_RET_FROM_EXCPN r11

	; Save callee regs in case gdb wants to have a look
	; SP will grow up by size of CALLEE Reg-File
	; NOTE: clobbers r12
	SAVE_CALLEE_SAVED_USER

	; save location of saved Callee Regs @ thread_struct->pc
	GET_CURR_TASK_FIELD_PTR   TASK_THREAD, r10
	st  sp, [r10, THREAD_CALLEE_REG]

	; Call the trap handler
	bl  do_non_swi_trap

	; unwind stack to discard Callee saved Regs
	DISCARD_CALLEE_SAVED_USER

	b   ret_from_exception

;##################### Trap Handling ##############################
;
; EV_Trap caused by TRAP_S and TRAP0 instructions.
;------------------------------------------------------------------
;   (1) System Calls
;       :parameters in r0-r7.
;       :r8 has the system call number
;   (2) Break Points
;------------------------------------------------------------------

ENTRY(EV_Trap)

	EXCEPTION_PROLOGUE

	;------- (4) What caused the Trap --------------
	lr     r12, [ecr]
	bmsk.f 0, r12, 7
	bnz    trap_with_param

	; ======= (5a) Trap is due to System Call ========

	; Before doing anything, return from CPU Exception Mode
	FAKE_RET_FROM_EXCPN r11

	; If syscall tracing ongoing, invoke pre-pos-hooks
	GET_CURR_THR_INFO_FLAGS   r10
	btst r10, TIF_SYSCALL_TRACE
	bnz tracesys  ; this never comes back

	;============ This is normal System Call case ==========
	; Sys-call num shd not exceed the total system calls avail
	cmp     r8,  NR_syscalls - 1
	mov.hi  r0, -ENOSYS
	bhi     ret_from_system_call

	; Offset into the syscall_table and call handler
	ld.as   r9,[sys_call_table, r8]
	jl      [r9]        ; Entry into Sys Call Handler

	; fall through to ret_from_system_call
END(EV_Trap)

ENTRY(ret_from_system_call)

	st  r0, [sp, PT_r0]     ; sys call return value in pt_regs

	; fall through yet again to ret_from_exception

;############# Return from Intr/Excp/Trap (Linux Specifics) ##############
;
; If ret to user mode do we need to handle signals, schedule() et al.

ENTRY(ret_from_exception)

	; Pre-{IRQ,Trap,Exception} K/U mode from pt_regs->status32
	ld  r8, [sp, PT_status32]   ; returning to User/Kernel Mode

	bbit0  r8, STATUS_U_BIT, resume_kernel_mode

	; Before returning to User mode check-for-and-complete any pending work
	; such as rescheduling/signal-delivery etc.
resume_user_mode_begin:

	; Disable IRQs to ensures that chk for pending work itself is atomic
	; (and we don't end up missing a NEED_RESCHED/SIGPENDING due to an
	; interim IRQ).
	IRQ_DISABLE	r10

	; Fast Path return to user mode if no pending work
	GET_CURR_THR_INFO_FLAGS   r9
	and.f  0,  r9, _TIF_WORK_MASK
	bz     restore_regs

	; --- (Slow Path #1) task preemption ---
	bbit0  r9, TIF_NEED_RESCHED, .Lchk_pend_signals
	mov    blink, resume_user_mode_begin  ; tail-call to U mode ret chks
	b      @schedule 	; BTST+Bnz causes relo error in link

.Lchk_pend_signals:
	IRQ_ENABLE	r10

	; --- (Slow Path #2) pending signal  ---
	mov r0, sp	; pt_regs for arg to do_signal()/do_notify_resume()

	GET_CURR_THR_INFO_FLAGS   r9
	bbit0  r9, TIF_SIGPENDING, .Lchk_notify_resume

	; Normal Trap/IRQ entry only saves Scratch (caller-saved) regs
	; in pt_reg since the "C" ABI (kernel code) will automatically
	; save/restore callee-saved regs.
	;
	; However, here we need to explicitly save callee regs because
	; (i)  If this signal causes coredump - full regfile needed
	; (ii) If signal is SIGTRAP/SIGSTOP, task is being traced thus
	;      tracer might call PEEKUSR(CALLEE reg)
	;
	; NOTE: SP will grow up by size of CALLEE Reg-File
	SAVE_CALLEE_SAVED_USER		; clobbers r12

	; save location of saved Callee Regs @ thread_struct->callee
	GET_CURR_TASK_FIELD_PTR   TASK_THREAD, r10
	st  sp, [r10, THREAD_CALLEE_REG]

	bl  @do_signal

	; Ideally we want to discard the Callee reg above, however if this was
	; a tracing signal, tracer could have done a POKEUSR(CALLEE reg)
	RESTORE_CALLEE_SAVED_USER

	b      resume_user_mode_begin	; loop back to start of U mode ret

	; --- (Slow Path #3) notify_resume ---
.Lchk_notify_resume:
	btst   r9, TIF_NOTIFY_RESUME
	blnz   @do_notify_resume
	b      resume_user_mode_begin	; unconditionally back to U mode ret chks
					; for single exit point from this block

resume_kernel_mode:

	; Disable Interrupts from this point on
	; CONFIG_PREEMPT: This is a must for preempt_schedule_irq()
	; !CONFIG_PREEMPT: To ensure restore_regs is intr safe
	IRQ_DISABLE	r9

#ifdef CONFIG_PREEMPT

	; Can't preempt if preemption disabled
	GET_CURR_THR_INFO_FROM_SP   r10
	ld  r8, [r10, THREAD_INFO_PREEMPT_COUNT]
	brne  r8, 0, restore_regs

	; check if this task's NEED_RESCHED flag set
	ld  r9, [r10, THREAD_INFO_FLAGS]
	bbit0  r9, TIF_NEED_RESCHED, restore_regs

	; Invoke PREEMPTION
	bl      preempt_schedule_irq

	; preempt_schedule_irq() always returns with IRQ disabled
#endif

	; fall through

;############# Return from Intr/Excp/Trap (ARC Specifics) ##############
;
; Restore the saved sys context (common exit-path for EXCPN/IRQ/Trap)
; IRQ shd definitely not happen between now and rtie
; All 2 entry points to here already disable interrupts

restore_regs :

	TRACE_ASM_IRQ_ENABLE

	lr	r10, [status32]

	; Restore REG File. In case multiple Events outstanding,
	; use the same priorty as rtie: EXCPN, L2 IRQ, L1 IRQ, None
	; Note that we use realtime STATUS32 (not pt_regs->status32) to
	; decide that.

	; if Returning from Exception
	bbit0  r10, STATUS_AE_BIT, not_exception
	RESTORE_ALL_SYS
	rtie

	; Not Exception so maybe Interrupts (Level 1 or 2)

not_exception:

#ifdef CONFIG_ARC_COMPACT_IRQ_LEVELS

	; Level 2 interrupt return Path - from hardware standpoint
	bbit0  r10, STATUS_A2_BIT, not_level2_interrupt

	;------------------------------------------------------------------
	; However the context returning might not have taken L2 intr itself
	; e.g. Task'A' user-code -> L2 intr -> schedule -> 'B' user-code ret
	; Special considerations needed for the context which took L2 intr

	ld   r9, [sp, PT_event]        ; Ensure this is L2 intr context
	brne r9, event_IRQ2, 149f

	;------------------------------------------------------------------
	; if L2 IRQ interrupted an L1 ISR,  we'd disabled preemption earlier
	; so that sched doesn't move to new task, causing L1 to be delayed
	; undeterministically. Now that we've achieved that, let's reset
	; things to what they were, before returning from L2 context
	;----------------------------------------------------------------

	ld r9, [sp, PT_status32]       ; get statu32_l2 (saved in pt_regs)
	bbit0 r9, STATUS_A1_BIT, 149f  ; L1 not active when L2 IRQ, so normal

	; decrement thread_info->preempt_count (re-enable preemption)
	GET_CURR_THR_INFO_FROM_SP   r10
	ld      r9, [r10, THREAD_INFO_PREEMPT_COUNT]

	; paranoid check, given A1 was active when A2 happened, preempt count
	; must not be 0 because we would have incremented it.
	; If this does happen we simply HALT as it means a BUG !!!
	cmp     r9, 0
	bnz     2f
	flag 1

2:
	sub     r9, r9, 1
	st      r9, [r10, THREAD_INFO_PREEMPT_COUNT]

149:
	;return from level 2
	RESTORE_ALL_INT2
debug_marker_l2:
	rtie

not_level2_interrupt:

#endif

	bbit0  r10, STATUS_A1_BIT, not_level1_interrupt

	;return from level 1

	RESTORE_ALL_INT1
debug_marker_l1:
	rtie

not_level1_interrupt:

	;this case is for syscalls or Exceptions (with fake rtie)

	RESTORE_ALL_SYS
debug_marker_syscall:
	rtie

END(ret_from_exception)

ENTRY(ret_from_fork)
	; when the forked child comes here from the __switch_to function
	; r0 has the last task pointer.
	; put last task in scheduler queue
	bl   @schedule_tail

	; If kernel thread, jump to its entry-point
	ld   r9, [sp, PT_status32]
	brne r9, 0, 1f

	jl.d [r14]
	mov  r0, r13		; arg to payload

1:
	; special case of kernel_thread entry point returning back due to
	; kernel_execve() - pretend return from syscall to ret to userland
	b    ret_from_exception
END(ret_from_fork)

;################### Special Sys Call Wrappers ##########################

ENTRY(sys_clone_wrapper)
	SAVE_CALLEE_SAVED_USER
	bl  @sys_clone
	DISCARD_CALLEE_SAVED_USER

	GET_CURR_THR_INFO_FLAGS   r10
	btst r10, TIF_SYSCALL_TRACE
	bnz  tracesys_exit

	b ret_from_system_call
END(sys_clone_wrapper)

#ifdef CONFIG_ARC_DW2_UNWIND
; Workaround for bug 94179 (STAR ):
; Despite -fasynchronous-unwind-tables, linker is not making dwarf2 unwinder
; section (.debug_frame) as loadable. So we force it here.
; This also fixes STAR 9000487933 where the prev-workaround (objcopy --setflag)
; would not work after a clean build due to kernel build system dependencies.
.section .debug_frame, "wa",@progbits
#endif
