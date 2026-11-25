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
 * The terminal and descriptor ioctls the FreePascalOS sysdeps take
 * (generic/terminal.cpp), with the Linux numbers, as there are no Linux
 * kernel headers to bring them.
 */
#ifndef _ABIBITS_IOCTLS_H
#define _ABIBITS_IOCTLS_H

#ifndef TCGETS
#define TCGETS 0x5401
#endif
#ifndef TCSETS
#define TCSETS 0x5402
#endif
#ifndef TCSETSW
#define TCSETSW 0x5403
#endif
#ifndef TCSETSF
#define TCSETSF 0x5404
#endif
#ifndef TIOCSCTTY
#define TIOCSCTTY 0x540E
#endif
#ifndef TIOCGPGRP
#define TIOCGPGRP 0x540F
#endif
#ifndef TIOCSPGRP
#define TIOCSPGRP 0x5410
#endif
#ifndef TIOCOUTQ
#define TIOCOUTQ 0x5411
#endif
#ifndef TIOCGWINSZ
#define TIOCGWINSZ 0x5413
#endif
#ifndef TIOCSWINSZ
#define TIOCSWINSZ 0x5414
#endif
#ifndef FIONREAD
#define FIONREAD 0x541B
#endif
#ifndef TIOCINQ
#define TIOCINQ FIONREAD
#endif
#ifndef FIONBIO
#define FIONBIO 0x5421
#endif
#ifndef TIOCNOTTY
#define TIOCNOTTY 0x5422
#endif
#ifndef FIONCLEX
#define FIONCLEX 0x5450
#endif
#ifndef FIOCLEX
#define FIOCLEX 0x5451
#endif

#endif /* _ABIBITS_IOCTLS_H */
