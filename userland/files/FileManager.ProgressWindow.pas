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
  The window showing how a long copy, move or delete is getting on:
  what is being done and where to, the file it is on, a bar, the files
  and bytes done out of all, and Cancel.

  It is made hidden when the operation starts and shows itself only
  once the operation has run for a while (the user's ProgressDelay), so
  a quick one never flashes a window. It is not modal: the file manager
  stays usable meanwhile. It looks at the operation's progress a few
  times a second (FileManager.OperationProgress); Cancel and its close
  button ask the operation to stop, which it does at the next piece of
  work.
}
unit FileManager.ProgressWindow;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  Controls.Base,
  Controls.Window,
  Controls.Labels,
  Controls.Buttons,
  Controls.ProgressBar,
  FileManager.OperationTypes,
  FileManager.OperationProgress;

type
  TProgressWindow = class(TControlWindow)
  private
    FProgress: TOperationProgress;
    FKind: TOperationKind;
    FStartTime: QWord;
    FDelay: LongWord;
    FShown: Boolean;
    FWhatLabel: TLabel;
    FNameLabel: TLabel;
    FAmountLabel: TLabel;
    FBar: TProgressBar;
    FCancelButton: TButton;
    procedure CancelClicked(Sender: TControl);
    procedure ShowProgress;
    procedure ShowWhenDue;
  protected
    procedure TimerFired(TimerId: LongWord); override;
    procedure CloseRequested; override;
  public
    { For an operation of Kind into TargetFolder ('' for a delete), shown
      after Delay milliseconds. }
    constructor CreateFor(AOwner: TWindow; AKind: TOperationKind; const TargetFolder: string; ItemCount: LongInt;
      AProgress: TOperationProgress; ADelay: LongWord);
    procedure StopUpdating;
  end;

implementation

uses
  SysUtils,
  Sys.Time,
  Windowing.Protocol,
  Controls.FileNames,
  Controls.FolderListing,
  FileManager.TestPlaces,
  FileManager.Output;

const
  UpdateTimer = 1;
  UpdateMilliseconds = 150;
  WindowWidth = 420;
  WindowHeight = 150;
  BarSteps = 1000;

function ItemsText(Count: LongInt): string;
begin
  if Count = 1 then
    Result := '1 item'
  else
    Result := IntToStr(Count) + ' items';
end;

constructor TProgressWindow.CreateFor(AOwner: TWindow; AKind: TOperationKind; const TargetFolder: string;
  ItemCount: LongInt; AProgress: TOperationProgress; ADelay: LongWord);
var
  Left: LongInt;
  Top: LongInt;
  What: string;
begin
  Left := AOwner.ScreenLeft + (AOwner.ClientWidth - WindowWidth) div 2;
  Top := AOwner.ScreenTop + (AOwner.ClientHeight - WindowHeight) div 2;
  inherited Create(OperationVerb(AKind), Left, Top, WindowWidth, WindowHeight, WindowFramed, AOwner);
  FProgress := AProgress;
  FKind := AKind;
  FDelay := ADelay;
  FStartTime := UptimeMilliseconds;
  What := OperationVerb(AKind) + ' ' + ItemsText(ItemCount);
  if TargetFolder <> '' then
    What := What + ' to ' + TargetFolder;
  FWhatLabel := TLabel.Create(Root);
  FWhatLabel.ShowsMnemonic := False;
  FWhatLabel.Text := What;
  FWhatLabel.SetBounds(12, 12, WindowWidth - 24, 18);
  FNameLabel := TLabel.Create(Root);
  FNameLabel.ShowsMnemonic := False;
  FNameLabel.SetBounds(12, 34, WindowWidth - 24, 18);
  FBar := TProgressBar.Create(Root);
  FBar.Maximum := BarSteps;
  FBar.SetBounds(12, 58, WindowWidth - 24, 18);
  FAmountLabel := TLabel.Create(Root);
  FAmountLabel.ShowsMnemonic := False;
  FAmountLabel.SetBounds(12, 82, WindowWidth - 24, 18);
  FCancelButton := TButton.Create(Root);
  FCancelButton.Text := 'Cancel';
  FCancelButton.SetBounds(WindowWidth - 12 - 75, WindowHeight - 12 - 23, 75, 23);
  FCancelButton.OnClick := @CancelClicked;
  CancelControl := FCancelButton;
  FocusControl(FCancelButton);
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
  Steps: QWord;
begin
  State := FProgress.Snapshot;
  if State.Phase = PhaseCounting then
  begin
    FNameLabel.Text := 'Counting the files...';
    Exit;
  end;
  if not FProgress.IsCancelled then
    FNameLabel.Text := State.CurrentName;
  { Bytes give the bar when there are any to speak of, files otherwise. }
  if State.TotalBytes > 0 then
    Steps := State.DoneBytes * BarSteps div State.TotalBytes
  else if State.TotalFiles > 0 then
    Steps := State.DoneFiles * BarSteps div State.TotalFiles
  else
    Steps := 0;
  if Steps > BarSteps then
    Steps := BarSteps;
  FBar.Position := Steps;
  FAmountLabel.Text := Format('%d of %d files, %s of %s', [State.DoneFiles, State.TotalFiles,
    SizeText(State.DoneBytes), SizeText(State.TotalBytes)]);
end;

procedure TProgressWindow.TimerFired(TimerId: LongWord);
begin
  if TimerId <> UpdateTimer then
    Exit;
  ShowProgress;
  ShowWhenDue;
end;

{ Shows the window once the operation has run for the delay (at once
  for none). }
procedure TProgressWindow.ShowWhenDue;
begin
  if not FShown and (UptimeMilliseconds - FStartTime >= FDelay) then
  begin
    FShown := True;
    Show;
    Say('progress-shown ' + LowerCase(OperationVerb(FKind)));
    TellControlPlace('progress-cancel', FCancelButton);
  end;
end;

procedure TProgressWindow.CancelClicked(Sender: TControl);
begin
  if FProgress.IsCancelled then
    Exit;
  FProgress.Cancel;
  FNameLabel.Text := 'Stopping...';
  FCancelButton.Enabled := False;
  Say('progress-cancelled');
end;

procedure TProgressWindow.CloseRequested;
begin
  CancelClicked(nil);
end;

end.
