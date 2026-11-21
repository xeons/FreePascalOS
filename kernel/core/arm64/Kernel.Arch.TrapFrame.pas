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
  Register state saved on entry to an exception or interrupt on AArch64.

  The exception entry code (ExceptionVectors.s) builds it on the kernel
  stack (SP_EL1): the general purpose registers, the interrupted stack
  pointer (SP_EL0 for user mode, the kernel's own otherwise), the return
  address and saved program state, and the syndrome and fault address of
  a synchronous exception. Vector and ErrorCode are filled in by the
  Pascal side: the kernel's vector number for what happened (see
  Hal.InterruptVectors and Kernel.Arch.Exceptions) and, for a page
  fault, the kernel's fault code (Kernel.Arch.Exceptions).

  The offsets are fixed: ExceptionVectors.s uses them.
}
unit Kernel.Arch.TrapFrame;

{$mode objfpc}

interface

type
  TTrapFrame = record
    X: array[0..30] of QWord;    { 0 }
    Sp: QWord;                   { 248 }
    Elr: QWord;                  { 256 }
    Spsr: QWord;                 { 264 }
    Esr: QWord;                  { 272 }
    Far: QWord;                  { 280 }
    Vector: QWord;               { 288 }
    ErrorCode: QWord;            { 296 }
  end;                           { 304 bytes, a multiple of 16 }
  PTrapFrame = ^TTrapFrame;

function TrapFrameVector(Frame: PTrapFrame): Byte;
function TrapFrameInstructionPointer(Frame: PTrapFrame): QWord;
{ The stack pointer of the interrupted code. }
function TrapFrameStackPointer(Frame: PTrapFrame): QWord;
{ The frame pointer of the interrupted code, where its back trace starts. }
function TrapFrameFramePointer(Frame: PTrapFrame): QWord;

implementation

function TrapFrameVector(Frame: PTrapFrame): Byte;
begin
  Result := Byte(Frame^.Vector);
end;

function TrapFrameInstructionPointer(Frame: PTrapFrame): QWord;
begin
  Result := Frame^.Elr;
end;

function TrapFrameStackPointer(Frame: PTrapFrame): QWord;
begin
  Result := Frame^.Sp;
end;

function TrapFrameFramePointer(Frame: PTrapFrame): QWord;
begin
  Result := Frame^.X[29];
end;

end.
