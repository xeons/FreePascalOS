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
  Unicode case mapping of JavaScript strings (UTF-16 that may hold lone
  surrogates): the run-time library's mapping refuses a lone surrogate
  (an exception), while String.prototype.toLowerCase and the rest leave
  it as it is. Text is mapped a run of well-formed characters at a time.
}
unit Js.CaseMapping;

{$mode objfpc}
{$H+}

interface

function JsLowerCase(const Text: UnicodeString): UnicodeString;
function JsUpperCase(const Text: UnicodeString): UnicodeString;
{ Whether the code unit is a surrogate (half of a pair, or alone). }
function IsSurrogateUnit(Code: LongWord): Boolean; inline;

implementation

uses
  Character;

function IsSurrogateUnit(Code: LongWord): Boolean;
begin
  Result := (Code >= $D800) and (Code <= $DFFF);
end;

function MapRuns(const Text: UnicodeString; Upper: Boolean): UnicodeString;
var
  Index, RunStart, Length_: Integer;
  Code, Next: Word;

  procedure FlushRun(Finish: Integer);
  var
    Run: UnicodeString;
  begin
    if Finish <= RunStart then
      Exit;
    Run := Copy(Text, RunStart, Finish - RunStart);
    if Upper then
      Result := Result + TCharacter.ToUpper(Run)
    else
      Result := Result + TCharacter.ToLower(Run);
  end;

begin
  Result := '';
  Length_ := System.Length(Text);
  RunStart := 1;
  Index := 1;
  while Index <= Length_ do
  begin
    Code := Ord(Text[Index]);
    if (Code >= $D800) and (Code <= $DBFF) and (Index < Length_) then
    begin
      Next := Ord(Text[Index + 1]);
      if (Next >= $DC00) and (Next <= $DFFF) then
      begin
        Inc(Index, 2);
        Continue;
      end;
    end;
    if IsSurrogateUnit(Code) then
    begin
      { A lone surrogate stays as it is. }
      FlushRun(Index);
      Result := Result + Text[Index];
      RunStart := Index + 1;
    end;
    Inc(Index);
  end;
  FlushRun(Length_ + 1);
end;

function JsLowerCase(const Text: UnicodeString): UnicodeString;
begin
  Result := MapRuns(Text, False);
end;

function JsUpperCase(const Text: UnicodeString): UnicodeString;
begin
  Result := MapRuns(Text, True);
end;

end.
