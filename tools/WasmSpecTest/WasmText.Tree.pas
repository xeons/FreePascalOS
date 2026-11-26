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
  The text format as S-expressions: every parenthesised list becomes a
  node with children, every other token an atom node. The module encoder
  and the script parser walk this tree; folded instructions are already
  nested the way they are written.

  ParseTextTree returns a list node (without parentheses of its own)
  holding the top level expressions; freeing it frees the whole tree.
}
unit WasmText.Tree;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  WasmText.Lexer;

type
  TTextNodeKind = (tnList, tnAtom);

  TTextNode = class
  private
    FChildren: array of TTextNode;
    FChildCount: Integer;
    function GetChild(Index: Integer): TTextNode;
  public
    Kind: TTextNodeKind;
    { For an atom: its token kind and text (decoded bytes for strings). }
    TokenKind: TTextTokenKind;
    Text: AnsiString;
    Line: Integer;
    constructor CreateList(ALine: Integer);
    constructor CreateAtom(const Token: TTextToken);
    destructor Destroy; override;
    procedure Add(Child: TTextNode);
    { True for a list whose first child is the keyword Name. }
    function IsListOf(const Name: AnsiString): Boolean;
    { True for an atom keyword Name. }
    function IsKeyword(const Name: AnsiString): Boolean;
    function IsAtomOf(AKind: TTextTokenKind): Boolean;
    { The first child's keyword of a list ('' when it is not a keyword). }
    function Head: AnsiString;
    property Children[Index: Integer]: TTextNode read GetChild; default;
    property Count: Integer read FChildCount;
  end;

function ParseTextTree(const Source: AnsiString): TTextNode;

implementation

constructor TTextNode.CreateList(ALine: Integer);
begin
  inherited Create;
  Kind := tnList;
  Line := ALine;
end;

constructor TTextNode.CreateAtom(const Token: TTextToken);
begin
  inherited Create;
  Kind := tnAtom;
  TokenKind := Token.Kind;
  Text := Token.Text;
  Line := Token.Line;
end;

destructor TTextNode.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FChildCount - 1 do
    FChildren[Index].Free;
  inherited Destroy;
end;

function TTextNode.GetChild(Index: Integer): TTextNode;
begin
  Result := FChildren[Index];
end;

procedure TTextNode.Add(Child: TTextNode);
begin
  if FChildCount = Length(FChildren) then
    SetLength(FChildren, FChildCount * 2 + 4);
  FChildren[FChildCount] := Child;
  Inc(FChildCount);
end;

function TTextNode.IsListOf(const Name: AnsiString): Boolean;
begin
  Result := (Kind = tnList) and (FChildCount > 0) and FChildren[0].IsKeyword(Name);
end;

function TTextNode.IsKeyword(const Name: AnsiString): Boolean;
begin
  Result := (Kind = tnAtom) and (TokenKind = ttKeyword) and (Text = Name);
end;

function TTextNode.IsAtomOf(AKind: TTextTokenKind): Boolean;
begin
  Result := (Kind = tnAtom) and (TokenKind = AKind);
end;

function TTextNode.Head: AnsiString;
begin
  if (Kind = tnList) and (FChildCount > 0) and FChildren[0].IsAtomOf(ttKeyword) then
    Result := FChildren[0].Text
  else
    Result := '';
end;

function ParseTextTree(const Source: AnsiString): TTextNode;
var
  Tokens: TTextTokenArray;
  Stack: array of TTextNode;
  Depth, Index: Integer;
  Node: TTextNode;
begin
  Tokens := TokenizeText(Source);
  Result := TTextNode.CreateList(1);
  try
    SetLength(Stack, 16);
    Stack[0] := Result;
    Depth := 0;
    for Index := 0 to High(Tokens) do
      case Tokens[Index].Kind of
        ttLeftParenthesis:
          begin
            Node := TTextNode.CreateList(Tokens[Index].Line);
            Stack[Depth].Add(Node);
            Inc(Depth);
            if Depth >= Length(Stack) then
              SetLength(Stack, Length(Stack) * 2);
            Stack[Depth] := Node;
          end;
        ttRightParenthesis:
          begin
            if Depth = 0 then
              raise EWasmTextError.CreateFmt('line %d: unexpected )', [Tokens[Index].Line]);
            Dec(Depth);
          end;
      else
        Stack[Depth].Add(TTextNode.CreateAtom(Tokens[Index]));
      end;
    if Depth <> 0 then
      raise EWasmTextError.Create('unexpected end of input: unclosed (');
  except
    Result.Free;
    raise;
  end;
end;

end.
