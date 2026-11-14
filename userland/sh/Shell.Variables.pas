{
  Shell variables and parameters.

  A variable is either local to the shell or exported. Exported
  variables live in the process environment (Sys.Environment), so new
  programs inherit them; local ones are kept here. Looking a name up
  checks the local table first, then the environment.

  Special parameters: $? (status of the last command), $$ (process id),
  $# (number of positional parameters), $0..$9 and $@ / $*.

  Functions get their own positional parameters, and "local" variables
  that are restored when the function returns (see BeginLocalScope).
}
unit Shell.Variables;

{$mode objfpc}
{$pointermath on}

interface

uses
  Sys.Text;

var
  LastStatus: LongInt = 0;
  ScriptName: PChar = 'sh';
  { Set by an expansion that failed (${NAME:?message}, a bad
    substitution); the command is then not run. }
  ExpansionFailed: Boolean = False;

{ Returns nil if the variable is not set. }
function LookupVariable(Name: PChar): PChar;
procedure AssignVariable(Name, Value: PChar);
procedure ExportVariable(Name: PChar);
procedure UnsetVariable(Name: PChar);
{ Handles "NAME=value"; False if Text is not an assignment. }
function AssignFromText(Text: PChar; MakeExported: Boolean): Boolean;

procedure SetPositionalParameters(Values: PPChar; Count: Integer);
function PositionalCount: Integer;
{ Index 1 is $1. Returns nil past the end. }
function PositionalParameter(Index: Integer): PChar;
procedure ShiftPositionalParameters(Count: Integer);

function IsValidName(Name: PChar): Boolean;

type
  TSavedPositionals = record
    Items: PPChar;
    Count: Integer;
    Block: PPChar;
    BlockCount: Integer;
  end;

procedure SavePositionalParameters(out Saved: TSavedPositionals);
procedure RestorePositionalParameters(const Saved: TSavedPositionals);

{ Function calls: variables declared local after BeginLocalScope get
  their old values back at EndLocalScope. }
procedure BeginLocalScope;
procedure EndLocalScope;
{ Declares Name local to the current function (False outside one). }
function DeclareLocal(Name: PChar): Boolean;

{ Appends shell commands that recreate the non-exported variables and
  the positional parameters (for a subshell started as a new process). }
procedure AppendVariableState(var Builder: TTextBuilder);
{ Appends Text in single quotes, quoting it for the shell. }
procedure AppendQuoted(var Builder: TTextBuilder; Text: PChar);

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Environment,
  Sys.Memory;

const
  MaximumLocals = 256;
  MaximumSavedLocals = 256;

type
  TLocalVariable = record
    Name: PChar;
    Value: PChar;
  end;

