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
  Commands built into the shell.

  Some commands have to run inside the shell because they change its
  state (cd, exit, export, unset, set, shift, read, ., break, continue,
  umask);
  a few more (:, true, false) are builtins only to save starting a
  process. Everything else is a program in /bin. The builtins about
  running commands and functions (eval, exec, command, type, return,
  local) are in Shell.CommandBuiltins, the job control ones (jobs, fg,
  bg, wait, kill) in Shell.JobBuiltins.

  A builtin gets its command line as a list: Arguments[0] is its name.
}
unit Shell.Builtins;

{$mode objfpc}
{$H+}

interface

uses
  Classes;

type
  TBuiltinRoutine = function(Arguments: TStrings): LongInt;

{ Returns nil if Name is not a builtin. }
function FindBuiltin(const Name: string): TBuiltinRoutine;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Environment,
  Sys.Errors,
  Sys.Files,
  Sys.Kernel,
  Sys.Streams,
  Sys.Text,
  Shell.Text,
  Shell.Output,
  Shell.Host,
  Shell.Variables,
  Shell.Functions,
  Shell.CommandBuiltins,
  Shell.JobBuiltins,
  Shell.Execution;

function BuiltinColon(Arguments: TStrings): LongInt;
begin
  Result := 0;
end;

function BuiltinFalse(Arguments: TStrings): LongInt;
begin
  Result := 1;
end;

function BuiltinChangeDirectory(Arguments: TStrings): LongInt;
var
  Target: string;
  Directory: string;
  Error: LongInt;
begin
  if Arguments.Count > 2 then
  begin
    CommandError('cd', 'too many arguments');
    Exit(1);
  end;
  if Arguments.Count = 2 then
    Target := Arguments[1]
  else if not FindVariable('HOME', Target) then
    Target := '/';
  if Target = '-' then
  begin
    if not FindVariable('OLDPWD', Target) then
    begin
      CommandError('cd', 'OLDPWD not set');
      Exit(1);
    end;
  end;

  if CurrentDirectoryPath(Directory) = ErrorNone then
    AssignVariable('OLDPWD', Directory);
  Error := ChangeDirectory(PChar(Target));
  if Error <> ErrorNone then
  begin
    CommandError('cd', Target + ': ' + ErrorMessage(Error));
    Exit(1);
  end;
  if CurrentDirectoryPath(Directory) = ErrorNone then
    AssignVariable('PWD', Directory);
  Result := 0;
end;

function BuiltinExit(Arguments: TStrings): LongInt;
var
  Code: Int64;
begin
  Code := LastStatus;
  if (Arguments.Count >= 2) and not TryParseInteger(Arguments[1], Code) then
  begin
    CommandError('exit', Arguments[1] + ': numeric argument required');
    Code := 2;
  end;
  ExitRequested := True;
  RequestedExitCode := LongInt(Code and $FF);
  Result := RequestedExitCode;
end;

procedure ListExportedVariables;
var
  Block: PPChar;
  Index: Integer;
begin
  Block := EnvironmentBlock;
  Index := 0;
  while Block[Index] <> nil do
  begin
    WriteStringLine(StandardOutput, 'export ' + string(Block[Index]));
    Inc(Index);
  end;
end;

function BuiltinExport(Arguments: TStrings): LongInt;
var
  Index: Integer;
  Argument: string;
  Valid: Boolean;
