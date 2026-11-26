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
  The clock information call (CallGetClockInformation): what the HAL
  says of its clocks (HalDescribeTimers), the broadcast timer of deep
  idle states (Kernel.BroadcastTimer) and whether programs read the
  time from the clock page. Anyone may read it.
}
unit Processes.ClockInformation;

{$mode objfpc}

interface

function PerformGetClockInformation(InformationAddress: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Runtime.Memory,
  Hal.Platform,
  Kernel.TimerDescription,
  Kernel.BroadcastTimer,
  Kernel.ClockPage,
  Processes.UserAccess;

procedure CopyFlags(constref Description: TTimerDescription; var Information: TAbiClockInformation);
const
  { The HAL's flags have the ABI's values (Kernel.TimerDescription). }
  PassedFlags = TimerCounterInvariant or TimerHpetPresent or TimerHpet64Bit or TimerHpetLegacyCapable or
    TimerHpetLegacyInUse or TimerClockForced or TimerClockWatched or TimerClockFellBack;
begin
  Information.Flags := Description.Flags and PassedFlags;
  if BroadcastUsesDevice then
    Information.Flags := Information.Flags or ClockInformationBroadcastDevice;
  if ClockPageOffersCounter then
    Information.Flags := Information.Flags or ClockInformationClockPageCounter;
end;

function PerformGetClockInformation(InformationAddress: QWord): Int64;
var
  Description: TTimerDescription;
  Information: TAbiClockInformation;
begin
  HalDescribeTimers(Description);
  ZeroMemory(@Information, SizeOf(Information));
  CopyFlags(Description, Information);
  Information.HpetComparators := Description.HpetComparators;
  Information.CounterHertz := Description.CounterHertz;
  Information.CounterMeasuredHertz := Description.CounterMeasuredHertz;
  Information.LocalTimerHertz := Description.LocalTimerHertz;
  Information.HpetPeriodFemtoseconds := Description.HpetPeriodFemtoseconds;
  Information.HpetMinimumTick := Description.HpetMinimumTick;
  Information.HpetVendorId := Description.HpetVendorId;
  Information.HpetBaseAddress := Description.HpetBaseAddress;
  Information.HpetEventComparator := Description.HpetEventComparator;
  Information.HpetCounterBits := Description.HpetCounterBits;
  Information.HpetInterrupts := Description.HpetInterrupts;
  Information.BroadcastWakes := BroadcastWakeCount;
  Information.WatchdogChecks := Description.WatchdogChecks;
  Information.WatchdogFailures := Description.WatchdogFailures;
  Information.WatchdogLargestDriftNanoseconds := Description.WatchdogLargestDriftNanoseconds;
  CopyText(@Information.ClockSource[0], @Description.ClockSource[0], AbiClockNameCapacity);
  CopyText(@Information.CounterCalibration[0], @Description.CounterCalibration[0], AbiClockNameCapacity);
  CopyText(@Information.LocalTimerCalibration[0], @Description.LocalTimerCalibration[0], AbiClockNameCapacity);
  CopyText(@Information.HpetRoute[0], @Description.HpetRoute[0], AbiClockNameCapacity);
  DescribeBroadcastTimer(@Information.BroadcastTimer[0], SizeOf(Information.BroadcastTimer));
  Result := -Int64(CopyToUser(InformationAddress, @Information, SizeOf(Information)));
end;

end.
