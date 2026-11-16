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
  Shell variables and parameters.

  A variable is either local to the shell or exported. Exported
  variables live in the process environment (Sys.Environment), so new
  programs inherit them; local ones are kept here. Looking a name up
  checks the local table first, then the environment. A value ends at
  its first NUL, as it would in the environment.

  Special parameters: $? (status of the last command), $$ (process id),
  $! (process id of the last background command), $# (number of
  positional parameters), $0..$9 and $@ / $*.

  Functions get their own positional parameters, and "local" variables
  that are restored when the function returns (see BeginLocalScope).
}
unit Shell.Variables;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes;

var
  LastStatus: LongInt = 0;
  ScriptName: string = 'sh';
  (* Set by an expansion that failed (${NAME:?message}, a bad
     substitution); the command is then not run. *)
  ExpansionFailed: Boolean = False;
  { $!: the last program of the most recent background pipeline (0 if
    none was started). }
  LastBackgroundProcessId: Int64 = 0;

{ False if the variable is not set. }
function FindVariable(const Name: string; out Value: string): Boolean;
{ The value, or '' if the variable is not set. }
function VariableValue(const Name: string): string;
procedure AssignVariable(const Name, Value: string);
procedure ExportVariable(const Name: string);
procedure UnsetVariable(const Name: string);
{ Handles "NAME=value"; False if Text is not an assignment. }
function AssignFromText(const Text: string; MakeExported: Boolean): Boolean;

