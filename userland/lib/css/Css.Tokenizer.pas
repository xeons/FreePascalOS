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
  The tokenizer of CSS Syntax Module Level 3 (section 4), on UTF-8.

  The input is preprocessed first (CR LF, CR and FF become LF; NUL
  becomes U+FFFD). Every byte of 0x80 and above is part of a non-ASCII
  code point, and all of those are ident code points, so the
  tokenizer classifies bytes and copies non-ASCII sequences whole.
  Escapes are decoded to UTF-8.
}
unit Css.Tokenizer;

{$mode objfpc}
{$H+}

interface

uses
  Css.Tokens;

{ The tokens of Source, ending with an EOF token, blocks matched. }
function TokenizeCss(const Source: string): TCssTokenArray;
{ The CSS preprocessing of Source (newlines and NUL). }
function PreprocessCss(const Source: string): string;
{ U+FFFD in UTF-8. }
function EncodeUtf8(CodePoint: LongWord): string;

implementation

const
  ReplacementCharacter = #$EF#$BF#$BD;

type
  TTokenizer = record
    Input: string;
    Length: Integer;
    { 1-based index of the next byte. }
    Position: Integer;
    Tokens: TCssTokenArray;
    Count: Integer;
  end;

function EncodeUtf8(CodePoint: LongWord): string;
begin
  if (CodePoint = 0) or ((CodePoint >= $D800) and (CodePoint <= $DFFF)) or (CodePoint > $10FFFF) then
    Exit(ReplacementCharacter);
  if CodePoint < $80 then
    Result := Chr(CodePoint)
  else if CodePoint < $800 then
    Result := Chr($C0 or (CodePoint shr 6)) + Chr($80 or (CodePoint and $3F))
  else if CodePoint < $10000 then
    Result := Chr($E0 or (CodePoint shr 12)) + Chr($80 or ((CodePoint shr 6) and $3F)) +
      Chr($80 or (CodePoint and $3F))
  else
    Result := Chr($F0 or (CodePoint shr 18)) + Chr($80 or ((CodePoint shr 12) and $3F)) +
      Chr($80 or ((CodePoint shr 6) and $3F)) + Chr($80 or (CodePoint and $3F));
end;

function PreprocessCss(const Source: string): string;
var
  Index, Count: Integer;
  NeedsWork: Boolean;
  Character: Char;
