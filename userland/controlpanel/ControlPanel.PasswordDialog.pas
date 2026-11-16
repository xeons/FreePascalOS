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
  A dialog asking for one password: a line of explanation, a box that
  shows dots, OK and Cancel. The box has the keyboard when it appears,
  so the password can simply be typed and Enter pressed. It says
  "password-asked TITLE" when it appears.
}
unit ControlPanel.PasswordDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

{ Asks for a password; True and the password if OK was pressed. }
function AskForPassword(Owner: TWindow; const Title, Explanation: string; out Password: string): Boolean;

implementation

uses
  Controls.Labels,
  Controls.EditBox,
  Controls.CommonDialogs,
  ControlPanel.Report;

const
  DialogWidth = 340;
  DialogHeight = 118;

type
  TPasswordDialog = class(TCommonDialog)
  private
    FPasswordEdit: TEditBox;
  protected
    procedure Showing; override;
  public
    constructor CreatePasswordDialog(AOwner: TWindow; const ATitle, Explanation: string);
    property PasswordEdit: TEditBox read FPasswordEdit;
  end;

constructor TPasswordDialog.CreatePasswordDialog(AOwner: TWindow; const ATitle, Explanation: string);
var
  Message: TLabel;
  Caption: TLabel;
begin
  inherited CreateDialog(ATitle, DialogWidth, DialogHeight, AOwner);
  Message := TLabel.Create(Root);
  Message.ShowsMnemonic := False;
  Message.Text := Explanation;
  Message.SetBounds(DialogMargin, DialogMargin, DialogWidth - 2 * DialogMargin, 18);
  Caption := TLabel.Create(Root);
  Caption.Text := '&Password:';
  Caption.SetBounds(DialogMargin, DialogMargin + 33, 80, 16);
  FPasswordEdit := TEditBox.Create(Root);
  FPasswordEdit.HidesText := True;
  FPasswordEdit.SetBounds(DialogMargin + 84, DialogMargin + 30, DialogWidth - 2 * DialogMargin - 84, 22);
  AddOkAndCancel(DialogWidth, DialogHeight);
end;

procedure TPasswordDialog.Showing;
begin
  FocusControl(FPasswordEdit);
  inherited Showing;
  Say('password-asked ' + Title);
  SayControlPlace('password-ok', Self, OkButton);
end;

function AskForPassword(Owner: TWindow; const Title, Explanation: string; out Password: string): Boolean;
var
  Dialog: TPasswordDialog;
begin
  Password := '';
  Dialog := TPasswordDialog.CreatePasswordDialog(Owner, Title, Explanation);
  try
    Result := Dialog.Execute;
    if Result then
      Password := Dialog.PasswordEdit.Text;
  finally
    Dialog.Free;
  end;
end;

end.
