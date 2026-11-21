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
  Thermal zones and what is done about them.

  A zone is a temperature the kernel can read - an ACPI thermal zone's
  _TMP (Io.AcpiThermal), the Raspberry Pi's processor temperature from
  the firmware (Power.BoardClocks) - with up to two trip points:
  - passive: above it the processors are slowed down, a step (10 % of
    full speed) at every reading, to 30 % at most; once it is 3 degrees
    below, they are let up a step at a time again (Power.Performance:
    the lowest limit any zone asks for holds);
  - critical: two readings in a row at or above it shut the machine
    down cleanly (Processes.Shutdown), as ACPI asks.
  A thread ("Thermal") reads each zone as often as it says. With the
  kernel option thermal=off the zones are only read and shown.
}
unit Power.ThermalZones;

{$mode objfpc}

interface

const
  MaximumThermalZones = 8;
  ThermalZoneNameCapacity = 32;
  { A trip point that is not there (Abi's ThermalTripNone). }
  NoTripPoint = Low(LongInt);

type
  PThermalZone = ^TThermalZone;
  { Reads the zone's temperature in thousandths of a degree Celsius. }
  TThermalZoneReader = function(Zone: PThermalZone; out MilliCelsius: LongInt): Boolean;

  TThermalZone = record
    Name: array[0..ThermalZoneNameCapacity - 1] of Char;
    { ThermalZoneAcpi or ThermalZoneFirmware (Abi.SystemCalls). }
    Kind: LongWord;
    Read: TThermalZoneReader;
    Context: Pointer;
    PassiveMilliCelsius: LongInt;
    CriticalMilliCelsius: LongInt;
    PollMilliseconds: LongWord;
    { Kept by the policy: the last reading (NoTripPoint before the
      first), the limit the zone asks for, the critical readings in a
      row, and when it is read next (clock nanoseconds). }
    TemperatureMilliCelsius: LongInt;
    LimitPercent: LongWord;
    CriticalReadings: LongWord;
    NextReadTime: QWord;
  end;

{ Adds a zone (its name, kind, reader, context, trip points and poll
  period filled in) and starts the policy thread if it does not run
  yet. False if there are too many. Passive level. }
function RegisterThermalZone(constref Zone: TThermalZone): Boolean;
function ThermalZoneCount: Integer;
{ A copy of zone Index; False past the last. }
function GetThermalZone(Index: Integer; out Zone: TThermalZone): Boolean;
procedure WriteThermalSummary;

implementation

uses
  Runtime.Text,
  Runtime.Memory,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Clock,
  Kernel.Scheduler,
  Kernel.Options,
  Processes.Thread,
  Processes.Shutdown,
  Power.Performance,
  Debug.Output;

const
  LimitStepPercent = 10;
  LowestLimitPercent = 30;
  PassiveHysteresisMilliCelsius = 3000;
  CriticalReadingsToShutDown = 2;
  ShortestPollMilliseconds = 100;
  DefaultPollMilliseconds = 10000;
  NanosecondsPerMillisecondHere = 1000000;
  ThermalThreadPriority = 20;
  { ACPI zones' readers run AML, which recurses as it nests. }
  ThermalThreadStackSize = 256 * 1024;

var
  Lock: TSpinLock;
  Zones: array[0..MaximumThermalZones - 1] of TThermalZone;
  ZoneCount: Integer = 0;
  PolicyStarted: Boolean = False;
  MonitorOnly: Boolean = False;
  ShutdownRequested: Boolean = False;

procedure WriteMilliCelsius(Value: LongInt);
begin
  if Value < 0 then
  begin
    DebugWrite('-');
    Value := -Value;
  end;
  DebugWriteDecimal(QWord(Value) div 1000);
  DebugWrite('.');
  DebugWriteDecimal((QWord(Value) mod 1000) div 100);
  DebugWrite(' C');
end;

procedure ReportZone(constref Zone: TThermalZone; Text: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('thermal');
  DebugWrite(@Zone.Name[0]);
  DebugWrite(': ');
  DebugWrite(Text);
  DebugWrite(' at ');
  WriteMilliCelsius(Zone.TemperatureMilliCelsius);
  DebugWriteLine('');
  DebugEndMessage;
end;

{ The limit the zone asks for after a reading. }
function NextLimit(constref Zone: TThermalZone; Temperature: LongInt): LongWord;
begin
  Result := Zone.LimitPercent;
  if Zone.PassiveMilliCelsius = NoTripPoint then
    Exit(100);
  if Temperature >= Zone.PassiveMilliCelsius then
  begin
    if Result > LowestLimitPercent + LimitStepPercent then
      Result := Result - LimitStepPercent
    else
      Result := LowestLimitPercent;
  end
  else if Temperature < Zone.PassiveMilliCelsius - PassiveHysteresisMilliCelsius then
  begin
    if Result + LimitStepPercent < 100 then
      Result := Result + LimitStepPercent
    else
      Result := 100;
  end;
end;

{ Reads zone Index if it is due; returns whether it was read. }
procedure ReadZone(Index: Integer; Now: QWord);
var
  PreviousLevel: TPriorityLevel;
  Zone: TThermalZone;
  Temperature: LongInt;
  Limit: LongWord;
  Critical: Boolean;
begin
  PreviousLevel := AcquireSpinLock(Lock);
  Zone := Zones[Index];
  ReleaseSpinLock(Lock, PreviousLevel);
  if Now < Zone.NextReadTime then
    Exit;
  Critical := False;
  if Zone.Read(@Zones[Index], Temperature) then
  begin
    Limit := NextLimit(Zone, Temperature);
    if (Zone.CriticalMilliCelsius <> NoTripPoint) and (Temperature >= Zone.CriticalMilliCelsius) then
      Inc(Zone.CriticalReadings)
    else
      Zone.CriticalReadings := 0;
    Critical := Zone.CriticalReadings >= CriticalReadingsToShutDown;
    Zone.TemperatureMilliCelsius := Temperature;
    if MonitorOnly then
      Limit := 100;
    if (Limit < 100) and (Zone.LimitPercent = 100) then
      ReportZone(Zone, 'above its passive trip point, slowing the processors')
    else if (Limit = 100) and (Zone.LimitPercent < 100) then
      ReportZone(Zone, 'cooled down, processors back to full speed');
    Zone.LimitPercent := Limit;
  end;
  PreviousLevel := AcquireSpinLock(Lock);
  Zones[Index].TemperatureMilliCelsius := Zone.TemperatureMilliCelsius;
  Zones[Index].LimitPercent := Zone.LimitPercent;
  Zones[Index].CriticalReadings := Zone.CriticalReadings;
  Zones[Index].NextReadTime := Now + QWord(Zone.PollMilliseconds) * NanosecondsPerMillisecondHere;
  ReleaseSpinLock(Lock, PreviousLevel);
  if Critical and not MonitorOnly and not ShutdownRequested then
  begin
    ShutdownRequested := True;
    ReportZone(Zone, 'CRITICAL temperature, shutting down');
    RequestShutdown(PowerActionOff);
  end;
end;

{ The lowest limit any zone asks for, and when the next one is due. }
procedure Summarize(out Limit: LongWord; out NextDue: QWord);
var
  PreviousLevel: TPriorityLevel;
  Index: Integer;
begin
  Limit := 100;
  NextDue := NeverDue;
  PreviousLevel := AcquireSpinLock(Lock);
  for Index := 0 to ZoneCount - 1 do
  begin
    if Zones[Index].LimitPercent < Limit then
      Limit := Zones[Index].LimitPercent;
    if Zones[Index].NextReadTime < NextDue then
      NextDue := Zones[Index].NextReadTime;
  end;
  ReleaseSpinLock(Lock, PreviousLevel);
end;

procedure RunThermalPolicy(Context: Pointer);
var
  Index: Integer;
  Limit: LongWord;
  NextDue: QWord;
  Now: QWord;
  Wait: QWord;
begin
  while True do
  begin
    Now := ClockNanoseconds;
    Index := 0;
    while Index < ThermalZoneCount do
    begin
      ReadZone(Index, Now);
      Inc(Index);
    end;
    Summarize(Limit, NextDue);
    SetThermalPerformanceLimit(Limit);
    Now := ClockNanoseconds;
    if NextDue > Now then
      Wait := (NextDue - Now) div NanosecondsPerMillisecondHere + 1
    else
      Wait := ShortestPollMilliseconds;
    if Wait < ShortestPollMilliseconds then
      Wait := ShortestPollMilliseconds;
    SleepMilliseconds(Wait);
  end;
end;

function OptionIsOff(Name: PChar): Boolean;
var
  Value: array[0..15] of Char;
begin
  Result := GetKernelOptionValue(Name, @Value[0], SizeOf(Value)) and TextIsEqual(@Value[0], 'off');
end;

function RegisterThermalZone(constref Zone: TThermalZone): Boolean;
var
  PreviousLevel: TPriorityLevel;
  StartPolicy: Boolean;
begin
  PreviousLevel := AcquireSpinLock(Lock);
  Result := ZoneCount < MaximumThermalZones;
  if Result then
  begin
    Zones[ZoneCount] := Zone;
    Zones[ZoneCount].TemperatureMilliCelsius := NoTripPoint;
    Zones[ZoneCount].LimitPercent := 100;
    Zones[ZoneCount].CriticalReadings := 0;
    Zones[ZoneCount].NextReadTime := 0;
    if Zones[ZoneCount].PollMilliseconds = 0 then
      Zones[ZoneCount].PollMilliseconds := DefaultPollMilliseconds;
    if Zones[ZoneCount].PollMilliseconds < ShortestPollMilliseconds then
      Zones[ZoneCount].PollMilliseconds := ShortestPollMilliseconds;
    Inc(ZoneCount);
  end;
  StartPolicy := Result and not PolicyStarted;
  if StartPolicy then
    PolicyStarted := True;
  ReleaseSpinLock(Lock, PreviousLevel);
  if not StartPolicy then
    Exit;
  MonitorOnly := OptionIsOff('thermal');
  if CreateSystemThread(@RunThermalPolicy, nil, ThermalThreadPriority, 'Thermal', False,
     ThermalThreadStackSize) = nil then
    PolicyStarted := False;
end;

function ThermalZoneCount: Integer;
begin
  Result := ZoneCount;
end;

function GetThermalZone(Index: Integer; out Zone: TThermalZone): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Lock);
  Result := (Index >= 0) and (Index < ZoneCount);
  if Result then
    Zone := Zones[Index];
  ReleaseSpinLock(Lock, PreviousLevel);
  if not Result then
    ZeroMemory(@Zone, SizeOf(Zone));
end;

procedure WriteThermalSummary;
var
  Index: Integer;
  Zone: TThermalZone;
begin
  if ThermalZoneCount = 0 then
  begin
    DebugBeginMessage;
    DebugWriteTag('thermal');
    DebugWriteLine('no thermal zones');
    DebugEndMessage;
    Exit;
  end;
  for Index := 0 to ThermalZoneCount - 1 do
  begin
    if not GetThermalZone(Index, Zone) then
      Break;
    DebugBeginMessage;
    DebugWriteTag('thermal');
    DebugWrite(@Zone.Name[0]);
    DebugWrite(': ');
    if Zone.TemperatureMilliCelsius = NoTripPoint then
      DebugWrite('not read yet')
    else
      WriteMilliCelsius(Zone.TemperatureMilliCelsius);
    if Zone.PassiveMilliCelsius <> NoTripPoint then
    begin
      DebugWrite(', passive ');
      WriteMilliCelsius(Zone.PassiveMilliCelsius);
    end;
    if Zone.CriticalMilliCelsius <> NoTripPoint then
    begin
      DebugWrite(', critical ');
      WriteMilliCelsius(Zone.CriticalMilliCelsius);
    end;
    DebugWrite(', limit ');
    DebugWriteDecimal(Zone.LimitPercent);
    DebugWrite(' %, read every ');
    DebugWriteDecimal(Zone.PollMilliseconds);
    DebugWriteLine(' ms');
    DebugEndMessage;
  end;
end;

end.
