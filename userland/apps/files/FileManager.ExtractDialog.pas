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
  "Extract all": where an archive's contents go. The folder starts as
  one named after the archive beside it ("photos.zip" into "photos"),
  can be typed or chosen with Browse (the folder dialog), and "Show the
  extracted files when done" opens it afterwards.
}
unit FileManager.ExtractDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

{ Asks where to extract Archive; False if cancelled. }
function ChooseExtractFolder(const Archive: string; Owner: TWindow; out Folder: string;
  out ShowWhenDone: Boolean): Boolean;
{ The folder an archive extracts into by default. }
function DefaultExtractFolder(const Archive: string): string;

implementation

uses
  SysUtils,
  Controls.Base,
  Controls.Window,
  Controls.Dialogs,
  Controls.Labels,
  Controls.EditBox,
  Controls.Buttons,
  Controls.Toggles,
  Controls.FileDialog,
  Controls.FileNames,
  FileManager.TestPlaces,
  FileManager.Output;

const
  DialogWidth = 460;
  DialogHeight = 150;

type
  TBrowseHelper = class
  public
    Box: TEditBox;
    Owner: TControlWindow;
    procedure BrowseClicked(Sender: TControl);
  end;

procedure TBrowseHelper.BrowseClicked(Sender: TControl);
var
  Chosen: string;
begin
  Chosen := Box.Text;
  if ChooseFolder('Choose where to extract', ParentFolderOf(Box.Text), Chosen) then
    Box.Text := Chosen;
end;

function DefaultExtractFolder(const Archive: string): string;
var
  Name: string;
  Lowered: string;
begin
  Name := LastPartOf(Archive);
  Lowered := LowerCase(Name);
  if Copy(Lowered, Length(Lowered) - 6, 7) = '.tar.gz' then
    Name := Copy(Name, 1, Length(Name) - 7)
  else
    Name := ChangeFileExt(Name, '');
  if Name = '' then
    Name := 'Extracted';
  Result := CombinePath(ParentFolderOf(Archive), Name);
end;

function ChooseExtractFolder(const Archive: string; Owner: TWindow; out Folder: string;
  out ShowWhenDone: Boolean): Boolean;
var
  Dialog: TDialog;
  Caption: TLabel;
  Box: TEditBox;
  Browse: TButton;
  ShowBox: TCheckBox;
  Helper: TBrowseHelper;
  OkButton: TButton;
begin
  Folder := '';
  ShowWhenDone := False;
  Dialog := TDialog.CreateDialog('Extract compressed folder', DialogWidth, DialogHeight, Owner);
  Helper := TBrowseHelper.Create;
  try
    Caption := TLabel.Create(Dialog.Root);
    Caption.Text := '&Files will be extracted to this folder:';
    Caption.SetBounds(12, 12, DialogWidth - 24, 18);
    Box := TEditBox.Create(Dialog.Root);
    Box.SetBounds(12, 34, DialogWidth - 24 - 90, 24);
    Box.Text := DefaultExtractFolder(Archive);
    Browse := TButton.Create(Dialog.Root);
    Browse.Text := '&Browse...';
    Browse.SetBounds(DialogWidth - 12 - 82, 34, 82, 24);
    Helper.Box := Box;
    Helper.Owner := Dialog;
    Browse.OnClick := @Helper.BrowseClicked;
    ShowBox := TCheckBox.Create(Dialog.Root);
    ShowBox.Text := '&Show extracted files when complete';
    ShowBox.Checked := True;
    ShowBox.SetBounds(12, 68, DialogWidth - 24, 20);
    OkButton := Dialog.AddButton('E&xtract', ResultOk, DialogWidth - 12 - 2 * 82 - 8, DialogHeight - 12 - 23, 82, 23,
      True);
    Dialog.AddButton('Cancel', ResultCancel, DialogWidth - 12 - 82, DialogHeight - 12 - 23, 82, 23, False, True);
    Dialog.FocusControl(Box);
    Box.SelectAll;
    Say('extract-dialog ' + Box.Text);
    TellControlPlace('extract-go', OkButton);
    Result := Dialog.ShowModal = ResultOk;
    if Result then
    begin
      Folder := CleanPath(Box.Text);
      ShowWhenDone := ShowBox.Checked;
    end;
  finally
    Helper.Free;
    Dialog.Free;
  end;
end;

end.
