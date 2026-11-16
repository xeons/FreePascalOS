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
  parser can keep the source text of function definitions. Input ends
  at its first NUL.
}
unit Shell.Lexer;

{$mode objfpc}
{$H+}

interface

type
  TTokenKind = (TokenWord, TokenNewline, TokenSemicolon, TokenDoubleSemicolon, TokenAmpersand,
    TokenPipe, TokenAndIf, TokenOrIf, TokenLeftParenthesis, TokenRightParenthesis, TokenRedirect,
    TokenEnd);

  TRedirectKind = (RedirectInput, RedirectOutput, RedirectAppend, RedirectDuplicate,
    RedirectHereDocument);

  TToken = record
    Kind: TTokenKind;
    Text: string;             { TokenWord: raw text }
    RedirectKind: TRedirectKind;
    RedirectHandle: Integer;  { the handle being redirected }
    { RedirectHereDocument: the body once it has been read, and whether
      the delimiter was quoted (no expansion). }
    HereBody: string;
    HasHereBody: Boolean;
    HereIsQuoted: Boolean;
    StripTabs: Boolean;
    { Where the token is in the input: its first character (1-based) and
      the position just after it. }
    StartPosition: Integer;
    EndPosition: Integer;
  end;

  TTokenArray = array of TToken;

  TLexResult = (LexComplete, LexIncomplete);

  TLexer = class
  private
    FText: string;
    FPosition: Integer;
    FTokens: TTokenArray;
    FCount: Integer;
    { Here-document redirections still waiting for their bodies. }
    FPendingHereDocuments: array of Integer;
    function Peek(Offset: Integer = 0): Char;
    procedure AddToken(const Token: TToken);
    procedure AddOperator(Kind: TTokenKind; Start, Finish: Integer);
    procedure AddRedirect(Kind: TRedirectKind; Handle, Start, Finish: Integer);
    function SkipQuoted: Boolean;
    function SkipCommandSubstitution: Boolean;
    function ReadWord(out Word: string): Boolean;
    procedure ReadRedirect(Handle, Start: Integer);
    procedure ReadOperator;
    function ReadHereDocument(TokenIndex: Integer): Boolean;
    function ReadPendingHereDocuments: Boolean;
    procedure NotePendingHereDocument;
  public
    constructor Create(const Text: string);
    { LexIncomplete means a quote, $( or here-document is still open, so
      more input is needed. The tokens always end with TokenEnd. }
    function Tokenize(out Tokens: TTokenArray): TLexResult;
  end;

{ Tokenizes Text with a TLexer. }
function Tokenize(const Text: string; out Tokens: TTokenArray): TLexResult;

{ The delimiter of a here-document with quotes removed. }
function UnquoteDelimiter(const Word: string; out WasQuoted: Boolean): string;

implementation

uses
  Sys.Text,
  Shell.Text;

function IsOperatorStart(Character: Char): Boolean;
begin
  Result := Character in [#10, ';', '&', '|', '(', ')', '<', '>'];
end;

function IsBlank(Character: Char): Boolean;
begin
  Result := (Character = ' ') or (Character = #9) or (Character = #13);
end;

function AllDigits(const Word: string): Boolean;
var
  Index: Integer;
begin
  Result := Word <> '';
  for Index := 1 to Length(Word) do
    if not IsDigit(Word[Index]) then
      Exit(False);
end;

function UnquoteDelimiter(const Word: string; out WasQuoted: Boolean): string;
var
  Index: Integer;
begin
  WasQuoted := False;
  Result := '';
  Index := 1;
  while Index <= Length(Word) do
  begin
    case Word[Index] of
      '''', '"':
        WasQuoted := True;
      '\':
        begin
          WasQuoted := True;
          if Index < Length(Word) then
          begin
            Inc(Index);
            Result := Result + Word[Index];
          end;
        end;
    else
      Result := Result + Word[Index];
    end;
    Inc(Index);
  end;
end;

function Tokenize(const Text: string; out Tokens: TTokenArray): TLexResult;
var
  Lexer: TLexer;
begin
  Lexer := TLexer.Create(Text);
  try
    Result := Lexer.Tokenize(Tokens);
  finally
    Lexer.Free;
  end;
end;

{ --- TLexer ----------------------------------------------------------- }

constructor TLexer.Create(const Text: string);
begin
  inherited Create;
  FText := TextBeforeNull(Text);
end;

function TLexer.Peek(Offset: Integer): Char;
begin
  Result := CharAt(FText, FPosition + Offset);
end;

procedure TLexer.AddToken(const Token: TToken);
begin
  if FCount = Length(FTokens) then
    SetLength(FTokens, FCount * 2 + 32);
  FTokens[FCount] := Token;
  Inc(FCount);
end;

procedure TLexer.AddOperator(Kind: TTokenKind; Start, Finish: Integer);
var
  Token: TToken;
begin
  Token := Default(TToken);
  Token.Kind := Kind;
  Token.StartPosition := Start;
  Token.EndPosition := Finish;
  AddToken(Token);
end;

procedure TLexer.AddRedirect(Kind: TRedirectKind; Handle, Start, Finish: Integer);
var
  Token: TToken;
begin
  Token := Default(TToken);
  Token.Kind := TokenRedirect;
  Token.RedirectKind := Kind;
  Token.RedirectHandle := Handle;
  Token.StartPosition := Start;
  Token.EndPosition := Finish;
  AddToken(Token);
end;

{ Skips the quoted text starting at the opening quote. Returns False if
  it is not closed. }
function TLexer.SkipQuoted: Boolean;
var
  Quote: Char;
begin
  Quote := Peek;
  Inc(FPosition);
  while Peek <> Quote do
  begin
    if Peek = #0 then
      Exit(False);
    if (Quote = '"') and (Peek = '\') and (Peek(1) <> #0) then
      Inc(FPosition, 2)
    else if (Quote = '"') and (Peek = '$') and (Peek(1) = '(') then
    begin
      if not SkipCommandSubstitution then
        Exit(False);
    end
    else
      Inc(FPosition);
  end;
  Inc(FPosition);
  Result := True;
end;

{ Skips a $( ... ) starting at its '$'. Returns False if it is not
  closed; otherwise the position ends just after the closing
  parenthesis. }
function TLexer.SkipCommandSubstitution: Boolean;
var
  Depth: Integer;
begin
  Inc(FPosition, 2);
  Depth := 1;
  while Depth > 0 do
  begin
    case Peek of
      #0: Exit(False);
      '''', '"':
        begin
          if not SkipQuoted then
            Exit(False);
          Continue;
        end;
      '\':
        if Peek(1) <> #0 then
          Inc(FPosition);
      '(': Inc(Depth);
      ')': Dec(Depth);
    end;
    Inc(FPosition);
  end;
  Result := True;
end;

{ Reads a word; returns False if a quote is open. }
function TLexer.ReadWord(out Word: string): Boolean;
var
  Start: Integer;
begin
  Word := '';
  Start := FPosition;
  while (Peek <> #0) and not IsBlank(Peek) and not IsOperatorStart(Peek) do
  begin
    case Peek of
      '''', '"':
        if not SkipQuoted then
          Exit(False);
      '\':
        begin
          if Peek(1) = #0 then
            Exit(False);
          Inc(FPosition, 2);
        end;
      '$':
        if Peek(1) = '(' then
        begin
          if not SkipCommandSubstitution then
            Exit(False);
        end
        else
          Inc(FPosition);
    else
      Inc(FPosition);
    end;
  end;
  Word := Copy(FText, Start, FPosition - Start);
  Result := True;
end;

{ Reads a redirection operator; Handle is the number written before it,
  or -1. }
procedure TLexer.ReadRedirect(Handle, Start: Integer);
begin
  if Peek = '<' then
  begin
    if Handle < 0 then
      Handle := 0;
    Inc(FPosition);
    if Peek = '<' then
    begin
      Inc(FPosition);
      AddRedirect(RedirectHereDocument, Handle, Start, FPosition);
      if Peek = '-' then
      begin
        Inc(FPosition);
        FTokens[FCount - 1].StripTabs := True;
        FTokens[FCount - 1].EndPosition := FPosition;
      end;
    end
    else if Peek = '&' then
    begin
      Inc(FPosition);
      AddRedirect(RedirectDuplicate, Handle, Start, FPosition);
    end
    else
      AddRedirect(RedirectInput, Handle, Start, FPosition);
    Exit;
  end;

  if Handle < 0 then
    Handle := 1;
  Inc(FPosition);
  if Peek = '>' then
  begin
    Inc(FPosition);
    AddRedirect(RedirectAppend, Handle, Start, FPosition);
  end
  else if Peek = '&' then
  begin
    Inc(FPosition);
    AddRedirect(RedirectDuplicate, Handle, Start, FPosition);
  end
  else
    AddRedirect(RedirectOutput, Handle, Start, FPosition);
end;

{ One of ; ;; & && | || ( ) at the current position. }
procedure TLexer.ReadOperator;
var
  Start: Integer;
  Doubled: Boolean;
begin
  Start := FPosition;
  Doubled := (Peek in [';', '&', '|']) and (Peek(1) = Peek);
  case Peek of
    ';':
      if Doubled then
        AddOperator(TokenDoubleSemicolon, Start, Start + 2)
      else
        AddOperator(TokenSemicolon, Start, Start + 1);
    '&':
      if Doubled then
        AddOperator(TokenAndIf, Start, Start + 2)
      else
        AddOperator(TokenAmpersand, Start, Start + 1);
    '|':
      if Doubled then
        AddOperator(TokenOrIf, Start, Start + 2)
      else
        AddOperator(TokenPipe, Start, Start + 1);
    '(':
      AddOperator(TokenLeftParenthesis, Start, Start + 1);
    ')':
      AddOperator(TokenRightParenthesis, Start, Start + 1);
  end;
  if Doubled then
    Inc(FPosition, 2)
  else
    Inc(FPosition);
end;

{ Collects the body of the here-document of token TokenIndex, starting
  at the current position (the start of the line after the command).
  Returns False if the input ends before the delimiter line. }
function TLexer.ReadHereDocument(TokenIndex: Integer): Boolean;
var
  Delimiter: string;
  Body: string;
  LineEnd: Integer;
  ContentStart: Integer;
  Content: string;
begin
  { The delimiter word follows the redirection token. }
  if (TokenIndex + 1 >= FCount) or (FTokens[TokenIndex + 1].Kind <> TokenWord) then
    Exit(True); { the parser reports the missing word }
  Delimiter := UnquoteDelimiter(FTokens[TokenIndex + 1].Text, FTokens[TokenIndex].HereIsQuoted);
  Body := '';
  while True do
  begin
    if Peek = #0 then
      Exit(False);
    LineEnd := FPosition;
    while not (CharAt(FText, LineEnd) in [#10, #0]) do
      Inc(LineEnd);
    ContentStart := FPosition;
    if FTokens[TokenIndex].StripTabs then
      while (ContentStart < LineEnd) and (FText[ContentStart] = #9) do
        Inc(ContentStart);
    Content := Copy(FText, ContentStart, LineEnd - ContentStart);
    { A line end that is the last thing in the input still counts: the
      delimiter line needs one, or the end of the text. }
    if Content = Delimiter then
    begin
      FPosition := LineEnd;
      if Peek = #10 then
        Inc(FPosition);
      Break;
    end;
    if CharAt(FText, LineEnd) = #0 then
      Exit(False);
    Body := Body + Content + #10;
    FPosition := LineEnd + 1;
  end;
  FTokens[TokenIndex].HereBody := Body;
  FTokens[TokenIndex].HasHereBody := True;
  Result := True;
end;

{ Here-document bodies start on the line after their redirection. }
function TLexer.ReadPendingHereDocuments: Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(FPendingHereDocuments) do
    if not ReadHereDocument(FPendingHereDocuments[Index]) then
      Exit(False);
  FPendingHereDocuments := nil;
  Result := True;
end;

{ A here-document redirection waits for its body at the next line end
  (it applies once its delimiter word has been read). }
procedure TLexer.NotePendingHereDocument;
var
  Count: Integer;
begin
  if (FCount >= 2) and (FTokens[FCount - 1].Kind = TokenWord) and
     (FTokens[FCount - 2].Kind = TokenRedirect) and
     (FTokens[FCount - 2].RedirectKind = RedirectHereDocument) and
     not FTokens[FCount - 2].HasHereBody then
  begin
    Count := Length(FPendingHereDocuments);
    SetLength(FPendingHereDocuments, Count + 1);
    FPendingHereDocuments[Count] := FCount - 2;
  end;
end;

function TLexer.Tokenize(out Tokens: TTokenArray): TLexResult;
var
  Start: Integer;
  Word: string;
  Token: TToken;
  Handle: Int64;
begin
  FTokens := nil;
  FCount := 0;
  FPendingHereDocuments := nil;
  FPosition := 1;
  Result := LexComplete;

  while Peek <> #0 do
  begin
    if IsBlank(Peek) then
    begin
      Inc(FPosition);
      Continue;
    end;
    if (Peek = '\') and (Peek(1) = #10) then
    begin
      { A line continuation. }
      Inc(FPosition, 2);
      Continue;
    end;
    if Peek = '#' then
    begin
      while (Peek <> #0) and (Peek <> #10) do
        Inc(FPosition);
      Continue;
    end;

    Start := FPosition;
    case Peek of
      #10:
        begin
          AddOperator(TokenNewline, Start, Start + 1);
          Inc(FPosition);
          if not ReadPendingHereDocuments then
          begin
            Result := LexIncomplete;
            Break;
          end;
        end;
      ';', '&', '|', '(', ')':
        ReadOperator;
      '<', '>':
        ReadRedirect(-1, Start);
    else
      begin
        if not ReadWord(Word) then
        begin
          Result := LexIncomplete;
          Break;
        end;
        { "2>" is a redirection of handle 2, not the word "2". }
        if AllDigits(Word) and (Peek in ['<', '>']) and TryParseInteger(Word, Handle) then
          ReadRedirect(Integer(Handle), Start)
        else
        begin
          Token := Default(TToken);
          Token.Kind := TokenWord;
          Token.Text := Word;
          Token.StartPosition := Start;
          Token.EndPosition := FPosition;
          AddToken(Token);
        end;
      end;
    end;

    NotePendingHereDocument;
  end;
  { A here-document without its body: more input is needed. }
  if (Result = LexComplete) and (Length(FPendingHereDocuments) > 0) then
    Result := LexIncomplete;
  AddOperator(TokenEnd, FPosition, FPosition);
  SetLength(FTokens, FCount);
  Tokens := FTokens;
  FTokens := nil;
end;

end.
