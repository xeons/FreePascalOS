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
  Reaching the current processor's data block on AArch64.

  Every processor keeps a pointer to its block (Kernel.Processors) in
  TPIDR_EL1, a register user mode cannot read or change, so nothing needs
  swapping on the way in and out of user mode (user code has TPIDR_EL0
  for its thread pointer).

  Reading the running thread takes two loads (the block, then its field),
  so it is done with interrupts masked: the thread cannot move to another
  processor in between.
}
unit Kernel.Arch.ProcessorBlock;

{$mode objfpc}

interface

const
  { Offsets of the fixed fields of TProcessor (Kernel.Processors). }
  ProcessorSelfOffset = 0;
  ProcessorRunningThreadOffset = 8;
  ProcessorSystemCallStackOffset = 16;
  ProcessorUserStackScratchOffset = 24;

{ Makes Block the current processor's block. }
procedure ArchSetProcessorBlock(Block: Pointer);

function ArchCurrentProcessorBlock: Pointer; external name 'ArchReadProcessorBlock';
{ The running thread of the current processor. }
function ArchCurrentThreadBlock: Pointer; external name 'ArchReadRunningThread';

implementation

procedure ArchWriteProcessorBlock(Block: Pointer); external name 'ArchWriteProcessorBlock';

procedure ArchSetProcessorBlock(Block: Pointer);
begin
  ArchWriteProcessorBlock(Block);
end;

end.
