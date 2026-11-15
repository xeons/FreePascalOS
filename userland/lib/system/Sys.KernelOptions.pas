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
  The options the system was started with (the kernel's command line,
  from options.txt on the boot volume): space separated words, flags
  ("kshell") or name=value pairs ("mode=text"). The service manager
  reads its boot mode here, login and the session manager the user to
  log in automatically.
}
unit Sys.KernelOptions;

{$mode objfpc}
{$pointermath on}

interface

const
  KernelOptionsCapacity = 512;

{ True if the flag Name (or a name=value pair of that name) is given. }
function KernelOptionIsSet(Name: PChar): Boolean;
{ Copies the value of the name=value option Name into Value (at most
  Capacity - 1 characters); False if the option is not given. }
function GetKernelOption(Name: PChar; Value: PChar; Capacity: PtrUInt): Boolean;

implementation

uses
  Runtime.Text,
  Sys.Kernel;

{ The line, read afresh: it is short, and asked for rarely. }
procedure ReadOptions(Line: PChar);
begin
  if KernelGetKernelOptions(Line, KernelOptionsCapacity) < 0 then
    Line^ := #0;
end;

{ The word of Line named Name: a pointer just past the name (at '=',
  a space or the end), or nil. }
function FindWord(Line: PChar; Name: PChar): PChar;
var
  WordStart: PChar;
  NameLength: PtrUInt;
  Index: PtrUInt;
  Matches: Boolean;
  AfterName: Char;
begin
  NameLength := TextLength(Name);
  WordStart := Line;
  while WordStart^ <> #0 do
  begin
    while WordStart^ = ' ' do
      Inc(WordStart);
    if WordStart^ = #0 then
      Break;
    Matches := True;
    Index := 0;
    while Matches and (Index < NameLength) do
    begin
      if WordStart[Index] <> Name[Index] then
        Matches := False;
      Inc(Index);
    end;
    if Matches then
    begin
      AfterName := WordStart[NameLength];
      if (AfterName = #0) or (AfterName = ' ') or (AfterName = '=') then
        Exit(@WordStart[NameLength]);
    end;
    while (WordStart^ <> ' ') and (WordStart^ <> #0) do
      Inc(WordStart);
  end;
  Result := nil;
end;

function KernelOptionIsSet(Name: PChar): Boolean;
var
  Line: array[0..KernelOptionsCapacity - 1] of Char;
begin
  ReadOptions(@Line[0]);
  Result := FindWord(@Line[0], Name) <> nil;
end;

function GetKernelOption(Name: PChar; Value: PChar; Capacity: PtrUInt): Boolean;
var
  Line: array[0..KernelOptionsCapacity - 1] of Char;
  AfterName: PChar;
  Length: PtrUInt;
begin
  Result := False;
  if Capacity = 0 then
    Exit;
  ReadOptions(@Line[0]);
  AfterName := FindWord(@Line[0], Name);
  if (AfterName = nil) or (AfterName^ <> '=') then
    Exit;
  Inc(AfterName);
  Length := 0;
  while (AfterName[Length] <> ' ') and (AfterName[Length] <> #0) and (Length + 1 < Capacity) do
  begin
    Value[Length] := AfterName[Length];
    Inc(Length);
  end;
  Value[Length] := #0;
  Result := True;
end;

end.
