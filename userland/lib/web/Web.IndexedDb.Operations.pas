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
  The record operations of IndexedDB's object stores and indexes
  (Indexed Database API 3.0, 5 "Database operations"): storing a record
  with its index entries (5.1), deleting and clearing (5.6, 5.7),
  retrieving values, keys and counts from a store or an index (5.2-5.5),
  and iterating a cursor (6.1 "iterate a cursor"), each reading its
  arguments from a request and writing its answer to the reply.

  Positions are byte searches over the sorted lists (see
  Web.IndexedDb.Keys for why "above K" is "at or above the successor of
  K"). For an index the entries' keys are the index key followed by the
  primary key, so "the next entry after this cursor's position" is the
  next composite key, and "the next index key" skips every entry that
  begins with the current one.
}
unit Web.IndexedDb.Operations;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.IndexedDb.Keys,
  Web.IndexedDb.Entries,
  Web.IndexedDb.Database,
  Web.IndexedDb.Wire;

const
  CursorNext = 0;
  CursorNextUnique = 1;
  CursorPrevious = 2;
  CursorPreviousUnique = 3;

  { The largest key the key generator makes (2^53). }
  GeneratorLimit = 9007199254740992.0;

function ReadKeyRange(Reader: TIdbReader): TIdbKeyRange;
{ Available: the bytes the origin may still store. }
procedure StoreRecord(Store: TIdbObjectStore; Reader: TIdbReader; Log: TIdbUndoLog; Available: Int64);
procedure DeleteRecords(Store: TIdbObjectStore; constref Range: TIdbKeyRange);
procedure GenerateKey(Store: TIdbObjectStore; Writer: TIdbWriter; Log: TIdbUndoLog);
{ Index nil: the store itself. }
procedure RetrieveFirst(Store: TIdbObjectStore; Index: TIdbIndex; Reader: TIdbReader; Writer: TIdbWriter);
procedure RetrieveAll(Store: TIdbObjectStore; Index: TIdbIndex; Reader: TIdbReader; Writer: TIdbWriter);
procedure CountRecords(Store: TIdbObjectStore; Index: TIdbIndex; Reader: TIdbReader; Writer: TIdbWriter);
procedure IterateCursor(Store: TIdbObjectStore; Index: TIdbIndex; Reader: TIdbReader; Writer: TIdbWriter);
{ The entries of a new index over the records already stored. }
procedure PopulateIndex(Index: TIdbIndex; Reader: TIdbReader);

implementation

const
  PutNoOverwrite = 1;

function ReadKeyRange(Reader: TIdbReader): TIdbKeyRange;
var
  Flags: Byte;
begin
  Result := UnboundedRange;
  Flags := Reader.ReadByte;
  Result.HasLower := (Flags and 1) <> 0;
  Result.HasUpper := (Flags and 2) <> 0;
  Result.LowerOpen := (Flags and 4) <> 0;
  Result.UpperOpen := (Flags and 8) <> 0;
  if Result.HasLower then
    Result.Lower := Reader.ReadBytes;
  if Result.HasUpper then
    Result.Upper := Reader.ReadBytes;
end;

function SameBytes(const A, B: TBytes): Boolean;
begin
  Result := CompareKeyBytes(A, B) = 0;
end;

{ The index key of an entry (its key without the primary key). }
function EntryIndexKey(Entries: TIdbEntryList; Position: Integer): TBytes;
begin
  Result := Copy(Entries.Keys[Position], 0, Length(Entries.Keys[Position]) - Length(Entries.Values[Position]));
end;

procedure RemoveIndexEntries(Store: TIdbObjectStore; const PrimaryKey: TBytes);
var
  IndexPosition, First, Past, Position: Integer;
  Index: TIdbIndex;
  IndexKey: TBytes;
begin
  for IndexPosition := 0 to Store.IndexCount - 1 do
  begin
    Index := Store.Indexes[IndexPosition];
    Index.Reverse.PrefixBounds(PrimaryKey, First, Past);
    Position := Past - 1;
    while Position >= First do
    begin
      IndexKey := Copy(Index.Reverse.Keys[Position], Length(PrimaryKey), MaxInt);
      Index.Entries.Remove(ConcatKeys(IndexKey, PrimaryKey));
      Index.Reverse.Delete(Position);
      Dec(Position);
    end;
  end;
end;

procedure AddIndexEntry(Index: TIdbIndex; const IndexKey, PrimaryKey: TBytes);
begin
  Index.Entries.Put(ConcatKeys(IndexKey, PrimaryKey), PrimaryKey);
  Index.Reverse.Put(ConcatKeys(PrimaryKey, IndexKey), nil);
end;

