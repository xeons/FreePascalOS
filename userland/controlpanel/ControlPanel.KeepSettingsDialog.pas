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
  "Keep these display settings?": asked after a display's mode or scale
  was changed, with a countdown. A display that shows nothing useful in
  its new mode cannot be answered, so unless Keep is pressed within the
  time, the settings go back as they were: Revert, Escape, closing the
  dialog and the time running out all mean no.

  It says "keep-asked SECONDS" when it appears, where its buttons are
  ("place keep-yes X Y", "place keep-revert X Y"), and "keep-countdown
  N" each second.
}
unit ControlPanel.KeepSettingsDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

const
  KeepSettingsSeconds = 15;

{ True if the user chose to keep the new settings in time. }
function AskToKeepSettings(Owner: TWindow; Seconds: LongInt = KeepSettingsSeconds): Boolean;

implementation

uses
  SysUtils,
  Controls.Labels,
  Controls.Buttons,
  Controls.Dialogs,
  Controls.CommonDialogs,
  ControlPanel.Report;

const
  DialogWidth = 340;
  DialogHeight = 104;
  CountdownTimer = 1;
  { The places are said once the dialog is up and every event before it
    (a new scale) is served. }
  PlacesTimer = 2;
  PlacesDelayMilliseconds = 300;

type
  TKeepSettingsDialog = class(TDialog)
  private
    FMessage: TLabel;
    FKeepButton: TButton;
    FRevertButton: TButton;
    FSecondsLeft: LongInt;
    procedure ShowSecondsLeft;
  protected
    procedure TimerFired(Timer: LongWord); override;
  public
    constructor CreateKeepDialog(AOwner: TWindow; Seconds: LongInt);
    function Ask: Boolean;
  end;

constructor TKeepSettingsDialog.CreateKeepDialog(AOwner: TWindow; Seconds: LongInt);
var
  Question: TLabel;
  Top: LongInt;
begin
  inherited CreateDialog('Display Settings', DialogWidth, DialogHeight, AOwner);
  FSecondsLeft := Seconds;
  Question := TLabel.Create(Root);
  Question.ShowsMnemonic := False;
  Question.Text := 'Keep these display settings?';
  Question.SetBounds(DialogMargin, DialogMargin, DialogWidth - 2 * DialogMargin, 18);
  FMessage := TLabel.Create(Root);
  FMessage.ShowsMnemonic := False;
  FMessage.SetBounds(DialogMargin, DialogMargin + 22, DialogWidth - 2 * DialogMargin, 18);
  Top := DialogHeight - DialogMargin - DialogButtonHeight;
  FRevertButton := AddButton('&Revert', ResultCancel, DialogWidth - DialogMargin - DialogButtonWidth, Top,
    DialogButtonWidth, DialogButtonHeight, False, True);
  FKeepButton := AddButton('&Keep', ResultOk, DialogWidth - DialogMargin - 2 * DialogButtonWidth - DialogButtonGap,
    Top, DialogButtonWidth, DialogButtonHeight, True, False);
  ShowSecondsLeft;
end;

procedure TKeepSettingsDialog.ShowSecondsLeft;
begin
  FMessage.Text := Format('They go back as they were in %d seconds.', [FSecondsLeft]);
end;

procedure TKeepSettingsDialog.TimerFired(Timer: LongWord);
begin
  if Timer = PlacesTimer then
  begin
    StopTimer(PlacesTimer);
    SayControlPlace('keep-yes', Self, FKeepButton);
    SayControlPlace('keep-revert', Self, FRevertButton);
    Exit;
  end;
  if Timer <> CountdownTimer then
  begin
    inherited TimerFired(Timer);
    Exit;
  end;
  Dec(FSecondsLeft);
  Say('keep-countdown ' + IntToStr(FSecondsLeft));
  ShowSecondsLeft;
  if FSecondsLeft <= 0 then
    EndModal(ResultCancel);
end;

function TKeepSettingsDialog.Ask: Boolean;
begin
  FocusControl(FKeepButton);
  Say('keep-asked ' + IntToStr(FSecondsLeft));
  StartTimer(PlacesTimer, PlacesDelayMilliseconds);
  StartTimer(CountdownTimer, 1000);
  Result := ShowModal = ResultOk;
  StopTimer(CountdownTimer);
  StopTimer(PlacesTimer);
end;

function AskToKeepSettings(Owner: TWindow; Seconds: LongInt): Boolean;
var
  Dialog: TKeepSettingsDialog;
begin
  Dialog := TKeepSettingsDialog.CreateKeepDialog(Owner, Seconds);
  try
    Result := Dialog.Ask;
  finally
    Dialog.Free;
  end;
end;

end.
