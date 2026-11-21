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
  Self tests of the AArch64 platform:

  - the interrupt controller: a GICv2 or GICv3 was found, and a
    dispatch SGI sent to this processor arrives (the dispatcher's own
    software interrupt);
  - address space identifiers: as many bits as the processor offers (or
    asidbits= asks for) are in use, and TCR_EL1.AS matches 16 of them;
  - the real-time clock (a PL031 where there is one): it reads the wall
    clock's time, and a time written to it reads back.
}
unit Kernel.Arch.PlatformSelfTest;

{$mode objfpc}

interface

procedure RunPlatformSelfTest;

implementation

uses
  Runtime.Time,
  Kernel.SelfTest,
  Kernel.WallClock,
  Kernel.Threads,
  Kernel.Events,
  Kernel.DeferredCalls,
  Memory.Arch.AddressSpaceIds,
  Hal.Gic,
  Hal.RealTimeClock;

const
  TranslationControlWideAsids = QWord(1) shl 36;
  ClockToleranceSeconds = 2;

function ArchReadTranslationControl: QWord; external name 'ArchReadTranslationControl';

var
  DeferredCallRan: TEvent;

procedure NoteDeferredCall(Context: Pointer);
begin
  SignalEvent(DeferredCallRan);
end;

procedure TestInterruptController;
var
  Call: TDeferredCall;
begin
  Check(GicVersion in [2, 3], 'the interrupt controller is a GICv2 or GICv3');
  { A deferred call runs from the dispatch SGI this processor sends
    itself. }
  InitializeEvent(DeferredCallRan, EventKindNotification, False);
  InitializeDeferredCall(Call, @NoteDeferredCall, nil);
  QueueDeferredCall(Call);
  Check(WaitForEventWithOptions(DeferredCallRan, 1000, False) = WaitSignaled,
    'a deferred call runs (the dispatch SGI arrives)');
end;

procedure TestAddressSpaceIds;
var
  Wide: Boolean;
begin
  Wide := (ArchReadTranslationControl and TranslationControlWideAsids) <> 0;
  Check(AddressSpaceIdBits in [2..16], 'address space identifiers have 2 to 16 bits');
  Check(Wide or (AddressSpaceIdBits <= 8), 'more than 8 ASID bits only with TCR_EL1.AS');
end;

function Distance(First, Second: TUnixTime): TUnixTime;
begin
  Result := First - Second;
  if Result < 0 then
    Result := -Result;
end;

procedure TestRealTimeClock;
var
  Now: TUnixTime;
begin
  if not RealTimeClockIsKept then
    Exit;
  Now := WallClockSeconds;
  Check(Distance(ReadRealTimeClock, Now) <= ClockToleranceSeconds, 'the PL031 reads the wall clock''s time');
  WriteRealTimeClock(Now);
  Check(Distance(ReadRealTimeClock, Now) <= 1, 'a time written to the PL031 reads back');
end;

procedure RunPlatformSelfTest;
begin
  TestInterruptController;
  TestAddressSpaceIds;
  TestRealTimeClock;
  if RealTimeClockIsKept then
    ReportPassed('AArch64 platform (GIC, ASIDs, PL031)')
  else
    ReportPassed('AArch64 platform (GIC, ASIDs)');
end;

end.
