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
  The reference data make-font-fixtures.py writes (references.txt, one
  record a line, fields split by spaces; see the script), read into
  records the checks go through.
}
unit FontTest.References;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes;

type
  TReference = record
    Kind: string;
    Name: string;
    Fields: array of string;
  end;
  TReferences = array of TReference;

{ Every record of the file at Path. }
function ReadReferences(const Path: string): TReferences;
{ Field Index (0 after the font's name) of a record as a number. }
function NumberField(const Reference: TReference; Index: Integer): Int64;
{ The coverage of a glyph record as bytes (hex, "-" for none). }
function CoverageField(const Reference: TReference; Index: Integer): TBytes;

implementation

function ReadReferences(const Path: string): TReferences;
var
  Lines: TStringList;
  Words: TStringList;
  Index: Integer;
  Count: Integer;
  Field: Integer;
begin
  Result := nil;
  Lines := TStringList.Create;
  Words := TStringList.Create;
  try
    Lines.LoadFromFile(Path);
    Words.Delimiter := ' ';
    Words.StrictDelimiter := True;
    SetLength(Result, Lines.Count);
    Count := 0;
    for Index := 0 to Lines.Count - 1 do
    begin
      Words.DelimitedText := Lines[Index];
      if Words.Count < 2 then
        Continue;
      Result[Count].Kind := Words[0];
      Result[Count].Name := Words[1];
      SetLength(Result[Count].Fields, Words.Count - 2);
      for Field := 2 to Words.Count - 1 do
        Result[Count].Fields[Field - 2] := Words[Field];
      Inc(Count);
    end;
    SetLength(Result, Count);
  finally
    Words.Free;
    Lines.Free;
  end;
end;

function NumberField(const Reference: TReference; Index: Integer): Int64;
begin
  Result := StrToInt64(Reference.Fields[Index]);
end;

function CoverageField(const Reference: TReference; Index: Integer): TBytes;
var
  Text: string;
  Position: Integer;
begin
  Result := nil;
  Text := Reference.Fields[Index];
  if Text = '-' then
    Exit;
  SetLength(Result, Length(Text) div 2);
  for Position := 0 to High(Result) do
    Result[Position] := StrToInt('$' + Copy(Text, 2 * Position + 1, 2));
end;

end.
