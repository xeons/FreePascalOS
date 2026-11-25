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
  CMOS real-time clock (the battery backed clock of PC compatibles).

  Read once at startup to find the current date and time; the kernel then
  keeps time by counting clock ticks. The clock is assumed to hold UTC.
  Setting the date and time (CallSetWallClock) writes it back, so the
  next boot starts from it.

  The alarm (a wake source from suspend to RAM through ACPI's RTC
  event): the seconds, minutes and hours alarm registers, matched every
  day, so an alarm must be due within 24 hours (no day of month alarm
  register is assumed). Setting it turns on the alarm interrupt enable
  (AIE) in status register B; status register C says (and clears) that
  it fired.
}
unit Hal.RealTimeClock;

{$mode objfpc}

interface

uses
  Runtime.Time;

{ Returns the current time, or zero if the clock could not be read. }
function ReadRealTimeClock: TUnixTime;
{ Sets the clock to Time (whole seconds, UTC), in the clock's own
  format (BCD or binary, 12 or 24 hours, as status register B says). }
procedure WriteRealTimeClock(Time: TUnixTime);
{ Sets the alarm for Time (UTC, within a day from now by the clock's own
  reading); 0 turns it off. False if Time is past or too far. }
function SetRealTimeClockAlarm(Time: TUnixTime): Boolean;
{ True if the alarm went off since the last call (reading clears it). }
function RealTimeClockAlarmFired: Boolean;

implementation

uses
  Hal.PortIo;

const
  CmosAddressPort = $70;
  CmosDataPort = $71;
  { Keeps NMIs enabled while selecting a register. }
  NmiEnabledMask = $7F;

  RegisterSeconds = $00;
  RegisterMinutes = $02;
  RegisterHours = $04;
  RegisterDayOfMonth = $07;
  RegisterMonth = $08;
  RegisterYear = $09;
  RegisterStatusA = $0A;
  RegisterStatusB = $0B;
  RegisterStatusC = $0C;
  RegisterCentury = $32;
  RegisterSecondsAlarm = $01;
  RegisterMinutesAlarm = $03;
  RegisterHoursAlarm = $05;
  StatusBAlarmInterrupt = $20;
  StatusCAlarmFlag = $20;
  SecondsPerDay = 86400;

  StatusAUpdateInProgress = $80;
  { Holds the clock still while it is being set. }
  StatusBSetClock = $80;
  StatusBBinaryMode = $04;
  StatusB24HourMode = $02;
  HourPmFlag = $80;

  MaximumAttempts = 10;

type
  TClockReading = record
    Second: Byte;
    Minute: Byte;
    Hour: Byte;
    Day: Byte;
    Month: Byte;
    Year: Byte;
    Century: Byte;
  end;

function ReadCmosRegister(Register: Byte): Byte;
begin
  WritePortByte(CmosAddressPort, Register and NmiEnabledMask);
  Result := ReadPortByte(CmosDataPort);
end;

procedure WriteCmosRegister(Register: Byte; Value: Byte);
begin
  WritePortByte(CmosAddressPort, Register and NmiEnabledMask);
  WritePortByte(CmosDataPort, Value);
end;

procedure WaitWhileUpdating;
var
  Attempt: Integer;
begin
  for Attempt := 1 to 100000 do
  begin
    if (ReadCmosRegister(RegisterStatusA) and StatusAUpdateInProgress) = 0 then
      Exit;
  end;
end;

procedure TakeReading(out Reading: TClockReading);
begin
  WaitWhileUpdating;
  Reading.Second := ReadCmosRegister(RegisterSeconds);
  Reading.Minute := ReadCmosRegister(RegisterMinutes);
  Reading.Hour := ReadCmosRegister(RegisterHours);
  Reading.Day := ReadCmosRegister(RegisterDayOfMonth);
  Reading.Month := ReadCmosRegister(RegisterMonth);
  Reading.Year := ReadCmosRegister(RegisterYear);
  Reading.Century := ReadCmosRegister(RegisterCentury);
end;

function ReadingsAreEqual(const First, Second: TClockReading): Boolean;
begin
  Result := (First.Second = Second.Second) and (First.Minute = Second.Minute) and
    (First.Hour = Second.Hour) and (First.Day = Second.Day) and
    (First.Month = Second.Month) and (First.Year = Second.Year) and
    (First.Century = Second.Century);
end;

function BcdToBinary(Value: Byte): Byte;
begin
  Result := (Value shr 4) * 10 + (Value and $0F);
end;

function BinaryToBcd(Value: Byte): Byte;
begin
  Result := ((Value div 10) shl 4) or (Value mod 10);
end;

function ReadRealTimeClock: TUnixTime;
var
  Reading: TClockReading;
  Confirmation: TClockReading;
  Attempt: Integer;
  StatusB: Byte;
  IsPm: Boolean;
  Year: LongInt;
