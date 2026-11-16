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
  FILE is given". OpenInput handles the '-' convention; ReadLinesInto
  collects a whole input for tools that need to see all of it at once
  (sort, tail, tac and others).
}
unit Util.Input;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  Sys.Streams;

{ Opens Path for reading ('-' is standard input). Reports the error and
  returns nil when the file cannot be opened. }
function OpenInput(const Path: string): PInputStream;
procedure CloseInput(Stream: PInputStream);

{ Appends every line of Stream to Lines. Returns False if the last line
  had no line end. }
function ReadLinesInto(Stream: PInputStream; Lines: TStrings): Boolean;
{ Everything left in Stream. }
function ReadAllText(Stream: PInputStream): string;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Memory,
  Util.Messages;

function OpenInput(const Path: string): PInputStream;
var
  Handle: Int64;
  Information: TFileInformation;
begin
  if Path = '-' then
    Exit(StandardInput);
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
  begin
    ReportError(ErrorCodeOf(Handle), Path);
    Exit(nil);
  end;
  if (GetHandleInformation(Handle, Information) = ErrorNone) and (Information.Kind = KindDirectory) then
  begin
    CloseFile(Handle);
    ReportError(ErrorIsDirectory, Path);
    Exit(nil);
  end;
  Result := CreateInputStream(Handle);
end;

function ReadLinesInto(Stream: PInputStream; Lines: TStrings): Boolean;
var
  Line: string;
  HadLineEnd: Boolean;
begin
  Result := True;
  while ReadTextLine(Stream, Line, HadLineEnd) do
  begin
    Lines.Add(Line);
    Result := HadLineEnd;
  end;
end;

function ReadAllText(Stream: PInputStream): string;
var
  Buffer: array[0..4095] of Byte;
  Count: QWord;
  OldLength: SizeInt;
begin
  Result := '';
  repeat
    Count := ReadBytes(Stream, @Buffer[0], SizeOf(Buffer));
    if Count > 0 then
    begin
      OldLength := Length(Result);
      SetLength(Result, OldLength + SizeInt(Count));
      Move(Buffer[0], Result[OldLength + 1], Count);
    end;
  until Count = 0;
end;

procedure CloseInput(Stream: PInputStream);
begin
  if (Stream = nil) or (Stream = StandardInput) then
    Exit;
  CloseFile(Stream^.Handle);
  DestroyInputStream(Stream);
end;

end.
