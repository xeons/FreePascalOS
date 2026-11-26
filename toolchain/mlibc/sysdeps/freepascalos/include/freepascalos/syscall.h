/*
 * FreePascalOS
 * Copyright (C) 2026 Brandon Scott
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/*
 * The FreePascalOS system call interface for C: the call numbers, the
 * flags and the records of shared/Abi.SystemCalls.inc and
 * shared/Abi.Networking.inc that the C library uses, and the calls
 * themselves. The kernel takes the number in RAX (X8 on AArch64) and up
 * to six arguments in RDI, RSI, RDX, R10, R8, R9 (X0-X5) and returns a
 * result in RAX (X0); an error comes back as a negative number whose
 * absolute value is the Linux errno of the same name.
 *
 * Keep this file in step with the Pascal include files.
 */
#ifndef _FREEPASCALOS_SYSCALL_H
#define _FREEPASCALOS_SYSCALL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- Call numbers ------------------------------------------------------- */

#define FPOS_CALL_EXIT 0
#define FPOS_CALL_WRITE 1
#define FPOS_CALL_READ 2
#define FPOS_CALL_OPEN 3
#define FPOS_CALL_CLOSE 4
#define FPOS_CALL_SEEK 5
#define FPOS_CALL_GET_HANDLE_INFORMATION 6
#define FPOS_CALL_GET_PATH_INFORMATION 7
#define FPOS_CALL_READ_DIRECTORY 8
#define FPOS_CALL_CREATE_DIRECTORY 9
#define FPOS_CALL_REMOVE 10
#define FPOS_CALL_RENAME 11
#define FPOS_CALL_CREATE_SYMBOLIC_LINK 12
#define FPOS_CALL_READ_SYMBOLIC_LINK 13
#define FPOS_CALL_SET_FILE_SIZE 14
#define FPOS_CALL_GET_CURRENT_DIRECTORY 15
#define FPOS_CALL_SET_CURRENT_DIRECTORY 16
#define FPOS_CALL_ALLOCATE_MEMORY 17
#define FPOS_CALL_FREE_MEMORY 18
#define FPOS_CALL_CREATE_PROCESS 19
#define FPOS_CALL_WAIT_FOR_PROCESS 20
#define FPOS_CALL_GET_PROCESS_ID 21
#define FPOS_CALL_CREATE_PIPE 22
#define FPOS_CALL_DUPLICATE_HANDLE 23
#define FPOS_CALL_SLEEP 24
#define FPOS_CALL_GET_TIME 25
#define FPOS_CALL_LOAD_LIBRARY 26
#define FPOS_CALL_FIND_SYMBOL 27
#define FPOS_CALL_GET_SYSTEM_INFORMATION 28
#define FPOS_CALL_GET_VOLUME_INFORMATION 29
#define FPOS_CALL_SYNC 30
#define FPOS_CALL_GET_HANDLE_KIND 31
#define FPOS_CALL_SET_PATH_ATTRIBUTES 33
#define FPOS_CALL_CREATE_HARD_LINK 34
#define FPOS_CALL_TERMINATE_PROCESS 35
#define FPOS_CALL_SET_ROOT_DIRECTORY 36
#define FPOS_CALL_CONTROL_HANDLE 37
#define FPOS_CALL_SET_INTERRUPT_IGNORED 38
#define FPOS_CALL_GET_PROCESS_GROUP 39
#define FPOS_CALL_CREATE_THREAD 40
#define FPOS_CALL_EXIT_THREAD 41
#define FPOS_CALL_WAIT_FOR_THREAD 42
#define FPOS_CALL_SET_THREAD_POINTER 43
#define FPOS_CALL_GET_THREAD_ID 44
#define FPOS_CALL_WAIT_ON_ADDRESS 45
#define FPOS_CALL_WAKE_ADDRESS 46
#define FPOS_CALL_LIST_PROCESSES 50
#define FPOS_CALL_GET_CREDENTIALS 51
#define FPOS_CALL_SET_USER_IDS 52
#define FPOS_CALL_SET_GROUP_IDS 53
#define FPOS_CALL_SET_GROUPS 54
#define FPOS_CALL_SET_UMASK 55
#define FPOS_CALL_GET_PRIORITY 56
#define FPOS_CALL_SET_PRIORITY 57
#define FPOS_CALL_CREATE_FIFO 58
#define FPOS_CALL_STOP_PROCESSES 59
#define FPOS_CALL_CONTINUE_PROCESSES 60
#define FPOS_CALL_WAIT_FOR_PROCESS_CHANGE 61
#define FPOS_CALL_SET_HANDLE_ATTRIBUTES 66
#define FPOS_CALL_SET_EXCEPTION_DISPATCHER 67
#define FPOS_CALL_EXCEPTION_DISPATCHED 68
#define FPOS_CALL_CONTINUE 69
#define FPOS_CALL_MAP_HANDLE 72
#define FPOS_CALL_CREATE_EVENT 73
#define FPOS_CALL_SET_EVENT 74
#define FPOS_CALL_RESET_EVENT 75
#define FPOS_CALL_CREATE_TIMER 76
#define FPOS_CALL_SET_TIMER 77
#define FPOS_CALL_WAIT_FOR_HANDLES 78
#define FPOS_CALL_CREATE_PSEUDO_TERMINAL 86
#define FPOS_CALL_SELECT_NOTIFICATIONS 91
#define FPOS_CALL_RECEIVE_NOTIFICATION 92
#define FPOS_CALL_REQUEST_END 93
#define FPOS_CALL_CREATE_SOCKET 104
#define FPOS_CALL_BIND_SOCKET 105
#define FPOS_CALL_LISTEN_SOCKET 106
#define FPOS_CALL_ACCEPT_SOCKET 107
#define FPOS_CALL_CONNECT_SOCKET 108
#define FPOS_CALL_SEND_SOCKET 109
#define FPOS_CALL_RECEIVE_SOCKET 110
#define FPOS_CALL_SHUTDOWN_SOCKET 111
#define FPOS_CALL_GET_SOCKET_OPTION 112
#define FPOS_CALL_SET_SOCKET_OPTION 113
#define FPOS_CALL_GET_SOCKET_ADDRESS 114
#define FPOS_CALL_WAIT_FOR_SOCKET 115
#define FPOS_CALL_LIST_NETWORK_INTERFACES 116
#define FPOS_CALL_GET_DNS_SERVERS 122
#define FPOS_CALL_SET_NODE_NAME 124
#define FPOS_CALL_SET_THREAD_NAME 148
#define FPOS_CALL_GET_PRECISE_TIME 152
#define FPOS_CALL_RESERVE_MEMORY 160
#define FPOS_CALL_COMMIT_MEMORY 161
#define FPOS_CALL_DECOMMIT_MEMORY 162
#define FPOS_CALL_PROTECT_MEMORY 163
#define FPOS_CALL_QUERY_MEMORY 164
#define FPOS_CALL_SET_MEMORY_POLICY 165
#define FPOS_CALL_GET_FILE_TIMES 175

