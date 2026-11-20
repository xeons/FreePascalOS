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
  A page's window.prompt: its message, a box with the default answer
  (selected), OK and Cancel.
}
unit Browser.PromptDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

{ True and the text typed on OK. }
function AskForText(Owner: TWindow; const Title, Message, Default: string; out Answer: string): Boolean;

implementation

uses
  Controls.Base,
  Controls.Labels,
  Controls.EditBox,
  Controls.CommonDialogs;

const
  DialogWidth = 420;
  DialogHeight = 120;

type
  TPromptDialog = class(TCommonDialog)
  private
    FEdit: TEditBox;
  protected
    procedure Showing; override;
  public
    constructor CreatePrompt(AOwner: TWindow; const ATitle, AMessage, ADefault: string);
    property Edit: TEditBox read FEdit;
  end;

constructor TPromptDialog.CreatePrompt(AOwner: TWindow; const ATitle, AMessage, ADefault: string);
var
  Caption: TLabel;
begin
  inherited CreateDialog(ATitle, DialogWidth, DialogHeight, AOwner);
  Caption := TLabel.Create(Root);
  Caption.ShowsMnemonic := False;
  Caption.Text := AMessage;
  Caption.SetBounds(DialogMargin, DialogMargin, DialogWidth - 2 * DialogMargin, 18);
  FEdit := TEditBox.Create(Root);
  FEdit.SetBounds(DialogMargin, DialogMargin + 24, DialogWidth - 2 * DialogMargin, 22);
  FEdit.Text := ADefault;
  AddOkAndCancel(DialogWidth, DialogHeight);
end;

procedure TPromptDialog.Showing;
begin
  FocusControl(FEdit);
  FEdit.SelectAll;
  inherited Showing;
end;

function AskForText(Owner: TWindow; const Title, Message, Default: string; out Answer: string): Boolean;
var
  Dialog: TPromptDialog;
begin
  Answer := '';
  Dialog := TPromptDialog.CreatePrompt(Owner, Title, Message, Default);
  try
    Result := Dialog.Execute;
    if Result then
      Answer := Dialog.Edit.Text;
  finally
    Dialog.Free;
  end;
end;

end.
