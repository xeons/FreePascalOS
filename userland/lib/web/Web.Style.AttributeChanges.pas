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
  What an attribute change on an element asks to be styled again, from
  the selectors naming what changed (the engine's name dependencies,
  Css.NameInvalidation): for the class attribute the classes added or
  removed, for id the old and the new id, else the attribute's name;
  [class] and [id] selectors count for those two as well.

  Attributes the element adapter turns into states or reads up the tree
  (href for :link, disabled, checked, lang, dir ...) are not in the
  selectors as names: a change of one of them counts for everything.
}
unit Web.Style.AttributeChanges;

{$mode objfpc}
{$H+}

interface

uses
  Web.Atoms, Web.Dom, Css.StyleEngine, Css.NameInvalidation;

{ What changing attribute LocalName (no namespace) of Element from
  OldValue asks to be styled again. }
function AttributeChangeInvalidation(Engine: TCssStyleEngine; Element: TElement; LocalName: TAtom;
  const OldValue: string): TCssNameInvalidation;

implementation

uses
  SysUtils, Css.Atoms;

var
  StateAttributes: array of TAtom;

{ Whether the element adapter derives states, the language or the
  direction from the attribute (or form control state hangs on it). }
function IsStateAttribute(LocalName: TAtom): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(StateAttributes) do
    if StateAttributes[Index] = LocalName then
      Exit(True);
  Result := False;
end;

function IsAsciiWhitespace(Character: Char): Boolean; inline;
begin
  Result := Character in [#9, #10, #12, #13, ' '];
end;

{ The whitespace separated tokens of Text. }
function SplitTokenList(const Text: string): TStringArray;
var
  Position, Start, Count: Integer;
begin
  Result := nil;
  Count := 0;
  Position := 1;
  while Position <= Length(Text) do
  begin
    while (Position <= Length(Text)) and IsAsciiWhitespace(Text[Position]) do
      Inc(Position);
    if Position > Length(Text) then
      Break;
    Start := Position;
    while (Position <= Length(Text)) and not IsAsciiWhitespace(Text[Position]) do
      Inc(Position);
    if Count >= Length(Result) then
      SetLength(Result, Count * 2 + 4);
    Result[Count] := Copy(Text, Start, Position - Start);
    Inc(Count);
  end;
  SetLength(Result, Count);
end;

function HasToken(const Tokens: TStringArray; const Token: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Tokens) do
    if Tokens[Index] = Token then
      Exit(True);
  Result := False;
end;

{ The selector name atom of Name: lowercase, NoAtom when no selector can
  have it (selector names are interned when parsed). }
function SelectorName(const Name: string): TCssAtom;
begin
  Result := FindAtom(AsciiLowerCase(Name));
end;

{ The classes in one list and not in the other, both ways. }
function ClassChangeInvalidation(Engine: TCssStyleEngine; const OldValue, NewValue: string): TCssNameInvalidation;
var
  OldTokens, NewTokens: TStringArray;
  Index: Integer;
begin
  Result := [];
  OldTokens := SplitTokenList(OldValue);
  NewTokens := SplitTokenList(NewValue);
  for Index := 0 to High(OldTokens) do
    if not HasToken(NewTokens, OldTokens[Index]) then
      Result := Result + Engine.NameInvalidation(snClass, SelectorName(OldTokens[Index]));
  for Index := 0 to High(NewTokens) do
    if not HasToken(OldTokens, NewTokens[Index]) then
      Result := Result + Engine.NameInvalidation(snClass, SelectorName(NewTokens[Index]));
end;

function AttributeChangeInvalidation(Engine: TCssStyleEngine; Element: TElement; LocalName: TAtom;
  const OldValue: string): TCssNameInvalidation;
var
  NewValue: string;
begin
  if IsStateAttribute(LocalName) then
    Exit([niEverywhere]);
  Result := Engine.NameInvalidation(snAttribute, SelectorName(NameOfAtom(LocalName)));
  if (LocalName <> AtomClass) and (LocalName <> AtomId) then
    Exit;
  NewValue := Element.AttributeValueOf(LocalName);
  if LocalName = AtomClass then
    Result := Result + ClassChangeInvalidation(Engine, OldValue, NewValue)
  else if OldValue <> NewValue then
    Result := Result + Engine.NameInvalidation(snId, SelectorName(OldValue)) +
      Engine.NameInvalidation(snId, SelectorName(NewValue));
end;

procedure AddStateAttribute(const Name: string);
begin
  SetLength(StateAttributes, Length(StateAttributes) + 1);
  StateAttributes[High(StateAttributes)] := Atomize(Name);
end;

initialization
  AddStateAttribute('href');
  AddStateAttribute('disabled');
  AddStateAttribute('required');
  AddStateAttribute('readonly');
  AddStateAttribute('checked');
  AddStateAttribute('selected');
  AddStateAttribute('open');
  AddStateAttribute('placeholder');
  AddStateAttribute('type');
  AddStateAttribute('value');
  AddStateAttribute('multiple');
  AddStateAttribute('min');
  AddStateAttribute('max');
  AddStateAttribute('step');
  AddStateAttribute('pattern');
  AddStateAttribute('minlength');
  AddStateAttribute('maxlength');
  AddStateAttribute('lang');
  AddStateAttribute('dir');
  AddStateAttribute('popover');
  AddStateAttribute('contenteditable');
  AddStateAttribute('slot');
  AddStateAttribute('name');
  AddStateAttribute('part');
  AddStateAttribute('exportparts');
  AddStateAttribute('is');
end.
