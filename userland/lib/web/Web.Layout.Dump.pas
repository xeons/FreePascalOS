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
  The layout tree as text, for tests and debugging (like the layout
  tree dumps of WPT's layout tests): one line per box with its kind,
  element, border box in document coordinates and size, then its line
  boxes and their fragments (text with its content). Numbers are CSS
  pixels with at most two decimals.
}
unit Web.Layout.Dump;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes;

function DumpLayoutTree(Root: TLayoutBox): string;
{ A number as the dump writes it. }
function FormatLayoutNumber(Value: Single): string;

implementation

uses
  SysUtils, Web.Dom;

function FormatLayoutNumber(Value: Single): string;
var
  Rounded: Int64;
  Settings: TFormatSettings;
begin
  Rounded := Round(Value * 100);
  Settings := DefaultFormatSettings;
  Settings.DecimalSeparator := '.';
  Result := FormatFloat('0.##', Rounded / 100, Settings);
  if Result = '-0' then
    Result := '0';
end;

function KindName(Box: TLayoutBox): string;
begin
  case Box.Kind of
    bkBlock:
      if bfInlineLevel in Box.Flags then
        Result := 'inline-block'
      else
        Result := 'block';
    bkInline: Result := 'inline';
    bkText: Result := 'text';
    bkLineBreak: Result := 'br';
    bkReplaced: Result := 'replaced';
    bkFlex: Result := 'flex';
    bkGrid: Result := 'grid';
    bkTable: Result := 'table';
    bkTableRowGroup: Result := 'row-group';
    bkTableRow: Result := 'row';
    bkTableCell: Result := 'cell';
    bkTableColumn: Result := 'column';
    bkTableColumnGroup: Result := 'column-group';
    bkTableCaption: Result := 'caption';
    bkViewport: Result := 'viewport';
  else
    Result := '?';
  end;
end;

function NameOf(Box: TLayoutBox): string;
begin
  if bfBefore in Box.Flags then
    Result := '::before'
  else if bfAfter in Box.Flags then
    Result := '::after'
  else if bfMarker in Box.Flags then
    Result := '::marker'
  else if bfAnonymous in Box.Flags then
    Result := '(anonymous)'
  else if (Box.Node <> nil) and Box.Node.IsElement then
    Result := '<' + TElement(Box.Node).LocalName + '>'
  else
    Result := '';
end;

function Escaped(const Text: string): string;
begin
  Result := StringReplace(Text, '"', '\"', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
end;

procedure DumpBox(Box: TLayoutBox; OffsetX, OffsetY: Single; const Indent: string; var Output: string); forward;

{ The boxes inside an inline box (atomic inlines, floats ...) are
  positioned relative to the block container. }
procedure DumpInlineChildren(Box: TLayoutBox; OffsetX, OffsetY: Single; const Indent: string; var Output: string);
var
  Child: TLayoutBox;
begin
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if Child.Kind = bkInline then
      DumpInlineChildren(Child, OffsetX, OffsetY, Indent, Output)
    else if Child.Kind <> bkText then
      DumpBox(Child, OffsetX, OffsetY, Indent, Output);
    Child := Child.NextSibling;
  end;
end;

procedure DumpBox(Box: TLayoutBox; OffsetX, OffsetY: Single; const Indent: string; var Output: string);
var
  X, Y: Single;
  Child: TLayoutBox;
  Line, Index: Integer;
  Fragment: PLineFragment;
  Text, Name: string;
begin
  if Box.Kind = bkInline then
  begin
    X := OffsetX;
    Y := OffsetY;
  end
  else
  begin
    X := OffsetX + Box.X;
    Y := OffsetY + Box.Y;
  end;
  if not (Box.Kind in [bkText, bkInline]) then
  begin
    Name := NameOf(Box);
    Output := Output + Indent + KindName(Box);
    if Name <> '' then
      Output := Output + ' ' + Name;
    Output := Output + ' at (' + FormatLayoutNumber(X + Box.RelativeX) + ',' + FormatLayoutNumber(Y + Box.RelativeY) +
      ') size ' + FormatLayoutNumber(Box.Width) + 'x' + FormatLayoutNumber(Box.Height);
    if Box.IsFloating then
      Output := Output + ' float';
    if bfAbsolute in Box.Flags then
      Output := Output + ' positioned';
    if (bfScrollContainer in Box.Flags) and (Box.Kind <> bkViewport) then
      Output := Output + ' scroll ' + FormatLayoutNumber(Box.ScrollWidth) + 'x' + FormatLayoutNumber(Box.ScrollHeight);
    Output := Output + LineEnding;
  end
  else if Box.Kind = bkInline then
  begin
    Name := NameOf(Box);
    Output := Output + Indent + 'inline';
    if Name <> '' then
      Output := Output + ' ' + Name;
    Output := Output + LineEnding;
  end;
  if (bfChildrenInline in Box.Flags) and (Box.Inline <> nil) then
    for Line := 0 to Box.Inline.LineCount - 1 do
    begin
      Output := Output + Indent + '  line ' + IntToStr(Line) + ' at y ' +
        FormatLayoutNumber(Y + Box.ContentTop + Box.Inline.Lines[Line].Top) + ' height ' +
        FormatLayoutNumber(Box.Inline.Lines[Line].Height) + ' baseline ' +
        FormatLayoutNumber(Y + Box.Inline.Lines[Line].Baseline) + LineEnding;
      for Index := Box.Inline.Lines[Line].FirstFragment to
        Box.Inline.Lines[Line].FirstFragment + Box.Inline.Lines[Line].FragmentCount - 1 do
      begin
        Fragment := @Box.Inline.Fragments[Index];
        case Fragment^.Kind of
          fkText:
            begin
              Text := Copy(TTextBox(Fragment^.Box).Text, Fragment^.TextStart, Fragment^.TextLength);
              Output := Output + Indent + '    text "' + Escaped(Text) + '"';
            end;
          fkInlineBox:
            Output := Output + Indent + '    inline-box ' + NameOf(TLayoutBox(Fragment^.Box));
          fkAtomic:
            Output := Output + Indent + '    atomic ' + NameOf(TLayoutBox(Fragment^.Box));
          fkLineBreak:
            Output := Output + Indent + '    br';
        end;
        Output := Output + ' at (' + FormatLayoutNumber(X + Fragment^.X) + ',' + FormatLayoutNumber(Y + Fragment^.Y) +
          ') size ' + FormatLayoutNumber(Fragment^.Width) + 'x' + FormatLayoutNumber(Fragment^.Height) + LineEnding;
      end;
    end;
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if Child.Kind = bkInline then
      DumpInlineChildren(Child, X + Box.RelativeX, Y + Box.RelativeY, Indent + '  ', Output)
    else if Child.Kind <> bkText then
      DumpBox(Child, X + Box.RelativeX, Y + Box.RelativeY, Indent + '  ', Output);
    Child := Child.NextSibling;
  end;
end;

function DumpLayoutTree(Root: TLayoutBox): string;
begin
  Result := '';
  if Root <> nil then
    DumpBox(Root, 0, 0, '', Result);
end;

end.
