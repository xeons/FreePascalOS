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
  The compiled programs of recent regular expressions, by pattern and
  flags: a literal evaluated in a loop, or new RegExp(sameText), shares
  one program instead of compiling again (a program is immutable; each
  regexp keeps a matcher of its own).

  A fixed table indexed by the pattern's hash and the flags; a newer
  entry replaces the one in its slot. The table holds a reference to
  each program it keeps.
}
unit Js.RegExpCache;

{$mode objfpc}{$H+}

interface

uses
  Js.Strings,
  Js.RegExpCompiler;

type
  TRxProgramCache = class
  private type
    TSlot = record
      Hash: LongWord;
      Flags: Integer;
      Pattern: UnicodeString;
      Compiled: TRxProgram;
    end;
  private
    FSlots: array of TSlot;
    function SlotOf(Hash: LongWord; Flags: Integer): Integer;
  public
    constructor Create;
    destructor Destroy; override;
    { The program compiled from the (flat) pattern with these flags,
      with a reference added for the caller; nil when not kept. }
    function Lookup(Pattern: TJsString; Flags: Integer): TRxProgram;
    { Keeps Compiled (the cache adds its own reference). }
    procedure Insert(Pattern: TJsString; const PatternText: UnicodeString; Flags: Integer; Compiled: TRxProgram);
  end;

implementation

const
  SlotCount = 256;
  { Longer patterns are compiled each time (rarely repeated). }
  LongestCachedPattern = 4096;

constructor TRxProgramCache.Create;
begin
  inherited Create;
  SetLength(FSlots, SlotCount);
end;

destructor TRxProgramCache.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(FSlots) do
    FSlots[Index].Compiled.Release;
  inherited Destroy;
end;

function TRxProgramCache.SlotOf(Hash: LongWord; Flags: Integer): Integer;
begin
  Result := Integer((Hash xor (LongWord(Flags) * 2654435761)) and (SlotCount - 1));
end;

function SamePattern(Pattern: TJsString; const Text: UnicodeString): Boolean;
var
  Index: Integer;
begin
  if Pattern.Length <> Length(Text) then
    Exit(False);
  for Index := 0 to Pattern.Length - 1 do
    if Pattern.CharAt(Index) <> Ord(Text[Index + 1]) then
      Exit(False);
  Result := True;
end;

function TRxProgramCache.Lookup(Pattern: TJsString; Flags: Integer): TRxProgram;
var
  Hash: LongWord;
  Slot: Integer;
begin
  Result := nil;
  if Pattern.Length > LongestCachedPattern then
    Exit;
  Hash := Pattern.Hash;
  Slot := SlotOf(Hash, Flags);
  if (FSlots[Slot].Compiled <> nil) and (FSlots[Slot].Hash = Hash) and (FSlots[Slot].Flags = Flags) and
    SamePattern(Pattern, FSlots[Slot].Pattern) then
  begin
    Result := FSlots[Slot].Compiled;
    Result.AddReference;
  end;
end;

procedure TRxProgramCache.Insert(Pattern: TJsString; const PatternText: UnicodeString; Flags: Integer;
  Compiled: TRxProgram);
var
  Slot: Integer;
begin
  if Pattern.Length > LongestCachedPattern then
    Exit;
  Slot := SlotOf(Pattern.Hash, Flags);
  Compiled.AddReference;
  FSlots[Slot].Compiled.Release;
  FSlots[Slot].Hash := Pattern.Hash;
  FSlots[Slot].Flags := Flags;
  FSlots[Slot].Pattern := PatternText;
  FSlots[Slot].Compiled := Compiled;
end;

end.
