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
{$pointermath on}

interface

function MatchWildcards(Pattern, Text: PChar; IgnoreCase: Boolean): Boolean; overload;
function MatchWildcards(const Pattern, Text: string; IgnoreCase: Boolean): Boolean; overload;

implementation

uses
  Sys.Text;

function SameCharacter(First, Second: Char; IgnoreCase: Boolean): Boolean;
begin
  if IgnoreCase then
    Result := ToLowerCase(First) = ToLowerCase(Second)
  else
    Result := First = Second;
end;

function InRange(Character, Low, High: Char): Boolean;
begin
  Result := (Character >= Low) and (Character <= High);
end;

{ Matches a bracket expression (Pattern is just after '['). Returns the
  position after ']', or nil if the bracket is not closed. }
function MatchBracket(Pattern: PChar; Character: Char; IgnoreCase: Boolean; out Matched: Boolean): PChar;
var
  Negate: Boolean;
  First: Boolean;
  Low: Char;
  High: Char;
begin
  Matched := False;
  Negate := (Pattern^ = '!') or (Pattern^ = '^');
  if Negate then
    Inc(Pattern);
  First := True;
  while (Pattern^ <> #0) and ((Pattern^ <> ']') or First) do
  begin
    First := False;
    Low := Pattern^;
    if (Low = '\') and (Pattern[1] <> #0) then
    begin
      Inc(Pattern);
      Low := Pattern^;
    end;
    High := Low;
    if (Pattern[1] = '-') and (Pattern[2] <> ']') and (Pattern[2] <> #0) then
    begin
      High := Pattern[2];
      Inc(Pattern, 2);
    end;
    if InRange(Character, Low, High) then
      Matched := True
    else if IgnoreCase and (InRange(ToLowerCase(Character), Low, High) or
      InRange(ToUpperCase(Character), Low, High)) then
      Matched := True;
    Inc(Pattern);
  end;
  if Pattern^ <> ']' then
    Exit(nil);
  if Negate then
    Matched := not Matched;
  Result := Pattern + 1;
end;

function MatchWildcards(Pattern, Text: PChar; IgnoreCase: Boolean): Boolean;
var
  Matched: Boolean;
  AfterBracket: PChar;
begin
  while Pattern^ <> #0 do
  begin
    case Pattern^ of
      '*':
        begin
          while Pattern^ = '*' do
            Inc(Pattern);
          if Pattern^ = #0 then
            Exit(True);
          while Text^ <> #0 do
          begin
            if MatchWildcards(Pattern, Text, IgnoreCase) then
              Exit(True);
            Inc(Text);
          end;
          Exit(False);
        end;
      '?':
        begin
          if Text^ = #0 then
            Exit(False);
          Inc(Pattern);
          Inc(Text);
        end;
      '[':
        begin
          if Text^ = #0 then
            Exit(False);
          AfterBracket := MatchBracket(Pattern + 1, Text^, IgnoreCase, Matched);
          if AfterBracket = nil then
          begin
            { An unclosed '[' is an ordinary character. }
            if Text^ <> '[' then
              Exit(False);
            Inc(Pattern);
          end
          else
          begin
            if not Matched then
              Exit(False);
            Pattern := AfterBracket;
          end;
          Inc(Text);
        end;
    else
      begin
        if (Pattern^ = '\') and (Pattern[1] <> #0) then
          Inc(Pattern);
        if not SameCharacter(Pattern^, Text^, IgnoreCase) then
          Exit(False);
        Inc(Pattern);
        Inc(Text);
      end;
    end;
  end;
  Result := Text^ = #0;
end;

function MatchWildcards(const Pattern, Text: string; IgnoreCase: Boolean): Boolean;
begin
  Result := MatchWildcards(PChar(Pattern), PChar(Text), IgnoreCase);
end;

end.
