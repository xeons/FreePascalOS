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
  The atom table: interned strings, the keys of named properties.

  Interning a string finds the atom with the same characters, or makes
  the string (or a flat copy of it) that atom; equal keys are then one
  cell and compare by pointer. The table is open addressing over the
  strings' hashes and is weak: atoms nobody marks are forgotten at each
  collection (the weak processor), except the predefined atoms below,
  which the engine itself uses and which live as long as the table.
}
unit Js.Atoms;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Values,
  Js.Heap,
  Js.Strings;

type
  TJsAtomName = (
    anEmpty, anLength, anPrototype, anConstructor, anName, anMessage, anStack,
    anToString, anValueOf, anValue, anDone, anNext, anGet, anSet, anWritable,
    anEnumerable, anConfigurable, anCallee, anCaller, anArguments, anThen,
    anIndex, anInput, anGroups, anLastIndex, anSource, anFlags, anUndefined,
    anNull, anTrue, anFalse, anObject, anFunction, anString, anNumber,
    anBoolean, anSymbol, anBigInt, anDefault, anNaN, anInfinity,
    anNegativeInfinity, anToJSON, anCause, anErrors, anRaw, anReturn, anThrow,
    anJoin, anAnonymous, anGlobalThis, anEval, anToLocaleString, anIndices,
    anStatus, anReason, anFulfilled, anRejected, anAsync, anKey, anConstructorName,
    anAdd, anHas, anDeleteName, anSize, anGlobal, anIgnoreCase, anMultiline,
    anSticky, anUnicode, anDotAll, anHasIndices, anUnicodeSets, anExec, anLast);

const
  AtomNameTexts: array[TJsAtomName] of string = (
    '', 'length', 'prototype', 'constructor', 'name', 'message', 'stack',
    'toString', 'valueOf', 'value', 'done', 'next', 'get', 'set', 'writable',
    'enumerable', 'configurable', 'callee', 'caller', 'arguments', 'then',
    'index', 'input', 'groups', 'lastIndex', 'source', 'flags', 'undefined',
    'null', 'true', 'false', 'object', 'function', 'string', 'number',
    'boolean', 'symbol', 'bigint', 'default', 'NaN', 'Infinity',
    '-Infinity', 'toJSON', 'cause', 'errors', 'raw', 'return', 'throw',
    'join', 'anonymous', 'globalThis', 'eval', 'toLocaleString', 'indices',
    'status', 'reason', 'fulfilled', 'rejected', 'async', 'key', '<constructor>',
    'add', 'has', 'delete', 'size', 'global', 'ignoreCase', 'multiline',
    'sticky', 'unicode', 'dotAll', 'hasIndices', 'unicodeSets', 'exec', '<last>');

type
  TJsAtomTable = class
  private
    FHeap: TJsHeap;
    FSlots: array of TJsString;
    FCount: Integer;
    FMask: Integer;
    FNames: array[TJsAtomName] of TJsString;
    procedure Grow;
    procedure InsertSlot(Atom: TJsString);
    function FindUnits8(Characters: PByte; Count: Integer; Hash: LongWord): TJsString;
    function FindUnits16(Units: PWord; Count: Integer; Hash: LongWord): TJsString;
    function ProcessWeak(Tracer: TJsTracer; Phase: Integer): Boolean;
    procedure MarkNames(Tracer: TJsTracer);
  public
    constructor Create(Heap: TJsHeap);
    { The atom with the characters of Text (perhaps Text itself). }
    function Intern(Text: TJsString): TJsString;
    function InternUtf8(const Text: string): TJsString;
    function InternLatin1(Characters: PByte; Count: Integer): TJsString;
    function Name(Atom: TJsAtomName): TJsString; inline;
    property Count: Integer read FCount;
  end;

implementation

constructor TJsAtomTable.Create(Heap: TJsHeap);
var
  Atom: TJsAtomName;
begin
  inherited Create;
  FHeap := Heap;
  SetLength(FSlots, 1024);
  FMask := 1023;
  Heap.AddWeakProcessor(@ProcessWeak);
  Heap.AddRootProvider(@MarkNames);
  for Atom := Low(TJsAtomName) to High(TJsAtomName) do
    FNames[Atom] := InternUtf8(AtomNameTexts[Atom]);
end;

function TJsAtomTable.Name(Atom: TJsAtomName): TJsString;
begin
  Result := FNames[Atom];
end;

procedure TJsAtomTable.MarkNames(Tracer: TJsTracer);
var
  Atom: TJsAtomName;
