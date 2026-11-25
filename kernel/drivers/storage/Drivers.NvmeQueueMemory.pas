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
  An NVMe queue pair's memory and the polled admin commands.

  The queues are DMA memory of the controller (Io.Dma, shared: mapped
  uncached for a controller that does not snoop, as behind the Pi 5's
  PCIe bridge), handed over at their bus addresses. Its doorbells follow
  from the registers, the doorbell stride and the queue's identifier.
}
unit Drivers.NvmeQueueMemory;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.Dma,
  Drivers.NvmeQueues;

function AllocateQueuePair(constref Dma: TDmaAttributes; Identifier: Word; Registers: PByte;
  DoorbellStride: LongWord; out Pair: TNvmeQueuePair): Boolean;

{ Submits Command and waits up to TimeoutMilliseconds for its own
  completion (a late one of an earlier command is dropped). True if it
  came and succeeded; TimedOut says whether it did not come. }
function ExecuteCommand(var Pair: TNvmeQueuePair; var Command: TNvmeCommand;
  TimeoutMilliseconds: QWord; out TimedOut: Boolean): Boolean;

implementation

uses
  Runtime.Memory,
  Kernel.Arch.Cpu,
  Kernel.Clock;

const
  DoorbellBase = $1000;

function AllocateQueuePair(constref Dma: TDmaAttributes; Identifier: Word; Registers: PByte;
  DoorbellStride: LongWord; out Pair: TNvmeQueuePair): Boolean;
var
  Submissions: TDmaBuffer;
  Completions: TDmaBuffer;
begin
  FillMemory(@Pair, SizeOf(Pair), 0);
  Pair.Identifier := Identifier;
  Result := AllocateDmaBuffer(Dma, NvmeQueueEntries * NvmeCommandSize, DmaShared, Submissions) and
    AllocateDmaBuffer(Dma, NvmeQueueEntries * NvmeCompletionSize, DmaShared, Completions);
  if not Result then
    Exit;
  Pair.Submissions := PNvmeCommand(Submissions.Address);
  Pair.SubmissionsBusAddress := Submissions.DeviceAddress;
  Pair.Completions := PNvmeCompletion(Completions.Address);
  Pair.CompletionsBusAddress := Completions.DeviceAddress;
  Pair.SubmissionDoorbell := PLongWord(Registers + DoorbellBase + (2 * Identifier) * DoorbellStride);
  Pair.CompletionDoorbell := PLongWord(Registers + DoorbellBase + (2 * Identifier + 1) * DoorbellStride);
  Pair.ExpectedPhase := NvmeCompletionPhaseBit;
end;

function ExecuteCommand(var Pair: TNvmeQueuePair; var Command: TNvmeCommand;
  TimeoutMilliseconds: QWord; out TimedOut: Boolean): Boolean;
var
  Deadline: QWord;
  Status: Word;
  Identifier: Word;
begin
  TimedOut := False;
  Identifier := SubmitCommand(Pair, Command);
  Deadline := ClockTickCount + MillisecondsToTicks(TimeoutMilliseconds);
  while not TakeCompletionFor(Pair, Identifier, Status) do
  begin
    if ClockTickCount > Deadline then
    begin
      TimedOut := True;
      Exit(False);
    end;
    CpuRelax;
  end;
  Result := Status = 0;
end;

end.
