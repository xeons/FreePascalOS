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
  Finding text in lines: the next match after a position, or the one
  before it, with or without matching case.

  A match lies within one line (what is looked for holds no line feed).
  Without matching case the letters A to Z match their small letters;
  other characters match only themselves. The search does not go round
  past the end (or the start, looking up): the caller says it found
  nothing.

  Plain logic, checked on the host.
}
unit Controls.TextSearch;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Controls.TextPositions;

type
  TSearchDirection = (SearchDown, SearchUp);

  TSearchOptions = record
    MatchCase: Boolean;
    Direction: TSearchDirection;
  end;

function MakeSearchOptions(MatchCase: Boolean; Direction: TSearchDirection): TSearchOptions;
{ The first match of Pattern starting at or after From (searching down),
  or the last one ending at or before From (searching up). True and the
  match's ends in MatchStart and MatchEnd if there is one. }
function FindInLines(Lines: TStrings; const Pattern: string; const From: TTextPosition;
  const Options: TSearchOptions; out MatchStart, MatchEnd: TTextPosition): Boolean;
{ Whether Text is Pattern (as the options compare). }
function TextMatches(const Text, Pattern: string; MatchCase: Boolean): Boolean;

implementation

uses
  StrUtils;

function MakeSearchOptions(MatchCase: Boolean; Direction: TSearchDirection): TSearchOptions;
begin
  Result.MatchCase := MatchCase;
  Result.Direction := Direction;
end;

{ Text with A to Z made small (only these: bytes of other characters stay,
  so offsets do not move). }
function FoldedCase(const Text: string): string;
var
  Index: LongInt;
begin
  Result := Text;
  UniqueString(Result);
  for Index := 1 to Length(Result) do
    if Result[Index] in ['A'..'Z'] then
      Result[Index] := Chr(Ord(Result[Index]) + 32);
end;

function Prepared(const Text: string; MatchCase: Boolean): string;
begin
  if MatchCase then
    Result := Text
  else
    Result := FoldedCase(Text);
end;

function TextMatches(const Text, Pattern: string; MatchCase: Boolean): Boolean;
begin
  Result := Prepared(Text, MatchCase) = Prepared(Pattern, MatchCase);
end;

{ The byte (from 1) of the first match in Line at or after byte Start
  (from 1); 0 if none. }
function MatchFrom(const Line, Pattern: string; Start: LongInt): LongInt;
begin
  if Start > Length(Line) then
    Exit(0);
  Result := PosEx(Pattern, Line, Start);
end;

{ The byte (from 1) of the last match in Line that ends at or before byte
  Limit (bytes 1 to Limit); 0 if none. }
function LastMatchBefore(const Line, Pattern: string; Limit: LongInt): LongInt;
var
  Found: LongInt;
begin
  Result := 0;
  Found := MatchFrom(Line, Pattern, 1);
  while (Found > 0) and (Found + Length(Pattern) - 1 <= Limit) do
  begin
    Result := Found;
    Found := MatchFrom(Line, Pattern, Found + 1);
  end;
end;

function FindInLines(Lines: TStrings; const Pattern: string; const From: TTextPosition;
  const Options: TSearchOptions; out MatchStart, MatchEnd: TTextPosition): Boolean;
var
  Wanted: string;
  Line: LongInt;
  Text: string;
  Found: LongInt;
  StartByte: LongInt;
begin
  Result := False;
  MatchStart := From;
  MatchEnd := From;
  if (Pattern = '') or (Pos(#10, Pattern) > 0) or (Lines.Count = 0) then
    Exit;
  if (From.Line < 0) or (From.Line >= Lines.Count) then
    Exit;
  Wanted := Prepared(Pattern, Options.MatchCase);
  Line := From.Line;
  while (Line >= 0) and (Line < Lines.Count) do
  begin
    Text := Prepared(Lines[Line], Options.MatchCase);
    if Options.Direction = SearchDown then
    begin
      StartByte := 1;
      if Line = From.Line then
        StartByte := ByteOfColumn(Text, From.Column) + 1;
      Found := MatchFrom(Text, Wanted, StartByte);
    end
    else
    begin
      if Line = From.Line then
        Found := LastMatchBefore(Text, Wanted, ByteOfColumn(Text, From.Column))
      else
        Found := LastMatchBefore(Text, Wanted, Length(Text));
    end;
    if Found > 0 then
    begin
      MatchStart := MakePosition(Line, ColumnOfByte(Text, Found - 1));
      MatchEnd := MakePosition(Line, ColumnOfByte(Text, Found - 1 + Length(Wanted)));
      Exit(True);
    end;
    if Options.Direction = SearchDown then
      Inc(Line)
    else
      Dec(Line);
  end;
end;

end.
