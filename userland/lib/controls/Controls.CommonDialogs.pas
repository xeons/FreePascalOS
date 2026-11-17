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
  What the common dialogs (open and save a file, choose a colour,
  choose a font) share: OK and Cancel buttons at the bottom right, and
  Execute, which shows the dialog and says whether it was accepted.
  OK ends the dialog only if Accept agrees: a dialog checks what was
  chosen there (a file dialog opens a folder instead, or asks before
  replacing a file).

  OnShowing runs just before the dialog appears, with its controls
  placed: a program can adjust them, or (as the tests do) find where
  they are on the screen.
}
unit Controls.CommonDialogs;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Buttons,
  Controls.Dialogs;

const
  DialogMargin = 8;
  DialogButtonWidth = 75;
  DialogButtonHeight = 23;
  DialogButtonGap = 6;

type
  TCommonDialog = class;
  TCommonDialogEvent = procedure(Dialog: TCommonDialog) of object;

  TCommonDialog = class(TDialog)
  private
    FOkButton: TButton;
    FCancelButton: TButton;
    FOnShowing: TCommonDialogEvent;
    procedure OkClicked(Sender: TControl);
  protected
    { OK and Cancel along the bottom right of a dialog Width x Height
      (logical units). OK is the default button. }
    procedure AddOkAndCancel(Width, Height: LongInt);
    { The dialog is about to be shown (the default runs OnShowing). }
    procedure Showing; virtual;
    { OK was pressed: True ends the dialog with ResultOk (the default
      always agrees). }
    function Accept: Boolean; virtual;
  public
    { Shows the dialog until it ends; True if it ended with OK. }
    function Execute: Boolean;
    property OkButton: TButton read FOkButton;
    property CancelButton: TButton read FCancelButton;
    property OnShowing: TCommonDialogEvent read FOnShowing write FOnShowing;
  end;

implementation

procedure TCommonDialog.AddOkAndCancel(Width, Height: LongInt);
var
  Top: LongInt;
  CancelLeft: LongInt;
begin
  Top := Height - DialogMargin - DialogButtonHeight;
  CancelLeft := Width - DialogMargin - DialogButtonWidth;
  FOkButton := AddButton('OK', ResultOk, CancelLeft - DialogButtonGap - DialogButtonWidth, Top, DialogButtonWidth,
    DialogButtonHeight, True, False);
  FOkButton.OnClick := @OkClicked;
  FCancelButton := AddButton('Cancel', ResultCancel, CancelLeft, Top, DialogButtonWidth, DialogButtonHeight,
    False, True);
  { They stay at the corner if the dialog is resized. }
  FOkButton.Anchors := [akRight, akBottom];
  FCancelButton.Anchors := [akRight, akBottom];
end;

procedure TCommonDialog.OkClicked(Sender: TControl);
begin
  if Accept then
    EndModal(ResultOk);
end;

function TCommonDialog.Accept: Boolean;
begin
  Result := True;
end;

procedure TCommonDialog.Showing;
begin
  if Assigned(FOnShowing) then
    FOnShowing(Self);
end;

function TCommonDialog.Execute: Boolean;
begin
  Showing;
  Result := ShowModal = ResultOk;
end;

end.
