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
  How a long operation is getting on, in libcontrols' progress dialog
  (Controls.ProgressDialog: a heading, the percentage, a bar, Pause and
  Cancel, and "More details" with the speed, the time left, the item
  being done, what is left and a graph of the speed).

  It is made hidden when the operation starts and shows itself only
  once the operation has run for a while (the user's ProgressDelay), so
  a quick one never flashes a window. It is not modal. It looks at the
  operation's progress a few times a second (FileManager.
  OperationProgress); Pause holds the worker at its next piece of work,
  Cancel (and the close button) asks it to stop there.
}
unit FileManager.ProgressWindow;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  Controls.ProgressDialog,
  FileManager.OperationTypes,
  FileManager.OperationProgress;

type
  TProgressWindow = class(TProgressDialog)
  private
    FProgress: TOperationProgress;
    FKind: TOperationKind;
    FStartTime: QWord;
    FDelay: LongWord;
    FShown: Boolean;
    procedure ShowProgress;
    procedure ShowWhenDue;
    procedure Paused(Sender: TProgressDialog; IsPaused: Boolean);
    procedure Cancelled(Sender: TProgressDialog);
  protected
    procedure TimerFired(TimerId: LongWord); override;
  public
    { For an operation of Kind on ItemCount items from SourceFolder into
      TargetFolder (either may be ''), shown after Delay milliseconds. }
    constructor CreateFor(AOwner: TWindow; AKind: TOperationKind; const SourceFolder, TargetFolder: string;
      ItemCount: LongInt; AProgress: TOperationProgress; ADelay: LongWord);
    procedure StopUpdating;
  end;

implementation

uses
  SysUtils,
  Sys.Time,
  Drawing.Rectangles,
  Controls.FileNames,
  FileManager.TestPlaces,
  FileManager.Output;

const
  UpdateTimer = 1;
  UpdateMilliseconds = 250;

function ItemsText(Count: LongInt): string;
begin
  if Count = 1 then
    Result := '1 item'
  else
    Result := IntToStr(Count) + ' items';
end;

function FolderName(const Path: string): string;
begin
  Result := LastPartOf(Path);
  if Result = '' then
    Result := Path;
end;

constructor TProgressWindow.CreateFor(AOwner: TWindow; AKind: TOperationKind; const SourceFolder,
  TargetFolder: string; ItemCount: LongInt; AProgress: TOperationProgress; ADelay: LongWord);
var
  Heading: string;
begin
  inherited CreateProgress(AOwner, OperationVerb(AKind));
  FProgress := AProgress;
  FKind := AKind;
  FDelay := ADelay;
  FStartTime := UptimeMilliseconds;
  Heading := OperationVerb(AKind) + ' ' + ItemsText(ItemCount);
  if SourceFolder <> '' then
    Heading := Heading + ' from ' + FolderName(SourceFolder);
  if TargetFolder <> '' then
    Heading := Heading + ' to ' + FolderName(TargetFolder);
  SetHeading(Heading);
  OnPauseChanged := @Paused;
  OnCancel := @Cancelled;
  StartTimer(UpdateTimer, UpdateMilliseconds);
  ShowProgress;
  ShowWhenDue;
end;

procedure TProgressWindow.StopUpdating;
begin
  StopTimer(UpdateTimer);
end;

procedure TProgressWindow.ShowProgress;
var
  State: TProgressSnapshot;
begin
  State := FProgress.Snapshot;
  if State.Phase = PhaseCounting then
  begin
    UpdateProgress(0, 0, 0, 0, 'Counting the items...');
    Exit;
  end;
  UpdateProgress(State.DoneBytes, State.TotalBytes, State.DoneFiles, State.TotalFiles, State.CurrentName);
end;

procedure TProgressWindow.TimerFired(TimerId: LongWord);
begin
  if TimerId <> UpdateTimer then
  begin
    inherited TimerFired(TimerId);
    Exit;
  end;
  ShowProgress;
  ShowWhenDue;
end;

procedure TProgressWindow.ShowWhenDue;
var
  Box: TRectangle;
begin
  if FShown or (UptimeMilliseconds - FStartTime < FDelay) then
    Exit;
  FShown := True;
  Show;
  Say('progress-shown ' + LowerCase(OperationVerb(FKind)));
  Box := CancelButtonBounds;
  TellPlace('progress-cancel', Root, Box.Left + RectangleWidth(Box) div 2, Box.Top + RectangleHeight(Box) div 2);
  Box := PauseButtonBounds;
  TellPlace('progress-pause', Root, Box.Left + RectangleWidth(Box) div 2, Box.Top + RectangleHeight(Box) div 2);
  Box := DetailsToggleBounds;
  TellPlace('progress-details', Root, Box.Left + RectangleWidth(Box) div 2, Box.Top + RectangleHeight(Box) div 2);
end;

procedure TProgressWindow.Paused(Sender: TProgressDialog; IsPaused: Boolean);
begin
  FProgress.SetPaused(IsPaused);
  if IsPaused then
    Say('progress-paused')
  else
    Say('progress-resumed');
end;

procedure TProgressWindow.Cancelled(Sender: TProgressDialog);
begin
  FProgress.SetPaused(False);
  FProgress.Cancel;
  Say('progress-cancelled');
end;

end.
