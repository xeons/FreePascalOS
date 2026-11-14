{
  Splitting shell input into tokens.

  A word token keeps its raw text, quotes and backslashes included;
  expansion (Shell.Expansion) interprets them later, when the command
  runs, because variables can change between parsing and running.

  Operators: newline ; & | && || ( ) and the redirections
    < > >> <& >&    each optionally preceded by a handle number (2>file)

  "#" at the start of a word begins a comment that runs to the line end.
}
unit Shell.Lexer;

{$mode objfpc}
{$pointermath on}

interface

type
  TTokenKind = (TokenWord, TokenNewline, TokenSemicolon, TokenAmpersand, TokenPipe,
    TokenAndIf, TokenOrIf, TokenLeftParenthesis, TokenRightParenthesis, TokenRedirect,
    TokenEnd);

  TRedirectKind = (RedirectInput, RedirectOutput, RedirectAppend, RedirectDuplicate);

  PToken = ^TToken;
  TToken = record
    Kind: TTokenKind;
    Text: PChar;              { TokenWord: raw text (heap) }
    RedirectKind: TRedirectKind;
    RedirectHandle: Integer;  { the handle being redirected }
  end;

  TTokenList = record
    Items: PToken;
    Count: Integer;
    Capacity: Integer;
  end;

  TLexResult = (LexComplete, LexIncomplete);

{ Tokenizes Text. LexIncomplete means a quote or $( is still open, so
  more input is needed. The list always ends with TokenEnd. }
function Tokenize(Text: PChar; out Tokens: TTokenList): TLexResult;
procedure FreeTokens(var Tokens: TTokenList);

implementation

uses
  Runtime.Memory,
  Sys.Memory,
  Sys.Text;

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

procedure AddOperator(var Tokens: TTokenList; Kind: TTokenKind);
var
  Token: TToken;
begin
  FillMemory(@Token, SizeOf(Token), 0);
  Token.Kind := Kind;
  AddToken(Tokens, Token);
end;

procedure AddRedirect(var Tokens: TTokenList; Kind: TRedirectKind; Handle: Integer);
var
  Token: TToken;
begin
  FillMemory(@Token, SizeOf(Token), 0);
  Token.Kind := TokenRedirect;
  Token.RedirectKind := Kind;
  Token.RedirectHandle := Handle;
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

procedure ReadRedirect(Text: PChar; var Position: PtrUInt; var Tokens: TTokenList; Handle: Integer);
begin
  if Text[Position] = '<' then
  begin
    if Handle < 0 then
      Handle := 0;
    Inc(Position);
    if Text[Position] = '&' then
    begin
      Inc(Position);
      AddRedirect(Tokens, RedirectDuplicate, Handle);
    end
    else
      AddRedirect(Tokens, RedirectInput, Handle);
    Exit;
  end;

  if Handle < 0 then
    Handle := 1;
  Inc(Position);
  if Text[Position] = '>' then
  begin
    Inc(Position);
    AddRedirect(Tokens, RedirectAppend, Handle);
  end
  else if Text[Position] = '&' then
  begin
    Inc(Position);
    AddRedirect(Tokens, RedirectDuplicate, Handle);
  end
  else
    AddRedirect(Tokens, RedirectOutput, Handle);
end;

function Tokenize(Text: PChar; out Tokens: TTokenList): TLexResult;
var
  Position: PtrUInt;
  Word: PChar;
  Token: TToken;
  Handle: Int64;
begin
  Tokens.Items := nil;
  Tokens.Count := 0;
  Tokens.Capacity := 0;
  Result := LexComplete;
  Position := 0;

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

    case Text[Position] of
      #10:
        begin
          AddOperator(Tokens, TokenNewline);
          Inc(Position);
        end;
      ';':
        begin
          AddOperator(Tokens, TokenSemicolon);
          Inc(Position);
        end;
      '&':
        if Text[Position + 1] = '&' then
        begin
          AddOperator(Tokens, TokenAndIf);
          Inc(Position, 2);
        end
        else
        begin
          AddOperator(Tokens, TokenAmpersand);
          Inc(Position);
        end;
      '|':
        if Text[Position + 1] = '|' then
        begin
          AddOperator(Tokens, TokenOrIf);
          Inc(Position, 2);
        end
        else
        begin
          AddOperator(Tokens, TokenPipe);
          Inc(Position);
        end;
      '(':
        begin
          AddOperator(Tokens, TokenLeftParenthesis);
          Inc(Position);
        end;
      ')':
        begin
          AddOperator(Tokens, TokenRightParenthesis);
          Inc(Position);
        end;
      '<', '>':
        ReadRedirect(Text, Position, Tokens, -1);
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
          ReadRedirect(Text, Position, Tokens, Integer(Handle));
        end
        else
        begin
          FillMemory(@Token, SizeOf(Token), 0);
          Token.Kind := TokenWord;
          Token.Text := Word;
          AddToken(Tokens, Token);
        end;
      end;
    end;
  end;
  AddOperator(Tokens, TokenEnd);
end;

procedure FreeTokens(var Tokens: TTokenList);
var
  Index: Integer;
begin
  Index := 0;
  while Index < Tokens.Count do
  begin
    FreeMemory(Tokens.Items[Index].Text);
    Inc(Index);
  end;
  FreeMemory(Tokens.Items);
  Tokens.Items := nil;
  Tokens.Count := 0;
  Tokens.Capacity := 0;
end;

end.
