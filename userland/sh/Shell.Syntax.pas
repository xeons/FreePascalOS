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

(*
  The parser that builds the shell's syntax tree (Shell.Nodes).

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
{$H+}

interface

uses
  Shell.Lexer,
  Shell.Nodes;

type
  TParseResult = (ParseSuccess, ParseIncomplete, ParseError);

  TParser = class
  private
    FSource: string;
    FTokens: TTokenArray;
    FPosition: Integer;
    FIncomplete: Boolean;
    FFailed: Boolean;
    FErrorMessage: string;
    function CurrentKind: TTokenKind;
    function CurrentText: string;
    procedure Advance;
    function IsReservedWord(const Word: string): Boolean;
    function AtListTerminator: Boolean;
    procedure SkipNewlines;
    function Stopped: Boolean;
    procedure SetError(const Message: string);
    function Expect(const Word, Message: string): Boolean;
    function ParseRedirection(var Redirections: TRedirectionArray): Boolean;
    function ParseSimpleCommand: TShellNode;
    function ParseIf: TShellNode;
    function ParseLoop: TShellNode;
    function ParseFor: TShellNode;
    function ParseCaseItem(Node: TCaseNode): Boolean;
    function ParseCase: TShellNode;
    function ParseFunction: TShellNode;
    function IsFunctionDefinition: Boolean;
    function ParseCompoundCommand: TShellNode;
    function IsCompoundStart: Boolean;
    function ParseCommand: TShellNode;
    function ParsePipeline: TShellNode;
    function ParseAndOr: TShellNode;
    function ParseList: TSequenceNode;
  public
    constructor Create(const Text: string);
    { Parses the whole input. Tree is nil unless the result is
      ParseSuccess; on ParseError, ErrorMessage describes the problem. }
    function Parse(out Tree: TShellNode; out ErrorMessage: string): TParseResult;
  end;

{ Parses Text with a TParser. }
function ParseInput(const Text: string; out Tree: TShellNode; out ErrorMessage: string): TParseResult;

implementation

uses
  Shell.Text;

function ParseInput(const Text: string; out Tree: TShellNode; out ErrorMessage: string): TParseResult;
var
  Parser: TParser;
begin
  Parser := TParser.Create(Text);
  try
    Result := Parser.Parse(Tree, ErrorMessage);
  finally
    Parser.Free;
  end;
end;

function IsAssignment(const Word: string): Boolean;
var
  Index: Integer;
begin
  Result := False;
  if not IsNameStart(CharAt(Word, 1)) then
    Exit;
  Index := 2;
  while IsNameCharacter(CharAt(Word, Index)) do
    Inc(Index);
  Result := CharAt(Word, Index) = '=';
end;

constructor TParser.Create(const Text: string);
begin
  inherited Create;
  FSource := TextBeforeNull(Text);
end;

{ --- Token access ------------------------------------------------------ }

function TParser.CurrentKind: TTokenKind;
begin
  Result := FTokens[FPosition].Kind;
end;

function TParser.CurrentText: string;
begin
  Result := FTokens[FPosition].Text;
end;

procedure TParser.Advance;
begin
  if CurrentKind <> TokenEnd then
    Inc(FPosition);
end;

function TParser.IsReservedWord(const Word: string): Boolean;
begin
  Result := (CurrentKind = TokenWord) and (CurrentText = Word);
end;

{ Words that end a list inside a compound command. }
function TParser.AtListTerminator: Boolean;
var
  Word: string;
begin
  case CurrentKind of
    TokenEnd, TokenRightParenthesis, TokenDoubleSemicolon:
      Result := True;
    TokenWord:
      begin
        Word := CurrentText;
        Result := (Word = 'then') or (Word = 'else') or (Word = 'elif') or (Word = 'fi') or
          (Word = 'do') or (Word = 'done') or (Word = '}') or (Word = 'esac');
      end;
  else
    Result := False;
  end;
end;

procedure TParser.SkipNewlines;
begin
  while CurrentKind = TokenNewline do
    Advance;
end;

function TParser.Stopped: Boolean;
begin
  Result := FFailed or FIncomplete;
end;

procedure TParser.SetError(const Message: string);
begin
  if Stopped then
    Exit;
  { Running out of tokens means the user is still typing. }
  if CurrentKind = TokenEnd then
  begin
    FIncomplete := True;
    Exit;
  end;
  FFailed := True;
  FErrorMessage := Message;
end;

function TParser.Expect(const Word, Message: string): Boolean;
begin
  SkipNewlines;
  Result := IsReservedWord(Word);
  if Result then
    Advance
  else
    SetError(Message);
end;

{ --- Grammar ----------------------------------------------------------- }

{ Parses the redirection at the current token and adds it. }
function TParser.ParseRedirection(var Redirections: TRedirectionArray): Boolean;
var
  Token: TToken;
  Redirection: TRedirection;
begin
  Token := FTokens[FPosition];
  Advance;
  if CurrentKind <> TokenWord then
  begin
    SetError('syntax error: missing file name after redirection');
    Exit(False);
  end;
  Redirection.Kind := Token.RedirectKind;
  Redirection.Handle := Token.RedirectHandle;
  Redirection.HereBody := Token.HereBody;
  Redirection.HereIsQuoted := Token.HereIsQuoted;
  Redirection.Target := CurrentText;
  Advance;
  AppendRedirection(Redirections, Redirection);
  Result := True;
end;

function TParser.ParseSimpleCommand: TShellNode;
var
  Node: TSimpleCommandNode;
begin
  Node := TSimpleCommandNode.Create;
  while True do
  begin
    if CurrentKind = TokenWord then
    begin
      if (Length(Node.Words) = 0) and IsAssignment(CurrentText) then
        AppendWord(Node.Assignments, CurrentText)
      else
        AppendWord(Node.Words, CurrentText);
      Advance;
    end
    else if CurrentKind = TokenRedirect then
    begin
      if not ParseRedirection(Node.Redirections) then
      begin
        Node.Free;
        Exit(nil);
      end;
    end
    else
      Break;
  end;

  if (Length(Node.Words) = 0) and (Length(Node.Assignments) = 0) and (Length(Node.Redirections) = 0) then
  begin
    SetError('syntax error: command expected');
    Node.Free;
    Exit(nil);
  end;
  Result := Node;
end;

function TParser.ParseIf: TShellNode;
var
  Node: TIfNode;
begin
  Advance; { 'if' or 'elif' }
  Node := TIfNode.Create;
  Result := Node;
  Node.Condition := ParseList;
  if Expect('then', 'syntax error: "then" expected') then
    Node.Body := ParseList;
  SkipNewlines;
  if IsReservedWord('elif') then
    { The rest of the chain, including its "fi", parses as a nested if. }
    Node.ElseBody := ParseIf()
  else
  begin
    if IsReservedWord('else') then
    begin
      Advance;
      Node.ElseBody := ParseList;
    end;
    Expect('fi', 'syntax error: "fi" expected');
  end;
end;

function TParser.ParseLoop: TShellNode;
var
  Node: TLoopNode;
begin
  Node := TLoopNode.Create;
  Result := Node;
  Node.IsUntil := IsReservedWord('until');
  Advance;
  Node.Condition := ParseList;
  if Expect('do', 'syntax error: "do" expected') then
    Node.Body := ParseList;
  Expect('done', 'syntax error: "done" expected');
end;

function TParser.ParseFor: TShellNode;
var
  Node: TForNode;
begin
  Advance; { 'for' }
  Node := TForNode.Create;
  Result := Node;
  if CurrentKind <> TokenWord then
  begin
    SetError('syntax error: variable name expected after "for"');
    Exit;
  end;
  Node.VariableName := CurrentText;
  Advance;
  SkipNewlines;
  if IsReservedWord('in') then
  begin
    Advance;
    { An empty list after "in" means no iterations, not "$@". }
    Node.HasWordList := True;
    while CurrentKind = TokenWord do
    begin
      AppendWord(Node.Words, CurrentText);
      Advance;
    end;
  end;
  if CurrentKind = TokenSemicolon then
    Advance;
  if Expect('do', 'syntax error: "do" expected') then
    Node.Body := ParseList;
  Expect('done', 'syntax error: "done" expected');
end;

{ One "pattern | pattern ) list ;;" of a case; False after an error. }
function TParser.ParseCaseItem(Node: TCaseNode): Boolean;
var
  Item: TCaseItem;
begin
  Result := False;
  Item := TCaseItem.Create;
  Node.Add(Item);
  if CurrentKind = TokenLeftParenthesis then
    Advance;
  repeat
    if CurrentKind <> TokenWord then
    begin
      SetError('syntax error: pattern expected');
      Exit;
    end;
    AppendWord(Item.Patterns, CurrentText);
    Advance;
    if CurrentKind <> TokenPipe then
      Break;
    Advance;
  until False;
  if CurrentKind <> TokenRightParenthesis then
  begin
    SetError('syntax error: ")" expected after pattern');
    Exit;
  end;
  Advance;
  Item.Body := ParseList;
  SkipNewlines;
  if CurrentKind = TokenDoubleSemicolon then
  begin
    Advance;
    SkipNewlines;
  end
  else if not IsReservedWord('esac') then
  begin
    SetError('syntax error: ";;" or "esac" expected');
    Exit;
  end;
  Result := True;
end;

function TParser.ParseCase: TShellNode;
var
  Node: TCaseNode;
begin
  Advance; { 'case' }
  Node := TCaseNode.Create;
  Result := Node;
  if CurrentKind <> TokenWord then
  begin
    SetError('syntax error: word expected after "case"');
    Exit;
  end;
  Node.Subject := CurrentText;
  Advance;
  SkipNewlines;
  if not IsReservedWord('in') then
  begin
    SetError('syntax error: "in" expected');
    Exit;
  end;
  Advance;
  SkipNewlines;
  while not IsReservedWord('esac') do
  begin
    if Stopped then
      Exit;
    if CurrentKind = TokenEnd then
    begin
      SetError('syntax error: "esac" expected');
      Exit;
    end;
    if not ParseCaseItem(Node) then
      Exit;
  end;
  Advance; { 'esac' }
end;

{ NAME ( ) command, or function NAME [( )] command. }
function TParser.ParseFunction: TShellNode;
var
  Node: TFunctionNode;
  StartIndex: Integer;
  StartPosition: Integer;
begin
  StartIndex := FPosition;
  Node := TFunctionNode.Create;
  Result := Node;
  if IsReservedWord('function') then
    Advance;
  if CurrentKind <> TokenWord then
  begin
    SetError('syntax error: function name expected');
    Exit;
  end;
  Node.Name := CurrentText;
  Advance;
  if CurrentKind = TokenLeftParenthesis then
  begin
    Advance;
    if CurrentKind <> TokenRightParenthesis then
    begin
      SetError('syntax error: ")" expected');
      Exit;
    end;
    Advance;
  end;
  SkipNewlines;
  Node.Body := ParseCommand;
  if (Node.Body = nil) or Stopped then
    Exit;
  StartPosition := FTokens[StartIndex].StartPosition;
  Node.SourceText := Copy(FSource, StartPosition, FTokens[FPosition - 1].EndPosition - StartPosition);
end;

function TParser.IsFunctionDefinition: Boolean;
begin
  if IsReservedWord('function') then
    Exit(True);
  Result := (CurrentKind = TokenWord) and (FPosition + 2 < Length(FTokens)) and
    (FTokens[FPosition + 1].Kind = TokenLeftParenthesis) and
    (FTokens[FPosition + 2].Kind = TokenRightParenthesis);
end;

function TParser.ParseCompoundCommand: TShellNode;
begin
  Result := nil;
  if IsReservedWord('case') then
    Exit(ParseCase);
  if IsReservedWord('if') then
    Exit(ParseIf);
  if IsReservedWord('while') or IsReservedWord('until') then
    Exit(ParseLoop);
  if IsReservedWord('for') then
    Exit(ParseFor);
  if IsReservedWord('{') then
  begin
    Advance;
    Result := ParseList;
    Expect('}', 'syntax error: "}" expected');
    Exit;
  end;
  if CurrentKind = TokenLeftParenthesis then
  begin
    Advance;
    Result := ParseList;
    SkipNewlines;
    if CurrentKind = TokenRightParenthesis then
      Advance
    else
      SetError('syntax error: ")" expected');
  end;
end;

function TParser.IsCompoundStart: Boolean;
begin
  Result := IsReservedWord('case') or IsReservedWord('if') or
    IsReservedWord('while') or IsReservedWord('until') or
    IsReservedWord('for') or IsReservedWord('{') or
    (CurrentKind = TokenLeftParenthesis);
end;

function TParser.ParseCommand: TShellNode;
var
  Wrapper: TRedirectedNode;
begin
  if IsFunctionDefinition then
    Exit(ParseFunction);
  if not IsCompoundStart then
    Exit(ParseSimpleCommand);
  Result := ParseCompoundCommand;
  if Stopped or (CurrentKind <> TokenRedirect) then
    Exit;
  { Redirections after a compound command apply to all of it. }
  Wrapper := TRedirectedNode.Create;
  Wrapper.Body := Result;
  Result := Wrapper;
  while CurrentKind = TokenRedirect do
    if not ParseRedirection(Wrapper.Redirections) then
      Exit;
end;

function TParser.ParsePipeline: TShellNode;
var
  Node: TPipelineNode;
  Command: TShellNode;
  Count: Integer;
begin
  Node := TPipelineNode.Create;
  if IsReservedWord('!') then
  begin
    Node.Negate := True;
    Advance;
  end;
  repeat
    Command := ParseCommand;
    if Command = nil then
    begin
      Node.Free;
      Exit(nil);
    end;
    Count := Length(Node.Commands);
    SetLength(Node.Commands, Count + 1);
    Node.Commands[Count] := Command;
    if CurrentKind <> TokenPipe then
      Break;
    Advance;
    SkipNewlines;
  until Stopped;

  { A single command without '!' needs no pipeline node. }
  if (Length(Node.Commands) = 1) and not Node.Negate then
  begin
    Result := Node.Commands[0];
    Node.Commands := nil;
    Node.Free;
  end
  else
    Result := Node;
end;

function TParser.ParseAndOr: TShellNode;
var
  Left: TShellNode;
  Right: TShellNode;
  Node: TAndOrNode;
  Operation: TAndOrOperator;
begin
  Left := ParsePipeline;
  while (Left <> nil) and (CurrentKind in [TokenAndIf, TokenOrIf]) do
  begin
    if CurrentKind = TokenAndIf then
      Operation := OperatorAnd
    else
      Operation := OperatorOr;
    Advance;
    SkipNewlines;
    Right := ParsePipeline;
    if Right = nil then
    begin
      Left.Free;
      Exit(nil);
    end;
    Node := TAndOrNode.Create;
    Node.Left := Left;
    Node.Right := Right;
    Node.Operation := Operation;
    Left := Node;
  end;
  Result := Left;
end;

function TParser.ParseList: TSequenceNode;
var
  Item: TShellNode;
begin
  Result := TSequenceNode.Create;
  SkipNewlines;
  while not AtListTerminator do
  begin
    Item := ParseAndOr;
    if Item = nil then
      Break;
    Result.Add(Item, CurrentKind = TokenAmpersand);
    if CurrentKind in [TokenSemicolon, TokenAmpersand, TokenNewline] then
      Advance
    else if not AtListTerminator then
    begin
      SetError('syntax error: unexpected token');
      Break;
    end;
    SkipNewlines;
    if Stopped then
      Break;
  end;
end;

function TParser.Parse(out Tree: TShellNode; out ErrorMessage: string): TParseResult;
begin
  Tree := nil;
  ErrorMessage := '';
  FPosition := 0;
  FFailed := False;
  FIncomplete := False;
  FErrorMessage := '';
  if Tokenize(FSource, FTokens) = LexIncomplete then
    Exit(ParseIncomplete);

  Tree := ParseList;
  if not Stopped and (CurrentKind <> TokenEnd) then
  begin
    FFailed := True;
    if CurrentKind = TokenWord then
      FErrorMessage := 'syntax error: unexpected word'
    else
      FErrorMessage := 'syntax error: unexpected token';
  end;
  FTokens := nil;

  if Stopped then
  begin
    Tree.Free;
    Tree := nil;
    if FIncomplete then
      Exit(ParseIncomplete);
    ErrorMessage := FErrorMessage;
    Exit(ParseError);
  end;
  Result := ParseSuccess;
end;

end.
