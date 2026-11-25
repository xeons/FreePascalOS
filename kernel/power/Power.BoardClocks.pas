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
  The Raspberry Pi's ARM clock, temperature and fan (untested on the
  board).

  Through the VideoCore mailbox (Drivers.VideoCoreMailbox) the firmware
  tells the ARM clock now, its least and its most (arm_freq_min and
  arm_freq: 1.5 and 2.4 GHz on a Pi 5) and the processor's temperature,
  and sets the ARM clock (with the voltage for it) when asked. The
  firmware keeps whatever clock it started with unless the operating
  system asks for another, and does not run the Pi 5's fan.

  - Frequency scaling. A thread ("BoardClocks") looks at the processors
    every half second: when the busiest was busy 60 % of the time or
    more, the clock goes to the most allowed; after three looks in a
    row under 25 % it goes to the least; in between it stays (the gap
    and the wait are the hysteresis). Each change is one mailbox call.
  - Thermal limit. The temperature is a thermal zone ("soc",
    Power.ThermalZones) read every second, passive at 80 C (thermallimit=)
    and critical at 90 C (thermalcritical=): above the passive point the
    allowed clock comes down in steps (this unit is the performance
    limiter, Power.Performance), never below the firmware's least; the
    firmware's own limit (85 C) stays beneath it all.
  - The fan (Pi 5, Drivers.Rp1Fan): on at 55 C (fanon=), off below 48 C
    (7 degrees less), read every two seconds; fan=on keeps it running,
    fan=off leaves it alone.
  cpufreq=off leaves the clock to the firmware (no scaling, no limit);
  cpufreq=max and cpufreq=min fix it at either end.
}
unit Power.BoardClocks;

{$mode objfpc}

interface

{ Starts the governor if the firmware can tell and set the ARM clock
  (on a Raspberry Pi), and the fan control where there is a fan. }
procedure StartBoardPower;
procedure WriteBoardPowerSummary;

implementation

uses
  Runtime.Text,
  Runtime.Memory,
  Abi.SystemCalls,
  Kernel.Clock,
  Kernel.Scheduler,
  Kernel.Options,
  Kernel.Processors,
  Kernel.ProcessorTime,
  Processes.Thread,
  Drivers.VideoCoreMailbox,
  Drivers.Rp1Fan,
  Power.Performance,
  Power.ThermalZones,
  Power.ProcessorLoad,
  Debug.Output;

type
  TScalingMode = (ScalingDynamic, ScalingOff, ScalingMaximum, ScalingMinimum);
  TFanMode = (FanAutomatic, FanAlwaysOn, FanLeftAlone);

const
  SampleMilliseconds = 500;
  BusyPercentToRaise = 60;
  BusyPercentToLower = 25;
  QuietSamplesToLower = 3;
  FanSampleInterval = 4;
  DefaultPassiveCelsius = 80;
  DefaultCriticalCelsius = 90;
  DefaultFanOnCelsius = 55;
  FanHysteresisCelsius = 7;
  TemperaturePollMilliseconds = 1000;
  GovernorPriority = 20;

var
  Mode: TScalingMode = ScalingDynamic;
  FanMode: TFanMode = FanAutomatic;
  MinimumHertz: LongWord = 0;
  MaximumHertz: LongWord = 0;
  CurrentHertz: LongWord = 0;
  { The most the thermal limit allows now. }
  AllowedHertz: LongWord = 0;
  FanOnMilliCelsius: LongInt = DefaultFanOnCelsius * 1000;
  FanRunning: Boolean = False;
  { The pin has been driven once (until then its state is whatever the
    firmware left). }
  FanDriven: Boolean = False;
  LastTemperature: LongInt = NoTripPoint;
  { The clock asked for by the load, before the limit. }
  WantsMaximum: Boolean = True;
  QuietSamples: Integer = 0;

function OptionValueIs(Name, Value: PChar): Boolean;
var
  Text: array[0..15] of Char;
begin
  Result := GetKernelOptionValue(Name, @Text[0], SizeOf(Text)) and TextIsEqual(@Text[0], Value);
end;

function OptionCelsius(Name: PChar; Default: LongInt): LongInt;
var
  Number: QWord;
