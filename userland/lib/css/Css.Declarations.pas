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
  Declaration blocks: the declarations of a style rule, a keyframe, a
  style attribute or @page, with their values parsed.

  A declaration is a small record (property, importance, value). A
  shorthand is stored as its longhands, each remembering the shorthand
  it came from so that serialization can fold them back. A value with
  var() in it stays unparsed until the cascade substitutes it (for a
  shorthand, every longhand shares the shorthand's tokens). Within one
  block a property is declared once: a later declaration replaces an
  earlier one, except that a normal declaration does not replace an
  !important one.
}
unit Css.Declarations;

{$mode objfpc}
{$H+}

interface

uses
  Css.Atoms, Css.Tokens, Css.Values, Css.PropertyIds;

type
  TCssDeclaration = record
    Id: TCssPropertyId;
    Important: Boolean;
    { The shorthand this longhand was written as (cpInvalid if none). }
    Shorthand: TCssPropertyId;
    { A custom property's name (with the leading dashes). }
    CustomName: TCssAtom;
    Value: TCssValue;
  end;
  PCssDeclaration = ^TCssDeclaration;

  TCssDeclarationBlock = class
  private
    FItems: array of TCssDeclaration;
    FCount: Integer;
    FImportantCount: Integer;
    FUsesAttributes: Boolean;
    function IndexOf(Id: TCssPropertyId; CustomName: TCssAtom): Integer;
    procedure RemoveAt(Index: Integer);
  public
    destructor Destroy; override;
    { Adds a declaration (taking Value's reference). }
    procedure Add(Id: TCssPropertyId; Value: TCssValue; Important: Boolean;
      Shorthand: TCssPropertyId = cpInvalid; CustomName: TCssAtom = NoAtom);
    { Parses "Name: Value" (Value's tokens without the !important) and
      adds what it declares. False when the declaration is invalid. }
    function AddParsed(const Name: string; Value: TCssTokenCursor; Important: Boolean): Boolean;
    function Item(Index: Integer): PCssDeclaration;
    function Find(Id: TCssPropertyId): PCssDeclaration;
    function FindCustom(Name: TCssAtom): PCssDeclaration;
    procedure Clear;
    { CSSOM: the block's text, shorthands folded where possible. }
    function Serialize: string;
    { CSSOM getPropertyValue (longhands and the foldable shorthands). }
    function PropertyValue(const Name: string): string;
    property Count: Integer read FCount;
    function HasImportant: Boolean;
    function HasNormal: Boolean;
    { Some value needs the element's attributes (attr()), so styles
      computed from this block cannot be shared between elements. }
    property UsesAttributes: Boolean read FUsesAttributes;
  end;

{ Whether the tokens contain var() or env() at any depth. }
function ContainsSubstitution(Cursor: TCssTokenCursor): Boolean;
{ A declaration value's range without leading and trailing whitespace. }
function TrimRange(Cursor: TCssTokenCursor): TCssTokenCursor;

implementation

uses
  SysUtils, Css.Keywords, Css.Properties, Css.Grammar, Css.Shorthands, Css.ValueParser,
  Css.Serialization, Css.PropertyParsers;

function ContainsSubstitution(Cursor: TCssTokenCursor): Boolean;
var
  Index: Integer;
  Token: PCssToken;
begin
  for Index := Cursor.Position to Cursor.Stop - 1 do
  begin
    Token := @Cursor.Tokens[Index];
    if (Token^.Kind = tkFunction) and (AsciiSameText(Token^.Text, 'var') or AsciiSameText(Token^.Text, 'env')) then
      Exit(True);
  end;
  Result := False;
end;

function ContainsAttr(Cursor: TCssTokenCursor): Boolean;
var
  Index: Integer;
  Token: PCssToken;
begin
  for Index := Cursor.Position to Cursor.Stop - 1 do
  begin
    Token := @Cursor.Tokens[Index];
    if (Token^.Kind = tkFunction) and AsciiSameText(Token^.Text, 'attr') then
      Exit(True);
  end;
  Result := False;
end;

function TrimRange(Cursor: TCssTokenCursor): TCssTokenCursor;
begin
  Result := Cursor;
  while (Result.Position < Result.Stop) and (Result.Tokens[Result.Position].Kind = tkWhitespace) do
    Inc(Result.Position);
  while (Result.Stop > Result.Position) and (Result.Tokens[Result.Stop - 1].Kind = tkWhitespace) do
    Dec(Result.Stop);
end;

destructor TCssDeclarationBlock.Destroy;
begin
  Clear;
  inherited Destroy;
end;

procedure TCssDeclarationBlock.Clear;
var
  Index: Integer;
begin
  for Index := 0 to FCount - 1 do
    ReleaseValue(FItems[Index].Value);
  FItems := nil;
  FCount := 0;
  FImportantCount := 0;
end;

function TCssDeclarationBlock.IndexOf(Id: TCssPropertyId; CustomName: TCssAtom): Integer;
var
  Index: Integer;
begin
  for Index := FCount - 1 downto 0 do
    if (FItems[Index].Id = Id) and (FItems[Index].CustomName = CustomName) then
      Exit(Index);
  Result := -1;
end;

procedure TCssDeclarationBlock.RemoveAt(Index: Integer);
var
  Other: Integer;
begin
  if FItems[Index].Important then
    Dec(FImportantCount);
  ReleaseValue(FItems[Index].Value);
  for Other := Index to FCount - 2 do
    FItems[Other] := FItems[Other + 1];
  Dec(FCount);
  FItems[FCount].Value := nil;
end;

procedure TCssDeclarationBlock.Add(Id: TCssPropertyId; Value: TCssValue; Important: Boolean;
  Shorthand: TCssPropertyId; CustomName: TCssAtom);
var
  Existing: Integer;
begin
  Existing := IndexOf(Id, CustomName);
  if Existing >= 0 then
  begin
    if FItems[Existing].Important and not Important then
    begin
      Value.Release;
      Exit;
    end;
    RemoveAt(Existing);
  end;
  if FCount >= Length(FItems) then
    SetLength(FItems, FCount * 2 + 4);
  FItems[FCount].Id := Id;
  FItems[FCount].Important := Important;
  FItems[FCount].Shorthand := Shorthand;
  FItems[FCount].CustomName := CustomName;
  FItems[FCount].Value := Value;
  Inc(FCount);
  if Important then
    Inc(FImportantCount);
end;

function TCssDeclarationBlock.Item(Index: Integer): PCssDeclaration;
begin
  Result := @FItems[Index];
end;

function TCssDeclarationBlock.Find(Id: TCssPropertyId): PCssDeclaration;
var
  Index: Integer;
begin
  Index := IndexOf(Id, NoAtom);
  if Index < 0 then
    Result := nil
  else
    Result := @FItems[Index];
end;

function TCssDeclarationBlock.FindCustom(Name: TCssAtom): PCssDeclaration;
var
  Index: Integer;
begin
  Index := IndexOf(cpCustom, Name);
  if Index < 0 then
    Result := nil
  else
    Result := @FItems[Index];
end;

function TCssDeclarationBlock.HasImportant: Boolean;
begin
  Result := FImportantCount > 0;
end;

function TCssDeclarationBlock.HasNormal: Boolean;
begin
  Result := FCount > FImportantCount;
end;

{ The CSS-wide keyword that is the whole value, or kwInvalid. }
function WholeCssWideKeyword(Cursor: TCssTokenCursor): TCssKeyword;
var
  Keyword: TCssKeyword;
begin
  Result := kwInvalid;
  Keyword := PeekKeyword(Cursor);
  if not CssWideKeyword(Keyword) then
    Exit;
  Cursor.NextNonWhitespace;
  if Cursor.AtEndIgnoringWhitespace then
    Result := Keyword;
end;

function TCssDeclarationBlock.AddParsed(const Name: string; Value: TCssTokenCursor; Important: Boolean): Boolean;
var
  Id, Longhand: TCssPropertyId;
  Keyword: TCssKeyword;
  Parsed, Shared: TCssValue;
  Longhands: TCssPropertyIdArray;
  Values: TCssValueArray;
  Index: Integer;
  Trimmed: TCssTokenCursor;
begin
  Result := False;
  Id := PropertyByName(Name);
  Trimmed := TrimRange(Value);
  if Id = cpCustom then
  begin
    Keyword := WholeCssWideKeyword(Trimmed);
    if Keyword <> kwInvalid then
      Parsed := NewKeyword(Keyword)
    else
      Parsed := NewUnparsed(CopyTokens(Trimmed.Tokens, Trimmed.Position, Trimmed.Stop));
    Add(cpCustom, Parsed, Important, cpInvalid, InternAtom(Name));
    Exit(True);
  end;
  if (Id = cpInvalid) and AsciiSameText(Name, 'all') then
  begin
    { 'all' takes only the CSS-wide keywords. }
    Keyword := WholeCssWideKeyword(Trimmed);
    if Keyword = kwInvalid then
      Exit;
    Shared := NewKeyword(Keyword);
    for Longhand := Succ(cpInvalid) to High(TCssPhysicalId) do
      if (Longhand <> cpDirection) and (Longhand <> cpUnicodeBidi) then
        Add(Longhand, Shared.AddRef, Important, cpInvalid);
    Shared.Release;
    Exit(True);
  end;
  if (Id = cpInvalid) or Trimmed.AtEnd then
    Exit;
  if ContainsAttr(Trimmed) then
    FUsesAttributes := True;
  Keyword := WholeCssWideKeyword(Trimmed);
  if IsShorthand(Id) then
  begin
    Longhands := ShorthandLonghands(Id);
    if (Keyword <> kwInvalid) or ContainsSubstitution(Trimmed) then
    begin
      if Keyword <> kwInvalid then
        Shared := NewKeyword(Keyword)
      else
      begin
        Shared := NewUnparsed(CopyTokens(Trimmed.Tokens, Trimmed.Position, Trimmed.Stop));
        Shared.Shorthand := Ord(Id);
      end;
      for Index := 0 to High(Longhands) do
        Add(Longhands[Index], Shared.AddRef, Important, Id);
      Shared.Release;
      Exit(True);
    end;
    if not ExpandShorthand(Id, Trimmed, Values) then
      Exit;
    for Index := 0 to High(Longhands) do
      Add(Longhands[Index], Values[Index], Important, Id);
    Exit(True);
  end;
  if Keyword <> kwInvalid then
    Parsed := NewKeyword(Keyword)
  else if ContainsSubstitution(Trimmed) then
    Parsed := NewUnparsed(CopyTokens(Trimmed.Tokens, Trimmed.Position, Trimmed.Stop))
  else
    Parsed := ParseLonghandValue(Id, Trimmed);
  if Parsed = nil then
    Exit;
  Add(Id, Parsed, Important, cpInvalid);
  Result := True;
end;

{ ---- serialization ---- }

function DeclarationText(const Name, Value: string; Important: Boolean): string;
begin
  Result := Name + ': ' + Value;
  if Important then
    Result := Result + ' !important';
  Result := Result + ';';
end;

{ The shorthand's value from its longhands' values (all present, one
  importance), or '' when it cannot be written as the shorthand. }
function FoldShorthand(Id: TCssPropertyId; const Values: TCssValueArray): string;
var
  Index: Integer;
  AllSame, AllUnparsed: Boolean;
  Top, Right, Bottom, Left: string;
begin
  Result := '';
  AllSame := True;
  AllUnparsed := True;
  for Index := 0 to High(Values) do
  begin
    if Values[Index] <> Values[0] then
      AllSame := False;
    if (Values[Index].Kind <> vkUnparsed) or (Values[Index].Shorthand <> Ord(Id)) then
      AllUnparsed := False;
  end;
  if AllUnparsed and AllSame then
    Exit(Values[0].Serialize);
  for Index := 0 to High(Values) do
    if (Values[Index].Kind = vkKeyword) and CssWideKeyword(Values[Index].Keyword) then
    begin
      if AllSame then
        Exit(Values[0].Serialize);
      Exit('');
    end
    else if Values[Index].Kind = vkUnparsed then
      Exit('');
  case Id of
    cpMargin, cpPadding, cpInset, cpBorderWidth, cpBorderStyle, cpBorderColor:
      begin
        Top := Values[0].Serialize;
        Right := Values[1].Serialize;
        Bottom := Values[2].Serialize;
        Left := Values[3].Serialize;
        if Left <> Right then
          Result := Top + ' ' + Right + ' ' + Bottom + ' ' + Left
        else if Bottom <> Top then
          Result := Top + ' ' + Right + ' ' + Bottom
        else if Right <> Top then
          Result := Top + ' ' + Right
        else
          Result := Top;
      end;
    cpMarginBlock, cpMarginInline, cpPaddingBlock, cpPaddingInline, cpInsetBlock, cpInsetInline,
    cpBorderBlockWidth, cpBorderBlockStyle, cpBorderBlockColor, cpBorderInlineWidth, cpBorderInlineStyle,
    cpBorderInlineColor, cpGap, cpOverflow, cpPlaceContent, cpPlaceItems, cpPlaceSelf:
      begin
        Top := Values[0].Serialize;
        Right := Values[1].Serialize;
        if Top = Right then
          Result := Top
        else
          Result := Top + ' ' + Right;
      end;
    cpBorderTop, cpBorderRight, cpBorderBottom, cpBorderLeft, cpOutline, cpColumnRule, cpBorderBlockStart,
    cpBorderBlockEnd, cpBorderInlineStart, cpBorderInlineEnd:
      Result := Values[0].Serialize + ' ' + Values[1].Serialize + ' ' + Values[2].Serialize;
    cpFlex:
      Result := Values[0].Serialize + ' ' + Values[1].Serialize + ' ' + Values[2].Serialize;
    cpFlexFlow:
      Result := Values[0].Serialize + ' ' + Values[1].Serialize;
    cpGridRow, cpGridColumn:
      if Values[0].Equals(Values[1]) and (Values[0].Kind = vkCustomIdent) then
        Result := Values[0].Serialize
      else if Values[1].IsKeyword(kwAuto) and (Values[0].Kind <> vkCustomIdent) then
        Result := Values[0].Serialize
      else
        Result := Values[0].Serialize + ' / ' + Values[1].Serialize;
  end;
end;

function TCssDeclarationBlock.Serialize: string;
var
  Index, Other, Found: Integer;
  Done: array of Boolean;
  Shorthand: TCssPropertyId;
  Longhands: TCssPropertyIdArray;
  Values: TCssValueArray;
  Important, Complete: Boolean;
  Folded: string;
  Declaration: PCssDeclaration;
begin
  Result := '';
  SetLength(Done, FCount);
  for Index := 0 to FCount - 1 do
  begin
    if Done[Index] then
      Continue;
    Declaration := @FItems[Index];
    Shorthand := Declaration^.Shorthand;
    if Shorthand <> cpInvalid then
    begin
      { Fold the shorthand when all its longhands are here, from it, with one importance. }
      Longhands := ShorthandLonghands(Shorthand);
      SetLength(Values, Length(Longhands));
      Important := Declaration^.Important;
      Complete := True;
      for Other := 0 to High(Longhands) do
      begin
        Found := IndexOf(Longhands[Other], NoAtom);
        if (Found < 0) or Done[Found] or (FItems[Found].Shorthand <> Shorthand) or
          (FItems[Found].Important <> Important) then
        begin
          Complete := False;
          Break;
        end;
        Values[Other] := FItems[Found].Value;
      end;
      if Complete then
      begin
        Folded := FoldShorthand(Shorthand, Values);
        if Folded <> '' then
        begin
          for Other := 0 to High(Longhands) do
            Done[IndexOf(Longhands[Other], NoAtom)] := True;
          if Result <> '' then
            Result := Result + ' ';
          Result := Result + DeclarationText(PropertyName(Shorthand), Folded, Important);
          Continue;
        end;
      end;
    end;
    Done[Index] := True;
    if Result <> '' then
      Result := Result + ' ';
    if Declaration^.Id = cpCustom then
      Result := Result + DeclarationText(AtomText(Declaration^.CustomName),
        SerializeValueOrEmpty(Declaration^.Value), Declaration^.Important)
    else
      Result := Result + DeclarationText(PropertyName(Declaration^.Id), Declaration^.Value.Serialize,
        Declaration^.Important);
  end;
end;

function TCssDeclarationBlock.PropertyValue(const Name: string): string;
var
  Id: TCssPropertyId;
  Declaration: PCssDeclaration;
  Longhands: TCssPropertyIdArray;
  Values: TCssValueArray;
  Index: Integer;
begin
  Result := '';
  Id := PropertyByName(Name);
  if Id = cpCustom then
  begin
    Declaration := FindCustom(FindAtom(Name));
    if Declaration <> nil then
      Result := SerializeValueOrEmpty(Declaration^.Value);
    Exit;
  end;
  if IsShorthand(Id) then
  begin
    Longhands := ShorthandLonghands(Id);
    SetLength(Values, Length(Longhands));
    for Index := 0 to High(Longhands) do
    begin
      Declaration := Find(Longhands[Index]);
      if Declaration = nil then
        Exit;
      Values[Index] := Declaration^.Value;
    end;
    Exit(FoldShorthand(Id, Values));
  end;
  Declaration := Find(Id);
  if Declaration <> nil then
    Result := Declaration^.Value.Serialize;
end;

end.