begin
  Result := 0;
  if Arguments.Count = 1 then
  begin
    ListExportedVariables;
    Exit;
  end;
  for Index := 1 to Arguments.Count - 1 do
  begin
    Argument := Arguments[Index];
    if Pos('=', Argument) > 0 then
      Valid := AssignFromText(Argument, True)
    else
    begin
      Valid := IsValidName(Argument);
      if Valid then
        ExportVariable(Argument);
    end;
    if not Valid then
    begin
      CommandError('export', '''' + Argument + ''': not a valid identifier');
      Result := 1;
    end;
  end;
end;

{ unset [-v] NAME... removes variables; unset -f NAME... functions. }
function BuiltinUnset(Arguments: TStrings): LongInt;
var
  Index: Integer;
  First: Integer;
  RemoveFunctions: Boolean;
begin
  First := 1;
  RemoveFunctions := False;
  if (Arguments.Count > 1) and (Arguments[1] = '-f') then
  begin
    RemoveFunctions := True;
    First := 2;
  end
  else if (Arguments.Count > 1) and (Arguments[1] = '-v') then
    First := 2;
  for Index := First to Arguments.Count - 1 do
    if RemoveFunctions then
      UnsetFunction(Arguments[Index])
    else
      UnsetVariable(Arguments[Index]);
  Result := 0;
end;

{ set -- ARG... replaces the positional parameters. }
function BuiltinSet(Arguments: TStrings): LongInt;
var
  First: Integer;
begin
  First := 1;
  if (Arguments.Count > 1) and (Arguments[1] = '--') then
    First := 2;
  SetPositionalParameters(StringsFrom(Arguments, First));
  Result := 0;
end;

function BuiltinShift(Arguments: TStrings): LongInt;
var
  Amount: Int64;
begin
  Amount := 1;
  if (Arguments.Count >= 2) and (not TryParseInteger(Arguments[1], Amount) or (Amount < 0)) then
  begin
    CommandError('shift', Arguments[1] + ': numeric argument required');
    Exit(1);
  end;
  if Amount > PositionalCount then
    Exit(1);
  ShiftPositionalParameters(Integer(Amount));
  Result := 0;
end;

{ One line of standard input, a byte at a time so that nothing beyond
  the line is consumed. }
function ReadInputLine(out SawLineEnd: Boolean): string;
var
  Line: TTextBuffer;
  Character: Char;
begin
  Line.Clear;
  SawLineEnd := False;
  while ReadFile(StandardInputHandle, @Character, 1) > 0 do
  begin
    if Character = #10 then
    begin
      SawLineEnd := True;
      Break;
    end;
    Line.Append(Character);
  end;
  Result := Line.Value;
end;

{ read NAME... reads one line from standard input and assigns its words
  to the names, the last name getting the rest of the line. }
function BuiltinRead(Arguments: TStrings): LongInt;
var
  Line: string;
  SawLineEnd: Boolean;
  Position: Integer;
  Start: Integer;
  NameIndex: Integer;
  LastName: Integer;
begin
  FlushStandardStreams;
  Line := ReadInputLine(SawLineEnd);

  Position := 1;
  LastName := Arguments.Count - 1;
  for NameIndex := 1 to LastName do
  begin
    while IsSpace(CharAt(Line, Position)) do
      Inc(Position);
    Start := Position;
    if NameIndex = LastName then
    begin
      Position := Length(Line) + 1;
      while (Position > Start) and IsSpace(Line[Position - 1]) do
        Dec(Position);
    end
    else
      while (CharAt(Line, Position) <> #0) and not IsSpace(Line[Position]) do
        Inc(Position);
    AssignVariable(Arguments[NameIndex], Copy(Line, Start, Position - Start));
  end;

  if SawLineEnd or (Line <> '') then
    Result := 0
  else
    Result := 1;
end;

{ . FILE runs the commands in FILE in this shell. }
function BuiltinSource(Arguments: TStrings): LongInt;
var
  Text: string;
  Error: LongInt;
begin
  if Arguments.Count < 2 then
  begin
    CommandError('.', 'file name argument required');
    Exit(2);
  end;
  Error := ReadTextFile(Arguments[1], Text);
  if Error <> ErrorNone then
  begin
    CommandError('.', Arguments[1] + ': ' + ErrorMessage(Error));
    Exit(1);
  end;
  Result := ExecuteText(Text);
end;

function LoopControlBuiltin(const Name: string; Arguments: TStrings; Control: TLoopControl): LongInt;
var
  Levels: Int64;
begin
  Levels := 1;
  if (Arguments.Count >= 2) and (not TryParseInteger(Arguments[1], Levels) or (Levels < 1)) then
  begin
    CommandError(Name, Arguments[1] + ': loop count out of range');
    Exit(1);
  end;
  if LoopDepth = 0 then
    Exit(0);
  if Levels > LoopDepth then
    Levels := LoopDepth;
  LoopControl := Control;
  LoopLevels := Integer(Levels);
  Result := 0;
end;

function BuiltinBreak(Arguments: TStrings): LongInt;
begin
  Result := LoopControlBuiltin('break', Arguments, LoopControlBreak);
end;

function BuiltinContinue(Arguments: TStrings): LongInt;
begin
  Result := LoopControlBuiltin('continue', Arguments, LoopControlContinue);
end;

{ The mask as umask -S shows it: "u=rwx,g=rx,o=rx". }
function SymbolicMask(Mask: LongWord): string;
const
  ClassLetters: array[0..2] of Char = ('u', 'g', 'o');
var
  ClassIndex: Integer;
  Allowed: LongWord;
begin
  Result := '';
  for ClassIndex := 0 to 2 do
  begin
    if ClassIndex > 0 then
      Result := Result + ',';
    Result := Result + ClassLetters[ClassIndex] + '=';
    Allowed := (not Mask shr (3 * (2 - ClassIndex))) and 7;
    if (Allowed and 4) <> 0 then
      Result := Result + 'r';
    if (Allowed and 2) <> 0 then
      Result := Result + 'w';
    if (Allowed and 1) <> 0 then
      Result := Result + 'x';
  end;
end;

{ An octal mask of up to 0777; False if Text is not one. }
function ParseMask(const Text: string; out Mask: LongWord): Boolean;
var
  Position: Integer;
begin
  Mask := 0;
  Position := 1;
  while CharAt(Text, Position) in ['0'..'7'] do
  begin
    Mask := Mask * 8 + LongWord(Ord(Text[Position]) - Ord('0'));
    Inc(Position);
  end;
  Result := (Position > 1) and (Position > Length(Text)) and (Mask <= $1FF);
end;

{ umask [-S] [MODE]: shows or sets the permission bits taken away from
  new files. MODE is octal. }
function BuiltinUmask(Arguments: TStrings): LongInt;
var
  Mask: LongWord;
  Symbolic: Boolean;
  First: Integer;
begin
  Symbolic := (Arguments.Count >= 2) and (Arguments[1] = '-S');
  First := 1;
  if Symbolic then
    First := 2;
  if First < Arguments.Count then
  begin
    if not ParseMask(Arguments[First], Mask) then
    begin
      CommandError('umask', Arguments[First] + ': octal number out of range');
      Exit(1);
    end;
    KernelSetUmask(Mask);
    Exit(0);
  end;
  { Reading the mask means setting it and putting it back. }
  Mask := LongWord(KernelSetUmask(0));
  KernelSetUmask(Mask);
  if Symbolic then
    WriteStringLine(StandardOutput, SymbolicMask(Mask))
  else
    WriteStringLine(StandardOutput, '0' + IntToStr((Mask shr 6) and 7) + IntToStr((Mask shr 3) and 7) +
      IntToStr(Mask and 7));
  Result := 0;
end;

function FindBuiltin(const Name: string): TBuiltinRoutine;
begin
  if (Name = ':') or (Name = 'true') then
    Result := @BuiltinColon
  else if Name = 'false' then
    Result := @BuiltinFalse
  else if Name = 'cd' then
    Result := @BuiltinChangeDirectory
  else if Name = 'exit' then
    Result := @BuiltinExit
  else if Name = 'export' then
    Result := @BuiltinExport
  else if Name = 'unset' then
    Result := @BuiltinUnset
  else if Name = 'set' then
    Result := @BuiltinSet
  else if Name = 'shift' then
    Result := @BuiltinShift
  else if Name = 'read' then
    Result := @BuiltinRead
  else if (Name = '.') or (Name = 'source') then
    Result := @BuiltinSource
  else if Name = 'break' then
    Result := @BuiltinBreak
  else if Name = 'continue' then
    Result := @BuiltinContinue
  else if Name = 'umask' then
    Result := @BuiltinUmask
  else
  begin
    Result := FindCommandBuiltin(Name);
    if Result = nil then
      Result := FindJobBuiltin(Name);
  end;
end;

end.
