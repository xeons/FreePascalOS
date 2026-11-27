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

  Laid out by a table rather than positions: the explanation across
  both columns, then the caption in a column of its own and the box
  filling the rest of its row.
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
  Controls.Base,
  Controls.Labels,
  Controls.EditBox,
  Controls.TablePanel,
  Controls.TableArrangement,
  Controls.CommonDialogs,
  ControlPanel.Report;

const
  DialogWidth = 340;
  DialogHeight = 118;
  { The table's rows and its caption column (logical units). }
  ExplanationRowHeight = 30;
  PasswordRowHeight = 22;
  CaptionColumnWidth = 84;

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
  Table: TTableLayoutPanel;
  Message: TLabel;
  Caption: TLabel;
begin
  inherited CreateDialog(ATitle, DialogWidth, DialogHeight, AOwner);
  Table := TTableLayoutPanel.Create(Root);
  Table.SetBounds(DialogMargin, DialogMargin, DialogWidth - 2 * DialogMargin,
    ExplanationRowHeight + PasswordRowHeight);
  Table.AddColumn(TrackAbsolute, CaptionColumnWidth);
  Table.AddColumn(TrackPercent, 100);
  Table.AddRow(TrackAbsolute, ExplanationRowHeight);
  Table.AddRow(TrackAbsolute, PasswordRowHeight);
  Message := TLabel.Create(Table);
  Message.ShowsMnemonic := False;
  Message.Text := Explanation;
  Message.SetBounds(0, 0, 0, 18);
  Message.Anchors := [akLeft, akTop, akRight];
  Table.SetCell(Message, 0, 0);
  Table.SetSpan(Message, 2, 1);
  { At the left of its cell, in the middle of the row. }
  Caption := TLabel.Create(Table);
  Caption.Text := '&Password:';
  Caption.SetBounds(0, 0, 80, 16);
  Caption.Anchors := [akLeft];
  Table.SetCell(Caption, 0, 1);
  FPasswordEdit := TEditBox.Create(Table);
  FPasswordEdit.HidesText := True;
  FPasswordEdit.Align := AlignClient;
  Table.SetCell(FPasswordEdit, 1, 1);
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
