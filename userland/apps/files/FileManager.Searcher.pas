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
  Searching a folder and everything below it, on a thread of its own:
  results come in as they are found.

  Each item whose name and properties match the query (FileManager.
  SearchQuery) is a result; with content terms a file's first
  MostContentBytes are read too and must hold every term (any case).
  A scope inside an archive file ("/a/b.zip" or "/a/b.zip/docs")
  searches the archive's items below it (FileManager.ArchiveSearch),
  read with a reader of the thread's own; its members are taken out
  into memory for content terms (up to MostArchivedContentBytes).
  Symbolic links to folders are not followed (no loops), hidden items
  only on request. Found items gather under a lock; the window's thread
  is told with a message (at most one waiting) and takes them all
  (OnResults); OnFinished when the walk is over (or cancelled). Cancel
  stops it at the next item; a new search cancels the one before.
}
unit FileManager.Searcher;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Archive.Readers,
  Windowing.Messages,
  FileManager.SearchQuery,
  FileManager.Entries;

const
  MessageSearchResults = MessageUser + 42;
  MostContentBytes = 1024 * 1024;
  MostArchivedContentBytes = 64 * 1024 * 1024;
  MostResults = 20000;

type
  TSearchResultsEvent = procedure(Sender: TObject; Entries: TList) of object;
  TSearchEvent = procedure(Sender: TObject) of object;

  TFolderSearcher = class(TMessageReceiver)
  private
    FLock: TRTLCriticalSection;
    FThread: Int64;
    FScope: string;
    FQuery: TSearchQuery;
    FIncludeHidden: Boolean;
    FFound: TList;
    FCancelled: Boolean;
    FFinished: Boolean;
    FFinishTold: Boolean;
    FMessagePosted: Boolean;
    FResultCount: LongInt;
    FOnResults: TSearchResultsEvent;
    FOnFinished: TSearchEvent;
    procedure Walk(const Folder: string; Depth: LongInt);
    procedure SearchArchive(const Archive, Inner: string);
    procedure AddResult(Entry: TFolderEntry);
    function HoldsContentTerms(const Text: string): Boolean;
    function ContentMatches(const Path: string): Boolean;
    function ArchivedContentMatches(Reader: TArchiveReader; Index: LongInt): Boolean;
    procedure Deliver;
    procedure WaitForThread;
  public
    constructor Create;
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    procedure Start(const Scope: string; const Query: TSearchQuery; IncludeHidden: Boolean);
    procedure Cancel;
    function Running: Boolean;
    { (The thread.) }
    procedure Run;
    property OnResults: TSearchResultsEvent read FOnResults write FOnResults;
    property OnFinished: TSearchEvent read FOnFinished write FOnFinished;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.Files,
  Sys.Threads,
  Archive.Folders,
  Controls.FileNames,
  FileManager.Items,
  FileManager.FolderReading,
  FileManager.Locations,
  FileManager.Sources,
  FileManager.ArchiveSearch;

function RunSearch(Argument: Pointer): LongInt;
begin
  TFolderSearcher(Argument).Run;
  Result := 0;
end;

constructor TFolderSearcher.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
  FFound := TList.Create;
  FThread := -1;
end;

destructor TFolderSearcher.Destroy;
var
  Index: LongInt;
begin
  Cancel;
  WaitForThread;
  for Index := 0 to FFound.Count - 1 do
    TFolderEntry(FFound[Index]).Free;
  FFound.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TFolderSearcher.WaitForThread;
var
  ExitCode: LongInt;
begin
  if FThread < 0 then
    Exit;
  Sys.Threads.WaitForThread(FThread, -1, ExitCode);
  CloseThreadHandle(FThread);
  FThread := -1;
end;

procedure TFolderSearcher.Start(const Scope: string; const Query: TSearchQuery; IncludeHidden: Boolean);
var
  Index: LongInt;
begin
  Cancel;
  WaitForThread;
  for Index := 0 to FFound.Count - 1 do
    TFolderEntry(FFound[Index]).Free;
  FFound.Clear;
  FScope := Scope;
  UniqueString(FScope);
  FQuery := Query;
  FIncludeHidden := IncludeHidden;
  FCancelled := False;
  FFinished := False;
  FFinishTold := False;
  FMessagePosted := False;
  FResultCount := 0;
  FThread := CreateThread(@RunSearch, Self);
  if FThread < 0 then
  begin
    Run;
    Deliver;
  end;
end;

procedure TFolderSearcher.Cancel;
begin
  EnterCriticalSection(FLock);
  FCancelled := True;
  LeaveCriticalSection(FLock);
end;

function TFolderSearcher.Running: Boolean;
begin
  Result := (FThread >= 0) and not FFinishTold;
end;

function TFolderSearcher.ContentMatches(const Path: string): Boolean;
var
  Stream: TFileStream;
  Text: string;
  Count: LongInt;
begin
  Result := False;
  Text := '';
  try
    Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      Count := Stream.Size;
      if Count > MostContentBytes then
        Count := MostContentBytes;
      SetLength(Text, Count);
      if Count > 0 then
        Stream.ReadBuffer(Text[1], Count);
    finally
      Stream.Free;
    end;
  except
    on Exception do
      Exit(False);
  end;
  Result := HoldsContentTerms(Text);
end;

function TFolderSearcher.HoldsContentTerms(const Text: string): Boolean;
var
  Lowered: string;
  Term: string;
