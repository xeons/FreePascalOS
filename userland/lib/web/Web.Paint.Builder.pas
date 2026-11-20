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
  Building the display list from the box tree, in the painting order of
  CSS 2.2 Appendix E.

  Each stacking context (the root, positioned boxes with a z-index,
  boxes with opacity, transforms, filters, isolation, fixed and sticky
  boxes; positioned boxes with z-index auto, floats and atomic inlines
  are painted as if they were one) paints: its own background, borders
  and shadows; the stacking contexts below it with negative z-index;
  the backgrounds of its in-flow blocks in tree order; its floats; its
  inline content (inline boxes' backgrounds and borders, text with its
  decorations, atomic inlines, replaced content); positioned
  descendants with z-index auto or 0 in tree order; then those with
  positive z-index; and outlines. Overflow clips become clip pairs (with
  the scroll offset of scroll containers applied to their contents),
  opacity becomes a group.

  The root element's background (or the body's, when the root has
  none) paints the whole canvas, as CSS Backgrounds says.
}
unit Web.Paint.Builder;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes, Web.Layout.Resources, Web.Paint.DisplayList;

{ Fills List from the laid out tree under Root (the viewport box). }
procedure BuildDisplayList(Root: TLayoutBox; Resources: TDocumentResources; List: TDisplayList);

implementation

uses
  Math, SysUtils, Web.Dom, Web.Atoms, Drawing.Colors, Drawing.Rasterizer, Drawing.SmoothRoundedRectangles,
  Css.ComputedStyle, Css.ComputedValues, Css.Colors, Css.Values, Css.Keywords, Css.PropertyIds,
  Web.Layout.Values, Web.Layout.TreeBuilder, Web.Text.FontInstances, Image.Model;

type
  TClipEntry = record
    X, Y, Width, Height: Single;
    Radii: Integer;
  end;
  TClipChain = array of TClipEntry;

  TLayer = record
    Box: TLayoutBox;
    X, Y: Single;
    Z: Integer;
    Order: Integer;
    Clips: TClipChain;
  end;
  TLayerArray = array of TLayer;

  TPhase = (phBlocks, phFloats, phInline);

  TBuilder = record
    List: TDisplayList;
    Resources: TDocumentResources;
    CanvasBox: TLayoutBox;
    Order: Integer;
  end;

procedure PaintLayer(var Builder: TBuilder; Box: TLayoutBox; X, Y: Single); forward;

function ToColor(const Color: TCssColor): TColor;
var
  Rgba: TCssRgba8;
begin
  Rgba := ColorToRgba8(Color);
  Result := ArgbColor(Rgba.Alpha, Rgba.Red, Rgba.Green, Rgba.Blue);
end;

function StyleColor(Box: TLayoutBox; Id: TCssPropertyId): TColor;
begin
  Result := ToColor(Box.Style.ColorOf(Id));
end;

function IsVisible(Box: TLayoutBox): Boolean;
begin
  Result := Box.Style.Keyword(cpVisibility) = kwVisible;
end;

function IsLayer(Box: TLayoutBox): Boolean;
begin
  Result := Box.IsPositioned or MakesStackingContext(Box);
end;

{ A corner radius from its computed value (percentages of the box). }
procedure CornerRadius(Box: TLayoutBox; Id: TCssPropertyId; out Radius: TPrecisePoint);
var
  Value: PCssComputedValue;

  function Part(Item: TCssValue; Basis: Single): Single;
  begin
    if Item.Kind = vkPercentage then
      Result := Item.Number * Basis / 100
    else
      Result := Item.Number;
  end;

begin
  Value := Box.Style.Value(Id);
  Radius.X := 0;
  Radius.Y := 0;
  case Value^.Kind of
    cvLength:
      begin
        Radius.X := Value^.Number;
        Radius.Y := Value^.Number;
      end;
    cvPercentage:
      begin
        Radius.X := Value^.Percent * Box.Width / 100;
        Radius.Y := Value^.Percent * Box.Height / 100;
      end;
    cvLengthPercentage, cvCalc:
      begin
        Radius.X := ResolveComputed(Value^, Box.Width);
        Radius.Y := ResolveComputed(Value^, Box.Height);
      end;
    cvValue:
      if (Value^.Data <> nil) and (Value^.Data.Kind = vkList) and (Value^.Data.Count >= 2) then
      begin
        Radius.X := Part(Value^.Data.Items[0], Box.Width);
        Radius.Y := Part(Value^.Data.Items[1], Box.Height);
      end;
  end;
end;

{ The border box radii; False when all are 0. }
function BorderRadii(Box: TLayoutBox; out Radii: TCornerRadii): Boolean;
var
  Corner: Integer;
begin
  CornerRadius(Box, cpBorderTopLeftRadius, Radii[0]);
  CornerRadius(Box, cpBorderTopRightRadius, Radii[1]);
  CornerRadius(Box, cpBorderBottomRightRadius, Radii[2]);
  CornerRadius(Box, cpBorderBottomLeftRadius, Radii[3]);
  Result := False;
  for Corner := 0 to 3 do
    if (Radii[Corner].X > 0) and (Radii[Corner].Y > 0) then
      Result := True;
  if Result then
    FitCornerRadii(Radii, Box.Width, Box.Height);
end;

{ The radii shrunk by insets (for the padding and content boxes). }
function InsetRadii(const Radii: TCornerRadii; Top, Right, Bottom, Left: Single): TCornerRadii;
begin
  Result[0].X := Max(0, Radii[0].X - Left);
  Result[0].Y := Max(0, Radii[0].Y - Top);
  Result[1].X := Max(0, Radii[1].X - Right);
  Result[1].Y := Max(0, Radii[1].Y - Top);
  Result[2].X := Max(0, Radii[2].X - Right);
  Result[2].Y := Max(0, Radii[2].Y - Bottom);
  Result[3].X := Max(0, Radii[3].X - Left);
  Result[3].Y := Max(0, Radii[3].Y - Bottom);
end;

{ ---- backgrounds ---- }

