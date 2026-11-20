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
  The tokens the HTML tokenizer hands the tree builder. Characters come
  as runs (one token for many character tokens of the standard); a run
  holding U+0000 holds nothing else, so the tree builder can drop or
  replace it as a unit. The attribute array of a tag token is the
  tokenizer's and is reused: keep a Copy of it.
}
unit Web.Html.Tokens;

{$mode objfpc}
{$H+}

interface

uses
  Web.Atoms,
  Web.Namespaces;

type
  TTokenKind = (TokenStartTag, TokenEndTag, TokenCharacters, TokenComment, TokenDoctype, TokenEndOfFile);

  TTokenAttribute = record
    { The name as tokenized (lower case). }
    Name: TAtom;
    Value: string;
    { The name after the foreign content adjustments (else Name). }
    LocalName: TAtom;
    NamespaceId: TNamespaceId;
  end;

  TTokenAttributeArray = array of TTokenAttribute;

  TToken = record
    Kind: TTokenKind;
    { Tags }
    TagName: TAtom;
    Attributes: TTokenAttributeArray;
    AttributeCount: Integer;
    SelfClosing: Boolean;
    SelfClosingAcknowledged: Boolean;
    { Characters (UTF-8) and comments }
    Data: string;
    { Doctypes }
    DoctypeName: string;
    PublicId: string;
    SystemId: string;
    HasDoctypeName: Boolean;
    HasPublicId: Boolean;
    HasSystemId: Boolean;
    ForceQuirks: Boolean;
  end;

{ The index of an attribute of a tag token, or -1. }
function TokenAttributeIndex(const Token: TToken; Name: TAtom): Integer;
function TokenAttributeValue(const Token: TToken; Name: TAtom): string;
function TokenHasAttribute(const Token: TToken; Name: TAtom): Boolean;
{ A copy of a tag token's attributes that does not share the tokenizer's
  array. }
function CopyTokenAttributes(const Token: TToken): TTokenAttributeArray;

implementation

function TokenAttributeIndex(const Token: TToken; Name: TAtom): Integer;
var
  Index: Integer;
begin
  for Index := 1 to Token.AttributeCount do
    if Token.Attributes[Index - 1].Name = Name then
      Exit(Index - 1);
  Result := -1;
end;

function TokenAttributeValue(const Token: TToken; Name: TAtom): string;
var
  Index: Integer;
begin
  Index := TokenAttributeIndex(Token, Name);
  if Index < 0 then
    Result := ''
  else
    Result := Token.Attributes[Index].Value;
end;

function TokenHasAttribute(const Token: TToken; Name: TAtom): Boolean;
begin
  Result := TokenAttributeIndex(Token, Name) >= 0;
end;

function CopyTokenAttributes(const Token: TToken): TTokenAttributeArray;
begin
  Result := Copy(Token.Attributes, 0, Token.AttributeCount);
end;

end.
