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
  The system's commit charge: how many pages of private memory all
  processes together may come to use - what they committed (heap,
  stacks, thread data, committed parts of reservations) and the private
  copies their writable images and copy on write file mappings may need
  - whether or not those pages were touched yet. Each address space
  keeps its own share (Processes.AddressSpace: CommitChargeOf) and adds
  every change here as well.

  Nothing is refused on the system's total yet: it is what a policy for
  running out of memory looks at (the processes' shares, against the RAM
  there is), next to the per-process commit limit that is enforced.
}
unit Memory.CommitCharge;

{$mode objfpc}

interface

{ Adds Pages (positive or negative) to the system's commit charge. }
procedure ChangeSystemCommitCharge(Pages: Int64);
{ The pages committed by all processes together. }
function SystemCommittedPages: QWord;
{ The most there ever were. }
function PeakSystemCommittedPages: QWord;

implementation

uses
  Kernel.SpinLock,
  Kernel.PriorityLevel;

var
  ChargeLock: TSpinLock;
  ChargedPages: Int64 = 0;
  PeakPages: Int64 = 0;
  LockReady: Boolean = False;

procedure ChangeSystemCommitCharge(Pages: Int64);
var
  PreviousLevel: TPriorityLevel;
begin
  if not LockReady then
  begin
    InitializeSpinLock(ChargeLock);
    LockReady := True;
  end;
  PreviousLevel := AcquireSpinLock(ChargeLock);
  ChargedPages := ChargedPages + Pages;
  if ChargedPages > PeakPages then
    PeakPages := ChargedPages;
  ReleaseSpinLock(ChargeLock, PreviousLevel);
end;

function SystemCommittedPages: QWord;
begin
  if ChargedPages < 0 then
    Exit(0);
  Result := QWord(ChargedPages);
end;

function PeakSystemCommittedPages: QWord;
begin
  Result := QWord(PeakPages);
end;

end.