/* The POSIX block (180-199): calls added for the C library. */

/* (Address, Length, Protection, Flags, Handle, Offset): mmap. */
#define FPOS_CALL_MAP_MEMORY 180
/* (Address, Length): munmap. */
#define FPOS_CALL_UNMAP_MEMORY 181
/* (): fork. The parent gets the child's id, the child 0. */
#define FPOS_CALL_FORK_PROCESS 182
/* (ExecutionAddress): execve (struct fpos_execution). */
#define FPOS_CALL_EXECUTE_PROGRAM 183
/* (Pid, StatusAddress, Flags): waitpid (Linux status word). */
#define FPOS_CALL_WAIT_FOR_CHILD 184
/* (Entry, Argument, StackPointer): a thread on the caller's stack. */
#define FPOS_CALL_CREATE_THREAD_ON_STACK 185
/* (Dispatcher): the process's signal dispatcher. */
#define FPOS_CALL_SET_SIGNAL_DISPATCHER 186
/* (Target, Signal): kill (pid > 0, -group, 0: own group, -1: all). */
#define FPOS_CALL_SEND_SIGNAL 187
/* (How, SetAddress, OldAddress): sigprocmask of the calling thread. */
#define FPOS_CALL_SET_SIGNAL_MASK 188
/* (Signal, Disposition): what the kernel does with a signal. */
#define FPOS_CALL_SET_SIGNAL_DISPOSITION 189
/* (ContextAddress, Mask): leaves a signal handler. */
#define FPOS_CALL_RETURN_FROM_SIGNAL 190
/* (MaskAddress): sigsuspend. */
#define FPOS_CALL_SUSPEND_FOR_SIGNAL 191
/* (): the signals waiting for the calling thread. */
#define FPOS_CALL_PENDING_SIGNALS 192
/* (Pid, Group): setpgid. */
#define FPOS_CALL_SET_PROCESS_GROUP 193
/* (): setsid. */
#define FPOS_CALL_CREATE_SESSION 194
/* (Pid, Which): getpgid (Which 0) or getsid (Which 1). */
#define FPOS_CALL_GET_PROCESS_GROUP_OF 195
/* (): the parent's id. */
#define FPOS_CALL_GET_PARENT_PROCESS_ID 196

