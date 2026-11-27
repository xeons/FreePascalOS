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

  The source is decoded from UTF-8 to UTF-16 once. A token is a small
  record without strings (the parser copies tokens freely): its kind,
  where it starts and ends (offsets, line, column), numbers as doubles.
  Identifier names and reserved words are interned in the lexer's name
  table, and a token carries the name's index; the entry also says
  whether the name is a reserved word or a contextual word (let, of,
  async, await, yield, get, set, static...), so neither needs comparing
  text. The value of a string, template piece, regular expression or
  BigInt is taken from the source when the parser asks for it (most are
  never asked for: a lazily compiled function's body is only checked).

  Whether a / starts a regular expression or is division depends on
  the grammar, so the parser asks for a regular expression explicitly
  (ScanRegExp) where an expression may begin. Each token says whether
  a line terminator came before it, for automatic semicolon insertion.
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

  { Identifiers the grammar looks at: contextual words, the words
    reserved in strict mode only, and the names strict mode forbids as
    bindings. }
  TJsWord = (jwNone, jwAs, jwAssert, jwAsync, jwAwait, jwFrom, jwGet, jwLet, jwMeta, jwOf, jwSet, jwStatic,
    jwTarget, jwYield, jwEval, jwArguments, jwImplements, jwInterface, jwPackage, jwPrivate, jwProtected,
    jwPublic);

  TJsToken = record
    Kind: TJsTokenKind;
    { An identifier's contextual word (jwNone for most). }
    Word: TJsWord;
    NewlineBefore: Boolean;
    { A template piece: whether it ends the template (else a substitution follows). }
    TemplateTail: Boolean;
    { The cooked text is not valid (allowed in tagged templates). }
    InvalidEscape: Boolean;
    { A string with an octal escape, a legacy octal number. }
    LegacyOctal: Boolean;
    { An identifier written with an escape. }
    Escaped: Boolean;
    { A string or template piece whose value is not its source text
      (escapes, line ends to normalize). }
    HasEscape: Boolean;
    { An identifier, private name (without the #) or reserved word: its
      interned name (TJsLexer.Names). }
    Name: Integer;
    { A number's value; a BigInt's radix. }
    Number: Double;
    Start: Integer;
    Finish: Integer;
    Line: Integer;
    Column: Integer;
    { A regular expression: where its flags start (its body ends just
      before, at the closing slash). }
    FlagsStart: Integer;
  end;

  TJsNameList = array of UnicodeString;

  { A slot of the lexer's name table: the name's hash beside its index,
    so that a probe reads one place. }
  TJsNameSlot = record
    Hash: LongWord;
    { The name's index + 1; 0: empty. }
    Entry: Integer;
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
    { The names met so far, each kept once: a name written a thousand
      times is one string and one index. Dense arrays by index, and an
      open addressing table by hash. }
    FNames: TJsNameList;
    FNameKinds: array of TJsTokenKind;
    FNameWords: array of TJsWord;
    FNameHashes: array of LongWord;
    FNameCount: Integer;
    FNameSlots: array of TJsNameSlot;
    procedure GrowNameSlots;
    procedure InsertNameSlot(Entry: Integer);
    function NewNameEntry(Hash: LongWord): Integer;
    function AddName(Start, Count: Integer; Hash: LongWord): Integer;
    function FindName(Start, Count: Integer; Hash: LongWord): Integer;
    function InternText(const Text: UnicodeString): Integer;
    procedure InternWords;
    procedure CopyNames(From: TJsLexer);
    procedure Fail(const Text: string);
    function Peek(Offset: Integer = 0): WideChar; inline;
    procedure SkipComment;
    procedure SkipSpace;
    procedure ScanIdentifier(var Token: TJsToken);
    procedure ScanUnusualIdentifier(var Token: TJsToken);
    function ScanSimpleInteger(var Token: TJsToken): Boolean;
    procedure ScanNumber(var Token: TJsToken);
    procedure ScanString(var Token: TJsToken; Quote: WideChar);
    function ScanEscape(var Token: TJsToken; InTemplate: Boolean): LongInt;
    procedure ScanTemplatePiece(var Token: TJsToken);
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
    { The value of a string token. }
    procedure DecodeString(const Token: TJsToken; var Text: UnicodeString);
    { A template piece's cooked and raw text. }
    procedure DecodeTemplate(const Token: TJsToken; var Cooked, Raw: UnicodeString);
    { A regular expression token's body and flags. }
    procedure DecodeRegExp(const Token: TJsToken; var Body, Flags: UnicodeString);
    { A BigInt token's digits (no prefix, no separators). }
    procedure DecodeBigInt(const Token: TJsToken; var Digits: UnicodeString);
    { A string token that is the directive "use strict" (written so). }
    function IsUseStrict(const Token: TJsToken): Boolean;
    { The name is a reserved word (spelled with an escape it is still
      reserved, 12.7.2). }
    function IsReservedName(Name: Integer): Boolean; inline;
    property Source: UnicodeString read FSource;
    { Interned names, by a token's Name. }
    property Names: TJsNameList read FNames;
  end;

function IsIdentifierStart(Character: LongWord): Boolean;
function IsIdentifierPart(Character: LongWord): Boolean;
function IsLineTerminator(Character: WideChar): Boolean; inline;
function IsJsWhiteSpace(Character: WideChar): Boolean;
function TokenKindName(Kind: TJsTokenKind): string;
{ FNV-1a over UTF-16 units (the name tables of the lexer, scopes and
  scope chains); never overflows a range check. }
function NameHash(Text: PWideChar; Count: Integer): LongWord;

implementation

uses
  Character;

const
  KeywordTexts: array[tkBreak..tkWith] of UnicodeString = (
    'break', 'case', 'catch', 'class', 'const', 'continue', 'debugger',
    'default', 'delete', 'do', 'else', 'enum', 'export', 'extends', 'false',
    'finally', 'for', 'function', 'if', 'import', 'in', 'instanceof', 'new',
    'null', 'return', 'super', 'switch', 'this', 'throw', 'true', 'try',
    'typeof', 'var', 'void', 'while', 'with');

  WordTexts: array[jwAs..jwPublic] of UnicodeString = (
    'as', 'assert', 'async', 'await', 'from', 'get', 'let', 'meta', 'of', 'set', 'static', 'target', 'yield',
    'eval', 'arguments', 'implements', 'interface', 'package', 'private', 'protected', 'public');

  PunctuatorTexts: array[tkLeftBrace..tkAt] of string = (
    '{', '}', '(', ')', '[', ']', '.', '...', ';', ',', '<', '>', '<=', '>=',
    '==', '!=', '===', '!==', '+', '-', '*', '/', '%', '**', '++', '--', '<<',
    '>>', '>>>', '&', '|', '^', '!', '~', '&&', '||', '??', '?', '?.', ':',
    '=', '+=', '-=', '*=', '/=', '%=', '**=', '<<=', '>>=', '>>>=', '&=',
    '|=', '^=', '&&=', '||=', '??=', '=>', '#', '@');

  HashOffset = LongWord(2166136261);
  HashPrime = LongWord(16777619);

var
  { A lexer of no source, made at start-up: its name table holds the
    words, and new lexers start from a copy. }
  WordsLexer: TJsLexer = nil;

type
  { What an ASCII character means between tokens. }
  TJsSpaceClass = (
    scToken,       { starts a token }
    scBlank,       { white space }
    scNewline,     { a line terminator }
    scMaybeComment { / < - : a comment, or a token }
  );

var
  { Classes of the ASCII characters, filled in at start-up. }
  SpaceClasses: array[0..127] of TJsSpaceClass;
  IdentifierParts: array[0..127] of Boolean;

{$push}{$R-}{$Q-}
function NameHash(Text: PWideChar; Count: Integer): LongWord;
var
  Index: Integer;
begin
  Result := HashOffset;
  for Index := 0 to Count - 1 do
    Result := (Result xor LongWord(Ord(Text[Index]))) * HashPrime;
end;
{$pop}

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
    Result := '''' + string(KeywordTexts[Kind]) + '''';
  end;
end;

function IsLineTerminator(Character: WideChar): Boolean; inline;
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

{ Unicode's Other_ID_Start: kept in ID_Start for compatibility though
  their categories are not letters. }
function IsOtherIdentifierStart(Character: LongWord): Boolean;
begin
  case Character of
    $1885, $1886, $2118, $212E, $309B, $309C:
      Result := True;
  else
    Result := False;
  end;
end;

{ Other_ID_Continue (with ZWNJ and ZWJ, which ECMAScript adds). }
function IsOtherIdentifierPart(Character: LongWord): Boolean;
begin
  case Character of
    $00B7, $0387, $1369..$1371, $19DA, $200C, $200D, $30FB, $FF65:
      Result := True;
  else
    Result := False;
  end;
end;

function IsIdentifierStart(Character: LongWord): Boolean;
begin
  if Character < 128 then
    Exit(IdentifierParts[Character] and not ((Character >= Ord('0')) and (Character <= Ord('9'))));
  if Character > $FFFF then
    Exit(True);
  if IsOtherIdentifierStart(Character) then
    Exit(True);
  Result := TCharacter.IsLetter(WideChar(Character)) or
    (TCharacter.GetUnicodeCategory(WideChar(Character)) = TUnicodeCategory.ucLetterNumber);
end;

function IsIdentifierPart(Character: LongWord): Boolean;
begin
  if Character < 128 then
    Exit(IdentifierParts[Character]);
  if (Character > $FFFF) or IsOtherIdentifierPart(Character) then
    Exit(True);
  Result := IsIdentifierStart(Character) or
    (TCharacter.GetUnicodeCategory(WideChar(Character)) in [TUnicodeCategory.ucNonSpacingMark,
    TUnicodeCategory.ucCombiningMark, TUnicodeCategory.ucDecimalNumber,
    TUnicodeCategory.ucConnectPunctuation]);
end;

procedure FillCharacterClasses;
var
  Code: Integer;
begin
  for Code := 0 to 127 do
  begin
    case Chr(Code) of
      ' ', #9, #11, #12: SpaceClasses[Code] := scBlank;
      #10, #13: SpaceClasses[Code] := scNewline;
      '/', '<', '-': SpaceClasses[Code] := scMaybeComment;
    else
      SpaceClasses[Code] := scToken;
    end;
    IdentifierParts[Code] := Chr(Code) in ['a'..'z', 'A'..'Z', '0'..'9', '$', '_'];
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

{ TJsLexer }

constructor TJsLexer.Create(const Source: UnicodeString);
begin
  inherited Create;
  FSource := Source;
  FLength := Length(Source);
  FPosition := 1;
  FLine := 1;
  FLineStart := 1;
  if WordsLexer <> nil then
    CopyNames(WordsLexer)
  else
    InternWords;
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

{ The name table }

{ Rebuilt with four slots per name or more (kept at least half empty;
  a power of two: the hash is masked). }
procedure TJsLexer.GrowNameSlots;
var
  Index, Size: Integer;
begin
  Size := 1024;
  while Size < FNameCount * 4 do
    Size := Size * 2;
  FNameSlots := nil;
  SetLength(FNameSlots, Size);
  for Index := 0 to FNameCount - 1 do
    InsertNameSlot(Index);
end;

procedure TJsLexer.InsertNameSlot(Entry: Integer);
var
  Mask, Slot: LongWord;
begin
  Mask := LongWord(Length(FNameSlots) - 1);
  Slot := FNameHashes[Entry] and Mask;
  while FNameSlots[Slot].Entry <> 0 do
    Slot := (Slot + 1) and Mask;
  FNameSlots[Slot].Hash := FNameHashes[Entry];
  FNameSlots[Slot].Entry := Entry + 1;
end;

{ The index of the name written at Start (Count units, hashed to Hash);
  -1 when it is new. }
function TJsLexer.FindName(Start, Count: Integer; Hash: LongWord): Integer;
var
  Mask, Slot: LongWord;
  Entry, Index: Integer;
  Text, Name: PWideChar;
begin
  Text := @FSource[Start];
  Mask := LongWord(Length(FNameSlots) - 1);
  Slot := Hash and Mask;
  while True do
  begin
    Entry := FNameSlots[Slot].Entry;
    if Entry = 0 then
      Exit(-1);
    if FNameSlots[Slot].Hash = Hash then
    begin
      Dec(Entry);
      if Length(FNames[Entry]) = Count then
      begin
        { Names are short: a loop rather than a call. }
        Name := PWideChar(FNames[Entry]);
        Index := 0;
        while (Index < Count) and (Name[Index] = Text[Index]) do
          Inc(Index);
        if Index = Count then
          Exit(Entry);
      end;
    end;
    Slot := (Slot + 1) and Mask;
  end;
end;

{ A new entry (an identifier, no text yet), not in the slots yet. }
function TJsLexer.NewNameEntry(Hash: LongWord): Integer;
begin
  if FNameCount >= Length(FNames) then
  begin
    SetLength(FNames, Length(FNames) * 2 + 256);
    SetLength(FNameKinds, Length(FNames));
    SetLength(FNameWords, Length(FNames));
    SetLength(FNameHashes, Length(FNames));
  end;
  Result := FNameCount;
  FNameKinds[Result] := tkIdentifier;
  FNameWords[Result] := jwNone;
  FNameHashes[Result] := Hash;
  Inc(FNameCount);
end;

{ A new name, the source's units from Start. }
function TJsLexer.AddName(Start, Count: Integer; Hash: LongWord): Integer;
begin
  Result := NewNameEntry(Hash);
  SetString(FNames[Result], PWideChar(@FSource[Start]), Count);
  if FNameCount * 2 > Length(FNameSlots) then
    GrowNameSlots
  else
    InsertNameSlot(Result);
end;

{ A name that is not a slice of the source as written (escapes): the
  text itself is entered. }
function TJsLexer.InternText(const Text: UnicodeString): Integer;
var
  Hash, Mask, Slot: LongWord;
  Entry: Integer;
begin
  Hash := NameHash(PWideChar(Text), Length(Text));
  Mask := LongWord(Length(FNameSlots) - 1);
  Slot := Hash and Mask;
  while FNameSlots[Slot].Entry <> 0 do
  begin
    Entry := FNameSlots[Slot].Entry - 1;
    if (FNameSlots[Slot].Hash = Hash) and (FNames[Entry] = Text) then
      Exit(Entry);
    Slot := (Slot + 1) and Mask;
  end;
  Result := NewNameEntry(Hash);
  FNames[Result] := Text;
  if FNameCount * 2 > Length(FNameSlots) then
    GrowNameSlots
  else
    InsertNameSlot(Result);
end;

{ The reserved and contextual words come first: a name scanned later
  finds what it is on its entry. }
procedure TJsLexer.InternWords;
var
  Keyword: TJsTokenKind;
  Word: TJsWord;
  Name: Integer;
begin
  GrowNameSlots;
  { Entered first, then marked: entering may move the arrays. }
  for Keyword := Low(KeywordTexts) to High(KeywordTexts) do
  begin
    Name := InternText(KeywordTexts[Keyword]);
    FNameKinds[Name] := Keyword;
  end;
  for Word := Low(WordTexts) to High(WordTexts) do
  begin
    Name := InternText(WordTexts[Word]);
    FNameWords[Name] := Word;
  end;
end;

{ The table of a lexer that only knows the words (cheaper than entering
  them again: a lazily compiled function makes a lexer of its own). }
procedure TJsLexer.CopyNames(From: TJsLexer);
begin
  FNames := Copy(From.FNames);
  FNameKinds := Copy(From.FNameKinds);
  FNameWords := Copy(From.FNameWords);
  FNameHashes := Copy(From.FNameHashes);
  FNameSlots := Copy(From.FNameSlots);
  FNameCount := From.FNameCount;
end;

function TJsLexer.IsReservedName(Name: Integer): Boolean;
begin
  Result := FNameKinds[Name] <> tkIdentifier;
end;

{ Space and comments }

{ A comment at FPosition (/, < or - starts it), skipped; nothing moves
  when the character starts a token instead. }
procedure TJsLexer.SkipComment;
var
  Character: WideChar;
begin
  Character := FSource[FPosition];
  if (Character = '/') and (Peek(1) = '/') then
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
  else if ((Character = '<') and (Peek(1) = '!') and (Peek(2) = '-') and (Peek(3) = '-')) or
    ((Character = '-') and (Peek(1) = '-') and (Peek(2) = '>') and (FNewline or (FPosition = 1))) then
  begin
    { An HTML-like comment (Annex B). }
    while (FPosition <= FLength) and not IsLineTerminator(FSource[FPosition]) do
      Inc(FPosition);
  end;
end;

procedure TJsLexer.SkipSpace;
var
  Character: WideChar;
  Before: Integer;
begin
  while FPosition <= FLength do
  begin
    Character := FSource[FPosition];
    if Ord(Character) < 128 then
    begin
      case SpaceClasses[Ord(Character)] of
        scToken:
          Exit;
        scBlank:
          Inc(FPosition);
        scNewline:
          begin
            if (Character = #13) and (Peek(1) = #10) then
              Inc(FPosition);
            Inc(FPosition);
            Inc(FLine);
            FLineStart := FPosition;
            FNewline := True;
          end;
        scMaybeComment:
          begin
            Before := FPosition;
            SkipComment;
            if FPosition = Before then
              Exit;
          end;
      end;
    end
    else if IsLineTerminator(Character) then
    begin
      Inc(FPosition);
      Inc(FLine);
      FLineStart := FPosition;
      FNewline := True;
    end
    else if IsJsWhiteSpace(Character) then
      Inc(FPosition)
    else
      Exit;
  end;
end;

{ Escapes }

{ After the backslash: the escape's code point; -1 for none (a line
  continuation, or a bad escape in a template, noted on the token). }
function TJsLexer.ScanEscape(var Token: TJsToken; InTemplate: Boolean): LongInt;
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
  Result := -1;
  if FPosition > FLength then
    Fail('Unterminated string');
  Character := FSource[FPosition];
  Inc(FPosition);
  case Character of
    'n': Result := 10;
    't': Result := 9;
    'r': Result := 13;
    'b': Result := 8;
    'f': Result := 12;
    'v': Result := 11;
    '0'..'7':
      begin
        if (Character = '0') and not ((Peek >= '0') and (Peek <= '9')) then
          Exit(0);
        if InTemplate then
        begin
          Token.InvalidEscape := True;
          Exit(-1);
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
        Result := Value;
      end;
    '8', '9':
      begin
        if InTemplate then
          Token.InvalidEscape := True
        else
          Token.LegacyOctal := True;
        Result := Ord(Character);
      end;
    'x':
      begin
        if (HexValue(Peek) < 0) or (HexValue(Peek(1)) < 0) then
        begin
          Bad('Invalid hexadecimal escape sequence');
          Exit(-1);
        end;
        Result := HexValue(Peek) * 16 + HexValue(Peek(1));
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
            Exit(-1);
          end;
          Inc(FPosition);
          Result := Value;
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
              Exit(-1);
            end;
            Value := Value * 16 + Digit;
            Inc(FPosition);
          end;
          Result := Value;
        end;
      end;
    #13:
      begin
        if Peek = #10 then
          Inc(FPosition);
        Inc(FLine);
        FLineStart := FPosition;
      end;
    #10, #$2028, #$2029:
      begin
        Inc(FLine);
        FLineStart := FPosition;
      end;
  else
    Result := Ord(Character);
  end;
end;

{ Identifiers }

{ The common case, ASCII letters, digits, $ and _ only, hashed while
  scanned and looked up in place (no strings made: this runs for every
  identifier and keyword). }
procedure TJsLexer.ScanIdentifier(var Token: TJsToken);
var
  Start, Position, Count: Integer;
  Code: LongWord;
  Hash: LongWord;
  Text: PWideChar;
begin
  Start := FPosition;
  Position := Start;
  Text := PWideChar(FSource) - 1;
  Hash := HashOffset;
  {$push}{$R-}{$Q-}
  while Position <= FLength do
  begin
    Code := Ord(Text[Position]);
    if (Code >= 128) or not IdentifierParts[Code] then
      Break;
    Hash := (Hash xor Code) * HashPrime;
    Inc(Position);
  end;
  {$pop}
  if (Position <= FLength) and ((Text[Position] = '\') or (Ord(Text[Position]) >= 128)) then
  begin
    ScanUnusualIdentifier(Token);
    Exit;
  end;
  FPosition := Position;
  Count := Position - Start;
  Token.Name := FindName(Start, Count, Hash);
  if Token.Name < 0 then
    Token.Name := AddName(Start, Count, Hash);
  Token.Kind := FNameKinds[Token.Name];
  Token.Word := FNameWords[Token.Name];
end;

{ An identifier with escapes or characters beyond ASCII. }
procedure TJsLexer.ScanUnusualIdentifier(var Token: TJsToken);
var
  Name: UnicodeString;
  Character: WideChar;
  Dummy: TJsToken;
  CodePoint: LongInt;
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
      CodePoint := ScanEscape(Dummy, False);
      if CodePoint < 0 then
        Fail('Invalid escape in identifier');
      if ((Name = '') and not IsIdentifierStart(CodePoint)) or ((Name <> '') and not IsIdentifierPart(CodePoint)) then
        Fail('Invalid identifier escape');
      Token.Escaped := True;
      Name := Name + CodePointText(CodePoint);
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
  Token.Name := InternText(Name);
  Token.Word := FNameWords[Token.Name];
  if Token.Escaped then
    Token.Kind := tkIdentifier
  else
    Token.Kind := FNameKinds[Token.Name];
end;

{ Numbers }

{ The common case: a decimal integer of up to 15 digits, no separators,
  fraction, exponent or suffix. False (nothing consumed) otherwise. }
function TJsLexer.ScanSimpleInteger(var Token: TJsToken): Boolean;
var
  Start, Index: Integer;
  Value: Int64;
  Character: WideChar;
begin
  Result := False;
  Start := FPosition;
  Index := FPosition;
  Value := 0;
  while (Index <= FLength) and (FSource[Index] >= '0') and (FSource[Index] <= '9') do
  begin
    Value := Value * 10 + (Ord(FSource[Index]) - Ord('0'));
    Inc(Index);
  end;
  if (Index - Start > 15) or ((FSource[Start] = '0') and (Index - Start > 1)) then
    Exit;
  if Index <= FLength then
  begin
    Character := FSource[Index];
    case Character of
      '.', '_', '$', '\', 'a'..'z', 'A'..'Z':
        Exit;
    end;
    if Ord(Character) > 127 then
      Exit;
  end;
  FPosition := Index;
  Token.Number := Value;
  Result := True;
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
  if ScanSimpleInteger(Token) then
    Exit;
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
    { The digits are taken from the source when asked for (DecodeBigInt). }
    Inc(FPosition);
    Token.Kind := tkBigInt;
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
  end;
  if (FPosition <= FLength) and (IsIdentifierStart(Ord(FSource[FPosition])) or
    ((FSource[FPosition] >= '0') and (FSource[FPosition] <= '9'))) then
    Fail('Invalid or unexpected token');
end;

procedure TJsLexer.DecodeBigInt(const Token: TJsToken; var Digits: UnicodeString);
var
  Index, First: Integer;
begin
  Digits := '';
  First := Token.Start;
  if Token.Number <> 10 then
    Inc(First, 2);
  { Up to the n. }
  for Index := First to Token.Finish - 2 do
    if FSource[Index] <> '_' then
      Digits := Digits + FSource[Index];
end;

{ Strings }

{ Checked to its end; the value is decoded when asked for. }
procedure TJsLexer.ScanString(var Token: TJsToken; Quote: WideChar);
var
  Character: WideChar;
begin
  Inc(FPosition);
  while True do
  begin
    if FPosition > FLength then
      Fail('Unterminated string');
    Character := FSource[FPosition];
    if Character = Quote then
      Break;
    if Character = '\' then
    begin
      Inc(FPosition);
      Token.HasEscape := True;
      ScanEscape(Token, False);
      Continue;
    end;
    if (Character = #10) or (Character = #13) then
      Fail('Unterminated string');
    Inc(FPosition);
  end;
  Inc(FPosition);
  Token.Kind := tkString;
end;

procedure TJsLexer.DecodeString(const Token: TJsToken; var Text: UnicodeString);
var
  SavedPosition, SavedLine, SavedLineStart, Start, CodePoint: Integer;
  Scratch: TJsToken;
begin
  if not Token.HasEscape then
  begin
    SetString(Text, PWideChar(@FSource[Token.Start + 1]), Token.Finish - Token.Start - 2);
    Exit;
  end;
  SavePosition(SavedPosition, SavedLine, SavedLineStart);
  Scratch := Token;
  Text := '';
  FPosition := Token.Start + 1;
  Start := FPosition;
  while FPosition < Token.Finish - 1 do
  begin
    if FSource[FPosition] = '\' then
    begin
      Text := Text + Copy(FSource, Start, FPosition - Start);
      Inc(FPosition);
      CodePoint := ScanEscape(Scratch, False);
      if CodePoint >= 0 then
        Text := Text + CodePointText(CodePoint);
      Start := FPosition;
    end
    else
      Inc(FPosition);
  end;
  Text := Text + Copy(FSource, Start, Token.Finish - 1 - Start);
  RestorePosition(SavedPosition, SavedLine, SavedLineStart);
end;

function TJsLexer.IsUseStrict(const Token: TJsToken): Boolean;
const
  Directive: UnicodeString = 'use strict';
begin
  Result := (Token.Kind = tkString) and (Token.Finish - Token.Start = Length(Directive) + 2) and
    (CompareWord(FSource[Token.Start + 1], Directive[1], Length(Directive)) = 0);
end;

{ Templates }

{ From just after the backquote or the closing brace to the end of the
  piece (a backquote, or dollar and brace): checked, its lines counted. }
procedure TJsLexer.ScanTemplatePiece(var Token: TJsToken);
var
  Character: WideChar;
begin
  Token.Kind := tkTemplate;
  Token.InvalidEscape := False;
  Token.HasEscape := False;
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
      Token.HasEscape := True;
      Inc(FPosition);
      ScanEscape(Token, True);
      Continue;
    end;
    if Character = #13 then
    begin
      Token.HasEscape := True;
      if Peek(1) = #10 then
        Inc(FPosition);
      Character := #10;
    end;
    if IsLineTerminator(Character) then
    begin
      Inc(FLine);
      FLineStart := FPosition + 1;
    end;
    Inc(FPosition);
  end;
  Token.Finish := FPosition;
end;

procedure TJsLexer.ScanTemplate(var Token: TJsToken);
begin
  { The piece starts at the closing brace. }
  Token.Start := FPosition - 1;
  ScanTemplatePiece(Token);
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

procedure TJsLexer.DecodeTemplate(const Token: TJsToken; var Cooked, Raw: UnicodeString);
var
  SavedPosition, SavedLine, SavedLineStart, Finish, RawStart, CodePoint: Integer;
  Character: WideChar;
  Scratch: TJsToken;
begin
  { The text between the opening backquote or closing brace and the
    closing backquote or dollar and brace. }
  if Token.TemplateTail then
    Finish := Token.Finish - 1
  else
    Finish := Token.Finish - 2;
  if not Token.HasEscape then
  begin
    SetString(Cooked, PWideChar(@FSource[Token.Start + 1]), Finish - Token.Start - 1);
    Raw := Cooked;
    Exit;
  end;
  SavePosition(SavedPosition, SavedLine, SavedLineStart);
  Scratch := Token;
  Cooked := '';
  Raw := '';
  FPosition := Token.Start + 1;
  while FPosition < Finish do
  begin
    Character := FSource[FPosition];
    if Character = '\' then
    begin
      RawStart := FPosition;
      Inc(FPosition);
      CodePoint := ScanEscape(Scratch, True);
      if CodePoint >= 0 then
        Cooked := Cooked + CodePointText(CodePoint);
      Raw := Raw + NormalizeLineEnds(Copy(FSource, RawStart, FPosition - RawStart));
      Continue;
    end;
    if Character = #13 then
    begin
      if (FPosition + 1 < Finish) and (FSource[FPosition + 1] = #10) then
        Inc(FPosition);
      Character := #10;
    end;
    Cooked := Cooked + Character;
    Raw := Raw + Character;
    Inc(FPosition);
  end;
  RestorePosition(SavedPosition, SavedLine, SavedLineStart);
end;

{ Regular expressions }

procedure TJsLexer.ScanRegExp(var Token: TJsToken);
var
  InClass: Boolean;
  Character: WideChar;
begin
  FPosition := Token.Start + 1;
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
      Inc(FPosition);
      Continue;
    end;
    if Character = '[' then
      InClass := True
    else if Character = ']' then
      InClass := False
    else if (Character = '/') and not InClass then
      Break;
  end;
  Token.FlagsStart := FPosition;
  while (FPosition <= FLength) and IsIdentifierPart(Ord(FSource[FPosition])) do
    Inc(FPosition);
  Token.Kind := tkRegExp;
  Token.Finish := FPosition;
end;

procedure TJsLexer.DecodeRegExp(const Token: TJsToken; var Body, Flags: UnicodeString);
begin
  Body := Copy(FSource, Token.Start + 1, Token.FlagsStart - Token.Start - 2);
  Flags := Copy(FSource, Token.FlagsStart, Token.Finish - Token.FlagsStart);
end;

{ Punctuators }

procedure TJsLexer.ScanPunctuator(var Token: TJsToken);
var
  Best: TJsTokenKind;
  BestLength: Integer;
  Next1, Next2, Next3: WideChar;

  procedure Take(Kind: TJsTokenKind; Size: Integer); inline;
  begin
    Best := Kind;
    BestLength := Size;
  end;

begin
  Best := tkEnd;
  BestLength := 0;
  Next1 := Peek(1);
  { The longest punctuator starting here. }
  case FSource[FPosition] of
    '{': Take(tkLeftBrace, 1);
    '}': Take(tkRightBrace, 1);
    '(': Take(tkLeftParen, 1);
    ')': Take(tkRightParen, 1);
    '[': Take(tkLeftBracket, 1);
    ']': Take(tkRightBracket, 1);
    ';': Take(tkSemicolon, 1);
    ',': Take(tkComma, 1);
    '~': Take(tkTilde, 1);
    ':': Take(tkColon, 1);
    '#': Take(tkHash, 1);
    '@': Take(tkAt, 1);
    '.':
      if (Next1 = '.') and (Peek(2) = '.') then
        Take(tkEllipsis, 3)
      else
        Take(tkDot, 1);
    '<':
      if Next1 = '<' then
      begin
        if Peek(2) = '=' then
          Take(tkShiftLeftAssign, 3)
        else
          Take(tkShiftLeft, 2);
      end
      else if Next1 = '=' then
        Take(tkLessEqual, 2)
      else
        Take(tkLess, 1);
    '>':
      if Next1 = '>' then
      begin
        Next2 := Peek(2);
        if Next2 = '>' then
        begin
          Next3 := Peek(3);
          if Next3 = '=' then
            Take(tkShiftRightUnsignedAssign, 4)
          else
            Take(tkShiftRightUnsigned, 3);
        end
        else if Next2 = '=' then
          Take(tkShiftRightAssign, 3)
        else
          Take(tkShiftRight, 2);
      end
      else if Next1 = '=' then
        Take(tkGreaterEqual, 2)
      else
        Take(tkGreater, 1);
    '=':
      if Next1 = '=' then
      begin
        if Peek(2) = '=' then
          Take(tkStrictEqual, 3)
        else
          Take(tkEqual, 2);
      end
      else if Next1 = '>' then
        Take(tkArrow, 2)
      else
        Take(tkAssign, 1);
    '!':
      if Next1 = '=' then
      begin
        if Peek(2) = '=' then
          Take(tkStrictNotEqual, 3)
        else
          Take(tkNotEqual, 2);
      end
      else
        Take(tkBang, 1);
    '+':
      if Next1 = '+' then
        Take(tkPlusPlus, 2)
      else if Next1 = '=' then
        Take(tkPlusAssign, 2)
      else
        Take(tkPlus, 1);
    '-':
      if Next1 = '-' then
        Take(tkMinusMinus, 2)
      else if Next1 = '=' then
        Take(tkMinusAssign, 2)
      else
        Take(tkMinus, 1);
    '*':
      if Next1 = '*' then
      begin
        if Peek(2) = '=' then
          Take(tkStarStarAssign, 3)
        else
          Take(tkStarStar, 2);
      end
      else if Next1 = '=' then
        Take(tkStarAssign, 2)
      else
        Take(tkStar, 1);
    '/':
      if Next1 = '=' then
        Take(tkSlashAssign, 2)
      else
        Take(tkSlash, 1);
    '%':
      if Next1 = '=' then
        Take(tkPercentAssign, 2)
      else
        Take(tkPercent, 1);
    '&':
      if Next1 = '&' then
      begin
        if Peek(2) = '=' then
          Take(tkAndAndAssign, 3)
        else
          Take(tkAndAnd, 2);
      end
      else if Next1 = '=' then
        Take(tkAmpersandAssign, 2)
      else
        Take(tkAmpersand, 1);
    '|':
      if Next1 = '|' then
      begin
        if Peek(2) = '=' then
          Take(tkOrOrAssign, 3)
        else
          Take(tkOrOr, 2);
      end
      else if Next1 = '=' then
        Take(tkBarAssign, 2)
      else
        Take(tkBar, 1);
    '^':
      if Next1 = '=' then
        Take(tkCaretAssign, 2)
      else
        Take(tkCaret, 1);
    '?':
      if Next1 = '?' then
      begin
        if Peek(2) = '=' then
          Take(tkQuestionQuestionAssign, 3)
        else
          Take(tkQuestionQuestion, 2);
      end
      { ?. followed by a digit is ? then a number (a ? .5 : b). }
      else if (Next1 = '.') and not ((Peek(2) >= '0') and (Peek(2) <= '9')) then
        Take(tkQuestionDot, 2)
      else
        Take(tkQuestion, 1);
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
  Token.Kind := tkEnd;
  Token.Word := jwNone;
  Token.Name := -1;
  Token.Number := 0;
  Token.TemplateTail := False;
  Token.InvalidEscape := False;
  Token.LegacyOctal := False;
  Token.Escaped := False;
  Token.HasEscape := False;
  Token.FlagsStart := 0;
  FNewline := False;
  SkipSpace;
  Token.NewlineBefore := FNewline;
  Token.Start := FPosition;
  Token.Line := FLine;
  Token.Column := FPosition - FLineStart + 1;
  if FPosition > FLength then
  begin
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
        ScanTemplatePiece(Token);
      end;
    '#':
      begin
        Inc(FPosition);
        if (FPosition <= FLength) and (IsIdentifierStart(Ord(FSource[FPosition])) or (FSource[FPosition] = '\') or
          ((FSource[FPosition] >= #$D800) and (FSource[FPosition] <= #$DBFF))) then
        begin
          ScanIdentifier(Token);
          Token.Kind := tkPrivateName;
          Token.Word := jwNone;
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

initialization
  FillCharacterClasses;
  WordsLexer := TJsLexer.Create('');
finalization
  WordsLexer.Free;
end.