begin
  for Atom := Low(TJsAtomName) to High(TJsAtomName) do
    Tracer.MarkCell(FNames[Atom]);
end;

procedure TJsAtomTable.InsertSlot(Atom: TJsString);
var
  Slot: Integer;
begin
  Slot := Integer(Atom.Hash and LongWord(FMask));
  while FSlots[Slot] <> nil do
    Slot := (Slot + 1) and FMask;
  FSlots[Slot] := Atom;
end;

procedure TJsAtomTable.Grow;
var
  Old: array of TJsString;
  Index: Integer;
begin
  Old := FSlots;
  FSlots := nil;
  SetLength(FSlots, Length(Old) * 2);
  FMask := Length(FSlots) - 1;
  for Index := 0 to High(Old) do
    if Old[Index] <> nil then
      InsertSlot(Old[Index]);
end;

function TJsAtomTable.FindUnits8(Characters: PByte; Count: Integer; Hash: LongWord): TJsString;
var
  Slot, Index: Integer;
  Candidate: TJsString;
  Same: Boolean;
begin
  Slot := Integer(Hash and LongWord(FMask));
  while True do
  begin
    Candidate := FSlots[Slot];
    if Candidate = nil then
      Exit(nil);
    if (Candidate.Hash = Hash) and (Candidate.Length = Count) then
    begin
      if not Candidate.IsWide then
        Same := (Count = 0) or (CompareByte(Candidate.Chars8^, Characters^, Count) = 0)
      else
      begin
        Same := True;
        for Index := 0 to Count - 1 do
          if Candidate.Chars16[Index] <> Characters[Index] then
          begin
            Same := False;
            Break;
          end;
      end;
      if Same then
        Exit(Candidate);
    end;
    Slot := (Slot + 1) and FMask;
  end;
end;

function TJsAtomTable.FindUnits16(Units: PWord; Count: Integer; Hash: LongWord): TJsString;
var
  Slot, Index: Integer;
  Candidate: TJsString;
  Same: Boolean;
begin
  Slot := Integer(Hash and LongWord(FMask));
  while True do
  begin
    Candidate := FSlots[Slot];
    if Candidate = nil then
      Exit(nil);
    if (Candidate.Hash = Hash) and (Candidate.Length = Count) then
    begin
      Same := True;
      for Index := 0 to Count - 1 do
        if Candidate.CharAt(Index) <> Units[Index] then
        begin
          Same := False;
          Break;
        end;
      if Same then
        Exit(Candidate);
    end;
    Slot := (Slot + 1) and FMask;
  end;
end;

function TJsAtomTable.Intern(Text: TJsString): TJsString;
begin
  if Text.IsAtom then
    Exit(Text);
  Text.Flatten(FHeap);
  if Text.IsWide then
    Result := FindUnits16(Text.Chars16, Text.Length, Text.Hash)
  else
    Result := FindUnits8(Text.Chars8, Text.Length, Text.Hash);
  if Result <> nil then
    Exit;
  if (FCount + 1) * 2 > Length(FSlots) then
    Grow;
  Text.MarkAtom;
  InsertSlot(Text);
  Inc(FCount);
  Result := Text;
end;

function TJsAtomTable.InternLatin1(Characters: PByte; Count: Integer): TJsString;
begin
  Result := FindUnits8(Characters, Count, HashUnits8(Characters, Count));
  if Result = nil then
    Result := Intern(NewLatin1String(FHeap, Characters, Count));
end;

function TJsAtomTable.InternUtf8(const Text: string): TJsString;
var
  Index: Integer;
begin
  for Index := 1 to Length(Text) do
    if Byte(Text[Index]) >= $80 then
      Exit(Intern(NewStringFromUtf8(FHeap, Text)));
  if Text = '' then
    Result := InternLatin1(nil, 0)
  else
    Result := InternLatin1(PByte(@Text[1]), Length(Text));
end;

function TJsAtomTable.ProcessWeak(Tracer: TJsTracer; Phase: Integer): Boolean;
var
  Old: array of TJsString;
  Index: Integer;
begin
  Result := False;
  if Phase <> 1 then
    Exit;
  Old := FSlots;
  FSlots := nil;
  SetLength(FSlots, Length(Old));
  FCount := 0;
  for Index := 0 to High(Old) do
    if (Old[Index] <> nil) and Old[Index].Marked then
    begin
      InsertSlot(Old[Index]);
      Inc(FCount);
    end;
end;

end.
