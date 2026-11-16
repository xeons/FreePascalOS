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
  Builtins about running commands and functions:

    eval ARG...          runs the arguments, joined by spaces, as shell input
    exec [PROGRAM ARG...] (the program case is handled by Shell.Execution;
                         alone, with redirections, they become permanent)
    command [-v] NAME... runs NAME skipping functions; -v tells what it is
    type NAME...         tells whether NAME is a keyword, function, builtin
                         or program
    return [N]           leaves the current function with status N
    local NAME[=VALUE]... makes variables local to the current function
}
unit Shell.CommandBuiltins;

{$mode objfpc}
{$H+}

interface

uses
  Shell.Builtins;

{ Returns nil if Name is not one of these builtins. }
function FindCommandBuiltin(const Name: string): TBuiltinRoutine;

implementation

uses
  SysUtils,
  Classes,
  Sys.Processes,
  Sys.Streams,
  Shell.Text,
  Shell.Output,
  Shell.Host,
  Shell.Variables,
  Shell.Functions,
  Shell.Execution;

function IsKeyword(const Name: string): Boolean;
const
  Keywords: array[0..15] of string = ('if', 'then', 'else', 'elif', 'fi', 'while', 'until', 'for',
    'do', 'done', 'case', 'esac', 'in', 'function', '{', '}');
var
  Index: Integer;
begin
  for Index := Low(Keywords) to High(Keywords) do
    if Name = Keywords[Index] then
      Exit(True);
  Result := False;
end;

function BuiltinEval(Arguments: TStrings): LongInt;
var
  Text: string;
  Index: Integer;
begin
  if Arguments.Count < 2 then
    Exit(0);
  Text := Arguments[1];
  for Index := 2 to Arguments.Count - 1 do
    Text := Text + ' ' + Arguments[Index];
  Result := ExecuteText(Text);
end;

{ Reached only for "exec" without a program (see Shell.Execution). }
function BuiltinExec(Arguments: TStrings): LongInt;
begin
  Result := 0;
end;

{ Describes Name for "type" (Verbose) or "command -v". Returns False if
  it is not found. }
function DescribeCommand(const Name: string; Verbose: Boolean): Boolean;
var
  ProgramPath: string;
  Kind: string;
begin
  Result := True;
  Kind := '';
  if IsKeyword(Name) then
    Kind := 'keyword'
  else if FindFunction(Name) <> nil then
    Kind := 'function'
  else if FindBuiltin(Name) <> nil then
    Kind := 'builtin';
  if Kind <> '' then
  begin
    if Verbose then
      WriteStringLine(StandardOutput, Name + ' is a shell ' + Kind)
    else
      WriteStringLine(StandardOutput, Name);
  end
  else if FindProgramPath(Name, ProgramPath) then
  begin
    if Verbose then
      WriteStringLine(StandardOutput, Name + ' is ' + ProgramPath)
    else
      WriteStringLine(StandardOutput, ProgramPath);
  end
  else
  begin
    if Verbose then
      CommandError('type', Name + ': not found');
    Result := False;
  end;
end;

function BuiltinType(Arguments: TStrings): LongInt;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 1 to Arguments.Count - 1 do
    if not DescribeCommand(Arguments[Index], True) then
      Result := 1;
end;

{ "command NAME ..." is turned into a plain run of NAME by
  Shell.Execution; what reaches here is "command" alone or "command -v". }
function BuiltinCommand(Arguments: TStrings): LongInt;
var
  Index: Integer;
begin
  Result := 0;
  if Arguments.Count < 2 then
    Exit;
  if (Arguments[1] <> '-v') and (Arguments[1] <> '-V') then
  begin
    CommandError('command', Arguments[1] + ': unknown option');
    Exit(2);
  end;
  for Index := 2 to Arguments.Count - 1 do
    if not DescribeCommand(Arguments[Index], Arguments[1] = '-V') then
      Result := 1;
end;

function BuiltinReturn(Arguments: TStrings): LongInt;
var
  Status: Int64;
begin
  Status := LastStatus;
  if (Arguments.Count >= 2) and not TryParseInteger(Arguments[1], Status) then
  begin
    CommandError('return', Arguments[1] + ': numeric argument required');
    Status := 2;
  end;
  if FunctionDepth = 0 then
  begin
    CommandError('return', 'can only be used in a function');
    Exit(1);
  end;
  ReturnRequested := True;
  ReturnStatus := LongInt(Status and $FF);
  Result := ReturnStatus;
end;

function BuiltinLocal(Arguments: TStrings): LongInt;
var
  Index: Integer;
  EqualsPosition: Integer;
  Name: string;
begin
  Result := 0;
  if FunctionDepth = 0 then
  begin
    CommandError('local', 'can only be used in a function');
    Exit(1);
  end;
  for Index := 1 to Arguments.Count - 1 do
  begin
    EqualsPosition := Pos('=', Arguments[Index]);
    if EqualsPosition > 0 then
      Name := Copy(Arguments[Index], 1, EqualsPosition - 1)
    else
      Name := Arguments[Index];
    if not DeclareLocal(Name) then
    begin
      CommandError('local', Name + ': not a valid name');
      Result := 1;
      Continue;
    end;
    if EqualsPosition > 0 then
      AssignVariable(Name, Copy(Arguments[Index], EqualsPosition + 1, MaxInt));
  end;
end;

function FindCommandBuiltin(const Name: string): TBuiltinRoutine;
begin
  if Name = 'eval' then
    Result := @BuiltinEval
  else if Name = 'exec' then
    Result := @BuiltinExec
  else if Name = 'command' then
    Result := @BuiltinCommand
  else if Name = 'type' then
    Result := @BuiltinType
  else if Name = 'return' then
    Result := @BuiltinReturn
  else if Name = 'local' then
    Result := @BuiltinLocal
  else
    Result := nil;
end;

end.
