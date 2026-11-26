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
  An IndexedDB database in memory (Indexed Database API 3.0, 2.1-2.7):
  its name, version and object stores; a store's key path, key
  generator, records and indexes; an index's key path, unique and
  multiEntry flags and entries.

  Records map a primary key to the serialized value. An index keeps two
  lists: its entries (index key then primary key, mapping to the
  primary key), sorted as the index iterates, and the same pairs the
  other way round (primary key then index key), so a record's entries
  are found when it is overwritten or deleted. The page computes index
  keys (it alone can evaluate key paths on values); key paths are kept
  as the bytes it sent.

  Every change a transaction makes goes to its undo log
  (TIdbUndoLog): list changes through the lists' observer (the
  database's relay, pointed at the running transaction's log), schema
  changes through the Log* routines. Abort plays the log backwards;
  commit forgets it and frees what was deleted.
}
unit Web.IndexedDb.Database;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Web.IndexedDb.Keys,
  Web.IndexedDb.Entries;

type
  TIdbIndex = class
  public
    Id: LongWord;
    Name: RawByteString;
    KeyPath: TBytes;
    Unique: Boolean;
    MultiEntry: Boolean;
    Entries: TIdbEntryList;
    Reverse: TIdbEntryList;
    constructor Create;
    destructor Destroy; override;
    function Bytes: Int64;
  end;

  TIdbObjectStore = class
  private
    FIndexes: TFPList;
    function GetIndex(Position: Integer): TIdbIndex;
  public
    Id: LongWord;
    Name: RawByteString;
    KeyPath: TBytes;
    AutoIncrement: Boolean;
    { The key generator's current number (2.11). }
    Generator: Double;
    NextIndexId: LongWord;
    Records: TIdbEntryList;
    constructor Create;
    destructor Destroy; override;
    function IndexCount: Integer;
    function FindIndex(IndexId: LongWord): TIdbIndex;
    function FindIndexNamed(const IndexName: RawByteString): TIdbIndex;
    function PositionOfIndex(Index: TIdbIndex): Integer;
    procedure InsertIndex(Position: Integer; Index: TIdbIndex);
    procedure DetachIndex(Index: TIdbIndex);
    function Bytes: Int64;
    property Indexes[Position: Integer]: TIdbIndex read GetIndex;
  end;

  TIdbUndoLog = class;

  { Forwards the database's list changes to the running transaction. }
  TIdbUndoRelay = class(TIdbEntryObserver)
  public
    Log: TIdbUndoLog;
    procedure EntryInserted(List: TIdbEntryList; const Key: TBytes); override;
    procedure EntryReplaced(List: TIdbEntryList; const Key, OldValue: TBytes); override;
    procedure EntryDeleted(List: TIdbEntryList; const Key, OldValue: TBytes); override;
  end;

  TIdbDatabase = class
  private
    FStores: TFPList;
    FRelay: TIdbUndoRelay;
    function GetStore(Position: Integer): TIdbObjectStore;
  public
    { 0: a page's database; 1: the origin's Cache API storage. }
    Namespace: Byte;
    Name: RawByteString;
    Version: Int64;
    NextStoreId: LongWord;
    constructor Create;
    destructor Destroy; override;
    function StoreCount: Integer;
    function FindStore(StoreId: LongWord): TIdbObjectStore;
    function FindStoreNamed(const StoreName: RawByteString): TIdbObjectStore;
    function PositionOfStore(Store: TIdbObjectStore): Integer;
    procedure InsertStore(Position: Integer; Store: TIdbObjectStore);
    procedure DetachStore(Store: TIdbObjectStore);
    { Points the lists' changes at Log (nil: none recorded). }
    procedure WatchLists(Log: TIdbUndoLog);
    procedure AttachList(List: TIdbEntryList);
    function Bytes: Int64;
    property Stores[Position: Integer]: TIdbObjectStore read GetStore;
  end;

  TIdbUndoKind = (UndoInserted, UndoReplaced, UndoDeleted, UndoStoreCreated, UndoStoreDeleted,
    UndoStoreRenamed, UndoIndexCreated, UndoIndexDeleted, UndoIndexRenamed, UndoGenerator, UndoVersion);

  TIdbUndoEntry = record
    Kind: TIdbUndoKind;
    List: TIdbEntryList;
    Key, Value: TBytes;
    Store: TIdbObjectStore;
    Index: TIdbIndex;
    Position: Integer;
    Name: RawByteString;
    Number: Double;
  end;

  TIdbUndoLog = class
  private
    FEntries: array of TIdbUndoEntry;
    FCount: Integer;
    FDatabase: TIdbDatabase;
    function Add(Kind: TIdbUndoKind): Integer;
  public
    constructor Create(Database: TIdbDatabase);
    { Commit: deleted stores and indexes are freed. }
    destructor Destroy; override;
    procedure LogList(Kind: TIdbUndoKind; List: TIdbEntryList; const Key, Value: TBytes);
    procedure LogStoreCreated(Store: TIdbObjectStore);
    procedure LogStoreDeleted(Store: TIdbObjectStore; Position: Integer);
    procedure LogStoreRenamed(Store: TIdbObjectStore; const OldName: RawByteString);
    procedure LogIndexCreated(Store: TIdbObjectStore; Index: TIdbIndex);
    procedure LogIndexDeleted(Store: TIdbObjectStore; Index: TIdbIndex; Position: Integer);
    procedure LogIndexRenamed(Index: TIdbIndex; const OldName: RawByteString);
    procedure LogGenerator(Store: TIdbObjectStore; OldValue: Double);
    procedure LogVersion(OldVersion: Int64);
    { Abort: everything back as it was, the log emptied. }
    procedure Undo;
    property Count: Integer read FCount;
  end;

implementation

{ TIdbIndex }

constructor TIdbIndex.Create;
begin
  inherited Create;
  Entries := TIdbEntryList.Create;
  Reverse := TIdbEntryList.Create;
end;

destructor TIdbIndex.Destroy;
begin
  Entries.Free;
  Reverse.Free;
  inherited Destroy;
end;

function TIdbIndex.Bytes: Int64;
begin
  Result := Entries.Bytes;
end;

{ TIdbObjectStore }

constructor TIdbObjectStore.Create;
begin
  inherited Create;
  FIndexes := TFPList.Create;
  Records := TIdbEntryList.Create;
  Generator := 1;
  NextIndexId := 1;
end;

destructor TIdbObjectStore.Destroy;
var
  Position: Integer;
begin
  for Position := 0 to FIndexes.Count - 1 do
    TIdbIndex(FIndexes[Position]).Free;
  FIndexes.Free;
  Records.Free;
  inherited Destroy;
end;

function TIdbObjectStore.GetIndex(Position: Integer): TIdbIndex;
begin
  Result := TIdbIndex(FIndexes[Position]);
end;

function TIdbObjectStore.IndexCount: Integer;
begin
  Result := FIndexes.Count;
end;

function TIdbObjectStore.FindIndex(IndexId: LongWord): TIdbIndex;
var
  Position: Integer;
begin
  for Position := 0 to FIndexes.Count - 1 do
    if TIdbIndex(FIndexes[Position]).Id = IndexId then
      Exit(TIdbIndex(FIndexes[Position]));
  Result := nil;
end;

function TIdbObjectStore.FindIndexNamed(const IndexName: RawByteString): TIdbIndex;
var
  Position: Integer;
begin
  for Position := 0 to FIndexes.Count - 1 do
    if TIdbIndex(FIndexes[Position]).Name = IndexName then
      Exit(TIdbIndex(FIndexes[Position]));
  Result := nil;
end;

function TIdbObjectStore.PositionOfIndex(Index: TIdbIndex): Integer;
begin
  Result := FIndexes.IndexOf(Index);
end;

procedure TIdbObjectStore.InsertIndex(Position: Integer; Index: TIdbIndex);
begin
  if (Position < 0) or (Position > FIndexes.Count) then
    Position := FIndexes.Count;
  FIndexes.Insert(Position, Index);
end;

procedure TIdbObjectStore.DetachIndex(Index: TIdbIndex);
begin
  FIndexes.Remove(Index);
end;

function TIdbObjectStore.Bytes: Int64;
var
  Position: Integer;
begin
  Result := Records.Bytes;
  for Position := 0 to FIndexes.Count - 1 do
    Result := Result + TIdbIndex(FIndexes[Position]).Bytes;
end;

{ TIdbUndoRelay }

procedure TIdbUndoRelay.EntryInserted(List: TIdbEntryList; const Key: TBytes);
begin
  if Log <> nil then
    Log.LogList(UndoInserted, List, Key, nil);
end;

procedure TIdbUndoRelay.EntryReplaced(List: TIdbEntryList; const Key, OldValue: TBytes);
begin
  if Log <> nil then
    Log.LogList(UndoReplaced, List, Key, OldValue);
end;

procedure TIdbUndoRelay.EntryDeleted(List: TIdbEntryList; const Key, OldValue: TBytes);
begin
  if Log <> nil then
    Log.LogList(UndoDeleted, List, Key, OldValue);
end;

{ TIdbDatabase }

constructor TIdbDatabase.Create;
begin
  inherited Create;
  FStores := TFPList.Create;
  FRelay := TIdbUndoRelay.Create;
  NextStoreId := 1;
end;

destructor TIdbDatabase.Destroy;
var
  Position: Integer;
begin
  for Position := 0 to FStores.Count - 1 do
    TIdbObjectStore(FStores[Position]).Free;
  FStores.Free;
  FRelay.Free;
  inherited Destroy;
end;

function TIdbDatabase.GetStore(Position: Integer): TIdbObjectStore;
begin
  Result := TIdbObjectStore(FStores[Position]);
end;

function TIdbDatabase.StoreCount: Integer;
begin
  Result := FStores.Count;
end;

function TIdbDatabase.FindStore(StoreId: LongWord): TIdbObjectStore;
var
  Position: Integer;
begin
  for Position := 0 to FStores.Count - 1 do
    if TIdbObjectStore(FStores[Position]).Id = StoreId then
      Exit(TIdbObjectStore(FStores[Position]));
  Result := nil;
end;

function TIdbDatabase.FindStoreNamed(const StoreName: RawByteString): TIdbObjectStore;
var
  Position: Integer;
begin
  for Position := 0 to FStores.Count - 1 do
    if TIdbObjectStore(FStores[Position]).Name = StoreName then
      Exit(TIdbObjectStore(FStores[Position]));
  Result := nil;
end;

function TIdbDatabase.PositionOfStore(Store: TIdbObjectStore): Integer;
begin
  Result := FStores.IndexOf(Store);
end;

procedure TIdbDatabase.InsertStore(Position: Integer; Store: TIdbObjectStore);
var
  IndexPosition: Integer;
begin
  if (Position < 0) or (Position > FStores.Count) then
    Position := FStores.Count;
  FStores.Insert(Position, Store);
  AttachList(Store.Records);
  for IndexPosition := 0 to Store.IndexCount - 1 do
  begin
    AttachList(Store.Indexes[IndexPosition].Entries);
    AttachList(Store.Indexes[IndexPosition].Reverse);
  end;
end;

procedure TIdbDatabase.DetachStore(Store: TIdbObjectStore);
begin
  FStores.Remove(Store);
end;

procedure TIdbDatabase.AttachList(List: TIdbEntryList);
begin
  List.Observer := FRelay;
end;

procedure TIdbDatabase.WatchLists(Log: TIdbUndoLog);
begin
  FRelay.Log := Log;
end;

function TIdbDatabase.Bytes: Int64;
var
  Position: Integer;
begin
  Result := Length(Name);
  for Position := 0 to FStores.Count - 1 do
    Result := Result + TIdbObjectStore(FStores[Position]).Bytes;
end;

{ TIdbUndoLog }

constructor TIdbUndoLog.Create(Database: TIdbDatabase);
begin
  inherited Create;
  FDatabase := Database;
end;

destructor TIdbUndoLog.Destroy;
var
  Position: Integer;
begin
  for Position := 0 to FCount - 1 do
    case FEntries[Position].Kind of
      UndoStoreDeleted: FEntries[Position].Store.Free;
      UndoIndexDeleted: FEntries[Position].Index.Free;
    end;
  inherited Destroy;
end;

function TIdbUndoLog.Add(Kind: TIdbUndoKind): Integer;
begin
  if FCount = Length(FEntries) then
  begin
    if FCount < 16 then
      SetLength(FEntries, 16)
    else
      SetLength(FEntries, FCount * 2);
  end;
  Result := FCount;
  FEntries[Result] := Default(TIdbUndoEntry);
  FEntries[Result].Kind := Kind;
  Inc(FCount);
end;

procedure TIdbUndoLog.LogList(Kind: TIdbUndoKind; List: TIdbEntryList; const Key, Value: TBytes);
var
  Position: Integer;
begin
  Position := Add(Kind);
  FEntries[Position].List := List;
  FEntries[Position].Key := Key;
  FEntries[Position].Value := Value;
end;

procedure TIdbUndoLog.LogStoreCreated(Store: TIdbObjectStore);
var
  Entry: Integer;
begin
  { Add may move the array: index it after. }
  Entry := Add(UndoStoreCreated);
  FEntries[Entry].Store := Store;
end;

procedure TIdbUndoLog.LogStoreDeleted(Store: TIdbObjectStore; Position: Integer);
var
  Entry: Integer;
begin
  Entry := Add(UndoStoreDeleted);
  FEntries[Entry].Store := Store;
  FEntries[Entry].Position := Position;
end;

procedure TIdbUndoLog.LogStoreRenamed(Store: TIdbObjectStore; const OldName: RawByteString);
var
  Entry: Integer;
begin
  Entry := Add(UndoStoreRenamed);
  FEntries[Entry].Store := Store;
  FEntries[Entry].Name := OldName;
end;

procedure TIdbUndoLog.LogIndexCreated(Store: TIdbObjectStore; Index: TIdbIndex);
var
  Entry: Integer;
begin
  Entry := Add(UndoIndexCreated);
  FEntries[Entry].Store := Store;
  FEntries[Entry].Index := Index;
end;

procedure TIdbUndoLog.LogIndexDeleted(Store: TIdbObjectStore; Index: TIdbIndex; Position: Integer);
var
  Entry: Integer;
begin
  Entry := Add(UndoIndexDeleted);
  FEntries[Entry].Store := Store;
  FEntries[Entry].Index := Index;
  FEntries[Entry].Position := Position;
end;

procedure TIdbUndoLog.LogIndexRenamed(Index: TIdbIndex; const OldName: RawByteString);
var
  Entry: Integer;
begin
  Entry := Add(UndoIndexRenamed);
  FEntries[Entry].Index := Index;
  FEntries[Entry].Name := OldName;
end;

procedure TIdbUndoLog.LogGenerator(Store: TIdbObjectStore; OldValue: Double);
var
  Entry: Integer;
begin
  Entry := Add(UndoGenerator);
  FEntries[Entry].Store := Store;
  FEntries[Entry].Number := OldValue;
end;

procedure TIdbUndoLog.LogVersion(OldVersion: Int64);
var
  Entry: Integer;
begin
  Entry := Add(UndoVersion);
  FEntries[Entry].Number := OldVersion;
end;

procedure TIdbUndoLog.Undo;
var
  Cursor: Integer;
begin
  { Inside the with, Position is the entry's field. }
  Cursor := FCount - 1;
  while Cursor >= 0 do
  begin
    with FEntries[Cursor] do
      case Kind of
        UndoInserted: List.RawRemove(Key);
        UndoReplaced, UndoDeleted: List.RawPut(Key, Value);
        UndoStoreCreated:
          begin
            FDatabase.DetachStore(Store);
            Store.Free;
          end;
        UndoStoreDeleted: FDatabase.InsertStore(Position, Store);
        UndoStoreRenamed: Store.Name := Name;
        UndoIndexCreated:
          begin
            Store.DetachIndex(Index);
            Index.Free;
          end;
        UndoIndexDeleted:
          begin
            Store.InsertIndex(Position, Index);
            FDatabase.AttachList(Index.Entries);
            FDatabase.AttachList(Index.Reverse);
          end;
        UndoIndexRenamed: Index.Name := Name;
        UndoGenerator: Store.Generator := Number;
        UndoVersion: FDatabase.Version := Trunc(Number);
      end;
    FEntries[Cursor] := Default(TIdbUndoEntry);
    Dec(Cursor);
  end;
  FCount := 0;
end;

end.
