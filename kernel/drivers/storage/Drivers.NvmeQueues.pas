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
  NVMe queue pairs.

  An NVMe controller works through pairs of rings in memory: the host
  writes 64-byte commands into a submission queue and tells the
  controller with a doorbell (the new tail); the controller writes
  16-byte completions into the completion queue. A completion entry's
  phase bit flips each time the controller wraps around the queue, so
  the host recognizes new entries without being told where they end; it
  frees them by writing the completion queue's doorbell (the new head).

  Each queue here is one page (64 commands, 256 completions at most);
  the queues are used one command at a time.
}
unit Drivers.NvmeQueues;

{$mode objfpc}
{$pointermath on}

interface

const
  NvmeQueueEntries = 64;
  NvmeCommandSize = 64;
  NvmeCompletionSize = 16;

type
  TNvmeCommand = packed record
    OpcodeAndIdentifier: LongWord;
    NamespaceId: LongWord;
    Reserved: QWord;
    MetadataPointer: QWord;
    DataPointer1: QWord;
    DataPointer2: QWord;
    CommandDword10: LongWord;
    CommandDword11: LongWord;
    CommandDword12: LongWord;
    CommandDword13: LongWord;
    CommandDword14: LongWord;
    CommandDword15: LongWord;
  end;
  PNvmeCommand = ^TNvmeCommand;

  TNvmeCompletion = packed record
    CommandSpecific: LongWord;
    Reserved: LongWord;
    SubmissionHeadAndQueue: LongWord;
    IdentifierPhaseStatus: LongWord;
  end;
  PNvmeCompletion = ^TNvmeCompletion;

  PNvmeQueuePair = ^TNvmeQueuePair;
  TNvmeQueuePair = record
    Identifier: Word;
    Submissions: PNvmeCommand;
    SubmissionsPhysical: QWord;
    Completions: PNvmeCompletion;
    CompletionsPhysical: QWord;
    SubmissionTail: Word;
    CompletionHead: Word;
    ExpectedPhase: LongWord;
    SubmissionDoorbell: PLongWord;
    CompletionDoorbell: PLongWord;
    NextCommandIdentifier: Word;
  end;

{ Allocates the queues' pages; the doorbells follow from Registers, the
  doorbell stride and the queue's identifier. }
function AllocateQueuePair(Identifier: Word; Registers: PByte; DoorbellStride: LongWord;
  out Pair: TNvmeQueuePair): Boolean;

{ Copies Command into the next submission slot (setting its identifier)
  and rings the doorbell. }
procedure SubmitCommand(var Pair: TNvmeQueuePair; var Command: TNvmeCommand);
{ If a new completion is there, frees its slot and returns True with its
  status (0 = success). }
function TakeCompletion(var Pair: TNvmeQueuePair; out Status: Word): Boolean;
{ Submits Command and waits up to TimeoutMilliseconds for its completion. }
function ExecuteCommand(var Pair: TNvmeQueuePair; var Command: TNvmeCommand;
  TimeoutMilliseconds: QWord): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Atomic,
  Kernel.Arch.Cpu,
  Kernel.Clock,
  Memory.Layout,
  Memory.PhysicalPages;

const
  DoorbellBase = $1000;
  CompletionPhaseBit = $10000;

function AllocateQueuePair(Identifier: Word; Registers: PByte; DoorbellStride: LongWord;
  out Pair: TNvmeQueuePair): Boolean;
begin
  FillMemory(@Pair, SizeOf(Pair), 0);
  Pair.Identifier := Identifier;
  Pair.SubmissionsPhysical := AllocateZeroedPhysicalPage(PageUsageGeneral);
  Pair.CompletionsPhysical := AllocateZeroedPhysicalPage(PageUsageGeneral);
  Result := (Pair.SubmissionsPhysical <> 0) and (Pair.CompletionsPhysical <> 0);
  if not Result then
    Exit;
  Pair.Submissions := PNvmeCommand(PhysicalToVirtual(Pair.SubmissionsPhysical));
  Pair.Completions := PNvmeCompletion(PhysicalToVirtual(Pair.CompletionsPhysical));
  Pair.SubmissionDoorbell := PLongWord(Registers + DoorbellBase + (2 * Identifier) * DoorbellStride);
  Pair.CompletionDoorbell := PLongWord(Registers + DoorbellBase + (2 * Identifier + 1) * DoorbellStride);
  Pair.ExpectedPhase := CompletionPhaseBit;
end;

procedure SubmitCommand(var Pair: TNvmeQueuePair; var Command: TNvmeCommand);
begin
  Command.OpcodeAndIdentifier := (Command.OpcodeAndIdentifier and $FF) or
    (LongWord(Pair.NextCommandIdentifier) shl 16);
  Inc(Pair.NextCommandIdentifier);
  Pair.Submissions[Pair.SubmissionTail] := Command;
  Pair.SubmissionTail := (Pair.SubmissionTail + 1) mod NvmeQueueEntries;
  FullMemoryBarrier;
  Pair.SubmissionDoorbell^ := Pair.SubmissionTail;
end;

function TakeCompletion(var Pair: TNvmeQueuePair; out Status: Word): Boolean;
var
  Entry: PNvmeCompletion;
begin
  FullMemoryBarrier;
  Entry := @Pair.Completions[Pair.CompletionHead];
  Result := (Entry^.IdentifierPhaseStatus and CompletionPhaseBit) = Pair.ExpectedPhase;
  if not Result then
    Exit;
  Status := Word(Entry^.IdentifierPhaseStatus shr 17);
  Pair.CompletionHead := (Pair.CompletionHead + 1) mod NvmeQueueEntries;
  if Pair.CompletionHead = 0 then
    Pair.ExpectedPhase := Pair.ExpectedPhase xor CompletionPhaseBit;
  FullMemoryBarrier;
  Pair.CompletionDoorbell^ := Pair.CompletionHead;
end;

function ExecuteCommand(var Pair: TNvmeQueuePair; var Command: TNvmeCommand;
  TimeoutMilliseconds: QWord): Boolean;
var
  Deadline: QWord;
  Status: Word;
begin
  SubmitCommand(Pair, Command);
  Deadline := ClockTickCount + MillisecondsToTicks(TimeoutMilliseconds);
  while not TakeCompletion(Pair, Status) do
  begin
    if ClockTickCount > Deadline then
      Exit(False);
    CpuRelax;
  end;
  Result := Status = 0;
end;

end.
