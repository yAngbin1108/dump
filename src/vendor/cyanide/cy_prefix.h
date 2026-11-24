//
//  cyv_prefix.h — 只给 src/vendor/cyanide/ 下的文件用（-include 注入）
//
//  Cyanide 的 TaskRop 与 dump 自己的 kexploit/TaskRop 定义了同名符号
//  （init_remote_call / do_remote_call_stable / remote_read / sign_state …），
//  两套都要留在包里，所以把 vendored 这一侧统一加 cyv_ 前缀。
//
//  这里**只做重命名**，不改任何一行 vendored 源码；kexploit 层
//  （kread64 / kwrite64 / is_kaddr_valid / proc_find_by_name …）来自
//  src/kexploit/cy/，是同一份 Cyanide 代码，不加前缀。
//

#ifndef CY_VENDOR_PREFIX_H
#define CY_VENDOR_PREFIX_H

/* vendored RemoteCall.m 依赖 MAP_PRIVATE/MAP_ANON 但没有包含 sys/mman.h
   （Cyanide 工程里靠别处传递进来）。用这个强制包含头补上，不改 vendored 源码。 */
#include <sys/mman.h>
#import <UIKit/UIKit.h>

/* Thread.m 用这个宏做系统版本分支，Cyanide 在 kexploit_opa334.h 里定义。 */
#ifndef SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO
#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v) \
    ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending)
#endif

/* ── RemoteCall.m ─────────────────────────────────────────────────────── */
#define init_remote_call                                                cyv_init_remote_call
#define init_remote_call_with_first_exception_timeout                   cyv_init_remote_call_with_first_exception_timeout
#define init_remote_call_original_thread_only_with_first_exception_timeout \
                                                                        cyv_init_remote_call_original_thread_only_with_first_exception_timeout
#define destroy_remote_call                                             cyv_destroy_remote_call
#define abandon_remote_call                                             cyv_abandon_remote_call
#define do_remote_call_stable                                           cyv_do_remote_call_stable
#define do_remote_call_stable_addr                                      cyv_do_remote_call_stable_addr
#define do_remote_call_temp                                             cyv_do_remote_call_temp
#define remote_call_current_success                                     cyv_remote_call_current_success
#define remote_call_current_pid                                         cyv_remote_call_current_pid
#define remote_call_set_stable_timeout_floor_ms                         cyv_remote_call_set_stable_timeout_floor_ms
#define remote_call_last_init_failure                                   cyv_remote_call_last_init_failure
#define remote_call_last_init_failure_pid                               cyv_remote_call_last_init_failure_pid
#define remote_call_init_failure_description                            cyv_remote_call_init_failure_description
#define remote_call_has_local_state                                     cyv_remote_call_has_local_state
#define remote_call_trojan_mem                                          cyv_remote_call_trojan_mem
#define remote_call_with_session                                        cyv_remote_call_with_session
#define remote_read                                                     cyv_remote_read
#define remote_read64                                                   cyv_remote_read64
#define remote_hexdump                                                  cyv_remote_hexdump
#define remote_write                                                    cyv_remote_write
#define remote_write64                                                  cyv_remote_write64
#define remote_writeStr                                                 cyv_remote_writeStr
#define sign_state                                                      cyv_sign_state
#define restore_trojan_thread                                           cyv_restore_trojan_thread
#define retry_first_thread                                              cyv_retry_first_thread
#define set_exception_port_on_thread                                    cyv_set_exception_port_on_thread
#define get_shmem_from_cache                                            cyv_get_shmem_from_cache
#define put_shmem_in_cache                                              cyv_put_shmem_in_cache
#define get_shmem_for_page                                              cyv_get_shmem_for_page
#define g_RC_targetProcOverride                                         cyv_g_RC_targetProcOverride
#define g_RC_gadgetPacia                                                cyv_g_RC_gadgetPacia
#define RemoteCallSession                                               CyvRemoteCallSession
#define RemotePointer                                                   CyvRemotePointer

/* ── Extras from RemoteCall.m ─────────────────────────────────────────── */
#define remote_pac                                                      cyv_remote_pac
#define native_strip                                                    cyv_native_strip
#define pacia                                                           cyv_pacia
#define ptrauth_blend_discriminator_wrapper                             cyv_ptrauth_blend_discriminator_wrapper
#define ptrauth_string_discriminator_special                            cyv_ptrauth_string_discriminator_special
#define find_pacia_gadget                                               cyv_find_pacia_gadget
#define pac_cleanup                                                     cyv_pac_cleanup

