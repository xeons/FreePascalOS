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
  Tokens of the WebAssembly text format (core specification 2.0,
  section 6.2): parentheses, keywords, identifiers, numbers and strings,
  with line comments (;; to the end of the line) and nested block
  comments ((; ... ;)) skipped as white space.

  A token is a maximal run of characters up to white space, a
  parenthesis or a comment. A run made of identifier characters alone is
  an atom (a keyword when it starts with a lower case letter, an
  identifier when it starts with '$', otherwise a number to be parsed
  where one is expected); a run that is exactly one string is a string.
  Anything else (a string glued to another token, a character outside
  the grammar) is a reserved token, which the format rejects: the lexer
  raises EWasmTextError at once.

  Strings are decoded into their raw bytes: \t \n \r \" \' \\, \hh
  (two hexadecimal digits) and \u with a hexadecimal code point in
  braces (written out in UTF-8).
}
unit WasmText.Lexer;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  EWasmTextError = class(Exception);

  TTextTokenKind = (
    ttLeftParenthesis,
    ttRightParenthesis,
    ttKeyword,
    ttIdentifier,
    ttNumber,
    ttString
  );

  TTextToken = record
    Kind: TTextTokenKind;
    { The token's characters; for a string, its decoded bytes. }
    Text: AnsiString;
    Line: Integer;
  end;

  TTextTokenArray = array of TTextToken;

function TokenizeText(const Source: AnsiString): TTextTokenArray;
function IsIdentifierCharacter(Character: AnsiChar): Boolean;

implementation

function IsIdentifierCharacter(Character: AnsiChar): Boolean;
begin
  case Character of
    '0'..'9', 'A'..'Z', 'a'..'z', '!', '#', '$', '%', '&', '''', '*', '+', '-', '.', '/',
    ':', '<', '=', '>', '?', '@', '\', '^', '_', '`', '|', '~':
      Result := True;
  else
    Result := False;
  end;
end;

function HexDigitValue(Character: AnsiChar): Integer;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
    'A'..'F': Result := Ord(Character) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

procedure AppendCodePoint(var Bytes: AnsiString; CodePoint: Cardinal);
begin
  if CodePoint < $80 then
    Bytes := Bytes + AnsiChar(CodePoint)
  else if CodePoint < $800 then
    Bytes := Bytes + AnsiChar($C0 or (CodePoint shr 6)) + AnsiChar($80 or (CodePoint and $3F))
  else if CodePoint < $10000 then
    Bytes := Bytes + AnsiChar($E0 or (CodePoint shr 12)) + AnsiChar($80 or ((CodePoint shr 6) and $3F)) +
      AnsiChar($80 or (CodePoint and $3F))
  else
    Bytes := Bytes + AnsiChar($F0 or (CodePoint shr 18)) + AnsiChar($80 or ((CodePoint shr 12) and $3F)) +
      AnsiChar($80 or ((CodePoint shr 6) and $3F)) + AnsiChar($80 or (CodePoint and $3F));
end;

type
  TTextLexer = class
  private
    FSource: AnsiString;
    FPosition: Integer;
    FLine: Integer;
    FTokens: TTextTokenArray;
    FCount: Integer;
    procedure Fail(const Message: AnsiString);
    procedure SkipBlockComment;
    procedure SkipWhiteSpaceAndComments;
    function AtCommentStart: Boolean;
    function ReadString: AnsiString;
    procedure ReadRun;
    procedure Add(Kind: TTextTokenKind; const Text: AnsiString; Line: Integer);
  public
    constructor Create(const Source: AnsiString);
    function Tokenize: TTextTokenArray;
  end;

constructor TTextLexer.Create(const Source: AnsiString);
begin
  inherited Create;
  FSource := Source;
  FPosition := 1;
  FLine := 1;
end;

procedure TTextLexer.Fail(const Message: AnsiString);
begin
  raise EWasmTextError.CreateFmt('line %d: %s', [FLine, Message]);
end;

procedure TTextLexer.Add(Kind: TTextTokenKind; const Text: AnsiString; Line: Integer);
begin
  if FCount = Length(FTokens) then
    SetLength(FTokens, FCount * 2 + 64);
  FTokens[FCount].Kind := Kind;
  FTokens[FCount].Text := Text;
  FTokens[FCount].Line := Line;
  Inc(FCount);
end;

procedure TTextLexer.SkipBlockComment;
var
  Depth: Integer;
begin
  { At "(;". }
  Inc(FPosition, 2);
  Depth := 1;
  while Depth > 0 do
  begin
    if FPosition > Length(FSource) then
      Fail('unclosed comment');
    if (FSource[FPosition] = '(') and (FPosition < Length(FSource)) and (FSource[FPosition + 1] = ';') then
    begin
      Inc(Depth);
      Inc(FPosition, 2);
    end
    else if (FSource[FPosition] = ';') and (FPosition < Length(FSource)) and (FSource[FPosition + 1] = ')') then
    begin
      Dec(Depth);
      Inc(FPosition, 2);
    end
    else
    begin
      if FSource[FPosition] = #10 then
        Inc(FLine);
      Inc(FPosition);
    end;
  end;
end;

function TTextLexer.AtCommentStart: Boolean;
begin
  Result := (FPosition < Length(FSource)) and
    (((FSource[FPosition] = ';') and (FSource[FPosition + 1] = ';')) or
     ((FSource[FPosition] = '(') and (FSource[FPosition + 1] = ';')));
end;

procedure TTextLexer.SkipWhiteSpaceAndComments;
begin
  while FPosition <= Length(FSource) do
  begin
    case FSource[FPosition] of
      ' ', #9, #13:
        Inc(FPosition);
      #10:
        begin
          Inc(FLine);
          Inc(FPosition);
        end;
      ';':
        if (FPosition < Length(FSource)) and (FSource[FPosition + 1] = ';') then
        begin
          while (FPosition <= Length(FSource)) and (FSource[FPosition] <> #10) do
            Inc(FPosition);
        end
        else
          Exit;
      '(':
        if (FPosition < Length(FSource)) and (FSource[FPosition + 1] = ';') then
          SkipBlockComment
        else
          Exit;
    else
      Exit;
    end;
  end;
end;

function TTextLexer.ReadString: AnsiString;
var
  Character: AnsiChar;
  High, Low: Integer;
  CodePoint: Cardinal;
  DigitCount: Integer;
begin
  { At the opening quote. }
  Result := '';
  Inc(FPosition);
  while True do
  begin
    if FPosition > Length(FSource) then
      Fail('unclosed string');
    Character := FSource[FPosition];
    if Character = '"' then
    begin
      Inc(FPosition);
      Exit;
    end;
    if (Ord(Character) < $20) or (Ord(Character) = $7F) then
      Fail('illegal character in string');
    if Character <> '\' then
    begin
      Result := Result + Character;
      Inc(FPosition);
      Continue;
    end;
    Inc(FPosition);
    if FPosition > Length(FSource) then
      Fail('unclosed string');
    Character := FSource[FPosition];
    case Character of
      't': Result := Result + #9;
      'n': Result := Result + #10;
      'r': Result := Result + #13;
      '"': Result := Result + '"';
      '''': Result := Result + '''';
      '\': Result := Result + '\';
      'u':
        begin
          Inc(FPosition);
          if (FPosition > Length(FSource)) or (FSource[FPosition] <> '{') then
            Fail('illegal escape');
          Inc(FPosition);
          CodePoint := 0;
          DigitCount := 0;
          while (FPosition <= Length(FSource)) and (FSource[FPosition] <> '}') do
          begin
            if FSource[FPosition] = '_' then
            begin
              if (DigitCount = 0) or (FSource[FPosition - 1] = '_') then
                Fail('illegal escape');
            end
            else
            begin
              High := HexDigitValue(FSource[FPosition]);
              if High < 0 then
                Fail('illegal escape');
              CodePoint := CodePoint * 16 + Cardinal(High);
              if CodePoint >= $110000 then
                Fail('illegal escape');
              Inc(DigitCount);
            end;
            Inc(FPosition);
          end;
          if (FPosition > Length(FSource)) or (DigitCount = 0) or (FSource[FPosition - 1] = '_') then
            Fail('illegal escape');
          if (CodePoint >= $D800) and (CodePoint < $E000) then
            Fail('illegal escape');
          AppendCodePoint(Result, CodePoint);
        end;
    else
      begin
        High := HexDigitValue(Character);
        if (High < 0) or (FPosition >= Length(FSource)) then
          Fail('illegal escape');
        Low := HexDigitValue(FSource[FPosition + 1]);
        if Low < 0 then
          Fail('illegal escape');
        Result := Result + AnsiChar(High * 16 + Low);
        Inc(FPosition);
      end;
    end;
    Inc(FPosition);
  end;
end;

procedure TTextLexer.ReadRun;
var
  Start, Line, Pieces: Integer;
  HasString, HasOther: Boolean;
  StringBytes: AnsiString;
  Character: AnsiChar;
begin
  Start := FPosition;
  Line := FLine;
  Pieces := 0;
  HasString := False;
  HasOther := False;
  StringBytes := '';
  while FPosition <= Length(FSource) do
  begin
    Character := FSource[FPosition];
    if Character in [' ', #9, #10, #13, '(', ')'] then
      Break;
    if AtCommentStart then
      Break;
    if Character = '"' then
    begin
      StringBytes := ReadString;
      HasString := True;
      Inc(Pieces);
    end
    else if IsIdentifierCharacter(Character) then
    begin
      if (FPosition = Start) or (FSource[FPosition - 1] = '"') then
        Inc(Pieces);
      HasOther := True;
      Inc(FPosition);
    end
    else
      Fail('unknown operator: illegal character');
  end;
  if HasString and not HasOther and (Pieces = 1) then
    Add(ttString, StringBytes, Line)
  else if HasString then
    Fail('unknown operator: string glued to another token')
  else
  begin
    StringBytes := Copy(FSource, Start, FPosition - Start);
    case StringBytes[1] of
      '$':
        begin
          if Length(StringBytes) = 1 then
            Fail('unknown operator: empty identifier');
          Add(ttIdentifier, StringBytes, Line);
        end;
      'a'..'z':
        Add(ttKeyword, StringBytes, Line);
      '0'..'9', '+', '-':
        Add(ttNumber, StringBytes, Line);
    else
      Fail('unknown operator: reserved token ' + StringBytes);
    end;
  end;
end;

function TTextLexer.Tokenize: TTextTokenArray;
begin
  while True do
  begin
    SkipWhiteSpaceAndComments;
    if FPosition > Length(FSource) then
      Break;
    case FSource[FPosition] of
      '(':
        begin
          Add(ttLeftParenthesis, '(', FLine);
          Inc(FPosition);
        end;
      ')':
        begin
          Add(ttRightParenthesis, ')', FLine);
          Inc(FPosition);
        end;
    else
      ReadRun;
    end;
  end;
  SetLength(FTokens, FCount);
  Result := FTokens;
end;

function TokenizeText(const Source: AnsiString): TTextTokenArray;
var
  Lexer: TTextLexer;
begin
  Lexer := TTextLexer.Create(Source);
  try
    Result := Lexer.Tokenize;
  finally
    Lexer.Free;
  end;
end;

end.
