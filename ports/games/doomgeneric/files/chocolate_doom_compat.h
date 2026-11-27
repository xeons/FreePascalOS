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
 * What Chocolate Doom 3.1's music files (i_oplmusic.c, midifile.c) use
 * that doomgeneric's older copy of its engine lacks, included before
 * each of them (-include): SDL's byte swapping, and three helpers of
 * its i_system.c and m_misc.c, which there only differ from the C
 * library's on Windows.
 */

#ifndef CHOCOLATE_DOOM_COMPAT_H
#define CHOCOLATE_DOOM_COMPAT_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "i_system.h"

#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
#define SDL_SwapBE16(value) ((uint16_t)(value))
#define SDL_SwapBE32(value) ((uint32_t)(value))
#else
#define SDL_SwapBE16(value) __builtin_bswap16((uint16_t)(value))
#define SDL_SwapBE32(value) __builtin_bswap32((uint32_t)(value))
#endif

#define M_fopen fopen
#define M_remove remove

static inline void *I_Realloc(void *block, size_t size)
{
	void *resized = realloc(block, size);
	if (size != 0 && resized == NULL)
		I_Error("I_Realloc: failed on reallocation of %zu bytes", size);
	return resized;
}

#endif
