// FreePascalOS
// Copyright (C) 2026 Brandon Scott
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// Processes: ids, fork, execve, waitpid, process groups and sessions,
// users and groups, priorities.

#include "kernel.hpp"
#include "descriptors.hpp"
#include "timers.hpp"

#include <errno.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#include <mlibc/all-sysdeps.hpp>

namespace fpos {

namespace {

int credentials(struct fpos_credentials *out) {
	return call_checked(FPOS_CALL_GET_CREDENTIALS, out);
}

int set_user_ids(long real, long effective, long saved) {
	return call_checked(FPOS_CALL_SET_USER_IDS, real, effective, saved);
}

int set_group_ids(long real, long effective, long saved) {
	return call_checked(FPOS_CALL_SET_GROUP_IDS, real, effective, saved);
}

constexpr long unchanged = -1;

long id_or_unchanged(unsigned int id) {
	return id == (unsigned int)-1 ? unchanged : (long)id;
}

} // namespace

} // namespace fpos

namespace mlibc {

pid_t Sysdeps<GetPid>::operator()() {
	return static_cast<pid_t>(fpos::call(FPOS_CALL_GET_PROCESS_ID, -1));
}

pid_t Sysdeps<GetPpid>::operator()() {
	return static_cast<pid_t>(fpos::call(FPOS_CALL_GET_PARENT_PROCESS_ID));
}

int Sysdeps<Fork>::operator()(pid_t *child) {
	if (int e = fpos::call_into(child, FPOS_CALL_FORK_PROCESS))
		return e;
	if (*child == 0)
		fpos::forget_timers_after_fork();
	return 0;
}

int Sysdeps<Execve>::operator()(const char *path, char *const argv[], char *const envp[]) {
	static int close_list[fpos::descriptor_limit];
	struct fpos_execution execution = {};
	execution.path = path;
	execution.arguments = argv;
	execution.environment = envp;
	execution.close_on_exec = close_list;
	execution.close_on_exec_count = fpos::close_on_exec_descriptors(close_list, fpos::descriptor_limit);
	// Returns only when the program could not be started.
	return fpos::call_checked(FPOS_CALL_EXECUTE_PROGRAM, &execution);
}

int Sysdeps<Waitpid>::operator()(pid_t pid, int *status, int flags, struct rusage *ru, pid_t *ret_pid) {
	int ignored;
	long result = fpos::call(FPOS_CALL_WAIT_FOR_CHILD, pid, status ? status : &ignored, flags);
	if (int e = fpos::error_of(result))
		return e;
	if (ru)
		memset(ru, 0, sizeof(*ru));
	*ret_pid = static_cast<pid_t>(result);
	return 0;
}

int Sysdeps<GetPgid>::operator()(pid_t pid, pid_t *pgid) {
	return fpos::call_into(pgid, FPOS_CALL_GET_PROCESS_GROUP_OF, pid, 0);
}

int Sysdeps<GetSid>::operator()(pid_t pid, pid_t *sid) {
	return fpos::call_into(sid, FPOS_CALL_GET_PROCESS_GROUP_OF, pid, 1);
}

int Sysdeps<SetPgid>::operator()(pid_t pid, pid_t pgid) {
	return fpos::call_checked(FPOS_CALL_SET_PROCESS_GROUP, pid, pgid);
}

int Sysdeps<SetSid>::operator()(pid_t *sid) {
	return fpos::call_into(sid, FPOS_CALL_CREATE_SESSION);
}

uid_t Sysdeps<GetUid>::operator()() {
	struct fpos_credentials c;
	return fpos::credentials(&c) ? 0 : c.real_user_id;
}

uid_t Sysdeps<GetEuid>::operator()() {
	struct fpos_credentials c;
	return fpos::credentials(&c) ? 0 : c.effective_user_id;
}

gid_t Sysdeps<GetGid>::operator()() {
	struct fpos_credentials c;
	return fpos::credentials(&c) ? 0 : c.real_group_id;
}

gid_t Sysdeps<GetEgid>::operator()() {
	struct fpos_credentials c;
	return fpos::credentials(&c) ? 0 : c.effective_group_id;
}

int Sysdeps<GetResuid>::operator()(uid_t *ruid, uid_t *euid, uid_t *suid) {
	struct fpos_credentials c;
	if (int e = fpos::credentials(&c))
		return e;
	*ruid = c.real_user_id;
	*euid = c.effective_user_id;
	*suid = c.saved_user_id;
	return 0;
}

int Sysdeps<GetResgid>::operator()(gid_t *rgid, gid_t *egid, gid_t *sgid) {
	struct fpos_credentials c;
	if (int e = fpos::credentials(&c))
		return e;
	*rgid = c.real_group_id;
	*egid = c.effective_group_id;
	*sgid = c.saved_group_id;
	return 0;
}

int Sysdeps<SetUid>::operator()(uid_t uid) {
	struct fpos_credentials c;
	if (int e = fpos::credentials(&c))
		return e;
	// root sets all three; anyone else only the effective id.
	if (c.effective_user_id == 0)
		return fpos::set_user_ids(uid, uid, uid);
	return fpos::set_user_ids(fpos::unchanged, uid, fpos::unchanged);
}

int Sysdeps<SetEuid>::operator()(uid_t euid) {
	return fpos::set_user_ids(fpos::unchanged, euid, fpos::unchanged);
}

int Sysdeps<SetGid>::operator()(gid_t gid) {
	struct fpos_credentials c;
	if (int e = fpos::credentials(&c))
		return e;
	if (c.effective_user_id == 0)
		return fpos::set_group_ids(gid, gid, gid);
	return fpos::set_group_ids(fpos::unchanged, gid, fpos::unchanged);
}

int Sysdeps<SetEgid>::operator()(gid_t egid) {
	return fpos::set_group_ids(fpos::unchanged, egid, fpos::unchanged);
}

int Sysdeps<SetResuid>::operator()(uid_t ruid, uid_t euid, uid_t suid) {
	return fpos::set_user_ids(fpos::id_or_unchanged(ruid), fpos::id_or_unchanged(euid),
		fpos::id_or_unchanged(suid));
}

int Sysdeps<SetResgid>::operator()(gid_t rgid, gid_t egid, gid_t sgid) {
	return fpos::set_group_ids(fpos::id_or_unchanged(rgid), fpos::id_or_unchanged(egid),
		fpos::id_or_unchanged(sgid));
}

int Sysdeps<SetReuid>::operator()(uid_t ruid, uid_t euid) {
	return fpos::set_user_ids(fpos::id_or_unchanged(ruid), fpos::id_or_unchanged(euid), fpos::unchanged);
}

int Sysdeps<SetRegid>::operator()(gid_t rgid, gid_t egid) {
	return fpos::set_group_ids(fpos::id_or_unchanged(rgid), fpos::id_or_unchanged(egid), fpos::unchanged);
}

int Sysdeps<GetGroups>::operator()(size_t size, gid_t *list, int *ret) {
	struct fpos_credentials c;
	if (int e = fpos::credentials(&c))
		return e;
	if (size == 0) {
		*ret = (int)c.group_count;
		return 0;
	}
	if (size < c.group_count)
		return EINVAL;
	for (uint32_t i = 0; i < c.group_count; i++)
		list[i] = c.groups[i];
	*ret = (int)c.group_count;
	return 0;
}

int Sysdeps<SetGroups>::operator()(size_t size, const gid_t *list) {
	if (size > FPOS_MAXIMUM_SUPPLEMENTARY_GROUPS)
		return EINVAL;
	uint32_t groups[FPOS_MAXIMUM_SUPPLEMENTARY_GROUPS];
	for (size_t i = 0; i < size; i++)
		groups[i] = list[i];
	return fpos::call_checked(FPOS_CALL_SET_GROUPS, groups, size);
}

int Sysdeps<GetPriority>::operator()(int which, id_t who, int *value) {
	if (which != PRIO_PROCESS)
		return EINVAL;
	long result = fpos::call(FPOS_CALL_GET_PRIORITY, who);
	if (int e = fpos::error_of(result))
		return e;
	*value = 20 - (int)result;
	return 0;
}

int Sysdeps<SetPriority>::operator()(int which, id_t who, int prio) {
	if (which != PRIO_PROCESS)
		return EINVAL;
	return fpos::call_checked(FPOS_CALL_SET_PRIORITY, who, prio);
}

int Sysdeps<Nice>::operator()(int nice, int *new_nice) {
	int current;
	if (int e = Sysdeps<GetPriority>::operator()(PRIO_PROCESS, 0, &current))
		return e;
	int wanted = current + nice;
	if (wanted < -20)
		wanted = -20;
	if (wanted > 19)
		wanted = 19;
	if (int e = Sysdeps<SetPriority>::operator()(PRIO_PROCESS, 0, wanted))
		return e;
	*new_nice = wanted;
	return 0;
}

} // namespace mlibc