type
  { A variable's state before a function made it local. }
  TSavedLocal = record
    Scope: Integer;
    Name: PChar;
    Value: PChar;       { nil if it was unset }
    WasExported: Boolean;
  end;

var
  SavedLocals: array[0..MaximumSavedLocals - 1] of TSavedLocal;
  SavedLocalCount: Integer = 0;
  ScopeDepth: Integer = 0;
  Locals: array[0..MaximumLocals - 1] of TLocalVariable;
  LocalCount: Integer = 0;
  Positionals: PPChar = nil;
  PositionalTotal: Integer = 0;
  { The allocation Positionals points into (shift moves the pointer). }
  PositionalBlock: PPChar = nil;
  PositionalBlockCount: Integer = 0;

function IsValidName(Name: PChar): Boolean;
var
  Index: Integer;
begin
  Result := False;
  if (Name = nil) or not (IsLetter(Name[0]) or (Name[0] = '_')) then
    Exit;
  Index := 1;
  while Name[Index] <> #0 do
  begin
    if not (IsAlphanumeric(Name[Index]) or (Name[Index] = '_')) then
      Exit;
    Inc(Index);
  end;
  Result := True;
end;

function FindLocal(Name: PChar): Integer;
var
  Index: Integer;
begin
  for Index := 0 to LocalCount - 1 do
  begin
    if TextIsEqual(Locals[Index].Name, Name) then
      Exit(Index);
  end;
  Result := -1;
end;

procedure RemoveLocal(Index: Integer);
begin
  FreeMemory(Locals[Index].Name);
  FreeMemory(Locals[Index].Value);
  while Index < LocalCount - 1 do
  begin
    Locals[Index] := Locals[Index + 1];
    Inc(Index);
  end;
  Dec(LocalCount);
end;

function LookupVariable(Name: PChar): PChar;
var
  Index: Integer;
begin
  Index := FindLocal(Name);
  if Index >= 0 then
    Exit(Locals[Index].Value);
  Result := GetVariable(Name);
end;

procedure AssignVariable(Name, Value: PChar);
var
  Index: Integer;
begin
  { An exported variable stays exported when it changes. }
  if (FindLocal(Name) < 0) and (GetVariable(Name) <> nil) then
  begin
    SetVariable(Name, Value);
    Exit;
  end;
  Index := FindLocal(Name);
  if Index >= 0 then
  begin
    FreeMemory(Locals[Index].Value);
    Locals[Index].Value := DuplicateText(Value);
    Exit;
  end;
  if LocalCount = MaximumLocals then
    Exit;
  Locals[LocalCount].Name := DuplicateText(Name);
  Locals[LocalCount].Value := DuplicateText(Value);
  Inc(LocalCount);
end;

procedure ExportVariable(Name: PChar);
var
  Index: Integer;
begin
  Index := FindLocal(Name);
  if Index >= 0 then
  begin
    SetVariable(Name, Locals[Index].Value);
    RemoveLocal(Index);
  end
  else if GetVariable(Name) = nil then
    SetVariable(Name, '');
end;

procedure UnsetVariable(Name: PChar);
var
  Index: Integer;
begin
  Index := FindLocal(Name);
  if Index >= 0 then
    RemoveLocal(Index);
  RemoveVariable(Name);
end;

function AssignFromText(Text: PChar; MakeExported: Boolean): Boolean;
var
  EqualsPosition: PtrInt;
  Name: array[0..255] of Char;
begin
  EqualsPosition := FindCharacter(Text, '=');
  if (EqualsPosition <= 0) or (EqualsPosition >= Length(Name)) then
    Exit(False);
  CopyText(@Name[0], Text, PtrUInt(EqualsPosition) + 1);
  if not IsValidName(@Name[0]) then
    Exit(False);
  AssignVariable(@Name[0], Text + EqualsPosition + 1);
  if MakeExported then
    ExportVariable(@Name[0]);
  Result := True;
end;

procedure SetPositionalParameters(Values: PPChar; Count: Integer);
var
  Index: Integer;
begin
  Positionals := PPChar(AllocateZeroedMemory(QWord(Count + 1) * SizeOf(PChar)));
  for Index := 0 to Count - 1 do
    Positionals[Index] := DuplicateText(Values[Index]);
  PositionalTotal := Count;
  PositionalBlock := Positionals;
  PositionalBlockCount := Count;
end;

function PositionalCount: Integer;
begin
  Result := PositionalTotal;
end;

function PositionalParameter(Index: Integer): PChar;
begin
  if (Index < 1) or (Index > PositionalTotal) then
    Exit(nil);
  Result := Positionals[Index - 1];
end;

procedure ShiftPositionalParameters(Count: Integer);
begin
  if Count > PositionalTotal then
    Count := PositionalTotal;
  Positionals := Positionals + Count;
  PositionalTotal := PositionalTotal - Count;
end;

procedure SavePositionalParameters(out Saved: TSavedPositionals);
begin
  Saved.Items := Positionals;
  Saved.Count := PositionalTotal;
  Saved.Block := PositionalBlock;
  Saved.BlockCount := PositionalBlockCount;
end;

{ Frees the function's parameters and puts the caller's back. }
procedure RestorePositionalParameters(const Saved: TSavedPositionals);
var
  Index: Integer;
begin
  if (PositionalBlock <> nil) and (PositionalBlock <> Saved.Block) then
  begin
    for Index := 0 to PositionalBlockCount - 1 do
      FreeMemory(PositionalBlock[Index]);
    FreeMemory(PositionalBlock);
  end;
  Positionals := Saved.Items;
  PositionalTotal := Saved.Count;
  PositionalBlock := Saved.Block;
  PositionalBlockCount := Saved.BlockCount;
end;

procedure BeginLocalScope;
begin
  Inc(ScopeDepth);
end;

procedure EndLocalScope;
var
  Saved: ^TSavedLocal;
begin
  while (SavedLocalCount > 0) and (SavedLocals[SavedLocalCount - 1].Scope = ScopeDepth) do
  begin
    Saved := @SavedLocals[SavedLocalCount - 1];
    UnsetVariable(Saved^.Name);
    if Saved^.Value <> nil then
    begin
      AssignVariable(Saved^.Name, Saved^.Value);
      if Saved^.WasExported then
        ExportVariable(Saved^.Name);
    end;
    FreeMemory(Saved^.Name);
    FreeMemory(Saved^.Value);
    Dec(SavedLocalCount);
  end;
  if ScopeDepth > 0 then
    Dec(ScopeDepth);
end;

function DeclareLocal(Name: PChar): Boolean;
var
  Index: Integer;
  Value: PChar;
begin
  if (ScopeDepth = 0) or not IsValidName(Name) then
    Exit(False);
  { Declared twice in one function: the first saved value counts. }
  for Index := SavedLocalCount - 1 downto 0 do
  begin
    if SavedLocals[Index].Scope <> ScopeDepth then
      Break;
    if TextIsEqual(SavedLocals[Index].Name, Name) then
      Exit(True);
  end;
  if SavedLocalCount = MaximumSavedLocals then
    Exit(False);
  Value := LookupVariable(Name);
  SavedLocals[SavedLocalCount].Scope := ScopeDepth;
  SavedLocals[SavedLocalCount].Name := DuplicateText(Name);
  SavedLocals[SavedLocalCount].WasExported := (FindLocal(Name) < 0) and (GetVariable(Name) <> nil);
  if Value <> nil then
    SavedLocals[SavedLocalCount].Value := DuplicateText(Value)
  else
    SavedLocals[SavedLocalCount].Value := nil;
  Inc(SavedLocalCount);
  Result := True;
end;

procedure AppendQuoted(var Builder: TTextBuilder; Text: PChar);
var
  Index: PtrUInt;
begin
  AppendCharacter(Builder, '''');
  Index := 0;
  while Text[Index] <> #0 do
  begin
    if Text[Index] = '''' then
      AppendText(Builder, '''\''''')
    else
      AppendCharacter(Builder, Text[Index]);
    Inc(Index);
  end;
  AppendCharacter(Builder, '''');
end;

procedure AppendVariableState(var Builder: TTextBuilder);
var
  Index: Integer;
begin
  for Index := 0 to LocalCount - 1 do
  begin
    AppendText(Builder, Locals[Index].Name);
    AppendCharacter(Builder, '=');
    AppendQuoted(Builder, Locals[Index].Value);
    AppendCharacter(Builder, #10);
  end;
  AppendText(Builder, 'set --');
  for Index := 1 to PositionalTotal do
  begin
    AppendCharacter(Builder, ' ');
    AppendQuoted(Builder, Positionals[Index - 1]);
  end;
  AppendCharacter(Builder, #10);
end;

end.
