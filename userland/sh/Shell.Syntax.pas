(*
  The shell's syntax tree and the parser that builds it.

  Grammar (a subset of the POSIX shell grammar):

    list       := and_or { (';' | '&' | newline) and_or }
    and_or     := pipeline { ('&&' | '||') pipeline }
    pipeline   := ['!'] command { '|' command }
    command    := simple | compound [redirection...] | function
    compound   := if | while | until | for | case | '{' list '}' | '(' list ')'
    simple     := { NAME=value } { word | redirection }
    if         := 'if' list 'then' list { 'elif' list 'then' list } ['else' list] 'fi'
    while      := 'while' list 'do' list 'done'      (until likewise)
    for        := 'for' NAME ['in' word...] (';' | newline) 'do' list 'done'
    case       := 'case' word 'in' { ['('] pattern {'|' pattern} ')' list [';;'] } 'esac'
    function   := NAME '(' ')' command  |  'function' NAME ['(' ')'] command

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
  TNodeKind = (NodeSimple, NodePipeline, NodeAndOr, NodeSequence, NodeIf, NodeLoop, NodeFor,
    NodeCase, NodeCaseItem, NodeFunction, NodeRedirected);
  TAndOrOperator = (OperatorAnd, OperatorOr);

  PRedirection = ^TRedirection;
  TRedirection = record
    Kind: TRedirectKind;
    Handle: Integer;
    Target: PChar;      { raw word }
    { Here-documents: the body, and whether it is taken literally. }
    HereBody: PChar;
    HereIsQuoted: Boolean;
  end;

  PNode = ^TNode;
  PPNode = ^PNode;
  TNode = record
    Kind: TNodeKind;

    { NodeSimple: words and NAME=value assignments are raw text.
      NodeFor: Words is the list after "in" (nil = "$@").
      NodeCase: Words[0] is the subject; Children are NodeCaseItems,
      whose Words are the patterns and Body the commands. }
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
      NodeLoop: Condition/Body, IsUntil. NodeFor: VariableName/Body.
      NodeFunction: VariableName is the function's name, Body its body
      and SourceText the definition as written.
      NodeRedirected: a compound command (Body) with Redirections. }
    Condition: PNode;
    Body: PNode;
    ElseBody: PNode;
    IsUntil: Boolean;
    VariableName: PChar;
    SourceText: PChar;
  end;

  TParseResult = (ParseSuccess, ParseIncomplete, ParseError);

{ Parses a whole input. Tree is nil for empty input. On ParseError,
  ErrorMessage describes the problem. }
function ParseInput(Text: PChar; out Tree: PNode; out ErrorMessage: PChar): TParseResult;
procedure FreeNode(Node: PNode);
{ A deep copy (function bodies outlive the command line they came in). }
function CopyNode(Node: PNode): PNode;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Memory,
  Sys.Text;

type
  TParser = record
    Source: PChar;
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
        TextIsEqual(Token^.Text, '}') or TextIsEqual(Token^.Text, 'esac');
    TokenDoubleSemicolon: Result := True;
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

{ Parses the redirection at the current token and adds it to Node. }
function ParseRedirection(var Parser: TParser; Node: PNode): Boolean;
var
  Token: PToken;
  Redirection: TRedirection;
begin
  Token := Current(Parser);
  Redirection.Kind := Token^.RedirectKind;
  Redirection.Handle := Token^.RedirectHandle;
  Redirection.HereBody := nil;
  Redirection.HereIsQuoted := Token^.HereIsQuoted;
  Advance(Parser);
  if Current(Parser)^.Kind <> TokenWord then
  begin
    SetError(Parser, 'syntax error: missing file name after redirection');
    Exit(False);
  end;
  if Token^.HereBody <> nil then
    Redirection.HereBody := DuplicateText(Token^.HereBody);
  Redirection.Target := DuplicateText(Current(Parser)^.Text);
  Advance(Parser);
  Node^.Redirections := PRedirection(ReallocateMemory(Node^.Redirections,
    QWord(Node^.RedirectionCount + 1) * SizeOf(TRedirection)));
  Node^.Redirections[Node^.RedirectionCount] := Redirection;
  Inc(Node^.RedirectionCount);
  Result := True;
end;

function ParseSimpleCommand(var Parser: TParser): PNode;
var
  Token: PToken;
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
      if not ParseRedirection(Parser, Node) then
      begin
        FreeNode(Node);
        Exit(nil);
      end;
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

