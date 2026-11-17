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
  UEFI runtime services: the part of the table the loader uses (the
  time of day).
}
unit Uefi.RuntimeServices;

{$mode objfpc}

interface

uses
  Uefi.Base;

const
  { TEfiTime.TimeZone when the time is local time of no known zone. }
  EfiUnspecifiedTimeZone = $07FF;

type
  TEfiTime = record
    Year: Word;          { 1900 - 9999 }
    Month: Byte;         { 1 - 12 }
    Day: Byte;           { 1 - 31 }
    Hour: Byte;
    Minute: Byte;
    Second: Byte;
    Pad1: Byte;
    Nanosecond: LongWord;
    { Minutes from UTC (-1440 .. 1440), or EfiUnspecifiedTimeZone. }
    TimeZone: SmallInt;
    Daylight: Byte;
    Pad2: Byte;
  end;
  PEfiTime = ^TEfiTime;

  TEfiGetTime = function(Time: PEfiTime; Capabilities: Pointer): TEfiStatus;

  TEfiRuntimeServices = record
    Header: TEfiTableHeader;
    GetTime: TEfiGetTime;
    SetTime: Pointer;
    GetWakeupTime: Pointer;
    SetWakeupTime: Pointer;
    { The rest (variables, virtual addressing, reset) is not used. }
  end;
  PEfiRuntimeServices = ^TEfiRuntimeServices;

implementation

end.
