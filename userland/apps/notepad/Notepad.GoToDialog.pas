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
  The Go To dialog: asks for a line number. OK takes it only if it is a
  number from 1 to the number of lines; otherwise a message says so and
  the dialog stays.
}
unit Notepad.GoToDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

{ Asks for a line from 1 to LineCount, starting with Current; True and
  the line in Line if one was given. }
function AskForLine(Owner: TWindow; Current, LineCount: LongInt; out Line: LongInt): Boolean;

implementation

uses
  SysUtils,
  Controls.Labels,
  Controls.EditBox,
  Controls.CommonDialogs,
  Controls.MessageBoxes;

const
  DialogWidth = 260;
  DialogHeight = 96;

type
  TGoToDialog = class(TCommonDialog)
  private
    FLineEdit: TEditBox;
    FLineCount: LongInt;
    FLine: LongInt;
  protected
    procedure Showing; override;
    function Accept: Boolean; override;
  public
    constructor CreateGoToDialog(AOwner: TWindow; Current, LineCount: LongInt);
    property Line: LongInt read FLine;
  end;

constructor TGoToDialog.CreateGoToDialog(AOwner: TWindow; Current, LineCount: LongInt);
var
  Caption: TLabel;
begin
  inherited CreateDialog('Go To Line', DialogWidth, DialogHeight, AOwner);
  FLineCount := LineCount;
  Caption := TLabel.Create(Root);
  Caption.Text := '&Line number:';
  Caption.SetBounds(DialogMargin, DialogMargin + 3, 90, 16);
  FLineEdit := TEditBox.Create(Root);
  FLineEdit.SetBounds(DialogMargin + 96, DialogMargin, DialogWidth - 2 * DialogMargin - 96, 22);
  FLineEdit.Text := IntToStr(Current);
  AddOkAndCancel(DialogWidth, DialogHeight);
end;

procedure TGoToDialog.Showing;
begin
  FocusControl(FLineEdit);
  FLineEdit.SelectAll;
  inherited Showing;
end;

function TGoToDialog.Accept: Boolean;
var
  Wanted: LongInt;
begin
  Result := TryStrToInt(Trim(FLineEdit.Text), Wanted) and (Wanted >= 1) and (Wanted <= FLineCount);
  if not Result then
  begin
    ShowMessageBox('Go To Line', 'The line number is beyond the total number of lines.', MessageOk, SignWarning,
      Self);
    Exit;
  end;
  FLine := Wanted;
end;

function AskForLine(Owner: TWindow; Current, LineCount: LongInt; out Line: LongInt): Boolean;
var
  Dialog: TGoToDialog;
begin
  Line := Current;
  Dialog := TGoToDialog.CreateGoToDialog(Owner, Current, LineCount);
  try
    Result := Dialog.Execute;
    if Result then
      Line := Dialog.Line;
  finally
    Dialog.Free;
  end;
end;

end.
