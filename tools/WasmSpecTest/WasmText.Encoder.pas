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
  The entry points of the text format front end: a module written in
  WebAssembly text into the binary format.

  A module is "(module $name? field*)", or just its fields (the text
  format lets a module that is alone in its file leave out the module
  wrapper). The script forms "(module definition ...)" (read like the
  others), "(module $name? binary string*)" (the bytes
  as written) and "(module $name? quote string*)" (text to be parsed
  only now, so that a malformed one can be expected to fail) are
  understood too.

  Every malformation raises EWasmTextError; nothing is validated.
}
unit WasmText.Encoder;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  WasmText.Lexer,
  WasmText.Tree;

{ Text holding one module, with or without "(module ...)" around it. }
function EncodeModuleText(const Text: AnsiString): TBytes;
{ A "(module ...)" list. Name is its identifier ('' when none). }
function EncodeModuleNode(Node: TTextNode; out Name: AnsiString): TBytes;

implementation

uses
  WasmText.Module;

function JoinStrings(Node: TTextNode; First: Integer): AnsiString;
var
  Index: Integer;
begin
  Result := '';
  for Index := First to Node.Count - 1 do
  begin
    if not Node[Index].IsAtomOf(ttString) then
      raise EWasmTextError.CreateFmt('line %d: unexpected token: expected a string', [Node[Index].Line]);
    Result := Result + Node[Index].Text;
  end;
end;

function BytesOf(const Text: AnsiString): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(Text));
  if Text <> '' then
    Move(Text[1], Result[0], Length(Text));
end;

function EncodeModuleNode(Node: TTextNode; out Name: AnsiString): TBytes;
var
  Position: Integer;
begin
  Name := '';
  Position := 1;
  if (Position < Node.Count) and Node[Position].IsKeyword('definition') then
    Inc(Position);
  if (Position < Node.Count) and Node[Position].IsAtomOf(ttIdentifier) then
  begin
    Name := Node[Position].Text;
    Inc(Position);
  end;
  if (Position < Node.Count) and Node[Position].IsKeyword('binary') then
    Result := BytesOf(JoinStrings(Node, Position + 1))
  else if (Position < Node.Count) and Node[Position].IsKeyword('quote') then
    Result := EncodeModuleText(JoinStrings(Node, Position + 1))
  else
    Result := EncodeModuleFields(Node, Position);
end;

function EncodeModuleText(const Text: AnsiString): TBytes;
var
  Tree: TTextNode;
  Name: AnsiString;
begin
  Tree := ParseTextTree(Text);
  try
    if (Tree.Count = 1) and Tree[0].IsListOf('module') then
      Result := EncodeModuleNode(Tree[0], Name)
    else
      Result := EncodeModuleFields(Tree, 0);
  finally
    Tree.Free;
  end;
end;

end.
