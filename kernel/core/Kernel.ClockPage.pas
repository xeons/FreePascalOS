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
  The clock page: one physical page with the clock's parameters
  (TAbiClockPage), mapped read-only into every program
  (Processes.UserProcess, AuxiliaryClockPage), so that the runtime reads
  the uptime and the wall clock with the processor's counter and no
  system call.

  The page says how the kernel's own clock turns the counter into
  nanoseconds (the counter value at an origin, the time then and the
  rate: HalDescribeUserClock) and the wall clock's offset and gradual
  adjustment (Kernel.WallClock). Both change rarely: at start, when the
  wall clock is set or adjusted, and when the clock continues after
  suspend to RAM. Each change is published with a sequence count, odd
  while the page changes, so a program never uses a half written page.
  Where programs cannot read the kernel's clock (KVM's paravirtual
  clock), the page says so (ClockPageModeSystemCall) and the runtime
  makes the system call instead.
}
unit Kernel.ClockPage;

{$mode objfpc}

interface

uses
  Memory.Layout;

{ Allocates the page and fills it in; after the clock and the wall clock
  have started. }
procedure InitializeClockPage;
{ Writes the clock's current parameters into the page. Any level up to
  DispatchLevel; does nothing before InitializeClockPage. }
procedure PublishClockPage;
{ The page, for mapping it into programs (0 before it exists). }
function ClockPagePhysicalAddress: TPhysicalAddress;
{ Whether programs can read the time from the page. }
function ClockPageOffersCounter: Boolean;

implementation

uses
  Abi.SystemCalls,
  Runtime.Atomic,
  Hal.Platform,
  Kernel.Arch.Cpu,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.WallClock,
  Memory.PhysicalPages,
  Kernel.Panic;

var
  PagePhysical: TPhysicalAddress = 0;
  Page: PAbiClockPage = nil;
  PublishLock: TSpinLock;

procedure InitializeClockPage;
begin
  InitializeSpinLock(PublishLock);
  PagePhysical := AllocateZeroedPhysicalPage(PageUsageGeneral);
  if PagePhysical = 0 then
    KernelPanic('no memory for the clock page');
  Page := PAbiClockPage(PhysicalToVirtual(PagePhysical));
  PublishClockPage;
end;

procedure PublishClockPage;
var
  PreviousLevel: TPriorityLevel;
  WereEnabled: Boolean;
  Origin: QWord;
  OriginNanoseconds: QWord;
  Frequency: QWord;
  Offset: Int64;
  Total: Int64;
  Start: QWord;
  OffersCounter: Boolean;
begin
  if Page = nil then
    Exit;
  PreviousLevel := AcquireSpinLock(PublishLock);
  { Read under the lock, so that two publishers cannot leave the older
    state on the page. }
  ReadWallClockState(Offset, Total, Start);
  { A program on this processor cannot run meanwhile, but the clock
    interrupt must not find the HAL's origin half read. }
  WereEnabled := SaveAndDisableInterrupts;
  OffersCounter := HalDescribeUserClock(Origin, OriginNanoseconds, Frequency);
  Page^.Sequence := Page^.Sequence + 1;
  FullMemoryBarrier;
  if OffersCounter then
    Page^.Mode := ClockPageModeCounter
  else
    Page^.Mode := ClockPageModeSystemCall;
  Page^.CounterOrigin := Origin;
  Page^.OriginNanoseconds := OriginNanoseconds;
  Page^.CounterFrequency := Frequency;
  Page^.WallBaseOffset := Offset;
  Page^.SlewTotal := Total;
  Page^.SlewStart := Start;
  Page^.SlewPartsPerMillion := SlewPartsPerMillion;
  FullMemoryBarrier;
  Page^.Sequence := Page^.Sequence + 1;
  RestoreInterrupts(WereEnabled);
  ReleaseSpinLock(PublishLock, PreviousLevel);
end;

function ClockPagePhysicalAddress: TPhysicalAddress;
begin
  Result := PagePhysical;
end;

function ClockPageOffersCounter: Boolean;
begin
  Result := (Page <> nil) and (Page^.Mode = ClockPageModeCounter);
end;

end.
