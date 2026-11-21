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
  The bookmarks: a tree under three folders that are always there - the
  Bookmarks Toolbar (shown on the bookmarks toolbar), the Bookmarks Menu
  (the Bookmarks menu) and Unsorted Bookmarks (what the star adds with
  one click). A folder holds bookmarks, folders and separators in order.
  A bookmark has a name, an address, tags (words to find it by, shown in
  the Library under Tags), a keyword (typed in the location bar, with
  "%s" in the address standing for the words after it) and a
  description.

  Kept in bookmarks.txt in the profile, a node a line, depth first so a
  folder comes before what it holds (fields tab-separated):

    #bookmarks 2
    F  id  parent  title  added  description
    B  id  parent  title  url  tags  keyword  added  description
    S  id  parent

  (the three folders are ids 2, 3 and 4 and are not written). A file of
  the older format (title and URL a line) is read into the Bookmarks
  Toolbar folder, where the old bookmarks bar showed them.

  Plain logic (the RTL only), checked on the host.
}
unit Browser.Bookmarks;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes;

const
  RootFolderId = 1;
  MenuFolderId = 2;
  ToolbarFolderId = 3;
  UnsortedFolderId = 4;

type
  TBookmarkKind = (BookmarkItem, BookmarkFolder, BookmarkSeparator);

  TBookmarkNode = class
  private
    FChildren: TList;
    FParent: TBookmarkNode;
    function GetChild(Index: Integer): TBookmarkNode;
  public
    Id: Integer;
    Kind: TBookmarkKind;
    Title: string;
    Url: string;
    Keyword: string;
    Description: string;
    Tags: TStringArray;
    { Unix time it was made. }
    Added: Int64;
    constructor Create(AKind: TBookmarkKind);
    destructor Destroy; override;
    function Count: Integer;
    function IndexOf(Child: TBookmarkNode): Integer;
    function IsFolder: Boolean;
    { Whether Node is this one or below it. }
    function Contains(Node: TBookmarkNode): Boolean;
    { The tags joined with ", ". }
    function TagText: string;
    { The name shown: the title, else the address. }
    function ShownTitle: string;
    property Parent: TBookmarkNode read FParent;
    property Children[Index: Integer]: TBookmarkNode read GetChild; default;
  end;

  TBookmarkNodeList = array of TBookmarkNode;

  TBookmarkStore = class
  private
    FPath: string;
    FRoot: TBookmarkNode;
    FMenu: TBookmarkNode;
    FToolbar: TBookmarkNode;
    FUnsorted: TBookmarkNode;
    FNextId: Integer;
    FUpdating: Integer;
    FDirty: Boolean;
    FOnChanged: TNotifyEvent;
    procedure MakeRoots;
    procedure Attach(Node, Folder: TBookmarkNode; Index: Integer);
    procedure Detach(Node: TBookmarkNode);
    function NewNode(Kind: TBookmarkKind): TBookmarkNode;
    procedure LoadOldFormat(Lines: TStringList);
    procedure LoadNodes(Lines: TStringList);
    procedure SaveNode(Node: TBookmarkNode; Lines: TStringList);
    procedure CollectItems(Node: TBookmarkNode; var List: TBookmarkNodeList);
  public
    constructor Create(const Path: string);
    destructor Destroy; override;
    procedure Load;
    procedure Save;
    { Saves (and tells OnChanged) once, at the outermost EndUpdate. }
    procedure BeginUpdate;
    procedure EndUpdate;
    { A node's fields were changed by hand: save and tell. }
    procedure Changed;
    function NodeById(Id: Integer): TBookmarkNode;
    { The first bookmark of Url (nil: none). }
    function FindUrl(const Url: string): TBookmarkNode;
    function IsBookmarked(const Url: string): Boolean;
    { Index -1: at the end; Added: the Unix time now. }
    function AddBookmark(Folder: TBookmarkNode; const Title, Url: string; Index: Integer = -1;
      Added: Int64 = 0): TBookmarkNode;
    function AddFolder(Folder: TBookmarkNode; const Title: string; Index: Integer = -1;
      Added: Int64 = 0): TBookmarkNode;
    function AddSeparator(Folder: TBookmarkNode; Index: Integer = -1): TBookmarkNode;
    { Moves Node into Folder at Index (-1: the end); False if it cannot
      go there (a root folder, into itself or below itself). }
    function Move(Node, Folder: TBookmarkNode; Index: Integer): Boolean;
    { Removes and frees Node (not a root folder). }
    procedure Delete(Node: TBookmarkNode);
    { Removes every bookmark of Url. }
    procedure DeleteUrl(const Url: string);
    { Tags from Text, comma separated (trimmed, no repeats). }
    procedure SetTags(Node: TBookmarkNode; const Text: string);
    { Every tag used, sorted. }
    function AllTags: TStringArray;
    function Tagged(const Tag: string): TBookmarkNodeList;
    { Every bookmark (not folders or separators), depth first. }
    function AllBookmarks: TBookmarkNodeList;
    { The Count bookmarks made last, newest first. }
    function RecentlyBookmarked(Count: Integer): TBookmarkNodeList;
    { The tags of the bookmarks made last, newest first, at most Count. }
    function RecentTags(Count: Integer): TStringArray;
    { The bookmarks whose name, address, tags, keyword or description hold
      every word of Text. }
    function Search(const Text: string): TBookmarkNodeList;
    function FindKeyword(const Keyword: string): TBookmarkNode;
    { The invisible top: its children are the three folders. }
    property Root: TBookmarkNode read FRoot;
    property MenuFolder: TBookmarkNode read FMenu;
    property ToolbarFolder: TBookmarkNode read FToolbar;
    property UnsortedFolder: TBookmarkNode read FUnsorted;
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
  end;

{ Text split at commas, trimmed, empty and repeated ones dropped. }
function ParseTags(const Text: string): TStringArray;

implementation

uses
  Browser.TextFiles,
  Browser.History;

const
  FormatHeader = '#bookmarks 2';

function ParseTags(const Text: string): TStringArray;
var
  Parts: TStringArray;
  Index, Other: Integer;
  Tag: string;
  Repeated: Boolean;
begin
  Result := nil;
  Parts := Text.Split([',']);
  for Index := 0 to High(Parts) do
  begin
    Tag := Trim(Parts[Index]);
    if Tag = '' then
      Continue;
    Repeated := False;
    for Other := 0 to High(Result) do
      if SameText(Result[Other], Tag) then
        Repeated := True;
    if Repeated then
      Continue;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Tag;
  end;
end;

{ ---- nodes ---- }

constructor TBookmarkNode.Create(AKind: TBookmarkKind);
begin
  inherited Create;
  Kind := AKind;
  FChildren := TList.Create;
end;

destructor TBookmarkNode.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FChildren.Count - 1 do
    TBookmarkNode(FChildren[Index]).Free;
  FChildren.Free;
  inherited Destroy;
end;

function TBookmarkNode.GetChild(Index: Integer): TBookmarkNode;
begin
  Result := TBookmarkNode(FChildren[Index]);
end;

function TBookmarkNode.Count: Integer;
begin
  Result := FChildren.Count;
end;

function TBookmarkNode.IndexOf(Child: TBookmarkNode): Integer;
begin
  Result := FChildren.IndexOf(Child);
end;

function TBookmarkNode.IsFolder: Boolean;
begin
  Result := Kind = BookmarkFolder;
end;

function TBookmarkNode.Contains(Node: TBookmarkNode): Boolean;
begin
  while Node <> nil do
  begin
    if Node = Self then
      Exit(True);
    Node := Node.FParent;
  end;
  Result := False;
end;

function TBookmarkNode.TagText: string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Tags) do
  begin
    if Index > 0 then
      Result := Result + ', ';
    Result := Result + Tags[Index];
  end;
