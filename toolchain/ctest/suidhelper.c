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

/* ctest's set-user-ID helper (/usr/bin/ctest-suid, owned by root, mode
   4755 on the system disk):

     --report-euid   exits 0 (the harmless program of ctest's exec race)
     --secure        run by a user: AT_SECURE is set, the auxiliary vector
                     has the credentials it runs with, and LD_PRELOAD did
                     not load libctestplugin.so; exits 0 if so
     --not-secure    run by root: AT_SECURE is clear; exits 0 if so */

#include <dlfcn.h>
#include <string.h>
#include <sys/auxv.h>
#include <unistd.h>

int main(int argc, char **argv) {
	if (argc < 2 || strcmp(argv[1], "--report-euid") == 0)
		return 0;
	if (strcmp(argv[1], "--secure") == 0) {
		if (getauxval(AT_SECURE) != 1)
			return 1;
		if (getauxval(AT_EUID) != 0 || getauxval(AT_UID) == 0 || geteuid() != 0 || getuid() == 0)
			return 2;
		/* Preloaded, the plugin's symbols would be found everywhere. */
		if (dlsym(RTLD_DEFAULT, "plugin_add") != NULL)
			return 3;
		return 0;
	}
	if (strcmp(argv[1], "--not-secure") == 0)
		return getauxval(AT_SECURE) == 0 && geteuid() == 0 ? 0 : 1;
	return 9;
}
