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
  The lexer: ECMAScript source text to tokens.

  The source is decoded from UTF-8 to UTF-16 once; tokens carry their
  text as UTF-16 (identifier names, string values, template pieces both
  cooked and raw), numbers as doubles, BigInt literals as their digits.
  Whether a / starts a regular expression or is division depends on
  the grammar, so the parser asks for a regular expression explicitly
  (ScanRegExp) where an expression may begin. Each token says whether
  a line terminator came before it, for automatic semicolon insertion,
  and where it starts (line, column) for messages and stack traces.

  Reserved words are tokens of their own; contextual words (let, of,
  async, await, yield, get, set, static) are identifiers that the
  parser looks at by value.
}
unit Js.Lexer;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TJsTokenKind = (
    tkEnd, tkIdentifier, tkPrivateName, tkNumber, tkBigInt, tkString,
    tkTemplate, tkRegExp,
    { punctuators }
    tkLeftBrace, tkRightBrace, tkLeftParen, tkRightParen, tkLeftBracket,
    tkRightBracket, tkDot, tkEllipsis, tkSemicolon, tkComma, tkLess, tkGreater,
    tkLessEqual, tkGreaterEqual, tkEqual, tkNotEqual, tkStrictEqual,
    tkStrictNotEqual, tkPlus, tkMinus, tkStar, tkSlash, tkPercent, tkStarStar,
    tkPlusPlus, tkMinusMinus, tkShiftLeft, tkShiftRight, tkShiftRightUnsigned,
    tkAmpersand, tkBar, tkCaret, tkBang, tkTilde, tkAndAnd, tkOrOr,
    tkQuestionQuestion, tkQuestion, tkQuestionDot, tkColon, tkAssign,
    tkPlusAssign, tkMinusAssign, tkStarAssign, tkSlashAssign, tkPercentAssign,
    tkStarStarAssign, tkShiftLeftAssign, tkShiftRightAssign,
    tkShiftRightUnsignedAssign, tkAmpersandAssign, tkBarAssign, tkCaretAssign,
    tkAndAndAssign, tkOrOrAssign, tkQuestionQuestionAssign, tkArrow, tkHash,
    tkAt,
    { reserved words }
    tkBreak, tkCase, tkCatch, tkClass, tkConst, tkContinue, tkDebugger,
    tkDefault, tkDelete, tkDo, tkElse, tkEnum, tkExport, tkExtends, tkFalse,
    tkFinally, tkFor, tkFunction, tkIf, tkImport, tkIn, tkInstanceof, tkNew,
    tkNull, tkReturn, tkSuper, tkSwitch, tkThis, tkThrow, tkTrue, tkTry,
    tkTypeof, tkVar, tkVoid, tkWhile, tkWith);

  TJsToken = record
    Kind: TJsTokenKind;
    { Identifier name, string value, cooked template text, regexp body,
      number or BigInt digits as written. }
    Text: UnicodeString;
    { A template piece's raw text; a regexp's flags. }
    Raw: UnicodeString;
    Number: Double;
    Start: Integer;
    Finish: Integer;
    Line: Integer;
    Column: Integer;
    NewlineBefore: Boolean;
    { A template piece: whether it ends the template (else a substitution follows). }
    TemplateTail: Boolean;
    { The cooked text is not valid (allowed in tagged templates). }
    InvalidEscape: Boolean;
    { A string with an octal escape, a legacy octal number. }
    LegacyOctal: Boolean;
    { An identifier written with an escape. }
    Escaped: Boolean;
  end;

  EJsSyntaxError = class(Exception)
  public
    Line: Integer;
    Column: Integer;
    constructor CreateAt(const Text: string; ALine, AColumn: Integer);
  end;

  TJsLexer = class
  private
    FSource: UnicodeString;
    FLength: Integer;
    FPosition: Integer;
    FLine: Integer;
    FLineStart: Integer;
    FNewline: Boolean;
    procedure Fail(const Text: string);
    function Peek(Offset: Integer = 0): WideChar; inline;
    procedure SkipSpace;
    procedure ScanIdentifier(var Token: TJsToken);
    procedure ScanNumber(var Token: TJsToken);
    procedure ScanString(var Token: TJsToken; Quote: WideChar);
    function ScanEscape(var Token: TJsToken; InTemplate: Boolean): UnicodeString;
    procedure ScanPunctuator(var Token: TJsToken);
  public
    constructor Create(const Source: UnicodeString);
    procedure Next(out Token: TJsToken);
    { Rescans from Token's start as a regular expression literal. }
    procedure ScanRegExp(var Token: TJsToken);
    { Continues a template after the brace closing a substitution. }
    procedure ScanTemplate(var Token: TJsToken);
    { Back to just after Token (for the parser's lookahead). }
    procedure Rewind(const Token: TJsToken);
    procedure SavePosition(out Position, Line, LineStart: Integer);
    procedure RestorePosition(Position, Line, LineStart: Integer);
    function SourceText(Start, Finish: Integer): UnicodeString;
    property Source: UnicodeString read FSource;
  end;

function IsIdentifierStart(Character: LongWord): Boolean;
function IsIdentifierPart(Character: LongWord): Boolean;
function IsLineTerminator(Character: WideChar): Boolean; inline;
function IsJsWhiteSpace(Character: WideChar): Boolean;
function TokenKindName(Kind: TJsTokenKind): string;
function KeywordToken(const Name: UnicodeString; out Kind: TJsTokenKind): Boolean;

implementation

uses
  Character;

const
  KeywordTexts: array[tkBreak..tkWith] of string = (
    'break', 'case', 'catch', 'class', 'const', 'continue', 'debugger',
    'default', 'delete', 'do', 'else', 'enum', 'export', 'extends', 'false',
    'finally', 'for', 'function', 'if', 'import', 'in', 'instanceof', 'new',
    'null', 'return', 'super', 'switch', 'this', 'throw', 'true', 'try',
    'typeof', 'var', 'void', 'while', 'with');

  PunctuatorTexts: array[tkLeftBrace..tkAt] of string = (
    '{', '}', '(', ')', '[', ']', '.', '...', ';', ',', '<', '>', '<=', '>=',
    '==', '!=', '===', '!==', '+', '-', '*', '/', '%', '**', '++', '--', '<<',
    '>>', '>>>', '&', '|', '^', '!', '~', '&&', '||', '??', '?', '?.', ':',
    '=', '+=', '-=', '*=', '/=', '%=', '**=', '<<=', '>>=', '>>>=', '&=',
    '|=', '^=', '&&=', '||=', '??=', '=>', '#', '@');

constructor EJsSyntaxError.CreateAt(const Text: string; ALine, AColumn: Integer);
begin
  inherited Create(Text);
  Line := ALine;
  Column := AColumn;
end;

function TokenKindName(Kind: TJsTokenKind): string;
begin
  case Kind of
    tkEnd: Result := 'end of input';
    tkIdentifier: Result := 'identifier';
    tkPrivateName: Result := 'private name';
    tkNumber, tkBigInt: Result := 'number';
    tkString: Result := 'string';
    tkTemplate: Result := 'template';
    tkRegExp: Result := 'regular expression';
    tkLeftBrace..tkAt: Result := '''' + PunctuatorTexts[Kind] + '''';
  else
    Result := '''' + KeywordTexts[Kind] + '''';
  end;
end;

function KeywordToken(const Name: UnicodeString; out Kind: TJsTokenKind): Boolean;
var
  Candidate: TJsTokenKind;
  Text: string;
begin
  Result := False;
  Kind := tkIdentifier;
  if (Length(Name) < 2) or (Length(Name) > 10) or (Name[1] < 'a') or (Name[1] > 'w') then
    Exit;
  Text := string(Name);
  for Candidate := tkBreak to tkWith do
    if KeywordTexts[Candidate] = Text then
    begin
      Kind := Candidate;
      Exit(True);
    end;
end;

function IsLineTerminator(Character: WideChar): Boolean;
begin
  Result := (Character = #10) or (Character = #13) or (Character = #$2028) or (Character = #$2029);
end;

function IsJsWhiteSpace(Character: WideChar): Boolean;
begin
  case Character of
    #9, #11, #12, ' ', #$A0, #$FEFF, #$1680, #$2000..#$200A, #$202F, #$205F, #$3000:
      Result := True;
  else
    Result := False;
  end;
end;

function IsIdentifierStart(Character: LongWord): Boolean;
begin
  if Character < 128 then
    Exit(((Character >= Ord('a')) and (Character <= Ord('z'))) or ((Character >= Ord('A')) and
      (Character <= Ord('Z'))) or (Character = Ord('$')) or (Character = Ord('_')));
  if Character > $FFFF then
    Exit(True);
  Result := TCharacter.IsLetter(WideChar(Character)) or
    (TCharacter.GetUnicodeCategory(WideChar(Character)) = TUnicodeCategory.ucLetterNumber);
end;

function IsIdentifierPart(Character: LongWord): Boolean;
begin
  if Character < 128 then
    Exit(IsIdentifierStart(Character) or ((Character >= Ord('0')) and (Character <= Ord('9'))));
  if (Character = $200C) or (Character = $200D) or (Character > $FFFF) then
    Exit(True);
  Result := IsIdentifierStart(Character) or
    (TCharacter.GetUnicodeCategory(WideChar(Character)) in [TUnicodeCategory.ucNonSpacingMark,
    TUnicodeCategory.ucCombiningMark, TUnicodeCategory.ucDecimalNumber,
    TUnicodeCategory.ucConnectPunctuation]);
end;

{ TJsLexer }

constructor TJsLexer.Create(const Source: UnicodeString);
begin
  inherited Create;
  FSource := Source;
  FLength := Length(Source);
  FPosition := 1;
  FLine := 1;
  FLineStart := 1;
  { A #! line at the very start is a comment. }
  if (FLength >= 2) and (FSource[1] = '#') and (FSource[2] = '!') then
    while (FPosition <= FLength) and not IsLineTerminator(FSource[FPosition]) do
      Inc(FPosition);
end;

procedure TJsLexer.Fail(const Text: string);
begin
  raise EJsSyntaxError.CreateAt(Text, FLine, FPosition - FLineStart + 1);
end;

function TJsLexer.Peek(Offset: Integer): WideChar;
begin
  if FPosition + Offset <= FLength then
    Result := FSource[FPosition + Offset]
  else
    Result := #0;
end;

function TJsLexer.SourceText(Start, Finish: Integer): UnicodeString;
begin
  Result := Copy(FSource, Start, Finish - Start);
end;

procedure TJsLexer.SavePosition(out Position, Line, LineStart: Integer);
begin
  Position := FPosition;
  Line := FLine;
  LineStart := FLineStart;
end;

procedure TJsLexer.RestorePosition(Position, Line, LineStart: Integer);
begin
  FPosition := Position;
  FLine := Line;
  FLineStart := LineStart;
end;

procedure TJsLexer.Rewind(const Token: TJsToken);
begin
  FPosition := Token.Finish;
end;

procedure TJsLexer.SkipSpace;
var
  Character: WideChar;
begin
  while FPosition <= FLength do
  begin
    Character := FSource[FPosition];
    if IsLineTerminator(Character) then
    begin
      if (Character = #13) and (Peek(1) = #10) then
        Inc(FPosition);
      Inc(FPosition);
      Inc(FLine);
      FLineStart := FPosition;
      FNewline := True;
    end
    else if (Character = ' ') or (Character = #9) or IsJsWhiteSpace(Character) then
      Inc(FPosition)
    else if (Character = '/') and (Peek(1) = '/') then
    begin
      while (FPosition <= FLength) and not IsLineTerminator(FSource[FPosition]) do
        Inc(FPosition);
    end
    else if (Character = '/') and (Peek(1) = '*') then
    begin
      Inc(FPosition, 2);
      while True do
      begin
        if FPosition > FLength then
          Fail('Unterminated comment');
        Character := FSource[FPosition];
        if (Character = '*') and (Peek(1) = '/') then
        begin
          Inc(FPosition, 2);
          Break;
        end;
        if IsLineTerminator(Character) then
        begin
          if (Character = #13) and (Peek(1) = #10) then
            Inc(FPosition);
          Inc(FLine);
          FLineStart := FPosition + 1;
          FNewline := True;
        end;
        Inc(FPosition);
      end;
    end
    else if (Character = '<') and (Peek(1) = '!') and (Peek(2) = '-') and (Peek(3) = '-') then
    begin
      { An HTML-like comment (Annex B). }
      while (FPosition <= FLength) and not IsLineTerminator(FSource[FPosition]) do
        Inc(FPosition);
    end
    else if (Character = '-') and (Peek(1) = '-') and (Peek(2) = '>') and (FNewline or (FPosition = 1)) then
    begin
      while (FPosition <= FLength) and not IsLineTerminator(FSource[FPosition]) do
        Inc(FPosition);
    end
    else
      Break;
  end;
end;

function HexValue(Character: WideChar): Integer;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
    'A'..'F': Result := Ord(Character) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

{ CR LF and CR as LF (template raw text). }
function NormalizeLineEnds(const Text: UnicodeString): UnicodeString;
var
  Index: Integer;
begin
  Result := '';
  Index := 1;
  while Index <= Length(Text) do
  begin
    if Text[Index] = #13 then
    begin
      Result := Result + #10;
      if (Index < Length(Text)) and (Text[Index + 1] = #10) then
        Inc(Index);
    end
    else
      Result := Result + Text[Index];
    Inc(Index);
  end;
end;

function CodePointText(CodePoint: LongWord): UnicodeString;
begin
  if CodePoint >= $10000 then
  begin
    Dec(CodePoint, $10000);
    Result := WideChar($D800 + (CodePoint shr 10)) + WideChar($DC00 + (CodePoint and $3FF));
  end
  else
    Result := WideChar(CodePoint);
end;

{ After the backslash: the escape's value. In templates a bad escape is
  noted on the token instead of failing. }
function TJsLexer.ScanEscape(var Token: TJsToken; InTemplate: Boolean): UnicodeString;
var
  Character: WideChar;
  Value, Digit, Count: LongWord;

  procedure Bad(const Text: string);
  begin
    if InTemplate then
      Token.InvalidEscape := True
    else
      Fail(Text);
  end;

begin
  Result := '';
  if FPosition > FLength then
    Fail('Unterminated string');
  Character := FSource[FPosition];
  Inc(FPosition);
  case Character of
    'n': Result := #10;
    't': Result := #9;
    'r': Result := #13;
    'b': Result := #8;
    'f': Result := #12;
    'v': Result := #11;
    '0'..'7':
      begin
        if (Character = '0') and not ((Peek >= '0') and (Peek <= '9')) then
          Exit(#0);
        if InTemplate then
        begin
          Token.InvalidEscape := True;
          Exit('');
        end;
        Token.LegacyOctal := True;
        Value := Ord(Character) - Ord('0');
        if (Peek >= '0') and (Peek <= '7') then
        begin
          Value := Value * 8 + LongWord(Ord(Peek) - Ord('0'));
          Inc(FPosition);
          if (Character <= '3') and (Peek >= '0') and (Peek <= '7') then
          begin
            Value := Value * 8 + LongWord(Ord(Peek) - Ord('0'));
            Inc(FPosition);
          end;
        end;
        Result := WideChar(Value);
      end;
    '8', '9':
      begin
        if InTemplate then
          Token.InvalidEscape := True
        else
          Token.LegacyOctal := True;
        Result := Character;
      end;
    'x':
      begin
        if (HexValue(Peek) < 0) or (HexValue(Peek(1)) < 0) then
        begin
          Bad('Invalid hexadecimal escape sequence');
          Exit('');
        end;
        Result := WideChar(HexValue(Peek) * 16 + HexValue(Peek(1)));
        Inc(FPosition, 2);
      end;
    'u':
      begin
        if Peek = '{' then
        begin
          Inc(FPosition);
          Value := 0;
          Count := 0;
          while (FPosition <= FLength) and (HexValue(Peek) >= 0) do
          begin
            Value := Value * 16 + LongWord(HexValue(Peek));
            Inc(Count);
            Inc(FPosition);
            if Value > $10FFFF then
              Break;
          end;
          if (Peek <> '}') or (Count = 0) or (Value > $10FFFF) then
          begin
            Bad('Invalid Unicode escape sequence');
            Exit('');
          end;
          Inc(FPosition);
          Result := CodePointText(Value);
        end
        else
        begin
          Value := 0;
          for Count := 0 to 3 do
          begin
            Digit := LongWord(HexValue(Peek));
            if Integer(Digit) < 0 then
            begin
              Bad('Invalid Unicode escape sequence');
              Exit('');
            end;
            Value := Value * 16 + Digit;
            Inc(FPosition);
          end;
          Result := WideChar(Value);
        end;
      end;
    #13:
      begin
        if Peek = #10 then
          Inc(FPosition);
        Inc(FLine);
        FLineStart := FPosition;
        Result := '';
      end;
    #10, #$2028, #$2029:
      begin
        Inc(FLine);
        FLineStart := FPosition;
        Result := '';
      end;
  else
    Result := Character;
  end;
end;

procedure TJsLexer.ScanIdentifier(var Token: TJsToken);
var
  Name: UnicodeString;
  Character: WideChar;
  Dummy: TJsToken;
  Piece: UnicodeString;
  CodePoint: LongWord;
begin
  Name := '';
  while FPosition <= FLength do
  begin
    Character := FSource[FPosition];
    if Character = '\' then
    begin
      Inc(FPosition);
      if Peek <> 'u' then
        Fail('Invalid escape in identifier');
      Dummy := Default(TJsToken);
      Piece := ScanEscape(Dummy, False);
      if Piece = '' then
        Fail('Invalid escape in identifier');
      CodePoint := Ord(Piece[1]);
      if ((Name = '') and not IsIdentifierStart(CodePoint)) or ((Name <> '') and not IsIdentifierPart(CodePoint)) then
        Fail('Invalid identifier escape');
      Token.Escaped := True;
      Name := Name + Piece;
      Continue;
    end;
    if (Character >= #$D800) and (Character <= #$DBFF) and (Peek(1) >= #$DC00) and (Peek(1) <= #$DFFF) then
    begin
      Name := Name + Character + Peek(1);
      Inc(FPosition, 2);
      Continue;
    end;
    if not IsIdentifierPart(Ord(Character)) then
      Break;
    Name := Name + Character;
    Inc(FPosition);
  end;
  Token.Text := Name;
  Token.Kind := tkIdentifier;
  if not Token.Escaped then
    KeywordToken(Name, Token.Kind);
end;

procedure TJsLexer.ScanNumber(var Token: TJsToken);
var
  Digits: string;
  Radix: Integer;
  Value: Double;
  Character: WideChar;
  Code: Integer;
  IsLegacyOctal: Boolean;

  procedure TakeDigits(Allowed: TSysCharSet);
  var
    LastWasSeparator: Boolean;
  begin
    LastWasSeparator := True;
    while FPosition <= FLength do
    begin
      Character := FSource[FPosition];
      if Character = '_' then
      begin
        if LastWasSeparator then
          Fail('Invalid numeric separator');
        LastWasSeparator := True;
        Inc(FPosition);
        if not (CharInSet(Peek, Allowed)) then
          Fail('Invalid numeric separator');
        Continue;
      end;
      if (Ord(Character) > 127) or not (AnsiChar(Character) in Allowed) then
        Break;
      Digits := Digits + AnsiChar(Character);
      LastWasSeparator := False;
      Inc(FPosition);
    end;
  end;

begin
  Token.Kind := tkNumber;
  Digits := '';
  Radix := 10;
  IsLegacyOctal := False;
  if (Peek = '0') and CharInSet(Peek(1), ['x', 'X', 'o', 'O', 'b', 'B']) then
  begin
    case Peek(1) of
      'x', 'X': Radix := 16;
      'o', 'O': Radix := 8;
    else
      Radix := 2;
    end;
    Inc(FPosition, 2);
    case Radix of
      16: TakeDigits(['0'..'9', 'a'..'f', 'A'..'F']);
      8: TakeDigits(['0'..'7']);
    else
      TakeDigits(['0', '1']);
    end;
    if Digits = '' then
      Fail('Invalid number');
  end
  else if (Peek = '0') and (Peek(1) >= '0') and (Peek(1) <= '9') then
  begin
    { 0777 (legacy octal) or 089 (decimal with a leading zero). }
    Inc(FPosition);
    while (Peek >= '0') and (Peek <= '9') do
    begin
      Digits := Digits + AnsiChar(Peek);
      Inc(FPosition);
    end;
    if Pos('8', Digits) + Pos('9', Digits) = 0 then
    begin
      Radix := 8;
      IsLegacyOctal := True;
    end;
    Token.LegacyOctal := True;
  end
  else
  begin
    TakeDigits(['0'..'9']);
    if Peek = '.' then
    begin
      Digits := Digits + '.';
      Inc(FPosition);
      if Peek = '_' then
        Fail('Invalid numeric separator');
      TakeDigits(['0'..'9']);
    end;
    if CharInSet(Peek, ['e', 'E']) then
    begin
      Digits := Digits + 'e';
      Inc(FPosition);
      if CharInSet(Peek, ['+', '-']) then
      begin
        Digits := Digits + AnsiChar(Peek);
        Inc(FPosition);
      end;
      if not ((Peek >= '0') and (Peek <= '9')) then
        Fail('Invalid number');
      TakeDigits(['0'..'9']);
    end;
  end;
  if (Peek = 'n') and not IsLegacyOctal and not Token.LegacyOctal and (Pos('.', Digits) = 0) and
    ((Radix <> 10) or (Pos('e', Digits) = 0)) then
  begin
    Inc(FPosition);
    Token.Kind := tkBigInt;
    Token.Text := UnicodeString(Digits);
    Token.Number := Radix;
  end
  else
  begin
    if Radix = 10 then
    begin
      if Digits[1] = '.' then
        Digits := '0' + Digits;
      if Digits[Length(Digits)] = '.' then
        Digits := Digits + '0';
      Val(Digits, Value, Code);
      if Code <> 0 then
        Fail('Invalid number');
    end
    else
    begin
      Value := 0;
      for Code := 1 to Length(Digits) do
        Value := Value * Radix + HexValue(WideChar(Digits[Code]));
    end;
    Token.Number := Value;
    Token.Text := UnicodeString(Digits);
  end;
  if (FPosition <= FLength) and (IsIdentifierStart(Ord(FSource[FPosition])) or
    ((FSource[FPosition] >= '0') and (FSource[FPosition] <= '9'))) then
    Fail('Invalid or unexpected token');
end;

procedure TJsLexer.ScanString(var Token: TJsToken; Quote: WideChar);
var
  Text: UnicodeString;
  Character: WideChar;
  Start: Integer;
begin
  Inc(FPosition);
  Text := '';
  Start := FPosition;
  while True do
  begin
    if FPosition > FLength then
      Fail('Unterminated string');
    Character := FSource[FPosition];
    if Character = Quote then
      Break;
    if Character = '\' then
    begin
      Text := Text + Copy(FSource, Start, FPosition - Start);
      Inc(FPosition);
      Text := Text + ScanEscape(Token, False);
      Start := FPosition;
      Continue;
    end;
    if (Character = #10) or (Character = #13) then
      Fail('Unterminated string');
    Inc(FPosition);
  end;
  Text := Text + Copy(FSource, Start, FPosition - Start);
  Inc(FPosition);
  Token.Kind := tkString;
  Token.Text := Text;
end;

procedure TJsLexer.ScanTemplate(var Token: TJsToken);
var
  Cooked, Raw: UnicodeString;
  Character: WideChar;
  RawStart: Integer;
begin
  { FPosition is just after the backquote or the closing brace. }
  Token.Kind := tkTemplate;
  Token.InvalidEscape := False;
  Cooked := '';
  Raw := '';
  while True do
  begin
    if FPosition > FLength then
      Fail('Unterminated template literal');
    Character := FSource[FPosition];
    if Character = '`' then
    begin
      Inc(FPosition);
      Token.TemplateTail := True;
      Break;
    end;
    if (Character = '$') and (Peek(1) = '{') then
    begin
      Inc(FPosition, 2);
      Token.TemplateTail := False;
      Break;
    end;
    if Character = '\' then
    begin
      RawStart := FPosition;
      Inc(FPosition);
      Cooked := Cooked + ScanEscape(Token, True);
      Raw := Raw + NormalizeLineEnds(Copy(FSource, RawStart, FPosition - RawStart));
      Continue;
    end;
    if Character = #13 then
    begin
      if Peek(1) = #10 then
        Inc(FPosition);
      Character := #10;
    end;
    if IsLineTerminator(Character) then
    begin
      Inc(FLine);
      FLineStart := FPosition + 1;
    end;
    Cooked := Cooked + Character;
    Raw := Raw + Character;
    Inc(FPosition);
  end;
  Token.Text := Cooked;
  Token.Raw := Raw;
  Token.Finish := FPosition;
end;

procedure TJsLexer.ScanRegExp(var Token: TJsToken);
var
  Body, Flags: UnicodeString;
  InClass: Boolean;
  Character: WideChar;
begin
  FPosition := Token.Start + 1;
  Body := '';
  InClass := False;
  while True do
  begin
    if (FPosition > FLength) or IsLineTerminator(FSource[FPosition]) then
      Fail('Invalid regular expression: missing /');
    Character := FSource[FPosition];
    Inc(FPosition);
    if Character = '\' then
    begin
      if (FPosition > FLength) or IsLineTerminator(FSource[FPosition]) then
        Fail('Invalid regular expression: missing /');
      Body := Body + Character + FSource[FPosition];
      Inc(FPosition);
      Continue;
    end;
    if Character = '[' then
      InClass := True
    else if Character = ']' then
      InClass := False
    else if (Character = '/') and not InClass then
      Break;
    Body := Body + Character;
  end;
  Flags := '';
  while (FPosition <= FLength) and IsIdentifierPart(Ord(FSource[FPosition])) do
  begin
    Flags := Flags + FSource[FPosition];
    Inc(FPosition);
  end;
  Token.Kind := tkRegExp;
  Token.Text := Body;
  Token.Raw := Flags;
  Token.Finish := FPosition;
end;

procedure TJsLexer.ScanPunctuator(var Token: TJsToken);
var
  Kind: TJsTokenKind;
  Best: TJsTokenKind;
  BestLength, Size, Index: Integer;
  Text: string;
  Matches: Boolean;
begin
  Best := tkEnd;
  BestLength := 0;
  for Kind := tkLeftBrace to tkAt do
  begin
    Text := PunctuatorTexts[Kind];
    Size := Length(Text);
    if (Size <= BestLength) or (FPosition + Size - 1 > FLength) then
      Continue;
    Matches := True;
    for Index := 1 to Size do
      if FSource[FPosition + Index - 1] <> WideChar(Text[Index]) then
      begin
        Matches := False;
        Break;
      end;
    if Matches then
    begin
      Best := Kind;
      BestLength := Size;
    end;
  end;
  { ?. followed by a digit is ? then a number (a ? .5 : b). }
  if (Best = tkQuestionDot) and (Peek(2) >= '0') and (Peek(2) <= '9') then
  begin
    Best := tkQuestion;
    BestLength := 1;
  end;
  if Best = tkEnd then
    Fail('Invalid or unexpected token');
  Token.Kind := Best;
  Inc(FPosition, BestLength);
end;

procedure TJsLexer.Next(out Token: TJsToken);
var
  Character: WideChar;
begin
  Token := Default(TJsToken);
  FNewline := False;
  SkipSpace;
  Token.NewlineBefore := FNewline;
  Token.Start := FPosition;
  Token.Line := FLine;
  Token.Column := FPosition - FLineStart + 1;
  if FPosition > FLength then
  begin
    Token.Kind := tkEnd;
    Token.Finish := FPosition;
    Exit;
  end;
  Character := FSource[FPosition];
  case Character of
    'a'..'z', 'A'..'Z', '$', '_', '\':
      ScanIdentifier(Token);
    '0'..'9':
      ScanNumber(Token);
    '"', '''':
      ScanString(Token, Character);
    '`':
      begin
        Inc(FPosition);
        ScanTemplate(Token);
      end;
    '#':
      begin
        Inc(FPosition);
        if (FPosition <= FLength) and (IsIdentifierStart(Ord(FSource[FPosition])) or (FSource[FPosition] = '\')) then
        begin
          ScanIdentifier(Token);
          Token.Kind := tkPrivateName;
        end
        else
          Fail('Invalid or unexpected token');
      end;
    '.':
      if (Peek(1) >= '0') and (Peek(1) <= '9') then
        ScanNumber(Token)
      else
        ScanPunctuator(Token);
  else
    if (Ord(Character) > 127) and (IsIdentifierStart(Ord(Character)) or
      ((Character >= #$D800) and (Character <= #$DBFF))) then
      ScanIdentifier(Token)
    else
      ScanPunctuator(Token);
  end;
  Token.Finish := FPosition;
end;

end.