function ParseCase(var Parser: TParser): PNode;
var
  Node: PNode;
  Item: PNode;
begin
  Advance(Parser); { 'case' }
  Node := NewNode(NodeCase);
  Result := Node;
  if Current(Parser)^.Kind <> TokenWord then
  begin
    SetError(Parser, 'syntax error: word expected after "case"');
    Exit;
  end;
  AppendText(Node^.Words, Node^.WordCount, DuplicateText(Current(Parser)^.Text));
  Advance(Parser);
  SkipNewlines(Parser);
  if not IsReservedWord(Parser, 'in') then
  begin
    SetError(Parser, 'syntax error: "in" expected');
    Exit;
  end;
  Advance(Parser);
  SkipNewlines(Parser);
  while not IsReservedWord(Parser, 'esac') do
  begin
    if Parser.Failed or Parser.Incomplete then
      Exit;
    if Current(Parser)^.Kind = TokenEnd then
    begin
      SetError(Parser, 'syntax error: "esac" expected');
      Exit;
    end;
    Item := NewNode(NodeCaseItem);
    AppendChild(Node, Item, False);
    if Current(Parser)^.Kind = TokenLeftParenthesis then
      Advance(Parser);
    repeat
      if Current(Parser)^.Kind <> TokenWord then
      begin
        SetError(Parser, 'syntax error: pattern expected');
        Exit;
      end;
      AppendText(Item^.Words, Item^.WordCount, DuplicateText(Current(Parser)^.Text));
      Advance(Parser);
      if Current(Parser)^.Kind <> TokenPipe then
        Break;
      Advance(Parser);
    until False;
    if Current(Parser)^.Kind <> TokenRightParenthesis then
    begin
      SetError(Parser, 'syntax error: ")" expected after pattern');
      Exit;
    end;
    Advance(Parser);
    Item^.Body := ParseList(Parser);
    SkipNewlines(Parser);
    if Current(Parser)^.Kind = TokenDoubleSemicolon then
    begin
      Advance(Parser);
      SkipNewlines(Parser);
    end
    else if not IsReservedWord(Parser, 'esac') then
    begin
      SetError(Parser, 'syntax error: ";;" or "esac" expected');
      Exit;
    end;
  end;
  Advance(Parser); { 'esac' }
end;

function ParseCommand(var Parser: TParser): PNode; forward;

{ NAME ( ) command, or function NAME [( )] command; StartIndex is the
  first token of the definition, for its source text. }
function ParseFunction(var Parser: TParser; StartIndex: Integer): PNode;
var
  Node: PNode;
  StartOffset: PtrUInt;
  EndOffset: PtrUInt;
  Length: PtrUInt;
begin
  Node := NewNode(NodeFunction);
  Result := Node;
  if IsReservedWord(Parser, 'function') then
    Advance(Parser);
  if Current(Parser)^.Kind <> TokenWord then
  begin
    SetError(Parser, 'syntax error: function name expected');
    Exit;
  end;
  Node^.VariableName := DuplicateText(Current(Parser)^.Text);
  Advance(Parser);
  if Current(Parser)^.Kind = TokenLeftParenthesis then
  begin
    Advance(Parser);
    if Current(Parser)^.Kind <> TokenRightParenthesis then
    begin
      SetError(Parser, 'syntax error: ")" expected');
      Exit;
    end;
    Advance(Parser);
  end;
  SkipNewlines(Parser);
  Node^.Body := ParseCommand(Parser);
  if (Node^.Body = nil) or Parser.Failed or Parser.Incomplete then
    Exit;
  StartOffset := Parser.Tokens.Items[StartIndex].StartOffset;
  EndOffset := Parser.Tokens.Items[Parser.Position - 1].EndOffset;
  Length := EndOffset - StartOffset;
  Node^.SourceText := PChar(AllocateMemory(Length + 1));
  CopyMemory(Node^.SourceText, Parser.Source + StartOffset, Length);
  Node^.SourceText[Length] := #0;
end;

function IsFunctionDefinition(var Parser: TParser): Boolean;
var
  Index: Integer;
begin
  if IsReservedWord(Parser, 'function') then
    Exit(True);
  Index := Parser.Position;
  Result := (Parser.Tokens.Items[Index].Kind = TokenWord) and
    (Index + 2 < Parser.Tokens.Count) and
    (Parser.Tokens.Items[Index + 1].Kind = TokenLeftParenthesis) and
    (Parser.Tokens.Items[Index + 2].Kind = TokenRightParenthesis);
