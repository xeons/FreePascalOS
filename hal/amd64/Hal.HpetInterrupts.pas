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
  Where an HPET comparator's interrupt goes.

  One comparator is taken for the kernel's event timer (Hal.HpetEvent-
  Timer), and its interrupt is sent to the boot processor the first of
  these ways that works:
  1. A message (FSB delivery: the comparator writes the vector straight
     into the local APIC's window, like MSI) where the comparator can,
     and interrupt remapping is off (with remapping on, the message
     would need an entry of the remapping table with the HPET's source
     id from the DMAR or IVRS table).
  2. An I/O APIC input the comparator's route capability allows that
     nothing else uses, edge triggered and active high: input 2 (the
     PIT's line; its channel 0 is silenced first), then inputs above 23.
     The input is kept (Hal.InterruptController) so no driver can take
     it over.
  3. Legacy replacement, only when neither works and the HPET can:
     comparator 0 then drives ISA IRQ 0 (through the MADT's override,
     usually input 2), and the PIT's and RTC's interrupts are cut off.
  4. Input 8 (the RTC's line, which its alarm raises too), then the
     first of 16-23 still free (PCI interrupt lines on most chipsets).
  Each way is checked before it is kept: the comparator is armed 1 ms
  ahead three times and its interrupt must arrive no more than 2 ms late
  each time (Hal.HpetEventTimer), else the way is undone and the next
  tried; if no way is on time, a second round takes the first whose
  interrupt arrives at all (within 50 ms). That is not only caution:
  KVM's in-kernel interrupt controller routes ISA IRQ 0 to input 2 but
  has no route for input 2 itself, so a comparator routed there
  interrupts only late and now and then, and legacy replacement is what
  works under KVM.
  Kernel option hpetroute=message, hpetroute=ioapic or hpetroute=legacy
  takes only that way (for tests).
}
unit Hal.HpetInterrupts;

{$mode objfpc}

interface

type
  THpetRouteKind = (HpetRouteNone, HpetRouteMessage, HpetRouteIoApic, HpetRouteLegacy);

  THpetRoute = record
    Kind: THpetRouteKind;
    Comparator: LongWord;
    { The I/O APIC input (HpetRouteIoApic, HpetRouteLegacy). }
    GlobalInterrupt: LongWord;
    { The comparator's configuration bits that select the route. }
    ConfigurationBits: LongWord;
  end;

type
  { Arms the comparator on Route and waits for its interrupt: True if it
    came (and when Strict, on time, several times). }
  THpetRouteCheck = function(constref Route: THpetRoute; Strict: Boolean): Boolean;

{ Picks a comparator and routes it to the processor with APIC id
  TargetApicId as Vector, each way tried checked by Check. The
  comparator's interrupt is left disabled. }
function RouteHpetEventComparator(Vector: Byte; TargetApicId: LongWord; Check: THpetRouteCheck;
  out Route: THpetRoute): Boolean;
{ "message", "I/O APIC input 2", "legacy replacement (IRQ 0, input 2)". }
procedure DescribeHpetRoute(constref Route: THpetRoute; Text: PChar; Capacity: LongWord);

implementation

uses
  Runtime.Text,
  Firmware.Madt,
  Kernel.Options,
  Hal.Hpet,
  Hal.IntervalTimer,
  Hal.InterruptController,
  Hal.InterruptRemapping;

const
  PitInput = 2;
  RtcInput = 8;
  FirstPciInput = 16;
  LastPciInput = 23;
  HighestRouteInput = 31;

var
  RouteCheck: THpetRouteCheck = nil;
  StrictCheck: Boolean = True;

function RouteOption(Value: PChar): Boolean;
var
  Text: array[0..15] of Char;
begin
  Result := GetKernelOptionValue('hpetroute', @Text[0], SizeOf(Text)) and TextIsEqual(@Text[0], Value);
end;

function AnyRouteOption: Boolean;
var
  Text: array[0..15] of Char;
begin
  Result := GetKernelOptionValue('hpetroute', @Text[0], SizeOf(Text));
end;

function MayTry(Value: PChar): Boolean;
begin
  Result := not AnyRouteOption or RouteOption(Value);
end;

{ The bits every route shares: a 32-bit comparator, edge triggered. }
function BaseBits(Comparator: LongWord): LongWord;
begin
  Result := 0;
  if (HpetComparatorConfiguration(Comparator) and Comparator64BitCapable) <> 0 then
    Result := Comparator32BitMode;
end;

{ Leaves the comparator quiet and its line free again. }
procedure UndoRoute(constref Route: THpetRoute);
begin
  WriteHpetComparatorConfiguration(Route.Comparator, BaseBits(Route.Comparator));
  case Route.Kind of
    HpetRouteIoApic:
      ReleasePlatformTimerInterrupt(Route.GlobalInterrupt);
    HpetRouteLegacy:
      begin
        SetHpetLegacyReplacement(False);
        ReleasePlatformTimerInterrupt(Route.GlobalInterrupt);
      end;
  end;
end;

{ Route is set up: keeps it if its interrupt comes. }
function Verified(constref Route: THpetRoute): Boolean;
begin
  Result := (RouteCheck = nil) or RouteCheck(Route, StrictCheck);
  if not Result then
    UndoRoute(Route);
end;

function TryMessage(Vector: Byte; TargetApicId: LongWord; var Route: THpetRoute): Boolean;
var
  Comparator: LongWord;
  Address: QWord;
  Data: LongWord;
begin
  Result := False;
  if InterruptRemappingKind <> RemappingNone then
    Exit;
  Comparator := 0;
  while Comparator < HpetComparatorTotal do
  begin
    if ((HpetComparatorConfiguration(Comparator) and ComparatorMessageCapable) <> 0) and
       ComposeMessageInterrupt(0, Vector, TargetApicId, Address, Data) then
    begin
      WriteHpetMessageRoute(Comparator, LongWord(Address), Data);
      Route.Kind := HpetRouteMessage;
      Route.Comparator := Comparator;
      Route.GlobalInterrupt := 0;
      Route.ConfigurationBits := BaseBits(Comparator) or ComparatorMessageEnable;
      if Verified(Route) then
        Exit(True);
    end;
    Inc(Comparator);
  end;
end;

{ Comparator may be routed to Input, which is free. }
function InputFits(Comparator, Input: LongWord): Boolean;
begin
  Result := (Input <= HighestRouteInput) and
    ((HpetComparatorRouteCapabilities(Comparator) and (LongWord(1) shl Input)) <> 0) and
    DeviceInterruptIsFree(Input);
end;

function RouteToInput(Comparator, Input: LongWord; Vector: Byte; TargetApicId: LongWord;
  var Route: THpetRoute): Boolean;
begin
  if Input = PitInput then
    SilenceIntervalTimerOutput;
  Result := RoutePlatformTimerInterrupt(Input, Vector, TargetApicId, False, False);
  if not Result then
    Exit;
  Route.Kind := HpetRouteIoApic;
  Route.Comparator := Comparator;
  Route.GlobalInterrupt := Input;
  Route.ConfigurationBits := BaseBits(Comparator) or (Input shl ComparatorRouteShift);
  Result := Verified(Route);
end;

function TryInput(Input: LongWord; Vector: Byte; TargetApicId: LongWord; var Route: THpetRoute): Boolean;
var
  Comparator: LongWord;
begin
  Comparator := 0;
  while Comparator < HpetComparatorTotal do
  begin
    if InputFits(Comparator, Input) and RouteToInput(Comparator, Input, Vector, TargetApicId, Route) then
      Exit(True);
    Inc(Comparator);
  end;
  Result := False;
end;

{ Inputs nothing else uses: the PIT's, and those above the PCI lines. }
function TryQuietInputs(Vector: Byte; TargetApicId: LongWord; var Route: THpetRoute): Boolean;
var
  Input: LongWord;
begin
  if TryInput(PitInput, Vector, TargetApicId, Route) then
    Exit(True);
  Input := LastPciInput + 1;
  while Input <= HighestRouteInput do
  begin
    if TryInput(Input, Vector, TargetApicId, Route) then
      Exit(True);
    Inc(Input);
  end;
  Result := False;
end;

{ The RTC's input (its alarm raises it too), then the PCI lines. }
function TryOtherInputs(Vector: Byte; TargetApicId: LongWord; var Route: THpetRoute): Boolean;
var
  Input: LongWord;
begin
  if TryInput(RtcInput, Vector, TargetApicId, Route) then
    Exit(True);
  Input := FirstPciInput;
  while Input <= LastPciInput do
  begin
    if TryInput(Input, Vector, TargetApicId, Route) then
      Exit(True);
    Inc(Input);
  end;
  Result := False;
end;

function TryLegacy(Vector: Byte; TargetApicId: LongWord; var Route: THpetRoute): Boolean;
var
  Routing: TIsaInterruptRouting;
begin
  Result := False;
  if not HpetIsLegacyCapable then
    Exit;
  Routing := RoutingOfIsaInterrupt(0);
  if not DeviceInterruptIsFree(Routing.GlobalInterrupt) then
    Exit;
  if not RoutePlatformTimerInterrupt(Routing.GlobalInterrupt, Vector, TargetApicId, Routing.ActiveLow, False) then
    Exit;
  SetHpetLegacyReplacement(True);
  Route.Kind := HpetRouteLegacy;
  Route.Comparator := 0;
  Route.GlobalInterrupt := Routing.GlobalInterrupt;
  Route.ConfigurationBits := BaseBits(0);
  Result := Verified(Route);
end;

function RouteHpetEventComparator(Vector: Byte; TargetApicId: LongWord; Check: THpetRouteCheck;
  out Route: THpetRoute): Boolean;
begin
  Route.Kind := HpetRouteNone;
  Route.Comparator := 0;
  Route.GlobalInterrupt := 0;
  Route.ConfigurationBits := 0;
  RouteCheck := Check;
  Result := False;
  if not HpetIsPresent then
    Exit;
  { Every way checked strictly first; if none is on time (an emulator
    on a busy host), the first whose interrupt comes at all. }
  StrictCheck := True;
  repeat
    Result := (MayTry('message') and TryMessage(Vector, TargetApicId, Route)) or
      (MayTry('ioapic') and TryQuietInputs(Vector, TargetApicId, Route)) or
      (MayTry('legacy') and TryLegacy(Vector, TargetApicId, Route)) or
      (MayTry('ioapic') and TryOtherInputs(Vector, TargetApicId, Route));
    if Result or not StrictCheck then
      Break;
    StrictCheck := False;
  until False;
  if not Result then
    Route.Kind := HpetRouteNone;
end;

procedure AppendText(Text: PChar; Addition: PChar; Capacity: LongWord);
var
  Used: PtrUInt;
begin
  Used := TextLength(Text);
  if Used + 1 < Capacity then
    CopyText(Text + Used, Addition, Capacity - Used);
end;

procedure AppendNumber(Text: PChar; Capacity: LongWord; Value: LongWord);
var
  Buffer: TNumberText;
begin
  AppendText(Text, FormatDecimal(Value, Buffer), Capacity);
end;

procedure DescribeHpetRoute(constref Route: THpetRoute; Text: PChar; Capacity: LongWord);
begin
  case Route.Kind of
    HpetRouteMessage:
      CopyText(Text, 'message (FSB delivery)', Capacity);
    HpetRouteIoApic:
      begin
        CopyText(Text, 'I/O APIC input ', Capacity);
        AppendNumber(Text, Capacity, Route.GlobalInterrupt);
      end;
    HpetRouteLegacy:
      begin
        CopyText(Text, 'legacy replacement (IRQ 0, input ', Capacity);
        AppendNumber(Text, Capacity, Route.GlobalInterrupt);
        AppendText(Text, ')', Capacity);
      end;
  else
    CopyText(Text, 'none', Capacity);
  end;
end;

end.
