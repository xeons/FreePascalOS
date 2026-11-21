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
  The regions of a user address space (Processes.AddressSpace): ranges
  of user addresses with fixed attributes, kept in a region tree
  (Processes.RegionTree).
}
unit Processes.UserRegions;

{$mode objfpc}

interface

type
  TRegionKind = (RegionKindImage, RegionKindStack, RegionKindAllocation,
    { A thread's thread control block and static thread-local storage. }
    RegionKindThreadData,
    { Address space below a stack that is never mapped. }
    RegionKindStackGuard,
    { Device memory, mapped when the region was made. }
    RegionKindDevice,
    { A section's pages, mapped when the region was made. }
    RegionKindSection);

  TUserRegion = record
    Start: QWord;
    Length: QWord;
    Attributes: LongWord;
    Kind: TRegionKind;
    CommitsOnDemand: Boolean;
    { Stacks: the bottom ReserveBytes are only provided once a stack
      overflow opened them (ReserveInUse). }
    ReserveInUse: Boolean;
    ReserveBytes: QWord;
    { A run time allocation made for one thread (its threadvar block):
      the id of that thread, which gives the region back if it ends
      without having freed it. 0 for every other region. }
    OwnerThreadId: QWord;
  end;
  PUserRegion = ^TUserRegion;

implementation

end.