/* File mappings (214-219). */

/* (Address, Length, Flags): msync (the MS_* values). */
#define FPOS_CALL_SYNC_MEMORY 214
/* (Address, Length, VectorAddress): mincore (FPOS_PAGE_RESIDENCY_*). */
#define FPOS_CALL_QUERY_MEMORY_RESIDENCY 215

/* Files and local sockets (250-259). */

/* (Handle, Buffer, Count, Offset): pread, the position left alone. */
#define FPOS_CALL_READ_AT 250
/* (Handle, Buffer, Count, Offset): pwrite. */
#define FPOS_CALL_WRITE_AT 251
/* (Handle, Flags): fsync of one file (FPOS_SYNC_HANDLE_DATA_ONLY). */
#define FPOS_CALL_SYNC_HANDLE 252
/* (Kind, Flags, PairAddress): a Unix domain socket, or a pair of them. */
#define FPOS_CALL_CREATE_LOCAL_SOCKET 253
/* (Handle, NameAddress): bind to a struct fpos_local_socket_name. */
#define FPOS_CALL_BIND_LOCAL_SOCKET 254
/* (Handle, NameAddress): connect. */
#define FPOS_CALL_CONNECT_LOCAL_SOCKET 255
/* (Handle, MessageAddress, Flags): sendmsg (struct fpos_local_message). */
#define FPOS_CALL_SEND_LOCAL_MESSAGE 256
/* (Handle, MessageAddress, Flags): recvmsg. */
#define FPOS_CALL_RECEIVE_LOCAL_MESSAGE 257
/* (Handle, Which, BufferAddress): names, peer credentials, the kind. */
#define FPOS_CALL_QUERY_LOCAL_SOCKET 258
/* Event descriptors (260-269): eventfd, timerfd, signalfd, epoll,
   inotify. Each handle is waited on like any other and read with
   FPOS_CALL_READ. */
/* (InitialValue, Flags): an event counter. */
#define FPOS_CALL_CREATE_EVENT_COUNTER 260
/* (Clock, Flags): a timer descriptor (clock: the Linux clock id). */
#define FPOS_CALL_CREATE_TIMER_DESCRIPTOR 261
/* (Handle, Flags, NewSpecification or 0, OldSpecification or 0). */
#define FPOS_CALL_SET_TIMER_DESCRIPTOR 262
/* (Handle): POLLIN, POLLOUT, POLLERR, POLLHUP bits. */
#define FPOS_CALL_QUERY_HANDLE_READINESS 263
/* (Handle or -1, Mask, Flags): a signal descriptor, or a new mask. */
#define FPOS_CALL_SET_SIGNAL_DESCRIPTOR 264
/* (Flags): an event poll. */
#define FPOS_CALL_CREATE_EVENT_POLL 265
/* (Poll, Operation, Handle, struct fpos_poll_event *). */
#define FPOS_CALL_CONTROL_EVENT_POLL 266
/* (Poll, struct fpos_poll_event *, Capacity, TimeoutMilliseconds). */
#define FPOS_CALL_WAIT_EVENT_POLL 267
/* (Flags): a watch group. */
#define FPOS_CALL_CREATE_WATCH_GROUP 268
/* (Group, Operation, Path or Descriptor, Mask). */
#define FPOS_CALL_CHANGE_GROUP_WATCH 269