end;

function TBookmarkNode.ShownTitle: string;
begin
  Result := Title;
  if Result = '' then
    Result := Url;
end;

{ ---- the store ---- }

constructor TBookmarkStore.Create(const Path: string);
begin
  inherited Create;
  FPath := Path;
  MakeRoots;
end;

destructor TBookmarkStore.Destroy;
begin
  FRoot.Free;
  inherited Destroy;
end;

procedure TBookmarkStore.MakeRoots;
begin
  FRoot.Free;
  FRoot := TBookmarkNode.Create(BookmarkFolder);
  FRoot.Id := RootFolderId;
  FRoot.Title := 'All Bookmarks';
  FToolbar := TBookmarkNode.Create(BookmarkFolder);
  FToolbar.Id := ToolbarFolderId;
  FToolbar.Title := 'Bookmarks Toolbar';
  Attach(FToolbar, FRoot, -1);
  FMenu := TBookmarkNode.Create(BookmarkFolder);
  FMenu.Id := MenuFolderId;
  FMenu.Title := 'Bookmarks Menu';
  Attach(FMenu, FRoot, -1);
  FUnsorted := TBookmarkNode.Create(BookmarkFolder);
  FUnsorted.Id := UnsortedFolderId;
  FUnsorted.Title := 'Unsorted Bookmarks';
  Attach(FUnsorted, FRoot, -1);
  FNextId := 10;
