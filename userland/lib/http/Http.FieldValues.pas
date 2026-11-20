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
  The common pieces of field values (RFC 9110 section 5.6): comma
  separated lists (commas inside quoted strings do not split), tokens,
  quoted strings with backslash escapes, and parameters
  (name=value;name2="value") as Cache-Control, Content-Type, Alt-Svc
  and Priority use them.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.FieldValues;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  THttpParameter = record
    { Lower case. }
    Name: string;
    { Unquoted. }
    Value: string;
    HasValue: Boolean;
  end;

  THttpParameterList = array of THttpParameter;

{ The members of a comma separated list, trimmed, empty ones left out. }
function SplitFieldList(const Value: string): TStringArray;
function IsToken(const Text: string): Boolean;
{ Text as a quoted-string ("a\"b"). }
function QuoteString(const Text: string): string;
{ A quoted-string's content (escapes undone); Text unchanged if it is
  not quoted. }
function UnquoteString(const Text: string): string;
{ "a=1, b, c="x, y"" as parameters (separators ',' or ';'). }
function ParseParameters(const Value: string; Separator: Char): THttpParameterList;
function FindParameter(constref List: THttpParameterList; const Name: string; out Parameter: THttpParameter): Boolean;
{ The token before the first ";" (Content-Type's media type), lower case. }
function MediaTypeOf(const ContentType: string): string;
{ A list of tokens contains Token (case-insensitive). }
function ListHasToken(const Value, Token: string): Boolean;
{ Decimal digits only (at most 18), as RFC 9110's 1*DIGIT. }
function ParseDecimalNumber(const Text: string; out Value: Int64): Boolean;

implementation

const
  TokenCharacters = ['!', '#', '$', '%', '&', '''', '*', '+', '-', '.', '^', '_', '`', '|', '~', '0'..'9',
    'a'..'z', 'A'..'Z'];

function TrimBlanks(const Text: string): string;
var
  First, Last: Integer;
begin
  First := 1;
  Last := Length(Text);
  while (First <= Last) and (Text[First] in [' ', #9]) do
    Inc(First);
  while (Last >= First) and (Text[Last] in [' ', #9]) do
    Dec(Last);
  Result := Copy(Text, First, Last - First + 1);
end;

{ Splits on Separator outside quoted strings. }
function SplitOutsideQuotes(const Value: string; Separator: Char): TStringArray;
var
  Index, Start: Integer;
  Quoted, Escaped: Boolean;

  procedure Take(Finish: Integer);
  var
    Piece: string;
  begin
    Piece := TrimBlanks(Copy(Value, Start, Finish - Start));
    if Piece <> '' then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Piece;
    end;
  end;

begin
  Result := nil;
  Quoted := False;
  Escaped := False;
  Start := 1;
  for Index := 1 to Length(Value) do
  begin
    if Escaped then
    begin
      Escaped := False;
      Continue;
    end;
    if Quoted and (Value[Index] = '\') then
      Escaped := True
    else if Value[Index] = '"' then
      Quoted := not Quoted
    else if not Quoted and (Value[Index] = Separator) then
    begin
      Take(Index);
      Start := Index + 1;
    end;
  end;
  Take(Length(Value) + 1);
end;

function SplitFieldList(const Value: string): TStringArray;
begin
  Result := SplitOutsideQuotes(Value, ',');
end;

function IsToken(const Text: string): Boolean;
var
  Character: Char;
begin
  if Text = '' then
    Exit(False);
  for Character in Text do
    if not (Character in TokenCharacters) then
      Exit(False);
  Result := True;
end;

function QuoteString(const Text: string): string;
var
  Character: Char;
begin
  Result := '"';
  for Character in Text do
  begin
    if Character in ['"', '\'] then
      Result := Result + '\';
    Result := Result + Character;
  end;
  Result := Result + '"';
end;

function UnquoteString(const Text: string): string;
var
  Index: Integer;
begin
  if (Length(Text) < 2) or (Text[1] <> '"') or (Text[Length(Text)] <> '"') then
    Exit(Text);
  Result := '';
  Index := 2;
  while Index < Length(Text) do
  begin
    if (Text[Index] = '\') and (Index + 1 < Length(Text)) then
      Inc(Index);
    Result := Result + Text[Index];
    Inc(Index);
  end;
end;

function ParseParameters(const Value: string; Separator: Char): THttpParameterList;
var
  Piece: string;
  Equals: Integer;
  Parameter: THttpParameter;
begin
  Result := nil;
  for Piece in SplitOutsideQuotes(Value, Separator) do
  begin
    Parameter := Default(THttpParameter);
    Equals := Pos('=', Piece);
    if Equals > 0 then
    begin
      Parameter.Name := LowerCase(TrimBlanks(Copy(Piece, 1, Equals - 1)));
      Parameter.Value := UnquoteString(TrimBlanks(Copy(Piece, Equals + 1, MaxInt)));
      Parameter.HasValue := True;
    end
    else
      Parameter.Name := LowerCase(Piece);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Parameter;
  end;
end;

function FindParameter(constref List: THttpParameterList; const Name: string; out Parameter: THttpParameter): Boolean;
var
  Candidate: THttpParameter;
begin
  for Candidate in List do
    if Candidate.Name = Name then
    begin
      Parameter := Candidate;
      Exit(True);
    end;
  Parameter := Default(THttpParameter);
  Result := False;
end;

function MediaTypeOf(const ContentType: string): string;
var
  Semicolon: Integer;
begin
  Semicolon := Pos(';', ContentType);
  if Semicolon > 0 then
    Result := LowerCase(TrimBlanks(Copy(ContentType, 1, Semicolon - 1)))
  else
    Result := LowerCase(TrimBlanks(ContentType));
end;

function ListHasToken(const Value, Token: string): Boolean;
var
  Member: string;
begin
  for Member in SplitFieldList(Value) do
    if SameText(Member, Token) then
      Exit(True);
  Result := False;
end;

function ParseDecimalNumber(const Text: string; out Value: Int64): Boolean;
var
  Character: Char;
begin
  Value := 0;
  if (Text = '') or (Length(Text) > 18) then
    Exit(False);
  for Character in Text do
  begin
    if not (Character in ['0'..'9']) then
      Exit(False);
    Value := Value * 10 + (Ord(Character) - Ord('0'));
  end;
  Result := True;
end;

end.
