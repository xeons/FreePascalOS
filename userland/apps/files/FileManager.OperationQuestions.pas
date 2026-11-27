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
  How the worker thread of a file operation asks the user something (a
  name already taken, an error) and waits for the answer, while the
  window's thread stays free to ask it.

  The worker puts its question here and posts MessageOperationQuestion
  to the receiver (the operation runner, on the window's thread), then
  sleeps on an event. The runner shows a dialog, puts the answer here
  and sets the event; the worker wakes with it. Only one question is
  ever waiting: the worker asks one at a time.

  An answer remembered with "apply to all" is kept here too, so later
  questions of the same kind are answered at once without bothering the
  user (or the window's thread).
}
unit FileManager.OperationQuestions;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Messages,
  FileManager.OperationTypes;

const
  MessageOperationQuestion = MessageUser + 20;

type
  TQuestionChannel = class
  private
    FReceiver: TMessageReceiver;
    FEvent: Int64;
    FQuestion: TOperationQuestion;
    FAnswer: TOperationAnswer;
    FHasStandingAnswer: array[TQuestionKind] of Boolean;
    FStandingAnswer: array[TQuestionKind] of TOperationAnswer;
  public
    constructor Create(AReceiver: TMessageReceiver);
    destructor Destroy; override;
    { (The worker's thread.) Asks Question and waits for the answer. }
    function Ask(const Question: TOperationQuestion): TOperationAnswer;
    { (The window's thread.) The question waiting, and its answer. }
    function PendingQuestion: TOperationQuestion;
    procedure Answer(const AAnswer: TOperationAnswer);
  end;

implementation

uses
  Sys.Objects;

const
  WaitForever = -1;

constructor TQuestionChannel.Create(AReceiver: TMessageReceiver);
begin
  inherited Create;
  FReceiver := AReceiver;
  FEvent := CreateEvent(False, False);
end;

destructor TQuestionChannel.Destroy;
begin
  if FEvent >= 0 then
    CloseHandle(FEvent);
  inherited Destroy;
end;

function TQuestionChannel.Ask(const Question: TOperationQuestion): TOperationAnswer;
begin
  if FHasStandingAnswer[Question.Kind] then
    Exit(FStandingAnswer[Question.Kind]);
  FQuestion := Question;
  { If the message cannot be posted (or there is no event) nobody can
    answer: stop rather than wait for ever. }
  if (FEvent < 0) or not PostMessage(FReceiver, MessageOperationQuestion, PtrInt(Self)) then
  begin
    Result.ApplyToAll := False;
    if Question.Kind = QuestionConflict then
      Result.Choice := Ord(ConflictStop)
    else
      Result.Choice := Ord(ErrorStop);
    Exit;
  end;
  WaitForHandle(FEvent, WaitForever);
  Result := FAnswer;
  if Result.ApplyToAll then
  begin
    FHasStandingAnswer[Question.Kind] := True;
    FStandingAnswer[Question.Kind] := Result;
  end;
end;

function TQuestionChannel.PendingQuestion: TOperationQuestion;
begin
  Result := FQuestion;
end;

procedure TQuestionChannel.Answer(const AAnswer: TOperationAnswer);
begin
  FAnswer := AAnswer;
  SetEvent(FEvent);
end;

end.