/* --- Errors --------------------------------------------------------------- */

#define FPOS_ERROR_TIMED_OUT 110
#define FPOS_ERROR_BUSY 16
#define FPOS_ERROR_WOULD_BLOCK 11

/* --- Open flags, seek origins, kinds -------------------------------------- */

#define FPOS_OPEN_READ 0x01
#define FPOS_OPEN_WRITE 0x02
#define FPOS_OPEN_CREATE 0x04
#define FPOS_OPEN_EXCLUSIVE 0x08
#define FPOS_OPEN_TRUNCATE 0x10
#define FPOS_OPEN_APPEND 0x20

#define FPOS_KIND_FILE 0
#define FPOS_KIND_DIRECTORY 1
#define FPOS_KIND_SYMBOLIC_LINK 2
#define FPOS_KIND_OTHER 3
#define FPOS_KIND_FIFO 4
#define FPOS_KIND_CHARACTER_DEVICE 5
#define FPOS_KIND_BLOCK_DEVICE 6
#define FPOS_KIND_SOCKET 7

#define FPOS_HANDLE_KIND_FILE 1
#define FPOS_HANDLE_KIND_CONSOLE 2
#define FPOS_HANDLE_KIND_PIPE 3
#define FPOS_HANDLE_KIND_PROCESS 4
#define FPOS_HANDLE_KIND_NULL_DEVICE 5
#define FPOS_HANDLE_KIND_THREAD 6
#define FPOS_HANDLE_KIND_DEVICE 7
#define FPOS_HANDLE_KIND_SOCKET 14
#define FPOS_HANDLE_KIND_EVENT_COUNTER 20
#define FPOS_HANDLE_KIND_TIMER_DESCRIPTOR 21
#define FPOS_HANDLE_KIND_SIGNAL_DESCRIPTOR 22
#define FPOS_HANDLE_KIND_EVENT_POLL 23
#define FPOS_HANDLE_KIND_WATCH_GROUP 24

#define FPOS_TIME_WALL_CLOCK 0
#define FPOS_TIME_UPTIME_NANOSECONDS 2

#define FPOS_INFINITE_WAIT (-1)
#define FPOS_CURRENT_THREAD_HANDLE (-1)

/* Attribute changes (FPOS_CALL_SET_PATH_ATTRIBUTES). */
#define FPOS_CHANGE_MODE 0x01
#define FPOS_CHANGE_OWNER 0x02
#define FPOS_CHANGE_GROUP 0x04
#define FPOS_CHANGE_MODIFICATION_TIME 0x08
#define FPOS_CHANGE_ACCESS_TIME 0x10
#define FPOS_CHANGE_TIMES_ARE_NOW 0x20
/* The record's nanosecond fields count (utimensat). */
#define FPOS_CHANGE_NANOSECONDS 0x40

/* The clock page (auxiliary vector entry FPOS_AUXILIARY_CLOCK_PAGE). */
#define FPOS_AUXILIARY_CLOCK_PAGE 0x1004
#define FPOS_CLOCK_PAGE_MODE_SYSTEM_CALL 0
#define FPOS_CLOCK_PAGE_MODE_COUNTER 1

/* mincore bits (FPOS_CALL_QUERY_MEMORY_RESIDENCY). */
#define FPOS_PAGE_RESIDENCY_RESIDENT 0x01
#define FPOS_PAGE_RESIDENCY_MAPPED 0x02
#define FPOS_PAGE_RESIDENCY_DIRTY 0x04

/* FPOS_CALL_SYNC_HANDLE. */
#define FPOS_SYNC_HANDLE_DATA_ONLY 0x01

