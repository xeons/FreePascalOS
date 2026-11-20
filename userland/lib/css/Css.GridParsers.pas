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
  Value routines for grid layout (CSS Grid Layout Level 2): track
  lists with line names, repeat(), minmax() and fit-content(); subgrid;
  template areas (checked to be rectangles); auto tracks; auto flow;
  grid line placement.

  Line names are bracketed lists (NewLineNames); a track list is a
  space separated list of line names, track sizes and repeat()
  functions.
}
unit Css.GridParsers;

{$mode objfpc}
{$H+}

interface

uses
  Css.Tokens, Css.Values;

function ParseTrackListValue(var Cursor: TCssTokenCursor): TCssValue;
function ParseGridTemplateAreas(var Cursor: TCssTokenCursor): TCssValue;
function ParseTrackSizes(var Cursor: TCssTokenCursor): TCssValue;
function ParseGridAutoFlow(var Cursor: TCssTokenCursor): TCssValue;
function ParseGridLine(var Cursor: TCssTokenCursor): TCssValue;
function ParseLineNames(var Cursor: TCssTokenCursor): TCssValue;
function ParseTrackSize(var Cursor: TCssTokenCursor): TCssValue;
{ A track list without auto-repeat (grid-template's rows with areas). }
function ParseExplicitTrackList(var Cursor: TCssTokenCursor): TCssValue;
{ The column count of each row of a template areas string, or -1 when invalid. }
function AreaColumnCount(const Row: string): Integer;
function AreasAreValid(Rows: TCssValue): Boolean;

implementation

uses
  SysUtils, Css.Atoms, Css.Keywords, Css.Units, Css.ValueParser;

function ParseLineNames(var Cursor: TCssTokenCursor): TCssValue;
var
  Saved: Integer;
  Token: PCssToken;
  Contents: TCssTokenCursor;
  Name: TCssValue;
begin
  Result := nil;
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  if Token^.Kind <> tkOpenSquare then
    Exit;
  Cursor.Next;
  Contents := Cursor.Contents(Token);
  Result := NewLineNames;
  repeat
    Name := ParseCustomIdent(Contents, [kwSpan, kwAuto]);
    if Name = nil then
      Break;
    Result.Add(Name);
  until False;
  if not Contents.AtEndIgnoringWhitespace then
  begin
    ReleaseValue(Result);
    Cursor.Position := Saved;
  end;
end;

function ParseTrackBreadth(var Cursor: TCssTokenCursor; AllowFlex: Boolean): TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwMinContent, kwMaxContent, kwAuto]);
  if Result = nil then
    Result := ParseLengthPercentage(Cursor, True);
  if (Result = nil) and AllowFlex then
    Result := ParseDimension(Cursor, ucFlex, False, True, False);
end;

function ParseFunctionArguments(var Cursor: TCssTokenCursor; const Name: string; out Contents: TCssTokenCursor): Boolean;
var
  Saved: Integer;
  Token: PCssToken;
begin
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  Result := (Token^.Kind = tkFunction) and AsciiSameText(Token^.Text, Name);
  if Result then
  begin
    Cursor.Next;
    Contents := Cursor.Contents(Token);
  end
  else
    Cursor.Position := Saved;
end;

function ParseTrackSize(var Cursor: TCssTokenCursor): TCssValue;
var
  Saved: Integer;
  Contents: TCssTokenCursor;
  Minimum, Maximum: TCssValue;
begin
  Result := ParseTrackBreadth(Cursor, True);
  if Result <> nil then
    Exit;
  Saved := Cursor.Position;
  if ParseFunctionArguments(Cursor, 'minmax', Contents) then
  begin
    Minimum := ParseTrackBreadth(Contents, False);
    if (Minimum <> nil) and SkipComma(Contents) then
    begin
      Maximum := ParseTrackBreadth(Contents, True);
      if (Maximum <> nil) and Contents.AtEndIgnoringWhitespace then
      begin
        Result := NewFunction('minmax');
        Result.Add(Minimum);
        Result.Add(Maximum);
        Exit;
      end;
      ReleaseValue(Maximum);
    end;
    ReleaseValue(Minimum);
    Cursor.Position := Saved;
    Exit;
  end;
  if ParseFunctionArguments(Cursor, 'fit-content', Contents) then
  begin
    Minimum := ParseLengthPercentage(Contents, True);
    if (Minimum <> nil) and Contents.AtEndIgnoringWhitespace then
    begin
      Result := NewFunction('fit-content');
      Result.Add(Minimum);
      Exit;
    end;
    ReleaseValue(Minimum);
    Cursor.Position := Saved;
  end;
end;

{ repeat( <count> , [ <line-names>? <track-size> ]+ <line-names>? ) }
function ParseRepeat(var Cursor: TCssTokenCursor; out IsAuto: Boolean): TCssValue;
var
  Saved: Integer;
  Contents: TCssTokenCursor;
  Count, Tracks, Item: TCssValue;
  Sizes: Integer;
