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
  Replaced elements: their intrinsic sizes and used sizes (CSS 2.2
  10.3.2, 10.4, 10.6.2).

  An image gives its pixel size (one image pixel per CSS pixel) and
  ratio; video, canvas, iframe, embed and object without one are 300 by
  150; an img without its image is 0 by 0 (the attributes' width and
  height arrive as presentational hints). The engine-drawn controls
  have the sizes of their fonts: a text field of size characters, a
  textarea of cols by rows, 13 pixel check boxes and radio buttons,
  meters and ranges. Used sizes keep the ratio when only one side is
  given and when min/max sizes clamp an auto size.
}
unit Web.Layout.Replaced;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes, Web.Layout.Context;

procedure UpdateIntrinsicSize(Box: TReplacedBox);
{ The used border box width for a containing width (-1: unknown). }
function ReplacedContentWidth(Box: TReplacedBox; ContainingWidth: Single): Single;
{ Sets the box's edges, width and height. }
procedure LayoutReplaced(Box: TReplacedBox; const Input: TLayoutInput);

implementation

uses
  SysUtils, Web.Atoms, Web.Dom, Css.PropertyIds, Css.Keywords, Web.Layout.Values, Web.Layout.TreeBuilder,
  Web.Text.FontInstances;

function AttributeNumber(Box: TLayoutBox; const Name: string; Default: Integer): Integer;
var
  Text: string;
  Code: Integer;
begin
  Result := Default;
  if (Box.Node = nil) or not Box.Node.IsElement then
    Exit;
  Text := Trim(TElement(Box.Node).GetAttribute(Name));
  if Text = '' then
    Exit;
  Val(Text, Result, Code);
  if (Code <> 0) or (Result <= 0) then
    Result := Default;
end;

procedure UpdateIntrinsicSize(Box: TReplacedBox);
var
  Font: TTextFont;
  CharacterWidth, LineHeight: Single;
begin
  Box.HasIntrinsicWidth := False;
  Box.HasIntrinsicHeight := False;
  Box.IntrinsicRatio := 0;
  Font := TextFontOf(Box.Style);
  CharacterWidth := Font.AdvanceOf(Ord('0'));
  LineHeight := Font.Ascent + Font.Descent;
  case Box.ControlKind of
    ControlImage:
      if Box.Image <> nil then
      begin
        Box.IntrinsicWidth := Box.Image.Width;
        Box.IntrinsicHeight := Box.Image.Height;
        Box.HasIntrinsicWidth := True;
        Box.HasIntrinsicHeight := True;
      end
      else if (Box.Node <> nil) and TElement(Box.Node).IsHtmlElement(AtomImg) then
      begin
        Box.IntrinsicWidth := 0;
        Box.IntrinsicHeight := 0;
        Box.HasIntrinsicWidth := True;
        Box.HasIntrinsicHeight := True;
      end
      else
      begin
        Box.IntrinsicWidth := 300;
        Box.IntrinsicHeight := 150;
        Box.HasIntrinsicWidth := True;
        Box.HasIntrinsicHeight := True;
      end;
    ControlTextField:
      begin
        Box.IntrinsicWidth := AttributeNumber(Box, 'size', 20) * CharacterWidth;
        Box.IntrinsicHeight := LineHeight;
        Box.HasIntrinsicWidth := True;
        Box.HasIntrinsicHeight := True;
      end;
    ControlTextArea:
      begin
        Box.IntrinsicWidth := AttributeNumber(Box, 'cols', 20) * CharacterWidth;
        Box.IntrinsicHeight := AttributeNumber(Box, 'rows', 2) * UsedLineHeight(Box.Style);
        Box.HasIntrinsicWidth := True;
        Box.HasIntrinsicHeight := True;
      end;
    ControlCheckbox, ControlRadio:
      begin
        Box.IntrinsicWidth := 13;
        Box.IntrinsicHeight := 13;
        Box.HasIntrinsicWidth := True;
        Box.HasIntrinsicHeight := True;
      end;
    ControlMeter:
      begin
        Box.IntrinsicWidth := 80;
        Box.IntrinsicHeight := 16;
        Box.HasIntrinsicWidth := True;
        Box.HasIntrinsicHeight := True;
      end;
  end;
  if Box.HasIntrinsicWidth and Box.HasIntrinsicHeight and (Box.IntrinsicHeight > 0) then
    Box.IntrinsicRatio := Box.IntrinsicWidth / Box.IntrinsicHeight;
end;

{ Content box sizes. }
procedure UsedContentSize(Box: TReplacedBox; ContainingWidth, ContainingHeight: Single; out UsedWidth,
  UsedHeight: Single);
var
  HasWidth, HasHeight: Boolean;
  Value, MinValue, MaxValue: Single;
  HorizontalExtra, VerticalExtra: Single;
  IsBorderBox: Boolean;
begin
  UpdateIntrinsicSize(Box);
  IsBorderBox := Box.Style.Keyword(cpBoxSizing) = kwBorderBox;
  HorizontalExtra := 0;
  VerticalExtra := 0;
  if IsBorderBox then
  begin
    HorizontalExtra := HorizontalBorderPadding(Box);
    VerticalExtra := VerticalBorderPadding(Box);
  end;
  HasWidth := TryLength(Box.Style, cpWidth, ContainingWidth, UsedWidth);
  if HasWidth then
    UsedWidth := UsedWidth - HorizontalExtra;
  HasHeight := TryLength(Box.Style, cpHeight, ContainingHeight, UsedHeight);
  if HasHeight then
    UsedHeight := UsedHeight - VerticalExtra;
  if not HasWidth and not HasHeight then
  begin
    if Box.HasIntrinsicWidth then
      UsedWidth := Box.IntrinsicWidth
    else
      UsedWidth := 300;
    if Box.HasIntrinsicHeight then
      UsedHeight := Box.IntrinsicHeight
    else if Box.IntrinsicRatio > 0 then
      UsedHeight := UsedWidth / Box.IntrinsicRatio
    else
      UsedHeight := 150;
  end
  else if not HasWidth then
  begin
    if Box.IntrinsicRatio > 0 then
      UsedWidth := UsedHeight * Box.IntrinsicRatio
    else if Box.HasIntrinsicWidth then
      UsedWidth := Box.IntrinsicWidth
    else
      UsedWidth := 300;
  end
  else if not HasHeight then
  begin
    if Box.IntrinsicRatio > 0 then
      UsedHeight := UsedWidth / Box.IntrinsicRatio
    else if Box.HasIntrinsicHeight then
      UsedHeight := Box.IntrinsicHeight
    else
      UsedHeight := 150;
  end;
  { max/min, keeping the ratio when the size came from it. }
  if TryLength(Box.Style, cpMaxWidth, ContainingWidth, MaxValue) and (UsedWidth > MaxValue - HorizontalExtra) then
  begin
    Value := MaxValue - HorizontalExtra;
    if not HasHeight and (Box.IntrinsicRatio > 0) then
      UsedHeight := Value / Box.IntrinsicRatio;
    UsedWidth := Value;
  end;
  if TryLength(Box.Style, cpMaxHeight, ContainingHeight, MaxValue) and (UsedHeight > MaxValue - VerticalExtra) then
  begin
    Value := MaxValue - VerticalExtra;
    if not HasWidth and (Box.IntrinsicRatio > 0) then
      UsedWidth := Value * Box.IntrinsicRatio;
    UsedHeight := Value;
  end;
  if TryLength(Box.Style, cpMinWidth, ContainingWidth, MinValue) and (UsedWidth < MinValue - HorizontalExtra) then
  begin
    Value := MinValue - HorizontalExtra;
    if not HasHeight and (Box.IntrinsicRatio > 0) then
      UsedHeight := Value / Box.IntrinsicRatio;
    UsedWidth := Value;
  end;
  if TryLength(Box.Style, cpMinHeight, ContainingHeight, MinValue) and (UsedHeight < MinValue - VerticalExtra) then
  begin
    Value := MinValue - VerticalExtra;
    if not HasWidth and (Box.IntrinsicRatio > 0) then
      UsedWidth := Value * Box.IntrinsicRatio;
    UsedHeight := Value;
  end;
  if UsedWidth < 0 then
    UsedWidth := 0;
  if UsedHeight < 0 then
    UsedHeight := 0;
end;

function ReplacedContentWidth(Box: TReplacedBox; ContainingWidth: Single): Single;
var
  UsedWidth, UsedHeight: Single;
begin
  ResolveBoxEdges(Box, ContainingWidth);
  UsedContentSize(Box, ContainingWidth, Indefinite, UsedWidth, UsedHeight);
  Result := UsedWidth + HorizontalBorderPadding(Box);
end;

procedure LayoutReplaced(Box: TReplacedBox; const Input: TLayoutInput);
var
  UsedWidth, UsedHeight: Single;
begin
  ResolveBoxEdges(Box, Input.AvailableWidth);
  UsedContentSize(Box, Input.AvailableWidth, Input.ContainingHeight, UsedWidth, UsedHeight);
  Box.Width := UsedWidth + HorizontalBorderPadding(Box);
  Box.Height := UsedHeight + VerticalBorderPadding(Box);
  if Input.WidthMode = wmFixed then
    Box.Width := Input.FixedWidth;
  if Input.FixedHeight >= 0 then
    Box.Height := Input.FixedHeight;
end;

end.
