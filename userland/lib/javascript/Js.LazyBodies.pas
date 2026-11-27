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
  alike. Those are copied into nodes of their own (the arena's
  reference nodes), the function infos inside forget their nodes, and
  every node made since the function began is released at once: the
  next function is parsed into the same memory. The function's scopes
  stay (they are small).

  So a lazy function's body costs a scratch tree, not a tree: a bundle
  of megabytes of minified code is mostly such functions (its tree was
  hundreds of megabytes while it was parsed). The functions are parsed
  again from their source when first called (Js.Compiler).
}
unit Js.LazyBodies;

{$mode objfpc}{$H+}

interface

uses
  Js.Lexer,
  Js.Ast;

{ Keeps the references of Info's scopes and releases every node made
  since the arena's node count was Mark (Info's parameters and body). }
procedure DiscardLazyBody(Arena: TJsAstArena; Info: TJsFunctionInfo; Mark: Integer);

implementation

const
  { Scopes with more kept identifiers than this find duplicates
    through a hash. }
  LinearDuplicateLimit = 16;

type
  { The identifier names a scope keeps, by the address of their text:
    names are interned by the lexer, so one name is one string (a name
    made otherwise, never equal by address, is merely kept twice). }
  TKeptNames = record
    Slots: array of Pointer;
    Mask: LongWord;
  end;

function PointerHash(Key: Pointer): LongWord; inline;
begin
  {$push}{$R-}{$Q-}
  Result := LongWord(PtrUInt(Key) shr 3) * LongWord(2654435761);
  {$pop}
end;

{ Adds Key; False when it was there. }
function AddKeptName(var Names: TKeptNames; Key: Pointer): Boolean;
var
  Slot: LongWord;
begin
  Slot := PointerHash(Key) and Names.Mask;
  while Names.Slots[Slot] <> nil do
  begin
    if Names.Slots[Slot] = Key then
      Exit(False);
    Slot := (Slot + 1) and Names.Mask;
  end;
  Names.Slots[Slot] := Key;
  Result := True;
end;

{ Whether an identifier with Text's name is among References[0..Count - 1]. }
function KeptLinearly(const References: array of TJsNode; Count: Integer; Text: Pointer): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    if (References[Index].Kind = nkIdentifier) and (Pointer(References[Index].Text) = Text) then
      Exit(True);
  Result := False;
end;

{ A reference node of the arena standing for Node. }
function CopyReference(Arena: TJsAstArena; Node: TJsNode): TJsNode;
begin
  Result := Arena.NewReferenceNode(Node.Kind, Node.Line, Node.Column);
  Result.Op := Node.Op;
  Result.Flags := Node.Flags;
  Result.Text := Node.Text;
  Result.Number := Node.Number;
  Result.Scope := Node.Scope;
end;

{ The scope's references, one identifier per name (the first), copied
  out of the tree. }
procedure KeepReferences(Arena: TJsAstArena; Scope: TJsScope);
var
  Names: TKeptNames;
  Index, Kept, Size: Integer;
  Node: TJsNode;
  Hashed: Boolean;
begin
  if Scope.ReferenceCount = 0 then
    Exit;
  Hashed := Scope.ReferenceCount > LinearDuplicateLimit;
  if Hashed then
  begin
    Size := 32;
    while Size < Scope.ReferenceCount * 2 do
      Size := Size * 2;
    SetLength(Names.Slots, Size);
    Names.Mask := LongWord(Size - 1);
  end;
  Kept := 0;
  for Index := 0 to Scope.ReferenceCount - 1 do
  begin
    Node := Scope.References[Index];
    if Node.Kind = nkIdentifier then
    begin
      if Hashed then
      begin
        if not AddKeptName(Names, Pointer(Node.Text)) then
          Continue;
      end
      else if KeptLinearly(Scope.References, Kept, Pointer(Node.Text)) then
        Continue;
    end;
    Scope.References[Kept] := CopyReference(Arena, Node);
    Inc(Kept);
  end;
  Scope.ReferenceCount := Kept;
  SetLength(Scope.References, Kept);
end;

{ The nodes a function info holds go away. }
procedure ForgetInfoNodes(Info: TJsFunctionInfo);
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

{ The scope tree's references copied out, its function infos without
  nodes. A function inside that was discarded already (its own body
  finished first) has nothing left in the tree but what its caller set
  on its info since. }
procedure KeepScopeTree(Arena: TJsAstArena; Scope: TJsScope; Root: Boolean);
var
  Index: Integer;
  Info: TJsFunctionInfo;
begin
  Info := Scope.Func;
  if (Info <> nil) and (Info.Scope = Scope) then
  begin
    if Info.BodyDiscarded and not Root then
    begin
      ForgetInfoNodes(Info);
      Exit;
    end;
    ForgetInfoNodes(Info);
  end;
  KeepReferences(Arena, Scope);
  for Index := 0 to Scope.ChildCount - 1 do
    KeepScopeTree(Arena, Scope.Children[Index], False);
end;

procedure DiscardLazyBody(Arena: TJsAstArena; Info: TJsFunctionInfo; Mark: Integer);
begin
  KeepScopeTree(Arena, Info.Scope, True);
  Arena.ReleaseNodes(Mark);
end;

end.
