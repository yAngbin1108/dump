//
//  cy_prefix.h — 只给 src/vendor/cyanide/ 下的文件用（-include 注入）
//
//  Cyanide 的 TaskRop 与 dump 自己的 kexploit/TaskRop 定义了同名符号
//  （init_remote_call / do_remote_call_stable / remote_read / sign_state …），
//  两套都要留在包里，所以把 vendored 这一侧统一加 cy_ 前缀。
//
//  这里**只做重命名**，不改任何一行 vendored 源码；kexploit 层
//  （kread64 / kwrite64 / is_kaddr_valid / proc_find_by_name …）来自
//  src/kexploit/cy/，是同一份 Cyanide 代码，不加前缀。
//

#ifndef CY_VENDOR_PREFIX_H
#define CY_VENDOR_PREFIX_H

/* ── RemoteCall.m ─────────────────────────────────────────────────────── */
#define init_remote_call                                                cy_init_remote_call
#define init_remote_call_with_first_exception_timeout                   cy_init_remote_call_with_first_exception_timeout
#define init_remote_call_original_thread_only_with_first_exception_timeout \
                                                                        cy_init_remote_call_original_thread_only_with_first_exception_timeout
#define destroy_remote_call                                             cy_destroy_remote_call
#define abandon_remote_call                                             cy_abandon_remote_call
#define do_remote_call_stable                                           cy_do_remote_call_stable
#define do_remote_call_stable_addr                                      cy_do_remote_call_stable_addr
#define do_remote_call_temp                                             cy_do_remote_call_temp
#define remote_call_current_success                                     cy_remote_call_current_success
#define remote_call_current_pid                                         cy_remote_call_current_pid
#define remote_call_set_stable_timeout_floor_ms                         cy_remote_call_set_stable_timeout_floor_ms
#define remote_call_last_init_failure                                   cy_remote_call_last_init_failure
#define remote_call_last_init_failure_pid                               cy_remote_call_last_init_failure_pid
#define remote_call_init_failure_description                            cy_remote_call_init_failure_description
#define remote_call_has_local_state                                     cy_remote_call_has_local_state
#define remote_call_trojan_mem                                          cy_remote_call_trojan_mem
#define remote_call_with_session                                        cy_remote_call_with_session
#define remote_read                                                     cy_remote_read
#define remote_read64                                                   cy_remote_read64
#define remote_hexdump                                                  cy_remote_hexdump
#define remote_write                                                    cy_remote_write
#define remote_write64                                                  cy_remote_write64
#define remote_writeStr                                                 cy_remote_writeStr
#define sign_state                                                      cy_sign_state
#define restore_trojan_thread                                           cy_restore_trojan_thread
#define retry_first_thread                                              cy_retry_first_thread
#define set_exception_port_on_thread                                    cy_set_exception_port_on_thread
#define get_shmem_from_cache                                            cy_get_shmem_from_cache
#define put_shmem_in_cache                                              cy_put_shmem_in_cache
#define get_shmem_for_page                                              cy_get_shmem_for_page
#define g_RC_targetProcOverride                                         cy_g_RC_targetProcOverride
#define g_RC_gadgetPacia                                                cy_g_RC_gadgetPacia
#define RemoteCallSession                                               CyRemoteCallSession
#define RemotePointer                                                   CyRemotePointer

/* ── Extras from RemoteCall.m ─────────────────────────────────────────── */
#define remote_pac                                                      cy_remote_pac
#define native_strip                                                    cy_native_strip
#define pacia                                                           cy_pacia
#define ptrauth_blend_discriminator_wrapper                             cy_ptrauth_blend_discriminator_wrapper
#define ptrauth_string_discriminator_special                            cy_ptrauth_string_discriminator_special
#define find_pacia_gadget                                               cy_find_pacia_gadget
#define pac_cleanup                                                     cy_pac_cleanup