/* Console requests (FPOS_CALL_CONTROL_HANDLE). */
#define FPOS_CONTROL_GET_CONSOLE_MODE 1
#define FPOS_CONTROL_SET_CONSOLE_MODE 2
#define FPOS_CONTROL_GET_CONSOLE_SIZE 3
#define FPOS_CONTROL_SET_FOREGROUND_GROUP 4
#define FPOS_CONTROL_GET_FOREGROUND_GROUP 5
#define FPOS_CONTROL_SET_CONSOLE_SIZE 6
#define FPOS_CONTROL_GET_TERMINAL_NUMBER 7
#define FPOS_CONTROL_LOCK_FILE 300
#define FPOS_CONTROL_UNLOCK_FILE 301
/* On an event descriptor: 1 non-blocking, 0 blocking. */
#define FPOS_CONTROL_SET_NON_BLOCKING 320

/* Event descriptor flags (Abi.EventDescriptors.inc). */
#define FPOS_EVENT_DESCRIPTOR_NON_BLOCKING 0x800
#define FPOS_EVENT_COUNTER_SEMAPHORE 1
#define FPOS_TIMER_ABSOLUTE 1
#define FPOS_TIMER_CANCEL_ON_SET 2
#define FPOS_POLL_ADD 1
#define FPOS_POLL_REMOVE 2
#define FPOS_POLL_MODIFY 3
#define FPOS_POLL_MAXIMUM_EVENTS 1024
#define FPOS_GROUP_WATCH_ADD 1
#define FPOS_GROUP_WATCH_REMOVE 2

/* An event poll's event and registration (TAbiPollEvent). */
struct fpos_poll_event {
	uint32_t events;
	uint32_t reserved;
	uint64_t data;
};

/* A timer descriptor's setting (TAbiTimerSpecification: struct
   itimerspec on 64-bit). */
struct fpos_timer_specification {
	int64_t interval_seconds;
	int64_t interval_nanoseconds;
	int64_t value_seconds;
	int64_t value_nanoseconds;
};
#define FPOS_FILE_LOCK_SHARED 1
#define FPOS_FILE_LOCK_EXCLUSIVE 2
#define FPOS_FILE_LOCK_NO_WAIT 0x100
#define FPOS_CONSOLE_MODE_ECHO 0x01
#define FPOS_CONSOLE_MODE_LINE_EDITING 0x02
#define FPOS_CONSOLE_MODE_INTERRUPT_KEY 0x04

/* Memory (FPOS_CALL_MAP_MEMORY and the virtual memory calls). */
#define FPOS_MEMORY_NO_ACCESS 0
#define FPOS_MEMORY_READ 1
#define FPOS_MEMORY_WRITE 2
#define FPOS_MEMORY_EXECUTE 4
#define FPOS_MAP_SHARED 0x01
#define FPOS_MAP_PRIVATE 0x02
#define FPOS_MAP_FIXED 0x10
#define FPOS_MAP_ANONYMOUS 0x20
#define FPOS_MAP_FIXED_NOREPLACE 0x100000

/* Process creation. */
#define FPOS_GROUP_INHERIT 0
#define FPOS_GROUP_NEW (-1)
#define FPOS_PROCESS_PASS_HANDLES 0x02

/* Waiting for a child (FPOS_CALL_WAIT_FOR_CHILD): the Linux values. */
#define FPOS_WAIT_NO_HANG 1
#define FPOS_WAIT_UNTRACED 2
#define FPOS_WAIT_CONTINUED 8

/* Signal dispositions (FPOS_CALL_SET_SIGNAL_DISPOSITION). */
#define FPOS_SIGNAL_DEFAULT 0
#define FPOS_SIGNAL_IGNORE 1
#define FPOS_SIGNAL_HANDLE 2

