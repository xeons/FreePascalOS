(*
  The shell's syntax tree and the parser that builds it.

  Grammar (a subset of the POSIX shell grammar):

    list       := and_or { (';' | '&' | newline) and_or }
    and_or     := pipeline { ('&&' | '||') pipeline }
    pipeline   := ['!'] command { '|' command }
    command    := simple | if | while | until | for | '{' list '}' | '(' list ')'
    simple     := { NAME=value } { word | redirection }
    if         := 'if' list 'then' list { 'elif' list 'then' list } ['else' list] 'fi'
    while      := 'while' list 'do' list 'done'      (until likewise)
    for        := 'for' NAME ['in' word...] (';' | newline) 'do' list 'done'

  Newlines are allowed after '|', '&&', '||' and inside compound
  commands. "( list )" runs in the same shell, like "{ list }".
*)
unit Shell.Syntax;

{$mode objfpc}
{$pointermath on}

interface

uses
  Shell.Lexer;

type
  TNodeKind = (NodeSimple, NodePipeline, NodeAndOr, NodeSequence, NodeIf, NodeLoop, NodeFor);
  TAndOrOperator = (OperatorAnd, OperatorOr);

  PRedirection = ^TRedirection;
  TRedirection = record
    Kind: TRedirectKind;
    Handle: Integer;
    Target: PChar;      { raw word }
  end;

  PNode = ^TNode;
  PPNode = ^PNode;
  TNode = record
    Kind: TNodeKind;

    { NodeSimple: words and NAME=value assignments are raw text.
      NodeFor: Words is the list after "in" (nil = "$@"). }
    Words: PPChar;
    WordCount: Integer;
    Assignments: PPChar;
    AssignmentCount: Integer;
    Redirections: PRedirection;
    RedirectionCount: Integer;

    { NodePipeline: the commands; NodeSequence: the items. }
    Children: PPNode;
    ChildCount: Integer;
    { NodeSequence: which items end with '&'. }
    RunInBackground: PBoolean;
    { NodePipeline: '!' inverts the status. }
    Negate: Boolean;

    { NodeAndOr }
    Left: PNode;
    Right: PNode;
    AndOrOperator: TAndOrOperator;

    { NodeIf: Condition/Body/ElseBody (elif nests in ElseBody).
      NodeLoop: Condition/Body, IsUntil. NodeFor: VariableName/Body. }
    Condition: PNode;
    Body: PNode;
    ElseBody: PNode;
    IsUntil: Boolean;
    VariableName: PChar;
  end;

  TParseResult = (ParseSuccess, ParseIncomplete, ParseError);

{ Parses a whole input. Tree is nil for empty input. On ParseError,
  ErrorMessage describes the problem. }
function ParseInput(Text: PChar; out Tree: PNode; out ErrorMessage: PChar): TParseResult;
procedure FreeNode(Node: PNode);

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Memory,
  Sys.Text;

type
  TParser = record
    Tokens: TTokenList;
    Position: Integer;
    Incomplete: Boolean;
    Failed: Boolean;
    ErrorMessage: PChar;
  end;

function NewNode(Kind: TNodeKind): PNode;
begin
  Result := PNode(AllocateZeroedMemory(SizeOf(TNode)));
  Result^.Kind := Kind;
end;

procedure AppendText(var Items: PPChar; var Count: Integer; Text: PChar);
begin
  Items := PPChar(ReallocateMemory(Items, QWord(Count + 2) * SizeOf(PChar)));
  Items[Count] := Text;
  Inc(Count);
  Items[Count] := nil;
end;

procedure AppendChild(Node: PNode; Child: PNode; Background: Boolean);
begin
  Node^.Children := PPNode(ReallocateMemory(Node^.Children, QWord(Node^.ChildCount + 1) * SizeOf(PNode)));
  Node^.RunInBackground := PBoolean(ReallocateMemory(Node^.RunInBackground, QWord(Node^.ChildCount + 1) * SizeOf(Boolean)));
  Node^.Children[Node^.ChildCount] := Child;
  Node^.RunInBackground[Node^.ChildCount] := Background;
  Inc(Node^.ChildCount);
end;

{ --- Token access ---------------------------------------------------- }

function Current(var Parser: TParser): PToken;
begin
  Result := @Parser.Tokens.Items[Parser.Position];
