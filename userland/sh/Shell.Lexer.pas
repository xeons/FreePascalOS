{
  Splitting shell input into tokens.

  A word token keeps its raw text, quotes and backslashes included;
  expansion (Shell.Expansion) interprets them later, when the command
  runs, because variables can change between parsing and running.

  Operators: newline ; ;; & | && || ( ) and the redirections
    < > >> <& >&    each optionally preceded by a handle number (2>file)
    <<WORD <<-WORD  here-documents

  A here-document's body is the lines after the next line end, up to a
  line consisting of WORD; the lexer collects it into the redirection
  token. With <<- leading tabs are removed from the body and from the
  delimiter line. If WORD is quoted in any way, the body is taken
  literally; otherwise it is expanded like text in double quotes.

  "#" at the start of a word begins a comment that runs to the line end.
  Every token records where it starts and ends in the input, so that the
  parser can keep the source text of function definitions.
}
unit Shell.Lexer;

{$mode objfpc}
{$pointermath on}

interface

type
  TTokenKind = (TokenWord, TokenNewline, TokenSemicolon, TokenDoubleSemicolon, TokenAmpersand,
    TokenPipe, TokenAndIf, TokenOrIf, TokenLeftParenthesis, TokenRightParenthesis, TokenRedirect,
    TokenEnd);

  TRedirectKind = (RedirectInput, RedirectOutput, RedirectAppend, RedirectDuplicate,
    RedirectHereDocument);

  PToken = ^TToken;
  TToken = record
    Kind: TTokenKind;
    Text: PChar;              { TokenWord: raw text (heap) }
    RedirectKind: TRedirectKind;
    RedirectHandle: Integer;  { the handle being redirected }
    { RedirectHereDocument: the body (heap), and whether the delimiter
      was quoted (no expansion). }
    HereBody: PChar;
    HereIsQuoted: Boolean;
    StripTabs: Boolean;
    { Byte offsets of the token in the input. }
    StartOffset: PtrUInt;
    EndOffset: PtrUInt;
  end;

  TTokenList = record
    Items: PToken;
    Count: Integer;
    Capacity: Integer;
  end;

  TLexResult = (LexComplete, LexIncomplete);