begin
  NeedsWork := False;
  for Index := 1 to Length(Source) do
    if Source[Index] in [#0, #12, #13] then
    begin
      NeedsWork := True;
      Break;
    end;
  if not NeedsWork then
    Exit(Source);
  Result := '';
  SetLength(Result, Length(Source) * 3);
  Count := 0;
  Index := 1;
  while Index <= Length(Source) do
  begin
    Character := Source[Index];
    case Character of
      #13:
        begin
          Inc(Count);
          Result[Count] := #10;
          if (Index < Length(Source)) and (Source[Index + 1] = #10) then
            Inc(Index);
        end;
      #12:
        begin
          Inc(Count);
          Result[Count] := #10;
        end;
      #0:
        begin
          Result[Count + 1] := #$EF;
          Result[Count + 2] := #$BF;
          Result[Count + 3] := #$BD;
          Inc(Count, 3);
        end;
    else
      Inc(Count);
      Result[Count] := Character;
    end;
    Inc(Index);
  end;
  SetLength(Result, Count);
end;

function IsNameStart(Character: Char): Boolean; inline;
begin
  Result := (Character in ['a'..'z', 'A'..'Z', '_']) or (Ord(Character) >= $80);
end;

function IsNameCharacter(Character: Char): Boolean; inline;
begin
  Result := (Character in ['a'..'z', 'A'..'Z', '_', '0'..'9', '-']) or (Ord(Character) >= $80);
end;

function IsHexDigit(Character: Char): Boolean; inline;
begin
  Result := Character in ['0'..'9', 'a'..'f', 'A'..'F'];
end;

function HexValue(Character: Char): LongWord;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
  else
    Result := Ord(Character) - Ord('A') + 10;
  end;
end;

function IsWhitespace(Character: Char): Boolean; inline;
begin
  Result := Character in [#9, #10, ' '];
end;

function IsNonPrintable(Character: Char): Boolean; inline;
begin
  Result := (Character in [#0..#8, #11, #14..#31]) or (Character = #127);
end;

{ The byte at Position + Offset, #0 past the end (NUL never survives
  preprocessing, so it marks EOF). }
function At(const State: TTokenizer; Offset: Integer): Char; inline;
var
  Index: Integer;
begin
  Index := State.Position + Offset;
  if (Index >= 1) and (Index <= State.Length) then
    Result := State.Input[Index]
  else
    Result := #0;
end;

function IsValidEscape(First, Second: Char): Boolean; inline;
begin
  Result := (First = '\') and (Second <> #10) and (Second <> #0);
end;

function StartsIdentSequence(First, Second, Third: Char): Boolean;
begin
  if First = '-' then
    Result := IsNameStart(Second) or (Second = '-') or IsValidEscape(Second, Third)
  else if IsNameStart(First) then
    Result := True
  else if First = '\' then
    Result := IsValidEscape(First, Second)
  else
    Result := False;
end;

function StartsNumber(First, Second, Third: Char): Boolean;
begin
  if First in ['+', '-'] then
  begin
    if Second in ['0'..'9'] then
      Result := True
    else
      Result := (Second = '.') and (Third in ['0'..'9']);
  end
  else if First = '.' then
    Result := Second in ['0'..'9']
  else
    Result := First in ['0'..'9'];
end;

{ Consumes an escaped code point; the backslash is already consumed. }
function ConsumeEscape(var State: TTokenizer): string;
var
  Value: LongWord;
  Digits: Integer;
  Character: Char;
  Lead: Byte;
  SequenceLength: Integer;
begin
  Character := At(State, 0);
  if Character = #0 then
    Exit(ReplacementCharacter);
  if IsHexDigit(Character) then
  begin
    Value := 0;
    Digits := 0;
    while (Digits < 6) and IsHexDigit(At(State, 0)) do
    begin
      Value := Value * 16 + HexValue(At(State, 0));
      Inc(State.Position);
      Inc(Digits);
    end;
    if IsWhitespace(At(State, 0)) then
      Inc(State.Position);
    Exit(EncodeUtf8(Value));
  end;
  { Any other code point stands for itself; copy a UTF-8 sequence whole. }
  Lead := Ord(Character);
  if Lead >= $F0 then
    SequenceLength := 4
  else if Lead >= $E0 then
    SequenceLength := 3
  else if Lead >= $C0 then
    SequenceLength := 2
  else
    SequenceLength := 1;
  Result := Copy(State.Input, State.Position, SequenceLength);
  Inc(State.Position, SequenceLength);
end;

function ConsumeIdentSequence(var State: TTokenizer): string;
var
  Start: Integer;
begin
  Result := '';
  repeat
    Start := State.Position;
    while IsNameCharacter(At(State, 0)) do
      Inc(State.Position);
    if State.Position > Start then
      Result := Result + Copy(State.Input, Start, State.Position - Start);
    if IsValidEscape(At(State, 0), At(State, 1)) then
    begin
      Inc(State.Position);
      Result := Result + ConsumeEscape(State);
    end
    else
      Break;
  until False;
end;

function AddToken(var State: TTokenizer; Kind: TCssTokenKind; Start: Integer): PCssToken;
begin
  if State.Count >= Length(State.Tokens) then
    SetLength(State.Tokens, State.Count * 2 + 64);
  Result := @State.Tokens[State.Count];
  Inc(State.Count);
  Result^.Kind := Kind;
  Result^.Flags := [];
  Result^.Match := -1;
  Result^.Position := Start - 1;
  Result^.Text := '';
  Result^.Number := 0;
end;

procedure ConsumeNumber(var State: TTokenizer; out Value: Double; out Flags: TCssTokenFlags);
var
  Sign, ExponentSign: Integer;
  IntegerPart, FractionPart, Scale: Double;
  Exponent: Integer;
begin
  Flags := [tfInteger];
  Sign := 1;
  if At(State, 0) in ['+', '-'] then
  begin
    if At(State, 0) = '-' then
      Sign := -1;
    Include(Flags, tfSigned);
    Inc(State.Position);
  end;
  IntegerPart := 0;
  while At(State, 0) in ['0'..'9'] do
  begin
    IntegerPart := IntegerPart * 10 + (Ord(At(State, 0)) - Ord('0'));
    Inc(State.Position);
  end;
  FractionPart := 0;
  if (At(State, 0) = '.') and (At(State, 1) in ['0'..'9']) then
  begin
    Exclude(Flags, tfInteger);
    Inc(State.Position);
    Scale := 0.1;
    while At(State, 0) in ['0'..'9'] do
    begin
      FractionPart := FractionPart + (Ord(At(State, 0)) - Ord('0')) * Scale;
      Scale := Scale / 10;
      Inc(State.Position);
    end;
  end;
  Exponent := 0;
  ExponentSign := 1;
  if (At(State, 0) in ['e', 'E']) and ((At(State, 1) in ['0'..'9']) or
    ((At(State, 1) in ['+', '-']) and (At(State, 2) in ['0'..'9']))) then
  begin
    Exclude(Flags, tfInteger);
    Inc(State.Position);
    if At(State, 0) in ['+', '-'] then
    begin
      if At(State, 0) = '-' then
        ExponentSign := -1;
      Inc(State.Position);
    end;
    while At(State, 0) in ['0'..'9'] do
    begin
      if Exponent < 10000 then
        Exponent := Exponent * 10 + (Ord(At(State, 0)) - Ord('0'));
      Inc(State.Position);
    end;
  end;
  Value := Sign * (IntegerPart + FractionPart);
  if Exponent <> 0 then
  begin
    if Exponent > 400 then
      Exponent := 400;
    Scale := 1;
    while Exponent > 0 do
    begin
      Scale := Scale * 10;
      Dec(Exponent);
    end;
    if ExponentSign > 0 then
      Value := Value * Scale
    else
      Value := Value / Scale;
  end;
end;

procedure ConsumeNumeric(var State: TTokenizer);
var
  Start: Integer;
  Value: Double;
  Flags: TCssTokenFlags;
  Token: PCssToken;
  UnitName: string;
begin
  Start := State.Position;
  ConsumeNumber(State, Value, Flags);
  if StartsIdentSequence(At(State, 0), At(State, 1), At(State, 2)) then
  begin
    UnitName := ConsumeIdentSequence(State);
    Token := AddToken(State, tkDimension, Start);
    Token^.Text := UnitName;
  end
  else if At(State, 0) = '%' then
  begin
    Inc(State.Position);
    Token := AddToken(State, tkPercentage, Start);
  end
  else
    Token := AddToken(State, tkNumber, Start);
  Token^.Number := Value;
  Token^.Flags := Flags;
end;

{ Consumes what is left of a bad url, to its ')' or EOF. }
procedure ConsumeBadUrlRemnants(var State: TTokenizer);
var
  Character: Char;
begin
  repeat
    Character := At(State, 0);
    if Character = #0 then
      Exit;
    Inc(State.Position);
    if Character = ')' then
      Exit;
    if IsValidEscape(Character, At(State, 0)) then
      ConsumeEscape(State);
  until False;
end;

procedure ConsumeUrl(var State: TTokenizer; Start: Integer);
var
  Value: string;
  Character: Char;
  Token: PCssToken;
  RunStart: Integer;
begin
  Value := '';
  while IsWhitespace(At(State, 0)) do
    Inc(State.Position);
  repeat
    RunStart := State.Position;
    while not (At(State, 0) in [#0, ')', ' ', #9, #10, '"', '''', '(', '\']) and
      not IsNonPrintable(At(State, 0)) do
      Inc(State.Position);
    if State.Position > RunStart then
      Value := Value + Copy(State.Input, RunStart, State.Position - RunStart);
    Character := At(State, 0);
    case Character of
      ')':
        begin
          Inc(State.Position);
          Break;
        end;
      #0:
        Break;
      ' ', #9, #10:
        begin
          while IsWhitespace(At(State, 0)) do
            Inc(State.Position);
          if At(State, 0) = ')' then
          begin
            Inc(State.Position);
            Break;
          end;
          if At(State, 0) = #0 then
            Break;
          ConsumeBadUrlRemnants(State);
          AddToken(State, tkBadUrl, Start);
          Exit;
        end;
      '\':
        if IsValidEscape(Character, At(State, 1)) then
        begin
          Inc(State.Position);
          Value := Value + ConsumeEscape(State);
        end
        else
        begin
          ConsumeBadUrlRemnants(State);
          AddToken(State, tkBadUrl, Start);
          Exit;
        end;
    else
      { '"', '''', '(' or a non-printable code point. }
      ConsumeBadUrlRemnants(State);
      AddToken(State, tkBadUrl, Start);
      Exit;
    end;
  until False;
  Token := AddToken(State, tkUrl, Start);
  Token^.Text := Value;
end;

procedure ConsumeIdentLike(var State: TTokenizer);
var
  Start: Integer;
  Name: string;
  Token: PCssToken;
begin
  Start := State.Position;
  Name := ConsumeIdentSequence(State);
  if (Length(Name) = 3) and (Name[1] in ['u', 'U']) and (Name[2] in ['r', 'R']) and
    (Name[3] in ['l', 'L']) and (At(State, 0) = '(') then
  begin
    Inc(State.Position);
    while IsWhitespace(At(State, 0)) and IsWhitespace(At(State, 1)) do
      Inc(State.Position);
    if (At(State, 0) in ['"', '''']) or (IsWhitespace(At(State, 0)) and (At(State, 1) in ['"', ''''])) then
    begin
      Token := AddToken(State, tkFunction, Start);
      Token^.Text := Name;
    end
    else
      ConsumeUrl(State, Start);
  end
  else if At(State, 0) = '(' then
  begin
    Inc(State.Position);
    Token := AddToken(State, tkFunction, Start);
    Token^.Text := Name;
  end
  else
  begin
    Token := AddToken(State, tkIdent, Start);
    Token^.Text := Name;
  end;
end;

procedure ConsumeString(var State: TTokenizer; Quote: Char);
var
  Start, RunStart: Integer;
  Value: string;
  Character: Char;
  Token: PCssToken;
begin
  Start := State.Position;
  Inc(State.Position);
  Value := '';
  repeat
    RunStart := State.Position;
    while not (At(State, 0) in [#0, #10, '\']) and (At(State, 0) <> Quote) do
      Inc(State.Position);
    if State.Position > RunStart then
      Value := Value + Copy(State.Input, RunStart, State.Position - RunStart);
    Character := At(State, 0);
    if Character = Quote then
    begin
      Inc(State.Position);
      Break;
    end;
    case Character of
      #0:
        Break;
      #10:
        begin
          { Not consumed: the newline becomes whitespace. }
          AddToken(State, tkBadString, Start);
          Exit;
        end;
      '\':
        begin
          Inc(State.Position);
          if At(State, 0) = #0 then
            Continue
          else if At(State, 0) = #10 then
            Inc(State.Position)
          else
            Value := Value + ConsumeEscape(State);
        end;
    end;
  until False;
  Token := AddToken(State, tkString, Start);
  Token^.Text := Value;
end;

procedure AddDelim(var State: TTokenizer; Character: Char);
var
  Token: PCssToken;
begin
  Token := AddToken(State, tkDelim, State.Position);
  Token^.Text := Character;
  Inc(State.Position);
end;

procedure ConsumeToken(var State: TTokenizer);
var
  Character: Char;
  Start: Integer;
  Token: PCssToken;
begin
  Character := At(State, 0);
  Start := State.Position;
  case Character of
    ' ', #9, #10:
      begin
        while IsWhitespace(At(State, 0)) do
          Inc(State.Position);
        AddToken(State, tkWhitespace, Start);
      end;
    '"', '''':
      ConsumeString(State, Character);
    '#':
      if IsNameCharacter(At(State, 1)) or IsValidEscape(At(State, 1), At(State, 2)) then
      begin
        Inc(State.Position);
        Token := AddToken(State, tkHash, Start);
        if StartsIdentSequence(At(State, 0), At(State, 1), At(State, 2)) then
          Token^.Flags := [tfIdHash];
        Token^.Text := ConsumeIdentSequence(State);
      end
      else
        AddDelim(State, Character);
    '(':
      begin
        AddToken(State, tkOpenParen, Start);
        Inc(State.Position);
      end;
    ')':
      begin
        AddToken(State, tkCloseParen, Start);
        Inc(State.Position);
      end;
    '+', '.':
      if StartsNumber(Character, At(State, 1), At(State, 2)) then
        ConsumeNumeric(State)
      else
        AddDelim(State, Character);
    ',':
      begin
        AddToken(State, tkComma, Start);
        Inc(State.Position);
      end;
    '-':
      if StartsNumber(Character, At(State, 1), At(State, 2)) then
        ConsumeNumeric(State)
      else if (At(State, 1) = '-') and (At(State, 2) = '>') then
      begin
        AddToken(State, tkCdc, Start);
        Inc(State.Position, 3);
      end
      else if StartsIdentSequence(Character, At(State, 1), At(State, 2)) then
        ConsumeIdentLike(State)
      else
        AddDelim(State, Character);
    ':':
      begin
        AddToken(State, tkColon, Start);
        Inc(State.Position);
      end;
    ';':
      begin
        AddToken(State, tkSemicolon, Start);
        Inc(State.Position);
      end;
    '<':
      if (At(State, 1) = '!') and (At(State, 2) = '-') and (At(State, 3) = '-') then
      begin
        AddToken(State, tkCdo, Start);
        Inc(State.Position, 4);
      end
      else
        AddDelim(State, Character);
    '@':
      if StartsIdentSequence(At(State, 1), At(State, 2), At(State, 3)) then
      begin
        Inc(State.Position);
        Token := AddToken(State, tkAtKeyword, Start);
        Token^.Text := ConsumeIdentSequence(State);
      end
      else
        AddDelim(State, Character);
    '[':
      begin
        AddToken(State, tkOpenSquare, Start);
        Inc(State.Position);
      end;
    '\':
      if IsValidEscape(Character, At(State, 1)) then
        ConsumeIdentLike(State)
      else
        AddDelim(State, Character);
    ']':
      begin
        AddToken(State, tkCloseSquare, Start);
        Inc(State.Position);
      end;
    '{':
      begin
        AddToken(State, tkOpenCurly, Start);
        Inc(State.Position);
      end;
    '}':
      begin
        AddToken(State, tkCloseCurly, Start);
        Inc(State.Position);
      end;
    '0'..'9':
      ConsumeNumeric(State);
  else
    if IsNameStart(Character) then
      ConsumeIdentLike(State)
    else
      AddDelim(State, Character);
  end;
end;

procedure SkipComments(var State: TTokenizer);
var
  Found: Integer;
begin
  while (At(State, 0) = '/') and (At(State, 1) = '*') do
  begin
    Found := Pos('*/', State.Input, State.Position + 2);
    if Found = 0 then
      State.Position := State.Length + 1
    else
      State.Position := Found + 2;
  end;
end;

function TokenizeCss(const Source: string): TCssTokenArray;
var
  State: TTokenizer;
begin
  State.Input := PreprocessCss(Source);
  State.Length := Length(State.Input);
  State.Position := 1;
  State.Tokens := nil;
  State.Count := 0;
  SetLength(State.Tokens, State.Length div 3 + 16);
  repeat
    SkipComments(State);
    if State.Position > State.Length then
      Break;
    ConsumeToken(State);
  until False;
  AddToken(State, tkEof, State.Position);
  SetLength(State.Tokens, State.Count);
  MatchBlocks(State.Tokens);
  Result := State.Tokens;
end;

end.