begin
  Result := nil;
  IsAuto := False;
  Saved := Cursor.Position;
  if not ParseFunctionArguments(Cursor, 'repeat', Contents) then
    Exit;
  Count := ParseKeyword(Contents, [kwAutoFill, kwAutoFit]);
  if Count <> nil then
    IsAuto := True
  else
    Count := ParseInteger(Contents, 1);
  if (Count = nil) or not SkipComma(Contents) then
  begin
    ReleaseValue(Count);
    Cursor.Position := Saved;
    Exit;
  end;
  Tracks := NewList(lsSpace);
  Sizes := 0;
  repeat
    Item := ParseLineNames(Contents);
    if Item = nil then
    begin
      Item := ParseTrackSize(Contents);
      if Item <> nil then
        Inc(Sizes);
    end;
    if Item = nil then
      Break;
    Tracks.Add(Item);
  until False;
  if (Sizes = 0) or not Contents.AtEndIgnoringWhitespace then
  begin
    Count.Release;
    Tracks.Release;
    Cursor.Position := Saved;
    Exit;
  end;
  Result := NewFunction('repeat');
  Result.Add(Count);
  Result.Add(Tracks);
end;

function ParseTrackListItems(var Cursor: TCssTokenCursor; AllowAutoRepeat: Boolean): TCssValue;
var
  Item: TCssValue;
  IsAuto, SawAuto: Boolean;
  Sizes: Integer;
begin
  Result := NewList(lsSpace);
  SawAuto := False;
  Sizes := 0;
  repeat
    Item := ParseLineNames(Cursor);
    if Item = nil then
    begin
      Item := ParseRepeat(Cursor, IsAuto);
      if Item <> nil then
      begin
        if IsAuto and (SawAuto or not AllowAutoRepeat) then
        begin
          Item.Release;
          ReleaseValue(Result);
          Exit;
        end;
        SawAuto := SawAuto or IsAuto;
        Inc(Sizes);
      end;
    end;
    if Item = nil then
    begin
      Item := ParseTrackSize(Cursor);
      if Item <> nil then
        Inc(Sizes);
    end;
    if Item = nil then
      Break;
    Result.Add(Item);
  until False;
  if Sizes = 0 then
    ReleaseValue(Result);
end;

function ParseExplicitTrackList(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseTrackListItems(Cursor, False);
end;

function ParseTrackListValue(var Cursor: TCssTokenCursor): TCssValue;
var
  Names: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNone, kwMasonry]);
  if Result <> nil then
    Exit;
  Result := ParseKeyword(Cursor, [kwSubgrid]);
  if Result <> nil then
  begin
    Result := NewListOf(lsSpace, [Result]);
    repeat
      Names := ParseLineNames(Cursor);
      if Names = nil then
        Break;
      Result.Add(Names);
    until False;
    if Result.Count = 1 then
    begin
      Names := Result.Items[0].AddRef;
      Result.Release;
      Result := Names;
    end;
    Exit;
  end;
  Result := ParseTrackListItems(Cursor, True);
end;

function IsAreaNameCharacter(Character: Char): Boolean;
begin
  Result := (Character in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) or (Ord(Character) >= $80);
end;

{ The cell tokens of a row: names, '.' sequences (null cells). }
function AreaCells(const Row: string): TStringArray;
var
  Position, Start: Integer;
