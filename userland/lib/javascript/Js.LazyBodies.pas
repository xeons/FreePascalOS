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
  A lazily compiled function's syntax tree is not kept. Once the parser
  has finished such a function (its early errors checked), all that is
  still needed of its body is what the scope analysis does with it:
  which variables around it the function uses (they become captured)
  and which implicit variables of the functions around it (this,
  arguments) it needs. That is the references its scopes record - and
  of identifiers only one per name and scope, as they all resolve
  alike. Every other node of the function is freed at once, and the
  function's scopes stay (they are small).

  A bundle of megabytes of minified code is mostly such functions: its
  tree was hundreds of megabytes while it was parsed. The functions are
  parsed again from their source when first called (Js.Compiler).
}
unit Js.LazyBodies;

{$mode objfpc}{$H+}

interface

uses
  Js.Lexer,
  Js.Ast;

{ Frees the nodes of Info's parameters and body (made since the arena's
  node count was Mark) but the references its scopes resolve. }
procedure DiscardLazyBody(Arena: TJsAstArena; Info: TJsFunctionInfo; Mark: Integer);

implementation

{ A scope's references with one identifier per name (the first). }
procedure CompactReferences(Scope: TJsScope);
var
  Names: array of UnicodeString;
  Slots: array of Integer;
  Mask, Hash: Cardinal;
  Index, Kept: Integer;
  Node: TJsNode;
  Duplicate: Boolean;
begin
  if Scope.ReferenceCount = 0 then
    Exit;
  Mask := 16;
  while Mask < Cardinal(Scope.ReferenceCount) * 2 do
    Mask := Mask * 2;
  SetLength(Slots, Mask);
  SetLength(Names, Scope.ReferenceCount);
  Dec(Mask);
  Kept := 0;
  for Index := 0 to Scope.ReferenceCount - 1 do
  begin
    Node := Scope.References[Index];
    Duplicate := False;
    if Node.Kind = nkIdentifier then
    begin
      Hash := NameHash(PWideChar(Node.Text), Length(Node.Text)) and Mask;
      while Slots[Hash] <> 0 do
      begin
        if Names[Slots[Hash] - 1] = Node.Text then
        begin
          Duplicate := True;
          Break;
        end;
        Hash := (Hash + 1) and Mask;
      end;
      if not Duplicate then
      begin
        Names[Kept] := Node.Text;
        Slots[Hash] := Kept + 1;
      end;
    end;
    if Duplicate then
    begin
      Node.ReferenceScope := nil;
      Continue;
    end;
    { What the analysis reads is the node itself, not its children. }
    Node.A := nil;
    Node.B := nil;
    Node.C := nil;
    Node.D := nil;
    Node.List := nil;
    Node.Count := 0;
    Scope.References[Kept] := Node;
    Inc(Kept);
  end;
  Scope.ReferenceCount := Kept;
  SetLength(Scope.References, Kept);
end;

{ The nodes the function infos of the scope tree hold go away. }
procedure ForgetNodes(Scope: TJsScope);
var
  Index: Integer;
  Info: TJsFunctionInfo;
begin
  CompactReferences(Scope);
  Info := Scope.Func;
  if (Info <> nil) and (Info.Scope = Scope) then
  begin
    Info.Parameters := nil;
    Info.ParameterCount := 0;
    Info.Body := nil;
    Info.BodyCount := 0;
    Info.ExpressionBody := nil;
    Info.FieldInitializer := nil;
    Info.ClassNode := nil;
    Info.BodyDiscarded := True;
  end;
  for Index := 0 to Scope.ChildCount - 1 do
    ForgetNodes(Scope.Children[Index]);
end;

procedure DiscardLazyBody(Arena: TJsAstArena; Info: TJsFunctionInfo; Mark: Integer);
begin
  ForgetNodes(Info.Scope);
  Arena.ReleaseUnreferencedNodes(Mark);
end;

end.
