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
  Serializing the pieces of CSS text as CSSOM says: identifiers,
  strings, URLs, numbers, and runs of tokens (CSS Syntax section 9,
  with a comment between two tokens that would otherwise run
  together).
}
unit Css.Serialization;

{$mode objfpc}
{$H+}

interface

uses
  Css.Tokens;

function SerializeIdentifier(const Name: string): string;
function SerializeString(const Text: string): string;
function SerializeUrl(const Url: string): string;
{ A number the way CSSOM serializes <number>: no exponent, at most six
  decimals, no trailing zeros, "." as the separator. }
function SerializeNumber(Value: Double): string;
function SerializeToken(const Token: TCssToken): string;
{ The tokens of Cursor's range, whitespace collapsed to one space,
  leading and trailing whitespace dropped. }
function SerializeTokens(Cursor: TCssTokenCursor): string;
function SerializeTokenArray(const Tokens: TCssTokenArray): string;

implementation

uses
  SysUtils;

function HexEscape(CodePoint: Integer): string;
begin
  Result := '\' + LowerCase(IntToHex(CodePoint, 1)) + ' ';
end;

function SerializeIdentifier(const Name: string): string;
var
  Index: Integer;
  Character: Char;
begin
  Result := '';
  if (Name = '-') then
    Exit('\-');
  for Index := 1 to Length(Name) do
  begin
    Character := Name[Index];
    if (Character in [#1..#31]) or (Character = #127) then
      Result := Result + HexEscape(Ord(Character))
    else if (Character in ['0'..'9']) and ((Index = 1) or ((Index = 2) and (Name[1] = '-'))) then
      Result := Result + HexEscape(Ord(Character))
    else if (Ord(Character) >= $80) or (Character in ['-', '_', '0'..'9', 'a'..'z', 'A'..'Z']) then
      Result := Result + Character
    else
      Result := Result + '\' + Character;
  end;
end;

function SerializeString(const Text: string): string;
var
  Index: Integer;
  Character: Char;
begin
  Result := '"';
  for Index := 1 to Length(Text) do
  begin
    Character := Text[Index];
    if (Character in [#1..#31]) or (Character = #127) then
      Result := Result + HexEscape(Ord(Character))
    else if Character in ['"', '\'] then
      Result := Result + '\' + Character
    else
      Result := Result + Character;
  end;
  Result := Result + '"';
end;

function SerializeUrl(const Url: string): string;
begin
  Result := 'url(' + SerializeString(Url) + ')';
end;

function SerializeNumber(Value: Double): string;
var
  Settings: TFormatSettings;
  Position: Integer;
begin
  if (Abs(Value) < 1E15) and (Frac(Value) = 0) then
    Exit(IntToStr(Trunc(Value)));
  Settings := DefaultFormatSettings;
  Settings.DecimalSeparator := '.';
  Settings.ThousandSeparator := #0;
  Result := FloatToStrF(Value, ffFixed, 18, 6, Settings);
  Position := Pos('.', Result);
  if Position > 0 then
  begin
    while (Length(Result) > Position) and (Result[Length(Result)] = '0') do
      SetLength(Result, Length(Result) - 1);
    if Result[Length(Result)] = '.' then
      SetLength(Result, Length(Result) - 1);
  end;
  if (Result = '-0') then
    Result := '0';
end;

{ A dimension's unit, escaped where it would read as an exponent. }
function SerializeUnit(const UnitName: string): string;
begin
  Result := SerializeIdentifier(UnitName);
  if (Length(UnitName) >= 2) and (UnitName[1] in ['e', 'E']) and
    ((UnitName[2] in ['0'..'9']) or ((UnitName[2] in ['+', '-']) and (Length(UnitName) >= 3) and
    (UnitName[3] in ['0'..'9']))) then
    Result := HexEscape(Ord(UnitName[1])) + Copy(Result, 2, Length(Result));
end;

function SerializeNumberToken(const Token: TCssToken): string;
begin
  Result := SerializeNumber(Token.Number);
  if (tfSigned in Token.Flags) and (Token.Number >= 0) then
    Result := '+' + Result;
end;

function SerializeToken(const Token: TCssToken): string;
begin
  case Token.Kind of
    tkIdent: Result := SerializeIdentifier(Token.Text);
    tkFunction: Result := SerializeIdentifier(Token.Text) + '(';
    tkAtKeyword: Result := '@' + SerializeIdentifier(Token.Text);
    tkHash:
      if tfIdHash in Token.Flags then
        Result := '#' + SerializeIdentifier(Token.Text)
      else
        Result := '#' + Token.Text;
    tkString: Result := SerializeString(Token.Text);
    tkBadString: Result := '"';
    tkUrl: Result := SerializeUrl(Token.Text);
    tkBadUrl: Result := 'url(';
    tkDelim:
      if Token.Text = '\' then
        Result := '\'#10
      else
        Result := Token.Text;
    tkNumber: Result := SerializeNumberToken(Token);
    tkPercentage: Result := SerializeNumberToken(Token) + '%';
    tkDimension: Result := SerializeNumberToken(Token) + SerializeUnit(Token.Text);
    tkWhitespace: Result := ' ';
    tkCdo: Result := '<!--';
    tkCdc: Result := '-->';
    tkColon: Result := ':';
    tkSemicolon: Result := ';';
    tkComma: Result := ',';
    tkOpenSquare: Result := '[';
    tkCloseSquare: Result := ']';
    tkOpenParen: Result := '(';
    tkCloseParen: Result := ')';
    tkOpenCurly: Result := '{';
    tkCloseCurly: Result := '}';
  else
    Result := '';
  end;
end;

type
  TPairClass = (pcOther, pcIdent, pcFunction, pcUrl, pcBadUrl, pcMinus, pcNumber, pcPercentage,
    pcDimension, pcCdc, pcOpenParen, pcAtKeyword, pcHash, pcNumberSign, pcAt, pcDot, pcPlus,
    pcSlash, pcStar, pcPercentSign);

function PairClassOf(const Token: TCssToken): TPairClass;
begin
  case Token.Kind of
    tkIdent: Result := pcIdent;
    tkFunction: Result := pcFunction;
    tkUrl: Result := pcUrl;
    tkBadUrl: Result := pcBadUrl;
    tkNumber: Result := pcNumber;
    tkPercentage: Result := pcPercentage;
    tkDimension: Result := pcDimension;
    tkCdc: Result := pcCdc;
    tkOpenParen: Result := pcOpenParen;
    tkAtKeyword: Result := pcAtKeyword;
    tkHash: Result := pcHash;
    tkDelim:
      if Token.Text = '-' then Result := pcMinus
      else if Token.Text = '#' then Result := pcNumberSign
      else if Token.Text = '@' then Result := pcAt
      else if Token.Text = '.' then Result := pcDot
      else if Token.Text = '+' then Result := pcPlus
      else if Token.Text = '/' then Result := pcSlash
      else if Token.Text = '*' then Result := pcStar
      else if Token.Text = '%' then Result := pcPercentSign
      else Result := pcOther;
  else
    Result := pcOther;
  end;
end;

function NeedsComment(Previous, Next: TPairClass): Boolean;
const
  IdentLike = [pcIdent, pcFunction, pcUrl, pcBadUrl, pcMinus, pcNumber, pcPercentage, pcDimension, pcCdc];
  NumberLike = [pcNumber, pcPercentage, pcDimension];
begin
  case Previous of
    pcIdent: Result := Next in IdentLike + [pcOpenParen];
    pcAtKeyword, pcHash, pcDimension: Result := Next in IdentLike;
    pcNumberSign, pcMinus: Result := Next in IdentLike - [pcCdc];
    pcNumber: Result := Next in [pcIdent, pcFunction, pcUrl, pcBadUrl, pcNumber, pcPercentage,
      pcDimension, pcPercentSign];
    pcAt: Result := Next in [pcIdent, pcFunction, pcUrl, pcBadUrl, pcMinus];
    pcDot, pcPlus: Result := Next in NumberLike;
    pcSlash: Result := Next = pcStar;
  else
    Result := False;
  end;
end;

function SerializeTokens(Cursor: TCssTokenCursor): string;
var
  Index, First, Last: Integer;
  Previous: TPairClass;
  PendingSpace: Boolean;
  Token: PCssToken;
begin
  Result := '';
  First := Cursor.Position;
  Last := Cursor.Stop - 1;
  while (First <= Last) and (Cursor.Tokens[First].Kind = tkWhitespace) do
    Inc(First);
  while (Last >= First) and (Cursor.Tokens[Last].Kind = tkWhitespace) do
    Dec(Last);
  Previous := pcOther;
  PendingSpace := False;
  for Index := First to Last do
  begin
    Token := @Cursor.Tokens[Index];
    if Token^.Kind = tkWhitespace then
    begin
      PendingSpace := True;
      Continue;
    end;
    if Token^.Kind = tkEof then
      Break;
    if PendingSpace then
      Result := Result + ' '
    else if (Index > First) and NeedsComment(Previous, PairClassOf(Token^)) then
      Result := Result + '/**/';
    PendingSpace := False;
    Result := Result + SerializeToken(Token^);
    Previous := PairClassOf(Token^);
  end;
end;

function SerializeTokenArray(const Tokens: TCssTokenArray): string;
begin
  Result := SerializeTokens(TCssTokenCursor.Create(Tokens));
end;

end.