begin
  Result := Default;
  if GetKernelOptionNumber(Name, Number) and (Number >= 30) and (Number <= 110) then
    Result := LongInt(Number);
end;

procedure ReadOptions;
begin
  if OptionValueIs('cpufreq', 'off') then
    Mode := ScalingOff
  else if OptionValueIs('cpufreq', 'max') then
    Mode := ScalingMaximum
  else if OptionValueIs('cpufreq', 'min') then
    Mode := ScalingMinimum;
  if OptionValueIs('fan', 'on') then
    FanMode := FanAlwaysOn
  else if OptionValueIs('fan', 'off') then
    FanMode := FanLeftAlone;
  FanOnMilliCelsius := OptionCelsius('fanon', DefaultFanOnCelsius) * 1000;
end;

procedure Report;
var
  ClockReport: TProcessorClockReport;
begin
  ClockReport.ClockHertz := CurrentHertz;
  ClockReport.MinimumClockHertz := MinimumHertz;
  ClockReport.MaximumClockHertz := MaximumHertz;
  ClockReport.Scaling := Mode = ScalingDynamic;
  ClockReport.FanControlled := Rp1FanIsAvailable and (FanMode <> FanLeftAlone);
  ClockReport.FanRunning := FanRunning;
  ReportProcessorClock(ClockReport);
end;

procedure SetArmClock(Hertz: LongWord);
var
  Actual: LongWord;
begin
  if Hertz < MinimumHertz then
    Hertz := MinimumHertz;
  if Hertz = CurrentHertz then
    Exit;
  if SetClockRate(FirmwareClockArm, Hertz, Actual) then
    CurrentHertz := Actual
  else if QueryClockRate(FirmwareClockArm, Actual) then
    CurrentHertz := Actual;
  Report;
end;

{ The clock the load and the limit ask for now. }
procedure ApplyClock;
begin
  case Mode of
    ScalingOff:
      Exit;
    ScalingMaximum:
      SetArmClock(AllowedHertz);
    ScalingMinimum:
      SetArmClock(MinimumHertz);
  else
    if WantsMaximum then
      SetArmClock(AllowedHertz)
    else
      SetArmClock(MinimumHertz);
  end;
end;

{ The performance limiter: the thermal policy's percent of full speed
  as a cap on the ARM clock. }
procedure LimitArmClock(Percent: LongWord);
begin
  if Mode = ScalingOff then
    Exit;
  AllowedHertz := LongWord(QWord(MaximumHertz) * Percent div 100);
  if AllowedHertz < MinimumHertz then
    AllowedHertz := MinimumHertz;
  ApplyClock;
end;

function ReadTemperature(Zone: PThermalZone; out MilliCelsius: LongInt): Boolean;
var
  Value: LongWord;
begin
  Result := QueryTemperature(Value) and (Value > 0) and (Value < 150000);
  if Result then
  begin
    MilliCelsius := LongInt(Value);
    LastTemperature := MilliCelsius;
  end
  else
    MilliCelsius := NoTripPoint;
end;

procedure RegisterTemperatureZone;
var
  Zone: TThermalZone;
begin
  ZeroMemory(@Zone, SizeOf(Zone));
  CopyText(@Zone.Name[0], 'soc', ThermalZoneNameCapacity);
  Zone.Kind := ThermalZoneFirmware;
  Zone.Read := @ReadTemperature;
  Zone.PassiveMilliCelsius := OptionCelsius('thermallimit', DefaultPassiveCelsius) * 1000;
  Zone.CriticalMilliCelsius := OptionCelsius('thermalcritical', DefaultCriticalCelsius) * 1000;
  Zone.PollMilliseconds := TemperaturePollMilliseconds;
  RegisterThermalZone(Zone);
end;

procedure UpdateFan;
var
  Running: Boolean;