begin
  Result := nil;
  Position := 1;
  while Position <= Length(Row) do
  begin
    if Row[Position] in [' ', #9, #10] then
    begin
      Inc(Position);
      Continue;
    end;
    Start := Position;
    if Row[Position] = '.' then
    begin
      while (Position <= Length(Row)) and (Row[Position] = '.') do
        Inc(Position);
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := '.';
    end
    else if IsAreaNameCharacter(Row[Position]) then
    begin
      while (Position <= Length(Row)) and IsAreaNameCharacter(Row[Position]) do
        Inc(Position);
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(Row, Start, Position - Start);
    end
    else
    begin
      { A trash token makes the declaration invalid. }
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := #0;
      Exit;
    end;
  end;
end;

function AreaColumnCount(const Row: string): Integer;
var
  Cells: TStringArray;
  Index: Integer;
begin
  Cells := AreaCells(Row);
  for Index := 0 to High(Cells) do
    if Cells[Index] = #0 then
      Exit(-1);
  Result := Length(Cells);
end;

function AreasAreValid(Rows: TCssValue): Boolean;
var
  Grid: array of TStringArray;
  RowIndex, Column, Columns, Top, Left, Bottom, Right, Y, X: Integer;
  Name: string;
  Seen: array of string;
  SeenIndex: Integer;
  Duplicate: Boolean;
begin
  Result := False;
  SetLength(Grid, Rows.Count);
  Columns := -1;
  for RowIndex := 0 to Rows.Count - 1 do
  begin
    Grid[RowIndex] := AreaCells(Rows.Items[RowIndex].Text);
    if (Length(Grid[RowIndex]) = 0) or (AreaColumnCount(Rows.Items[RowIndex].Text) < 0) then
      Exit;
    if (Columns >= 0) and (Length(Grid[RowIndex]) <> Columns) then
      Exit;
    Columns := Length(Grid[RowIndex]);
  end;
  { Every named area must fill exactly its bounding rectangle. }
  Seen := nil;
  for RowIndex := 0 to High(Grid) do
    for Column := 0 to Columns - 1 do
    begin
      Name := Grid[RowIndex][Column];
      if Name = '.' then
        Continue;
      Duplicate := False;
      for SeenIndex := 0 to High(Seen) do
        if Seen[SeenIndex] = Name then
          Duplicate := True;
      if Duplicate then
        Continue;
      SetLength(Seen, Length(Seen) + 1);
      Seen[High(Seen)] := Name;
      Top := RowIndex;
      Left := Column;
      Right := Column;
      while (Right + 1 < Columns) and (Grid[RowIndex][Right + 1] = Name) do
        Inc(Right);
      Bottom := RowIndex;
      while (Bottom + 1 <= High(Grid)) and (Grid[Bottom + 1][Left] = Name) do
        Inc(Bottom);
      for Y := 0 to High(Grid) do
        for X := 0 to Columns - 1 do
          if (Grid[Y][X] = Name) <> ((Y >= Top) and (Y <= Bottom) and (X >= Left) and (X <= Right)) then
            Exit;
    end;
  Result := True;
end;

function ParseGridTemplateAreas(var Cursor: TCssTokenCursor): TCssValue;
var
  Row: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNone]);
  if Result <> nil then
    Exit;
  Result := NewList(lsSpace);
  repeat
    Row := ParseStringValue(Cursor);
    if Row = nil then
      Break;
    Result.Add(Row);
  until False;
  if (Result.Count = 0) or not AreasAreValid(Result) then
    ReleaseValue(Result);
end;

function ParseTrackSizes(var Cursor: TCssTokenCursor): TCssValue;
var
  Item: TCssValue;
begin
  Result := NewList(lsSpace);
  repeat
    Item := ParseTrackSize(Cursor);
    if Item = nil then
      Break;
    Result.Add(Item);
  until False;
  if Result.Count = 0 then
    ReleaseValue(Result)
  else if Result.Count = 1 then
  begin
    Item := Result.Items[0].AddRef;
    Result.Release;
    Result := Item;
  end;
end;

function ParseGridAutoFlow(var Cursor: TCssTokenCursor): TCssValue;
var
  Direction, Dense: TCssValue;
begin
  Direction := ParseKeyword(Cursor, [kwRow, kwColumn]);
  Dense := ParseKeyword(Cursor, [kwDense]);
  if (Direction = nil) and (Dense <> nil) then
    Direction := ParseKeyword(Cursor, [kwRow, kwColumn]);
  if Dense = nil then
    Exit(Direction);
  if (Direction = nil) or Direction.IsKeyword(kwRow) then
  begin
    ReleaseValue(Direction);
    Exit(Dense);
  end;
  Result := NewListOf(lsSpace, [Direction, Dense]);
end;

function ParseGridLine(var Cursor: TCssTokenCursor): TCssValue;
var
  Span, Number, Name: TCssValue;
  Index: Integer;
begin
  Result := ParseKeyword(Cursor, [kwAuto]);
  if Result <> nil then
    Exit;
  Span := nil;
  Number := nil;
  Name := nil;
  for Index := 1 to 3 do
  begin
    if Span = nil then
    begin
      Span := ParseKeyword(Cursor, [kwSpan]);
      if Span <> nil then
        Continue;
    end;
    if Number = nil then
    begin
      Number := ParseInteger(Cursor);
      if Number <> nil then
        Continue;
    end;
    if Name = nil then
    begin
      Name := ParseCustomIdent(Cursor, [kwSpan, kwAuto]);
      if Name <> nil then
        Continue;
    end;
    Break;
  end;
  { An integer may not be 0; span needs a positive integer or a name. }
  if ((Number <> nil) and (Number.Kind = vkInteger) and ((Number.Number = 0) or
    ((Span <> nil) and (Number.Number < 0)))) or ((Span <> nil) and (Number = nil) and (Name = nil)) or
    ((Span = nil) and (Number = nil) and (Name = nil)) then
  begin
    ReleaseValue(Span);
    ReleaseValue(Number);
    ReleaseValue(Name);
    Exit;
  end;
  if (Span = nil) and (Number = nil) then
    Exit(Name);
  if (Span = nil) and (Name = nil) then
    Exit(Number);
  Result := NewListOf(lsSpace, [Span, Number, Name]);
end;

end.
