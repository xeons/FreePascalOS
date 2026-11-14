{
  Shell variables and parameters.

  A variable is either local to the shell or exported. Exported
  variables live in the process environment (Sys.Environment), so new
  programs inherit them; local ones are kept here. Looking a name up
  checks the local table first, then the environment.

  Special parameters: $? (status of the last command), $$ (process id),
  $# (number of positional parameters), $0..$9 and $@ / $*.
}
unit Shell.Variables;

{$mode objfpc}
{$pointermath on}

interface

var
  LastStatus: LongInt = 0;
  ScriptName: PChar = 'sh';

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

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Environment,
  Sys.Memory,
  Sys.Text;

const
  MaximumLocals = 256;

type
  TLocalVariable = record
    Name: PChar;
    Value: PChar;
  end;

var
  Locals: array[0..MaximumLocals - 1] of TLocalVariable;
  LocalCount: Integer = 0;
  Positionals: PPChar = nil;
  PositionalTotal: Integer = 0;

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

end.