begin
  if not Rp1FanIsAvailable or (FanMode = FanLeftAlone) then
    Exit;
  Running := FanRunning;
  if FanMode = FanAlwaysOn then
    Running := True
  else if LastTemperature <> NoTripPoint then
  begin
    if LastTemperature >= FanOnMilliCelsius then
      Running := True
    else if LastTemperature < FanOnMilliCelsius - FanHysteresisCelsius * 1000 then
      Running := False;
  end;
  if (Running = FanRunning) and FanDriven then
    Exit;
  FanRunning := Running;
  FanDriven := True;
  SetRp1FanRunning(Running);
  Report;
  DebugBeginMessage;
  DebugWriteTag('fan');
  if Running then
    DebugWrite('on at ')
  else
    DebugWrite('off at ');
  DebugWriteDecimal(QWord(LastTemperature) div 1000);
  DebugWriteLine(' C');
  DebugEndMessage;
end;

procedure RunGovernor(Context: Pointer);
var
  Load: TProcessorLoadSample;
  Busiest: LongWord;
  Samples: QWord;
begin
  StartLoadSample(Load);
  Samples := 0;
  while True do
  begin
    SleepMilliseconds(SampleMilliseconds);
    Inc(Samples);
    Busiest := BusiestProcessorPercent(Load);
    if Busiest >= BusyPercentToRaise then
    begin
      WantsMaximum := True;
      QuietSamples := 0;
    end
    else if Busiest < BusyPercentToLower then
    begin
      Inc(QuietSamples);
      if QuietSamples >= QuietSamplesToLower then
        WantsMaximum := False;
    end
    else
      QuietSamples := 0;
    ApplyClock;
    if (Samples mod FanSampleInterval) = 0 then
      UpdateFan;
  end;
end;

procedure WriteMegahertz(Hertz: LongWord);
begin
  DebugWriteDecimal(Hertz div 1000000);
  DebugWrite(' MHz');
end;

procedure WriteBoardPowerSummary;
begin
  if MaximumHertz = 0 then
    Exit;
  DebugBeginMessage;
  DebugWriteTag('board');
  DebugWrite('ARM clock ');
  WriteMegahertz(CurrentHertz);
  DebugWrite(' (');
  WriteMegahertz(MinimumHertz);
  DebugWrite(' to ');
  WriteMegahertz(MaximumHertz);
  DebugWrite(', allowed ');
  WriteMegahertz(AllowedHertz);
  DebugWrite(')');
  if LastTemperature <> NoTripPoint then
  begin
    DebugWrite(', ');
    DebugWriteDecimal(QWord(LastTemperature) div 1000);
    DebugWrite('.');
    DebugWriteDecimal((QWord(LastTemperature) mod 1000) div 100);
    DebugWrite(' C');
  end;
  case Mode of
    ScalingOff: DebugWrite('; scaling off (cpufreq=off)');
    ScalingMaximum: DebugWrite('; fixed at the most (cpufreq=max)');
    ScalingMinimum: DebugWrite('; fixed at the least (cpufreq=min)');
  else
    DebugWrite('; scaled with the load');
  end;
  if Rp1FanIsAvailable then
    case FanMode of
      FanAlwaysOn: DebugWrite('; fan always on');
      FanLeftAlone: DebugWrite('; fan left alone');
    else
      if FanRunning then
        DebugWrite('; fan on')
      else
        DebugWrite('; fan off');
    end;
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure StartBoardPower;
var
  Value: LongWord;
  Temperature: LongInt;
begin
  if not VideoCoreMailboxIsAvailable then
    Exit;
  if not QueryMaximumClockRate(FirmwareClockArm, MaximumHertz) then
    Exit;
  if not QueryMinimumClockRate(FirmwareClockArm, MinimumHertz) or (MinimumHertz > MaximumHertz) then
    MinimumHertz := MaximumHertz;
  if QueryClockRate(FirmwareClockArm, Value) then
    CurrentHertz := Value
  else
    CurrentHertz := MaximumHertz;
  AllowedHertz := MaximumHertz;
  ReadTemperature(nil, Temperature);
  ReadOptions;
  InitializeRp1Fan;
  Report;
  if Mode <> ScalingOff then
    SetPerformanceLimiter(@LimitArmClock);
  RegisterTemperatureZone;
  UpdateFan;
  ApplyClock;
  WriteBoardPowerSummary;
  if (Mode = ScalingDynamic) or (Rp1FanIsAvailable and (FanMode = FanAutomatic)) then
    CreateSystemThread(@RunGovernor, nil, GovernorPriority, 'BoardClocks', False);
end;

end.
