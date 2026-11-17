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
  Notepad's window as far as its file goes: the text being edited, the
  file it came from (none for a new one, "Untitled"), the title showing
  that file's name, and New, Open, Save and Save As.

  Whatever would throw away changes not saved (New, Open, closing)
  asks first whether to save them: Yes saves (and goes on only if that
  worked), No goes on without, Cancel stays. Errors reading or writing
  are told in a message box; the text stays as it was.
}
unit Notepad.DocumentWindow;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Window,
  Controls.TextEdit,
  Notepad.Files;

type
  TDocumentWindow = class(TControlWindow)
  private
    FPath: string;
    FFormat: TTextFileFormat;
    function StartFolder: string;
    function WriteDocument(const APath: string): Boolean;
  protected
    FEditor: TTextEdit;
    procedure CloseRequested; override;
    { The document became another (opened, new, saved under a name). }
    procedure DocumentChanged; virtual;
  public
    constructor Create;
    { "Untitled", or the file's name. }
    function DocumentName: string;
    procedure UpdateTitle;
    { True if there are no changes to lose, or the user agreed to lose
      them or saved them. }
    function ConfirmDiscard: Boolean;
    procedure NewDocument;
    { Opens APath; a file that does not exist yet is an empty document
      that will be saved there. False if it could not be read. }
    function OpenDocument(const APath: string): Boolean;
    { Asks for a file and opens it. }
    procedure ChooseAndOpenDocument;
    { Saves to the file it came from (asking for one if new). }
    function SaveDocument: Boolean;
    function SaveDocumentAs: Boolean;
    { Ends the program, if the changes are saved or may be lost. }
    procedure ExitIfAllowed;
    property Path: string read FPath;
    property Editor: TTextEdit read FEditor;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Util.Paths,
  Windowing.Windows,
  Controls.Base,
  Controls.Dialogs,
  Controls.MessageBoxes,
  Controls.FileDialog,
  Controls.FileNames,
  Notepad.Output;

const
  ProgramName = 'Notepad';
  TextFilter = '*.txt';

constructor TDocumentWindow.Create;
begin
  inherited Create(ProgramName, 80, 60, 560, 400);
  IconName := 'app-text-editor';
  FFormat := DefaultTextFileFormat;
  FEditor := TTextEdit.Create(Root);
  FEditor.Align := AlignClient;
  FEditor.AcceptTabs := True;
  FocusControl(FEditor);
end;

function TDocumentWindow.DocumentName: string;
begin
  if FPath = '' then
    Result := 'Untitled'
  else
    Result := LastPartOf(FPath);
end;

procedure TDocumentWindow.UpdateTitle;
begin
  Title := DocumentName + ' - ' + ProgramName;
  Say('title ' + Title);
end;

procedure TDocumentWindow.DocumentChanged;
begin
  UpdateTitle;
end;

{ Where the file dialogs start: the document's folder, or the current
  one. }
function TDocumentWindow.StartFolder: string;
begin
  if FPath <> '' then
    Exit(ParentFolderOf(FPath));
  if CurrentDirectoryPath(Result) <> ErrorNone then
    Result := '/';
end;

function TDocumentWindow.ConfirmDiscard: Boolean;
var
  Answer: LongInt;
begin
  if not FEditor.Modified then
    Exit(True);
  Answer := ShowMessageBox(ProgramName, 'The text in ' + DocumentName + ' has changed.'#10#10 +
    'Do you want to save the changes?', MessageYesNoCancel, SignWarning, Self);
  case Answer of
    ResultYes:
      begin
        Say('answer yes');
        Result := SaveDocument;
      end;
    ResultNo:
      begin
        Say('answer no');
        Result := True;
      end;
  else
    Say('answer cancel');
    Result := False;
  end;
end;

procedure TDocumentWindow.NewDocument;
begin
  if not ConfirmDiscard then
    Exit;
  FPath := '';
  FFormat := DefaultTextFileFormat;
  FEditor.SetAllText('');
  DocumentChanged;
end;

function TDocumentWindow.OpenDocument(const APath: string): Boolean;
var
  Text: string;
  Format: TTextFileFormat;
  Error: string;
  FullPath: string;
begin
  FullPath := CombinePath(StartFolder, APath);
  if not PathExists(PChar(FullPath)) then
  begin
    { A new file, to be made when saved. }
    Text := '';
    Format := DefaultTextFileFormat;
  end
  else
  begin
    Error := ReadTextFile(FullPath, Text, Format);
    if Error <> '' then
    begin
      ShowMessageBox(ProgramName, 'Cannot open ' + FullPath + ':'#10 + Error, MessageOk, SignError, Self);
      Exit(False);
    end;
  end;
  FPath := FullPath;
  FFormat := Format;
  FEditor.SetAllText(Text);
  Say('opened ' + FPath);
  Say('first-line ' + FEditor.Lines[0]);
  DocumentChanged;
  Result := True;
end;

procedure TDocumentWindow.ChooseAndOpenDocument;
var
  Chosen: string;
begin
  if not ConfirmDiscard then
    Exit;
  if ChooseFileToOpen('Open', StartFolder, TextFilter, Chosen) then
    OpenDocument(Chosen);
end;

function TDocumentWindow.WriteDocument(const APath: string): Boolean;
var
  Error: string;
begin
  Error := WriteTextFile(APath, FEditor.AllText, FFormat);
  if Error <> '' then
  begin
    ShowMessageBox(ProgramName, 'Cannot save ' + APath + ':'#10 + Error, MessageOk, SignError, Self);
    Exit(False);
  end;
  FPath := APath;
  FEditor.Modified := False;
  Say('saved ' + FPath);
  DocumentChanged;
  Result := True;
end;

function TDocumentWindow.SaveDocument: Boolean;
begin
  if FPath = '' then
    Result := SaveDocumentAs
  else
    Result := WriteDocument(FPath);
end;

function TDocumentWindow.SaveDocumentAs: Boolean;
var
  Chosen: string;
  Name: string;
begin
  Name := '';
  if FPath <> '' then
    Name := LastPartOf(FPath);
  Result := ChooseFileToSave('Save As', StartFolder, TextFilter, Chosen, Name) and WriteDocument(Chosen);
end;

procedure TDocumentWindow.ExitIfAllowed;
begin
  if not ConfirmDiscard then
    Exit;
  Say('exit');
  QuitMessageLoop(0);
end;

procedure TDocumentWindow.CloseRequested;
begin
  ExitIfAllowed;
end;

end.
