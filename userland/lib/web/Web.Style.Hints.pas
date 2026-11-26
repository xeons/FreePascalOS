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
  Presentational hints: the HTML attributes the HTML Standard's
  rendering section maps to CSS (width, height, bgcolor, align, valign,
  border, cellspacing, cellpadding, nowrap, font's color, face and
  size, hr's size and noshade, list types, br's clear, hspace and
  vspace ...).

  SVG elements (inline SVG) take their presentation attributes (fill,
  stroke-width, font-size ...) as hints, through libsvg's list of them;
  the outermost <svg> also its width and height, which size its box.

  The hints are written as declaration text and parsed with libcss's
  style attribute parser, once per element until its attributes change;
  the cascade puts them below every author rule. Dimensions and colors
  are read with the HTML Standard's rules for dimension values and
  legacy color values.
}
unit Web.Style.Hints;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom, Css.Declarations;

{ The element's presentational hints, nil when it has none. }
function BuildPresentationalHints(Element: TElement): TCssDeclarationBlock;

{ HTML's rules for parsing dimension values: '' when Value is none,
  else CSS text ('50%', '120px'). NonZero refuses 0. }
function ParseHtmlDimension(const Value: string; NonZero: Boolean): string;
{ HTML's rules for parsing a legacy color value: '' when invalid, else
  CSS text. }
function ParseHtmlLegacyColor(const Value: string): string;

implementation

uses
  SysUtils, Web.Atoms, Web.Namespaces, Css.Colors, Css.Parser, Svg.Presentation;

var
  AtomBgcolor, AtomAlign, AtomValign, AtomBorder, AtomCellspacing, AtomCellpadding, AtomNowrap,
  AtomHspace, AtomVspace, AtomNoshade, AtomClear, AtomTextAttribute, AtomBackground, AtomMarginwidth,
  AtomMarginheight, AtomLeftmargin, AtomTopmargin, AtomRightmargin, AtomBottommargin: TAtom;

function IsAsciiWhitespace(Character: Char): Boolean; inline;
begin
  Result := Character in [#9, #10, #12, #13, ' '];
end;

function ParseHtmlDimension(const Value: string; NonZero: Boolean): string;
var
  Position, StartPosition: Integer;
  Number: Double;
  Text: string;
  Settings: TFormatSettings;
begin
  Result := '';
  Position := 1;
  while (Position <= Length(Value)) and IsAsciiWhitespace(Value[Position]) do
    Inc(Position);
  StartPosition := Position;
  while (Position <= Length(Value)) and (Value[Position] in ['0'..'9']) do
    Inc(Position);
  if Position = StartPosition then
    Exit;
  if (Position <= Length(Value)) and (Value[Position] = '.') then
  begin
    Inc(Position);
    while (Position <= Length(Value)) and (Value[Position] in ['0'..'9']) do
      Inc(Position);
  end;
  Text := Copy(Value, StartPosition, Position - StartPosition);
  if (Text <> '') and (Text[Length(Text)] = '.') then
    Delete(Text, Length(Text), 1);
  Settings := DefaultFormatSettings;
  Settings.DecimalSeparator := '.';
  Number := StrToFloatDef(Text, -1, Settings);
  if Number < 0 then
    Exit;
  if NonZero and (Number = 0) then
    Exit;
  if (Position <= Length(Value)) and (Value[Position] = '%') then
    Result := Text + '%'
  else
    Result := Text + 'px';
end;

function HexValue(Character: Char): Integer;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
    'A'..'F': Result := Ord(Character) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function ParseHtmlLegacyColor(const Value: string): string;
var
  Text: string;
  Index, ComponentLength: Integer;
  Red, Green, Blue: string;
  NamedColor: TCssColor;
begin
  Result := '';
  Text := Trim(Value);
  if (Text = '') or SameText(Text, 'transparent') then
    Exit;
  if (Length(Text) = 4) and (Text[1] = '#') and (HexValue(Text[2]) >= 0) and (HexValue(Text[3]) >= 0) and
     (HexValue(Text[4]) >= 0) then
    Exit(Text);
  if FindNamedColor(LowerCase(Text), NamedColor) then
    Exit(LowerCase(Text));
  { The legacy algorithm: non-hex characters become 0, padded to a
    multiple of three, each third cut to its last two significant digits. }
  if Text[1] = '#' then
    Delete(Text, 1, 1);
  for Index := 1 to Length(Text) do
    if HexValue(Text[Index]) < 0 then
      Text[Index] := '0';
  if Length(Text) > 128 then
    SetLength(Text, 128);
  while (Length(Text) = 0) or (Length(Text) mod 3 <> 0) do
    Text := Text + '0';
  ComponentLength := Length(Text) div 3;
  Red := Copy(Text, 1, ComponentLength);
  Green := Copy(Text, ComponentLength + 1, ComponentLength);
  Blue := Copy(Text, 2 * ComponentLength + 1, ComponentLength);
  if ComponentLength > 8 then
  begin
    Red := Copy(Red, ComponentLength - 7, 8);
    Green := Copy(Green, ComponentLength - 7, 8);
    Blue := Copy(Blue, ComponentLength - 7, 8);
    ComponentLength := 8;
  end;
  while (ComponentLength > 2) and (Red[1] = '0') and (Green[1] = '0') and (Blue[1] = '0') do
  begin
    Delete(Red, 1, 1);
    Delete(Green, 1, 1);
    Delete(Blue, 1, 1);
    Dec(ComponentLength);
  end;
  if ComponentLength > 2 then
  begin
    SetLength(Red, 2);
    SetLength(Green, 2);
    SetLength(Blue, 2);
  end
  else if ComponentLength = 1 then
  begin
    Red := '0' + Red;
    Green := '0' + Green;
    Blue := '0' + Blue;
  end;
  Result := '#' + Red + Green + Blue;
end;

type
  THintWriter = record
    Text: string;
    Element: TElement;
  end;

procedure AddDeclaration(var Writer: THintWriter; const Name, Value: string);
begin
  if Value = '' then
    Exit;
  Writer.Text := Writer.Text + Name + ':' + Value + ';';
end;

function Attribute(var Writer: THintWriter; Name: TAtom; out Value: string): Boolean;
begin
  Result := Writer.Element.HasAttributeAtom(Name);
  if Result then
    Value := Writer.Element.AttributeValueOf(Name)
  else
    Value := '';
end;

procedure MapDimension(var Writer: THintWriter; Name: TAtom; const PropertyName: string; NonZero: Boolean);
var
  Value: string;
begin
  if Attribute(Writer, Name, Value) then
    AddDeclaration(Writer, PropertyName, ParseHtmlDimension(Value, NonZero));
end;

procedure MapColor(var Writer: THintWriter; Name: TAtom; const PropertyName: string);
var
  Value: string;
begin
  if Attribute(Writer, Name, Value) then
    AddDeclaration(Writer, PropertyName, ParseHtmlLegacyColor(Value));
end;

procedure MapBackgroundImage(var Writer: THintWriter);
var
  Value: string;
begin
  if Attribute(Writer, AtomBackground, Value) and (Trim(Value) <> '') then
    AddDeclaration(Writer, 'background-image', 'url("' + StringReplace(Trim(Value), '"', '%22', [rfReplaceAll]) + '")');
end;

procedure MapTextAlign(var Writer: THintWriter);
var
  Value: string;
begin
  if not Attribute(Writer, AtomAlign, Value) then
    Exit;
  Value := AsciiLowerCase(Trim(Value));
  if (Value = 'left') or (Value = 'right') or (Value = 'center') or (Value = 'justify') then
  begin
    if Value = 'center' then
      Value := '-webkit-center'
    else if Value = 'left' then
      Value := '-webkit-left'
    else if Value = 'right' then
      Value := '-webkit-right';
    AddDeclaration(Writer, 'text-align', Value);
  end
  else if Value = 'middle' then
    AddDeclaration(Writer, 'text-align', '-webkit-center');
end;

procedure MapVerticalAlign(var Writer: THintWriter);
var
  Value: string;
begin
  if not Attribute(Writer, AtomValign, Value) then
    Exit;
  Value := AsciiLowerCase(Trim(Value));
  if (Value = 'top') or (Value = 'middle') or (Value = 'bottom') or (Value = 'baseline') then
    AddDeclaration(Writer, 'vertical-align', Value);
end;

procedure MapReplacedAlign(var Writer: THintWriter);
var
  Value: string;
begin
  if not Attribute(Writer, AtomAlign, Value) then
    Exit;
  Value := AsciiLowerCase(Trim(Value));
  if (Value = 'left') or (Value = 'right') then
    AddDeclaration(Writer, 'float', Value)
  else if (Value = 'top') or (Value = 'bottom') or (Value = 'middle') then
    AddDeclaration(Writer, 'vertical-align', Value)
  else if (Value = 'absmiddle') or (Value = 'abscenter') then
    AddDeclaration(Writer, 'vertical-align', 'middle')
  else if Value = 'texttop' then
    AddDeclaration(Writer, 'vertical-align', 'text-top');
end;

procedure MapSpace(var Writer: THintWriter);
var
  Dimension: string;
  Value: string;
begin
  if Attribute(Writer, AtomHspace, Value) then
  begin
    Dimension := ParseHtmlDimension(Value, False);
    AddDeclaration(Writer, 'margin-left', Dimension);
    AddDeclaration(Writer, 'margin-right', Dimension);
  end;
  if Attribute(Writer, AtomVspace, Value) then
  begin
    Dimension := ParseHtmlDimension(Value, False);
    AddDeclaration(Writer, 'margin-top', Dimension);
    AddDeclaration(Writer, 'margin-bottom', Dimension);
  end;
end;

function ParseNonNegativeInteger(const Value: string; out Number: Integer): Boolean;
var
  Position, StartPosition: Integer;
begin
  Number := 0;
  Position := 1;
  while (Position <= Length(Value)) and IsAsciiWhitespace(Value[Position]) do
    Inc(Position);
  if (Position <= Length(Value)) and (Value[Position] = '+') then
    Inc(Position);
  StartPosition := Position;
  while (Position <= Length(Value)) and (Value[Position] in ['0'..'9']) and (Number < 100000) do
  begin
    Number := Number * 10 + Ord(Value[Position]) - Ord('0');
    Inc(Position);
  end;
  Result := Position > StartPosition;
end;

{ The nearest table ancestor of a cell (through its row and section). }
function TableOfCell(Element: TElement): TElement;
var
  Node: TElement;
begin
  Node := Element.ParentElement;
  while (Node <> nil) and not Node.IsHtmlElement(AtomTable) do
  begin
    if Node.IsHtmlElement(AtomTd) or Node.IsHtmlElement(AtomTh) then
      Exit(nil);
    Node := Node.ParentElement;
  end;
  Result := Node;
end;

procedure MapBody(var Writer: THintWriter);
var
  Value: string;
begin
  MapColor(Writer, AtomBgcolor, 'background-color');
  MapColor(Writer, AtomTextAttribute, 'color');
  MapBackgroundImage(Writer);
  if Attribute(Writer, AtomMarginheight, Value) or Attribute(Writer, AtomTopmargin, Value) then
    AddDeclaration(Writer, 'margin-top', ParseHtmlDimension(Value, False));
  if Attribute(Writer, AtomMarginheight, Value) or Attribute(Writer, AtomBottommargin, Value) then
    AddDeclaration(Writer, 'margin-bottom', ParseHtmlDimension(Value, False));
  if Attribute(Writer, AtomMarginwidth, Value) or Attribute(Writer, AtomLeftmargin, Value) then
    AddDeclaration(Writer, 'margin-left', ParseHtmlDimension(Value, False));
  if Attribute(Writer, AtomMarginwidth, Value) or Attribute(Writer, AtomRightmargin, Value) then
    AddDeclaration(Writer, 'margin-right', ParseHtmlDimension(Value, False));
end;

procedure MapTable(var Writer: THintWriter);
var
  Value: string;
  Number: Integer;
begin
  MapColor(Writer, AtomBgcolor, 'background-color');
  MapBackgroundImage(Writer);
  MapDimension(Writer, AtomWidth, 'width', True);
  MapDimension(Writer, AtomHeight, 'height', False);
  if Attribute(Writer, AtomCellspacing, Value) then
    AddDeclaration(Writer, 'border-spacing', ParseHtmlDimension(Value, False));
  if Attribute(Writer, AtomBorder, Value) then
  begin
    if not ParseNonNegativeInteger(Value, Number) then
      Number := 1;
    if Number > 0 then
      AddDeclaration(Writer, 'border', IntToStr(Number) + 'px outset gray');
  end;
  if Attribute(Writer, AtomAlign, Value) then
  begin
    Value := AsciiLowerCase(Trim(Value));
    if Value = 'center' then
    begin
      AddDeclaration(Writer, 'margin-left', 'auto');
      AddDeclaration(Writer, 'margin-right', 'auto');
    end
    else if (Value = 'left') or (Value = 'right') then
      AddDeclaration(Writer, 'float', Value);
  end;
end;

procedure MapCell(var Writer: THintWriter);
var
  Table: TElement;
  Value: string;
  Number: Integer;
begin
  MapColor(Writer, AtomBgcolor, 'background-color');
  MapBackgroundImage(Writer);
  MapDimension(Writer, AtomWidth, 'width', True);
  MapDimension(Writer, AtomHeight, 'height', True);
  MapTextAlign(Writer);
  MapVerticalAlign(Writer);
  if Writer.Element.HasAttributeAtom(AtomNowrap) then
    AddDeclaration(Writer, 'white-space', 'nowrap');
  Table := TableOfCell(Writer.Element);
  if Table = nil then
    Exit;
  if Table.HasAttributeAtom(AtomCellpadding) then
    AddDeclaration(Writer, 'padding', ParseHtmlDimension(Table.AttributeValueOf(AtomCellpadding), False));
  if Table.HasAttributeAtom(AtomBorder) then
  begin
    Value := Table.AttributeValueOf(AtomBorder);
    if not ParseNonNegativeInteger(Value, Number) then
      Number := 1;
    if Number > 0 then
      AddDeclaration(Writer, 'border', '1px inset gray');
  end;
end;

procedure MapReplaced(var Writer: THintWriter; WithBorder: Boolean);
var
  Value: string;
  Number: Integer;
begin
  MapDimension(Writer, AtomWidth, 'width', False);
  MapDimension(Writer, AtomHeight, 'height', False);
  MapReplacedAlign(Writer);
  MapSpace(Writer);
  if WithBorder and Attribute(Writer, AtomBorder, Value) and ParseNonNegativeInteger(Value, Number) then
  begin
    AddDeclaration(Writer, 'border-width', IntToStr(Number) + 'px');
    AddDeclaration(Writer, 'border-style', 'solid');
  end;
end;

{ An iframe whose frameborder is zero (or "no") has no border (HTML
  15.4.3). }
procedure MapFrameBorder(var Writer: THintWriter);
var
  Value: string;
  Number: Integer;
begin
  if not Attribute(Writer, Atomize('frameborder'), Value) then
    Exit;
  Value := AsciiLowerCase(Trim(Value));
  if (Value = 'no') or (ParseNonNegativeInteger(Value, Number) and (Number = 0)) then
    AddDeclaration(Writer, 'border', 'none');
end;

procedure MapHorizontalRule(var Writer: THintWriter);
var
  Value: string;
  Number: Integer;
  Color: string;
begin
  MapDimension(Writer, AtomWidth, 'width', True);
  if Attribute(Writer, AtomSize, Value) and ParseNonNegativeInteger(Value, Number) and (Number > 0) then
  begin
    if Writer.Element.HasAttributeAtom(AtomNoshade) or Writer.Element.HasAttributeAtom(AtomColor) then
      AddDeclaration(Writer, 'height', IntToStr(Number) + 'px')
    else if Number = 1 then
      AddDeclaration(Writer, 'border-bottom-width', '0')
    else
      AddDeclaration(Writer, 'height', IntToStr(Number - 2) + 'px');
  end;
  if Attribute(Writer, AtomColor, Value) then
  begin
    Color := ParseHtmlLegacyColor(Value);
    AddDeclaration(Writer, 'color', Color);
    AddDeclaration(Writer, 'background-color', Color);
    AddDeclaration(Writer, 'border-style', 'none');
  end;
  if Writer.Element.HasAttributeAtom(AtomNoshade) then
  begin
    AddDeclaration(Writer, 'border-style', 'solid');
    AddDeclaration(Writer, 'border-color', 'gray');
    AddDeclaration(Writer, 'background-color', 'gray');
  end;
  if Attribute(Writer, AtomAlign, Value) then
  begin
    Value := AsciiLowerCase(Trim(Value));
    if Value = 'left' then
    begin
      AddDeclaration(Writer, 'margin-left', '0');
      AddDeclaration(Writer, 'margin-right', 'auto');
    end
    else if Value = 'right' then
    begin
      AddDeclaration(Writer, 'margin-left', 'auto');
      AddDeclaration(Writer, 'margin-right', '0');
    end
    else if Value = 'center' then
    begin
      AddDeclaration(Writer, 'margin-left', 'auto');
      AddDeclaration(Writer, 'margin-right', 'auto');
    end;
  end;
end;

procedure MapFont(var Writer: THintWriter);
const
  SizeKeywords: array[1..7] of string = ('x-small', 'small', 'medium', 'large', 'x-large', 'xx-large',
    'xxx-large');
var
  Value: string;
  Position, Number: Integer;
  Relative: Char;
begin
  MapColor(Writer, AtomColor, 'color');
  if Attribute(Writer, AtomFace, Value) and (Trim(Value) <> '') then
    AddDeclaration(Writer, 'font-family', Value);
  if not Attribute(Writer, AtomSize, Value) then
    Exit;
  Value := Trim(Value);
  Relative := ' ';
  Position := 1;
  if (Value <> '') and (Value[1] in ['+', '-']) then
  begin
    Relative := Value[1];
    Inc(Position);
  end;
  Number := 0;
  if (Position > Length(Value)) or not (Value[Position] in ['0'..'9']) then
    Exit;
  while (Position <= Length(Value)) and (Value[Position] in ['0'..'9']) and (Number < 100) do
  begin
    Number := Number * 10 + Ord(Value[Position]) - Ord('0');
    Inc(Position);
  end;
  if Relative = '+' then
    Number := 3 + Number
  else if Relative = '-' then
    Number := 3 - Number;
  if Number < 1 then
    Number := 1;
  if Number > 7 then
    Number := 7;
  AddDeclaration(Writer, 'font-size', SizeKeywords[Number]);
end;

procedure MapListType(var Writer: THintWriter);
var
  Value, Mapped: string;
begin
  if not Attribute(Writer, AtomType, Value) then
    Exit;
  Value := Trim(Value);
  Mapped := '';
  if Value = '1' then
    Mapped := 'decimal'
  else if Value = 'a' then
    Mapped := 'lower-alpha'
  else if Value = 'A' then
    Mapped := 'upper-alpha'
  else if Value = 'i' then
    Mapped := 'lower-roman'
  else if Value = 'I' then
    Mapped := 'upper-roman'
  else if SameText(Value, 'disc') then
    Mapped := 'disc'
  else if SameText(Value, 'circle') then
    Mapped := 'circle'
  else if SameText(Value, 'square') then
    Mapped := 'square'
  else if SameText(Value, 'none') then
    Mapped := 'none';
  AddDeclaration(Writer, 'list-style-type', Mapped);
end;

{ ol start and li value as the list-item counter. }
procedure MapListNumbering(var Writer: THintWriter; Name: TAtom);
var
  Value: string;
  Number, Code: Integer;
begin
  if (Name = AtomOl) and Attribute(Writer, AtomStart, Value) then
  begin
    Val(Trim(Value), Number, Code);
    if Code = 0 then
      AddDeclaration(Writer, 'counter-reset', 'list-item ' + IntToStr(Number - 1));
  end
  else if (Name = AtomLi) and Attribute(Writer, AtomValue, Value) then
  begin
    Val(Trim(Value), Number, Code);
    if Code = 0 then
      AddDeclaration(Writer, 'counter-set', 'list-item ' + IntToStr(Number));
  end;
end;

procedure MapBreakClear(var Writer: THintWriter);
var
  Value: string;
begin
  if not Attribute(Writer, AtomClear, Value) then
    Exit;
  Value := AsciiLowerCase(Trim(Value));
  if (Value = 'left') or (Value = 'right') or (Value = 'both') then
    AddDeclaration(Writer, 'clear', Value)
  else if Value = 'all' then
    AddDeclaration(Writer, 'clear', 'both');
end;

{ An outermost <svg>'s width or height: a length (a bare number is in
  pixels) or a percentage; '' for anything else (auto). }
function SvgDimension(const Value: string): string;
var
  Text: string;
  Number: Double;
  Code: Integer;
begin
  Result := '';
  Text := Trim(Value);
  if Text = '' then
    Exit;
  Val(Text, Number, Code);
  if Code = 0 then
  begin
    if Number >= 0 then
      Result := Text + 'px';
    Exit;
  end;
  if (Pos(';', Text) = 0) and (Pos('{', Text) = 0) and (Pos('}', Text) = 0) and (Text[1] in ['0'..'9', '.']) then
    Result := Text;
end;

function BuildSvgHints(Element: TElement): TCssDeclarationBlock;
var
  Index: Integer;
  Attribute: PAttributeRecord;
  Text, Dimension: string;
  Parent: TElement;
  Outermost: Boolean;
begin
  Result := nil;
  if not Element.HasAttributes then
    Exit;
  Parent := Element.ParentElement;
  Outermost := (NameOfAtom(Element.LocalNameAtom) = 'svg') and ((Parent = nil) or (not Parent.IsSvg));
  Text := '';
  for Index := 0 to Element.AttributeCount - 1 do
  begin
    Attribute := Element.AttributeAt(Index);
    if Attribute^.NamespaceId <> NamespaceNone then
      Continue;
    if Outermost and ((Attribute^.LocalName = AtomWidth) or (Attribute^.LocalName = AtomHeight)) then
    begin
      Dimension := SvgDimension(Attribute^.Value);
      if Dimension <> '' then
        Text := Text + NameOfAtom(Attribute^.LocalName) + ':' + Dimension + ';';
    end
    else
      Text := Text + PresentationDeclaration(NameOfAtom(Attribute^.LocalName), Attribute^.Value);
  end;
  if Text <> '' then
    Result := ParseStyleAttribute(Text);
end;

function BuildPresentationalHints(Element: TElement): TCssDeclarationBlock;
var
  Writer: THintWriter;
  Name: TAtom;
begin
  Result := nil;
  if Element.IsSvg then
    Exit(BuildSvgHints(Element));
  if not Element.IsHtml then
    Exit;
  { Cells take hints from their table's attributes too. }
  if not Element.HasAttributes and not Element.IsHtmlElement(AtomTd) and not Element.IsHtmlElement(AtomTh) then
    Exit;
  Writer.Text := '';
  Writer.Element := Element;
  Name := Element.LocalNameAtom;
  if Name = AtomBody then
    MapBody(Writer)
  else if Name = AtomTable then
    MapTable(Writer)
  else if (Name = AtomTd) or (Name = AtomTh) then
    MapCell(Writer)
  else if (Name = AtomTr) or (Name = AtomThead) or (Name = AtomTbody) or (Name = AtomTfoot) then
  begin
    MapColor(Writer, AtomBgcolor, 'background-color');
    MapBackgroundImage(Writer);
    MapTextAlign(Writer);
    MapVerticalAlign(Writer);
    MapDimension(Writer, AtomHeight, 'height', False);
  end
  else if (Name = AtomCol) or (Name = AtomColgroup) then
    MapDimension(Writer, AtomWidth, 'width', True)
  else if (Name = AtomP) or (Name = AtomDiv) or (Name = AtomH1) or (Name = AtomH2) or (Name = AtomH3) or
    (Name = AtomH4) or (Name = AtomH5) or (Name = AtomH6) or (Name = AtomCaption) or (Name = AtomLegend) then
    MapTextAlign(Writer)
  else if Name = AtomImg then
    MapReplaced(Writer, True)
  else if (Name = AtomObject) or (Name = AtomEmbed) or (Name = AtomIframe) or (Name = AtomVideo) or
    (Name = AtomCanvas) then
  begin
    MapReplaced(Writer, Name = AtomObject);
    if Name = AtomIframe then
      MapFrameBorder(Writer);
  end
  else if Name = AtomHr then
    MapHorizontalRule(Writer)
  else if Name = AtomFont then
    MapFont(Writer)
  else if (Name = AtomUl) or (Name = AtomOl) or (Name = AtomLi) then
  begin
    MapListType(Writer);
    MapListNumbering(Writer, Name);
  end
  else if Name = AtomBr then
    MapBreakClear(Writer)
  else if Name = AtomPre then
    MapDimension(Writer, AtomWidth, 'width', True);
  if Writer.Text <> '' then
    Result := ParseStyleAttribute(Writer.Text);
end;

initialization
  AtomBgcolor := Atomize('bgcolor');
  AtomAlign := Atomize('align');
  AtomValign := Atomize('valign');
  AtomBorder := Atomize('border');
  AtomCellspacing := Atomize('cellspacing');
  AtomCellpadding := Atomize('cellpadding');
  AtomNowrap := Atomize('nowrap');
  AtomHspace := Atomize('hspace');
  AtomVspace := Atomize('vspace');
  AtomNoshade := Atomize('noshade');
  AtomClear := Atomize('clear');
  AtomTextAttribute := Atomize('text');
  AtomBackground := Atomize('background');
  AtomMarginwidth := Atomize('marginwidth');
  AtomMarginheight := Atomize('marginheight');
  AtomLeftmargin := Atomize('leftmargin');
  AtomTopmargin := Atomize('topmargin');
  AtomRightmargin := Atomize('rightmargin');
  AtomBottommargin := Atomize('bottommargin');
end.