{ Tokenizes Text. LexIncomplete means a quote, $( or here-document is
  still open, so more input is needed. The list always ends with
  TokenEnd. }
function Tokenize(Text: PChar; out Tokens: TTokenList): TLexResult;
procedure FreeTokens(var Tokens: TTokenList);

{ The delimiter of a here-document with quotes removed. }
function UnquoteDelimiter(Word: PChar; out WasQuoted: Boolean): PChar;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Memory,
  Sys.Text;

const
  MaximumPendingHereDocuments = 16;

procedure AddToken(var Tokens: TTokenList; const Token: TToken);
begin
  if Tokens.Count = Tokens.Capacity then
  begin
    if Tokens.Capacity = 0 then
      Tokens.Capacity := 32
    else
      Tokens.Capacity := Tokens.Capacity * 2;
    Tokens.Items := PToken(ReallocateMemory(Tokens.Items, QWord(Tokens.Capacity) * SizeOf(TToken)));
  end;
  Tokens.Items[Tokens.Count] := Token;
  Inc(Tokens.Count);
end;

procedure AddOperator(var Tokens: TTokenList; Kind: TTokenKind; Start, Finish: PtrUInt);
var
  Token: TToken;
begin
  FillMemory(@Token, SizeOf(Token), 0);
  Token.Kind := Kind;
  Token.StartOffset := Start;
  Token.EndOffset := Finish;
  AddToken(Tokens, Token);
end;

procedure AddRedirect(var Tokens: TTokenList; Kind: TRedirectKind; Handle: Integer; Start, Finish: PtrUInt);
var
  Token: TToken;
begin
  FillMemory(@Token, SizeOf(Token), 0);
  Token.Kind := TokenRedirect;
  Token.RedirectKind := Kind;
  Token.RedirectHandle := Handle;
  Token.StartOffset := Start;
  Token.EndOffset := Finish;
  AddToken(Tokens, Token);
end;

function IsOperatorStart(Character: Char): Boolean;
begin
  Result := Character in [#10, ';', '&', '|', '(', ')', '<', '>'];
end;

function IsBlank(Character: Char): Boolean;
begin
  Result := (Character = ' ') or (Character = #9) or (Character = #13);
end;

{ Skips a $( ... ) starting at Text[Position] = '$'. Returns False if
  it is not closed. Position ends just after the closing parenthesis. }
function SkipCommandSubstitution(Text: PChar; var Position: PtrUInt): Boolean; forward;

{ Skips the quoted text starting at the opening quote. }
function SkipQuoted(Text: PChar; var Position: PtrUInt): Boolean;
var
  Quote: Char;
begin
  Quote := Text[Position];
  Inc(Position);
  while Text[Position] <> Quote do
  begin
    if Text[Position] = #0 then
      Exit(False);
    if (Quote = '"') and (Text[Position] = '\') and (Text[Position + 1] <> #0) then
      Inc(Position, 2)
    else if (Quote = '"') and (Text[Position] = '$') and (Text[Position + 1] = '(') then
    begin
      if not SkipCommandSubstitution(Text, Position) then
        Exit(False);
    end
    else
      Inc(Position);
  end;
  Inc(Position);
  Result := True;
end;

function SkipCommandSubstitution(Text: PChar; var Position: PtrUInt): Boolean;
var
  Depth: Integer;
begin
  Inc(Position, 2);
  Depth := 1;
  while Depth > 0 do
  begin
    case Text[Position] of
      #0: Exit(False);
      '''', '"':
        begin
          if not SkipQuoted(Text, Position) then
            Exit(False);
          Continue;
        end;
      '\':
        if Text[Position + 1] <> #0 then
          Inc(Position);
      '(': Inc(Depth);
      ')': Dec(Depth);
    end;
    Inc(Position);
  end;
  Result := True;
end;

{ Reads a word starting at Position; returns False if a quote is open. }
function ReadWord(Text: PChar; var Position: PtrUInt; out Word: PChar): Boolean;
var
  Start: PtrUInt;
  Length: PtrUInt;
begin
  Word := nil;
  Start := Position;
  while (Text[Position] <> #0) and not IsBlank(Text[Position]) and not IsOperatorStart(Text[Position]) do
  begin
    case Text[Position] of
      '''', '"':
        if not SkipQuoted(Text, Position) then
          Exit(False);
      '\':
        begin
          if Text[Position + 1] = #0 then
            Exit(False);
          Inc(Position, 2);
        end;
      '$':
        if Text[Position + 1] = '(' then
        begin
          if not SkipCommandSubstitution(Text, Position) then
            Exit(False);
        end
        else
          Inc(Position);
    else
      Inc(Position);
    end;
  end;
  Length := Position - Start;
  Word := PChar(AllocateMemory(Length + 1));
  CopyMemory(Word, Text + Start, Length);
  Word[Length] := #0;
  Result := True;
end;

function AllDigits(Word: PChar): Boolean;
var
  Index: Integer;
begin
  Result := Word[0] <> #0;
  Index := 0;
  while Word[Index] <> #0 do
  begin
    if not IsDigit(Word[Index]) then
      Exit(False);
    Inc(Index);
  end;
end;

procedure ReadRedirect(Text: PChar; var Position: PtrUInt; var Tokens: TTokenList; Handle: Integer;
  Start: PtrUInt);
begin
  if Text[Position] = '<' then
  begin
    if Handle < 0 then
      Handle := 0;
    Inc(Position);
    if Text[Position] = '<' then
    begin
      Inc(Position);
      AddRedirect(Tokens, RedirectHereDocument, Handle, Start, Position);
      if Text[Position] = '-' then
      begin
        Inc(Position);
        Tokens.Items[Tokens.Count - 1].StripTabs := True;
        Tokens.Items[Tokens.Count - 1].EndOffset := Position;
      end;
    end
    else if Text[Position] = '&' then
    begin
      Inc(Position);
      AddRedirect(Tokens, RedirectDuplicate, Handle, Start, Position);
    end
    else
      AddRedirect(Tokens, RedirectInput, Handle, Start, Position);
    Exit;
  end;

  if Handle < 0 then
    Handle := 1;
  Inc(Position);
  if Text[Position] = '>' then
  begin
    Inc(Position);
    AddRedirect(Tokens, RedirectAppend, Handle, Start, Position);
  end
  else if Text[Position] = '&' then
  begin
    Inc(Position);
    AddRedirect(Tokens, RedirectDuplicate, Handle, Start, Position);
  end
  else
    AddRedirect(Tokens, RedirectOutput, Handle, Start, Position);
end;

function UnquoteDelimiter(Word: PChar; out WasQuoted: Boolean): PChar;
var
  Builder: TTextBuilder;
  Index: PtrUInt;
begin
  WasQuoted := False;
  BeginText(Builder);
  Index := 0;
  while Word[Index] <> #0 do
  begin
    case Word[Index] of
      '''', '"':
        WasQuoted := True;
      '\':
        begin
          WasQuoted := True;
          if Word[Index + 1] <> #0 then
          begin
            Inc(Index);
            AppendCharacter(Builder, Word[Index]);
          end;
        end;
    else
      AppendCharacter(Builder, Word[Index]);
    end;
    Inc(Index);
  end;
  Result := FinishText(Builder);
end;

{ Collects the body of the here-document of token TokenIndex, starting
  at Position (the start of the line after the command). Returns False
  if the input ends before the delimiter line. }
function ReadHereDocument(Text: PChar; var Position: PtrUInt; var Tokens: TTokenList;
  TokenIndex: Integer): Boolean;
var
  Redirect: PToken;
  Delimiter: PChar;
  Body: TTextBuilder;
  LineStart: PtrUInt;
  LineEnd: PtrUInt;
  ContentStart: PtrUInt;
  DelimiterLength: PtrUInt;
begin
  Result := False;
  Redirect := @Tokens.Items[TokenIndex];
  { The delimiter word follows the redirection token. }
  if (TokenIndex + 1 >= Tokens.Count) or (Tokens.Items[TokenIndex + 1].Kind <> TokenWord) then
    Exit(True); { the parser reports the missing word }
  Delimiter := UnquoteDelimiter(Tokens.Items[TokenIndex + 1].Text, Redirect^.HereIsQuoted);
  DelimiterLength := TextLength(Delimiter);
  BeginText(Body);
  while True do
  begin
    if Text[Position] = #0 then
    begin
      DiscardText(Body);
      FreeMemory(Delimiter);
      Exit(False);
    end;
    LineStart := Position;
    LineEnd := Position;
    while (Text[LineEnd] <> #10) and (Text[LineEnd] <> #0) do
      Inc(LineEnd);
    ContentStart := LineStart;
    if Redirect^.StripTabs then
      while (ContentStart < LineEnd) and (Text[ContentStart] = #9) do
        Inc(ContentStart);
    { A line end that is the last thing in the input still counts: the
      delimiter line needs one, or the end of the text. }
    if (LineEnd - ContentStart = DelimiterLength) and
       MemoryIsEqual(Text + ContentStart, Delimiter, DelimiterLength) then
    begin
      Position := LineEnd;
      if Text[Position] = #10 then
        Inc(Position);
      Break;
    end;
    if Text[LineEnd] = #0 then
    begin
      DiscardText(Body);
      FreeMemory(Delimiter);
      Exit(False);
    end;
    AppendBytes(Body, Text + ContentStart, LineEnd - ContentStart);
    AppendCharacter(Body, #10);
    Position := LineEnd + 1;
  end;
  Redirect^.HereBody := FinishText(Body);
  FreeMemory(Delimiter);
  Result := True;
end;

function Tokenize(Text: PChar; out Tokens: TTokenList): TLexResult;
var
  Position: PtrUInt;
  Start: PtrUInt;
  Word: PChar;
  Token: TToken;
  Handle: Int64;
  Pending: array[0..MaximumPendingHereDocuments - 1] of Integer;
  PendingCount: Integer;
  PendingIndex: Integer;
begin
  Tokens.Items := nil;
  Tokens.Count := 0;
  Tokens.Capacity := 0;
  Result := LexComplete;
  Position := 0;
  PendingCount := 0;

  while Text[Position] <> #0 do
  begin
    if IsBlank(Text[Position]) then
    begin
      Inc(Position);
      Continue;
    end;
    if (Text[Position] = '\') and (Text[Position + 1] = #10) then
    begin
      { A line continuation. }
      Inc(Position, 2);
      Continue;
    end;
    if Text[Position] = '#' then
    begin
      while (Text[Position] <> #0) and (Text[Position] <> #10) do
        Inc(Position);
      Continue;
    end;

    Start := Position;
    case Text[Position] of
      #10:
        begin
          AddOperator(Tokens, TokenNewline, Start, Start + 1);
          Inc(Position);
          { Here-document bodies start on the next line. }
          for PendingIndex := 0 to PendingCount - 1 do
            if not ReadHereDocument(Text, Position, Tokens, Pending[PendingIndex]) then
            begin
              Result := LexIncomplete;
              AddOperator(Tokens, TokenEnd, Position, Position);
              Exit;
            end;
          PendingCount := 0;
        end;
      ';':
        if Text[Position + 1] = ';' then
        begin
          AddOperator(Tokens, TokenDoubleSemicolon, Start, Start + 2);
          Inc(Position, 2);
        end
        else
        begin
          AddOperator(Tokens, TokenSemicolon, Start, Start + 1);
          Inc(Position);
        end;
      '&':
        if Text[Position + 1] = '&' then
        begin
          AddOperator(Tokens, TokenAndIf, Start, Start + 2);
          Inc(Position, 2);
        end
        else
        begin
          AddOperator(Tokens, TokenAmpersand, Start, Start + 1);
          Inc(Position);
        end;
      '|':
        if Text[Position + 1] = '|' then
        begin
          AddOperator(Tokens, TokenOrIf, Start, Start + 2);
          Inc(Position, 2);
        end
        else
        begin
          AddOperator(Tokens, TokenPipe, Start, Start + 1);
          Inc(Position);
        end;
      '(':
        begin
          AddOperator(Tokens, TokenLeftParenthesis, Start, Start + 1);
          Inc(Position);
        end;
      ')':
        begin
          AddOperator(Tokens, TokenRightParenthesis, Start, Start + 1);
          Inc(Position);
        end;
      '<', '>':
        ReadRedirect(Text, Position, Tokens, -1, Start);
    else
      begin
        if not ReadWord(Text, Position, Word) then
        begin
          Result := LexIncomplete;
          Break;
        end;
        { "2>" is a redirection of handle 2, not the word "2". }
        if AllDigits(Word) and (Text[Position] in ['<', '>']) and ParseInteger(Word, Handle) then
        begin
          FreeMemory(Word);
          ReadRedirect(Text, Position, Tokens, Integer(Handle), Start);
        end
        else
        begin
          FillMemory(@Token, SizeOf(Token), 0);
          Token.Kind := TokenWord;
          Token.Text := Word;
          Token.StartOffset := Start;
          Token.EndOffset := Position;
          AddToken(Tokens, Token);
        end;
      end;
    end;

    { A here-document redirection waits for its body at the next line
      end (it applies once its delimiter word has been read). }
    if (Tokens.Count >= 2) and (Tokens.Items[Tokens.Count - 1].Kind = TokenWord) and
       (Tokens.Items[Tokens.Count - 2].Kind = TokenRedirect) and
       (Tokens.Items[Tokens.Count - 2].RedirectKind = RedirectHereDocument) and
       (Tokens.Items[Tokens.Count - 2].HereBody = nil) and (PendingCount < MaximumPendingHereDocuments) then
    begin
      Pending[PendingCount] := Tokens.Count - 2;
      Inc(PendingCount);
    end;
  end;
  { A here-document without its body: more input is needed. }
  if (Result = LexComplete) and (PendingCount > 0) then
    Result := LexIncomplete;
  AddOperator(Tokens, TokenEnd, Position, Position);
end;

procedure FreeTokens(var Tokens: TTokenList);
var
  Index: Integer;
begin
  Index := 0;
  while Index < Tokens.Count do
  begin
    FreeMemory(Tokens.Items[Index].Text);
    FreeMemory(Tokens.Items[Index].HereBody);
    Inc(Index);
  end;
  FreeMemory(Tokens.Items);
  Tokens.Items := nil;
  Tokens.Count := 0;
  Tokens.Capacity := 0;
end;

end.