function LayerItem(List: PCssComputedValue; Index: Integer): TCssValue;
begin
  Result := nil;
  if (List^.Kind <> cvValue) or (List^.Data = nil) then
    Exit;
  if List^.Data.Kind = vkList then
  begin
    if List^.Data.Count = 0 then
      Exit;
    Result := List^.Data.Items[Index mod List^.Data.Count];
  end
  else
    Result := List^.Data;
end;

function LayerKeyword(Style: TCssComputedStyle; Id: TCssPropertyId; Index: Integer; Default: TCssKeyword): TCssKeyword;
var
  Item: TCssValue;
  Value: PCssComputedValue;
begin
  Value := Style.Value(Id);
  if Value^.Kind = cvKeyword then
    Exit(TCssKeyword(Value^.Keyword));
  Item := LayerItem(Value, Index);
  if (Item <> nil) and (Item.Kind = vkKeyword) then
    Result := Item.Keyword
  else
    Result := Default;
end;

function PositionPart(Item: TCssValue; Free: Single): Single;
var
  Index: Integer;
  Keyword: TCssKeyword;
  Offset: Single;
begin
  Result := 0;
  if Item = nil then
    Exit;
  case Item.Kind of
    vkPercentage: Result := Item.Number * Free / 100;
    vkDimension, vkNumber: Result := Item.Number;
    vkKeyword:
      case Item.Keyword of
        kwCenter: Result := Free / 2;
        kwRight, kwBottom: Result := Free;
      end;
    vkCalc: Result := 0;
    vkList:
      begin
        { "right 10px" }
        Keyword := kwLeft;
        Offset := 0;
        for Index := 0 to Item.Count - 1 do
          if Item.Items[Index].Kind = vkKeyword then
            Keyword := Item.Items[Index].Keyword
          else if Item.Items[Index].Kind = vkPercentage then
            Offset := Item.Items[Index].Number * Free / 100
          else
            Offset := Item.Items[Index].Number;
        if KeywordIn(Keyword, [kwRight, kwBottom]) then
          Result := Free - Offset
        else if Keyword = kwCenter then
          Result := Free / 2 + Offset
        else
          Result := Offset;
      end;
  end;
end;

procedure TileSize(Style: TCssComputedStyle; Layer: Integer; AreaWidth, AreaHeight, ImageWidth,
  ImageHeight: Single; out Width, Height: Single);
var
  Item, First, Second: TCssValue;
  Ratio: Single;

  function Dimension(Value: TCssValue; Basis: Single; out Size: Single): Boolean;
  begin
    Result := False;
    Size := 0;
    if Value = nil then
      Exit;
    if Value.Kind = vkPercentage then
    begin
      Size := Value.Number * Basis / 100;
      Result := True;
    end
    else if Value.Kind in [vkDimension, vkNumber] then
    begin
      Size := Value.Number;
      Result := True;
    end;
  end;

var
  HasWidth, HasHeight: Boolean;
begin
  Width := ImageWidth;
  Height := ImageHeight;
  if ImageHeight > 0 then
    Ratio := ImageWidth / ImageHeight
  else
    Ratio := 0;
  Item := LayerItem(Style.Value(cpBackgroundSize), Layer);
  if Item = nil then
    Exit;
  if Item.Kind = vkKeyword then
  begin
    if (KeywordIn(Item.Keyword, [kwCover, kwContain])) and (Ratio > 0) then
    begin
      Width := AreaWidth;
      Height := Width / Ratio;
      if (Item.Keyword = kwCover) and (Height < AreaHeight) or (Item.Keyword = kwContain) and (Height > AreaHeight) then
      begin
        Height := AreaHeight;
        Width := Height * Ratio;
      end;
    end;
    Exit;
  end;
  First := Item;
  Second := nil;
  if (Item.Kind = vkList) and (Item.Count >= 1) then
  begin
    First := Item.Items[0];
    if Item.Count >= 2 then
      Second := Item.Items[1];
  end;
  HasWidth := Dimension(First, AreaWidth, Width);
  HasHeight := Dimension(Second, AreaHeight, Height);
  if HasWidth and not HasHeight then
  begin
    if Ratio > 0 then
      Height := Width / Ratio
    else
      Height := AreaHeight;
  end
  else if HasHeight and not HasWidth then
  begin
    if Ratio > 0 then
      Width := Height * Ratio
    else
      Width := AreaWidth;
  end
  else if not HasWidth and not HasHeight then
  begin
    Width := ImageWidth;
    Height := ImageHeight;
  end;
end;

procedure PaintBackgroundLayers(var Builder: TBuilder; Box: TLayoutBox; Style: TCssComputedStyle;
  X, Y, Width, Height: Single; const Outer: TCornerRadii; HasRadii: Boolean);
var
  Images: PCssComputedValue;
  Count, Layer: Integer;
  Item: TCssValue;
  Clip, Origin: TCssKeyword;
  AreaX, AreaY, AreaWidth, AreaHeight, ClipX, ClipY, ClipWidth, ClipHeight: Single;
  TileWidth, TileHeight, PositionX, PositionY: Single;
  Repeating: TCssKeyword;
  ImageRun: TImageRun;
  GradientRun: TGradientRun;
  Image: TImage;
  Entry: PDisplayItem;
  Radii: TCornerRadii;
  Color: TColor;
