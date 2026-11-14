{
  Program arguments and environment variables.

  The arguments and the initial environment come from the stack the
  kernel set up. The environment can then be changed (SetVariable,
  RemoveVariable); the changed copy is what new processes inherit.
}
unit Sys.Environment;

{$mode objfpc}
{$pointermath on}

interface

function ArgumentTotal: Integer;
{ Argument 0 is the program name. Returns '' past the end. }
function Argument(Index: Integer): PChar;
{ All arguments, nil terminated (for passing on to a new process). }
function ArgumentValues: PPChar;

{ Returns nil if the variable is not set. }
function GetVariable(Name: PChar): PChar;
procedure SetVariable(Name, Value: PChar);
procedure RemoveVariable(Name: PChar);

{ The environment as a nil terminated array of "NAME=value" strings. }
function EnvironmentBlock: PPChar;
function EnvironmentCount: Integer;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Memory,
  Sys.Text;

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
function EntryHasName(Entry, Name: PChar): Boolean;
var
  NameLength: PtrUInt;
begin
  NameLength := TextLength(Name);
  Result := TextStartsWith(Entry, Name) and (Entry[NameLength] = '=');
end;

function FindVariableIndex(Name: PChar): Integer;
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

function GetVariable(Name: PChar): PChar;
var
  Index: Integer;
begin
  Index := FindVariableIndex(Name);
  if Index < 0 then
    Exit(nil);
  Result := EnvironmentBlock[Index] + TextLength(Name) + 1;
end;

procedure SetVariable(Name, Value: PChar);
var
  Builder: TTextBuilder;
  Index: Integer;
begin
  MakeEnvironmentWritable;
  BeginText(Builder);
  AppendText(Builder, Name);
  AppendCharacter(Builder, '=');
  AppendText(Builder, Value);

  Index := FindVariableIndex(Name);
  if Index >= 0 then
  begin
    FreeMemory(Variables[Index]);
    Variables[Index] := FinishText(Builder);
  end
  else if VariableCount < MaximumVariables then
  begin
    Variables[VariableCount] := FinishText(Builder);
    Inc(VariableCount);
    Variables[VariableCount] := nil;
  end
  else
    DiscardText(Builder);
end;

procedure RemoveVariable(Name: PChar);
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