/* Sockets. */
#define FPOS_ADDRESS_FAMILY_IPV4 2
#define FPOS_ADDRESS_FAMILY_IPV6 10
#define FPOS_SOCKET_KIND_STREAM 1
#define FPOS_SOCKET_KIND_DATAGRAM 2
#define FPOS_SOCKET_KIND_RAW 3
#define FPOS_SOCKET_KIND_NON_BLOCKING 0x100
#define FPOS_SOCKET_FLAG_PEEK 0x01
#define FPOS_SOCKET_FLAG_DONT_WAIT 0x02
#define FPOS_SOCKET_ADDRESS_LOCAL 0
#define FPOS_SOCKET_ADDRESS_PEER 1
#define FPOS_SOCKET_READABLE 0x01
#define FPOS_SOCKET_WRITABLE 0x02
#define FPOS_SOCKET_OPTION_RECEIVE_TIMEOUT 1
#define FPOS_SOCKET_OPTION_SEND_TIMEOUT 2
#define FPOS_SOCKET_OPTION_BROADCAST 3
#define FPOS_SOCKET_OPTION_REUSE_ADDRESS 4
#define FPOS_SOCKET_OPTION_TIME_TO_LIVE 5
#define FPOS_SOCKET_OPTION_NON_BLOCKING 6
#define FPOS_SOCKET_OPTION_ERROR 7
#define FPOS_SOCKET_OPTION_NO_DELAY 8
#define FPOS_SOCKET_OPTION_KIND 9
#define FPOS_SOCKET_OPTION_READABLE_BYTES 12
#define FPOS_SOCKET_OPTION_KEEP_ALIVE 13
#define FPOS_SOCKET_OPTION_KEEP_IDLE 14
#define FPOS_SOCKET_OPTION_KEEP_INTERVAL 15
#define FPOS_SOCKET_OPTION_KEEP_COUNT 16
#define FPOS_SOCKET_OPTION_RECEIVE_BUFFER 17
#define FPOS_SOCKET_OPTION_SEND_BUFFER 18
#define FPOS_SOCKET_OPTION_IPV6_ONLY 22
#define FPOS_SOCKET_OPTION_PASS_CREDENTIALS 28
#define FPOS_SOCKET_OPTION_LISTENING 29

/* Local (Unix domain) sockets. */
#define FPOS_LOCAL_SOCKET_STREAM 1
#define FPOS_LOCAL_SOCKET_DATAGRAM 2
#define FPOS_LOCAL_SOCKET_PACKETS 5
#define FPOS_LOCAL_SOCKET_NON_BLOCKING 0x100
#define FPOS_LOCAL_SOCKET_NAME_CAPACITY 108
#define FPOS_MAXIMUM_LOCAL_MESSAGE_HANDLES 64
#define FPOS_LOCAL_MESSAGE_PEEK 0x01
#define FPOS_LOCAL_MESSAGE_DONT_WAIT 0x02
#define FPOS_LOCAL_MESSAGE_WAIT_ALL 0x04
#define FPOS_LOCAL_MESSAGE_TRUNCATED 0x10
#define FPOS_LOCAL_MESSAGE_HANDLES_CUT 0x20
#define FPOS_LOCAL_QUERY_NAME 0
#define FPOS_LOCAL_QUERY_PEER_NAME 1
#define FPOS_LOCAL_QUERY_PEER_CREDENTIALS 2
#define FPOS_LOCAL_QUERY_KIND 3

/* --- Records ---------------------------------------------------------------- */

struct fpos_file_information {
	uint32_t kind;
	uint32_t mode;
	uint64_t size_in_bytes;
	uint64_t node_number;
	uint32_t link_count;
	uint32_t owner_id;
	uint32_t group_id;
	uint32_t volume_number;
	int64_t modification_time;
	int64_t access_time;
	int64_t change_time;
	uint64_t allocated_bytes;
};

struct fpos_precise_time {
	int64_t seconds;
	uint32_t nanoseconds;
	uint32_t reserved;
};

struct fpos_file_times {
	struct fpos_precise_time access;
	struct fpos_precise_time modification;
	struct fpos_precise_time change;
	struct fpos_precise_time birth;
	uint32_t flags;
	uint32_t reserved;
};

#define FPOS_NAME_CAPACITY 256
#define FPOS_TEXT_CAPACITY 64
#define FPOS_MAXIMUM_SUPPLEMENTARY_GROUPS 32

struct fpos_directory_entry {
	uint32_t kind;
	uint32_t reserved;
	uint64_t node_number;
	char name[FPOS_NAME_CAPACITY];
};