/* ── Thread.m ─────────────────────────────────────────────────────────── */
#define inject_guard_exception                                          cy_inject_guard_exception
#define clear_guard_exception                                           cy_clear_guard_exception
#define thread_get_state_wrapper                                        cy_thread_get_state_wrapper
#define thread_set_state_wrapper                                        cy_thread_set_state_wrapper
#define thread_resume_wrapper                                           cy_thread_resume_wrapper
#define thread_set_pac_keys                                             cy_thread_set_pac_keys

/* ── Exception.m ──────────────────────────────────────────────────────── */
#define create_exception_port                                           cy_create_exception_port
#define destroy_exception_port                                          cy_destroy_exception_port
#define wait_exception                                                  cy_wait_exception
#define reply_with_state                                                cy_reply_with_state

/* ── VM.m ─────────────────────────────────────────────────────────────── */
#define vm_map_get_header                                               cy_vm_map_get_header
#define vm_map_header_get_first_entry                                   cy_vm_map_header_get_first_entry
#define vm_map_entry_get_next_entry                                     cy_vm_map_entry_get_next_entry
#define vm_header_get_nentries                                          cy_vm_header_get_nentries
#define vm_entry_get_range                                              cy_vm_entry_get_range
#define vm_map_iterate_entries                                          cy_vm_map_iterate_entries
#define vm_map_find_entry                                               cy_vm_map_find_entry
#define VM_PACKING_IS_BASE_RELATIVE                                     cy_VM_PACKING_IS_BASE_RELATIVE
#define vm_unpack_pointer                                               cy_vm_unpack_pointer
#define vm_pack_pointer                                                 cy_vm_pack_pointer
#define VME_OFFSET                                                      cy_VME_OFFSET
#define vm_get_object                                                   cy_vm_get_object
#define vm_create_shmem_with_object                                     cy_vm_create_shmem_with_object
#define vm_map_remote_page                                              cy_vm_map_remote_page

/* ── MigFilterBypassThread.m ──────────────────────────────────────────── */
#define kstrip                                                          cy_kstrip
#define trunc_page_16k                                                  cy_trunc_page_16k
#define current_time_ms                                                 cy_current_time_ms
#define lock_sandbox_lock                                               cy_lock_sandbox_lock
#define unlock_sandbox_lock                                             cy_unlock_sandbox_lock
#define find_return_value_offs                                          cy_find_return_value_offs
#define disable_filter_on_thread                                        cy_disable_filter_on_thread
#define wait_for_mig_syscall                                            cy_wait_for_mig_syscall
#define start_filter_bypass                                             cy_start_filter_bypass
#define mig_bypass_thread_func                                          cy_mig_bypass_thread_func
#define mig_bypass_init                                                 cy_mig_bypass_init
#define mig_bypass_start                                                cy_mig_bypass_start
#define mig_bypass_stop                                                 cy_mig_bypass_stop
#define mig_bypass_pause                                                cy_mig_bypass_pause
#define mig_bypass_resume                                               cy_mig_bypass_resume
#define mig_bypass_monitor_threads                                      cy_mig_bypass_monitor_threads
#define mig_bypass_is_running                                           cy_mig_bypass_is_running
#define mig_bypass_destroy                                              cy_mig_bypass_destroy
#define g_MFB_kernelSlide                                               cy_g_MFB_kernelSlide
#define g_MFB_migLockOff                                                cy_g_MFB_migLockOff
#define g_MFB_migSbxMsgOff                                              cy_g_MFB_migSbxMsgOff
#define g_MFB_migKernelStackLR                                          cy_g_MFB_migKernelStackLR
#define g_MFB_runFlag                                                   cy_g_MFB_runFlag
#define g_MFB_isRunning                                                 cy_g_MFB_isRunning
#define g_MFB_monitorThread1                                            cy_g_MFB_monitorThread1
#define g_MFB_monitorThread2                                            cy_g_MFB_monitorThread2
#define g_MFB_thread                                                    cy_g_MFB_thread
#define g_MFB_initialized                                               cy_g_MFB_initialized

#endif /* CY_VENDOR_PREFIX_H */
