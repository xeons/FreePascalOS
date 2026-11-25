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
  Kernel debug log.

  Text written here goes to the serial port, once it is initialized to
  the framebuffer console, and to the in-memory log (Debug.LogRing) that
  the network log sends on. A lock taken at HighLevel keeps lines from
  different processors and interrupt handlers from interleaving.

  Messages are built from several calls, for example:

    DebugWriteTag('memory');
    DebugWrite('free pages: ');
    DebugWriteDecimal(FreePageCount);
    DebugWriteLine('');

  Long messages should be bracketed by DebugBeginMessage/DebugEndMessage
  so they are printed as a unit.
}
unit Debug.Output;

{$mode objfpc}

interface

uses
  Boot.Information,
  Debug.FramebufferConsole;

procedure InitializeDebugOutput;
procedure AttachFramebufferConsole(const Framebuffer: TFramebufferInformation;
  FramebufferVirtualBase: Pointer);

procedure DebugBeginMessage;
procedure DebugEndMessage;

procedure DebugWriteCharacter(Character: Char);
procedure DebugWrite(Text: PChar);
procedure DebugWriteLine(Text: PChar);
procedure DebugWriteDecimal(Value: QWord);
procedure DebugWriteSignedDecimal(Value: Int64);
procedure DebugWriteHex(Value: QWord; MinimumDigits: LongWord);
procedure DebugWriteAddress(Value: QWord);

{ Writes a byte count in the largest unit that keeps it whole, e.g. 64 MiB. }
procedure DebugWriteSize(ByteCount: QWord);

{ Writes "[Component] " with the component name highlighted. }
procedure DebugWriteTag(Component: PChar);

procedure DebugSetColor(const Color: TColor);
procedure DebugResetColor;

type
  TDebugOutputCopy = procedure(Character: Char);

{ Every character written from now on is also given to Copy (nil: to
  nobody), with the output lock held, at HighLevel: it must only store
  it. Used by the network debug shell to see what a command writes. }
procedure SetDebugOutputCopy(Copy: TDebugOutputCopy);

{ Used only by the panic path: forgets any lock holder (who may be the
  very code that crashed) so the panic message can always be printed. }
procedure DebugForceUnlockForPanic;

implementation

uses
  Runtime.Text,
  Runtime.Atomic,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Kernel.Processors,
  Hal.SerialPort,
  Debug.LogRing;

