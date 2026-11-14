{
  Shell functions: the table of defined functions.

  A definition keeps a copy of the function's body (the command line it
  came in is freed after it runs) and its source text, so that a
  subshell started as a new process (command substitution) can be given
  the same functions.
}
unit Shell.Functions;

{$mode objfpc}
{$pointermath on}

interface

uses
  Sys.Text,
  Shell.Syntax;

{ Defines (or redefines) a function from a NodeFunction. }
procedure DefineFunction(Definition: PNode);
{ The body of a function, or nil. }
function FindFunction(Name: PChar): PNode;
function UnsetFunction(Name: PChar): Boolean;
{ Appends every definition's source text, one per line. }
procedure AppendFunctionDefinitions(var Builder: TTextBuilder);

implementation

uses
  Runtime.Text,
  Sys.Memory;

const
  MaximumFunctions = 256;

type
  TFunction = record
    Name: PChar;
    Body: PNode;
    SourceText: PChar;
  end;

var
  Functions: array[0..MaximumFunctions - 1] of TFunction;
  FunctionCount: Integer = 0;

function FindIndex(Name: PChar): Integer;
var
  Index: Integer;
begin
  for Index := 0 to FunctionCount - 1 do
    if TextIsEqual(Functions[Index].Name, Name) then
      Exit(Index);
  Result := -1;
end;

procedure DefineFunction(Definition: PNode);
var
  Index: Integer;
begin
  Index := FindIndex(Definition^.VariableName);
  if Index < 0 then
  begin
    if FunctionCount = MaximumFunctions then
      Exit;
    Index := FunctionCount;
    Inc(FunctionCount);
    Functions[Index].Name := DuplicateText(Definition^.VariableName);
  end
  else
  begin
    { A function may redefine itself while it runs; the old body is kept
      (leaked) rather than freed under the running code. }
    FreeMemory(Functions[Index].SourceText);
  end;
  Functions[Index].Body := CopyNode(Definition^.Body);
  if Definition^.SourceText <> nil then
    Functions[Index].SourceText := DuplicateText(Definition^.SourceText)
  else
    Functions[Index].SourceText := nil;
end;

function FindFunction(Name: PChar): PNode;
var
  Index: Integer;
begin
  Index := FindIndex(Name);
  if Index < 0 then
    Exit(nil);
  Result := Functions[Index].Body;
end;

function UnsetFunction(Name: PChar): Boolean;
var
  Index: Integer;
begin
  Index := FindIndex(Name);
  if Index < 0 then
    Exit(False);
  FreeMemory(Functions[Index].Name);
  FreeMemory(Functions[Index].SourceText);
  while Index < FunctionCount - 1 do
  begin
    Functions[Index] := Functions[Index + 1];
    Inc(Index);
  end;
  Dec(FunctionCount);
  Result := True;
end;

procedure AppendFunctionDefinitions(var Builder: TTextBuilder);
var
  Index: Integer;
begin
  for Index := 0 to FunctionCount - 1 do
    if Functions[Index].SourceText <> nil then
    begin
      AppendText(Builder, Functions[Index].SourceText);
      AppendCharacter(Builder, #10);
    end;
end;

end.
