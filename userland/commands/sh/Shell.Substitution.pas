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
  Command substitution: $( command ).

  The command runs in a new shell, which first gets this shell's
  variables, positional parameters and functions, as a subshell would
  have them. Its output, without the line ends at the end, replaces the
  substitution (up to a NUL in it, which would end the text anywhere
  else); its status becomes $?.
}
unit Shell.Substitution;

{$mode objfpc}
{$H+}

interface

{ Runs Command in a new shell and returns its output. }
function RunCommandSubstitution(const Command: string): string;

implementation

uses
  Abi.SystemCalls,
  Sys.Files,
  Sys.Processes,
  Shell.Text,
  Shell.Host,
  Shell.Variables,
  Shell.Functions;

const
  StatusNotFound = 127;

function RemoveTrailingLineEnds(const Text: string): string;
var
  Count: Integer;
begin
  Count := Length(Text);
  while (Count > 0) and (Text[Count] = #10) do
    Dec(Count);
  Result := Copy(Text, 1, Count);
end;

function RunCommandSubstitution(const Command: string): string;
var
  ReadHandle: Int64;
  WriteHandle: Int64;
  Script: string;
  Arguments: array[0..3] of PChar;
  Options: TProcessOptions;
  Process: Int64;
  Output: string;
begin
  if CreatePipe(ReadHandle, WriteHandle) <> ErrorNone then
    Exit('');
  Script := VariableStateScript + FunctionDefinitionsScript + Command;
  Arguments[0] := 'sh';
  Arguments[1] := '-c';
  Arguments[2] := PChar(Script);
  Arguments[3] := nil;
  DefaultProcessOptions(Options);
  Options.OutputHandle := WriteHandle;
  Process := StartProgram('/bin/sh', @Arguments[0], Options);
  CloseFile(WriteHandle);
  Output := '';
  if Process >= 0 then
  begin
    Output := ReadToEnd(ReadHandle);
    LastStatus := WaitForProgram(Process);
  end
  else
    LastStatus := StatusNotFound;
  CloseFile(ReadHandle);
  Result := TextBeforeNull(RemoveTrailingLineEnds(Output));
end;

end.
