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
  What the Raspberry Pi's firmware says about the board, through the
  VideoCore mailbox: model, revision, memory, serial number, Ethernet
  address, firmware revision, clock rates and the processor's
  temperature.

  The board revision word (new style, bit 23 set) packs:
    bits 0-3 the board's revision, 4-11 its type (11h: Pi 4 Model B,
    13h: Pi 400, 14h: Compute Module 4), 12-15 the processor (3:
    BCM2711), 16-19 the maker, 20-22 the memory (256 MiB shl n).

  GetBoardInformation answers a sysinfo-like query; WriteBoardInformation
  writes it to the kernel log (at start-up and the kernel debug shell's
  "board").
}
unit Drivers.RaspberryPiBoard;

{$mode objfpc}

interface

type
  TBoardInformation = record
    FirmwareRevision: LongWord;
    BoardRevision: LongWord;
    Serial: QWord;
    MacAddress: array[0..5] of Byte;
    HasMacAddress: Boolean;
    { Megabytes, from the revision word (0 if it is old style). }
    MemoryMegabytes: LongWord;
    ArmClockHertz: LongWord;
    CoreClockHertz: LongWord;
    Emmc2ClockHertz: LongWord;
    TemperatureMilliCelsius: LongWord;
  end;

{ False if there is no VideoCore mailbox (not a Raspberry Pi). }
function GetBoardInformation(out Information: TBoardInformation): Boolean;
{ "Raspberry Pi 4 Model B" and the like ("Raspberry Pi" if unknown). }
function BoardModelName(Revision: LongWord): PChar;
procedure WriteBoardInformation;

implementation

uses
  Runtime.Memory,
  Drivers.VideoCoreMailbox,
  Debug.Output;

const
  NewStyleRevision = LongWord(1) shl 23;

function BoardModelName(Revision: LongWord): PChar;
begin
  if (Revision and NewStyleRevision) = 0 then
    Exit('Raspberry Pi');
  case (Revision shr 4) and $FF of
    $08: Result := 'Raspberry Pi 3 Model B';
    $0D: Result := 'Raspberry Pi 3 Model B+';
    $0E: Result := 'Raspberry Pi 3 Model A+';
    $11: Result := 'Raspberry Pi 4 Model B';
    $13: Result := 'Raspberry Pi 400';
    $14: Result := 'Raspberry Pi Compute Module 4';
    $15: Result := 'Raspberry Pi Compute Module 4S';
    $17: Result := 'Raspberry Pi 5';
    $18: Result := 'Raspberry Pi Compute Module 5';
    $19: Result := 'Raspberry Pi 500';
  else
    Result := 'Raspberry Pi';
  end;
end;

function GetBoardInformation(out Information: TBoardInformation): Boolean;
begin
  ZeroMemory(@Information, SizeOf(Information));
  Result := VideoCoreMailboxIsAvailable;
  if not Result then
    Exit;
  QueryFirmwareWord(FirmwareTagFirmwareRevision, Information.FirmwareRevision);
  QueryFirmwareWord(FirmwareTagBoardRevision, Information.BoardRevision);
  QueryBoardSerial(Information.Serial);
  Information.HasMacAddress := QueryBoardMacAddress(@Information.MacAddress[0]);
  if (Information.BoardRevision and NewStyleRevision) <> 0 then
    Information.MemoryMegabytes := LongWord(256) shl ((Information.BoardRevision shr 20) and 7);
  QueryClockRate(FirmwareClockArm, Information.ArmClockHertz);
  QueryClockRate(FirmwareClockCore, Information.CoreClockHertz);
  QueryClockRate(FirmwareClockEmmc2, Information.Emmc2ClockHertz);
  QueryTemperature(Information.TemperatureMilliCelsius);
end;

procedure WriteMegahertz(Name: PChar; Hertz: LongWord);
begin
  if Hertz = 0 then
    Exit;
  DebugWrite(', ');
  DebugWrite(Name);
  DebugWrite(' ');
  DebugWriteDecimal(Hertz div 1000000);
  DebugWrite(' MHz');
end;

procedure WriteBoardInformation;
var
  Information: TBoardInformation;
  Index: Integer;
begin
  if not GetBoardInformation(Information) then
  begin
    DebugBeginMessage;
    DebugWriteTag('board');
    DebugWriteLine('no VideoCore mailbox (not a Raspberry Pi)');
    DebugEndMessage;
    Exit;
  end;
  DebugBeginMessage;
  DebugWriteTag('board');
  DebugWrite(BoardModelName(Information.BoardRevision));
  if (Information.BoardRevision and NewStyleRevision) <> 0 then
  begin
    DebugWrite(' rev 1.');
    DebugWriteDecimal(Information.BoardRevision and $F);
    DebugWrite(', ');
    DebugWriteDecimal(Information.MemoryMegabytes);
    DebugWrite(' MiB');
  end;
  DebugWrite(' (revision ');
  DebugWriteHex(Information.BoardRevision, 6);
  DebugWrite('), serial ');
  DebugWriteHex(Information.Serial, 16);
  DebugWriteLine('');
  DebugWriteTag('board');
  DebugWrite('firmware ');
  DebugWriteHex(Information.FirmwareRevision, 8);
  if Information.HasMacAddress then
  begin
    DebugWrite(', Ethernet address ');
    for Index := 0 to 5 do
    begin
      if Index > 0 then
        DebugWrite(':');
      DebugWriteHex(Information.MacAddress[Index], 2);
    end;
  end;
  WriteMegahertz('ARM', Information.ArmClockHertz);
  WriteMegahertz('core', Information.CoreClockHertz);
  WriteMegahertz('EMMC2', Information.Emmc2ClockHertz);
  if Information.TemperatureMilliCelsius <> 0 then
  begin
    DebugWrite(', ');
    DebugWriteDecimal(Information.TemperatureMilliCelsius div 1000);
    DebugWrite('.');
    DebugWriteDecimal((Information.TemperatureMilliCelsius mod 1000) div 100);
    DebugWrite(' C');
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

end.
