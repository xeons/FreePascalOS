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
  objls - lists the object namespace

  objls [-l] [-R] [PATH...]

  Lists the entries of each directory PATH of the object namespace
  (default \, the root), one name per line; a directory's name ends in
  a backslash. -l adds the mode, the owner and group ids, the
  references the kernel holds and the type:

    drwxrwxrwt    0    0     3 Directory     Shared\
    -rw-rw-rw-    0    0     2 Port          display

  -R lists every directory below too, each under a "PATH:" line.
  Exit status 1 if a directory could not be listed (its error on
  standard error).
}
program ObjLs;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.NamedObjects;

var
  LongFormat: Boolean = False;
  Recursive: Boolean = False;
  ExitStatus: LongInt = 0;

function JoinPath(const Directory, Name: string): string;
begin
  if Directory = '\' then
    Result := '\' + Name
  else
    Result := Directory + '\' + Name;
end;

function EntryLine(const Entry: TObjectEntry): string;
var
  Name: string;
begin
  Name := Entry.Name;
  if Entry.IsDirectory then
    Name := Name + '\';
  if not LongFormat then
    Exit(Name);
  Result := Format('%s %4d %4d %5d %-13s %s', [ObjectModeText(Entry), Entry.OwnerId, Entry.GroupId,
    Entry.ReferenceCount, Entry.TypeName, Name]);
end;

procedure ListDirectory(const Path: string; ShowHeader: Boolean);
var
  Entries: TObjectEntryArray;
  Error: LongInt;
  Index: Integer;
begin
  Error := ListObjectDirectory(Path, Entries);
  if Error <> ErrorNone then
  begin
    WriteLn(StdErr, 'objls: ', Path, ': ', string(ErrorMessage(Error)));
    ExitStatus := 1;
    Exit;
  end;
  if ShowHeader then
    WriteLn(Path, ':');
  for Index := 0 to High(Entries) do
    WriteLn(EntryLine(Entries[Index]));
  if not Recursive then
    Exit;
  for Index := 0 to High(Entries) do
    if Entries[Index].IsDirectory then
    begin
      WriteLn;
      ListDirectory(JoinPath(Path, Entries[Index].Name), True);
    end;
end;

var
  Paths: array of string;
  Index: Integer;
  Argument: string;
  Letter: Integer;

begin
  Paths := nil;
  for Index := 1 to ParamCount do
  begin
    Argument := ParamStr(Index);
    if (Length(Argument) > 1) and (Argument[1] = '-') then
    begin
      for Letter := 2 to Length(Argument) do
        case Argument[Letter] of
          'l': LongFormat := True;
          'R': Recursive := True;
        else
          WriteLn(StdErr, 'usage: objls [-l] [-R] [PATH...]');
          Halt(2);
        end;
    end
    else
    begin
      SetLength(Paths, Length(Paths) + 1);
      Paths[High(Paths)] := Argument;
    end;
  end;
  if Length(Paths) = 0 then
  begin
    SetLength(Paths, 1);
    Paths[0] := '\';
  end;
  for Index := 0 to High(Paths) do
  begin
    if Index > 0 then
      WriteLn;
    ListDirectory(Paths[Index], Recursive or (Length(Paths) > 1));
  end;
  Halt(ExitStatus);
end.
