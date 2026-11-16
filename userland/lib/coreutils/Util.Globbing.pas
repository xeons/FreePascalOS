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
  Shell style wildcard matching (fnmatch), as find -name and -path use it.

    *        any run of characters (including '/', as find -path wants)
    ?        any one character
    [abc]    one of the listed characters; ranges such as [a-z];
             [!abc] or [^abc] for any character not listed
    \c       the character c itself
}
unit Util.Globbing;

{$mode objfpc}{$H+}

interface

function MatchWildcards(const Pattern, Text: string; IgnoreCase: Boolean): Boolean;

implementation

uses
  SysUtils;

{ The character at Index (from 1), #0 past the end. }
function CharacterAt(const Text: string; Index: Integer): Char;
begin
  if Index <= Length(Text) then
    Result := Text[Index]
  else
    Result := #0;
end;

function SameCharacter(First, Second: Char; IgnoreCase: Boolean): Boolean;
begin
  if IgnoreCase then
    Result := LowerCase(First) = LowerCase(Second)
  else
    Result := First = Second;
end;

function InRange(Character, Low, High: Char): Boolean;
begin
  Result := (Character >= Low) and (Character <= High);
end;

{ Matches a bracket expression starting at Index (just after '[').
  Returns the index after ']', or 0 if the bracket is not closed. }
function MatchBracket(const Pattern: string; Index: Integer; Character: Char; IgnoreCase: Boolean;
  out Matched: Boolean): Integer;
var
  Negate: Boolean;
  First: Boolean;
  Low: Char;
  High: Char;
begin
  Matched := False;
  Negate := CharacterAt(Pattern, Index) in ['!', '^'];
  if Negate then
    Inc(Index);
  First := True;
  while (Index <= Length(Pattern)) and ((Pattern[Index] <> ']') or First) do
  begin
    First := False;
    Low := Pattern[Index];
    if (Low = '\') and (Index < Length(Pattern)) then
    begin
      Inc(Index);
      Low := Pattern[Index];
    end;
    High := Low;
    if (CharacterAt(Pattern, Index + 1) = '-') and not (CharacterAt(Pattern, Index + 2) in [']', #0]) then
    begin
      High := Pattern[Index + 2];
      Inc(Index, 2);
    end;
    if InRange(Character, Low, High) then
      Matched := True
    else if IgnoreCase and (InRange(LowerCase(Character), Low, High) or
      InRange(UpCase(Character), Low, High)) then
      Matched := True;
    Inc(Index);
  end;
  if CharacterAt(Pattern, Index) <> ']' then
    Exit(0);
  if Negate then
    Matched := not Matched;
  Result := Index + 1;
end;

function MatchFrom(const Pattern, Text: string; PatternIndex, TextIndex: Integer; IgnoreCase: Boolean): Boolean;
var
  Matched: Boolean;
  AfterBracket: Integer;
begin
  while PatternIndex <= Length(Pattern) do
  begin
    case Pattern[PatternIndex] of
      '*':
        begin
          while CharacterAt(Pattern, PatternIndex) = '*' do
            Inc(PatternIndex);
          if PatternIndex > Length(Pattern) then
            Exit(True);
          while TextIndex <= Length(Text) do
          begin
            if MatchFrom(Pattern, Text, PatternIndex, TextIndex, IgnoreCase) then
              Exit(True);
            Inc(TextIndex);
          end;
          Exit(False);
        end;
      '?':
        begin
          if TextIndex > Length(Text) then
            Exit(False);
          Inc(PatternIndex);
          Inc(TextIndex);
        end;
      '[':
        begin
          if TextIndex > Length(Text) then
            Exit(False);
          AfterBracket := MatchBracket(Pattern, PatternIndex + 1, Text[TextIndex], IgnoreCase, Matched);
          if AfterBracket = 0 then
          begin
            { An unclosed '[' is an ordinary character. }
            if Text[TextIndex] <> '[' then
              Exit(False);
            Inc(PatternIndex);
          end
          else
          begin
            if not Matched then
              Exit(False);
            PatternIndex := AfterBracket;
          end;
          Inc(TextIndex);
        end;
    else
      begin
        if (Pattern[PatternIndex] = '\') and (PatternIndex < Length(Pattern)) then
          Inc(PatternIndex);
        if not SameCharacter(Pattern[PatternIndex], CharacterAt(Text, TextIndex), IgnoreCase) then
          Exit(False);
        Inc(PatternIndex);
        Inc(TextIndex);
      end;
    end;
  end;
  Result := TextIndex > Length(Text);
end;

function MatchWildcards(const Pattern, Text: string; IgnoreCase: Boolean): Boolean;
begin
  Result := MatchFrom(Pattern, Text, 1, 1, IgnoreCase);
end;

end.
