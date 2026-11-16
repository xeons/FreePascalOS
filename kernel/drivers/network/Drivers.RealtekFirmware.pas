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
  Realtek PHY and MAC firmware patches (the rtl_nic/*.fw files of
  linux-firmware, read through Io.Firmware).

  A file is a little program of 32-bit operations. The newer files
  start with a header: a zero magic word, a 32-byte version string, the
  byte offset of the operations and their count, and a checksum byte
  chosen so that all the file's bytes add up to zero. Older files are
  only operations (their magic word, the first operation, is not
  zero).

  Each operation: bits 28-31 the op-code, bits 16-27 a register (or a
  count), bits 0-15 data. The program reads and writes registers of the
  PHY or, after "change to MAC" (the MCU), of the MAC, keeps the last
  value read, can compare it and skip or jump back (polling loops), and
  can wait some milliseconds. The register access itself is the chip
  driver's (TRealtekFirmwareAccess). Every operation is checked before
  anything runs, and a run stops after a bounded number of steps (a
  loop polling a register that never changes).
}
unit Drivers.RealtekFirmware;

{$mode objfpc}
{$pointermath on}

interface

type
  TFirmwareRead = function(Context: Pointer; RegisterNumber: LongWord): Word;
  TFirmwareWrite = procedure(Context: Pointer; RegisterNumber: LongWord; Value: Word);

  TRealtekFirmwareAccess = record
    Context: Pointer;
    PhyRead: TFirmwareRead;
    PhyWrite: TFirmwareWrite;
    MacRead: TFirmwareRead;
    MacWrite: TFirmwareWrite;
  end;

  PRealtekFirmware = ^TRealtekFirmware;
  TRealtekFirmware = record
    { The whole file (kernel memory, the firmware's own). }
    FileData: PByte;
    FileSize: QWord;
    Operations: PLongWord;
    OperationCount: LongWord;
    Version: array[0..31] of Char;
  end;

{ Checks the file and fills Firmware (which then owns Data). False if
  the file is malformed; Data is then still the caller's. }
function ParseRealtekFirmware(Data: PByte; Size: QWord; out Firmware: TRealtekFirmware): Boolean;
{ Runs the operations. False if the step limit was reached. Passive
  level (it may sleep). }
function RunRealtekFirmware(const Firmware: TRealtekFirmware; const Access: TRealtekFirmwareAccess): Boolean;

implementation

uses
  Runtime.Memory,
  Kernel.Scheduler;

const
  OperationBytes = 4;
  HeaderMagicOffset = 0;
  HeaderVersionOffset = 4;
  HeaderVersionBytes = 32;
  HeaderStartOffset = 36;
  HeaderCountOffset = 40;
  HeaderBytes = 45;
  MaximumSteps = 1000000;
  MaximumDelayMilliseconds = 1000;

  OperationPhyRead = $0;
  OperationDataOr = $1;
  OperationDataAnd = $2;
  OperationJumpBack = $3;
  OperationChangeTarget = $4;
  OperationClearReadCount = $7;
  OperationWrite = $8;
  OperationSkipIfReadCount = $9;
  OperationSkipIfEqual = $A;
  OperationSkipIfNotEqual = $B;
  OperationWritePrevious = $C;
  OperationSkip = $D;
  OperationDelay = $E;

function LittleEndian32(Data: PByte): LongWord;
begin
  Result := LongWord(Data[0]) or (LongWord(Data[1]) shl 8) or (LongWord(Data[2]) shl 16) or
    (LongWord(Data[3]) shl 24);
end;

function OperationAt(const Firmware: TRealtekFirmware; Index: LongWord): LongWord;
begin
  Result := LittleEndian32(PByte(Firmware.Operations) + QWord(Index) * OperationBytes);
end;

function FormatIsValid(Data: PByte; Size: QWord; out Firmware: TRealtekFirmware): Boolean;
var
  Index: QWord;
  Checksum: Byte;
  Start: QWord;
  Count: QWord;
  Character: Integer;
begin
  Result := False;
  ZeroMemory(@Firmware, SizeOf(Firmware));
  if Size < OperationBytes then
    Exit;
  if LittleEndian32(Data + HeaderMagicOffset) = 0 then
  begin
    if Size < HeaderBytes then
      Exit;
    Checksum := 0;
    for Index := 0 to Size - 1 do
      Checksum := Byte(Checksum + Data[Index]);
    if Checksum <> 0 then
      Exit;
    Start := LittleEndian32(Data + HeaderStartOffset);
    Count := LittleEndian32(Data + HeaderCountOffset);
    if (Start > Size) or (Count > (Size - Start) div OperationBytes) then
      Exit;
    for Character := 0 to HeaderVersionBytes - 2 do
      Firmware.Version[Character] := Char(Data[HeaderVersionOffset + Character]);
    Firmware.Version[HeaderVersionBytes - 1] := #0;
  end
  else
  begin
    if (Size mod OperationBytes) <> 0 then
      Exit;
    Start := 0;
    Count := Size div OperationBytes;
    Firmware.Version[0] := #0;
  end;
  Firmware.Operations := PLongWord(Data + Start);
  Firmware.OperationCount := LongWord(Count);
  Result := True;
end;

{ Every operation known and every jump inside the program. }
function OperationsAreValid(const Firmware: TRealtekFirmware): Boolean;
var
  Index: LongWord;
  Operation: LongWord;
  Data: LongWord;
  RegisterNumber: LongWord;
begin
  Result := False;
  if Firmware.OperationCount = 0 then
    Exit;
  for Index := 0 to Firmware.OperationCount - 1 do
  begin
    Operation := OperationAt(Firmware, Index);
    Data := Operation and $FFFF;
    RegisterNumber := (Operation shr 16) and $0FFF;
    case Operation shr 28 of
      OperationPhyRead, OperationDataOr, OperationDataAnd, OperationClearReadCount, OperationWrite,
      OperationWritePrevious, OperationDelay:
        ;
      OperationChangeTarget:
        if Data > 1 then
          Exit;
      OperationJumpBack:
        if RegisterNumber > Index then
          Exit;
      OperationSkipIfReadCount:
        if QWord(Index) + 2 >= Firmware.OperationCount then
          Exit;
      OperationSkipIfEqual, OperationSkipIfNotEqual, OperationSkip:
        if QWord(Index) + 1 + RegisterNumber >= Firmware.OperationCount then
          Exit;
    else
      Exit;
    end;
  end;
  Result := True;
end;

function ParseRealtekFirmware(Data: PByte; Size: QWord; out Firmware: TRealtekFirmware): Boolean;
begin
  Result := FormatIsValid(Data, Size, Firmware) and OperationsAreValid(Firmware);
  if Result then
  begin
    Firmware.FileData := Data;
    Firmware.FileSize := Size;
  end;
end;

function RunRealtekFirmware(const Firmware: TRealtekFirmware; const Access: TRealtekFirmwareAccess): Boolean;
var
  Index: Int64;
  Steps: LongWord;
  Operation: LongWord;
  Data: LongWord;
  RegisterNumber: LongWord;
  Previous: LongWord;
  ReadCount: LongWord;
  OnMac: Boolean;
begin
  Previous := 0;
  ReadCount := 0;
  OnMac := False;
  Index := 0;
  Steps := 0;
  while Index < Firmware.OperationCount do
  begin
    Inc(Steps);
    if Steps > MaximumSteps then
      Exit(False);
    Operation := OperationAt(Firmware, LongWord(Index));
    Data := Operation and $FFFF;
    RegisterNumber := (Operation shr 16) and $0FFF;
    case Operation shr 28 of
      OperationPhyRead:
        begin
          if OnMac then
            Previous := Access.MacRead(Access.Context, RegisterNumber)
          else
            Previous := Access.PhyRead(Access.Context, RegisterNumber);
          Inc(ReadCount);
        end;
      OperationDataOr:
        Previous := Previous or Data;
      OperationDataAnd:
        Previous := Previous and Data;
      OperationJumpBack:
        Index := Index - (RegisterNumber + 1);
      OperationChangeTarget:
        OnMac := Data <> 0;
      OperationClearReadCount:
        ReadCount := 0;
      OperationWrite:
        if OnMac then
          Access.MacWrite(Access.Context, RegisterNumber, Word(Data))
        else
          Access.PhyWrite(Access.Context, RegisterNumber, Word(Data));
      OperationSkipIfReadCount:
        if ReadCount = Data then
          Inc(Index);
      OperationSkipIfEqual:
        if Previous = Data then
          Index := Index + RegisterNumber;
      OperationSkipIfNotEqual:
        if Previous <> Data then
          Index := Index + RegisterNumber;
      OperationWritePrevious:
        if OnMac then
          Access.MacWrite(Access.Context, RegisterNumber, Word(Previous))
        else
          Access.PhyWrite(Access.Context, RegisterNumber, Word(Previous));
      OperationSkip:
        Index := Index + RegisterNumber;
      OperationDelay:
        if Data <= MaximumDelayMilliseconds then
          SleepMilliseconds(Data)
        else
          SleepMilliseconds(MaximumDelayMilliseconds);
    end;
    Inc(Index);
  end;
  Result := True;
end;

end.
