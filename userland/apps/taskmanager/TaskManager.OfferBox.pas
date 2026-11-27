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
  The question offering to end processes outright (they did not end
  when asked, or do not respond), which the task manager puts up on
  its own rather than because the user just chose something.

  The processes may end while the question is on the screen - they
  finally finished saving, or the user ended them another way (End now
  from a menu that was still open) - and then there is nothing left to
  answer: every second (whatever the update speed) the task manager
  calls WithdrawSettledOffer, which takes the question down (as No)
  once none of its processes runs any more.
  Without that the question would stay up, modal, over a task manager
  the user can no longer use until they answer it, and a Yes would end
  nothing.
}
unit TaskManager.OfferBox;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  TaskManager.Targets;

{ Asks the Yes/No Question about Targets (owned by Owner): True for
  Yes. False for No, and when every target ended meanwhile. }
function AskOfferToEnd(Owner: TWindow; const Question: string; const Targets: TProcessTargets): Boolean;
{ Takes the question down if none of its processes runs. }
procedure WithdrawSettledOffer;
{ Of Targets, those that still run. }
function TargetsStillRunning(const Targets: TProcessTargets): TProcessTargets;

implementation

uses
  Controls.Dialogs,
  Controls.MessageBoxes,
  TaskManager.EndWatch,
  TaskManager.Output;

const
  ProgramName = 'Task Manager';

type
  { Keeps the dialog of the question on the screen (OnShowing hands it
    over), so a look can take it down. }
  TOfferedQuestion = class
  public
    Dialog: TDialog;
    Targets: TProcessTargets;
    procedure Showing(ADialog: TDialog);
  end;

var
  { The question on the screen, or nil. }
  Offered: TOfferedQuestion;

procedure TOfferedQuestion.Showing(ADialog: TDialog);
begin
  Dialog := ADialog;
end;

function TargetsStillRunning(const Targets: TProcessTargets): TProcessTargets;
var
  Index: LongInt;
begin
  Result := nil;
  for Index := 0 to High(Targets) do
    if IsStillRunning(Targets[Index].ProcessId) then
      AddTarget(Result, Targets[Index]);
end;

function AskOfferToEnd(Owner: TWindow; const Question: string; const Targets: TProcessTargets): Boolean;
const
  Yes = 0;
  No = 1;
var
  Options: TChoiceBoxOptions;
  Shown: TOfferedQuestion;
  Outer: TOfferedQuestion;
begin
  Options := Default(TChoiceBoxOptions);
  SetLength(Options.Captions, 2);
  Options.Captions[Yes] := '&Yes';
  Options.Captions[No] := '&No';
  Options.CancelIndex := No;
  Shown := TOfferedQuestion.Create;
  Shown.Targets := Targets;
  Options.OnShowing := @Shown.Showing;
  Outer := Offered;
  Offered := Shown;
  try
    Result := ShowChoiceBox(ProgramName, Question, Options, SignWarning, Owner) = Yes;
  finally
    Offered := Outer;
    Shown.Free;
  end;
end;

procedure WithdrawSettledOffer;
begin
  if (Offered = nil) or (Offered.Dialog = nil) then
    Exit;
  if Length(TargetsStillRunning(Offered.Targets)) > 0 then
    Exit;
  Say('offer withdrawn');
  Offered.Dialog.EndModal(ResultCancel);
  Offered.Dialog := nil;
end;

end.