procedure SetPositionalParameters(const Values: TStringArray);
function PositionalCount: Integer;
{ Index 1 is $1. False past the end. }
function FindPositionalParameter(Index: Integer; out Value: string): Boolean;
{ The same with '' past the end. }
function PositionalParameter(Index: Integer): string;
procedure ShiftPositionalParameters(Count: Integer);
{ For a function call: the caller's parameters, to be put back. }
function SavePositionalParameters: TStringArray;
procedure RestorePositionalParameters(const Saved: TStringArray);

function IsValidName(const Name: string): Boolean;

{ Function calls: variables declared local after BeginLocalScope get
  their old values back at EndLocalScope. }
procedure BeginLocalScope;
procedure EndLocalScope;
{ Declares Name local to the current function (False outside one). }
function DeclareLocal(const Name: string): Boolean;

{ Shell commands that recreate the non-exported variables and the
  positional parameters (for a subshell started as a new process). }
function VariableStateScript: string;
{ Text in single quotes, quoted for the shell. }
function QuoteForShell(const Text: string): string;

implementation

uses
  Sys.Environment,
  Shell.Text;

type
  TShellVariable = record
    Name: string;
    Value: string;
  end;

  { A variable's state before a function made it local. }
  TSavedLocal = record
    Scope: Integer;
    Name: string;
    Value: string;
    WasSet: Boolean;
    WasExported: Boolean;
  end;

var
  { The shell's own variables, in the order they were made. }
  ShellVariables: array of TShellVariable;
  SavedLocals: array of TSavedLocal;
  ScopeDepth: Integer = 0;
  Positionals: TStringArray;

function IsValidName(const Name: string): Boolean;
var
  Index: Integer;
begin
  Result := False;
  if not IsNameStart(CharAt(Name, 1)) then
    Exit;
  for Index := 2 to Length(Name) do
    if not IsNameCharacter(Name[Index]) then
      Exit;
  Result := True;
end;

{ --- The environment (exported variables) ------------------------------ }

function FindEnvironmentVariable(const Name: string; out Value: string): Boolean;
begin
  Result := FindVariable(Name, Value);
end;

function IsEnvironmentVariable(const Name: string): Boolean;
begin
  Result := VariableIsSet(Name);
end;

{ --- The shell's own variables ------------------------------------------ }

function FindShellVariable(const Name: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(ShellVariables) do
    if ShellVariables[Index].Name = Name then
      Exit(Index);
  Result := -1;
end;

procedure AddShellVariable(const Name, Value: string);
var
  Count: Integer;
begin
  Count := Length(ShellVariables);
  SetLength(ShellVariables, Count + 1);
  ShellVariables[Count].Name := Name;
  ShellVariables[Count].Value := Value;
end;

procedure DeleteShellVariable(Index: Integer);
begin
  Delete(ShellVariables, Index, 1);
end;

{ --- Variables --------------------------------------------------------- }

function FindVariable(const Name: string; out Value: string): Boolean;
var
  Index: Integer;
begin
  Index := FindShellVariable(Name);
  if Index >= 0 then
  begin
    Value := ShellVariables[Index].Value;
    Exit(True);
  end;
  Result := FindEnvironmentVariable(Name, Value);
end;

function VariableValue(const Name: string): string;
begin
  FindVariable(Name, Result);
end;

procedure AssignVariable(const Name, Value: string);
var
  Index: Integer;
  StoredValue: string;
begin
  StoredValue := TextBeforeNull(Value);
  Index := FindShellVariable(Name);
  { An exported variable stays exported when it changes. }
  if (Index < 0) and IsEnvironmentVariable(Name) then
  begin
    SetVariable(Name, StoredValue);
    Exit;
  end;
  if Index >= 0 then
    ShellVariables[Index].Value := StoredValue
  else
    AddShellVariable(Name, StoredValue);
end;

procedure ExportVariable(const Name: string);
var
  Index: Integer;
begin
  Index := FindShellVariable(Name);
  if Index >= 0 then
  begin
    SetVariable(Name, ShellVariables[Index].Value);
    DeleteShellVariable(Index);
  end
  else if not IsEnvironmentVariable(Name) then
    SetVariable(Name, '');
end;

procedure UnsetVariable(const Name: string);
var
  Index: Integer;
begin
  Index := FindShellVariable(Name);
  if Index >= 0 then
    DeleteShellVariable(Index);
  RemoveVariable(Name);
end;

function AssignFromText(const Text: string; MakeExported: Boolean): Boolean;
var
  EqualsPosition: Integer;
  Name: string;
begin
  EqualsPosition := Pos('=', Text);
  if EqualsPosition <= 1 then
    Exit(False);
  Name := Copy(Text, 1, EqualsPosition - 1);
  if not IsValidName(Name) then
    Exit(False);
  AssignVariable(Name, Copy(Text, EqualsPosition + 1, MaxInt));
  if MakeExported then
    ExportVariable(Name);
  Result := True;
end;

{ --- Positional parameters --------------------------------------------- }

procedure SetPositionalParameters(const Values: TStringArray);
begin
  Positionals := Copy(Values);
end;

function PositionalCount: Integer;
begin
  Result := Length(Positionals);
end;

function FindPositionalParameter(Index: Integer; out Value: string): Boolean;
begin
  Result := (Index >= 1) and (Index <= Length(Positionals));
  if Result then
    Value := Positionals[Index - 1]
  else
    Value := '';
end;

function PositionalParameter(Index: Integer): string;
begin
  FindPositionalParameter(Index, Result);
end;

procedure ShiftPositionalParameters(Count: Integer);
begin
  if Count > Length(Positionals) then
    Count := Length(Positionals);
  { A new array: a caller's saved parameters stay as they were. }
  Positionals := Copy(Positionals, Count, MaxInt);
end;

function SavePositionalParameters: TStringArray;
begin
  Result := Positionals;
end;

procedure RestorePositionalParameters(const Saved: TStringArray);
begin
  Positionals := Saved;
end;

{ --- Local variables of functions -------------------------------------- }

procedure BeginLocalScope;
begin
  Inc(ScopeDepth);
end;

procedure EndLocalScope;
var
  Last: Integer;
  Saved: TSavedLocal;
begin
  Last := High(SavedLocals);
  while (Last >= 0) and (SavedLocals[Last].Scope = ScopeDepth) do
  begin
    Saved := SavedLocals[Last];
    UnsetVariable(Saved.Name);
    if Saved.WasSet then
    begin
      AssignVariable(Saved.Name, Saved.Value);
      if Saved.WasExported then
        ExportVariable(Saved.Name);
    end;
    SetLength(SavedLocals, Last);
    Dec(Last);
  end;
  if ScopeDepth > 0 then
    Dec(ScopeDepth);
end;

function DeclareLocal(const Name: string): Boolean;
var
  Index: Integer;
  Saved: TSavedLocal;
begin
  if (ScopeDepth = 0) or not IsValidName(Name) then
    Exit(False);
  { Declared twice in one function: the first saved value counts. }
  for Index := High(SavedLocals) downto 0 do
  begin
    if SavedLocals[Index].Scope <> ScopeDepth then
      Break;
    if SavedLocals[Index].Name = Name then
      Exit(True);
  end;
  Saved.Scope := ScopeDepth;
  Saved.Name := Name;
  Saved.WasSet := FindVariable(Name, Saved.Value);
  Saved.WasExported := (FindShellVariable(Name) < 0) and IsEnvironmentVariable(Name);
  Index := Length(SavedLocals);
  SetLength(SavedLocals, Index + 1);
  SavedLocals[Index] := Saved;
  Result := True;
end;

{ --- Subshells --------------------------------------------------------- }

function QuoteForShell(const Text: string): string;
begin
  Result := '''' + StringReplace(Text, '''', '''\''''', [rfReplaceAll]) + '''';
end;

function VariableStateScript: string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(ShellVariables) do
    Result := Result + ShellVariables[Index].Name + '=' + QuoteForShell(ShellVariables[Index].Value) + #10;
  Result := Result + 'set --';
  for Index := 0 to High(Positionals) do
    Result := Result + ' ' + QuoteForShell(Positionals[Index]);
  Result := Result + #10;
end;

end.
