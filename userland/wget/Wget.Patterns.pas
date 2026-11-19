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
  wget's accept and reject lists (-A, -R): comma separated, each a
  suffix ("jpg" takes "photo.jpg") or, when it has a wildcard (*, ?
  or [...]), a pattern the whole file name must match ("img*.png").
  Names compare with case, as GNU wget's do by default.

  A file is taken when the accept list is empty or names it, and the
  reject list does not.

  Plain Pascal (the RTL only), checked on the host by tools/WgetTest.
}
unit Wget.Patterns;

{$mode objfpc}
{$H+}

interface

type
  TNameList = array of string;

{ "jpg,png, gif" into its entries (blanks around them removed). }
function ParseNameList(const Text: string): TNameList;
{ True if Name matches an entry of List. }
function NameListMatches(const List: TNameList; const Name: string): Boolean;
{ True if the file name passes both lists. }
function FileNameAccepted(const Accept, Reject: TNameList; const Name: string): Boolean;
{ Shell style: "*" any run, "?" one character, "[abc]", "[a-z]", "[!x]". }
function WildcardMatches(const Pattern, Name: string): Boolean;

implementation

uses
  SysUtils;

function ParseNameList(const Text: string): TNameList;
var
  Entry: string;
begin
  Result := nil;
  for Entry in Text.Split([',']) do
    if Trim(Entry) <> '' then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Trim(Entry);
    end;
end;

function HasWildcard(const Entry: string): Boolean;
begin
  Result := (Pos('*', Entry) > 0) or (Pos('?', Entry) > 0) or (Pos('[', Entry) > 0);
end;

{ "[...]" at PatternIndex against Character; PatternIndex moves past
  the "]". False with PatternIndex unchanged when there is no "]". }
function MatchBracket(const Pattern: string; var PatternIndex: Integer; Character: Char;
  out Matched: Boolean): Boolean;
var
  Index: Integer;
  Negated: Boolean;
begin
  Matched := False;
  Index := PatternIndex + 1;
  Negated := (Index <= Length(Pattern)) and (Pattern[Index] in ['!', '^']);
  if Negated then
    Inc(Index);
  while (Index <= Length(Pattern)) and ((Pattern[Index] <> ']') or (Index = PatternIndex + 1 + Ord(Negated))) do
  begin
    if (Index + 2 <= Length(Pattern)) and (Pattern[Index + 1] = '-') and (Pattern[Index + 2] <> ']') then
    begin
      if (Character >= Pattern[Index]) and (Character <= Pattern[Index + 2]) then
        Matched := True;
      Inc(Index, 3);
    end
    else
    begin
      if Character = Pattern[Index] then
        Matched := True;
      Inc(Index);
    end;
  end;
  if Index > Length(Pattern) then
    Exit(False);
  if Negated then
    Matched := not Matched;
  PatternIndex := Index + 1;
  Result := True;
end;

function MatchFrom(const Pattern: string; PatternIndex: Integer; const Name: string; NameIndex: Integer): Boolean;
var
  Matched: Boolean;
begin
  while PatternIndex <= Length(Pattern) do
  begin
    case Pattern[PatternIndex] of
      '*':
        begin
          while NameIndex <= Length(Name) + 1 do
          begin
            if MatchFrom(Pattern, PatternIndex + 1, Name, NameIndex) then
              Exit(True);
            Inc(NameIndex);
          end;
          Exit(False);
        end;
      '?':
        begin
          if NameIndex > Length(Name) then
            Exit(False);
          Inc(PatternIndex);
          Inc(NameIndex);
        end;
      '[':
        begin
          if NameIndex > Length(Name) then
            Exit(False);
          if MatchBracket(Pattern, PatternIndex, Name[NameIndex], Matched) then
          begin
            if not Matched then
              Exit(False);
            Inc(NameIndex);
          end
          else
          begin
            { No "]": a plain "[". }
            if Name[NameIndex] <> '[' then
              Exit(False);
            Inc(PatternIndex);
            Inc(NameIndex);
          end;
        end;
    else
      if (NameIndex > Length(Name)) or (Pattern[PatternIndex] <> Name[NameIndex]) then
        Exit(False);
      Inc(PatternIndex);
      Inc(NameIndex);
    end;
  end;
  Result := NameIndex > Length(Name);
end;

function WildcardMatches(const Pattern, Name: string): Boolean;
begin
  Result := MatchFrom(Pattern, 1, Name, 1);
end;

function NameListMatches(const List: TNameList; const Name: string): Boolean;
var
  Entry: string;
begin
  for Entry in List do
  begin
    if HasWildcard(Entry) then
    begin
      if WildcardMatches(Entry, Name) then
        Exit(True);
    end
    else if (Length(Name) >= Length(Entry)) and (Copy(Name, Length(Name) - Length(Entry) + 1, MaxInt) = Entry) then
      Exit(True);
  end;
  Result := False;
end;

function FileNameAccepted(const Accept, Reject: TNameList; const Name: string): Boolean;
begin
  if (Length(Accept) > 0) and not NameListMatches(Accept, Name) then
    Exit(False);
  Result := not NameListMatches(Reject, Name);
end;

end.
