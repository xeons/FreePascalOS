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
  Running file operations, one after another, each on a worker thread
  (FileManager.OperationWorker) while the window's thread stays free:
  the window can be used, scrolled and even start more operations,
  which wait their turn.

  For each it makes the progress window (shown if the operation takes
  long), starts the thread and has the message loop watch the thread's
  handle, which becomes ready when the thread ends. The worker's
  questions arrive as posted messages (FileManager.OperationQuestions)
  and are asked in message boxes: a name already taken (Replace, Skip,
  Rename, Stop, and "do this for every conflict"), an error (Skip,
  Stop, and "skip every error"). When the thread has ended, what went
  wrong is printed, then "copied N", "moved N" or "deleted N" (the
  items done whole), and "stopped" if it was stopped; OnFinished tells
  the window.

  CancelAll stops the operation running and forgets the waiting ones;
  OnIdle tells when nothing runs any more (the window closes then, if
  it was asked to while an operation ran).
}
unit FileManager.OperationRunner;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Windowing.Messages,
  Windowing.Windows,
  Controls.Dialogs,
  FileManager.OperationTypes,
  FileManager.OperationProgress,
  FileManager.OperationQuestions,
  FileManager.OperationWorker,
  FileManager.ProgressWindow;

type
  TOperationFinishedEvent = procedure(Sender: TObject; const Request: TOperationRequest;
    const Outcome: TOperationOutcome) of object;
  TRunnerEvent = procedure(Sender: TObject) of object;

  TOperationRunner = class(TMessageReceiver)
  private
    FOwner: TWindow;
    FQueue: array of TOperationRequest;
    FProgress: TOperationProgress;
    FQuestions: TQuestionChannel;
    FWorker: TOperationWorker;
    FThread: Int64;
    FWindow: TProgressWindow;
    FProgressDelay: LongWord;
    FOnFinished: TOperationFinishedEvent;
    FOnIdle: TRunnerEvent;
    procedure StartNext;
    procedure WorkerEnded(Handle: Int64);
    procedure AnswerQuestion;
    function QuestionOwner: TWindow;
    function AskAboutConflict(const Question: TOperationQuestion): TOperationAnswer;
    function AskAboutError(const Question: TOperationQuestion): TOperationAnswer;
    procedure TellQuestionPlaces(Dialog: TDialog);
  public
    constructor Create(AOwner: TWindow; ProgressDelay: LongWord);
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    { Runs Request once those before it are done. }
    procedure Start(const Request: TOperationRequest);
    procedure CancelAll;
    function Busy: Boolean;
    property OnFinished: TOperationFinishedEvent read FOnFinished write FOnFinished;
    property OnIdle: TRunnerEvent read FOnIdle write FOnIdle;
  end;

implementation

uses
  SysUtils,
  Sys.Threads,
  Sys.Time,
  Windowing.HandleWatches,
  Controls.Base,
  Controls.Buttons,
  Controls.Toggles,
  Controls.Text,
  Controls.MessageBoxes,
  Controls.FileNames,
  Controls.FolderListing,
  Drawing.Rectangles,
  FileManager.Items,
  FileManager.TimeTexts,
  FileManager.Paths,
  FileManager.ConflictPolicy,
  FileManager.ErrorTexts,
  FileManager.TestPlaces,
  FileManager.Output;