var
  OutputLock: TSpinLock;
  LockPreviousLevel: TPriorityLevel;
  LockNestingDepth: LongWord;
  { The number of the processor holding the lock, plus one; 0 while it
    is free. Written only by the holder (set after taking the lock,
    cleared before releasing it), so a processor reads its own number
    here only while it holds the lock itself: its own writes are never
    seen out of order by itself, however stale the others' look. }
  LockHolder: PtrUInt;
  OutputCopy: TDebugOutputCopy = nil;

procedure InitializeDebugOutput;
begin
  InitializeSpinLock(OutputLock);
  LockNestingDepth := 0;
  LockHolder := 0;
  InitializeSerialPort;
end;

procedure AttachFramebufferConsole(const Framebuffer: TFramebufferInformation;
  FramebufferVirtualBase: Pointer);
begin
  InitializeFramebufferConsole(Framebuffer, FramebufferVirtualBase);
end;

{ The lock is recursive on purpose: DebugBeginMessage takes it for a whole
  message and the individual write calls inside take it again. The holder
  runs at HighLevel, so nothing else on its processor gets here; the
  holder's processor number (LockHolder) tells a nested call apart from
  another processor, which must wait. }
procedure DebugBeginMessage;
var
  PreviousLevel: TPriorityLevel;
  Number: LongInt;
begin
  { At HighLevel first, so this cannot move to another processor between
    reading its number and taking the lock. }
  PreviousLevel := RaisePriorityLevel(HighLevel);
  Number := LongInt(CurrentProcessorIndexOrZero);
  if AtomicLoad(LockHolder) = PtrUInt(Number) + 1 then
  begin
    Inc(LockNestingDepth);
    LowerPriorityLevel(PreviousLevel);
    Exit;
  end;

  AcquireSpinLockAtCurrentLevel(OutputLock);
  LockPreviousLevel := PreviousLevel;
  AtomicStore(LockHolder, PtrUInt(Number) + 1);
  LockNestingDepth := 1;
end;

procedure DebugEndMessage;
begin
  if LockNestingDepth = 0 then
    Exit;
  Dec(LockNestingDepth);
  if LockNestingDepth = 0 then
  begin
    AtomicStore(LockHolder, 0);
    ReleaseSpinLock(OutputLock, LockPreviousLevel);
  end;
end;

procedure SetDebugOutputCopy(Copy: TDebugOutputCopy);
begin
  DebugBeginMessage;
  OutputCopy := Copy;
  DebugEndMessage;
end;

procedure DebugForceUnlockForPanic;
begin
  OutputCopy := nil;
  LockNestingDepth := 0;
  AtomicStore(LockHolder, 0);
  InitializeSpinLock(OutputLock);
  ForceUnlockLogRingForPanic;
end;

procedure WriteCharacterToAllOutputs(Character: Char);
begin
  WriteSerialCharacter(Character);
  ConsoleWriteCharacter(Character);
  CaptureLogCharacter(Character);
  if Assigned(OutputCopy) then
    OutputCopy(Character);
end;

procedure DebugWriteCharacter(Character: Char);
begin
  DebugBeginMessage;
  WriteCharacterToAllOutputs(Character);
  DebugEndMessage;
end;

procedure DebugWrite(Text: PChar);
begin
  if Text = nil then
    Exit;
  DebugBeginMessage;
  while Text^ <> #0 do
  begin
    WriteCharacterToAllOutputs(Text^);
    Inc(Text);
  end;
  DebugEndMessage;
end;

procedure DebugWriteLine(Text: PChar);
begin
  DebugBeginMessage;
  DebugWrite(Text);
  WriteCharacterToAllOutputs(#10);
  DebugEndMessage;
end;

procedure DebugWriteDecimal(Value: QWord);
var
  NumberText: TNumberText;
begin
  DebugWrite(FormatDecimal(Value, NumberText));
end;

procedure DebugWriteSignedDecimal(Value: Int64);
var
  NumberText: TNumberText;
begin
  DebugWrite(FormatSignedDecimal(Value, NumberText));
end;

procedure DebugWriteHex(Value: QWord; MinimumDigits: LongWord);
var
  NumberText: TNumberText;
begin
  DebugWrite(FormatHexadecimal(Value, MinimumDigits, NumberText));
end;

procedure DebugWriteAddress(Value: QWord);
begin
  DebugBeginMessage;
  DebugWrite('0x');
  DebugWriteHex(Value, 16);
  DebugEndMessage;
end;

procedure DebugWriteSize(ByteCount: QWord);
const
  Kibibyte = QWord(1024);
  Mebibyte = Kibibyte * 1024;
  Gibibyte = Mebibyte * 1024;
begin
  DebugBeginMessage;
  if (ByteCount >= Gibibyte) and (ByteCount mod Gibibyte = 0) then
  begin
    DebugWriteDecimal(ByteCount div Gibibyte);
    DebugWrite(' GiB');
  end
  else if ByteCount >= Mebibyte then
  begin
    DebugWriteDecimal(ByteCount div Mebibyte);
    DebugWrite(' MiB');
  end
  else if ByteCount >= Kibibyte then
  begin
    DebugWriteDecimal(ByteCount div Kibibyte);
    DebugWrite(' KiB');
  end
  else
  begin
    DebugWriteDecimal(ByteCount);
    DebugWrite(' bytes');
  end;
  DebugEndMessage;
end;

procedure DebugSetColor(const Color: TColor);
begin
  ConsoleSetForegroundColor(Color);
end;

procedure DebugResetColor;
begin
  ConsoleSetForegroundColor(ColorLightGray);
end;

procedure DebugWriteTag(Component: PChar);
begin
  DebugBeginMessage;
  DebugWrite('[');
  DebugSetColor(ColorCyan);
  DebugWrite(Component);
  DebugResetColor;
  DebugWrite('] ');
  DebugEndMessage;
end;

end.