{ Whether a unique index has IndexKey for another record than PrimaryKey. }
function UniqueKeyTaken(Index: TIdbIndex; const IndexKey, PrimaryKey: TBytes): Boolean;
var
  First, Past, Position: Integer;
begin
  Result := False;
  if not Index.Unique then
    Exit;
  Index.Entries.PrefixBounds(IndexKey, First, Past);
  for Position := First to Past - 1 do
    if not SameBytes(Index.Entries.Values[Position], PrimaryKey) then
      Exit(True);
end;

procedure BumpGenerator(Store: TIdbObjectStore; const Key: TBytes; Log: TIdbUndoLog);
var
  Value: Double;
begin
  if not Store.AutoIncrement or not KeyNumberValue(Key, Value) then
    Exit;
  if Value > GeneratorLimit then
    Value := GeneratorLimit;
  { Only a value at or above the current number (at least 1) counts, so
    truncating is flooring here. }
  Value := Int(Value);
  if Value >= Store.Generator then
  begin
    Log.LogGenerator(Store, Store.Generator);
    Store.Generator := Value + 1;
  end;
end;

type
  TIndexKeys = record
    Index: TIdbIndex;
    Keys: array of TBytes;
  end;

procedure StoreRecord(Store: TIdbObjectStore; Reader: TIdbReader; Log: TIdbUndoLog; Available: Int64);
var
  Flags: Byte;
  Key, Value: TBytes;
  IndexKeys: array of TIndexKeys;
  IndexCount, KeyCount, Item, KeyItem: LongWord;
  Position, IndexItem, KeyPosition: Integer;
  Exists: Boolean;
  Added: Int64;
begin
  Flags := Reader.ReadByte;
  Key := Reader.ReadBytes;
  Value := Reader.ReadBytes;
  IndexCount := Reader.ReadLongWord;
  IndexKeys := nil;
  if IndexCount > LongWord(Store.IndexCount) then
    raise EIdbMalformed.Create('more indexes than the store has');
  SetLength(IndexKeys, IndexCount);
  Added := Length(Key) + Length(Value);
  Item := 0;
  while Item < IndexCount do
  begin
    IndexKeys[Item].Index := Store.FindIndex(Reader.ReadLongWord);
    if IndexKeys[Item].Index = nil then
      raise EIdbFailure.CreateStatus(IdbStatusNotFound, 'The index was not found.');
    KeyCount := Reader.ReadLongWord;
    if KeyCount > 1000000 then
      raise EIdbMalformed.Create('too many index keys');
    SetLength(IndexKeys[Item].Keys, KeyCount);
    KeyItem := 0;
    while KeyItem < KeyCount do
    begin
      IndexKeys[Item].Keys[KeyItem] := Reader.ReadBytes;
      Added := Added + 2 * (Length(IndexKeys[Item].Keys[KeyItem]) + Length(Key));
      Inc(KeyItem);
    end;
    Inc(Item);
  end;
  if Length(Key) = 0 then
    raise EIdbFailure.CreateStatus(IdbStatusData, 'The record has no key.');
  Exists := Store.Records.Find(Key, Position);
  if Exists and ((Flags and PutNoOverwrite) <> 0) then
    raise EIdbFailure.CreateStatus(IdbStatusConstraint, 'A record with the key already exists in the object store.');
  if Exists then
    Added := Added - Length(Key) - Length(Store.Records.Values[Position]);
  if Added > Available then
    raise EIdbFailure.CreateStatus(IdbStatusQuotaExceeded, 'The origin''s storage quota would be exceeded.');
  { Signed positions: High of an empty array is -1. }
  for IndexItem := 0 to High(IndexKeys) do
    for KeyPosition := 0 to High(IndexKeys[IndexItem].Keys) do
      if UniqueKeyTaken(IndexKeys[IndexItem].Index, IndexKeys[IndexItem].Keys[KeyPosition], Key) then
        raise EIdbFailure.CreateStatus(IdbStatusConstraint, 'A record with the index key already exists in a ' +
          'unique index.');
  if Exists then
    RemoveIndexEntries(Store, Key);
  Store.Records.Put(Key, Value);
  for IndexItem := 0 to High(IndexKeys) do
    for KeyPosition := 0 to High(IndexKeys[IndexItem].Keys) do
      AddIndexEntry(IndexKeys[IndexItem].Index, IndexKeys[IndexItem].Keys[KeyPosition], Key);
  BumpGenerator(Store, Key, Log);
end;

procedure DeleteRecords(Store: TIdbObjectStore; constref Range: TIdbKeyRange);
var
  First, Past, Position: Integer;
begin
  Store.Records.RangeBounds(Range, First, Past);
  Position := Past - 1;
  while Position >= First do
  begin
    RemoveIndexEntries(Store, Store.Records.Keys[Position]);
    Store.Records.Delete(Position);
    Dec(Position);
  end;
end;