{ The worker's thread. }
function RunWorker(Argument: Pointer): LongInt;
begin
  TOperationWorker(Argument).Run;
  Result := 0;
end;

constructor TOperationRunner.Create(AOwner: TWindow; ProgressDelay: LongWord);
begin
  inherited Create;
  FOwner := AOwner;
  FProgressDelay := ProgressDelay;
  FThread := -1;
end;

destructor TOperationRunner.Destroy;
begin
  { (The window waits for the worker before it lets the runner go.) }
  FWindow.Free;
  FWorker.Free;
  FQuestions.Free;
  FProgress.Free;
  inherited Destroy;
end;

function TOperationRunner.Busy: Boolean;
begin
  Result := FThread >= 0;
end;

procedure TOperationRunner.Start(const Request: TOperationRequest);
begin
  SetLength(FQueue, Length(FQueue) + 1);
  FQueue[High(FQueue)] := Request;
  if not Busy then
    StartNext;
end;

procedure TOperationRunner.StartNext;
var
  Request: TOperationRequest;
  Index: LongInt;
  ExitCode: LongInt;
begin
  if Length(FQueue) = 0 then
  begin
    if Assigned(FOnIdle) then
      FOnIdle(Self);
    Exit;
  end;
  Request := FQueue[0];
  for Index := 1 to High(FQueue) do
    FQueue[Index - 1] := FQueue[Index];
  SetLength(FQueue, Length(FQueue) - 1);
  FProgress := TOperationProgress.Create;
  FQuestions := TQuestionChannel.Create(Self);
  FWorker := TOperationWorker.Create(Request, FProgress, FQuestions);
  case Request.Kind of
    OperationDelete, OperationTrash, OperationRestore:
      FWindow := TProgressWindow.CreateFor(FOwner, Request.Kind, ParentFolderOf(Request.Sources[0]), '',
        Length(Request.Sources), FProgress, FProgressDelay);
    OperationCompress:
      FWindow := TProgressWindow.CreateFor(FOwner, Request.Kind, ParentFolderOf(Request.Sources[0]),
        Request.TargetFolder, Length(Request.Sources), FProgress, FProgressDelay);
    OperationExtract:
      FWindow := TProgressWindow.CreateFor(FOwner, Request.Kind, Request.Sources[0], Request.TargetFolder, 1,
        FProgress, FProgressDelay);
  else
    FWindow := TProgressWindow.CreateFor(FOwner, Request.Kind, ParentFolderOf(Request.Sources[0]),
      Request.TargetFolder, Length(Request.Sources), FProgress, FProgressDelay);
  end;
  Say('operation ' + LowerCase(OperationVerb(Request.Kind)) + ' ' + IntToStr(Length(Request.Sources)));
  FThread := CreateThread(@RunWorker, FWorker);
  if FThread < 0 then
  begin
    { No thread: done here and now instead (the window waits). }
    FWorker.Run;
    WorkerEnded(-1);
  end
  else if not WatchHandle(FThread, @WorkerEnded) then
  begin
    { Nothing to tell when it ends: wait for it. }
    WaitForThread(FThread, -1, ExitCode);
    CloseThreadHandle(FThread);
    WorkerEnded(-1);
  end;
end;

procedure TOperationRunner.WorkerEnded(Handle: Int64);
var
  ExitCode: LongInt;
  Index: LongInt;
  Request: TOperationRequest;
  Outcome: TOperationOutcome;
begin
  if Handle >= 0 then
  begin
    StopWatchingHandle(Handle);
    WaitForThread(Handle, -1, ExitCode);
    CloseThreadHandle(Handle);
  end;
  FThread := -1;
  for Index := 0 to FWorker.Log.Count - 1 do
    Say(FWorker.Log[Index]);
  Request := FWorker.Request;
  Outcome := FWorker.Outcome;
  Say(OperationPastTense(Request.Kind) + ' ' + IntToStr(Outcome.ItemsDone));
  if Outcome.Stopped then
    Say('stopped');
  FreeAndNil(FWindow);
  FreeAndNil(FWorker);
  FreeAndNil(FQuestions);
  FreeAndNil(FProgress);
  if Assigned(FOnFinished) then
    FOnFinished(Self, Request, Outcome);
  StartNext;
end;

procedure TOperationRunner.CancelAll;
begin
  FQueue := nil;
  if FProgress <> nil then
    FProgress.Cancel;
end;

{ --- Questions ------------------------------------------------------------------------- }

procedure TOperationRunner.ReceiveMessage(var Message: TPostedMessage);
begin
  if (Message.Code = MessageOperationQuestion) and (FQuestions <> nil) and
     (TQuestionChannel(Message.Parameter1) = FQuestions) then
  begin
    AnswerQuestion;
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

function TOperationRunner.QuestionOwner: TWindow;
begin
  if (FWindow <> nil) and FWindow.Visible then
    Result := FWindow
  else
    Result := FOwner;
end;

procedure TOperationRunner.TellQuestionPlaces(Dialog: TDialog);
var
  Index: LongInt;
  Control: TControl;
begin
  for Index := 0 to Dialog.Root.ChildCount - 1 do
  begin
    Control := Dialog.Root.Children[Index];
    if Control is TButton then
      TellControlPlace('question-' + LowerCase(TextWithoutMnemonic(Control.Text)), Control)
    else if Control is TCheckBox then
      TellPlace('question-all', Control, 8, RectangleHeight(Control.PixelBounds) div 2);
  end;
end;

function ItemSummary(const Item: TFolderItem): string;
begin
  if Item.Kind = ItemFolder then
    Result := 'a folder'
  else
    Result := SizeText(Item.SizeInBytes);
  Result := Result + ', modified ' + TimeText(Item.ModificationTime);
end;

function TOperationRunner.AskAboutConflict(const Question: TOperationQuestion): TOperationAnswer;
var
  Options: TChoiceBoxOptions;
  Choices: array of TConflictChoice;
  Text: string;
  Chosen: LongInt;
  procedure AddChoice(const Caption: string; Choice: TConflictChoice);
  begin
    SetLength(Options.Captions, Length(Options.Captions) + 1);
    Options.Captions[High(Options.Captions)] := Caption;
    SetLength(Choices, Length(Choices) + 1);
    Choices[High(Choices)] := Choice;
  end;
begin
  Options := Default(TChoiceBoxOptions);
  Choices := nil;
  if Question.CanReplace then
    AddChoice('&Replace', ConflictReplace);
  AddChoice('&Skip', ConflictSkip);
  AddChoice('&Keep both', ConflictRename);
  AddChoice('Stop', ConflictStop);
  Options.CancelIndex := High(Choices);
  Options.CheckBoxText := '&Do this for all current items';
  Options.OnShowing := @TellQuestionPlaces;
  { The two compared, as the question's "compare info" part. }
  Text := 'The destination already has an item named "' + LastPartOf(Question.TargetPath) + '"' + #10 + '(' +
    ParentFolderOf(Question.TargetPath) + ').' + #10#10 + 'In the destination: ' + ItemSummary(Question.Target) +
    #10 + 'Arriving: ' + ItemSummary(Question.Source) + #10 + CompareText(Question.Source, Question.Target);
  if Question.CanReplace then
    Text := Text + #10#10 + 'Replace the item in the destination, skip this item, or keep both (the arriving one ' +
      'numbered)?'
  else
    Text := Text + #10#10 + 'A folder cannot be replaced: skip this item, or keep both?';
  Say('question conflict ' + LastPartOf(Question.TargetPath));
  Chosen := ShowChoiceBox('Name already used', Text, Options, SignQuestion, QuestionOwner);
  Result.Choice := Ord(Choices[Chosen]);
  Result.ApplyToAll := Options.Checked;
  Say('answer ' + LowerCase(TextWithoutMnemonic(Options.Captions[Chosen])));
end;

function TOperationRunner.AskAboutError(const Question: TOperationQuestion): TOperationAnswer;
var
  Options: TChoiceBoxOptions;
  Chosen: LongInt;
begin
  Options := Default(TChoiceBoxOptions);
  SetLength(Options.Captions, 2);
  Options.Captions[0] := '&Skip';
  Options.Captions[1] := 'Stop';
  Options.CancelIndex := 1;
  Options.CheckBoxText := 'Skip &every error';
  Options.OnShowing := @TellQuestionPlaces;
  Say('question error ' + Question.ErrorPath);
  Chosen := ShowChoiceBox('Cannot ' + Question.Action, 'Cannot ' + Question.Action + ' "' +
    LastPartOf(Question.ErrorPath) + '":' + #10 + ReasonText(Question.Error), Options, SignError, QuestionOwner);
  if Chosen = 0 then
    Result.Choice := Ord(ErrorSkip)
  else
    Result.Choice := Ord(ErrorStop);
  Result.ApplyToAll := (Chosen = 0) and Options.Checked;
end;

procedure TOperationRunner.AnswerQuestion;
var
  Question: TOperationQuestion;
  Answer: TOperationAnswer;
  Channel: TQuestionChannel;
begin
  Channel := FQuestions;
  Question := Channel.PendingQuestion;
  { Cancelled meanwhile: no need to ask. }
  if FProgress.IsCancelled then
  begin
    Answer.ApplyToAll := False;
    if Question.Kind = QuestionConflict then
      Answer.Choice := Ord(ConflictStop)
    else
      Answer.Choice := Ord(ErrorStop);
  end
  else if Question.Kind = QuestionConflict then
    Answer := AskAboutConflict(Question)
  else
    Answer := AskAboutError(Question);
  Channel.Answer(Answer);
end;

end.
