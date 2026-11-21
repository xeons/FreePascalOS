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
  What the file manager does to the items chosen:

  * Open: a folder, a page or a volume is shown (in this tab, a new tab
    or a new window); an archive is browsed like a folder; a program
    runs; any other file opens with its type's default program
    (FileManager.Handlers: the user's choice, else the best that says it
    opens it; else Notepad for text, the image viewer for pictures). A
    file opened goes to the recent files. A file inside an archive is
    extracted to the cache first. "Open with" lists the programs
    (FileManager.OpenWithDialog), "Choose a default" makes one the
    type's default.
  * New: a folder ("New folder", Ctrl+Shift+N) or a file from a template
    (FileManager.Templates), made at once and put up for renaming.
  * Rename in place (F2); with several selected, the name typed goes to
    all of them, numbered ("Holiday (1).jpg": FileManager.BatchNames).
  * Compress to ZIP (named after the item, or the folder for several),
    Extract all (FileManager.ExtractDialog).
  * Pin to Home and unpin, add to favourites and remove, copy as path,
    send to the desktop or documents (the share hook).
  * Select all, none, invert; Properties.

  Renames and new items go into the undo history.
}
unit FileManager.ItemCommands;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Controls.Base,
  Controls.ItemView,
  Configuration.ProgramInfo,
  FileManager.Entries,
  FileManager.CommandWindow;

