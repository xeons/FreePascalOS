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

/* dlopen and dlsym of libctestplugin.so (through mlibc's ld.so). */

#include <dlfcn.h>

#include "ctest.h"

void test_dlopen(void) {
	void *plugin = dlopen("libctestplugin.so", RTLD_NOW);
	CHECK(plugin != NULL, "dlopen: %s", dlerror());
	if (!plugin)
		return;
	int (*add)(int, int) = (int (*)(int, int))dlsym(plugin, "plugin_add");
	int *value = (int *)dlsym(plugin, "plugin_value");
	CHECK(add != NULL && value != NULL, "dlsym");
	if (add && value) {
		CHECK(add(40, 2) == 42, "plugin_add");
		CHECK(*value == 1234, "plugin_value %d", *value);
	}
	CHECK(dlsym(plugin, "no_such_symbol") == NULL, "missing symbol");
	CHECK(dlclose(plugin) == 0, "dlclose");
	CHECK(dlopen("libnothere.so", RTLD_NOW) == NULL, "missing library");
}
