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
  I/O APIC driver.

  An I/O APIC receives interrupt lines from devices and sends each one to
  a local APIC as a message with a chosen vector. Each input ("global
  system interrupt", counted across all I/O APICs) has a redirection
  entry: vector, destination, polarity, trigger mode and a mask bit.

  The registers are reached indirectly: write a register number to
  IOREGSEL, then read or write IOWIN.
}
unit Hal.IoApic;

{$mode objfpc}
{$pointermath on}

interface

{ Adds an I/O APIC whose registers are at the virtual address Registers.
  All its inputs start masked. Returns False if the table is full. }
function AddIoApic(Registers: Pointer; GlobalInterruptBase: LongWord): Boolean;
function IoApicInputCount: LongWord;

{ Sends global interrupt Gsi to the local APIC DestinationApicId as
  Vector, and unmasks it. Returns False if no I/O APIC serves Gsi. }
function RouteGlobalInterrupt(Gsi: LongWord; Vector: Byte; DestinationApicId: Byte;
  ActiveLow: Boolean; LevelTriggered: Boolean): Boolean;
procedure MaskGlobalInterrupt(Gsi: LongWord);

implementation

const
  MaximumIoApics = 8;

  RegisterSelectOffset = $00;
  RegisterWindowOffset = $10;

  RegisterVersion = $01;
  RedirectionTableBase = $10;

  { Redirection entry, low 32 bits. }
  EntryMasked = $00010000;
  EntryLevelTriggered = $00008000;
  EntryActiveLow = $00002000;
  { Delivery mode fixed (0) and physical destination (0) are the defaults. }

type
  TIoApic = record
    Registers: PByte;
    GlobalInterruptBase: LongWord;
    InputCount: LongWord;
  end;

var
  IoApics: array[0..MaximumIoApics - 1] of TIoApic;
  IoApicTotal: Integer = 0;

function ReadRegister(const IoApic: TIoApic; Register: LongWord): LongWord;
begin
  PLongWord(IoApic.Registers + RegisterSelectOffset)^ := Register;
  Result := PLongWord(IoApic.Registers + RegisterWindowOffset)^;
end;

procedure WriteRegister(const IoApic: TIoApic; Register: LongWord; Value: LongWord);
begin
  PLongWord(IoApic.Registers + RegisterSelectOffset)^ := Register;
  PLongWord(IoApic.Registers + RegisterWindowOffset)^ := Value;
end;

function AddIoApic(Registers: Pointer; GlobalInterruptBase: LongWord): Boolean;
var
  IoApic: ^TIoApic;
  Input: LongWord;
begin
  if IoApicTotal = MaximumIoApics then
    Exit(False);
  IoApic := @IoApics[IoApicTotal];
  IoApic^.Registers := PByte(Registers);
  IoApic^.GlobalInterruptBase := GlobalInterruptBase;
  { Version register bits 16-23: the highest redirection entry. }
  IoApic^.InputCount := ((ReadRegister(IoApic^, RegisterVersion) shr 16) and $FF) + 1;
  Input := 0;
  while Input < IoApic^.InputCount do
  begin
    WriteRegister(IoApic^, RedirectionTableBase + 2 * Input, EntryMasked);
    WriteRegister(IoApic^, RedirectionTableBase + 2 * Input + 1, 0);
    Inc(Input);
  end;
  Inc(IoApicTotal);
  Result := True;
end;

function IoApicInputCount: LongWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to IoApicTotal - 1 do
    Result := Result + IoApics[Index].InputCount;
end;

{ Finds the I/O APIC serving Gsi and the input number on it. }
function FindIoApic(Gsi: LongWord; out Index: Integer; out Input: LongWord): Boolean;
var
  Candidate: Integer;
begin
  for Candidate := 0 to IoApicTotal - 1 do
    if (Gsi >= IoApics[Candidate].GlobalInterruptBase) and
       (Gsi < IoApics[Candidate].GlobalInterruptBase + IoApics[Candidate].InputCount) then
    begin
      Index := Candidate;
      Input := Gsi - IoApics[Candidate].GlobalInterruptBase;
      Exit(True);
    end;
  Index := -1;
  Input := 0;
  Result := False;
end;

function RouteGlobalInterrupt(Gsi: LongWord; Vector: Byte; DestinationApicId: Byte;
  ActiveLow: Boolean; LevelTriggered: Boolean): Boolean;
var
  Index: Integer;
  Input: LongWord;
  Low: LongWord;
begin
  if not FindIoApic(Gsi, Index, Input) then
    Exit(False);
  Low := Vector;
  if ActiveLow then
    Low := Low or EntryActiveLow;
  if LevelTriggered then
    Low := Low or EntryLevelTriggered;
  { Destination first, so the entry is complete when it is unmasked. }
  WriteRegister(IoApics[Index], RedirectionTableBase + 2 * Input + 1, LongWord(DestinationApicId) shl 24);
  WriteRegister(IoApics[Index], RedirectionTableBase + 2 * Input, Low);
  Result := True;
end;

procedure MaskGlobalInterrupt(Gsi: LongWord);
var
  Index: Integer;
  Input: LongWord;
begin
  if FindIoApic(Gsi, Index, Input) then
    WriteRegister(IoApics[Index], RedirectionTableBase + 2 * Input, EntryMasked);
end;

end.
