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
  QPACK's dynamic table (RFC 9204 section 3.2) as the decoder keeps it:
  entries in insertion order, each with its absolute index (0 for the
  first ever inserted), the newest last; an entry's size is its name and
  value lengths plus 32; inserting beyond the capacity evicts the oldest
  entries first, and an entry larger than the capacity is an error.
  The entries live in a ring that grows to hold as many as fit.
}
unit Qpack.DynamicTable;

{$mode objfpc}
{$H+}
{$modeswitch advancedrecords}

interface

uses
  Qpack.StaticTable;

type
  TQpackDynamicTable = record
    Entries: array of TQpackField;
    { Ring position of the oldest entry, and how many there are. }
    Head: Integer;
    Count: Integer;
    Size: QWord;
    Capacity: QWord;
    MaximumCapacity: QWord;
    { Entries ever inserted (the next absolute index). }
    InsertCount: QWord;
    procedure Initialize(Maximum: QWord);
    { False when Capacity is above the maximum. }
    function SetCapacity(NewCapacity: QWord): Boolean;
    { False when the entry cannot fit at all. }
    function Insert(const Name, Value: string): Boolean;
    { The entry with this absolute index, if it is still there. }
    function Get(AbsoluteIndex: QWord; out Field: TQpackField): Boolean;
  end;

function EntrySize(const Name, Value: string): QWord;

implementation

function EntrySize(const Name, Value: string): QWord;
begin
  Result := QWord(Length(Name)) + QWord(Length(Value)) + 32;
end;

procedure TQpackDynamicTable.Initialize(Maximum: QWord);
begin
  Entries := nil;
  Head := 0;
  Count := 0;
  Size := 0;
  Capacity := 0;
  MaximumCapacity := Maximum;
  InsertCount := 0;
end;

procedure EvictOldest(var Table: TQpackDynamicTable);
var
  Oldest: Integer;
begin
  Oldest := Table.Head;
  Table.Size := Table.Size - EntrySize(Table.Entries[Oldest].Name, Table.Entries[Oldest].Value);
  Table.Entries[Oldest].Name := '';
  Table.Entries[Oldest].Value := '';
  Table.Head := (Table.Head + 1) mod Length(Table.Entries);
  Dec(Table.Count);
end;

function TQpackDynamicTable.SetCapacity(NewCapacity: QWord): Boolean;
begin
  if NewCapacity > MaximumCapacity then
    Exit(False);
  Capacity := NewCapacity;
  while Size > Capacity do
    EvictOldest(Self);
  Result := True;
end;

procedure GrowRing(var Table: TQpackDynamicTable);
var
  Bigger: array of TQpackField;
  Index: Integer;
begin
  Bigger := nil;
  SetLength(Bigger, Length(Table.Entries) * 2 + 8);
  for Index := 0 to Table.Count - 1 do
    Bigger[Index] := Table.Entries[(Table.Head + Index) mod Length(Table.Entries)];
  Table.Entries := Bigger;
  Table.Head := 0;
end;

function TQpackDynamicTable.Insert(const Name, Value: string): Boolean;
var
  Needed: QWord;
  Position: Integer;
begin
  Needed := EntrySize(Name, Value);
  if Needed > Capacity then
    Exit(False);
  while Size + Needed > Capacity do
    EvictOldest(Self);
  if Count >= Length(Entries) then
    GrowRing(Self);
  Position := (Head + Count) mod Length(Entries);
  Entries[Position].Name := Name;
  Entries[Position].Value := Value;
  Inc(Count);
  Size := Size + Needed;
  Inc(InsertCount);
  Result := True;
end;

function TQpackDynamicTable.Get(AbsoluteIndex: QWord; out Field: TQpackField): Boolean;
var
  Oldest: QWord;
begin
  Field := Default(TQpackField);
  Oldest := InsertCount - QWord(Count);
  if (AbsoluteIndex < Oldest) or (AbsoluteIndex >= InsertCount) then
    Exit(False);
  Field := Entries[(Head + Integer(AbsoluteIndex - Oldest)) mod Length(Entries)];
  Result := True;
end;

end.
