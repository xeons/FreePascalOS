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
  A sorted list of key and value byte strings: an object store's
  records (primary key, serialized value) or an index's entries (index
  key followed by primary key, primary key). Keys are unique and kept
  in byte order (Web.IndexedDb.Keys) in one array, found by binary
  search; inserting moves the tail, which is fast enough for the tens
  of thousands of records pages keep.

  Every change can be told to an undo log (TIdbEntryObserver), so a
  transaction that aborts puts the list back as it was.
}
unit Web.IndexedDb.Entries;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.IndexedDb.Keys;

type
  TIdbEntry = record
    Key: TBytes;
    Value: TBytes;
  end;

  TIdbEntryList = class;

  { Hears each change before it is made (the transaction's undo log). }
  TIdbEntryObserver = class
  public
    procedure EntryInserted(List: TIdbEntryList; const Key: TBytes); virtual; abstract;
    procedure EntryReplaced(List: TIdbEntryList; const Key, OldValue: TBytes); virtual; abstract;
    procedure EntryDeleted(List: TIdbEntryList; const Key, OldValue: TBytes); virtual; abstract;
  end;

  TIdbEntryList = class
  private
    FItems: array of TIdbEntry;
    FCount: Integer;
    FBytes: Int64;
    function GetKey(Index: Integer): TBytes;
    function GetValue(Index: Integer): TBytes;
  public
    Observer: TIdbEntryObserver;
    { The first index whose key is at or above Key (Count when none). }
    function LowerBound(const Key: TBytes): Integer;
    { Where Key is: True and its index, or False and where it would go. }
    function Find(const Key: TBytes; out Index: Integer): Boolean;
    { The indexes [First, Past) of the keys in Range. }
    procedure RangeBounds(constref Range: TIdbKeyRange; out First, Past: Integer);
    { The indexes [First, Past) of the keys beginning with Prefix. }
    procedure PrefixBounds(const Prefix: TBytes; out First, Past: Integer);
    { Adds or replaces. }
    procedure Put(const Key, Value: TBytes);
    procedure Delete(Index: Integer);
    function Remove(const Key: TBytes): Boolean;
    { Without telling the observer (loading, undoing). }
    procedure RawPut(const Key, Value: TBytes);
    procedure RawRemove(const Key: TBytes);
    procedure RawAppend(const Key, Value: TBytes);
    property Count: Integer read FCount;
    property Keys[Index: Integer]: TBytes read GetKey;
    property Values[Index: Integer]: TBytes read GetValue;
    { Of all keys and values. }
    property Bytes: Int64 read FBytes;
  end;

implementation

function TIdbEntryList.GetKey(Index: Integer): TBytes;
begin
  Result := FItems[Index].Key;
end;

function TIdbEntryList.GetValue(Index: Integer): TBytes;
begin
  Result := FItems[Index].Value;
end;

function TIdbEntryList.LowerBound(const Key: TBytes): Integer;
var
  Low, High, Middle: Integer;
begin
  Low := 0;
  High := FCount;
  while Low < High do
  begin
    Middle := (Low + High) div 2;
    if CompareKeyBytes(FItems[Middle].Key, Key) < 0 then
      Low := Middle + 1
    else
      High := Middle;
  end;
  Result := Low;
end;

function TIdbEntryList.Find(const Key: TBytes; out Index: Integer): Boolean;
begin
  Index := LowerBound(Key);
  Result := (Index < FCount) and (CompareKeyBytes(FItems[Index].Key, Key) = 0);
end;

procedure TIdbEntryList.RangeBounds(constref Range: TIdbKeyRange; out First, Past: Integer);
var
  Successor: TBytes;
begin
  First := 0;
  Past := FCount;
  if Range.HasLower then
  begin
    if not Range.LowerOpen then
      First := LowerBound(Range.Lower)
    else if PrefixSuccessor(Range.Lower, Successor) then
      First := LowerBound(Successor)
    else
      First := FCount;
  end;
  if Range.HasUpper then
  begin
    if Range.UpperOpen then
      Past := LowerBound(Range.Upper)
    else if PrefixSuccessor(Range.Upper, Successor) then
      Past := LowerBound(Successor);
  end;
  if Past < First then
    Past := First;
end;

procedure TIdbEntryList.PrefixBounds(const Prefix: TBytes; out First, Past: Integer);
var
  Successor: TBytes;
begin
  First := LowerBound(Prefix);
  if PrefixSuccessor(Prefix, Successor) then
    Past := LowerBound(Successor)
  else
    Past := FCount;
end;

procedure TIdbEntryList.RawPut(const Key, Value: TBytes);
var
  Index: Integer;
begin
  if Find(Key, Index) then
  begin
    FBytes := FBytes - Length(FItems[Index].Value) + Length(Value);
    FItems[Index].Value := Value;
    Exit;
  end;
  if FCount = Length(FItems) then
  begin
    if FCount < 16 then
      SetLength(FItems, 16)
    else
      SetLength(FItems, FCount * 2);
  end;
  if Index < FCount then
  begin
    { Move the tail up without copying the managed references. }
    Move(FItems[Index], FItems[Index + 1], (FCount - Index) * SizeOf(TIdbEntry));
    FillChar(FItems[Index], SizeOf(TIdbEntry), 0);
  end;
  FItems[Index].Key := Key;
  FItems[Index].Value := Value;
  Inc(FCount);
  FBytes := FBytes + Length(Key) + Length(Value);
end;

procedure TIdbEntryList.RawAppend(const Key, Value: TBytes);
begin
  if (FCount > 0) and (CompareKeyBytes(FItems[FCount - 1].Key, Key) >= 0) then
  begin
    RawPut(Key, Value);
    Exit;
  end;
  if FCount = Length(FItems) then
  begin
    if FCount < 16 then
      SetLength(FItems, 16)
    else
      SetLength(FItems, FCount * 2);
  end;
  FItems[FCount].Key := Key;
  FItems[FCount].Value := Value;
  Inc(FCount);
  FBytes := FBytes + Length(Key) + Length(Value);
end;

procedure TIdbEntryList.Delete(Index: Integer);
begin
  if Observer <> nil then
    Observer.EntryDeleted(Self, FItems[Index].Key, FItems[Index].Value);
  FBytes := FBytes - Length(FItems[Index].Key) - Length(FItems[Index].Value);
  FItems[Index].Key := nil;
  FItems[Index].Value := nil;
  if Index < FCount - 1 then
  begin
    Move(FItems[Index + 1], FItems[Index], (FCount - Index - 1) * SizeOf(TIdbEntry));
    FillChar(FItems[FCount - 1], SizeOf(TIdbEntry), 0);
  end;
  Dec(FCount);
end;

procedure TIdbEntryList.RawRemove(const Key: TBytes);
var
  Index: Integer;
  Saved: TIdbEntryObserver;
begin
  if not Find(Key, Index) then
    Exit;
  Saved := Observer;
  Observer := nil;
  try
    Delete(Index);
  finally
    Observer := Saved;
  end;
end;

function TIdbEntryList.Remove(const Key: TBytes): Boolean;
var
  Index: Integer;
begin
  Result := Find(Key, Index);
  if Result then
    Delete(Index);
end;

procedure TIdbEntryList.Put(const Key, Value: TBytes);
var
  Index: Integer;
begin
  if Observer <> nil then
  begin
    if Find(Key, Index) then
      Observer.EntryReplaced(Self, Key, FItems[Index].Value)
    else
      Observer.EntryInserted(Self, Key);
  end;
  RawPut(Key, Value);
end;

end.
