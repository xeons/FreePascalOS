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
  The shell's syntax tree, as Shell.Syntax builds it.

  Words, assignments and redirection targets are kept as raw text;
  Shell.Expansion interprets them when the command runs. A node owns its
  children. Clone makes a deep copy: a function's body outlives the
  command line it came in.
}
unit Shell.Nodes;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Shell.Lexer;

type
  TNodeKind = (NodeSimple, NodePipeline, NodeAndOr, NodeSequence, NodeIf, NodeLoop, NodeFor,
    NodeCase, NodeFunction, NodeRedirected);
  TAndOrOperator = (OperatorAnd, OperatorOr);

  TRedirection = record
    Kind: TRedirectKind;
    Handle: Integer;
    Target: string;     { raw word }
    { Here-documents: the body, and whether it is taken literally. }
    HereBody: string;
    HereIsQuoted: Boolean;
  end;
  TRedirectionArray = array of TRedirection;

  TShellNode = class
  private
    FKind: TNodeKind;
  public
    constructor Create(Kind: TNodeKind);
    function Clone: TShellNode; virtual; abstract;
    property Kind: TNodeKind read FKind;
  end;

  TNodeArray = array of TShellNode;

  { NAME=value... word... with redirections. }
  TSimpleCommandNode = class(TShellNode)
  public
    Words: TStringArray;
    Assignments: TStringArray;
    Redirections: TRedirectionArray;
    constructor Create;
    function Clone: TShellNode; override;
  end;

  { command | command ...; '!' inverts the status. }
  TPipelineNode = class(TShellNode)
  public
    Commands: TNodeArray;
    Negate: Boolean;
    constructor Create;
    destructor Destroy; override;
    function Clone: TShellNode; override;
  end;

  TAndOrNode = class(TShellNode)
  public
    Left: TShellNode;
    Right: TShellNode;
    Operation: TAndOrOperator;
    constructor Create;
    destructor Destroy; override;
    function Clone: TShellNode; override;
  end;

  { A list; RunInBackground[I] tells whether item I ends with '&'. }
  TSequenceNode = class(TShellNode)
  public
    Items: TNodeArray;
    RunInBackground: array of Boolean;
    constructor Create;
    destructor Destroy; override;
    function Clone: TShellNode; override;
    procedure Add(Item: TShellNode; Background: Boolean);
  end;

  { elif nests in ElseBody. }
  TIfNode = class(TShellNode)
  public
    Condition: TShellNode;
    Body: TShellNode;
    ElseBody: TShellNode;
    constructor Create;
    destructor Destroy; override;
    function Clone: TShellNode; override;
  end;

  { while (or until, IsUntil) Condition do Body done. }
  TLoopNode = class(TShellNode)
  public
    Condition: TShellNode;
    Body: TShellNode;
    IsUntil: Boolean;
    constructor Create;
    destructor Destroy; override;
    function Clone: TShellNode; override;
  end;

  { for VariableName [in Words] do Body done; without "in" (HasWordList
    False) the loop runs over "$@". }
  TForNode = class(TShellNode)
  public
    VariableName: string;
    HasWordList: Boolean;
    Words: TStringArray;
    Body: TShellNode;
    constructor Create;
    destructor Destroy; override;
    function Clone: TShellNode; override;
  end;

  { pattern | pattern ) Body ;; }
  TCaseItem = class
  public
    Patterns: TStringArray;
    Body: TShellNode;
    destructor Destroy; override;
    function Clone: TCaseItem;
  end;

  TCaseNode = class(TShellNode)
  public
    Subject: string;
    Items: array of TCaseItem;
    constructor Create;
    destructor Destroy; override;
    function Clone: TShellNode; override;
    procedure Add(Item: TCaseItem);
  end;

  { A definition; SourceText is the definition as written. }
  TFunctionNode = class(TShellNode)
  public
    Name: string;
    Body: TShellNode;
    SourceText: string;
    constructor Create;
    destructor Destroy; override;
    function Clone: TShellNode; override;
  end;

  { A compound command with redirections that apply to all of it. }
  TRedirectedNode = class(TShellNode)
  public
    Body: TShellNode;
    Redirections: TRedirectionArray;
    constructor Create;
    destructor Destroy; override;
    function Clone: TShellNode; override;
  end;

