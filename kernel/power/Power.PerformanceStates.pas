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
  The processors' clock rate on PCs: hardware P-states, or ACPI's
  performance states.

  - Hardware P-states (HWP; Hal.PerformanceControl), where the processor
    has them: turned on on every processor and given the whole range it
    says it has, with a balanced energy preference; the processor then
    picks its clock itself. The thermal limit (Power.Performance) lowers
    the top of the range instead of modulating the clock.
  - Otherwise ACPI's _PSS (Firmware.AcpiProcessorControl, read by
    Io.AcpiPower after _PDC/_OSC), carried out through the performance
    control MSR (on every processor) or an I/O port (once): a governor
    thread ("Performance") looks at the busiest processor every half
    second, as the Raspberry Pi's does (Power.BoardClocks): 60 % busy or
    more takes the fastest state allowed, three looks in a row under
    25 % the slowest, in between it stays. Allowed: no faster than _PPC
    says (re-read on the processor's Notify 0x80) nor than the thermal
    limit (the fastest state at or below that share of the top
    frequency), which then also takes over from clock modulation.
  cpufreq=off leaves the clock alone, cpufreq=max and cpufreq=min fix
  it. The rate and its range go to the power information call
  (Power.Performance's report); the states to CallListPerformanceStates.
}
unit Power.PerformanceStates;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  Firmware.AcpiProcessorControl;

{ At start (once the processors run): hardware P-states, if any. }
procedure StartHardwarePStates;
{ The first processor's performance states and control (from
  Io.AcpiPower's thread); starts the governor. Ignored with hardware
  P-states on. }
procedure UseFirmwarePerformanceStates(constref Performance: TAcpiPerformance);
{ _PPC changed: the fastest state allowed now. }
procedure SetFirmwareFastestAllowed(Index: Integer);
function PerformanceStateCount: Integer;
function GetPerformanceStateRecord(Index: Integer; out State: TAbiPerformanceState): Boolean;
procedure WritePerformanceSummary;

implementation

uses
  Runtime.Text,
  Runtime.Memory,
  Kernel.Options,
  Kernel.Scheduler,
  Hal.PortIo,
  Hal.PerformanceControl,
  Processes.Thread,
  Power.Performance,
  Power.EveryProcessor,
  Power.ProcessorLoad,
  Debug.Output;

type
  TScalingMode = (ScalingDynamic, ScalingOff, ScalingMaximum, ScalingMinimum);

const
  SampleMilliseconds = 500;
  BusyPercentToRaise = 60;
  BusyPercentToLower = 25;
  QuietSamplesToLower = 3;
  GovernorPriority = 20;
  BalancedEnergyPreference = $80;
  MegahertzToHertz = 1000000;

var
  Mode: TScalingMode = ScalingDynamic;
  Firmware: TAcpiPerformance;
  FirmwareInUse: Boolean = False;
  CurrentState: Integer = 0;
  FastestAllowed: Integer = 0;
  WantsFastest: Boolean = True;
  QuietSamples: Integer = 0;
  HardwareInUse: Boolean = False;
  Hardware: THardwarePStateCapabilities;
  HardwareHighest: Byte;
  ThermalPercent: LongWord = 100;
  GovernorStarted: Boolean = False;

procedure ReadMode;
var
  Value: array[0..15] of Char;
begin
  if not GetKernelOptionValue('cpufreq', @Value[0], SizeOf(Value)) then
    Exit;
  if TextIsEqual(@Value[0], 'off') then
    Mode := ScalingOff
  else if TextIsEqual(@Value[0], 'max') then
    Mode := ScalingMaximum
  else if TextIsEqual(@Value[0], 'min') then
    Mode := ScalingMinimum;
end;

{ --- Hardware P-states -------------------------------------------------------- }

procedure EnableHardwareHere(Context: Pointer);
begin
  EnableHardwarePStatesOnThisProcessor;
end;

procedure RequestHardwareHere(Context: Pointer);
var
  Lowest: Byte;
begin
  Lowest := Hardware.Lowest;
  if Mode = ScalingMaximum then
    Lowest := HardwareHighest;
  if Lowest > HardwareHighest then
    Lowest := HardwareHighest;
  RequestThisProcessorHardwarePStates(Lowest, HardwareHighest, BalancedEnergyPreference);
end;

procedure ReportHardware;
var
  Report: TProcessorClockReport;
begin
  GetProcessorClockReport(Report);
  Report.Scaling := True;
  Report.MinimumClockHertz := QWord(Hardware.Lowest) * HardwarePStateLevelMegahertz * MegahertzToHertz;
  Report.MaximumClockHertz := QWord(Hardware.Highest) * HardwarePStateLevelMegahertz * MegahertzToHertz;
  { The processor chooses: the top of the range stands for it. }
  Report.ClockHertz := QWord(HardwareHighest) * HardwarePStateLevelMegahertz * MegahertzToHertz;
  ReportProcessorClock(Report);
end;

procedure LimitHardware(Percent: LongWord);
var
  Highest: LongWord;
begin
  ThermalPercent := Percent;
  Highest := LongWord(Hardware.Highest) * Percent div 100;
  if Highest < Hardware.Lowest then
    Highest := Hardware.Lowest;
  HardwareHighest := Byte(Highest);
  RunOnEveryProcessor(@RequestHardwareHere, nil);
  ReportHardware;
end;

procedure StartHardwarePStates;
begin
  ReadMode;
  if (Mode = ScalingOff) or not ReadHardwarePStateCapabilities(Hardware) or (Hardware.Highest = 0) then
    Exit;
  HardwareInUse := True;
  HardwareHighest := Hardware.Highest;
  if Mode = ScalingMinimum then
    HardwareHighest := Hardware.Lowest;
  RunOnEveryProcessor(@EnableHardwareHere, nil);
  RunOnEveryProcessor(@RequestHardwareHere, nil);
  SetPerformanceLimiter(@LimitHardware);
  ReportHardware;
  WritePerformanceSummary;
end;

{ --- ACPI performance states ------------------------------------------------------ }

procedure WriteControlHere(Context: Pointer);
begin
  WriteThisProcessorPerformanceControl(LongWord(PtrUInt(Context)));
end;

procedure WriteControl(Value: LongWord);
var
  Port: Word;
begin
  if Firmware.Control.Space = AcpiControlFixedHardware then
  begin
    RunOnEveryProcessor(@WriteControlHere, Pointer(PtrUInt(Value)));
    Exit;
  end;
  Port := Word(Firmware.Control.Address);
  case Firmware.Control.BitWidth of
    8: WritePortByte(Port, Byte(Value));
    16: WritePortWord(Port, Word(Value));
  else
    WritePortLongWord(Port, Value);
  end;
end;

{ The fastest state the firmware and the thermal limit allow. }
function FastestPermitted: Integer;
var
  Ceiling: QWord;
begin
  Result := FastestAllowed;
  Ceiling := QWord(Firmware.States[0].FrequencyMegahertz) * ThermalPercent div 100;
  while (Result < Firmware.Count - 1) and (Firmware.States[Result].FrequencyMegahertz > Ceiling) do
    Inc(Result);
end;

procedure ReportFirmware;
var
  Report: TProcessorClockReport;
begin
  GetProcessorClockReport(Report);
  Report.Scaling := Mode <> ScalingOff;
  Report.ClockHertz := QWord(Firmware.States[CurrentState].FrequencyMegahertz) * MegahertzToHertz;
  Report.MaximumClockHertz := QWord(Firmware.States[0].FrequencyMegahertz) * MegahertzToHertz;
  Report.MinimumClockHertz := QWord(Firmware.States[Firmware.Count - 1].FrequencyMegahertz) * MegahertzToHertz;
  ReportProcessorClock(Report);
end;

procedure ApplyState;
var
  Wanted: Integer;
begin
  case Mode of
    ScalingMaximum: Wanted := 0;
    ScalingMinimum: Wanted := Firmware.Count - 1;
  else
    if WantsFastest then
      Wanted := 0
    else
      Wanted := Firmware.Count - 1;
  end;
  if Wanted < FastestPermitted then
    Wanted := FastestPermitted;
  if Wanted = CurrentState then
    Exit;
  CurrentState := Wanted;
  WriteControl(Firmware.States[Wanted].Control);
  ReportFirmware;
end;

procedure LimitFirmware(Percent: LongWord);
begin
  ThermalPercent := Percent;
  ApplyState;
end;

procedure RunGovernor(Context: Pointer);
var
  Load: TProcessorLoadSample;
  Busiest: LongWord;
begin
  StartLoadSample(Load);
  while True do
  begin
    SleepMilliseconds(SampleMilliseconds);
    Busiest := BusiestProcessorPercent(Load);
    if Busiest >= BusyPercentToRaise then
    begin
      WantsFastest := True;
      QuietSamples := 0;
    end
    else if Busiest < BusyPercentToLower then
    begin
      Inc(QuietSamples);
      if QuietSamples >= QuietSamplesToLower then
        WantsFastest := False;
    end
    else
      QuietSamples := 0;
    ApplyState;
  end;
end;

function ControlIsUsable(constref Performance: TAcpiPerformance): Boolean;
begin
  if Performance.Control.Space = AcpiControlFixedHardware then
    Result := PerformanceControlIsAvailable
  else
    Result := (Performance.Control.Address <> 0) and (Performance.Control.Address <= $FFFF);
end;

procedure UseFirmwarePerformanceStates(constref Performance: TAcpiPerformance);
begin
  ReadMode;
  if HardwareInUse or FirmwareInUse or (Performance.Count = 0) then
    Exit;
  Firmware := Performance;
  FirmwareInUse := True;
  FastestAllowed := Performance.FastestAllowed;
  { Unknown until the first write: the state is written once at least. }
  CurrentState := -1;
  if not ControlIsUsable(Performance) then
    Mode := ScalingOff;
  if Mode <> ScalingOff then
  begin
    SetPerformanceLimiter(@LimitFirmware);
    ThermalPercent := PerformanceLimitPercent;
    ApplyState;
  end
  else
  begin
    CurrentState := 0;
    ReportFirmware;
  end;
  WritePerformanceSummary;
  if (Mode = ScalingDynamic) and (Firmware.Count > 1) and not GovernorStarted then
  begin
    GovernorStarted := True;
    CreateSystemThread(@RunGovernor, nil, GovernorPriority, 'Performance', False);
  end;
end;

procedure SetFirmwareFastestAllowed(Index: Integer);
begin
  if not FirmwareInUse then
    Exit;
  if (Index < 0) or (Index >= Firmware.Count) then
    Index := 0;
  FastestAllowed := Index;
  if Mode <> ScalingOff then
    ApplyState;
end;

function PerformanceStateCount: Integer;
begin
  if FirmwareInUse then
    Result := Firmware.Count
  else
    Result := 0;
end;

function GetPerformanceStateRecord(Index: Integer; out State: TAbiPerformanceState): Boolean;
begin
  ZeroMemory(@State, SizeOf(State));
  Result := (Index >= 0) and (Index < PerformanceStateCount);
  if not Result then
    Exit;
  State.FrequencyMegahertz := Firmware.States[Index].FrequencyMegahertz;
  State.PowerMilliwatts := Firmware.States[Index].PowerMilliwatts;
  State.LatencyMicroseconds := Firmware.States[Index].LatencyMicroseconds;
  if Index = CurrentState then
    State.Flags := State.Flags or PerformanceStateCurrent;
  if Index < FastestPermitted then
    State.Flags := State.Flags or PerformanceStateNotAllowed;
end;

procedure WritePerformanceSummary;
var
  Index: Integer;
begin
  DebugBeginMessage;
  DebugWriteTag('cpufreq');
  if HardwareInUse then
  begin
    DebugWrite('hardware P-states, levels ');
    DebugWriteDecimal(Hardware.Lowest);
    DebugWrite(' to ');
    DebugWriteDecimal(Hardware.Highest);
    DebugWrite(' (guaranteed ');
    DebugWriteDecimal(Hardware.Guaranteed);
    DebugWrite(')');
  end
  else if FirmwareInUse then
  begin
    DebugWrite('ACPI performance states:');
    for Index := 0 to Firmware.Count - 1 do
    begin
      DebugWrite(' ');
      DebugWriteDecimal(Firmware.States[Index].FrequencyMegahertz);
    end;
    DebugWrite(' MHz through ');
    if Firmware.Control.Space = AcpiControlFixedHardware then
      DebugWrite('the performance control MSR')
    else
    begin
      DebugWrite('port 0x');
      DebugWriteHex(Firmware.Control.Address, 4);
    end;
    DebugWrite(', fastest allowed ');
    DebugWriteDecimal(Firmware.States[FastestAllowed].FrequencyMegahertz);
    DebugWrite(' MHz');
  end
  else
    DebugWrite('no performance states');
  case Mode of
    ScalingOff: DebugWrite('; scaling off');
    ScalingMaximum: DebugWrite('; fixed at the fastest (cpufreq=max)');
    ScalingMinimum: DebugWrite('; fixed at the slowest (cpufreq=min)');
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

end.
