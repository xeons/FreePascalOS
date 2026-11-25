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
  Host test of the NVMe queue pairs (make nvme-queue-test:
  Drivers.NvmeQueues), with the controller played in memory: commands
  get identifiers of their own and ring the doorbell; a completion is
  taken only while its phase is the expected one, the phase flipping at
  each wrap; and a completion that comes late, for a command given up
  after a timeout, is dropped instead of being taken for the next
  command's (which is what the driver used to do: the next read then
  "finished" before its data was there).

  Prints every failed check and exits with 1 if there was one.
}
program NvmeQueueTest;

{$mode objfpc}
{$pointermath on}

uses
  SysUtils,
  Drivers.NvmeQueues;

var
  Failures: Integer = 0;
  Submissions: array[0..NvmeQueueEntries - 1] of TNvmeCommand;
  Completions: array[0..NvmeQueueEntries - 1] of TNvmeCompletion;
  SubmissionDoorbell: LongWord;
  CompletionDoorbell: LongWord;
  { The controller's side: where it writes the next completion, and
    with which phase. }
  ControllerTail: Integer;
  ControllerPhase: LongWord;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    WriteLn('NVME QUEUE TEST: failed: ', What);
    Inc(Failures);
  end;
end;

procedure CheckNumber(Actual, Expected: Int64; const What: string);
begin
  Check(Actual = Expected, What + ' is ' + IntToStr(Actual) + ', expected ' + IntToStr(Expected));
end;

procedure SetUpPair(out Pair: TNvmeQueuePair);
begin
  FillChar(Pair, SizeOf(Pair), 0);
  Pair.Identifier := 1;
  Pair.Submissions := @Submissions[0];
  Pair.Completions := @Completions[0];
  Pair.SubmissionDoorbell := @SubmissionDoorbell;
  Pair.CompletionDoorbell := @CompletionDoorbell;
  ResetQueuePair(Pair);
  ControllerTail := 0;
  ControllerPhase := NvmeCompletionPhaseBit;
end;

{ The controller completes command Identifier with Status. }
procedure Complete(Identifier, Status: Word);
begin
  Completions[ControllerTail].IdentifierPhaseStatus := Identifier or ControllerPhase or (LongWord(Status) shl 17);
  Inc(ControllerTail);
  if ControllerTail = NvmeQueueEntries then
  begin
    ControllerTail := 0;
    ControllerPhase := ControllerPhase xor NvmeCompletionPhaseBit;
  end;
end;

function Submit(var Pair: TNvmeQueuePair): Word;
var
  Command: TNvmeCommand;
begin
  FillChar(Command, SizeOf(Command), 0);
  Command.OpcodeAndIdentifier := $02;
  Result := SubmitCommand(Pair, Command);
end;

procedure TestIdentifiers;
var
  Pair: TNvmeQueuePair;
  First: Word;
  Second: Word;
begin
  SetUpPair(Pair);
  First := Submit(Pair);
  Second := Submit(Pair);
  Check(First <> Second, 'commands get identifiers of their own');
  CheckNumber(Submissions[1].OpcodeAndIdentifier shr 16, Second, 'the identifier is in the command');
  CheckNumber(Submissions[1].OpcodeAndIdentifier and $FF, $02, 'the opcode is kept');
  CheckNumber(SubmissionDoorbell, 2, 'the doorbell holds the new tail');
end;

procedure TestLateCompletion;
var
  Pair: TNvmeQueuePair;
  GivenUp: Word;
  Next: Word;
  Status: Word;
begin
  SetUpPair(Pair);
  GivenUp := Submit(Pair);
  Check(not TakeCompletionFor(Pair, GivenUp, Status), 'nothing before the controller answers');
  { Given up after a timeout; the next command goes out, then the late
    completion of the first arrives. }
  Next := Submit(Pair);
  Complete(GivenUp, 0);
  Check(not TakeCompletionFor(Pair, Next, Status), 'a late completion is not the next command''s');
  CheckNumber(CompletionDoorbell, 1, 'the late completion was taken off the queue');
  Complete(Next, 5);
  Check(TakeCompletionFor(Pair, Next, Status), 'the next command''s own completion counts');
  CheckNumber(Status, 5, 'its status');
end;

procedure TestPhaseWrap;
var
  Pair: TNvmeQueuePair;
  Round: Integer;
  Identifier: Word;
  Status: Word;
  Taken: Integer;
begin
  SetUpPair(Pair);
  Taken := 0;
  for Round := 1 to 3 * NvmeQueueEntries + 5 do
  begin
    Identifier := Submit(Pair);
    Complete(Identifier, 0);
    if TakeCompletionFor(Pair, Identifier, Status) and (Status = 0) then
      Inc(Taken);
    Check(not TakeCompletionFor(Pair, Identifier, Status), 'a completion is taken once');
  end;
  CheckNumber(Taken, 3 * NvmeQueueEntries + 5, 'completions taken over three wraps');
  CheckNumber(Pair.CompletionHead, 5, 'the completion head after three wraps');
end;

begin
  TestIdentifiers;
  TestLateCompletion;
  TestPhaseWrap;
  if Failures > 0 then
  begin
    WriteLn('NVME QUEUE TEST FAILED: ', Failures, ' checks');
    Halt(1);
  end;
  WriteLn('NVME QUEUE TEST PASSED');
end.
