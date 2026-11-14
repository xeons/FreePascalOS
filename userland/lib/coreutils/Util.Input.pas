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
  Input files and lists of lines.

  Many tools read "each FILE, or standard input when FILE is - or no
  FILE is given". OpenInput handles the '-' convention; the line list
  collects a whole input for tools that need to see all of it at once
  (sort, tail, tac and others).
}
unit Util.Input;

{$mode objfpc}
{$pointermath on}

interface

uses
  Sys.Streams;

type
  TLineList = record
    Items: PPChar;
    Count: Integer;
    Capacity: Integer;
    { False if the last line had no line end. }
    LastLineTerminated: Boolean;
  end;

{ Opens Path for reading ('-' is standard input). Reports the error and
  returns nil when the file cannot be opened. }
function OpenInput(Path: PChar): PInputStream;
procedure CloseInput(Stream: PInputStream);

procedure BeginLineList(out List: TLineList);
procedure AddLine(var List: TLineList; Line: PChar);
{ Appends every line of Stream to List. }
procedure ReadAllLines(Stream: PInputStream; var List: TLineList);
procedure FreeLineList(var List: TLineList);

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Util.Messages;

function OpenInput(Path: PChar): PInputStream;
var
  Handle: Int64;
  Information: TFileInformation;
begin
  if TextIsEqual(Path, '-') then
    Exit(StandardInput);
  Handle := OpenFile(Path, OpenRead);
  if Handle < 0 then
  begin
    ReportError(ErrorCodeOf(Handle), '%s', [ArgumentText(Path)]);
    Exit(nil);
  end;
  if (GetHandleInformation(Handle, Information) = ErrorNone) and (Information.Kind = KindDirectory) then
  begin
    CloseFile(Handle);
    ReportError(ErrorIsDirectory, '%s', [ArgumentText(Path)]);
    Exit(nil);
  end;
  Result := CreateInputStream(Handle);
end;

procedure CloseInput(Stream: PInputStream);
begin
  if (Stream = nil) or (Stream = StandardInput) then
    Exit;
  CloseFile(Stream^.Handle);
  DestroyInputStream(Stream);
end;

procedure BeginLineList(out List: TLineList);
begin
  List.Items := nil;
  List.Count := 0;
  List.Capacity := 0;
  List.LastLineTerminated := True;
end;

procedure AddLine(var List: TLineList; Line: PChar);
begin
  if List.Count = List.Capacity then
  begin
    if List.Capacity = 0 then
      List.Capacity := 64
    else
      List.Capacity := List.Capacity * 2;
    List.Items := PPChar(ReallocateMemory(List.Items, QWord(List.Capacity) * SizeOf(PChar)));
  end;
  List.Items[List.Count] := Line;
  Inc(List.Count);
end;

procedure ReadAllLines(Stream: PInputStream; var List: TLineList);
var
  Line: PChar;
  HadLineEnd: Boolean;
begin
  while ReadLine(Stream, Line, HadLineEnd) do
  begin
    AddLine(List, Line);
    List.LastLineTerminated := HadLineEnd;
  end;
end;

procedure FreeLineList(var List: TLineList);
var
  Index: Integer;
begin
  Index := 0;
  while Index < List.Count do
  begin
    FreeMemory(List.Items[Index]);
    Inc(Index);
  end;
  FreeMemory(List.Items);
  BeginLineList(List);
end;

end.
