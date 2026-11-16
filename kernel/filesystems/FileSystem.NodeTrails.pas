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
  Node trails: the nodes a path resolution passed through, from a
  volume's root directory down to the node it found.

  Watches (FileSystem.Watches) recognize the folder and file they watch
  by node number, not by path text: a path may name a folder through a
  symbolic link, in another letter case (FAT and exFAT ignore case), or
  through one of several hard links, and a folder above it may be
  renamed while it is watched. A change is reported with the trail of
  the folder it happened in, so a watch finds its folder anywhere along
  the trail (a watch on a whole subtree) and takes the names below it
  for the record.

  Entry 0 is the volume's root directory, with an empty name; each
  further entry is the node found by looking a name up in the entry
  before it. Text holds the names joined, each after a '/', so the part
  of Text after entry I's end is the path from entry I down to the last
  entry.

  A trail is large (about 3 KiB); open files keep a compact copy
  (TSavedTrail) of the trail of their own node, since a write to a file
  is reported in the folder the file was opened in.
}
unit FileSystem.NodeTrails;

{$mode objfpc}
{$pointermath on}

interface

const
  { One entry per path component, and one for the root. }
  MaximumTrailDepth = 129;
  MaximumTrailTextBytes = 1024;

type
  PNodeTrail = ^TNodeTrail;
  TNodeTrail = record
    Depth: Integer;
    TextLength: Integer;
    NodeNumbers: array[0..MaximumTrailDepth - 1] of QWord;
    { Where in Text each entry's name ends. }
    NameEnds: array[0..MaximumTrailDepth - 1] of Word;
    Text: array[0..MaximumTrailTextBytes - 1] of Char;
  end;

  { The same entries, in a block of just the size they need. }
  PSavedTrail = ^TSavedTrail;
  TSavedTrail = record
    Depth: Integer;
    TextLength: Integer;
    { Followed by Depth node numbers, Depth name ends and the text. }
  end;

function AllocateTrail: PNodeTrail;
procedure FreeTrail(Trail: PNodeTrail);

{ Starts a trail at a volume's root directory. }
procedure StartTrail(Trail: PNodeTrail; RootNodeNumber: QWord);
{ Adds the node found by looking up Name in the last entry. Returns
  False (leaving the trail as it was) if the trail is full. }
function ExtendTrail(Trail: PNodeTrail; NodeNumber: QWord; Name: PChar): Boolean;
{ Forgets the last entry: the trail of the folder holding it. }
procedure ShortenTrail(Trail: PNodeTrail);

function LastTrailNodeNumber(Trail: PNodeTrail): QWord;
{ Copies the name of the last entry (empty for the root) into Name. }
procedure CopyLastTrailName(Trail: PNodeTrail; Name: PChar; Capacity: PtrUInt);
{ The entry holding NodeNumber, or -1. }
function FindInTrail(Trail: PNodeTrail; NodeNumber: QWord): Integer;
{ Copies the path from entry Index down to the last entry ("sub/dir",
  empty when Index is the last) into Path. }
procedure CopyTrailPathBelow(Trail: PNodeTrail; Index: Integer; Path: PChar; Capacity: PtrUInt);

{ A compact copy of Trail; nil if memory ran out. Free it with
  FreeKernelMemory. }
function SaveTrail(Trail: PNodeTrail): PSavedTrail;
procedure RestoreTrail(Saved: PSavedTrail; Trail: PNodeTrail);

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Memory.KernelHeap;

function AllocateTrail: PNodeTrail;
begin
  Result := PNodeTrail(AllocateKernelMemory(SizeOf(TNodeTrail)));
  if Result <> nil then
  begin
    Result^.Depth := 0;
    Result^.TextLength := 0;
    Result^.Text[0] := #0;
  end;
end;

procedure FreeTrail(Trail: PNodeTrail);
begin
  FreeKernelMemory(Trail);
end;

procedure StartTrail(Trail: PNodeTrail; RootNodeNumber: QWord);
begin
  Trail^.Depth := 1;
  Trail^.TextLength := 0;
  Trail^.Text[0] := #0;
  Trail^.NodeNumbers[0] := RootNodeNumber;
  Trail^.NameEnds[0] := 0;
end;

function ExtendTrail(Trail: PNodeTrail; NodeNumber: QWord; Name: PChar): Boolean;
var
  NameLength: Integer;
begin
  NameLength := Integer(TextLength(Name));
  if (Trail^.Depth >= MaximumTrailDepth) or
     (Trail^.TextLength + 1 + NameLength >= MaximumTrailTextBytes) then
    Exit(False);
  Trail^.Text[Trail^.TextLength] := '/';
  CopyMemory(@Trail^.Text[Trail^.TextLength + 1], Name, NameLength);
  Trail^.TextLength := Trail^.TextLength + 1 + NameLength;
  Trail^.Text[Trail^.TextLength] := #0;
  Trail^.NodeNumbers[Trail^.Depth] := NodeNumber;
  Trail^.NameEnds[Trail^.Depth] := Word(Trail^.TextLength);
  Inc(Trail^.Depth);
  Result := True;
end;

procedure ShortenTrail(Trail: PNodeTrail);
begin
  if Trail^.Depth <= 1 then
    Exit;
  Dec(Trail^.Depth);
  Trail^.TextLength := Trail^.NameEnds[Trail^.Depth - 1];
  Trail^.Text[Trail^.TextLength] := #0;
end;

function LastTrailNodeNumber(Trail: PNodeTrail): QWord;
begin
  Result := Trail^.NodeNumbers[Trail^.Depth - 1];
end;

procedure CopyLastTrailName(Trail: PNodeTrail; Name: PChar; Capacity: PtrUInt);
var
  NameStart: Integer;
begin
  if Trail^.Depth <= 1 then
  begin
    Name[0] := #0;
    Exit;
  end;
  { The name starts after the '/' that ends the entry before it. }
  NameStart := Trail^.NameEnds[Trail^.Depth - 2] + 1;
  CopyText(Name, @Trail^.Text[NameStart], Capacity);
end;

function FindInTrail(Trail: PNodeTrail; NodeNumber: QWord): Integer;
var
  Index: Integer;
begin
  for Index := 0 to Trail^.Depth - 1 do
    if Trail^.NodeNumbers[Index] = NodeNumber then
      Exit(Index);
  Result := -1;
end;

procedure CopyTrailPathBelow(Trail: PNodeTrail; Index: Integer; Path: PChar; Capacity: PtrUInt);
var
  Start: Integer;
begin
  Start := Trail^.NameEnds[Index];
  { Skip the '/' in front of the first name below. }
  if Start < Trail^.TextLength then
    Inc(Start);
  CopyText(Path, @Trail^.Text[Start], Capacity);
end;

function SavedNodeNumbers(Saved: PSavedTrail): PQWord;
begin
  Result := PQWord(PByte(Saved) + SizeOf(TSavedTrail));
end;

function SavedNameEnds(Saved: PSavedTrail): PWord;
begin
  Result := PWord(PByte(SavedNodeNumbers(Saved)) + Saved^.Depth * SizeOf(QWord));
end;

function SavedText(Saved: PSavedTrail): PChar;
begin
  Result := PChar(PByte(SavedNameEnds(Saved)) + Saved^.Depth * SizeOf(Word));
end;

function SaveTrail(Trail: PNodeTrail): PSavedTrail;
var
  Size: PtrUInt;
begin
  Size := SizeOf(TSavedTrail) + PtrUInt(Trail^.Depth) * (SizeOf(QWord) + SizeOf(Word)) +
    PtrUInt(Trail^.TextLength) + 1;
  Result := PSavedTrail(AllocateKernelMemory(Size));
  if Result = nil then
    Exit;
  Result^.Depth := Trail^.Depth;
  Result^.TextLength := Trail^.TextLength;
  CopyMemory(SavedNodeNumbers(Result), @Trail^.NodeNumbers[0], Trail^.Depth * SizeOf(QWord));
  CopyMemory(SavedNameEnds(Result), @Trail^.NameEnds[0], Trail^.Depth * SizeOf(Word));
  CopyMemory(SavedText(Result), @Trail^.Text[0], Trail^.TextLength + 1);
end;

procedure RestoreTrail(Saved: PSavedTrail; Trail: PNodeTrail);
begin
  Trail^.Depth := Saved^.Depth;
  Trail^.TextLength := Saved^.TextLength;
  CopyMemory(@Trail^.NodeNumbers[0], SavedNodeNumbers(Saved), Saved^.Depth * SizeOf(QWord));
  CopyMemory(@Trail^.NameEnds[0], SavedNameEnds(Saved), Saved^.Depth * SizeOf(Word));
  CopyMemory(@Trail^.Text[0], SavedText(Saved), Saved^.TextLength + 1);
end;

end.