begin
  { Read until two consecutive readings agree, so an update in the middle
    of a reading cannot produce a mixed result. }
  TakeReading(Reading);
  for Attempt := 1 to MaximumAttempts do
  begin
    TakeReading(Confirmation);
    if ReadingsAreEqual(Reading, Confirmation) then
      Break;
    Reading := Confirmation;
  end;

  StatusB := ReadCmosRegister(RegisterStatusB);
  IsPm := (Reading.Hour and HourPmFlag) <> 0;
  Reading.Hour := Reading.Hour and not HourPmFlag;

  if (StatusB and StatusBBinaryMode) = 0 then
  begin
    Reading.Second := BcdToBinary(Reading.Second);
    Reading.Minute := BcdToBinary(Reading.Minute);
    Reading.Hour := BcdToBinary(Reading.Hour);
    Reading.Day := BcdToBinary(Reading.Day);
    Reading.Month := BcdToBinary(Reading.Month);
    Reading.Year := BcdToBinary(Reading.Year);
    Reading.Century := BcdToBinary(Reading.Century);
  end;

  if ((StatusB and StatusB24HourMode) = 0) then
  begin
    if Reading.Hour = 12 then
      Reading.Hour := 0;
    if IsPm then
      Reading.Hour := Reading.Hour + 12;
  end;

  { The century register is not guaranteed to exist. }
  if (Reading.Century >= 19) and (Reading.Century <= 30) then
    Year := LongInt(Reading.Century) * 100 + Reading.Year
  else
    Year := 2000 + Reading.Year;

  if (Reading.Month < 1) or (Reading.Month > 12) or (Reading.Day < 1) or (Reading.Day > 31) then
    Exit(0);

  Result := CalendarToUnixTime(Year, Reading.Month, Reading.Day,
    Reading.Hour, Reading.Minute, Reading.Second);
end;

procedure WriteRealTimeClock(Time: TUnixTime);
var
  Year, Month, Day, Hour, Minute, Second: LongInt;
  Reading: TClockReading;
  StatusB: Byte;
  IsPm: Boolean;
begin
  UnixTimeToCalendar(Time, Year, Month, Day, Hour, Minute, Second);
  if (Year < 2000) or (Year > 2099) then
    Exit;
  Reading.Second := Second;
  Reading.Minute := Minute;
  Reading.Day := Day;
  Reading.Month := Month;
  Reading.Year := Year mod 100;
  Reading.Century := Year div 100;
  StatusB := ReadCmosRegister(RegisterStatusB);
  { In 12 hour mode the hours are 1-12 with the top bit for PM. }
  IsPm := False;
  if (StatusB and StatusB24HourMode) = 0 then
  begin
    IsPm := Hour >= 12;
    Hour := Hour mod 12;
    if Hour = 0 then
      Hour := 12;
  end;
  Reading.Hour := Hour;
  if (StatusB and StatusBBinaryMode) = 0 then
  begin
    Reading.Second := BinaryToBcd(Reading.Second);
    Reading.Minute := BinaryToBcd(Reading.Minute);
    Reading.Hour := BinaryToBcd(Reading.Hour);
    Reading.Day := BinaryToBcd(Reading.Day);
    Reading.Month := BinaryToBcd(Reading.Month);
    Reading.Year := BinaryToBcd(Reading.Year);
    Reading.Century := BinaryToBcd(Reading.Century);
  end;
  if IsPm then
    Reading.Hour := Reading.Hour or HourPmFlag;

  { The clock stops counting while SET is on, so no update lands
    between two of the registers. }
  WriteCmosRegister(RegisterStatusB, StatusB or StatusBSetClock);
  WriteCmosRegister(RegisterSeconds, Reading.Second);
  WriteCmosRegister(RegisterMinutes, Reading.Minute);
  WriteCmosRegister(RegisterHours, Reading.Hour);
  WriteCmosRegister(RegisterDayOfMonth, Reading.Day);
  WriteCmosRegister(RegisterMonth, Reading.Month);
  WriteCmosRegister(RegisterYear, Reading.Year);
  WriteCmosRegister(RegisterCentury, Reading.Century);
  WriteCmosRegister(RegisterStatusB, StatusB and not StatusBSetClock);
end;

{ A value for a register in the clock's own format. }
function ClockFormat(Value: Byte; StatusB: Byte): Byte;
begin
  if (StatusB and StatusBBinaryMode) = 0 then
    Result := BinaryToBcd(Value)
  else
    Result := Value;
end;

function SetRealTimeClockAlarm(Time: TUnixTime): Boolean;
var
  Now: TUnixTime;
  Year, Month, Day, Hour, Minute, Second: LongInt;
  StatusB: Byte;
  IsPm: Boolean;
  HourValue: Byte;
begin
  StatusB := ReadCmosRegister(RegisterStatusB);
  if Time = 0 then
  begin
    WriteCmosRegister(RegisterStatusB, StatusB and not StatusBAlarmInterrupt);
    ReadCmosRegister(RegisterStatusC);
    Exit(True);
  end;
  Now := ReadRealTimeClock;
  if (Now = 0) or (Time <= Now) or (Time - Now >= SecondsPerDay) then
    Exit(False);
  UnixTimeToCalendar(Time, Year, Month, Day, Hour, Minute, Second);
  IsPm := False;
  if (StatusB and StatusB24HourMode) = 0 then
  begin
    IsPm := Hour >= 12;
    Hour := Hour mod 12;
    if Hour = 0 then
      Hour := 12;
  end;
  HourValue := ClockFormat(Byte(Hour), StatusB);
  if IsPm then
    HourValue := HourValue or HourPmFlag;
  WriteCmosRegister(RegisterStatusB, StatusB and not StatusBAlarmInterrupt);
  WriteCmosRegister(RegisterSecondsAlarm, ClockFormat(Byte(Second), StatusB));
  WriteCmosRegister(RegisterMinutesAlarm, ClockFormat(Byte(Minute), StatusB));
  WriteCmosRegister(RegisterHoursAlarm, HourValue);
  { A flag left from before would read as this alarm. }
  ReadCmosRegister(RegisterStatusC);
  WriteCmosRegister(RegisterStatusB, StatusB or StatusBAlarmInterrupt);
  Result := True;
end;

function RealTimeClockAlarmFired: Boolean;
begin
  Result := (ReadCmosRegister(RegisterStatusC) and StatusCAlarmFlag) <> 0;
end;

end.