type
  TOpenPlace = (OpenHere, OpenInNewTab, OpenInNewWindow);

  TItemCommandWindow = class(TCommandWindow)
  private
    FBatchPaths: TStringList;
    procedure ItemActivated(Sender: TControl);
    procedure ItemRenamed(Sender: TItemView; Index: LongInt; const NewCaption: string; var Accept: Boolean);
    procedure RenameBatch(const Typed: string);
    function NameTakenHere(const Name: string): Boolean;
    function NameTakenOutsideBatch(const Name: string): Boolean;
    function ExtractForOpening(Entry: TFolderEntry; out Path: string): Boolean;
    procedure OpenFile(const Path: string; Entry: TFolderEntry);
    procedure PutUpForRenaming(const Name: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure OpenEntry(Entry: TFolderEntry; Place: TOpenPlace = OpenHere);
    procedure OpenFocused(Place: TOpenPlace = OpenHere);
    procedure OpenFocusedWith(const Info: TProgramInfo);
    procedure OpenWithChooser(ChooseDefault: Boolean);
    procedure CreateNewFolder;
    procedure CreateNewFile(TemplateIndex: LongInt);
    procedure RenameFocused;
    procedure CompressSelected;
    procedure ExtractFocused;
    procedure PinSelected(Pin: Boolean);
    procedure PinPaths(Paths: TStrings; Pin: Boolean);
    procedure FavoriteSelected(Favorite: Boolean);
    procedure CopyAsPath;
    procedure SendTo(const Folder: string);
    procedure SelectNone;
    procedure InvertSelection;
    procedure ShowProperties;
    function FocusedEntry: TFolderEntry;
    { Whether the focused entry is an archive file (Extract all). }
    function FocusedIsArchive: Boolean;
    function SelectionIsPinned: Boolean;
    function SelectionIsFavorite: Boolean;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Windowing.Windows,
  Controls.Clipboard,
  Controls.MessageBoxes,
  Controls.FileNames,
  Archive.Readers,
  Configuration.ProgramFolders,
  FileManager.FolderReading,
  FileManager.Items,
  FileManager.Paths,
  FileManager.Locations,
  FileManager.FileKinds,
  FileManager.ConflictNames,
  FileManager.BatchNames,
  FileManager.UndoHistory,
  FileManager.OperationTypes,
  FileManager.Associations,
  FileManager.Handlers,
  FileManager.Launching,
  FileManager.Sources,
  FileManager.Settings,
  FileManager.UserLists,
  FileManager.Templates,
  FileManager.ErrorTexts,
  FileManager.OpenWithDialog,
  FileManager.ExtractDialog,
  FileManager.PropertiesDialog,
  FileManager.VolumeProperties,
  FileManager.BrowserWindow,
  FileManager.Output;

constructor TItemCommandWindow.Create;
begin
  inherited Create;
  FBatchPaths := TStringList.Create;
  FView.OnActivate := @ItemActivated;
  FView.OnEdited := @ItemRenamed;
end;

destructor TItemCommandWindow.Destroy;
begin
  FBatchPaths.Free;
  inherited Destroy;
end;

function TItemCommandWindow.FocusedEntry: TFolderEntry;
begin
  Result := FView.FocusedEntry;
end;

function TItemCommandWindow.FocusedIsArchive: Boolean;
var
  Entry: TFolderEntry;
begin
  Entry := FocusedEntry;
  Result := (Entry <> nil) and (Entry.Kind = EntryFile) and (Entry.Item.Kind = ItemFile) and
    IsBrowsableArchiveExtension(Entry.Item.Name);
end;

{ --- Opening ------------------------------------------------------------------------------- }

procedure TItemCommandWindow.ItemActivated(Sender: TControl);
begin
  if FOptions.OpenInNewWindow and (FocusedEntry <> nil) and FocusedEntry.IsFolder then
    OpenFocused(OpenInNewWindow)
  else
    OpenFocused(OpenHere);
end;

procedure TItemCommandWindow.OpenFocused(Place: TOpenPlace);
var
  Entry: TFolderEntry;
begin
  Entry := FocusedEntry;
  if Entry <> nil then
    OpenEntry(Entry, Place);
end;

procedure ShowLocationIn(Window: TItemCommandWindow; const Location: TLocation; Place: TOpenPlace);
begin
  case Place of
    OpenInNewTab: Window.NewTab(Location);
    OpenInNewWindow: OpenNewWindow(LocationAddress(Location));
  else
    Window.Navigate(Location);
  end;
end;

function TItemCommandWindow.ExtractForOpening(Entry: TFolderEntry; out Path: string): Boolean;
var
  Reader: TArchiveReader;
  Problem: string;
  Folder: string;
begin
  Path := '';
  Result := False;
  Reader := OpenArchiveCached(FView.Location.Path, Problem);
  if (Reader = nil) or (Entry.ArchiveIndex < 0) then
    Exit;
  Folder := CombinePath(HomeFolder, '.cache/files-open/' + LastPartOf(FView.Location.Path));
  ForceDirectories(Folder);
  Path := CombinePath(Folder, Entry.Item.Name);
  try
    Reader.ExtractToFile(Entry.ArchiveIndex, Path);
    Result := True;
  except
    on Failure: Exception do
    begin
      Say('error extract ' + Entry.Item.Name + ': ' + Failure.Message);
      ShowMessageBox(ProgramTitle, Entry.Item.Name + ' cannot be taken out of the archive:'#10 + Failure.Message,
        MessageOk, SignError, Self);
    end;
  end;
end;

procedure TItemCommandWindow.OpenFile(const Path: string; Entry: TFolderEntry);
var
  Info: TProgramInfo;
  Item: TFolderItem;
begin
  if DescribeItem(Path, Item) <> ErrorNone then
    Exit;
  if OpenActionFor(Path, Item) = OpenActionProgram then
  begin
    RunProgramFile(Path, Self);
    Exit;
  end;
  if DefaultHandlerFor(Path, Info) then
  begin
    if Info.FolderName = 'notepad' then
      OpenWithNotepad(Path, Self)
    else if Info.FolderName = 'imageviewer' then
      OpenWithImageViewer(Path, Self)
    else
      OpenWithProgram(ProgramExecutablePath(Info), Info.Name, Path, Self);
  end
  else
    case OpenActionFor(Path, Item) of
      OpenActionNotepad: OpenWithNotepad(Path, Self);
      OpenActionImageViewer: OpenWithImageViewer(Path, Self);
    else
      begin
        Say('error no program for ' + Path);
        OpenWithChooser(False);
        Exit;
      end;
    end;
  AddToUserList(ListRecent, Path);
end;

procedure TItemCommandWindow.OpenEntry(Entry: TFolderEntry; Place: TOpenPlace);
var
  Location: TLocation;
  Path: string;
begin
  case Entry.Kind of
    EntryPlace, EntryVolume:
      if ParseAddress(Entry.Address, '/', Location) then
        ShowLocationIn(Self, Location, Place);
    EntryTrashed:
      ShowProperties;
    EntryArchived:
      if Entry.IsFolder then
      begin
        Location := FView.Location;
        Location.InnerPath := Entry.InnerPath;
        ShowLocationIn(Self, Location, Place);
      end
      else if ExtractForOpening(Entry, Path) then
        OpenFile(Path, Entry);
  else
    if Entry.IsFolder then
      ShowLocationIn(Self, FolderLocation(Entry.FullPath), Place)
    else if IsBrowsableArchiveExtension(Entry.Item.Name) and (Place <> OpenHere) then
    begin
      Location := Default(TLocation);
      Location.Kind := LocationArchive;
      Location.Path := Entry.FullPath;
      ShowLocationIn(Self, Location, Place);
    end
    else if IsBrowsableArchiveExtension(Entry.Item.Name) then
    begin
      Location := Default(TLocation);
      Location.Kind := LocationArchive;
      Location.Path := Entry.FullPath;
      Navigate(Location);
    end
    else
      OpenFile(Entry.FullPath, Entry);
  end;
end;

procedure TItemCommandWindow.OpenFocusedWith(const Info: TProgramInfo);
var
  Entry: TFolderEntry;
  Path: string;
begin
  Entry := FocusedEntry;
  if (Entry = nil) or Entry.IsFolder then
    Exit;
  Path := Entry.FullPath;
  if (Entry.Kind = EntryArchived) and not ExtractForOpening(Entry, Path) then
    Exit;
  OpenWithProgram(ProgramExecutablePath(Info), Info.Name, Path, Self);
  AddToUserList(ListRecent, Path);
end;

procedure TItemCommandWindow.OpenWithChooser(ChooseDefault: Boolean);
var
  Entry: TFolderEntry;
  Info: TProgramInfo;
begin
  Entry := FocusedEntry;
  if (Entry = nil) or Entry.IsFolder then
    Exit;
  if ChooseProgram(Entry.FullPath, ChooseDefault, Self, Info) then
    OpenFocusedWith(Info);
end;

{ --- New items and renaming --------------------------------------------------------------- }

function TItemCommandWindow.NameTakenHere(const Name: string): Boolean;
begin
  Result := PathExists(PChar(CombinePath(FView.Folder, Name)));
end;

procedure TItemCommandWindow.PutUpForRenaming(const Name: string);
var
  Index: LongInt;
begin
  FView.Refresh;
  Index := FView.IndexOfName(Name);
  if Index >= 0 then
  begin
    FView.ItemIndex := Index;
    FView.EditItem(Index, True);
  end;
end;

procedure TItemCommandWindow.CreateNewFolder;
var
  Name: string;
  Error: LongInt;
begin
  if FView.Location.Kind <> LocationFolder then
    Exit;
  Name := FirstFreeName('New folder', True, @NameTakenHere);
  Error := CreateDirectory(PChar(CombinePath(FView.Folder, Name)));
  if Error <> ErrorNone then
  begin
    Say('error new folder: ' + ReasonText(Error));
    ShowMessageBox(ProgramTitle, 'A new folder cannot be made here:'#10 + ReasonText(Error), MessageOk, SignError,
      Self);
    Exit;
  end;
  Say('new-folder ' + Name);
  FHistory.Push(MakeEntry(UndoNewFolder, [''], [CombinePath(FView.Folder, Name)]));
  PutUpForRenaming(Name);
end;

procedure TItemCommandWindow.CreateNewFile(TemplateIndex: LongInt);
var
  Templates: TFileTemplates;
  Name: string;
  Error: LongInt;
begin
  if FView.Location.Kind <> LocationFolder then
    Exit;
  Templates := FileTemplates;
  if (TemplateIndex < 0) or (TemplateIndex > High(Templates)) then
    Exit;
  Name := FirstFreeName(Templates[TemplateIndex].FileName, False, @NameTakenHere);
  Error := MakeFromTemplate(Templates[TemplateIndex], CombinePath(FView.Folder, Name));
  if Error <> ErrorNone then
  begin
    Say('error new file: ' + ReasonText(Error));
    ShowMessageBox(ProgramTitle, 'A new file cannot be made here:'#10 + ReasonText(Error), MessageOk, SignError, Self);
    Exit;
  end;
  Say('new-file ' + Name);
  FHistory.Push(MakeEntry(UndoNewFile, [''], [CombinePath(FView.Folder, Name)]));
  PutUpForRenaming(Name);
end;

procedure TItemCommandWindow.RenameFocused;
begin
  if (FView.ItemIndex < 0) or not FocusedEntry.IsRealFile then
    Exit;
  FBatchPaths.Clear;
  if FView.SelectedCount > 1 then
    FView.GetSelectedPaths(FBatchPaths);
  FView.EditItem(FView.ItemIndex, True);
end;

function TItemCommandWindow.NameTakenOutsideBatch(const Name: string): Boolean;
var
  Path: string;
begin
  Path := CombinePath(FView.Folder, Name);
  Result := PathExists(PChar(Path)) and (FBatchPaths.IndexOf(Path) < 0);
end;

procedure TItemCommandWindow.RenameBatch(const Typed: string);
var
  Items: TBatchItems;
  Names: TStringArray;
  Index: LongInt;
  Error: LongInt;
  Sources: array of string;
  Targets: array of string;
  Item: TFolderItem;
begin
  Items := nil;
  SetLength(Items, FBatchPaths.Count);
  for Index := 0 to FBatchPaths.Count - 1 do
  begin
    Items[Index].Name := LastPartOf(FBatchPaths[Index]);
    Items[Index].IsFolder := (DescribeItem(FBatchPaths[Index], Item) = ErrorNone) and IsFolderItem(Item);
  end;
  Names := BatchRenameNames(Typed, Items, @NameTakenOutsideBatch);
  Sources := nil;
  Targets := nil;
  for Index := 0 to FBatchPaths.Count - 1 do
  begin
    Error := RenamePath(PChar(FBatchPaths[Index]), PChar(CombinePath(FView.Folder, Names[Index])));
    if Error <> ErrorNone then
    begin
      Say('error rename ' + Items[Index].Name + ': ' + ReasonText(Error));
      Continue;
    end;
    SetLength(Sources, Length(Sources) + 1);
    Sources[High(Sources)] := FBatchPaths[Index];
    SetLength(Targets, Length(Targets) + 1);
    Targets[High(Targets)] := CombinePath(FView.Folder, Names[Index]);
    RenameInLists(FBatchPaths[Index], Targets[High(Targets)]);
  end;
  FHistory.Push(MakeEntry(UndoRename, Sources, Targets));
  Say('renamed-batch ' + IntToStr(Length(Targets)) + ' ' + Typed);
  FBatchPaths.Clear;
  FView.Refresh;
end;

procedure TItemCommandWindow.ItemRenamed(Sender: TItemView; Index: LongInt; const NewCaption: string;
  var Accept: Boolean);
var
  Entry: TFolderEntry;
  OldName: string;
  NewName: string;
  Problem: string;
  Error: LongInt;
  Extension: string;
begin
  Accept := False;
  Entry := FView.EntryAt(Index);
  if (Entry = nil) or not Entry.IsRealFile then
    Exit;
  OldName := Entry.Item.Name;
  NewName := NewCaption;
  { Extensions hidden: the old one stays on. }
  Extension := ExtensionOf(OldName);
  if not FView.ShowExtensions and not Entry.IsFolder and (Extension <> '') then
    NewName := NewName + '.' + Copy(OldName, Length(OldName) - Length(Extension) + 1, Length(Extension));
  if FBatchPaths.Count > 1 then
  begin
    RenameBatch(NewName);
    Exit;
  end;
  Problem := NameProblem(NewName);
  if Problem = '' then
  begin
    if NameTakenHere(NewName) and (LowerCase(NewName) <> LowerCase(OldName)) then
      Problem := 'There is already something named "' + NewName + '" here.'
    else
    begin
      Error := RenamePath(PChar(Entry.FullPath), PChar(CombinePath(FView.Folder, NewName)));
      if Error <> ErrorNone then
        Problem := ReasonText(Error);
    end;
  end;
  if Problem <> '' then
  begin
    Say('error rename ' + OldName + ': ' + Problem);
    ShowMessageBox(ProgramTitle, OldName + ' cannot be renamed to "' + NewName + '":'#10 + Problem, MessageOk,
      SignError, Self);
    Exit;
  end;
  Say('renamed ' + OldName + ' ' + NewName);
  FHistory.Push(MakeEntry(UndoRename, [Entry.FullPath], [CombinePath(FView.Folder, NewName)]));
  RenameInLists(Entry.FullPath, CombinePath(FView.Folder, NewName));
  FView.Refresh;
  FView.ItemIndex := FView.IndexOfName(NewName);
end;

{ --- Archives ------------------------------------------------------------------------------ }

procedure TItemCommandWindow.CompressSelected;
var
  Paths: TStringList;
  Name: string;
begin
  if FView.Location.Kind <> LocationFolder then
    Exit;
  Paths := TStringList.Create;
  try
    FView.GetSelectedPaths(Paths);
    if Paths.Count = 0 then
      Exit;
    if Paths.Count = 1 then
      Name := ChangeFileExt(LastPartOf(Paths[0]), '') + '.zip'
    else
      Name := LastPartOf(FView.Folder) + '.zip';
    if (Name = '.zip') then
      Name := 'Archive.zip';
    Name := FirstFreeName(Name, False, @NameTakenHere);
    Say('compress ' + IntToStr(Paths.Count) + ' ' + Name);
    StartOperation(OperationCompress, Paths, CombinePath(FView.Folder, Name));
  finally
    Paths.Free;
  end;
end;

procedure TItemCommandWindow.ExtractFocused;
var
  Archive: string;
  Folder: string;
  ShowWhenDone: Boolean;
  Paths: TStringList;
begin
  if FocusedIsArchive then
    Archive := FocusedEntry.FullPath
  else if FView.Location.Kind = LocationArchive then
    Archive := FView.Location.Path
  else
    Exit;
  if not ChooseExtractFolder(Archive, Self, Folder, ShowWhenDone) then
    Exit;
  Paths := TStringList.Create;
  try
    Paths.Add(Archive);
    if ShowWhenDone then
      ShowWhenExtracted := Folder
    else
      ShowWhenExtracted := '';
    Say('extract ' + Archive + ' ' + Folder);
    StartOperation(OperationExtract, Paths, Folder);
  finally
    Paths.Free;
  end;
end;

{ --- Lists and the clipboard ---------------------------------------------------------------- }

function TItemCommandWindow.SelectionIsPinned: Boolean;
var
  Entry: TFolderEntry;
begin
  Entry := FocusedEntry;
  if Entry = nil then
    Result := (FView.Folder <> '') and IsInUserList(ListPinned, FView.Folder)
  else
    Result := IsInUserList(ListPinned, Entry.FullPath);
end;

function TItemCommandWindow.SelectionIsFavorite: Boolean;
begin
  Result := (FocusedEntry <> nil) and IsInUserList(ListFavorites, FocusedEntry.FullPath);
end;

procedure TItemCommandWindow.PinSelected(Pin: Boolean);
var
  Paths: TStringList;
begin
  Paths := TStringList.Create;
  try
    FView.GetSelectedPaths(Paths, True);
    if (Paths.Count = 0) and (FView.Folder <> '') then
      Paths.Add(FView.Folder);
    PinPaths(Paths, Pin);
  finally
    Paths.Free;
  end;
end;

procedure TItemCommandWindow.PinPaths(Paths: TStrings; Pin: Boolean);
var
  Path: string;
begin
  for Path in Paths do
    if Pin and IsDirectory(PChar(Path)) then
    begin
      AddToUserList(ListPinned, Path);
      Say('pinned ' + Path);
    end
    else if not Pin then
    begin
      RemoveFromUserList(ListPinned, Path);
      Say('unpinned ' + Path);
    end;
  FPlaces.ShowPinned;
  if FView.Location.Kind = LocationHome then
    FView.Refresh;
end;

procedure TItemCommandWindow.FavoriteSelected(Favorite: Boolean);
var
  Paths: TStringList;
  Path: string;
begin
  Paths := TStringList.Create;
  try
    FView.GetSelectedPaths(Paths);
    for Path in Paths do
      if Favorite then
      begin
        AddToUserList(ListFavorites, Path);
        Say('favorite ' + Path);
      end
      else
      begin
        RemoveFromUserList(ListFavorites, Path);
        Say('not-favorite ' + Path);
      end;
  finally
    Paths.Free;
  end;
  if FView.Location.Kind = LocationHome then
    FView.Refresh;
end;

procedure TItemCommandWindow.CopyAsPath;
var
  Paths: TStringList;
  Text: string;
  Index: LongInt;
begin
  Paths := TStringList.Create;
  try
    FView.GetSelectedPaths(Paths, True);
    if (Paths.Count = 0) and (FView.Folder <> '') then
      Paths.Add(FView.Folder);
    Text := '';
    for Index := 0 to Paths.Count - 1 do
    begin
      if Index > 0 then
        Text := Text + #10;
      Text := Text + '"' + Paths[Index] + '"';
    end;
    SetClipboardText(Text);
    Say('copied-path ' + IntToStr(Paths.Count));
  finally
    Paths.Free;
  end;
end;

procedure TItemCommandWindow.SendTo(const Folder: string);
var
  Paths: TStringList;
begin
  Paths := TStringList.Create;
  try
    FView.GetSelectedPaths(Paths);
    if Paths.Count > 0 then
    begin
      Say('send-to ' + Folder);
      StartOperation(OperationCopy, Paths, Folder);
    end;
  finally
    Paths.Free;
  end;
end;

procedure TItemCommandWindow.SelectNone;
begin
  FView.ClearSelection;
end;

procedure TItemCommandWindow.InvertSelection;
begin
  FView.InvertSelection;
end;

procedure TItemCommandWindow.ShowProperties;
var
  Entry: TFolderEntry;
begin
  Entry := FocusedEntry;
  if (Entry <> nil) and FView.Selected[FView.ItemIndex] and (Entry.Kind in [EntryFile, EntryPlace, EntryTrashed]) then
    ShowItemProperties(Entry.FullPath, Self)
  else if (Entry <> nil) and (Entry.Kind = EntryVolume) then
    ShowVolumeProperties(Entry.VolumeName, Self)
  else if FView.Folder <> '' then
    ShowItemProperties(FView.Folder, Self);
end;

end.