{ Node.Clone, or nil for nil. }
function CloneNode(Node: TShellNode): TShellNode;
procedure AppendWord(var Words: TStringArray; const Word: string);
procedure AppendRedirection(var Redirections: TRedirectionArray; const Redirection: TRedirection);

implementation

function CloneNode(Node: TShellNode): TShellNode;
begin
  if Node = nil then
    Result := nil
  else
    Result := Node.Clone;
end;

procedure FreeNodes(var Nodes: TNodeArray);
var
  Index: Integer;
begin
  for Index := 0 to High(Nodes) do
    Nodes[Index].Free;
  Nodes := nil;
end;

function CloneNodes(const Nodes: TNodeArray): TNodeArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Nodes));
  for Index := 0 to High(Nodes) do
    Result[Index] := CloneNode(Nodes[Index]);
end;

procedure AppendWord(var Words: TStringArray; const Word: string);
var
  Count: Integer;
begin
  Count := Length(Words);
  SetLength(Words, Count + 1);
  Words[Count] := Word;
end;

procedure AppendRedirection(var Redirections: TRedirectionArray; const Redirection: TRedirection);
var
  Count: Integer;
begin
  Count := Length(Redirections);
  SetLength(Redirections, Count + 1);
  Redirections[Count] := Redirection;
end;

{ --- TShellNode -------------------------------------------------------- }

constructor TShellNode.Create(Kind: TNodeKind);
begin
  inherited Create;
  FKind := Kind;
end;

{ --- TSimpleCommandNode ------------------------------------------------ }

constructor TSimpleCommandNode.Create;
begin
  inherited Create(NodeSimple);
end;

function TSimpleCommandNode.Clone: TShellNode;
var
  Duplicate: TSimpleCommandNode;
begin
  Duplicate := TSimpleCommandNode.Create;
  Duplicate.Words := Copy(Words);
  Duplicate.Assignments := Copy(Assignments);
  Duplicate.Redirections := Copy(Redirections);
  Result := Duplicate;
end;

{ --- TPipelineNode ----------------------------------------------------- }

constructor TPipelineNode.Create;
begin
  inherited Create(NodePipeline);
end;

destructor TPipelineNode.Destroy;
begin
  FreeNodes(Commands);
  inherited Destroy;
end;

function TPipelineNode.Clone: TShellNode;
var
  Duplicate: TPipelineNode;
begin
  Duplicate := TPipelineNode.Create;
  Duplicate.Commands := CloneNodes(Commands);
  Duplicate.Negate := Negate;
  Result := Duplicate;
end;

{ --- TAndOrNode -------------------------------------------------------- }

constructor TAndOrNode.Create;
begin
  inherited Create(NodeAndOr);
end;

destructor TAndOrNode.Destroy;
begin
  Left.Free;
  Right.Free;
  inherited Destroy;
end;

function TAndOrNode.Clone: TShellNode;
var
  Duplicate: TAndOrNode;
begin
  Duplicate := TAndOrNode.Create;
  Duplicate.Left := CloneNode(Left);
  Duplicate.Right := CloneNode(Right);
  Duplicate.Operation := Operation;
  Result := Duplicate;
end;

{ --- TSequenceNode ----------------------------------------------------- }

constructor TSequenceNode.Create;
begin
  inherited Create(NodeSequence);
end;

destructor TSequenceNode.Destroy;
begin
  FreeNodes(Items);
  inherited Destroy;
end;

function TSequenceNode.Clone: TShellNode;
var
  Duplicate: TSequenceNode;
begin
  Duplicate := TSequenceNode.Create;
  Duplicate.Items := CloneNodes(Items);
  Duplicate.RunInBackground := Copy(RunInBackground);
  Result := Duplicate;
end;

procedure TSequenceNode.Add(Item: TShellNode; Background: Boolean);
var
  Count: Integer;
begin
  Count := Length(Items);
  SetLength(Items, Count + 1);
  SetLength(RunInBackground, Count + 1);
  Items[Count] := Item;
  RunInBackground[Count] := Background;