/* ── Thread.m ─────────────────────────────────────────────────────────── */
#define inject_guard_exception                                          cyv_inject_guard_exception
#define clear_guard_exception                                           cyv_clear_guard_exception
#define thread_get_state_wrapper                                        cyv_thread_get_state_wrapper
#define thread_set_state_wrapper                                        cyv_thread_set_state_wrapper
#define thread_resume_wrapper                                           cyv_thread_resume_wrapper
#define thread_set_pac_keys                                             cyv_thread_set_pac_keys

/* ── Exception.m ──────────────────────────────────────────────────────── */
#define create_exception_port                                           cyv_create_exception_port
#define destroy_exception_port                                          cyv_destroy_exception_port
#define wait_exception                                                  cyv_wait_exception
#define reply_with_state                                                cyv_reply_with_state

/* ── VM.m ─────────────────────────────────────────────────────────────── */
#define vm_map_get_header                                               cyv_vm_map_get_header
#define vm_map_header_get_first_entry                                   cyv_vm_map_header_get_first_entry
#define vm_map_entry_get_next_entry                                     cyv_vm_map_entry_get_next_entry
#define vm_header_get_nentries                                          cyv_vm_header_get_nentries
#define vm_entry_get_range                                              cyv_vm_entry_get_range
#define vm_map_iterate_entries                                          cyv_vm_map_iterate_entries
#define vm_map_find_entry                                               cyv_vm_map_find_entry
#define VM_PACKING_IS_BASE_RELATIVE                                     cyv_VM_PACKING_IS_BASE_RELATIVE
#define vm_unpack_pointer                                               cyv_vm_unpack_pointer
#define vm_pack_pointer                                                 cyv_vm_pack_pointer
#define VME_OFFSET                                                      cyv_VME_OFFSET
#define vm_get_object                                                   cyv_vm_get_object
#define vm_create_shmem_with_object                                     cyv_vm_create_shmem_with_object
#define vm_map_remote_page                                              cyv_vm_map_remote_page

/* ── MigFilterBypassThread.m ──────────────────────────────────────────── */
#define kstrip                                                          cyv_kstrip
#define trunc_page_16k                                                  cyv_trunc_page_16k
#define current_time_ms                                                 cyv_current_time_ms
#define lock_sandbox_lock                                               cyv_lock_sandbox_lock
#define unlock_sandbox_lock                                             cyv_unlock_sandbox_lock
#define find_return_value_offs                                          cyv_find_return_value_offs
#define disable_filter_on_thread                                        cyv_disable_filter_on_thread
#define wait_for_mig_syscall                                            cyv_wait_for_mig_syscall
#define start_filter_bypass                                             cyv_start_filter_bypass
#define mig_bypass_thread_func                                          cyv_mig_bypass_thread_func
#define mig_bypass_init                                                 cyv_mig_bypass_init
#define mig_bypass_start                                                cyv_mig_bypass_start
#define mig_bypass_stop                                                 cyv_mig_bypass_stop
#define mig_bypass_pause                                                cyv_mig_bypass_pause
#define mig_bypass_resume                                               cyv_mig_bypass_resume
#define mig_bypass_monitor_threads                                      cyv_mig_bypass_monitor_threads
#define mig_bypass_is_running                                           cyv_mig_bypass_is_running
#define mig_bypass_destroy                                              cyv_mig_bypass_destroy
#define g_MFB_kernelSlide                                               cyv_g_MFB_kernelSlide
#define g_MFB_migLockOff                                                cyv_g_MFB_migLockOff
#define g_MFB_migSbxMsgOff                                              cyv_g_MFB_migSbxMsgOff
#define g_MFB_migKernelStackLR                                          cyv_g_MFB_migKernelStackLR
#define g_MFB_runFlag                                                   cyv_g_MFB_runFlag
#define g_MFB_isRunning                                                 cyv_g_MFB_isRunning
#define g_MFB_monitorThread1                                            cyv_g_MFB_monitorThread1
#define g_MFB_monitorThread2                                            cyv_g_MFB_monitorThread2
#define g_MFB_thread                                                    cyv_g_MFB_thread
#define g_MFB_initialized                                               cyv_g_MFB_initialized

#endif /* CY_VENDOR_PREFIX_H */