end;

function ParseCompoundCommand(var Parser: TParser): PNode;
begin
  Result := nil;
  if IsReservedWord(Parser, 'case') then
    Exit(ParseCase(Parser));
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
  end;
end;

function IsCompoundStart(var Parser: TParser): Boolean;
begin
  Result := IsReservedWord(Parser, 'case') or IsReservedWord(Parser, 'if') or
    IsReservedWord(Parser, 'while') or IsReservedWord(Parser, 'until') or
    IsReservedWord(Parser, 'for') or IsReservedWord(Parser, '{') or
    (Current(Parser)^.Kind = TokenLeftParenthesis);
end;

function ParseCommand(var Parser: TParser): PNode;
var
  Wrapper: PNode;
begin
  if IsFunctionDefinition(Parser) then
    Exit(ParseFunction(Parser, Parser.Position));
  if not IsCompoundStart(Parser) then
    Exit(ParseSimpleCommand(Parser));
  Result := ParseCompoundCommand(Parser);
  if Parser.Failed or Parser.Incomplete or (Current(Parser)^.Kind <> TokenRedirect) then
    Exit;
  { Redirections after a compound command apply to all of it. }
  Wrapper := NewNode(NodeRedirected);
  Wrapper^.Body := Result;
  Result := Wrapper;
  while Current(Parser)^.Kind = TokenRedirect do
    if not ParseRedirection(Parser, Wrapper) then
      Exit;
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
  Parser.Source := Text;
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
  for Index := 0 to Node^.RedirectionCount - 1 do
    FreeMemory(Node^.Redirections[Index].HereBody);
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
  FreeMemory(Node^.SourceText);
  FreeMemory(Node);
end;

function CopyTextList(Items: PPChar; Count: Integer): PPChar;
var
  Index: Integer;
begin
  if Items = nil then
    Exit(nil);
  Result := PPChar(AllocateZeroedMemory(QWord(Count + 1) * SizeOf(PChar)));
  for Index := 0 to Count - 1 do
    Result[Index] := DuplicateText(Items[Index]);
end;

function CopyOptionalText(Text: PChar): PChar;
begin
  if Text = nil then
    Result := nil
  else
    Result := DuplicateText(Text);
end;

function CopyNode(Node: PNode): PNode;
var
  Index: Integer;
begin
  if Node = nil then
    Exit(nil);
  Result := PNode(AllocateMemory(SizeOf(TNode)));
  Result^ := Node^;
  Result^.Words := CopyTextList(Node^.Words, Node^.WordCount);
  Result^.Assignments := CopyTextList(Node^.Assignments, Node^.AssignmentCount);
  Result^.Redirections := nil;
  if Node^.RedirectionCount > 0 then
  begin
    Result^.Redirections := PRedirection(AllocateMemory(QWord(Node^.RedirectionCount) * SizeOf(TRedirection)));
    for Index := 0 to Node^.RedirectionCount - 1 do
    begin
      Result^.Redirections[Index] := Node^.Redirections[Index];
      Result^.Redirections[Index].Target := CopyOptionalText(Node^.Redirections[Index].Target);
      Result^.Redirections[Index].HereBody := CopyOptionalText(Node^.Redirections[Index].HereBody);
    end;
  end;
  Result^.Children := nil;
  Result^.RunInBackground := nil;
  if Node^.ChildCount > 0 then
  begin
    Result^.Children := PPNode(AllocateMemory(QWord(Node^.ChildCount) * SizeOf(PNode)));
    Result^.RunInBackground := PBoolean(AllocateMemory(QWord(Node^.ChildCount) * SizeOf(Boolean)));
    for Index := 0 to Node^.ChildCount - 1 do
    begin
      Result^.Children[Index] := CopyNode(Node^.Children[Index]);
      Result^.RunInBackground[Index] := Node^.RunInBackground[Index];
    end;
  end;
  Result^.Left := CopyNode(Node^.Left);
  Result^.Right := CopyNode(Node^.Right);
  Result^.Condition := CopyNode(Node^.Condition);
  Result^.Body := CopyNode(Node^.Body);
  Result^.ElseBody := CopyNode(Node^.ElseBody);
  Result^.VariableName := CopyOptionalText(Node^.VariableName);
  Result^.SourceText := CopyOptionalText(Node^.SourceText);
end;

end.