begin
  { The color, under every image, clipped by the last layer's clip. }
  Clip := LayerKeyword(Style, cpBackgroundClip, 0, kwBorderBox);
  ClipX := X;
  ClipY := Y;
  ClipWidth := Width;
  ClipHeight := Height;
  Radii := Outer;
  if KeywordIn(Clip, [kwPaddingBox, kwContentBox]) then
  begin
    ClipX := X + Box.Border[sideLeft];
    ClipY := Y + Box.Border[sideTop];
    ClipWidth := Width - Box.Border[sideLeft] - Box.Border[sideRight];
    ClipHeight := Height - Box.Border[sideTop] - Box.Border[sideBottom];
    Radii := InsetRadii(Outer, Box.Border[sideTop], Box.Border[sideRight], Box.Border[sideBottom],
      Box.Border[sideLeft]);
    if Clip = kwContentBox then
    begin
      ClipX := ClipX + Box.Padding[sideLeft];
      ClipY := ClipY + Box.Padding[sideTop];
      ClipWidth := ClipWidth - Box.Padding[sideLeft] - Box.Padding[sideRight];
      ClipHeight := ClipHeight - Box.Padding[sideTop] - Box.Padding[sideBottom];
    end;
  end;
  Color := ToColor(Style.ColorOf(cpBackgroundColor));
  if AlphaOf(Color) > 0 then
  begin
    Entry := Builder.List.Add(diRectangle, ClipX, ClipY, ClipWidth, ClipHeight, Box);
    Entry^.Color := Color;
    if HasRadii then
      Entry^.Index := Builder.List.AddRadii(Radii);
  end;
  Images := Style.Value(cpBackgroundImage);
  if (Images^.Kind <> cvValue) or (Images^.Data = nil) then
    Exit;
  if Images^.Data.Kind = vkList then
    Count := Images^.Data.Count
  else
    Count := 1;
  if HasRadii then
  begin
    Entry := Builder.List.Add(diPushClip, ClipX, ClipY, ClipWidth, ClipHeight, Box);
    Entry^.Index := Builder.List.AddRadii(Radii);
  end;
  for Layer := Count - 1 downto 0 do
  begin
    Item := LayerItem(Images, Layer);
    if (Item = nil) or (Item.Kind = vkKeyword) then
      Continue;
    Origin := LayerKeyword(Style, cpBackgroundOrigin, Layer, kwPaddingBox);
    AreaX := X;
    AreaY := Y;
    AreaWidth := Width;
    AreaHeight := Height;
    if KeywordIn(Origin, [kwPaddingBox, kwContentBox]) then
    begin
      AreaX := AreaX + Box.Border[sideLeft];
      AreaY := AreaY + Box.Border[sideTop];
      AreaWidth := AreaWidth - Box.Border[sideLeft] - Box.Border[sideRight];
      AreaHeight := AreaHeight - Box.Border[sideTop] - Box.Border[sideBottom];
      if Origin = kwContentBox then
      begin
        AreaX := AreaX + Box.Padding[sideLeft];
        AreaY := AreaY + Box.Padding[sideTop];
        AreaWidth := AreaWidth - Box.Padding[sideLeft] - Box.Padding[sideRight];
        AreaHeight := AreaHeight - Box.Padding[sideTop] - Box.Padding[sideBottom];
      end;
    end;
    Repeating := LayerKeyword(Style, cpBackgroundRepeat, Layer, kwRepeat);
    if Item.Kind = vkUrl then
    begin
      Image := nil;
      if Builder.Resources <> nil then
        Image := Builder.Resources.UrlImage(Item.Text, '');
      if Image = nil then
        Continue;
      TileSize(Style, Layer, AreaWidth, AreaHeight, Image.Width, Image.Height, TileWidth, TileHeight);
      PositionX := PositionPart(LayerItem(Style.Value(cpBackgroundPositionX), Layer), AreaWidth - TileWidth);
      PositionY := PositionPart(LayerItem(Style.Value(cpBackgroundPositionY), Layer), AreaHeight - TileHeight);
      ImageRun.Image := Image;
      ImageRun.TileX := AreaX + PositionX;
      ImageRun.TileY := AreaY + PositionY;
      ImageRun.TileWidth := TileWidth;
      ImageRun.TileHeight := TileHeight;
      ImageRun.RepeatX := KeywordIn(Repeating, [kwRepeat, kwRepeatX, kwSpace, kwRound]);
      ImageRun.RepeatY := KeywordIn(Repeating, [kwRepeat, kwRepeatY, kwSpace, kwRound]);
      ImageRun.Pixelated := KeywordIn(Style.Keyword(cpImageRendering), [kwPixelated, kwCrispEdges]);
      Entry := Builder.List.Add(diImage, ClipX, ClipY, ClipWidth, ClipHeight, Box);
      Entry^.Index := Builder.List.AddImage(ImageRun);
    end
    else if Item.Kind = vkFunction then
    begin
      TileSize(Style, Layer, AreaWidth, AreaHeight, AreaWidth, AreaHeight, TileWidth, TileHeight);
      PositionX := PositionPart(LayerItem(Style.Value(cpBackgroundPositionX), Layer), AreaWidth - TileWidth);
      PositionY := PositionPart(LayerItem(Style.Value(cpBackgroundPositionY), Layer), AreaHeight - TileHeight);
      GradientRun.Gradient := Item;
      GradientRun.CurrentColor := ToColor(Style.Color);
      GradientRun.BoxX := AreaX + PositionX;
      GradientRun.BoxY := AreaY + PositionY;
      GradientRun.BoxWidth := TileWidth;
      GradientRun.BoxHeight := TileHeight;
      if (TileWidth >= AreaWidth - 0.5) and (TileHeight >= AreaHeight - 0.5) or (Repeating = kwNoRepeat) then
        Entry := Builder.List.Add(diGradient, Max(ClipX, GradientRun.BoxX), Max(ClipY, GradientRun.BoxY),
          Min(ClipX + ClipWidth, GradientRun.BoxX + TileWidth) - Max(ClipX, GradientRun.BoxX),
          Min(ClipY + ClipHeight, GradientRun.BoxY + TileHeight) - Max(ClipY, GradientRun.BoxY), Box)
      else
        Entry := Builder.List.Add(diGradient, ClipX, ClipY, ClipWidth, ClipHeight, Box);
      Entry^.Value := Ord(Repeating <> kwNoRepeat);
      Entry^.Index := Builder.List.AddGradient(GradientRun);
    end;
  end;
  if HasRadii then
    Builder.List.Add(diPopClip, 0, 0, 0, 0, Box);
end;

procedure PaintShadows(var Builder: TBuilder; Box: TLayoutBox; X, Y: Single; Inset: Boolean; const Radii: TCornerRadii;
  HasRadii: Boolean);
var
  Shadows: PCssComputedValue;
  Index, Part: Integer;
  Shadow, Item: TCssValue;
  Run: TShadowRun;
  Color: TColor;
  Lengths: array[0..3] of Single;
  LengthCount: Integer;
  IsInset: Boolean;
  Entry: PDisplayItem;
  Extent: Single;
begin
  Shadows := Box.Style.Value(cpBoxShadow);
  if (Shadows^.Kind <> cvValue) or (Shadows^.Data = nil) then
    Exit;
  { The first shadow is on top: paint from the last. }
  for Index := Shadows^.Data.Count - 1 downto 0 do
  begin
    if Shadows^.Data.Kind = vkList then
      Shadow := Shadows^.Data.Items[Index]
    else
      Shadow := Shadows^.Data;
    Color := ToColor(Box.Style.Color);
    LengthCount := 0;
    IsInset := False;
    FillChar(Lengths, SizeOf(Lengths), 0);
    for Part := 0 to Shadow.Count - 1 do
    begin
      Item := Shadow.Items[Part];
      case Item.Kind of
        vkColor: Color := ToColor(Item.Color);
        vkDimension, vkNumber:
          if LengthCount < 4 then
          begin
            Lengths[LengthCount] := Item.Number;
            Inc(LengthCount);
          end;
        vkKeyword:
          if Item.Keyword = kwInset then
            IsInset := True;
      end;
    end;
    if IsInset <> Inset then
      Continue;
    Run.OffsetX := Lengths[0];
    Run.OffsetY := Lengths[1];
    Run.Blur := Max(0, Lengths[2]);
    Run.Spread := Lengths[3];
    Run.Inset := IsInset;
    Run.BoxX := X;
    Run.BoxY := Y;
    Run.BoxWidth := Box.Width;
    Run.BoxHeight := Box.Height;
    Run.Radii := -1;
    if HasRadii then
      Run.Radii := Builder.List.AddRadii(Radii);
    if IsInset then
      Entry := Builder.List.Add(diShadow, X, Y, Box.Width, Box.Height, Box)
    else
    begin
      Extent := Run.Blur + Abs(Run.Spread);
      Entry := Builder.List.Add(diShadow, X + Run.OffsetX - Extent, Y + Run.OffsetY - Extent,
        Box.Width + 2 * Extent, Box.Height + 2 * Extent, Box);
    end;
    Entry^.Color := Color;
    Entry^.Index := Builder.List.AddShadow(Run);
  end;
end;

function SideStyle(Box: TLayoutBox; Id: TCssPropertyId): TCssKeyword;
begin
  Result := Box.Style.Keyword(Id);
end;

procedure PaintBorders(var Builder: TBuilder; Box: TLayoutBox; X, Y: Single; const Radii: TCornerRadii;
  HasRadii: Boolean);
var
  Sides: TBorderSides;
  Entry: PDisplayItem;
  Any: Boolean;
  Side: Integer;
begin
  Sides.Widths[0] := Box.Border[sideTop];
  Sides.Widths[1] := Box.Border[sideRight];
  Sides.Widths[2] := Box.Border[sideBottom];
  Sides.Widths[3] := Box.Border[sideLeft];
  Sides.Colors[0] := StyleColor(Box, cpBorderTopColor);
  Sides.Colors[1] := StyleColor(Box, cpBorderRightColor);
  Sides.Colors[2] := StyleColor(Box, cpBorderBottomColor);
  Sides.Colors[3] := StyleColor(Box, cpBorderLeftColor);
  Sides.Styles[0] := SideStyle(Box, cpBorderTopStyle);
  Sides.Styles[1] := SideStyle(Box, cpBorderRightStyle);
  Sides.Styles[2] := SideStyle(Box, cpBorderBottomStyle);
  Sides.Styles[3] := SideStyle(Box, cpBorderLeftStyle);
  Any := False;
  for Side := 0 to 3 do
    if (Sides.Widths[Side] > 0) and (AlphaOf(Sides.Colors[Side]) > 0) and
       not KeywordIn(Sides.Styles[Side], [kwNone, kwHidden]) then
      Any := True;
  if not Any then
    Exit;
  Sides.Radii := -1;
  if HasRadii then
    Sides.Radii := Builder.List.AddRadii(Radii);
  Entry := Builder.List.Add(diBorder, X, Y, Box.Width, Box.Height, Box);
  Entry^.Index := Builder.List.AddBorder(Sides);
end;

procedure PaintOutline(var Builder: TBuilder; Box: TLayoutBox; X, Y: Single);
var
  Width, Offset: Single;
  Style: TCssKeyword;
  Sides: TBorderSides;
  Side: Integer;
  Entry: PDisplayItem;
begin
  Style := Box.Style.Keyword(cpOutlineStyle);
  Width := Box.Style.Value(cpOutlineWidth)^.Number;
  if (Width <= 0) or KeywordIn(Style, [kwNone, kwHidden]) then
    Exit;
  if Style = kwAuto then
    Style := kwSolid;
  Offset := LengthOf(Box.Style, cpOutlineOffset, 0);
  for Side := 0 to 3 do
  begin
    Sides.Widths[Side] := Width;
    Sides.Colors[Side] := StyleColor(Box, cpOutlineColor);
    Sides.Styles[Side] := Style;
  end;
  Sides.Radii := -1;
  Entry := Builder.List.Add(diBorder, X - Offset - Width, Y - Offset - Width, Box.Width + 2 * (Offset + Width),
    Box.Height + 2 * (Offset + Width), Box);
  Entry^.Index := Builder.List.AddBorder(Sides);
end;

procedure PaintReplacedContent(var Builder: TBuilder; Box: TReplacedBox; X, Y: Single);
var
  ContentX, ContentY, ContentWidth, ContentHeight, DrawWidth, DrawHeight, Ratio: Single;
  Fit: TCssKeyword;
  Run: TImageRun;
  Entry: PDisplayItem;
  NeedsClip: Boolean;
  Text: string;
  Color: TColor;
begin
  ContentX := X + Box.ContentLeft;
  ContentY := Y + Box.ContentTop;
  ContentWidth := Box.ContentWidth;
  ContentHeight := Box.ContentHeight;
  if Box.ControlKind <> ControlImage then
  begin
    Entry := Builder.List.Add(diControl, ContentX, ContentY, ContentWidth, ContentHeight, Box);
    Entry^.Index := Box.ControlKind;
    Entry^.Color := ToColor(Box.Style.Color);
    if (Box.Node <> nil) and Box.Node.IsElement and TElement(Box.Node).HasAttributeAtom(AtomChecked) then
      Entry^.Value := 1;
    if (Box.ControlKind in [ControlTextField, ControlTextArea]) and (Box.Node <> nil) and Box.Node.IsElement then
    begin
      if Box.ControlKind = ControlTextArea then
        Text := DescendantTextContent(Box.Node)
      else if TElement(Box.Node).HasAttributeAtom(AtomValue) then
        Text := TElement(Box.Node).AttributeValueOf(AtomValue)
      else
        Text := '';
      Color := ToColor(Box.Style.Color);
      if (Text = '') and TElement(Box.Node).HasAttributeAtom(AtomPlaceholder) then
      begin
        Text := TElement(Box.Node).AttributeValueOf(AtomPlaceholder);
        Color := FadeColor(Color, 128);
      end;
      if Text <> '' then
      begin
        Entry := Builder.List.Add(diControlText, ContentX, ContentY, ContentWidth, ContentHeight, Box);
        Entry^.Index := Builder.List.AddString(Text);
        Entry^.Color := Color;
      end;
    end;
    Exit;
  end;
  if (Box.Image = nil) or (Box.Image.Width = 0) or (Box.Image.Height = 0) then
    Exit;
  Fit := Box.Style.Keyword(cpObjectFit);
  DrawWidth := ContentWidth;
  DrawHeight := ContentHeight;
  Ratio := Box.Image.Width / Box.Image.Height;
  case Fit of
    kwContain, kwCover, kwScaleDown:
      begin
        DrawWidth := ContentWidth;
        DrawHeight := DrawWidth / Ratio;
        if ((Fit <> kwCover) and (DrawHeight > ContentHeight)) or ((Fit = kwCover) and (DrawHeight < ContentHeight)) then
        begin
          DrawHeight := ContentHeight;
          DrawWidth := DrawHeight * Ratio;
        end;
        if (Fit = kwScaleDown) and (DrawWidth > Box.Image.Width) then
        begin
          DrawWidth := Box.Image.Width;
          DrawHeight := Box.Image.Height;
        end;
      end;
    kwNone:
      begin
        DrawWidth := Box.Image.Width;
        DrawHeight := Box.Image.Height;
      end;
  end;
  Run.Image := Box.Image;
  Run.TileWidth := DrawWidth;
  Run.TileHeight := DrawHeight;
  Run.TileX := ContentX + PositionPart(LayerItem(Box.Style.Value(cpObjectPosition), 0), ContentWidth - DrawWidth);
  Run.TileY := ContentY + (ContentHeight - DrawHeight) / 2;
  if Box.Style.Value(cpObjectPosition)^.Kind = cvKeyword then
    Run.TileX := ContentX + (ContentWidth - DrawWidth) / 2;
  Run.RepeatX := False;
  Run.RepeatY := False;
  Run.Pixelated := KeywordIn(Box.Style.Keyword(cpImageRendering), [kwPixelated, kwCrispEdges]);
  NeedsClip := (DrawWidth > ContentWidth + 0.5) or (DrawHeight > ContentHeight + 0.5);
  Entry := Builder.List.Add(diImage, Max(ContentX, Run.TileX), Max(ContentY, Run.TileY),
    Min(ContentWidth, DrawWidth), Min(ContentHeight, DrawHeight), Box);
  Entry^.Index := Builder.List.AddImage(Run);
  if NeedsClip then;
end;

{ Background, shadows and borders of a box at (X, Y). }
procedure PaintDecorations(var Builder: TBuilder; Box: TLayoutBox; X, Y: Single);
var
  Radii: TCornerRadii;
  HasRadii: Boolean;
begin
  if (Box.Kind in [bkViewport, bkText, bkTableColumn, bkTableColumnGroup]) or not IsVisible(Box) then
    Exit;
  if Box.Style.Keyword(cpPointerEvents) <> kwNone then
    Builder.List.Add(diHitArea, X, Y, Box.Width, Box.Height, Box);
  HasRadii := BorderRadii(Box, Radii);
  PaintShadows(Builder, Box, X, Y, False, Radii, HasRadii);
  if Box <> Builder.CanvasBox then
    PaintBackgroundLayers(Builder, Box, Box.Style, X, Y, Box.Width, Box.Height, Radii, HasRadii);
  PaintShadows(Builder, Box, X, Y, True, Radii, HasRadii);
  PaintBorders(Builder, Box, X, Y, Radii, HasRadii);
  if Box.Kind = bkReplaced then
    PaintReplacedContent(Builder, TReplacedBox(Box), X, Y);
end;

{ ---- text ---- }

procedure AddDecorationLines(var Builder: TBuilder; Text: TTextBox; const Fragment: TLineFragment; X, Y: Single;
  Font: TTextFont);
var
  Owner: TLayoutBox;
  Lines: PCssComputedValue;
  Thickness, Position: Single;
  Color: TColor;
  Entry: PDisplayItem;

  procedure AddLine(Top: Single);
  begin
    Entry := Builder.List.Add(diRectangle, X + Fragment.X, Top, Fragment.Width, Thickness, Text);
    Entry^.Color := Color;
  end;

  function HasLine(Value: PCssComputedValue; Keyword: TCssKeyword): Boolean;
  var
    Index: Integer;
  begin
    if Value^.Kind = cvKeyword then
      Exit(TCssKeyword(Value^.Keyword) = Keyword);
    Result := False;
    if (Value^.Kind = cvValue) and (Value^.Data <> nil) then
      for Index := 0 to Value^.Data.Count - 1 do
        if Value^.Data.Items[Index].IsKeyword(Keyword) then
          Exit(True);
  end;

begin
  Owner := Text.Parent;
  while Owner <> nil do
  begin
    Lines := Owner.Style.Value(cpTextDecorationLine);
    if not ((Lines^.Kind = cvKeyword) and (TCssKeyword(Lines^.Keyword) = kwNone)) then
    begin
      Color := ToColor(Owner.Style.ColorOf(cpTextDecorationColor));
      Thickness := Max(1, Font.Size / 14);
      if Owner.Style.Value(cpTextDecorationThickness)^.Kind = cvLength then
        Thickness := Owner.Style.Value(cpTextDecorationThickness)^.Number;
      Position := Y + Fragment.Baseline;
      if HasLine(Lines, kwUnderline) then
        AddLine(Position + Max(1, Font.Size * 0.1));
      if HasLine(Lines, kwOverline) then
        AddLine(Position - Font.Ascent);
      if HasLine(Lines, kwLineThrough) then
        AddLine(Position - Font.Size * 0.3);
    end;
    if (Owner.Kind <> bkInline) and ((Owner.IsAtomicInline) or Owner.IsOutOfFlow) then
      Break;
    Owner := Owner.Parent;
  end;
end;

procedure PaintText(var Builder: TBuilder; const Fragment: TLineFragment; X, Y: Single);
var
  Text: TTextBox;
  Run: TTextRun;
  Entry: PDisplayItem;
  Shadow: PCssComputedValue;
  Item: TCssValue;
  Part: Integer;
  OffsetX, OffsetY: Single;
  ShadowColor: TColor;
  Count: Integer;
begin
  Text := TTextBox(Fragment.Box);
  if not IsVisible(Text) then
    Exit;
  Run.Box := Text;
  Run.Font := TextFontOf(Text.Style);
  Run.TextStart := Fragment.TextStart;
  Run.TextLength := Fragment.TextLength;
  Run.Baseline := Y + Fragment.Baseline;
  Run.SpaceExtra := Fragment.SpaceExtra;
  Run.LetterExtra := Fragment.LetterExtra;
  { text-shadow: one offset copy each, without blur. }
  Shadow := Text.Style.Value(cpTextShadow);
  if (Shadow^.Kind = cvValue) and (Shadow^.Data <> nil) then
  begin
    Item := Shadow^.Data;
    if (Item.Kind = vkList) and (Item.Separator = lsComma) and (Item.Count > 0) then
      Item := Item.Items[0];
    ShadowColor := ToColor(Text.Style.Color);
    OffsetX := 0;
    OffsetY := 0;
    Count := 0;
    for Part := 0 to Item.Count - 1 do
      if Item.Items[Part].Kind = vkColor then
        ShadowColor := ToColor(Item.Items[Part].Color)
      else if Item.Items[Part].Kind in [vkDimension, vkNumber] then
      begin
        if Count = 0 then
          OffsetX := Item.Items[Part].Number
        else if Count = 1 then
          OffsetY := Item.Items[Part].Number;
        Inc(Count);
      end;
    Run.Baseline := Y + Fragment.Baseline + OffsetY;
    Entry := Builder.List.Add(diText, X + Fragment.X + OffsetX, Y + Fragment.Y + OffsetY, Fragment.Width,
      Fragment.Height, Text);
    Entry^.Color := ShadowColor;
    Entry^.Index := Builder.List.AddText(Run);
    Run.Baseline := Y + Fragment.Baseline;
  end;
  Entry := Builder.List.Add(diText, X + Fragment.X, Y + Fragment.Y, Fragment.Width, Fragment.Height, Text);
  Entry^.Color := ToColor(Text.Style.Color);
  Entry^.Index := Builder.List.AddText(Run);
  AddDecorationLines(Builder, Text, Fragment, X, Y, Run.Font);
end;

procedure ResolveBoxEdgesForPaint(Box: TLayoutBox);
begin
  ResolveBoxEdges(Box, 0);
end;

procedure PaintInlineBoxFragment(var Builder: TBuilder; const Fragment: TLineFragment; X, Y: Single);
var
  Box: TLayoutBox;
  Saved: TBoxEdges;
  SavedWidth, SavedHeight: Single;
  Radii: TCornerRadii;
  HasRadii: Boolean;
begin
  Box := TLayoutBox(Fragment.Box);
  if not IsVisible(Box) then
    Exit;
  { Paint as a box of the fragment's size, without the edges that are on
    other lines. }
  ResolveBoxEdgesForPaint(Box);
  Saved := Box.Border;
  SavedWidth := Box.Width;
  SavedHeight := Box.Height;
  if not Fragment.HasStart then
    Box.Border[sideLeft] := 0;
  if not Fragment.HasEnd then
    Box.Border[sideRight] := 0;
  Box.Width := Fragment.Width;
  Box.Height := Fragment.Height;
  Builder.List.Add(diHitArea, X + Fragment.X, Y + Fragment.Y, Fragment.Width, Fragment.Height, Box);
  HasRadii := BorderRadii(Box, Radii);
  PaintShadows(Builder, Box, X + Fragment.X, Y + Fragment.Y, False, Radii, HasRadii);
  PaintBackgroundLayers(Builder, Box, Box.Style, X + Fragment.X, Y + Fragment.Y, Fragment.Width, Fragment.Height,
    Radii, HasRadii);
  PaintBorders(Builder, Box, X + Fragment.X, Y + Fragment.Y, Radii, HasRadii);
  Box.Border := Saved;
  Box.Width := SavedWidth;
  Box.Height := SavedHeight;
end;

procedure PaintFragments(var Builder: TBuilder; Box: TLayoutBox; X, Y: Single);
var
  Index: Integer;
  Fragment: PLineFragment;
  Child: TLayoutBox;
begin
  if Box.Inline = nil then
    Exit;
  for Index := 0 to Box.Inline.FragmentCount - 1 do
  begin
    Fragment := @Box.Inline.Fragments[Index];
    case Fragment^.Kind of
      fkText:
        PaintText(Builder, Fragment^, X, Y);
      fkInlineBox:
        if not IsLayer(TLayoutBox(Fragment^.Box)) then
          PaintInlineBoxFragment(Builder, Fragment^, X, Y);
      fkAtomic:
        begin
          Child := TLayoutBox(Fragment^.Box);
          if not IsLayer(Child) then
            PaintLayer(Builder, Child, X + Child.X + Child.RelativeX, Y + Child.Y + Child.RelativeY);
        end;
    end;
  end;
end;

{ ---- normal flow ---- }

procedure PushOverflowClip(var Builder: TBuilder; Box: TLayoutBox; X, Y: Single);
var
  Entry: PDisplayItem;
  Radii: TCornerRadii;
begin
  Entry := Builder.List.Add(diPushClip, X + Box.Border[sideLeft], Y + Box.Border[sideTop],
    Box.Width - Box.Border[sideLeft] - Box.Border[sideRight], Box.Height - Box.Border[sideTop] -
    Box.Border[sideBottom], Box);
  if BorderRadii(Box, Radii) then
    Entry^.Index := Builder.List.AddRadii(InsetRadii(Radii, Box.Border[sideTop], Box.Border[sideRight],
      Box.Border[sideBottom], Box.Border[sideLeft]));
end;

function ScrollShiftX(Box: TLayoutBox): Single; inline;
begin
  if (bfScrollContainer in Box.Flags) and (Box.Kind <> bkViewport) then
    Result := -Box.ScrollX
  else
    Result := 0;
end;

function ScrollShiftY(Box: TLayoutBox): Single; inline;
begin
  if (bfScrollContainer in Box.Flags) and (Box.Kind <> bkViewport) then
    Result := -Box.ScrollY
  else
    Result := 0;
end;

procedure WalkFlow(var Builder: TBuilder; Box: TLayoutBox; X, Y: Single; Phase: TPhase);
var
  Child: TLayoutBox;
  ChildX, ChildY, InnerX, InnerY: Single;
  Clips: Boolean;
begin
  InnerX := X + ScrollShiftX(Box);
  InnerY := Y + ScrollShiftY(Box);
  if (Phase = phInline) and (bfChildrenInline in Box.Flags) then
    PaintFragments(Builder, Box, InnerX, InnerY);
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if Child.Kind = bkInline then
    begin
      { Floats and blocks inside inline boxes. }
      WalkFlow(Builder, Child, X, Y, Phase);
      Child := Child.NextSibling;
      Continue;
    end;
    if (Child.Kind = bkText) or IsLayer(Child) or Child.IsAtomicInline then
    begin
      Child := Child.NextSibling;
      Continue;
    end;
    ChildX := InnerX + Child.X + Child.RelativeX;
    ChildY := InnerY + Child.Y + Child.RelativeY;
    if Child.IsFloating then
    begin
      if Phase = phFloats then
        PaintLayer(Builder, Child, ChildX, ChildY);
      Child := Child.NextSibling;
      Continue;
    end;
    if Phase = phBlocks then
      PaintDecorations(Builder, Child, ChildX, ChildY);
    Clips := bfClipsOverflow in Child.Flags;
    if Clips then
      PushOverflowClip(Builder, Child, ChildX, ChildY);
    WalkFlow(Builder, Child, ChildX, ChildY, Phase);
    if Clips then
      Builder.List.Add(diPopClip, 0, 0, 0, 0, Child);
    Child := Child.NextSibling;
  end;
end;

procedure CollectLayers(var Builder: TBuilder; Box: TLayoutBox; X, Y: Single; var Clips: TClipChain;
  var Layers: TLayerArray; var Count: Integer);
var
  Child: TLayoutBox;
  ChildX, ChildY, InnerX, InnerY: Single;
  Pushed: Boolean;
  Radii: TCornerRadii;
begin
  InnerX := X + ScrollShiftX(Box);
  InnerY := Y + ScrollShiftY(Box);
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if Child.Kind = bkInline then
    begin
      CollectLayers(Builder, Child, X, Y, Clips, Layers, Count);
      Child := Child.NextSibling;
      Continue;
    end;
    if Child.Kind = bkText then
    begin
      Child := Child.NextSibling;
      Continue;
    end;
    ChildX := InnerX + Child.X + Child.RelativeX;
    ChildY := InnerY + Child.Y + Child.RelativeY;
    if IsLayer(Child) then
    begin
      if Count >= Length(Layers) then
        SetLength(Layers, Count * 2 + 4);
      Layers[Count].Box := Child;
      Layers[Count].X := ChildX;
      Layers[Count].Y := ChildY;
      if MakesStackingContext(Child) then
        Layers[Count].Z := ZIndexOf(Child.Style)
      else
        Layers[Count].Z := 0;
      Layers[Count].Order := Count;
      { Absolutely positioned boxes escape the clips of boxes between them
        and their containing block only approximately: all clips apply. }
      Layers[Count].Clips := Copy(Clips);
      Inc(Count);
    end
    else if not Child.IsFloating and not Child.IsAtomicInline then
    begin
      Pushed := bfClipsOverflow in Child.Flags;
      if Pushed then
      begin
        SetLength(Clips, Length(Clips) + 1);
        Clips[High(Clips)].X := ChildX + Child.Border[sideLeft];
        Clips[High(Clips)].Y := ChildY + Child.Border[sideTop];
        Clips[High(Clips)].Width := Child.Width - Child.Border[sideLeft] - Child.Border[sideRight];
        Clips[High(Clips)].Height := Child.Height - Child.Border[sideTop] - Child.Border[sideBottom];
        Clips[High(Clips)].Radii := -1;
        if BorderRadii(Child, Radii) then
          Clips[High(Clips)].Radii := Builder.List.AddRadii(InsetRadii(Radii, Child.Border[sideTop],
            Child.Border[sideRight], Child.Border[sideBottom], Child.Border[sideLeft]));
      end;
      CollectLayers(Builder, Child, ChildX, ChildY, Clips, Layers, Count);
      if Pushed then
        SetLength(Clips, Length(Clips) - 1);
    end
    else
    begin
      { Floats and atomic inlines paint their own positioned children. }
    end;
    Child := Child.NextSibling;
  end;
end;

procedure SortLayers(var Layers: TLayerArray; Count: Integer);
var
  Index, Other: Integer;
  Item: TLayer;
begin
  for Index := 1 to Count - 1 do
  begin
    Item := Layers[Index];
    Other := Index - 1;
    while (Other >= 0) and ((Layers[Other].Z > Item.Z) or
      ((Layers[Other].Z = Item.Z) and (Layers[Other].Order > Item.Order))) do
    begin
      Layers[Other + 1] := Layers[Other];
      Dec(Other);
    end;
    Layers[Other + 1] := Item;
  end;
end;

procedure PaintLayerWithClips(var Builder: TBuilder; const Layer: TLayer);
var
  Index: Integer;
  Entry: PDisplayItem;
begin
  for Index := 0 to High(Layer.Clips) do
  begin
    Entry := Builder.List.Add(diPushClip, Layer.Clips[Index].X, Layer.Clips[Index].Y, Layer.Clips[Index].Width,
      Layer.Clips[Index].Height, Layer.Box);
    Entry^.Index := Layer.Clips[Index].Radii;
  end;
  if bfFixed in Layer.Box.Flags then
    Builder.List.Add(diPushFixed, 0, 0, 0, 0, Layer.Box);
  PaintLayer(Builder, Layer.Box, Layer.X, Layer.Y);
  if bfFixed in Layer.Box.Flags then
    Builder.List.Add(diPopFixed, 0, 0, 0, 0, Layer.Box);
  for Index := 0 to High(Layer.Clips) do
    Builder.List.Add(diPopClip, 0, 0, 0, 0, Layer.Box);
end;

procedure PaintLayer(var Builder: TBuilder; Box: TLayoutBox; X, Y: Single);
var
  Layers: TLayerArray;
  Count, Index: Integer;
  Clips: TClipChain;
  Opacity: Single;
  Entry: PDisplayItem;
  ClipsOverflow: Boolean;
begin
  Opacity := 1;
  if Box.Style <> nil then
    Opacity := Box.Style.Value(cpOpacity)^.Number;
  if (Opacity <= 0) and (Box.Kind <> bkViewport) then
    Exit;
  if Opacity < 1 then
  begin
    Entry := Builder.List.Add(diPushOpacity, X, Y, Box.Width, Box.Height, Box);
    Entry^.Value := Opacity;
  end;
  PaintDecorations(Builder, Box, X, Y);
  Layers := nil;
  Count := 0;
  Clips := nil;
  ClipsOverflow := (bfClipsOverflow in Box.Flags) and (Box.Kind <> bkViewport);
  if ClipsOverflow then
  begin
    SetLength(Clips, 1);
    Clips[0].X := X + Box.Border[sideLeft];
    Clips[0].Y := Y + Box.Border[sideTop];
    Clips[0].Width := Box.Width - Box.Border[sideLeft] - Box.Border[sideRight];
    Clips[0].Height := Box.Height - Box.Border[sideTop] - Box.Border[sideBottom];
    Clips[0].Radii := -1;
  end;
  CollectLayers(Builder, Box, X, Y, Clips, Layers, Count);
  SortLayers(Layers, Count);
  { Negative z-index. }
  Index := 0;
  while (Index < Count) and (Layers[Index].Z < 0) do
  begin
    PaintLayerWithClips(Builder, Layers[Index]);
    Inc(Index);
  end;
  if ClipsOverflow then
    PushOverflowClip(Builder, Box, X, Y);
  WalkFlow(Builder, Box, X, Y, phBlocks);
  WalkFlow(Builder, Box, X, Y, phFloats);
  WalkFlow(Builder, Box, X, Y, phInline);
  if ClipsOverflow then
    Builder.List.Add(diPopClip, 0, 0, 0, 0, Box);
  { z-index auto and 0, then positive. }
  while Index < Count do
  begin
    PaintLayerWithClips(Builder, Layers[Index]);
    Inc(Index);
  end;
  if Box.Kind <> bkViewport then
    PaintOutline(Builder, Box, X, Y);
  if Opacity < 1 then
    Builder.List.Add(diPopOpacity, 0, 0, 0, 0, Box);
end;

{ The box whose background paints the canvas: the root element's, or the
  body's when the root has neither color nor image. }
function FindCanvasBox(Root: TLayoutBox): TLayoutBox;
var
  RootBox, Child: TLayoutBox;

  function HasBackground(Box: TLayoutBox): Boolean;
  var
    Images: PCssComputedValue;
  begin
    Images := Box.Style.Value(cpBackgroundImage);
    Result := (AlphaOf(ToColor(Box.Style.ColorOf(cpBackgroundColor))) > 0) or
      ((Images^.Kind = cvValue) and (Images^.Data <> nil) and not
       ((Images^.Data.Kind = vkList) and (Images^.Data.Count = 1) and (Images^.Data.Items[0].Kind = vkKeyword)));
  end;

begin
  Result := nil;
  RootBox := Root.FirstChild;
  if RootBox = nil then
    Exit;
  if HasBackground(RootBox) then
    Exit(RootBox);
  Child := RootBox.FirstChild;
  while Child <> nil do
  begin
    if (Child.Node <> nil) and Child.Node.IsElement and TElement(Child.Node).IsHtmlElement(AtomBody) then
    begin
      if HasBackground(Child) then
        Exit(Child);
      Exit(nil);
    end;
    Child := Child.NextSibling;
  end;
end;

procedure BuildDisplayList(Root: TLayoutBox; Resources: TDocumentResources; List: TDisplayList);
var
  Builder: TBuilder;
  Canvas: TLayoutBox;
  Width, Height, CanvasX, CanvasY: Single;
  NoRadii: TCornerRadii;
begin
  List.Clear;
  if Root = nil then
    Exit;
  Builder.List := List;
  Builder.Resources := Resources;
  Builder.Order := 0;
  Canvas := FindCanvasBox(Root);
  Builder.CanvasBox := Canvas;
  Width := Max(Root.Width, Root.ScrollWidth);
  Height := Max(Root.Height, Root.ScrollHeight);
  if Canvas <> nil then
  begin
    List.CanvasColor := ToColor(Canvas.Style.ColorOf(cpBackgroundColor));
    if AlphaOf(List.CanvasColor) = 0 then
      List.CanvasColor := ColorWhite
    else
      List.CanvasColor := BlendColors(ColorWhite, List.CanvasColor);
    FillChar(NoRadii, SizeOf(NoRadii), 0);
    Canvas.AbsolutePosition(CanvasX, CanvasY);
    { Images are positioned against the root element's box but cover the
      canvas (here: the document's area). }
    PaintBackgroundLayers(Builder, Canvas, Canvas.Style, 0, 0, Width, Height, NoRadii, False);
    if (List.Count > 0) and (List.Items[0].Kind = diRectangle) then
      List.Items[0].Kind := diRectangle;
  end;
  PaintLayer(Builder, Root, Root.X, Root.Y);
end;

end.