end;

procedure Advance(var Parser: TParser);
begin
  if Current(Parser)^.Kind <> TokenEnd then
    Inc(Parser.Position);
end;

function IsReservedWord(var Parser: TParser; Word: PChar): Boolean;
var
  Token: PToken;
begin
  Token := Current(Parser);
  Result := (Token^.Kind = TokenWord) and TextIsEqual(Token^.Text, Word);
end;

{ Words that end a list inside a compound command. }
function AtListTerminator(var Parser: TParser): Boolean;
var
  Token: PToken;
begin
  Token := Current(Parser);
  case Token^.Kind of
    TokenEnd, TokenRightParenthesis: Result := True;
    TokenWord:
      Result := TextIsEqual(Token^.Text, 'then') or TextIsEqual(Token^.Text, 'else') or
        TextIsEqual(Token^.Text, 'elif') or TextIsEqual(Token^.Text, 'fi') or
        TextIsEqual(Token^.Text, 'do') or TextIsEqual(Token^.Text, 'done') or
        TextIsEqual(Token^.Text, '}');
  else
    Result := False;
  end;
end;

procedure SkipNewlines(var Parser: TParser);
begin
  while Current(Parser)^.Kind = TokenNewline do
    Advance(Parser);
end;

procedure SetError(var Parser: TParser; Message: PChar);
begin
  if Parser.Failed or Parser.Incomplete then
    Exit;
  { Running out of tokens means the user is still typing. }
  if Current(Parser)^.Kind = TokenEnd then
  begin
    Parser.Incomplete := True;
    Exit;
  end;
  Parser.Failed := True;
  Parser.ErrorMessage := Message;
end;

function Expect(var Parser: TParser; Word: PChar; Message: PChar): Boolean;
begin
  SkipNewlines(Parser);
  Result := IsReservedWord(Parser, Word);
  if Result then
    Advance(Parser)
  else
    SetError(Parser, Message);
end;

{ --- Grammar --------------------------------------------------------- }

function ParseList(var Parser: TParser): PNode; forward;

function IsAssignment(Word: PChar): Boolean;
var
  Index: Integer;
begin
  Result := False;
  if not (IsLetter(Word[0]) or (Word[0] = '_')) then
    Exit;
  Index := 1;
  while IsAlphanumeric(Word[Index]) or (Word[Index] = '_') do
    Inc(Index);
  Result := Word[Index] = '=';
end;

function ParseSimpleCommand(var Parser: TParser): PNode;
var
  Token: PToken;
  Redirection: TRedirection;
  Node: PNode;
begin
  Node := NewNode(NodeSimple);
  while True do
  begin
    Token := Current(Parser);
    if Token^.Kind = TokenWord then
    begin
      if (Node^.WordCount = 0) and IsAssignment(Token^.Text) then
        AppendText(Node^.Assignments, Node^.AssignmentCount, DuplicateText(Token^.Text))
      else
        AppendText(Node^.Words, Node^.WordCount, DuplicateText(Token^.Text));
      Advance(Parser);
    end
    else if Token^.Kind = TokenRedirect then
    begin
      Redirection.Kind := Token^.RedirectKind;
      Redirection.Handle := Token^.RedirectHandle;
      Advance(Parser);
      if Current(Parser)^.Kind <> TokenWord then
      begin
        SetError(Parser, 'syntax error: missing file name after redirection');
        FreeNode(Node);
        Exit(nil);
      end;
      Redirection.Target := DuplicateText(Current(Parser)^.Text);
      Advance(Parser);
      Node^.Redirections := PRedirection(ReallocateMemory(Node^.Redirections,
        QWord(Node^.RedirectionCount + 1) * SizeOf(TRedirection)));
      Node^.Redirections[Node^.RedirectionCount] := Redirection;
      Inc(Node^.RedirectionCount);
    end
    else
      Break;
  end;

  if (Node^.WordCount = 0) and (Node^.AssignmentCount = 0) and (Node^.RedirectionCount = 0) then
  begin
    SetError(Parser, 'syntax error: command expected');
    FreeNode(Node);
    Exit(nil);
  end;
  Result := Node;
end;

function ParseIf(var Parser: TParser): PNode;
var
  Node: PNode;
