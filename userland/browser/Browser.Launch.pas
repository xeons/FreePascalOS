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
  Starting other programs from the browser: the file manager showing a
  downloaded file's folder (Show in Folder).
}
unit Browser.Launch;

{$mode objfpc}
{$H+}

interface

{ Starts program Name (found in PATH or /app) with Arguments, without
  waiting for it; False if it could not be started. }
function LaunchProgram(const Name: string; const Arguments: array of string): Boolean;
{ The file manager at Folder. }
function ShowFolder(const Folder: string): Boolean;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Processes,
  Sys.Objects,
  Browser.Output;

function LaunchProgram(const Name: string; const Arguments: array of string): Boolean;
var
  Path: string;
  Texts: array of string;
  Vector: array of PChar;
  Index: Integer;
  Options: TProcessOptions;
  Process: Int64;
begin
  Result := False;
  if not FindProgramPath(Name, Path) then
    Exit;
  Texts := nil;
  SetLength(Texts, Length(Arguments) + 1);
  Texts[0] := Name;
  for Index := 0 to High(Arguments) do
    Texts[Index + 1] := Arguments[Index];
  Vector := nil;
  SetLength(Vector, Length(Texts) + 1);
  for Index := 0 to High(Texts) do
    Vector[Index] := PChar(Texts[Index]);
  Vector[High(Vector)] := nil;
  DefaultProcessOptions(Options);
  Options.GroupId := GroupNew;
  Process := StartProgram(PChar(Path), @Vector[0], Options);
  if Process < 0 then
    Exit;
  CloseHandle(Process);
  Say('launched ' + Name);
  Result := True;
end;

function ShowFolder(const Folder: string): Boolean;
begin
  Result := LaunchProgram('files', [Folder]);
end;

end.