struct fpos_attribute_changes {
	uint32_t fields;
	uint32_t mode;
	uint32_t owner_id;
	uint32_t group_id;
	int64_t modification_time;
	int64_t access_time;
	/* Read only with FPOS_CHANGE_NANOSECONDS. */
	uint32_t modification_nanoseconds;
	uint32_t access_nanoseconds;
};

/* The clock page (TAbiClockPage): Sequence is odd while the kernel
   changes it. */
struct fpos_clock_page {
	uint32_t sequence;
	uint32_t mode;
	uint64_t counter_origin;
	uint64_t origin_nanoseconds;
	uint64_t counter_frequency;
	int64_t wall_base_offset;
	int64_t slew_total;
	uint64_t slew_start;
	uint32_t slew_parts_per_million;
	uint32_t reserved;
};

struct fpos_credentials {
	uint32_t real_user_id;
	uint32_t effective_user_id;
	uint32_t saved_user_id;
	uint32_t real_group_id;
	uint32_t effective_group_id;
	uint32_t saved_group_id;
	uint32_t umask;
	int32_t nice;
	uint32_t group_count;
	uint32_t reserved;
	uint32_t groups[FPOS_MAXIMUM_SUPPLEMENTARY_GROUPS];
};

struct fpos_system_information {
	char system_name[FPOS_TEXT_CAPACITY];
	char release[FPOS_TEXT_CAPACITY];
	char version[FPOS_TEXT_CAPACITY];
	char machine[FPOS_TEXT_CAPACITY];
	char node_name[FPOS_TEXT_CAPACITY];
	uint64_t total_memory;
	uint64_t free_memory;
	uint64_t uptime_milliseconds;
	uint32_t processor_count;
	uint32_t reserved;
	uint32_t load_averages[3];
	uint32_t runnable_threads;
};

struct fpos_volume_information {
	char name[FPOS_TEXT_CAPACITY];
	char file_system_type[FPOS_TEXT_CAPACITY];
	char volume_label[FPOS_TEXT_CAPACITY];
	uint64_t total_bytes;
	uint64_t free_bytes;
	uint32_t is_read_only;
	uint32_t is_system_volume;
	uint32_t has_free_space;
	uint32_t is_removable;
};

struct fpos_process_creation {
	const char *path;
	char *const *arguments;
	char *const *environment;
	const char *working_directory;
	int64_t input_handle;
	int64_t output_handle;
	int64_t error_handle;
	int64_t group_id;
	void *identity;
	uint64_t flags;
	const int64_t *passed_handles;
	uint64_t passed_handle_count;
};

/* FPOS_CALL_EXECUTE_PROGRAM: the program and what it starts with; the
   handles in close_on_exec are closed once the new program is loaded. */
struct fpos_execution {
	const char *path;
	char *const *arguments;
	char *const *environment;
	const int32_t *close_on_exec;
	uint64_t close_on_exec_count;
};

struct fpos_socket_address {
	uint16_t family;
	uint16_t port;
	uint32_t scope_id;
	uint8_t address[16];
	uint64_t reserved;
};

struct fpos_local_socket_name {
	uint32_t length;
	uint32_t reserved;
	char bytes[FPOS_LOCAL_SOCKET_NAME_CAPACITY];
};

struct fpos_local_credentials {
	uint32_t process_id;
	uint32_t user_id;
	uint32_t group_id;
	uint32_t reserved;
};

struct fpos_local_message {
	const void *buffer;
	uint64_t length;
	int64_t *handles;
	uint32_t handle_count;
	uint32_t flags;
	struct fpos_local_socket_name *name;
	struct fpos_local_credentials credentials;
};

struct fpos_pseudo_terminal {
	int64_t output_handle;
	int64_t input_handle;
	int64_t terminal_handle;
	int64_t number;
};

/* What the kernel hands a signal handler (FPOS_CALL_SET_SIGNAL_DISPATCHER):
   the signal, the thread's mask before it, why it came and the
   interrupted registers (as fpos_context). */
#if defined(__x86_64__)
struct fpos_context {
	uint64_t rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp;
	uint64_t r8, r9, r10, r11, r12, r13, r14, r15;
	uint64_t rip;
	uint64_t rflags;
};
#elif defined(__aarch64__)
struct fpos_context {
	uint64_t x[31];
	uint64_t sp;
	uint64_t pc;
	uint64_t pstate;
};
#endif

