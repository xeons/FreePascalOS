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

  Text written here goes to the serial port and, once it is initialized,
  to the framebuffer console. A lock taken at HighLevel keeps lines from
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

{ Used only by the panic path: forgets any lock holder (who may be the
  very code that crashed) so the panic message can always be printed. }
procedure DebugForceUnlockForPanic;

implementation

uses
  Runtime.Text,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Kernel.Processors,
  Hal.SerialPort;

var
  OutputLock: TSpinLock;
  LockPreviousLevel: TPriorityLevel;
  LockNestingDepth: LongWord;
  { The processor holding the lock (meaningful while it is held). }
  LockOwner: LongInt;

procedure InitializeDebugOutput;
begin
  InitializeSpinLock(OutputLock);
  LockNestingDepth := 0;
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
  owner's processor number tells a nested call apart from another
  processor, which must wait. }
procedure DebugBeginMessage;
var
  PreviousLevel: TPriorityLevel;
  Number: LongInt;
begin
  { At HighLevel first, so this cannot move to another processor between
    reading its number and taking the lock. }
  PreviousLevel := RaisePriorityLevel(HighLevel);
  Number := LongInt(CurrentProcessorIndexOrZero);
  if (LockNestingDepth > 0) and (LockOwner = Number) then
  begin
    Inc(LockNestingDepth);
    LowerPriorityLevel(PreviousLevel);
    Exit;
  end;

  AcquireSpinLockAtCurrentLevel(OutputLock);
  LockPreviousLevel := PreviousLevel;
  LockOwner := Number;
  LockNestingDepth := 1;
end;

procedure DebugEndMessage;
begin
  if LockNestingDepth = 0 then
    Exit;
  Dec(LockNestingDepth);
  if LockNestingDepth = 0 then
    ReleaseSpinLock(OutputLock, LockPreviousLevel);
end;

procedure DebugForceUnlockForPanic;
begin
  LockNestingDepth := 0;
  InitializeSpinLock(OutputLock);
end;

procedure WriteCharacterToAllOutputs(Character: Char);
begin
  WriteSerialCharacter(Character);
  ConsoleWriteCharacter(Character);
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