end;

procedure TBookmarkStore.Attach(Node, Folder: TBookmarkNode; Index: Integer);
begin
  if (Index < 0) or (Index > Folder.FChildren.Count) then
    Index := Folder.FChildren.Count;
  Folder.FChildren.Insert(Index, Node);
  Node.FParent := Folder;
end;

procedure TBookmarkStore.Detach(Node: TBookmarkNode);
begin
  if Node.FParent <> nil then
    Node.FParent.FChildren.Remove(Node);
  Node.FParent := nil;
end;

function TBookmarkStore.NewNode(Kind: TBookmarkKind): TBookmarkNode;
begin
  Result := TBookmarkNode.Create(Kind);
  Result.Id := FNextId;
  Inc(FNextId);
end;

function TBookmarkStore.NodeById(Id: Integer): TBookmarkNode;

  function FindIn(Node: TBookmarkNode): TBookmarkNode;
  var
    Index: Integer;
  begin
    if Node.Id = Id then
      Exit(Node);
    for Index := 0 to Node.Count - 1 do
    begin
      Result := FindIn(Node[Index]);
      if Result <> nil then
        Exit;
    end;
    Result := nil;
  end;

begin
  Result := FindIn(FRoot);
end;

procedure TBookmarkStore.Load;
var
  Lines: TStringList;
begin
  MakeRoots;
  Lines := ReadLines(FPath);
  try
    if (Lines.Count > 0) and (Lines[0] = FormatHeader) then
      LoadNodes(Lines)
    else
      LoadOldFormat(Lines);
  finally
    Lines.Free;
  end;
end;

procedure TBookmarkStore.LoadOldFormat(Lines: TStringList);
var
  Index: Integer;
  Fields: TStringArray;
  Node: TBookmarkNode;