/* A processor exception passed to the program (TAbiExceptionRecord). */
#define FPOS_EXCEPTION_ACCESS_VIOLATION 1
#define FPOS_EXCEPTION_INTEGER_DIVIDE 2
#define FPOS_EXCEPTION_INTEGER_OVERFLOW 3
#define FPOS_EXCEPTION_BOUND_RANGE 4
#define FPOS_EXCEPTION_ILLEGAL_INSTRUCTION 5
#define FPOS_EXCEPTION_BREAKPOINT 6
#define FPOS_EXCEPTION_FLOATING_POINT 7
#define FPOS_EXCEPTION_SIMD_FLOATING_POINT 8
#define FPOS_EXCEPTION_ALIGNMENT 9
#define FPOS_EXCEPTION_PRIVILEGED_OPERATION 10
#define FPOS_EXCEPTION_STACK_OVERFLOW 11
#define FPOS_EXCEPTION_GUARD_PAGE 12

struct fpos_exception_record {
	uint32_t code;
	uint32_t access;
	uint64_t address;
	uint64_t fault_address;
	struct fpos_context context;
};

/* Why a signal came (fpos_signal_record.code). */
#define FPOS_SIGNAL_FROM_PROCESS 0
#define FPOS_SIGNAL_FROM_KERNEL 1

struct fpos_signal_record {
	uint32_t signal;
	uint32_t code;
	uint64_t previous_mask;
	uint64_t fault_address;
	int64_t sender_process_id;
	uint64_t sender_user_id;
	int64_t value;
	struct fpos_context context;
};

/* --- The calls -------------------------------------------------------------- */

#if defined(__x86_64__)

static inline long fpos_syscall6(long number, long a0, long a1, long a2, long a3, long a4, long a5) {
	register long r10 __asm__("r10") = a3;
	register long r8 __asm__("r8") = a4;
	register long r9 __asm__("r9") = a5;
	long result;
	__asm__ volatile("syscall"
		: "=a"(result)
		: "a"(number), "D"(a0), "S"(a1), "d"(a2), "r"(r10), "r"(r8), "r"(r9)
		: "rcx", "r11", "memory");
	return result;
}

#elif defined(__aarch64__)

static inline long fpos_syscall6(long number, long a0, long a1, long a2, long a3, long a4, long a5) {
	register long x8 __asm__("x8") = number;
	register long x0 __asm__("x0") = a0;
	register long x1 __asm__("x1") = a1;
	register long x2 __asm__("x2") = a2;
	register long x3 __asm__("x3") = a3;
	register long x4 __asm__("x4") = a4;
	register long x5 __asm__("x5") = a5;
	__asm__ volatile("svc #0"
		: "+r"(x0)
		: "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
		: "memory");
	return x0;
}

#else
#error "FreePascalOS runs on x86-64 and AArch64"
#endif

static inline long fpos_syscall0(long number) {
	return fpos_syscall6(number, 0, 0, 0, 0, 0, 0);
}

static inline long fpos_syscall1(long number, long a0) {
	return fpos_syscall6(number, a0, 0, 0, 0, 0, 0);
}

static inline long fpos_syscall2(long number, long a0, long a1) {
	return fpos_syscall6(number, a0, a1, 0, 0, 0, 0);
}

static inline long fpos_syscall3(long number, long a0, long a1, long a2) {
	return fpos_syscall6(number, a0, a1, a2, 0, 0, 0);
}

static inline long fpos_syscall4(long number, long a0, long a1, long a2, long a3) {
	return fpos_syscall6(number, a0, a1, a2, a3, 0, 0);
}

static inline long fpos_syscall5(long number, long a0, long a1, long a2, long a3, long a4) {
	return fpos_syscall6(number, a0, a1, a2, a3, a4, 0);
}

/* The errno of a result: 0 for success. */
static inline int fpos_error_of(long result) {
	return (result < 0 && result > -4096) ? (int)-result : 0;
}

#ifdef __cplusplus
}
#endif

#endif /* _FREEPASCALOS_SYSCALL_H */