procedure GenerateKey(Store: TIdbObjectStore; Writer: TIdbWriter; Log: TIdbUndoLog);
begin
  if not Store.AutoIncrement then
    raise EIdbFailure.CreateStatus(IdbStatusData, 'The object store has no key generator.');
  if Store.Generator > GeneratorLimit then
    raise EIdbFailure.CreateStatus(IdbStatusConstraint, 'The key generator has reached its maximum.');
  Writer.WriteDouble(Store.Generator);
  Log.LogGenerator(Store, Store.Generator);
  Store.Generator := Store.Generator + 1;
end;

{ ---- reading through a source (a store or an index) ---- }

function SourceList(Store: TIdbObjectStore; Index: TIdbIndex): TIdbEntryList;
begin
  if Index = nil then
    Result := Store.Records
  else
    Result := Index.Entries;
end;

{ The key, primary key and (when WithValue) value at Position. }
procedure WriteItem(Store: TIdbObjectStore; Index: TIdbIndex; Position: Integer; WithKey, WithPrimaryKey,
  WithValue: Boolean; Writer: TIdbWriter);
var
  PrimaryKey: TBytes;
  RecordPosition: Integer;
begin
  if Index = nil then
  begin
    if WithKey then
      Writer.WriteBytes(Store.Records.Keys[Position]);
    if WithPrimaryKey then
      Writer.WriteBytes(Store.Records.Keys[Position]);
    if WithValue then
      Writer.WriteBytes(Store.Records.Values[Position]);
    Exit;
  end;
  PrimaryKey := Index.Entries.Values[Position];
  if WithKey then
    Writer.WriteBytes(EntryIndexKey(Index.Entries, Position));
  if WithPrimaryKey then
    Writer.WriteBytes(PrimaryKey);
  if WithValue then
  begin
    if Store.Records.Find(PrimaryKey, RecordPosition) then
      Writer.WriteBytes(Store.Records.Values[RecordPosition])
    else
      Writer.WriteBytes(nil);
  end;
end;

procedure RetrieveFirst(Store: TIdbObjectStore; Index: TIdbIndex; Reader: TIdbReader; Writer: TIdbWriter);
var
  Range: TIdbKeyRange;
  WithValue: Boolean;
  First, Past: Integer;
begin
  Range := ReadKeyRange(Reader);
  WithValue := Reader.ReadByte = 0;
  SourceList(Store, Index).RangeBounds(Range, First, Past);
  Writer.WriteBoolean(First < Past);
  if First < Past then
    WriteItem(Store, Index, First, True, True, WithValue, Writer);
end;

procedure RetrieveAll(Store: TIdbObjectStore; Index: TIdbIndex; Reader: TIdbReader; Writer: TIdbWriter);
const
  AllValues = 0;
  AllPrimaryKeys = 1;
  AllEntries = 2;
var
  Range: TIdbKeyRange;
  Limit: LongWord;
  What: Byte;
  First, Past, Position: Integer;
begin
  Range := ReadKeyRange(Reader);
  Limit := Reader.ReadLongWord;
  What := Reader.ReadByte;
  SourceList(Store, Index).RangeBounds(Range, First, Past);
  if (Limit > 0) and (Int64(Past) - First > Limit) then
    Past := First + Integer(Limit);
  Writer.WriteLongWord(Past - First);
  for Position := First to Past - 1 do
    case What of
      AllValues: WriteItem(Store, Index, Position, False, False, True, Writer);
      AllPrimaryKeys: WriteItem(Store, Index, Position, False, True, False, Writer);
      AllEntries: WriteItem(Store, Index, Position, True, True, True, Writer);
    else
      raise EIdbMalformed.Create('unknown retrieval');
    end;
end;

procedure CountRecords(Store: TIdbObjectStore; Index: TIdbIndex; Reader: TIdbReader; Writer: TIdbWriter);
var
  Range: TIdbKeyRange;
  First, Past: Integer;
begin
  Range := ReadKeyRange(Reader);
  SourceList(Store, Index).RangeBounds(Range, First, Past);
  Writer.WriteDouble(Past - First);
end;

