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
  A small dialog asking for a line of text (Open Location when the
  location bar is hidden, a new folder's name...).
}
unit Browser.InputDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

{ True (and Value changed) on OK. }
function AskText(Owner: TWindow; const Title, Prompt: string; var Value: string): Boolean;
{ One of Items (Index: the one chosen, the one picked at first); True on
  OK with one chosen. }
function ChooseFromList(Owner: TWindow; const Title, Prompt: string; const Items: array of string;
  var Index: Integer): Boolean;

implementation

uses
  Controls.Base,
  Controls.Labels,
  Controls.EditBox,
  Controls.ListBox,
  Controls.CommonDialogs;

const
  DialogWidth = 420;
  DialogHeight = 110;

type
  TTextDialog = class(TCommonDialog)
  private
    FEdit: TEditBox;
  protected
    procedure Showing; override;
  end;

procedure TTextDialog.Showing;
begin
  FocusControl(FEdit);
  FEdit.SelectAll;
  inherited Showing;
end;

function AskText(Owner: TWindow; const Title, Prompt: string; var Value: string): Boolean;
var
  Dialog: TTextDialog;
  Caption: TLabel;
begin
  Dialog := TTextDialog.CreateDialog(Title, DialogWidth, DialogHeight, Owner);
  try
    Caption := TLabel.Create(Dialog.Root);
    Caption.Text := Prompt;
    Caption.SetBounds(DialogMargin, DialogMargin, DialogWidth - 2 * DialogMargin, 18);
    Dialog.FEdit := TEditBox.Create(Dialog.Root);
    Dialog.FEdit.SetBounds(DialogMargin, DialogMargin + 22, DialogWidth - 2 * DialogMargin, 22);
    Dialog.FEdit.Anchors := [akLeft, akTop, akRight];
    Dialog.FEdit.Text := Value;
    Dialog.AddOkAndCancel(DialogWidth, DialogHeight);
    Result := Dialog.Execute;
    if Result then
      Value := Dialog.FEdit.Text;
  finally
    Dialog.Free;
  end;
end;

type
  TListDialog = class(TCommonDialog)
  private
    FList: TListBox;
  protected
    procedure Showing; override;
  end;

procedure TListDialog.Showing;
begin
  FocusControl(FList);
  inherited Showing;
end;

function ChooseFromList(Owner: TWindow; const Title, Prompt: string; const Items: array of string;
  var Index: Integer): Boolean;
const
  ListHeight = 300;
var
  Dialog: TListDialog;
  Caption: TLabel;
  Item: Integer;
begin
  Dialog := TListDialog.CreateDialog(Title, DialogWidth, ListHeight, Owner);
  try
    Caption := TLabel.Create(Dialog.Root);
    Caption.Text := Prompt;
    Caption.SetBounds(DialogMargin, DialogMargin, DialogWidth - 2 * DialogMargin, 18);
    Dialog.FList := TListBox.Create(Dialog.Root);
    Dialog.FList.SetBounds(DialogMargin, DialogMargin + 22, DialogWidth - 2 * DialogMargin, ListHeight - 3 *
      DialogMargin - 22 - DialogButtonHeight);
    Dialog.FList.Anchors := [akLeft, akTop, akRight, akBottom];
    for Item := 0 to High(Items) do
      Dialog.FList.Items.Add(Items[Item]);
    Dialog.FList.ItemIndex := Index;
    Dialog.AddOkAndCancel(DialogWidth, ListHeight);
    Result := Dialog.Execute and (Dialog.FList.ItemIndex >= 0);
    if Result then
      Index := Dialog.FList.ItemIndex;
  finally
    Dialog.Free;
  end;
end;

end.
