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
  The display list: what painting draws, in painting order.

  Items are small fixed records in one array (kind, bounds in document
  CSS pixels, a color, the box they come from for hit testing, and an
  index into one of the side arrays for what does not fit: corner radii,
  border sides, text runs, images, gradients, shadows). Clips, opacity
  groups, fixed-position and sticky subtrees are push/pop pairs. The list is
  built once per layout (Web.Paint.Builder) and kept: painting any
  rectangle of the viewport, at any scroll offset, and hit testing all
  read the same list.
}
unit Web.Paint.DisplayList;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors, Drawing.Rasterizer, Drawing.SmoothRoundedRectangles, Css.Values, Css.Keywords, Css.TransformMatrices,
  Image.Model, Web.Layout.Boxes, Web.Text.FontInstances, Web.Paint.Filters;

type
  TDisplayItemKind = (
    { A filled rectangle (Index: radii or -1). }
    diRectangle,
    { Borders (Index: a TBorderSides). }
    diBorder,
    { A text run (Index: a TTextRun). }
    diText,
    { An image (Index: a TImageRun). }
    diImage,
    { A gradient filling the bounds (Index: a TGradientRun). }
    diGradient,
    { A box shadow (Index: a TShadowRun). }
    diShadow,
    { A control drawn by the engine (Index: the control kind). }
    diControl,
    { Clip to the bounds (Index: radii or -1) until the matching pop. }
    diPushClip, diPopClip,
    { Draw into a group composited at Value's opacity. }
    diPushOpacity, diPopOpacity,
    { Items up to the pop do not move with the viewport's scroll. }
    diPushFixed, diPopFixed,
    { Items up to the pop move with a position: sticky box (the bounds:
      its border box; Index: a TStickyRun), by an offset that depends
      on the viewport's scroll (Web.Paint.Sticky). }
    diPushSticky, diPopSticky,
    { A masked subtree (CSS Masking): the items up to diMaskContent draw
      the mask layers, the ones after it the content, composited at the
      pop through the layers' alpha. The bounds: the mask's clip. }
    diPushMask, diMaskContent, diPopMask,
    { One mask layer composited with the layers below it (mask-composite;
      Index: a TMaskComposite), drawn into a group of its own. }
    diPushMaskLayer, diPopMaskLayer,
    { A filtered subtree (the filter property; Index: its operations in
      Filters), drawn into a group filtered at the pop. }
    diPushFilter, diPopFilter,
    { Not drawn: where a box is, for hit testing. }
    diHitArea,
    { A control's own text (a text field's value; Index: a string), in
      the box's font, clipped to the bounds. }
    diControlText,
    { A frame's document (Index: a TEmbeddedContent in Frames) painted
      into the bounds (the frame's content box). }
    diFrame,
    { Items up to the pop are drawn through a 2D transform (Index: a
      matrix in Transforms, of document coordinates); the bounds: what
      the group draws, before the transform. }
    diPushTransform, diPopTransform);

  TDisplayItem = record
    Kind: TDisplayItemKind;
    X, Y, Width, Height: Single;
    Color: TColor;
    Index: Integer;
    Value: Single;
    Box: TLayoutBox;
  end;
  PDisplayItem = ^TDisplayItem;

  TBorderSides = record
    Widths: array[0..3] of Single;
    Colors: array[0..3] of TColor;
    Styles: array[0..3] of TCssKeyword;
    Radii: Integer;
  end;

  { mask-composite: how a mask layer's alpha combines with the layers
    below it. }
  TMaskComposite = (mcAdd, mcSubtract, mcIntersect, mcExclude);

  TTextRun = record
    Box: TTextBox;
    Font: TTextFont;
    TextStart, TextLength: Integer;
    { Text of its own instead of the box's (an ellipsis): an index into
      Strings, -1 for none (Box is nil then). }
    Literal: Integer;
    Baseline: Single;
    SpaceExtra, LetterExtra: Single;
  end;

  TImageRun = record
    Image: TImage;
    { One tile (where the image's top left goes and its drawn size). }
    TileX, TileY, TileWidth, TileHeight: Single;
    RepeatX, RepeatY: Boolean;
    Pixelated: Boolean;
  end;

  TGradientRun = record
    Gradient: TCssValue;
    CurrentColor: TColor;
    { The gradient box (the tile). }
    BoxX, BoxY, BoxWidth, BoxHeight: Single;
  end;

  TShadowRun = record
    OffsetX, OffsetY, Blur, Spread: Single;
    Inset: Boolean;
    Radii: Integer;
    { The box the shadow belongs to. }
    BoxX, BoxY, BoxWidth, BoxHeight: Single;
  end;

  { A sticky box's constraints, in document CSS pixels: the rectangle
    its margin box must stay in (its containing block's content box less
    its margins) and the insets from the viewport's edges it keeps when
    it can (Has*: not auto). }
  TStickyRun = record
    LimitLeft, LimitTop, LimitRight, LimitBottom: Single;
    InsetLeft, InsetTop, InsetRight, InsetBottom: Single;
    HasLeft, HasTop, HasRight, HasBottom: Boolean;
  end;

  { What a push item's group draws, in the document coordinates of the
    push (Web.Paint.GroupExtents). }
  TGroupExtent = record
    Left, Top, Right, Bottom: Single;
    { False when not known: the origin moves inside (a fixed or sticky
      subtree) or a filter spreads what is drawn. }
    Bounded: Boolean;
    { The matching pop (-1: the list ends first). }
    PopIndex: Integer;
  end;

  TDisplayList = class
  public
    Items: array of TDisplayItem;
    Count: Integer;
    Radii: array of TCornerRadii;
    RadiusCount: Integer;
    Borders: array of TBorderSides;
    BorderCount: Integer;
    Texts: array of TTextRun;
    TextCount: Integer;
    Images: array of TImageRun;
    ImageCount: Integer;
    Gradients: array of TGradientRun;
    GradientCount: Integer;
    Shadows: array of TShadowRun;
    ShadowCount: Integer;
    Strings: array of string;
    StringCount: Integer;
    Stickies: array of TStickyRun;
    StickyCount: Integer;
    { TEmbeddedContent objects (the parent document's resources own
      their owners; the list is built again when they change). }
    Frames: array of TObject;
    FrameCount: Integer;
    Transforms: array of TCssMatrix2D;
    TransformCount: Integer;
    Filters: array of TFilterOperations;
    FilterCount: Integer;
    { The canvas color (the root's or body's background). }
    CanvasColor: TColor;
    { Changes with every Clear and Add, unique among all lists: what is
      worked out from a list is kept with the revision it was for. }
    Revision: LongWord;
    { Per item (meaningful at push items), for GroupExtentsRevision. }
    GroupExtents: array of TGroupExtent;
    GroupExtentsRevision: LongWord;
    procedure Clear;
    function Add(Kind: TDisplayItemKind; X, Y, Width, Height: Single; Box: TLayoutBox): PDisplayItem;
    function AddRadii(const Value: TCornerRadii): Integer;
    function AddBorder(const Value: TBorderSides): Integer;
    function AddText(const Value: TTextRun): Integer;
    function AddImage(const Value: TImageRun): Integer;
    function AddGradient(const Value: TGradientRun): Integer;
    function AddShadow(const Value: TShadowRun): Integer;
    function AddString(const Value: string): Integer;
    function AddSticky(const Value: TStickyRun): Integer;
    function AddFrame(Content: TObject): Integer;
    function AddTransform(const Value: TCssMatrix2D): Integer;
    function AddFilter(const Value: TFilterOperations): Integer;
    { Bytes the list holds. }
    function MemoryBytes: PtrUInt;
  end;

implementation

var
  LastRevision: LongWord = 0;

procedure NextRevision(List: TDisplayList); inline;
begin
  Inc(LastRevision);
  List.Revision := LastRevision;
end;

procedure TDisplayList.Clear;
begin
  NextRevision(Self);
  Count := 0;
  RadiusCount := 0;
  BorderCount := 0;
  TextCount := 0;
  ImageCount := 0;
  GradientCount := 0;
  ShadowCount := 0;
  StringCount := 0;
  StickyCount := 0;
  FrameCount := 0;
  TransformCount := 0;
  CanvasColor := ColorWhite;
end;

function TDisplayList.Add(Kind: TDisplayItemKind; X, Y, Width, Height: Single; Box: TLayoutBox): PDisplayItem;
begin
  NextRevision(Self);
  if Count >= Length(Items) then
    SetLength(Items, Count * 2 + 64);
  Result := @Items[Count];
  Result^.Kind := Kind;
  Result^.X := X;
  Result^.Y := Y;
  Result^.Width := Width;
  Result^.Height := Height;
  Result^.Color := 0;
  Result^.Index := -1;
  Result^.Value := 0;
  Result^.Box := Box;
  Inc(Count);
end;

function TDisplayList.AddTransform(const Value: TCssMatrix2D): Integer;
begin
  if TransformCount >= Length(Transforms) then
    SetLength(Transforms, TransformCount * 2 + 4);
  Transforms[TransformCount] := Value;
  Result := TransformCount;
  Inc(TransformCount);
end;

function TDisplayList.AddRadii(const Value: TCornerRadii): Integer;
begin
  if RadiusCount >= Length(Radii) then
    SetLength(Radii, RadiusCount * 2 + 8);
  Radii[RadiusCount] := Value;
  Result := RadiusCount;
  Inc(RadiusCount);
end;

function TDisplayList.AddBorder(const Value: TBorderSides): Integer;
begin
  if BorderCount >= Length(Borders) then
    SetLength(Borders, BorderCount * 2 + 8);
  Borders[BorderCount] := Value;
  Result := BorderCount;
  Inc(BorderCount);
end;

function TDisplayList.AddText(const Value: TTextRun): Integer;
begin
  if TextCount >= Length(Texts) then
    SetLength(Texts, TextCount * 2 + 32);
  Texts[TextCount] := Value;
  Result := TextCount;
  Inc(TextCount);
end;

function TDisplayList.AddImage(const Value: TImageRun): Integer;
begin
  if ImageCount >= Length(Images) then
    SetLength(Images, ImageCount * 2 + 4);
  Images[ImageCount] := Value;
  Result := ImageCount;
  Inc(ImageCount);
end;

function TDisplayList.AddGradient(const Value: TGradientRun): Integer;
begin
  if GradientCount >= Length(Gradients) then
    SetLength(Gradients, GradientCount * 2 + 4);
  Gradients[GradientCount] := Value;
  Result := GradientCount;
  Inc(GradientCount);
end;

function TDisplayList.AddShadow(const Value: TShadowRun): Integer;
begin
  if ShadowCount >= Length(Shadows) then
    SetLength(Shadows, ShadowCount * 2 + 4);
  Shadows[ShadowCount] := Value;
  Result := ShadowCount;
  Inc(ShadowCount);
end;

function TDisplayList.AddString(const Value: string): Integer;
begin
  if StringCount >= Length(Strings) then
    SetLength(Strings, StringCount * 2 + 4);
  Strings[StringCount] := Value;
  Result := StringCount;
  Inc(StringCount);
end;

function TDisplayList.AddSticky(const Value: TStickyRun): Integer;
begin
  if StickyCount >= Length(Stickies) then
    SetLength(Stickies, StickyCount * 2 + 4);
  Stickies[StickyCount] := Value;
  Result := StickyCount;
  Inc(StickyCount);
end;

function TDisplayList.AddFrame(Content: TObject): Integer;
begin
  if FrameCount >= Length(Frames) then
    SetLength(Frames, FrameCount * 2 + 4);
  Frames[FrameCount] := Content;
  Result := FrameCount;
  Inc(FrameCount);
end;

function TDisplayList.AddFilter(const Value: TFilterOperations): Integer;
begin
  if FilterCount >= Length(Filters) then
    SetLength(Filters, FilterCount * 2 + 4);
  Filters[FilterCount] := Value;
  Result := FilterCount;
  Inc(FilterCount);
end;

function TDisplayList.MemoryBytes: PtrUInt;
begin
  Result := PtrUInt(Length(Items)) * SizeOf(TDisplayItem) + PtrUInt(Length(Radii)) * SizeOf(TCornerRadii) +
    PtrUInt(Length(Borders)) * SizeOf(TBorderSides) + PtrUInt(Length(Texts)) * SizeOf(TTextRun) +
    PtrUInt(Length(Images)) * SizeOf(TImageRun) + PtrUInt(Length(Gradients)) * SizeOf(TGradientRun) +
    PtrUInt(Length(Shadows)) * SizeOf(TShadowRun) + PtrUInt(Length(Stickies)) * SizeOf(TStickyRun) +
    PtrUInt(Length(GroupExtents)) * SizeOf(TGroupExtent);
end;

end.
