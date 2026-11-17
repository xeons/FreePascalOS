{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  The system call interface between user programs and the kernel.

  Calling convention (x86-64): the "syscall" instruction with the call
  number in RAX and up to six arguments in RDI, RSI, RDX, R10, R8, R9.
  The result comes back in RAX: a value of zero or more is success, and a
  negative value is an error, minus one of the Error* codes below.
  RCX and R11 are lost (the instruction uses them); every other register
  is kept.

  Calling convention (AArch64): "svc #0" with the call number in X8 and up
  to six arguments in X0-X5; the result comes back in X0 with the same
  meaning. Every other general purpose register, SP, the condition flags
  and the floating point and SIMD registers are kept.

  Paths passed to the kernel are UTF-8 and may be absolute or relative to
  the process's current directory. "/" is the root of the system volume;
  other volumes are reached under "/volumes/<name>".

  This unit is compiled into both the kernel and libsystem, so the record
  layouts must only use explicitly sized types.
}
unit Abi.SystemCalls;

{$mode objfpc}

interface

{$include Abi.SystemCalls.inc}

implementation

end.
