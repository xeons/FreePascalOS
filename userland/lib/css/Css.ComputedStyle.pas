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
  A computed style: one pointer per property group to a shared style
  struct, the custom properties, and helpers to read values the way
  layout and painting want them.

  Styles are immutable and reference counted. Many elements hold the
  same style object (the style sharing cache), and different styles
  share structs.
}
unit Css.ComputedStyle;

{$mode objfpc}
{$H+}

interface

uses
  Css.Atoms, Css.Keywords, Css.Colors, Css.Values, Css.Selectors, Css.PropertyIds, Css.ComputedValues,
  Css.StyleStructs, Css.CustomProperties;

type
  TCssComputedStyle = class
  private
    FReferences: LongInt;
  public
    Structs: array[TCssStructGroup] of PCssStyleStruct;
    Custom: TCssCustomProperties;
    PseudoElement: TCssPseudoElement;
    { A number unique to this style (hash keys). }
    Serial: LongWord;
    constructor Create;
    destructor Destroy; override;
    function AddRef: TCssComputedStyle;
    procedure Release;
    { The computed value of a physical longhand. }
    function Value(Id: TCssPropertyId): PCssComputedValue;
    function Keyword(Id: TCssPropertyId): TCssKeyword;
    { A length-percentage resolved against Basis (px). }
    function Length(Id: TCssPropertyId; Basis: Double = 0): Double;
    function FontSize: Double;
    { The color property. }
    function Color: TCssColor;
    { A color property with currentcolor resolved. }
    function ColorOf(Id: TCssPropertyId): TCssColor;
    function CustomProperty(const Name: string): string;
    { CSSOM-style text of a computed value. }
    function SerializeProperty(Id: TCssPropertyId): string;
    { Whether display is none. }
    function IsDisplayNone: Boolean;
    property References: LongInt read FReferences;
  end;

var
  LiveStyleCount: Integer = 0;
  NextStyleSerial: LongWord = 0;

implementation

uses
  Css.Tokens, Css.Properties, Css.Serialization;

constructor TCssComputedStyle.Create;
begin
  inherited Create;
  FReferences := 1;
  Serial := InterlockedIncrement(NextStyleSerial);
  InterlockedIncrement(LiveStyleCount);
end;

destructor TCssComputedStyle.Destroy;
var
  Group: TCssStructGroup;
begin
  for Group := Low(TCssStructGroup) to High(TCssStructGroup) do
    ReleaseStruct(Structs[Group]);
  Custom.Release;
  InterlockedDecrement(LiveStyleCount);
  inherited Destroy;
end;

function TCssComputedStyle.AddRef: TCssComputedStyle;
begin
  if Self <> nil then
    InterlockedIncrement(FReferences);
  Result := Self;
end;

procedure TCssComputedStyle.Release;
begin
  if Self = nil then
    Exit;
  if InterlockedDecrement(FReferences) = 0 then
    Free;
end;

function TCssComputedStyle.Value(Id: TCssPropertyId): PCssComputedValue;
begin
  Result := StructValue(Structs[PropertyGroup(Id)], PropertySlot(Id));
end;

function TCssComputedStyle.Keyword(Id: TCssPropertyId): TCssKeyword;
begin
  Result := KeywordOfComputed(Value(Id)^);
end;

function TCssComputedStyle.Length(Id: TCssPropertyId; Basis: Double): Double;
begin
  Result := ResolveComputed(Value(Id)^, Basis);
end;

function TCssComputedStyle.FontSize: Double;
begin
  Result := Value(cpFontSize)^.Number;
end;

function TCssComputedStyle.Color: TCssColor;
begin
  Result := ComputedToColor(Value(cpColor)^, TransparentColor);
end;

function TCssComputedStyle.ColorOf(Id: TCssPropertyId): TCssColor;
begin
  Result := ComputedToColor(Value(Id)^, Color);
end;

function TCssComputedStyle.CustomProperty(const Name: string): string;
var
  Tokens: TCssTokenArray;
begin
  Result := '';
  if Custom.Find(FindAtom(Name), Tokens) then
    Result := SerializeTokenArray(Tokens);
end;

function TCssComputedStyle.SerializeProperty(Id: TCssPropertyId): string;
begin
  Result := SerializeComputed(Value(Id)^);
end;

function TCssComputedStyle.IsDisplayNone: Boolean;
begin
  Result := Keyword(cpDisplay) = kwNone;
end;

end.
