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
  Program arguments and environment variables.

  The arguments and the initial environment come from the stack the
  kernel set up. The environment can then be changed (SetVariable,
  RemoveVariable); the changed copy is what new processes inherit.
}
unit Sys.Environment;

{$mode objfpc}{$H+}
{$pointermath on}

interface

function ArgumentTotal: Integer;
{ Argument 0 is the program name. Returns '' past the end. }
function Argument(Index: Integer): PChar;
{ All arguments, nil terminated (for passing on to a new process). }
function ArgumentValues: PPChar;

{ The variable's value; '' when it is not set (or set to ''). }
function GetVariable(const Name: string): string;
{ The same, telling an unset variable from an empty one. }
function FindVariable(const Name: string; out Value: string): Boolean;
function VariableIsSet(const Name: string): Boolean;
procedure SetVariable(const Name, Value: string);
procedure RemoveVariable(const Name: string);

{ The environment as a nil terminated array of "NAME=value" strings. }
function EnvironmentBlock: PPChar;
function EnvironmentCount: Integer;

implementation

uses
  SysUtils,
  Runtime.Memory,
  Runtime.Text,
  Sys.Memory;

const
  MaximumVariables = 256;

var
  { Nil until the environment is first changed; until then the original
    block from the kernel is used. }
  Variables: PPChar = nil;
  VariableCount: Integer = 0;

function ArgumentTotal: Integer;
begin
  Result := argc;
end;

function ArgumentValues: PPChar;
begin
  Result := argv;
end;

function Argument(Index: Integer): PChar;
begin
  if (Index < 0) or (Index >= argc) then
    Result := ''
  else
    Result := argv[Index];
end;

function OriginalCount: Integer;
begin
  Result := 0;
  while envp[Result] <> nil do
    Inc(Result);
end;

procedure MakeEnvironmentWritable;
var
  Index: Integer;
begin
  if Variables <> nil then
    Exit;
  Variables := PPChar(AllocateZeroedMemory((MaximumVariables + 1) * SizeOf(PChar)));
  VariableCount := OriginalCount;
  if VariableCount > MaximumVariables then
    VariableCount := MaximumVariables;
  for Index := 0 to VariableCount - 1 do
    Variables[Index] := DuplicateText(envp[Index]);
end;

function EnvironmentBlock: PPChar;
begin
  if Variables = nil then
    Result := envp
  else
    Result := Variables;
end;

function EnvironmentCount: Integer;
begin
  if Variables = nil then
    Result := OriginalCount
  else
    Result := VariableCount;
end;

{ True if Entry is "Name=...". }
function EntryHasName(Entry: PChar; const Name: string): Boolean;
begin
  Result := (StrLComp(Entry, PChar(Name), Length(Name)) = 0) and (Entry[Length(Name)] = '=');
end;

function FindVariableIndex(const Name: string): Integer;
var
  Block: PPChar;
  Index: Integer;
begin
  Block := EnvironmentBlock;
  Index := 0;
  while Block[Index] <> nil do
  begin
    if EntryHasName(Block[Index], Name) then
      Exit(Index);
    Inc(Index);
  end;
  Result := -1;
end;

function FindVariable(const Name: string; out Value: string): Boolean;
var
  Index: Integer;
begin
  Value := '';
  Index := FindVariableIndex(Name);
  Result := Index >= 0;
  if Result then
    Value := EnvironmentBlock[Index] + Length(Name) + 1;
end;

function GetVariable(const Name: string): string;
begin
  FindVariable(Name, Result);
end;

function VariableIsSet(const Name: string): Boolean;
begin
  Result := FindVariableIndex(Name) >= 0;
end;

procedure SetVariable(const Name, Value: string);
var
  Entry: string;
  Index: Integer;
begin
  MakeEnvironmentWritable;
  Entry := Name + '=' + Value;
  Index := FindVariableIndex(Name);
  if Index >= 0 then
  begin
    FreeMemory(Variables[Index]);
    Variables[Index] := DuplicateText(PChar(Entry));
  end
  else if VariableCount < MaximumVariables then
  begin
    Variables[VariableCount] := DuplicateText(PChar(Entry));
    Inc(VariableCount);
    Variables[VariableCount] := nil;
  end;
end;

procedure RemoveVariable(const Name: string);
var
  Index: Integer;
begin
  MakeEnvironmentWritable;
  Index := FindVariableIndex(Name);
  if Index < 0 then
    Exit;
  FreeMemory(Variables[Index]);
  while Index < VariableCount do
  begin
    Variables[Index] := Variables[Index + 1];
    Inc(Index);
  end;
  Dec(VariableCount);
end;

end.