end;

{ --- TIfNode ----------------------------------------------------------- }

constructor TIfNode.Create;
begin
  inherited Create(NodeIf);
end;

destructor TIfNode.Destroy;
begin
  Condition.Free;
  Body.Free;
  ElseBody.Free;
  inherited Destroy;
end;

function TIfNode.Clone: TShellNode;
var
  Duplicate: TIfNode;
begin
  Duplicate := TIfNode.Create;
  Duplicate.Condition := CloneNode(Condition);
  Duplicate.Body := CloneNode(Body);
  Duplicate.ElseBody := CloneNode(ElseBody);
  Result := Duplicate;
end;

{ --- TLoopNode --------------------------------------------------------- }

constructor TLoopNode.Create;
begin
  inherited Create(NodeLoop);
end;

destructor TLoopNode.Destroy;
begin
  Condition.Free;
  Body.Free;
  inherited Destroy;
end;

function TLoopNode.Clone: TShellNode;
var
  Duplicate: TLoopNode;
begin
  Duplicate := TLoopNode.Create;
  Duplicate.Condition := CloneNode(Condition);
  Duplicate.Body := CloneNode(Body);
  Duplicate.IsUntil := IsUntil;
  Result := Duplicate;
end;

{ --- TForNode ---------------------------------------------------------- }

constructor TForNode.Create;
begin
  inherited Create(NodeFor);
end;

destructor TForNode.Destroy;
begin
  Body.Free;
  inherited Destroy;
end;

function TForNode.Clone: TShellNode;
var
  Duplicate: TForNode;
begin
  Duplicate := TForNode.Create;
  Duplicate.VariableName := VariableName;
  Duplicate.HasWordList := HasWordList;
  Duplicate.Words := Copy(Words);
  Duplicate.Body := CloneNode(Body);
  Result := Duplicate;
end;

{ --- TCaseItem and TCaseNode ------------------------------------------- }

destructor TCaseItem.Destroy;
begin
  Body.Free;
  inherited Destroy;
end;

function TCaseItem.Clone: TCaseItem;
begin
  Result := TCaseItem.Create;
  Result.Patterns := Copy(Patterns);
  Result.Body := CloneNode(Body);
end;

constructor TCaseNode.Create;
begin
  inherited Create(NodeCase);
end;

destructor TCaseNode.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(Items) do
    Items[Index].Free;
  inherited Destroy;
end;

function TCaseNode.Clone: TShellNode;
var
  Duplicate: TCaseNode;
  Index: Integer;
begin
  Duplicate := TCaseNode.Create;
  Duplicate.Subject := Subject;
  SetLength(Duplicate.Items, Length(Items));
  for Index := 0 to High(Items) do
    Duplicate.Items[Index] := Items[Index].Clone;
  Result := Duplicate;
end;

procedure TCaseNode.Add(Item: TCaseItem);
var
  Count: Integer;
begin
  Count := Length(Items);
  SetLength(Items, Count + 1);
  Items[Count] := Item;
end;

{ --- TFunctionNode ----------------------------------------------------- }

constructor TFunctionNode.Create;
begin
  inherited Create(NodeFunction);
end;

destructor TFunctionNode.Destroy;
begin
  Body.Free;
  inherited Destroy;
end;

function TFunctionNode.Clone: TShellNode;
var
  Duplicate: TFunctionNode;
begin
  Duplicate := TFunctionNode.Create;
  Duplicate.Name := Name;
  Duplicate.Body := CloneNode(Body);
  Duplicate.SourceText := SourceText;
  Result := Duplicate;
end;

{ --- TRedirectedNode --------------------------------------------------- }

constructor TRedirectedNode.Create;
begin
  inherited Create(NodeRedirected);
end;

destructor TRedirectedNode.Destroy;
begin
  Body.Free;
  inherited Destroy;
end;

function TRedirectedNode.Clone: TShellNode;
var
  Duplicate: TRedirectedNode;
begin
  Duplicate := TRedirectedNode.Create;
  Duplicate.Body := CloneNode(Body);
  Duplicate.Redirections := Copy(Redirections);
  Result := Duplicate;
end;

end.
