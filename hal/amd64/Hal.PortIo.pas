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
  x86 I/O port access.

  The kernel is compiled with the System V calling convention, so the first
  argument arrives in RDI (EDI/DI) and the second in RSI (ESI/SI).
}
unit Hal.PortIo;

{$mode objfpc}
{$asmmode intel}

interface

function ReadPortByte(Port: Word): Byte;
function ReadPortWord(Port: Word): Word;
function ReadPortLongWord(Port: Word): LongWord;

procedure WritePortByte(Port: Word; Value: Byte);
procedure WritePortWord(Port: Word; Value: Word);
procedure WritePortLongWord(Port: Word; Value: LongWord);

{ Writes to an unused port, giving slow legacy devices time to settle. }
procedure WaitForPortIo;

{ False: the processor has I/O instructions, no window is needed (the
  AArch64 HAL maps one, Io.PciPortWindow). }
function PortIoNeedsWindow: Boolean;
function UsePortIoWindow(PhysicalBase, Length: QWord): Boolean;

implementation

function PortIoNeedsWindow: Boolean;
begin
  Result := False;
end;

function UsePortIoWindow(PhysicalBase, Length: QWord): Boolean;
begin
  Result := True;
end;

function ReadPortByte(Port: Word): Byte; assembler; nostackframe;
asm
  mov dx, di
  in al, dx
end;

function ReadPortWord(Port: Word): Word; assembler; nostackframe;
asm
  mov dx, di
  in ax, dx
end;

function ReadPortLongWord(Port: Word): LongWord; assembler; nostackframe;
asm
  mov dx, di
  in eax, dx
end;

procedure WritePortByte(Port: Word; Value: Byte); assembler; nostackframe;
asm
  mov dx, di
  mov al, sil
  out dx, al
end;

procedure WritePortWord(Port: Word; Value: Word); assembler; nostackframe;
asm
  mov dx, di
  mov ax, si
  out dx, ax
end;

procedure WritePortLongWord(Port: Word; Value: LongWord); assembler; nostackframe;
asm
  mov dx, di
  mov eax, esi
  out dx, eax
end;

procedure WaitForPortIo;
const
  UnusedDiagnosticPort = $80;
begin
  WritePortByte(UnusedDiagnosticPort, 0);
end;

end.