begin
  Lowered := LowerCase(Text);
  for Term in FQuery.ContentTerms do
    if Pos(LowerCase(Term), Lowered) = 0 then
      Exit(False);
  Result := True;
end;

function TFolderSearcher.ArchivedContentMatches(Reader: TArchiveReader; Index: LongInt): Boolean;
var
  Stream: TMemoryStream;
  Text: string;
  Count: Int64;
begin
  Result := False;
  if (Index < 0) or (Reader.Entries[Index].Size > MostArchivedContentBytes) then
    Exit;
  Text := '';
  Stream := TMemoryStream.Create;
  try
    try
      Reader.ExtractToStream(Index, Stream);
    except
      on Exception do
        Exit(False);
    end;
    Count := Stream.Size;
    if Count > MostContentBytes then
      Count := MostContentBytes;
    SetLength(Text, Count);
    if Count > 0 then
      Move(Stream.Memory^, Text[1], Count);
  finally
    Stream.Free;
  end;
  Result := HoldsContentTerms(Text);
end;

procedure TFolderSearcher.AddResult(Entry: TFolderEntry);
begin
  EnterCriticalSection(FLock);
  FFound.Add(Entry);
  Inc(FResultCount);
  if not FMessagePosted then
    FMessagePosted := PostMessage(Self, MessageSearchResults);
  LeaveCriticalSection(FLock);
end;

procedure TFolderSearcher.Walk(const Folder: string; Depth: LongInt);
var
  Items: TFolderItems;
  Index: LongInt;
  Item: TFolderItem;
  Path: string;
  Entry: TFolderEntry;
  IsFolder: Boolean;
begin
  if (Depth > 64) or FCancelled or (FResultCount >= MostResults) then
    Exit;
  if ReadFolderItems(Folder, FIncludeHidden, Items) <> ErrorNone then
    Exit;
  for Index := 0 to High(Items) do
  begin
    if FCancelled then
      Exit;
    Item := Items[Index];
    Path := CombinePath(Folder, Item.Name);
    IsFolder := IsFolderItem(Item);
    if MatchesQuery(FQuery, Item.Name, IsFolder, Item.SizeInBytes, Item.ModificationTime) and
       ((Length(FQuery.ContentTerms) = 0) or (not IsFolder and (Item.Kind = ItemFile) and ContentMatches(Path))) then
    begin
      Entry := TFolderEntry.Create;
      Entry.Kind := EntryFile;
      Entry.Item := Item;
      Entry.FullPath := Path;
      Entry.Folder := Folder;
      AddResult(Entry);
    end;
    if IsFolder and not Item.IsLink then
      Walk(Path, Depth + 1);
  end;
end;

procedure TFolderSearcher.SearchArchive(const Archive, Inner: string);
var
  Reader: TArchiveReader;
  ArchiveFile: TFileInformation;
  Found: TArchiveFolderItems;
  Index: LongInt;
begin
  if GetFileInformation(PChar(Archive), ArchiveFile) <> ErrorNone then
    Exit;
  try
    Reader := OpenArchive(Archive);
  except
    on Exception do
      Exit;
  end;
  try
    Found := FindInArchive(Reader, Inner, FQuery, FIncludeHidden);
    for Index := 0 to High(Found) do
    begin
      if FCancelled or (FResultCount >= MostResults) then
        Exit;
      if (Length(FQuery.ContentTerms) > 0) and
         (Found[Index].IsFolder or not ArchivedContentMatches(Reader, Found[Index].EntryIndex)) then
        Continue;
      AddResult(ArchivedEntry(Reader, Archive, Found[Index], ArchiveFile.ModificationTime));
    end;
  finally
    Reader.Free;
  end;
end;

procedure TFolderSearcher.Run;
var
  Archive: string;
  Inner: string;
begin
  if not IsDirectory(PChar(FScope)) and SplitArchivePath(FScope, Archive, Inner) then
    SearchArchive(Archive, Inner)
  else
    Walk(FScope, 0);
  EnterCriticalSection(FLock);
  FFinished := True;
  if not FMessagePosted then
    FMessagePosted := PostMessage(Self, MessageSearchResults);
  LeaveCriticalSection(FLock);
end;

procedure TFolderSearcher.Deliver;
var
  Ready: TList;
  Finished: Boolean;
  Cancelled: Boolean;
begin
  Ready := TList.Create;
  try
    EnterCriticalSection(FLock);
    Ready.Assign(FFound);
    FFound.Clear;
    FMessagePosted := False;
    Finished := FFinished;
    Cancelled := FCancelled;
    LeaveCriticalSection(FLock);
    if (Ready.Count > 0) and Assigned(FOnResults) and not Cancelled then
      { The handler takes the entries. }
      FOnResults(Self, Ready)
    else
      while Ready.Count > 0 do
      begin
        TFolderEntry(Ready[0]).Free;
        Ready.Delete(0);
      end;
    if Finished and not FFinishTold then
    begin
      FFinishTold := True;
      WaitForThread;
      if Assigned(FOnFinished) then
        FOnFinished(Self);
    end;
  finally
    Ready.Free;
  end;
end;

procedure TFolderSearcher.ReceiveMessage(var Message: TPostedMessage);
begin
  if Message.Code = MessageSearchResults then
  begin
    Deliver;
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

end.
