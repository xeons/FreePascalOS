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
  "Open with": which program to open a file with. The programs that
  say they open its type come first (FileManager.Handlers), then every
  other installed program; "Always use this program for .EXT files"
  makes the choice the type's default (Files/Defaults). It is also the
  "Choose a default" of the context menu (the check box ticked).
}
unit FileManager.OpenWithDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  Configuration.ProgramInfo;

{ Asks which program opens Path; False if cancelled. AlwaysByDefault:
  the check box starts ticked. Info is the program chosen. }
function ChooseProgram(const Path: string; AlwaysByDefault: Boolean; Owner: TWindow; out Info: TProgramInfo): Boolean;

implementation

uses
  SysUtils,
  Configuration.ProgramFolders,
  Controls.Base,
  Controls.Dialogs,
  Controls.Labels,
  Controls.ListBox,
  Controls.Toggles,
  Controls.FileNames,
  FileManager.Paths,
  FileManager.Handlers,
  FileManager.Settings,
  FileManager.TestPlaces,
  FileManager.Output;

const
  DialogWidth = 380;
  DialogHeight = 330;

function ChooseProgram(const Path: string; AlwaysByDefault: Boolean; Owner: TWindow; out Info: TProgramInfo): Boolean;
var
  Dialog: TDialog;
  Caption: TLabel;
  List: TListBox;
  Always: TCheckBox;
  Choices: TProgramList;
  Handlers: TProgramList;
  Each: TProgramInfo;
  Extension: string;
  procedure AddChoice(const Candidate: TProgramInfo; Suggested: Boolean);
  var
    Other: LongInt;
  begin
    for Other := 0 to High(Choices) do
      if Choices[Other].FolderName = Candidate.FolderName then
        Exit;
    SetLength(Choices, Length(Choices) + 1);
    Choices[High(Choices)] := Candidate;
    if Suggested then
      List.Items.Add(Candidate.Name + ' (suggested)')
    else
      List.Items.Add(Candidate.Name);
  end;
begin
  Info := Default(TProgramInfo);
  Extension := ExtensionOf(Path);
  Choices := nil;
  Dialog := TDialog.CreateDialog('Open with', DialogWidth, DialogHeight, Owner);
  try
    Caption := TLabel.Create(Dialog.Root);
    Caption.ShowsMnemonic := False;
    Caption.Text := 'How do you want to open ' + LastPartOf(Path) + '?';
    Caption.SetBounds(12, 12, DialogWidth - 24, 18);
    List := TListBox.Create(Dialog.Root);
    List.SetBounds(12, 36, DialogWidth - 24, DialogHeight - 36 - 80);
    Handlers := HandlersForFile(Path);
    for Each in Handlers do
      AddChoice(Each, True);
    for Each in InstalledPrograms do
      if not Each.Hidden then
        AddChoice(Each, False);
    if List.Items.Count > 0 then
      List.ItemIndex := 0;
    Always := TCheckBox.Create(Dialog.Root);
    if Extension <> '' then
      Always.Text := '&Always use this program for .' + Extension + ' files'
    else
      Always.Text := '&Always use this program for such files';
    Always.Checked := AlwaysByDefault;
    Always.Enabled := Extension <> '';
    Always.SetBounds(12, DialogHeight - 70, DialogWidth - 24, 20);
    Dialog.AddButton('OK', ResultOk, DialogWidth - 12 - 2 * 75 - 8, DialogHeight - 12 - 23, 75, 23, True);
    Dialog.AddButton('Cancel', ResultCancel, DialogWidth - 12 - 75, DialogHeight - 12 - 23, 75, 23, False, True);
    Dialog.FocusControl(List);
    Say('open-with-dialog ' + IntToStr(Length(Choices)));
    Result := (Dialog.ShowModal = ResultOk) and (List.ItemIndex >= 0) and (List.ItemIndex <= High(Choices));
    if not Result then
      Exit;
    Info := Choices[List.ItemIndex];
    if Always.Checked and (Extension <> '') then
    begin
      RememberChosenProgram(Extension, Info.FolderName);
      Say('default ' + Extension + ' ' + Info.FolderName);
    end;
  finally
    Dialog.Free;
  end;
end;

end.