{ The first position at or above Bound's successor (Count if none). }
function AboveAll(List: TIdbEntryList; const Bound: TBytes): Integer;
var
  Successor: TBytes;
begin
  if PrefixSuccessor(Bound, Successor) then
    Result := List.LowerBound(Successor)
  else
    Result := List.Count;
end;

function MaxOf(A, B: Integer): Integer;
begin
  if A > B then
    Result := A
  else
    Result := B;
end;

function MinOf(A, B: Integer): Integer;
begin
  if A < B then
    Result := A
  else
    Result := B;
end;

procedure IterateCursor(Store: TIdbObjectStore; Index: TIdbIndex; Reader: TIdbReader; Writer: TIdbWriter);
var
  Range: TIdbKeyRange;
  Direction: Byte;
  HasPosition, HasTarget, HasTargetPrimary, WithValue: Boolean;
  PositionKey, PositionPrimary, TargetKey, TargetPrimary: TBytes;
  PositionComposite, TargetComposite: TBytes;
  Steps: LongWord;
  List: TIdbEntryList;
  First, Past, Candidate: Integer;
  Forward, Unique: Boolean;
begin
  Range := ReadKeyRange(Reader);
  Direction := Reader.ReadByte;
  HasPosition := Reader.ReadBoolean;
  PositionKey := Reader.ReadBytes;
  PositionPrimary := Reader.ReadBytes;
  HasTarget := Reader.ReadBoolean;
  TargetKey := Reader.ReadBytes;
  HasTargetPrimary := Reader.ReadBoolean;
  TargetPrimary := Reader.ReadBytes;
  Steps := Reader.ReadLongWord;
  WithValue := Reader.ReadBoolean;
  if Direction > CursorPreviousUnique then
    raise EIdbMalformed.Create('unknown cursor direction');
  if Steps = 0 then
    Steps := 1;
  List := SourceList(Store, Index);
  List.RangeBounds(Range, First, Past);
  Forward := Direction <= CursorNextUnique;
  { A store's keys are unique: its unique directions are the others. }
  Unique := (Index <> nil) and ((Direction = CursorNextUnique) or (Direction = CursorPreviousUnique));
  if Index = nil then
    TargetComposite := TargetKey
  else if HasTargetPrimary then
    TargetComposite := ConcatKeys(TargetKey, TargetPrimary);
  Candidate := -1;
  while Steps > 0 do
  begin
    if Index = nil then
      PositionComposite := PositionKey
    else
      PositionComposite := ConcatKeys(PositionKey, PositionPrimary);
    if Forward then
    begin
      Candidate := First;
      if HasPosition then
      begin
        if Unique then
          Candidate := MaxOf(Candidate, AboveAll(List, PositionKey))
        else
          Candidate := MaxOf(Candidate, AboveAll(List, PositionComposite));
      end;
      if HasTarget then
      begin
        if HasTargetPrimary and (Index <> nil) then
          Candidate := MaxOf(Candidate, List.LowerBound(TargetComposite))
        else
          Candidate := MaxOf(Candidate, List.LowerBound(TargetKey));
      end;
      if Candidate >= Past then
        Candidate := -1;
    end
    else
    begin
      Candidate := Past - 1;
      if HasPosition then
      begin
        if Unique then
          Candidate := MinOf(Candidate, List.LowerBound(PositionKey) - 1)
        else
          Candidate := MinOf(Candidate, List.LowerBound(PositionComposite) - 1);
      end;
      if HasTarget then
      begin
        if HasTargetPrimary and (Index <> nil) then
          Candidate := MinOf(Candidate, AboveAll(List, TargetComposite) - 1)
        else
          Candidate := MinOf(Candidate, AboveAll(List, TargetKey) - 1);
      end;
      if Candidate < First then
        Candidate := -1;
      if (Candidate >= 0) and Unique then
        { The first entry of that index key (still within the range). }
        Candidate := MaxOf(First, List.LowerBound(EntryIndexKey(List, Candidate)));
    end;
    if Candidate < 0 then
      Break;
    HasPosition := True;
    if Index = nil then
    begin
      PositionKey := List.Keys[Candidate];
      PositionPrimary := PositionKey;
    end
    else
    begin
      PositionKey := EntryIndexKey(List, Candidate);
      PositionPrimary := List.Values[Candidate];
    end;
    Dec(Steps);
  end;
  Writer.WriteBoolean(Candidate >= 0);
  if Candidate >= 0 then
    WriteItem(Store, Index, Candidate, True, True, WithValue, Writer);
end;

procedure PopulateIndex(Index: TIdbIndex; Reader: TIdbReader);
var
  Count, Item, KeyCount, KeyItem: LongWord;
  PrimaryKey, IndexKey: TBytes;
begin
  Count := Reader.ReadLongWord;
  Item := 0;
  while Item < Count do
  begin
    PrimaryKey := Reader.ReadBytes;
    KeyCount := Reader.ReadLongWord;
    KeyItem := 0;
    while KeyItem < KeyCount do
    begin
      IndexKey := Reader.ReadBytes;
      if UniqueKeyTaken(Index, IndexKey, PrimaryKey) then
        raise EIdbFailure.CreateStatus(IdbStatusConstraint, 'Unable to add a unique index: records share an index ' +
          'key.');
      AddIndexEntry(Index, IndexKey, PrimaryKey);
      Inc(KeyItem);
    end;
    Inc(Item);
  end;
end;

end.
