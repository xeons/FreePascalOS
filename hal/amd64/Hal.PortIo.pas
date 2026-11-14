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

implementation

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
