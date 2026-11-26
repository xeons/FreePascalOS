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
  The accesskey attribute (HTML Standard 6.7.2): an element's assigned
  access key is the first of its accesskey tokens that is one ASCII
  letter or digit (letters in lower case); the web view activates the
  element when that key is pressed with Alt and Shift (as Firefox does
  on Linux), so accessKeyLabel is "Alt+Shift+" and the key in upper
  case. The first element in tree order with a key wins.
}
unit Web.Dom.AccessKeys;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom;

const
  AccessKeyModifierLabel = 'Alt+Shift+';

{ The assigned access key ('' when none). }
function AssignedAccessKey(Element: TElement): string;
{ What accessKeyLabel gives ('' without an assigned key). }
function AccessKeyLabel(Element: TElement): string;
{ The first element of Document in tree order whose assigned key is Key
  (lower case), nil when none. }
function FindAccessKeyElement(Document: TDocument; const Key: string): TElement;

implementation

uses
  SysUtils,
  Web.Atoms;

var
  AtomAccesskey: TAtom;

function AssignedAccessKey(Element: TElement): string;
var
  Tokens: TStringArray;
  Index: Integer;
  Token: string;
begin
  Result := '';
  if not Element.HasAttributeAtom(AtomAccesskey) then
    Exit;
  Tokens := Element.AttributeValueOf(AtomAccesskey).Split([' ', #9, #10, #12, #13], TStringSplitOptions.ExcludeEmpty);
  for Index := 0 to High(Tokens) do
  begin
    Token := Tokens[Index];
    if (Length(Token) = 1) and (Token[1] in ['a'..'z', 'A'..'Z', '0'..'9']) then
      Exit(LowerCase(Token));
  end;
end;

function AccessKeyLabel(Element: TElement): string;
var
  Key: string;
begin
  Key := AssignedAccessKey(Element);
  if Key = '' then
    Result := ''
  else
    Result := AccessKeyModifierLabel + UpperCase(Key);
end;

function FindAccessKeyElement(Document: TDocument; const Key: string): TElement;
var
  Node: TNode;
begin
  Result := nil;
  if (Document = nil) or (Key = '') then
    Exit;
  Node := Document;
  while Node <> nil do
  begin
    if Node.IsElement and TElement(Node).HasAttributeAtom(AtomAccesskey) and
      (AssignedAccessKey(TElement(Node)) = Key) then
      Exit(TElement(Node));
    Node := Node.NextInTree(Document);
  end;
end;

initialization
  AtomAccesskey := Atomize('accesskey');

end.
