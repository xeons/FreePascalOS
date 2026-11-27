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
  File name patterns ("globs").

    *        any run of characters
    ?        any one character
    [abc]    one of the listed characters; ranges such as [a-z];
             [!abc] or [^abc] for any character not listed
    \c       the character c itself

  ExpandPattern matches the last component of a path against the
  entries of its directory, e.g. "src/*.pas". Names starting with a dot
  only match a pattern that starts with a dot.
}
unit Shell.Patterns;

{$mode objfpc}
{$H+}

interface

uses
  Classes;

function HasPatternCharacters(const Pattern: string): Boolean;
function MatchPattern(const Pattern, Text: string): Boolean;
{ Removes the backslash escapes from a pattern. }
function UnescapePattern(const Pattern: string): string;

{ Adds every matching path to Matches, in byte order. Returns the number
  of matches. }
function ExpandPattern(const Pattern: string; Matches: TStrings): Integer;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Shell.Text;

function HasPatternCharacters(const Pattern: string): Boolean;
var
  Index: Integer;
begin
  Index := 1;
  while Index <= Length(Pattern) do
  begin
    case Pattern[Index] of
      '\':
        if Index < Length(Pattern) then
          Inc(Index);
      '*', '?', '[':
        Exit(True);
    end;
    Inc(Index);
  end;
  Result := False;
end;

{ Matches a bracket expression starting at Pattern[Position] (just after
  the '['). Returns the position after the closing ']', or 0 if the
  expression is not closed. }
function MatchBracket(const Pattern: string; Position: Integer; Character: Char;
  out Matched: Boolean): Integer;
var
  Negate: Boolean;
  First: Boolean;
  Low: Char;
  High: Char;
begin
  Matched := False;
  Negate := CharAt(Pattern, Position) in ['!', '^'];
  if Negate then
    Inc(Position);
  First := True;
  while (CharAt(Pattern, Position) <> #0) and ((CharAt(Pattern, Position) <> ']') or First) do
  begin
    First := False;
    Low := Pattern[Position];
    if (Low = '\') and (CharAt(Pattern, Position + 1) <> #0) then
    begin
      Inc(Position);
      Low := Pattern[Position];
    end;
    High := Low;
    if (CharAt(Pattern, Position + 1) = '-') and not (CharAt(Pattern, Position + 2) in [']', #0]) then
    begin
      High := Pattern[Position + 2];
      Inc(Position, 2);
    end;
    if (Character >= Low) and (Character <= High) then
      Matched := True;
    Inc(Position);
  end;
  if CharAt(Pattern, Position) <> ']' then
    Exit(0);
  if Negate then
    Matched := not Matched;
  Result := Position + 1;
end;

{ Matches Pattern from PatternIndex against Text from TextIndex. }
function MatchFrom(const Pattern: string; PatternIndex: Integer; const Text: string;
  TextIndex: Integer): Boolean;
var
  Matched: Boolean;
  AfterBracket: Integer;
begin
  while CharAt(Pattern, PatternIndex) <> #0 do
  begin
    case Pattern[PatternIndex] of
      '*':
        begin
          while CharAt(Pattern, PatternIndex) = '*' do
            Inc(PatternIndex);
          if CharAt(Pattern, PatternIndex) = #0 then
            Exit(True);
          while CharAt(Text, TextIndex) <> #0 do
          begin
            if MatchFrom(Pattern, PatternIndex, Text, TextIndex) then
              Exit(True);
            Inc(TextIndex);
          end;
          Exit(False);
        end;
      '?':
        begin
          if CharAt(Text, TextIndex) = #0 then
            Exit(False);
          Inc(PatternIndex);
          Inc(TextIndex);
        end;
      '[':
        begin
          if CharAt(Text, TextIndex) = #0 then
            Exit(False);
          AfterBracket := MatchBracket(Pattern, PatternIndex + 1, Text[TextIndex], Matched);
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
        if (Pattern[PatternIndex] = '\') and (CharAt(Pattern, PatternIndex + 1) <> #0) then
          Inc(PatternIndex);
        if Pattern[PatternIndex] <> CharAt(Text, TextIndex) then
          Exit(False);
        Inc(PatternIndex);
        Inc(TextIndex);
      end;
    end;
  end;
  Result := CharAt(Text, TextIndex) = #0;
end;

function MatchPattern(const Pattern, Text: string): Boolean;
begin
  Result := MatchFrom(Pattern, 1, Text, 1);
end;

function UnescapePattern(const Pattern: string): string;
var
  Index: Integer;
begin
  Result := '';
  Index := 1;
  while Index <= Length(Pattern) do
  begin
    if (Pattern[Index] = '\') and (Index < Length(Pattern)) then
      Inc(Index);
    Result := Result + Pattern[Index];
    Inc(Index);
  end;
end;

function CompareInByteOrder(List: TStringList; First, Second: Integer): Integer;
begin
  Result := CompareStr(List[First], List[Second]);
end;

{ The names in Directory that match NamePattern, each after Prefix. }
procedure CollectMatches(const Directory, NamePattern, Prefix: string; Found: TStrings);
var
  Handle: Int64;
  Entry: TDirectoryEntry;
  Name: string;
begin
  Handle := OpenFile(PChar(Directory), OpenRead);
  if Handle < 0 then
    Exit;
  try
    while ReadDirectoryEntry(Handle, Entry) do
    begin
      Name := string(PChar(@Entry.Name[0]));
      if (Name = '.') or (Name = '..') then
        Continue;
      if (CharAt(Name, 1) = '.') and (CharAt(NamePattern, 1) <> '.') then
        Continue;
      if MatchPattern(NamePattern, Name) then
        Found.Add(Prefix + Name);
    end;
  finally
    CloseFile(Handle);
  end;
end;

function ExpandPattern(const Pattern: string; Matches: TStrings): Integer;
var
  LastSlash: Integer;
  Directory: string;
  NamePattern: string;
  Prefix: string;
  Found: TStringList;
begin
  Result := 0;
  LastSlash := LastDelimiter('/', Pattern);
  if LastSlash > 0 then
  begin
    Prefix := UnescapePattern(Copy(Pattern, 1, LastSlash));
    NamePattern := Copy(Pattern, LastSlash + 1, MaxInt);
    if LastSlash = 1 then
      Directory := '/'
    else
      Directory := Copy(Prefix, 1, Length(Prefix) - 1);
  end
  else
  begin
    NamePattern := Pattern;
    Prefix := '';
    Directory := '.';
  end;

  { Only the last component may contain pattern characters. }
  if HasPatternCharacters(Directory) then
    Exit;

  Found := TStringList.Create;
  try
    CollectMatches(Directory, NamePattern, Prefix, Found);
    Found.CustomSort(@CompareInByteOrder);
    Matches.AddStrings(Found);
    Result := Found.Count;
  finally
    Found.Free;
  end;
end;

end.