begin
  Advance(Parser); { 'if' or 'elif' }
  Node := NewNode(NodeIf);
  Node^.Condition := ParseList(Parser);
  if Expect(Parser, 'then', 'syntax error: "then" expected') then
    Node^.Body := ParseList(Parser);
  SkipNewlines(Parser);
  if IsReservedWord(Parser, 'elif') then
    { The rest of the chain, including its "fi", parses as a nested if. }
    Node^.ElseBody := ParseIf(Parser)
  else
  begin
    if IsReservedWord(Parser, 'else') then
    begin
      Advance(Parser);
      Node^.ElseBody := ParseList(Parser);
    end;
    Expect(Parser, 'fi', 'syntax error: "fi" expected');
  end;
  Result := Node;
end;

function ParseLoop(var Parser: TParser): PNode;
var
  Node: PNode;
begin
  Node := NewNode(NodeLoop);
  Node^.IsUntil := IsReservedWord(Parser, 'until');
  Advance(Parser);
  Node^.Condition := ParseList(Parser);
  if Expect(Parser, 'do', 'syntax error: "do" expected') then
    Node^.Body := ParseList(Parser);
  Expect(Parser, 'done', 'syntax error: "done" expected');
  Result := Node;
end;

function ParseFor(var Parser: TParser): PNode;
var
  Node: PNode;
begin
  Advance(Parser); { 'for' }
  Node := NewNode(NodeFor);
  if Current(Parser)^.Kind <> TokenWord then
  begin
    SetError(Parser, 'syntax error: variable name expected after "for"');
    Exit(Node);
  end;
  Node^.VariableName := DuplicateText(Current(Parser)^.Text);
  Advance(Parser);
  SkipNewlines(Parser);
  if IsReservedWord(Parser, 'in') then
  begin
    Advance(Parser);
    { An empty list after "in" means no iterations, not "$@". }
    AppendText(Node^.Words, Node^.WordCount, nil);
    Node^.WordCount := 0;
    while Current(Parser)^.Kind = TokenWord do
    begin
      AppendText(Node^.Words, Node^.WordCount, DuplicateText(Current(Parser)^.Text));
      Advance(Parser);
    end;
  end;
  if Current(Parser)^.Kind = TokenSemicolon then
    Advance(Parser);
  if Expect(Parser, 'do', 'syntax error: "do" expected') then
    Node^.Body := ParseList(Parser);
  Expect(Parser, 'done', 'syntax error: "done" expected');
  Result := Node;
end;

function ParseCommand(var Parser: TParser): PNode;
begin
  if IsReservedWord(Parser, 'if') then
    Exit(ParseIf(Parser));
  if IsReservedWord(Parser, 'while') or IsReservedWord(Parser, 'until') then
    Exit(ParseLoop(Parser));
  if IsReservedWord(Parser, 'for') then
    Exit(ParseFor(Parser));
  if IsReservedWord(Parser, '{') then
  begin
    Advance(Parser);
    Result := ParseList(Parser);
    Expect(Parser, '}', 'syntax error: "}" expected');
    Exit;
  end;
  if Current(Parser)^.Kind = TokenLeftParenthesis then
  begin
    Advance(Parser);
    Result := ParseList(Parser);
    SkipNewlines(Parser);
    if Current(Parser)^.Kind = TokenRightParenthesis then
      Advance(Parser)
    else
      SetError(Parser, 'syntax error: ")" expected');
    Exit;
  end;
  Result := ParseSimpleCommand(Parser);
end;

function ParsePipeline(var Parser: TParser): PNode;
var
  Node: PNode;
  Command: PNode;
begin
  Node := NewNode(NodePipeline);
  if IsReservedWord(Parser, '!') then
  begin
    Node^.Negate := True;
    Advance(Parser);
  end;
  repeat
    Command := ParseCommand(Parser);
    if Command = nil then
    begin
      FreeNode(Node);
      Exit(nil);
    end;
    AppendChild(Node, Command, False);
    if Current(Parser)^.Kind <> TokenPipe then
      Break;
    Advance(Parser);
    SkipNewlines(Parser);
  until Parser.Failed or Parser.Incomplete;

  { A single command without '!' needs no pipeline node. }
  if (Node^.ChildCount = 1) and not Node^.Negate then
  begin
    Result := Node^.Children[0];
    Node^.ChildCount := 0;
    FreeNode(Node);
  end
  else
    Result := Node;
