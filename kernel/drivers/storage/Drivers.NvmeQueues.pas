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

  Each queue here is one page (64 commands, 64 completions); the
  queues are used one command at a time. Every command gets an
  identifier of its own, and only the completion carrying the
  identifier of the command waited for counts: one that comes late,
  for a command already given up, is taken off the queue and dropped
  (TakeCompletionFor), never mistaken for the next command's.

  Plain Pascal with no kernel dependencies past the runtime: the memory
  and doorbells are the caller's (Drivers.NvmeQueueMemory allocates
  them), and the host test tools/NvmeQueueTest drives a queue pair in
  memory.
}
unit Drivers.NvmeQueues;

{$mode objfpc}
{$pointermath on}

interface

const
  NvmeQueueEntries = 64;
  NvmeCommandSize = 64;
  NvmeCompletionSize = 16;
  NvmeCompletionPhaseBit = $10000;

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
    { Where the controller finds the queues (bus addresses, Io.Dma). }
    SubmissionsBusAddress: QWord;
    Completions: PNvmeCompletion;
    CompletionsBusAddress: QWord;
    SubmissionTail: Word;
    CompletionHead: Word;
    ExpectedPhase: LongWord;
    SubmissionDoorbell: PLongWord;
    CompletionDoorbell: PLongWord;
    NextCommandIdentifier: Word;
  end;

{ Empties the queues (as a controller that was reset expects them):
  zeroed, at their first entries, expecting phase 1. }
procedure ResetQueuePair(var Pair: TNvmeQueuePair);

{ Copies Command into the next submission slot (setting its identifier)
  and rings the doorbell; returns the identifier. }
function SubmitCommand(var Pair: TNvmeQueuePair; var Command: TNvmeCommand): Word;
{ If a new completion is there, frees its slot and returns True with the
  identifier of its command and its status (0 = success). }
function TakeCompletion(var Pair: TNvmeQueuePair; out Identifier: Word; out Status: Word): Boolean;
{ Takes completions until the one of command Identifier: True with its
  status if it is there; others are dropped. False if it has not come
  yet. }
function TakeCompletionFor(var Pair: TNvmeQueuePair; Identifier: Word; out Status: Word): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Atomic;

procedure ResetQueuePair(var Pair: TNvmeQueuePair);
begin
  FillMemory(Pair.Submissions, NvmeQueueEntries * NvmeCommandSize, 0);
  FillMemory(Pair.Completions, NvmeQueueEntries * NvmeCompletionSize, 0);
  Pair.SubmissionTail := 0;
  Pair.CompletionHead := 0;
  Pair.ExpectedPhase := NvmeCompletionPhaseBit;
end;

function SubmitCommand(var Pair: TNvmeQueuePair; var Command: TNvmeCommand): Word;
begin
  Result := Pair.NextCommandIdentifier;
  Command.OpcodeAndIdentifier := (Command.OpcodeAndIdentifier and $FF) or (LongWord(Result) shl 16);
  Inc(Pair.NextCommandIdentifier);
  Pair.Submissions[Pair.SubmissionTail] := Command;
  Pair.SubmissionTail := (Pair.SubmissionTail + 1) mod NvmeQueueEntries;
  FullMemoryBarrier;
  Pair.SubmissionDoorbell^ := Pair.SubmissionTail;
end;

function TakeCompletion(var Pair: TNvmeQueuePair; out Identifier: Word; out Status: Word): Boolean;
var
  Entry: PNvmeCompletion;
  Word3: LongWord;
begin
  Identifier := 0;
  Status := 0;
  Entry := @Pair.Completions[Pair.CompletionHead];
  Word3 := PLongWord(@Entry^.IdentifierPhaseStatus)^;
  Result := (Word3 and NvmeCompletionPhaseBit) = Pair.ExpectedPhase;
  if not Result then
    Exit;
  { The rest only once the phase says the entry is complete. }
  FullMemoryBarrier;
  Identifier := Word(Word3);
  Status := Word(Word3 shr 17);
  Pair.CompletionHead := (Pair.CompletionHead + 1) mod NvmeQueueEntries;
  if Pair.CompletionHead = 0 then
    Pair.ExpectedPhase := Pair.ExpectedPhase xor NvmeCompletionPhaseBit;
  FullMemoryBarrier;
  Pair.CompletionDoorbell^ := Pair.CompletionHead;
end;

function TakeCompletionFor(var Pair: TNvmeQueuePair; Identifier: Word; out Status: Word): Boolean;
var
  Taken: Word;
  Guard: Integer;
begin
  Status := 0;
  { At most a queue's worth: the controller cannot have more there. }
  for Guard := 1 to NvmeQueueEntries do
  begin
    if not TakeCompletion(Pair, Taken, Status) then
      Exit(False);
    if Taken = Identifier then
      Exit(True);
  end;
  Result := False;
end;

end.
