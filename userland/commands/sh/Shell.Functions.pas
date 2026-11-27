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
  Shell functions: the table of defined functions.

  A definition keeps a copy of the function's body (the command line it
  came in is freed after it runs) and its source text, so that a
  subshell started as a new process (command substitution) can be given
  the same functions.

  A function may redefine or unset itself while it runs, so a body that
  is replaced or unset is not freed under the running code: it is
  retired, and freed with the table when the shell ends.
}
unit Shell.Functions;

{$mode objfpc}
{$H+}

interface

uses
  Shell.Nodes;

{ Defines (or redefines) a function. }
procedure DefineFunction(Definition: TFunctionNode);
{ The body of a function, or nil. }
function FindFunction(const Name: string): TShellNode;
function UnsetFunction(const Name: string): Boolean;
{ Every definition's source text, one per line. }
function FunctionDefinitionsScript: string;

implementation

uses
  Classes,
  Contnrs;

type
  TShellFunction = class
  public
    Body: TShellNode;
    SourceText: string;
  end;

var
  { Names, in the order they were defined, with their TShellFunction. }
  Functions: TStringList;
  RetiredBodies: TObjectList;

procedure RetireBody(ShellFunction: TShellFunction);
begin
  if ShellFunction.Body <> nil then
    RetiredBodies.Add(ShellFunction.Body);
  ShellFunction.Body := nil;
end;

procedure DefineFunction(Definition: TFunctionNode);
var
  Index: Integer;
  ShellFunction: TShellFunction;
begin
  Index := Functions.IndexOf(Definition.Name);
  if Index < 0 then
  begin
    ShellFunction := TShellFunction.Create;
    Functions.AddObject(Definition.Name, ShellFunction);
  end
  else
  begin
    ShellFunction := TShellFunction(Functions.Objects[Index]);
    RetireBody(ShellFunction);
  end;
  ShellFunction.Body := CloneNode(Definition.Body);
  ShellFunction.SourceText := Definition.SourceText;
end;

function FindFunction(const Name: string): TShellNode;
var
  Index: Integer;
begin
  Index := Functions.IndexOf(Name);
  if Index < 0 then
    Exit(nil);
  Result := TShellFunction(Functions.Objects[Index]).Body;
end;

function UnsetFunction(const Name: string): Boolean;
var
  Index: Integer;
  ShellFunction: TShellFunction;
begin
  Index := Functions.IndexOf(Name);
  if Index < 0 then
    Exit(False);
  ShellFunction := TShellFunction(Functions.Objects[Index]);
  RetireBody(ShellFunction);
  ShellFunction.Free;
  Functions.Delete(Index);
  Result := True;
end;

function FunctionDefinitionsScript: string;
var
  Index: Integer;
  ShellFunction: TShellFunction;
begin
  Result := '';
  for Index := 0 to Functions.Count - 1 do
  begin
    ShellFunction := TShellFunction(Functions.Objects[Index]);
    if ShellFunction.SourceText <> '' then
      Result := Result + ShellFunction.SourceText + #10;
  end;
end;

procedure FreeFunctions;
var
  Index: Integer;
  ShellFunction: TShellFunction;
begin
  for Index := 0 to Functions.Count - 1 do
  begin
    ShellFunction := TShellFunction(Functions.Objects[Index]);
    ShellFunction.Body.Free;
    ShellFunction.Free;
  end;
  Functions.Free;
end;

initialization
  Functions := TStringList.Create;
  Functions.CaseSensitive := True;
  Functions.UseLocale := False;
  RetiredBodies := TObjectList.Create(True);
finalization
  FreeFunctions;
  RetiredBodies.Free;
end.