end;

function ParseAndOr(var Parser: TParser): PNode;
var
  Left: PNode;
  Right: PNode;
  Node: PNode;
  Combination: TAndOrOperator;
begin
  Left := ParsePipeline(Parser);
  while (Left <> nil) and (Current(Parser)^.Kind in [TokenAndIf, TokenOrIf]) do
  begin
    if Current(Parser)^.Kind = TokenAndIf then
      Combination := OperatorAnd
    else
      Combination := OperatorOr;
    Advance(Parser);
    SkipNewlines(Parser);
    Right := ParsePipeline(Parser);
    if Right = nil then
    begin
      FreeNode(Left);
      Exit(nil);
    end;
    Node := NewNode(NodeAndOr);
    Node^.Left := Left;
    Node^.Right := Right;
    Node^.AndOrOperator := Combination;
    Left := Node;
  end;
  Result := Left;
end;

function ParseList(var Parser: TParser): PNode;
var
  Node: PNode;
  Item: PNode;
  Background: Boolean;
begin
  Node := NewNode(NodeSequence);
  SkipNewlines(Parser);
  while not AtListTerminator(Parser) do
  begin
    Item := ParseAndOr(Parser);
    if Item = nil then
      Break;
    Background := Current(Parser)^.Kind = TokenAmpersand;
    AppendChild(Node, Item, Background);
    if Current(Parser)^.Kind in [TokenSemicolon, TokenAmpersand, TokenNewline] then
      Advance(Parser)
    else if not AtListTerminator(Parser) then
    begin
      SetError(Parser, 'syntax error: unexpected token');
      Break;
    end;
    SkipNewlines(Parser);
    if Parser.Failed or Parser.Incomplete then
      Break;
  end;
  Result := Node;
end;

function ParseInput(Text: PChar; out Tree: PNode; out ErrorMessage: PChar): TParseResult;
var
  Parser: TParser;
begin
  Tree := nil;
  ErrorMessage := nil;
  FillMemory(@Parser, SizeOf(Parser), 0);
  if Tokenize(Text, Parser.Tokens) = LexIncomplete then
  begin
    FreeTokens(Parser.Tokens);
    Exit(ParseIncomplete);
  end;

  Tree := ParseList(Parser);
  if not Parser.Failed and not Parser.Incomplete and (Current(Parser)^.Kind <> TokenEnd) then
  begin
    Parser.Failed := True;
    if Current(Parser)^.Kind = TokenWord then
      Parser.ErrorMessage := 'syntax error: unexpected word'
    else
      Parser.ErrorMessage := 'syntax error: unexpected token';
  end;
  FreeTokens(Parser.Tokens);

  if Parser.Failed or Parser.Incomplete then
  begin
    FreeNode(Tree);
    Tree := nil;
    if Parser.Incomplete then
      Exit(ParseIncomplete);
    ErrorMessage := Parser.ErrorMessage;
    Exit(ParseError);
  end;
  Result := ParseSuccess;
end;

procedure FreeTextList(Items: PPChar; Count: Integer);
var
  Index: Integer;
begin
  Index := 0;
  while Index < Count do
  begin
    FreeMemory(Items[Index]);
    Inc(Index);
  end;
  FreeMemory(Items);
end;

procedure FreeNode(Node: PNode);
var
  Index: Integer;
begin
  if Node = nil then
    Exit;
  FreeTextList(Node^.Words, Node^.WordCount);
  FreeTextList(Node^.Assignments, Node^.AssignmentCount);
  Index := 0;
  while Index < Node^.RedirectionCount do
  begin
    FreeMemory(Node^.Redirections[Index].Target);
    Inc(Index);
  end;
  FreeMemory(Node^.Redirections);
  Index := 0;
  while Index < Node^.ChildCount do
  begin
    FreeNode(Node^.Children[Index]);
    Inc(Index);
  end;
  FreeMemory(Node^.Children);
  FreeMemory(Node^.RunInBackground);
  FreeNode(Node^.Left);
  FreeNode(Node^.Right);
  FreeNode(Node^.Condition);
  FreeNode(Node^.Body);
  FreeNode(Node^.ElseBody);
  FreeMemory(Node^.VariableName);
  FreeMemory(Node);
end;

end.
