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

//
// The kernel the native boot stub loads: kernel.elf without its debug
// information (the Makefile strips it into the build directory, which
// is on the assembler's include path), page aligned inside the image.

    .section .payload, "a"
    .balign 4096
    .global KernelPayloadStart
    .global KernelPayloadEnd
KernelPayloadStart:
    .incbin "kernel-stripped.elf"
KernelPayloadEnd:
    .balign 4096