begin
  for Index := 0 to Lines.Count - 1 do
  begin
    Fields := Lines[Index].Split([#9]);
    if (Length(Fields) < 2) or (Fields[1] = '') then
      Continue;
    Node := NewNode(BookmarkItem);
    Node.Title := Fields[0];
    Node.Url := Fields[1];
    Attach(Node, FToolbar, -1);
  end;
end;

procedure TBookmarkStore.LoadNodes(Lines: TStringList);
var
  Index, Id: Integer;
  Fields: TStringArray;
  Node, Folder: TBookmarkNode;
  Kind: TBookmarkKind;
  Ids: TStringList;
begin
  { Ids found so far, to their nodes (a parent comes before its children). }
  Ids := TStringList.Create;
  try
    Ids.Sorted := True;
    Ids.AddObject(IntToStr(MenuFolderId), FMenu);
    Ids.AddObject(IntToStr(ToolbarFolderId), FToolbar);
    Ids.AddObject(IntToStr(UnsortedFolderId), FUnsorted);
    for Index := 1 to Lines.Count - 1 do
    begin
      Fields := Lines[Index].Split([#9]);
      if Length(Fields) < 3 then
        Continue;
      case Fields[0] of
        'F': Kind := BookmarkFolder;
        'B': Kind := BookmarkItem;
        'S': Kind := BookmarkSeparator;
      else
        Continue;
      end;
      Id := StrToIntDef(Fields[1], 0);
      if (Id <= UnsortedFolderId) or (Ids.IndexOf(IntToStr(Id)) >= 0) then
        Continue;
      Node := TBookmarkNode.Create(Kind);
      Node.Id := Id;
      if Id >= FNextId then
        FNextId := Id + 1;
      case Kind of
        BookmarkFolder:
          begin
            Node.Title := FieldAt(Fields, 3);
            Node.Added := StrToInt64Def(FieldAt(Fields, 4), 0);
            Node.Description := FieldAt(Fields, 5);
          end;
        BookmarkItem:
          begin
            Node.Title := FieldAt(Fields, 3);
            Node.Url := FieldAt(Fields, 4);
            Node.Tags := ParseTags(FieldAt(Fields, 5));
            Node.Keyword := FieldAt(Fields, 6);
            Node.Added := StrToInt64Def(FieldAt(Fields, 7), 0);
            Node.Description := FieldAt(Fields, 8);
          end;
      end;
      Folder := FUnsorted;
      if Ids.Find(Fields[2], Id) and TBookmarkNode(Ids.Objects[Id]).IsFolder then
        Folder := TBookmarkNode(Ids.Objects[Id]);
      Attach(Node, Folder, -1);
      Ids.AddObject(IntToStr(Node.Id), Node);
    end;
  finally
    Ids.Free;
  end;
end;

procedure TBookmarkStore.SaveNode(Node: TBookmarkNode; Lines: TStringList);
var
  Index: Integer;
  ParentId: string;
begin
  if Node.Id > UnsortedFolderId then
  begin
    ParentId := IntToStr(Node.Parent.Id);
    case Node.Kind of
      BookmarkFolder:
        Lines.Add(JoinFields(['F', IntToStr(Node.Id), ParentId, Node.Title, IntToStr(Node.Added),
          Node.Description]));
      BookmarkItem:
        Lines.Add(JoinFields(['B', IntToStr(Node.Id), ParentId, Node.Title, Node.Url, Node.TagText,
          Node.Keyword, IntToStr(Node.Added), Node.Description]));
      BookmarkSeparator:
        Lines.Add(JoinFields(['S', IntToStr(Node.Id), ParentId]));
    end;
  end;
  for Index := 0 to Node.Count - 1 do
    SaveNode(Node[Index], Lines);
end;

procedure TBookmarkStore.Save;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Add(FormatHeader);
    SaveNode(FRoot, Lines);
    WriteLines(Lines, FPath);
  finally
    Lines.Free;
  end;
end;

procedure TBookmarkStore.BeginUpdate;
begin
  Inc(FUpdating);
end;

procedure TBookmarkStore.EndUpdate;
begin
  Dec(FUpdating);
  if (FUpdating = 0) and FDirty then
    Changed;
end;

procedure TBookmarkStore.Changed;
begin
  if FUpdating > 0 then
  begin
    FDirty := True;
    Exit;
  end;
  FDirty := False;
  Save;
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

function TBookmarkStore.FindUrl(const Url: string): TBookmarkNode;
var
  All: TBookmarkNodeList;
  Index: Integer;
begin
  All := AllBookmarks;
  for Index := 0 to High(All) do
    if All[Index].Url = Url then
      Exit(All[Index]);
  Result := nil;
end;

function TBookmarkStore.IsBookmarked(const Url: string): Boolean;
begin
  Result := (Url <> '') and (FindUrl(Url) <> nil);
end;

function TBookmarkStore.AddBookmark(Folder: TBookmarkNode; const Title, Url: string; Index: Integer;
  Added: Int64): TBookmarkNode;
begin
  if (Folder = nil) or not Folder.IsFolder or (Folder = FRoot) then
    Folder := FUnsorted;
  Result := NewNode(BookmarkItem);
  Result.Title := Title;
  Result.Url := Url;
  Result.Added := Added;
  Attach(Result, Folder, Index);
  Changed;
end;

function TBookmarkStore.AddFolder(Folder: TBookmarkNode; const Title: string; Index: Integer;
  Added: Int64): TBookmarkNode;
begin
  if (Folder = nil) or not Folder.IsFolder or (Folder = FRoot) then
    Folder := FMenu;
  Result := NewNode(BookmarkFolder);
  Result.Title := Title;
  Result.Added := Added;
  Attach(Result, Folder, Index);
  Changed;
end;

function TBookmarkStore.AddSeparator(Folder: TBookmarkNode; Index: Integer): TBookmarkNode;
begin
  if (Folder = nil) or not Folder.IsFolder or (Folder = FRoot) then
    Folder := FMenu;
  Result := NewNode(BookmarkSeparator);
  Attach(Result, Folder, Index);
  Changed;
end;

function TBookmarkStore.Move(Node, Folder: TBookmarkNode; Index: Integer): Boolean;
var
  OldIndex: Integer;
begin
  Result := False;
  if (Node = nil) or (Folder = nil) or not Folder.IsFolder or (Folder = FRoot) or (Node.Id <= UnsortedFolderId) or
     Node.Contains(Folder) then
    Exit;
  OldIndex := -1;
  if Node.Parent = Folder then
    OldIndex := Folder.IndexOf(Node);
  Detach(Node);
  { Moving down within one folder: the place counted the node itself. }
  if (OldIndex >= 0) and (Index > OldIndex) then
    Dec(Index);
  Attach(Node, Folder, Index);
  Changed;
  Result := True;
end;

procedure TBookmarkStore.Delete(Node: TBookmarkNode);
begin
  if (Node = nil) or (Node.Id <= UnsortedFolderId) then
    Exit;
  Detach(Node);
  Node.Free;
  Changed;
end;

procedure TBookmarkStore.DeleteUrl(const Url: string);
var
  Node: TBookmarkNode;
begin
  BeginUpdate;
  try
    Node := FindUrl(Url);
    while Node <> nil do
    begin
      Delete(Node);
      Node := FindUrl(Url);
    end;
  finally
    EndUpdate;
  end;
end;

procedure TBookmarkStore.SetTags(Node: TBookmarkNode; const Text: string);
begin
  if Node = nil then
    Exit;
  Node.Tags := ParseTags(Text);
  Changed;
end;

procedure TBookmarkStore.CollectItems(Node: TBookmarkNode; var List: TBookmarkNodeList);
var
  Index: Integer;
begin
  if Node.Kind = BookmarkItem then
  begin
    SetLength(List, Length(List) + 1);
    List[High(List)] := Node;
  end;
  for Index := 0 to Node.Count - 1 do
    CollectItems(Node[Index], List);
end;

function TBookmarkStore.AllBookmarks: TBookmarkNodeList;
begin
  Result := nil;
  CollectItems(FRoot, Result);
end;

function TBookmarkStore.AllTags: TStringArray;
var
  All: TBookmarkNodeList;
  Names: TStringList;
  Index, Tag: Integer;
begin
  Names := TStringList.Create;
  try
    Names.Sorted := True;
    Names.CaseSensitive := False;
    Names.Duplicates := dupIgnore;
    All := AllBookmarks;
    for Index := 0 to High(All) do
      for Tag := 0 to High(All[Index].Tags) do
        Names.Add(All[Index].Tags[Tag]);
    Result := nil;
    SetLength(Result, Names.Count);
    for Index := 0 to Names.Count - 1 do
      Result[Index] := Names[Index];
  finally
    Names.Free;
  end;
end;

function TBookmarkStore.Tagged(const Tag: string): TBookmarkNodeList;
var
  All: TBookmarkNodeList;
  Index, Other: Integer;
begin
  Result := nil;
  All := AllBookmarks;
  for Index := 0 to High(All) do
    for Other := 0 to High(All[Index].Tags) do
      if SameText(All[Index].Tags[Other], Tag) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := All[Index];
        Break;
      end;
end;

function TBookmarkStore.RecentlyBookmarked(Count: Integer): TBookmarkNodeList;
var
  All: TBookmarkNodeList;
  Index, Place: Integer;
  Node: TBookmarkNode;
begin
  All := AllBookmarks;
  { Newest first (a stable insertion sort: few bookmarks). }
  for Index := 1 to High(All) do
  begin
    Node := All[Index];
    Place := Index;
    while (Place > 0) and (All[Place - 1].Added < Node.Added) do
    begin
      All[Place] := All[Place - 1];
      Dec(Place);
    end;
    All[Place] := Node;
  end;
  Result := All;
  if Length(Result) > Count then
    SetLength(Result, Count);
end;

function TBookmarkStore.RecentTags(Count: Integer): TStringArray;
var
  Recent: TBookmarkNodeList;
  Index, Tag, Other: Integer;
  Known: Boolean;
begin
  Result := nil;
  Recent := RecentlyBookmarked(MaxInt);
  for Index := 0 to High(Recent) do
    for Tag := 0 to High(Recent[Index].Tags) do
    begin
      if Length(Result) >= Count then
        Exit;
      Known := False;
      for Other := 0 to High(Result) do
        if SameText(Result[Other], Recent[Index].Tags[Tag]) then
          Known := True;
      if not Known then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Recent[Index].Tags[Tag];
      end;
    end;
end;

function TBookmarkStore.Search(const Text: string): TBookmarkNodeList;
var
  All: TBookmarkNodeList;
  Words: TStringArray;
  Index: Integer;
  Node: TBookmarkNode;
begin
  Result := nil;
  Words := SplitWords(Text);
  All := AllBookmarks;
  for Index := 0 to High(All) do
  begin
    Node := All[Index];
    if MatchesAllWords(Node.Title + ' ' + Node.Url + ' ' + Node.TagText + ' ' + Node.Keyword + ' ' +
       Node.Description, Words) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Node;
    end;
  end;
end;

function TBookmarkStore.FindKeyword(const Keyword: string): TBookmarkNode;
var
  All: TBookmarkNodeList;
  Index: Integer;
begin
  Result := nil;
  if Keyword = '' then
    Exit;
  All := AllBookmarks;
  for Index := 0 to High(All) do
    if SameText(All[Index].Keyword, Keyword) then
      Exit(All[Index]);
end;

end.
