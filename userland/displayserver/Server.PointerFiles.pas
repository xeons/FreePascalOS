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
  The pointer's shapes from files, so they can be changed without
  building the server again.

  Each shape is a text file in /lib/pointers named after it
  (arrow.pointer, resize-horizontal.pointer, text-beam.pointer...):

    ; lines starting with a semicolon are comments
    hotspot X Y
    #
    #.#
    #..#

  After the hotspot line every line is a row of the pattern: '#' black,
  '.' white, a space or '-' clear (rows may be of any length up to 32;
  the pattern is as wide as the longest). A shape whose file is missing
  or wrong keeps the built-in one (Server.PointerShapes).
}
unit Server.PointerFiles;

{$mode objfpc}
{$H+}

interface

const
  PointerDirectory: PChar = '/lib/pointers';

{ Reads every shape's file over the built-in shape; the number read. }
function LoadPointerFiles: LongInt;

implementation

uses
  Abi.SystemCalls,
  Sys.Files,
  Sys.Text,
  Windowing.Protocol,
  Server.PointerShapes;

const
  MaximumPointerFileSize = 16384;
  PointerFileNames: array[0..PointerShapeCount - 1] of PChar = (
    'arrow', 'resize-horizontal', 'resize-vertical', 'resize-diagonal-down', 'resize-diagonal-up', 'text-beam',
    'busy');
  ClearMark = '-';
  CommentMark = ';';

{ The whole file as text, or '' if it cannot be read. }
function ReadWholeFile(const Path: string): string;
var
  Handle: Int64;
  Information: TFileInformation;
  Got: Int64;
begin
  Result := '';
  if (GetFileInformation(PChar(Path), Information) <> ErrorNone) or (Information.SizeInBytes = 0) or
     (Information.SizeInBytes > MaximumPointerFileSize) then
    Exit;
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit;
  SetLength(Result, Information.SizeInBytes);
  Got := ReadFile(Handle, @Result[1], Information.SizeInBytes);
  CloseFile(Handle);
  if Got <> Int64(Information.SizeInBytes) then
    Result := '';
end;

{ The next line of Text from Position (which moves past it), without
  its line break. }
function NextLine(const Text: string; var Position: LongInt): string;
var
  Start: LongInt;
begin
  Start := Position;
  while (Position <= Length(Text)) and (Text[Position] <> #10) do
    Inc(Position);
  Result := Copy(Text, Start, Position - Start);
  Inc(Position);
  if (Length(Result) > 0) and (Result[Length(Result)] = #13) then
    SetLength(Result, Length(Result) - 1);
end;

function LineIsBlank(const Line: string): Boolean;
var
  Column: LongInt;
begin
  for Column := 1 to Length(Line) do
    if Line[Column] <> ' ' then
      Exit(False);
  Result := True;
end;

{ "hotspot X Y". }
function ParseHotspot(const Line: string; out X, Y: LongInt): Boolean;
var
  Position: LongInt;

  function NextNumber(out Value: LongInt): Boolean;
  begin
    Value := 0;
    while (Position <= Length(Line)) and (Line[Position] = ' ') do
      Inc(Position);
    Result := (Position <= Length(Line)) and IsDigit(Line[Position]);
    while (Position <= Length(Line)) and IsDigit(Line[Position]) and (Value < MaximumPointerSize) do
    begin
      Value := Value * 10 + Ord(Line[Position]) - Ord('0');
      Inc(Position);
    end;
  end;

begin
  Result := False;
  if Copy(Line, 1, Length('hotspot ')) <> 'hotspot ' then
    Exit;
  Position := Length('hotspot ') + 1;
  Result := NextNumber(X) and NextNumber(Y);
end;

function ParsePointerFile(const Text: string; out Pattern: TPointerPattern): Boolean;
var
  Rows: array[0..MaximumPointerSize - 1] of TPointerRow;
  RowCount: LongInt;
  UsedRows: LongInt;
  Position: LongInt;
  Line: string;
  HotspotX: LongInt;
  HotspotY: LongInt;
  HotspotFound: Boolean;
  Column: LongInt;
begin
  Result := False;
  RowCount := 0;
  UsedRows := 0;
  HotspotFound := False;
  HotspotX := 0;
  HotspotY := 0;
  Position := 1;
  while Position <= Length(Text) do
  begin
    Line := NextLine(Text, Position);
    if (Length(Line) > 0) and (Line[1] = CommentMark) then
      Continue;
    if not HotspotFound then
    begin
      if Line = '' then
        Continue;
      if not ParseHotspot(Line, HotspotX, HotspotY) then
        Exit;
      HotspotFound := True;
      Continue;
    end;
    if (RowCount = MaximumPointerSize) or (Length(Line) > MaximumPointerSize) then
      Exit;
    for Column := 1 to Length(Line) do
      if Line[Column] = ClearMark then
        Line[Column] := ' ';
    Rows[RowCount] := Line;
    Inc(RowCount);
    { Blank lines at the end are not rows. }
    if not LineIsBlank(Line) then
      UsedRows := RowCount;
  end;
  if not HotspotFound or (UsedRows = 0) then
    Exit;
  Result := MakePointerPattern(Slice(Rows, UsedRows), HotspotX, HotspotY, Pattern);
end;

function LoadPointerFiles: LongInt;
var
  Shape: LongInt;
  Text: string;
  Pattern: TPointerPattern;
begin
  Result := 0;
  for Shape := 0 to PointerShapeCount - 1 do
  begin
    Text := ReadWholeFile(string(PointerDirectory) + '/' + string(PointerFileNames[Shape]) + '.pointer');
    if (Text <> '') and ParsePointerFile(Text, Pattern) then
    begin
      PointerPatterns[Shape] := Pattern;
      Inc(Result);
    end;
  end;
end;

end.
