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
  The SVG renderer: a styled document drawn onto a surface with
  libdrawing, anti-aliased.

  It walks the tree from the root with the current transform (user
  space to surface pixels), the viewport (for percentages) and the
  parent's style. Per element:

  - display: none skips it and its subtree; visibility: hidden skips
    painting it (children may still be visible); transform composes.
  - Shapes fill (fill-rule) and stroke (width, caps, joins, miter
    limit, dashes; vector-effect: non-scaling-stroke) with a colour, a
    gradient or a pattern, in paint-order; text the same, glyph by glyph
    (Svg.Text); <image> draws its picture (data: URLs) by
    preserveAspectRatio.
  - Groups (g, a, switch's first child) draw their children; nested
    svg and use of a symbol open a viewport (viewBox,
    preserveAspectRatio, clipped by its rectangle when the transform
    keeps it a rectangle); use draws its target, restyled under it.
  - opacity below 1 (unless only one of fill and stroke is painted and
    it can take the opacity itself), clip-path and mask draw the
    element into a layer of its own, put down through the clip's
    coverage and the mask's luminance.

  Paint servers: linear and radial gradients (gradientUnits,
  gradientTransform, spreadMethod, href inheritance of attributes and
  stops) and patterns (patternUnits, patternContentUnits,
  patternTransform, viewBox, href inheritance), whose tile is drawn at
  the device's resolution.
}
unit Svg.Renderer;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Regions,
  Drawing.Surfaces,
  Drawing.Canvas,
  Drawing.Rasterizer,
  Drawing.Transforms,
  Drawing.Paths,
  Drawing.Stroking,
  Drawing.Dashing,
  Drawing.Paints,
  Drawing.PaintFilling,
  Css.ComputedStyle,
  Svg.Nodes,
  Svg.Numbers,
  Svg.Document;

type
  TSvgRenderState = record
    { User space to surface pixels. }
    Transform: TAffineTransform;
    Viewport: TSvgViewport;
    ParentStyle: TCssComputedStyle;
    { Inside a <use>: styles are resolved again under it. }
    Restyle: Boolean;
  end;

  TSvgRenderer = class
  private
    FDocument: TSvgDocument;
    FCanvas: TCanvas;
    FDepth: Integer;
    FUseStack: array of TSvgNode;
    FUseCount: Integer;
    FRootViewBox: TSvgViewBox;
    FHasRootViewBox: Boolean;
    FTextRestyle: Boolean;
    function StyleFor(Node: TSvgNode; const State: TSvgRenderState): TCssComputedStyle;
    function TextChildStyle(Node: TSvgNode; ParentStyle: TCssComputedStyle): TCssComputedStyle;
    function ChildState(const State: TSvgRenderState; Style: TCssComputedStyle): TSvgRenderState;
    procedure RenderNode(Node: TSvgNode; const State: TSvgRenderState);
    procedure RenderChildren(Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState);
    procedure RenderContent(Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState;
      Opacity: Double);
    procedure RenderInLayer(Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState;
      Opacity: Double; ClipNode, MaskNode: TSvgNode);
    procedure RenderShape(Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState; Opacity: Double);
    procedure RenderText(Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState; Opacity: Double);
    procedure RenderImage(Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState; Opacity: Double);
    procedure RenderUse(Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState);
    procedure RenderSwitch(Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState);
    procedure RenderViewport(ContentNode: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState;
      X, Y, Width, Height: Double; HasViewBox: Boolean; const Box: TSvgViewBox);
    procedure DrawPath(Style: TCssComputedStyle; const State: TSvgRenderState; const Path: TPath;
      Opacity: Double; const BoundingBox: TPathBounds);
    procedure FillPath(Style: TCssComputedStyle; const State: TSvgRenderState; const Path: TPath;
      Opacity: Double; const BoundingBox: TPathBounds);
    procedure StrokePath(Style: TCssComputedStyle; const State: TSvgRenderState; const Path: TPath;
      Opacity: Double; const BoundingBox: TPathBounds);
    function ResolvePaint(Style: TCssComputedStyle; IsStroke: Boolean; const State: TSvgRenderState;
      const BoundingBox: TPathBounds; out Paint: TPaint; out Tile: TSurface): Boolean;
    function GradientPaint(Server: TSvgNode; const State: TSvgRenderState; const BoundingBox: TPathBounds;
      out Paint: TPaint): Boolean;
    function PatternPaintOf(Server: TSvgNode; const State: TSvgRenderState; const BoundingBox: TPathBounds;
      out Paint: TPaint; out Tile: TSurface): Boolean;
    function ElementBounds(Node: TSvgNode; Style: TCssComputedStyle; const Transform: TAffineTransform;
      const State: TSvgRenderState; IncludeStroke: Boolean): TPathBounds;
    function ChildBounds(Node: TSvgNode; const Transform: TAffineTransform; const State: TSvgRenderState;
      IncludeStroke: Boolean): TPathBounds;
    function BuildClipMask(ClipNode, Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState;
      const Area: TRectangle; Depth: Integer): TCoverageMask;
    function BuildLuminanceMask(MaskNode, Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState;
      const Area: TRectangle): TCoverageMask;
    function OnUseStack(Node: TSvgNode): Boolean;
  public
    constructor Create(Document: TSvgDocument);
    { Draws the document over Surface, its root viewport ViewportWidth x
      ViewportHeight user units (CSS pixels) stretched over the
      surface. With SynthesizeViewBox a root without a viewBox but with
      a size scales as if its viewBox were 0 0 width height (SVG shown
      as an image at another size). }
    procedure Render(const Surface: TSurface; ViewportWidth, ViewportHeight: Double; SynthesizeViewBox: Boolean);
  end;

{ The document drawn into a new surface of Width x Height pixels
  (transparent where nothing is drawn); the caller frees it. }
function RenderSvgToSurface(Document: TSvgDocument; Width, Height: LongInt; ViewportWidth,
  ViewportHeight: Double; SynthesizeViewBox: Boolean; out Surface: TSurface): Boolean;

implementation

uses
  Math,
  Image.Model,
  Image.Scalable,
  Image.Surfaces,
  Css.Keywords,
  Css.PropertyIds,
  Svg.Geometry,
  Svg.StyleValues,
  Svg.Text;

const
  MaximumDepth = 256;
  MaximumUseDepth = 24;
  MaximumTileSide = 2048;
  FillTolerance = 0.05;

function EmptyBounds: TPathBounds;
begin
  Result.Left := 0;
  Result.Top := 0;
  Result.Right := 0;
  Result.Bottom := 0;
  Result.Empty := True;
end;

procedure UniteBounds(var Bounds: TPathBounds; const Other: TPathBounds);
begin
  if Other.Empty then
    Exit;
  if Bounds.Empty then
  begin
    Bounds := Other;
    Exit;
  end;
  Bounds.Left := Min(Bounds.Left, Other.Left);
  Bounds.Top := Min(Bounds.Top, Other.Top);
  Bounds.Right := Max(Bounds.Right, Other.Right);
  Bounds.Bottom := Max(Bounds.Bottom, Other.Bottom);
end;

function RectangleBounds(X, Y, Width, Height: Double; const Transform: TAffineTransform): TPathBounds;
var
  Path: TPath;
begin
  BeginPath(Path);
  PathAddRectangle(Path, X, Y, Width, Height);
  Result := PathBounds(Path, Transform);
end;

function RectanglePath(X, Y, Width, Height: Double): TPath;
begin
  BeginPath(Result);
  PathAddRectangle(Result, X, Y, Width, Height);
end;

function ByteOf(Opacity: Double): Byte;
begin
  if Opacity <= 0 then
    Exit(0);
  if Opacity >= 1 then
    Exit(255);
  Result := Round(Opacity * 255);
end;

function ElementTransform(Node: TSvgNode): TAffineTransform;
begin
  if not ParseTransformList(Node.Attribute('transform'), Result) then
    Result := IdentityTransform;
end;

{ A node of the given kind an attribute refers to through url(#id) or #id. }
function ReferencedNode(Document: TSvgDocument; const Reference: string; Kind: TSvgElementKind): TSvgNode;
begin
  Result := nil;
  if Reference = '' then
    Exit;
  Result := Document.FindByReference(Reference);
  if (Result <> nil) and not Result.IsKind(Kind) then
    Result := nil;
end;

function MaskReference(Node: TSvgNode): string;
begin
  Result := Trim(Node.Attribute('mask'));
end;

constructor TSvgRenderer.Create(Document: TSvgDocument);
begin
  inherited Create;
  FDocument := Document;
end;

function TSvgRenderer.StyleFor(Node: TSvgNode; const State: TSvgRenderState): TCssComputedStyle;
begin
  if State.Restyle and (FDocument.StyleResolver <> nil) and (State.ParentStyle <> nil) then
    Result := FDocument.StyleResolver.ResolveStyle(Node, State.ParentStyle)
  else if Node.Style <> nil then
    Result := Node.Style.AddRef
  else
    Result := nil;
end;

function TSvgRenderer.TextChildStyle(Node: TSvgNode; ParentStyle: TCssComputedStyle): TCssComputedStyle;
begin
  if FTextRestyle and (FDocument.StyleResolver <> nil) then
    Result := FDocument.StyleResolver.ResolveStyle(Node, ParentStyle)
  else if Node.Style <> nil then
    Result := Node.Style.AddRef
  else
    Result := nil;
end;

function TSvgRenderer.ChildState(const State: TSvgRenderState; Style: TCssComputedStyle): TSvgRenderState;
begin
  Result := State;
  Result.ParentStyle := Style;
  Result.Viewport.FontSize := Style.FontSize;
end;

function TSvgRenderer.OnUseStack(Node: TSvgNode): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to FUseCount - 1 do
    if FUseStack[Index] = Node then
      Exit(True);
  Result := False;
end;

{ ---- the walk ---- }

function IsRenderedKind(Kind: TSvgElementKind): Boolean;
begin
  Result := Kind in [SvgSvg, SvgG, SvgUse, SvgRect, SvgCircle, SvgEllipse, SvgLine, SvgPolyline, SvgPolygon,
    SvgPath, SvgText, SvgImage, SvgSwitch, SvgAnchor];
end;

function CanFoldOpacity(Node: TSvgNode; Style: TCssComputedStyle): Boolean;
begin
  if Node.ElementKind = SvgImage then
    Exit(True);
  if not IsShapeKind(Node.ElementKind) then
    Exit(False);
  { One paint takes the opacity; with both, they must blend as one. }
  Result := (PaintOf(Style, cpFill).Kind = SvgPaintNone) or (PaintOf(Style, cpStroke).Kind = SvgPaintNone) or
    (StrokeWidthOf(Style, Default(TSvgViewport)) <= 0);
end;

procedure TSvgRenderer.RenderNode(Node: TSvgNode; const State: TSvgRenderState);
var
  Style: TCssComputedStyle;
  NodeState: TSvgRenderState;
  Opacity: Double;
  ClipNode, MaskNode: TSvgNode;
begin
  if not Node.IsElement or not IsRenderedKind(Node.ElementKind) or (FDepth >= MaximumDepth) then
    Exit;
  Style := StyleFor(Node, State);
  if Style = nil then
    Exit;
  Inc(FDepth);
  try
    if Style.IsDisplayNone then
      Exit;
    NodeState := ChildState(State, Style);
    NodeState.Transform := CombineTransforms(State.Transform, ElementTransform(Node));
    Opacity := OpacityOf(Style, cpOpacity);
    if Opacity <= 0 then
      Exit;
    ClipNode := ReferencedNode(FDocument, ReferenceOfUrl(Style, cpClipPath), SvgClipPath);
    MaskNode := ReferencedNode(FDocument, MaskReference(Node), SvgMask);
    if (ClipNode = nil) and (MaskNode = nil) and ((Opacity >= 1) or CanFoldOpacity(Node, Style)) then
      RenderContent(Node, Style, NodeState, Opacity)
    else
      RenderInLayer(Node, Style, NodeState, Opacity, ClipNode, MaskNode);
  finally
    Dec(FDepth);
    Style.Release;
  end;
end;

procedure TSvgRenderer.RenderChildren(Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState);
var
  Child: TSvgNode;
  Inner: TSvgRenderState;
begin
  Inner := ChildState(State, Style);
  Child := Node.FirstElementChild;
  while Child <> nil do
  begin
    RenderNode(Child, Inner);
    Child := Child.NextElementSibling;
  end;
end;

procedure TSvgRenderer.RenderContent(Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState;
  Opacity: Double);
var
  X, Y, Width, Height: Double;
  Box: TSvgViewBox;
  HasBox: Boolean;
begin
  case Node.ElementKind of
    SvgG, SvgAnchor:
      RenderChildren(Node, Style, State);
    SvgSwitch:
      RenderSwitch(Node, Style, State);
    SvgSvg:
      if Node = FDocument.Root then
        RenderViewport(Node, Style, State, 0, 0, State.Viewport.Width, State.Viewport.Height, FHasRootViewBox,
          FRootViewBox)
      else
      begin
        X := AttributeLength(Node, 'x', DirectionHorizontal, State.Viewport, 0);
        Y := AttributeLength(Node, 'y', DirectionVertical, State.Viewport, 0);
        Width := AttributeLength(Node, 'width', DirectionHorizontal, State.Viewport, State.Viewport.Width);
        Height := AttributeLength(Node, 'height', DirectionVertical, State.Viewport, State.Viewport.Height);
        HasBox := ParseViewBox(Node.Attribute('viewBox'), Box);
        RenderViewport(Node, Style, State, X, Y, Width, Height, HasBox, Box);
      end;
    SvgUse:
      RenderUse(Node, Style, State);
    SvgText:
      RenderText(Node, Style, State, Opacity);
    SvgImage:
      RenderImage(Node, Style, State, Opacity);
    else
      if IsShapeKind(Node.ElementKind) then
        RenderShape(Node, Style, State, Opacity);
  end;
end;

procedure TSvgRenderer.RenderSwitch(Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState);
var
  Child: TSvgNode;
  Language: string;
begin
  Child := Node.FirstElementChild;
  while Child <> nil do
  begin
    if IsRenderedKind(Child.ElementKind) and not Child.HasAttribute('requiredExtensions') then
    begin
      Language := LowerCase(Child.Attribute('systemLanguage'));
      if (Language = '') or (Pos('en', Language) > 0) then
      begin
        RenderNode(Child, ChildState(State, Style));
        Exit;
      end;
    end;
    Child := Child.NextElementSibling;
  end;
end;

procedure TSvgRenderer.RenderViewport(ContentNode: TSvgNode; Style: TCssComputedStyle;
  const State: TSvgRenderState; X, Y, Width, Height: Double; HasViewBox: Boolean; const Box: TSvgViewBox);
var
  ViewState: TSvgRenderState;
  ViewTransform: TAffineTransform;
  Saved: TRegion;
  Clipped: Boolean;
  Corner, FarCorner: TPrecisePoint;
  ClipRectangle: TRectangle;
  Overflow: string;
begin
  if (Width <= 0) or (Height <= 0) then
    Exit;
  ViewState := State;
  if HasViewBox then
  begin
    if (Box.Width <= 0) or (Box.Height <= 0) then
      Exit;
    ViewTransform := ViewBoxTransform(Box, ParseAspectRatio(ContentNode.Attribute('preserveAspectRatio')),
      X, Y, Width, Height);
    ViewState.Viewport.Width := Box.Width;
    ViewState.Viewport.Height := Box.Height;
  end
  else
  begin
    ViewTransform := TranslationTransform(X, Y);
    ViewState.Viewport.Width := Width;
    ViewState.Viewport.Height := Height;
  end;
  ViewState.Transform := CombineTransforms(State.Transform, ViewTransform);
  Overflow := LowerCase(Trim(ContentNode.Attribute('overflow')));
  Clipped := (ContentNode <> FDocument.Root) and (Overflow <> 'visible') and (Overflow <> 'auto') and
    IsAxisAligned(State.Transform);
  if Clipped then
  begin
    Corner := TransformPoint(State.Transform, X, Y);
    FarCorner := TransformPoint(State.Transform, X + Width, Y + Height);
    ClipRectangle.Left := Round(Min(Corner.X, FarCorner.X));
    ClipRectangle.Top := Round(Min(Corner.Y, FarCorner.Y));
    ClipRectangle.Right := Round(Max(Corner.X, FarCorner.X));
    ClipRectangle.Bottom := Round(Max(Corner.Y, FarCorner.Y));
    CopyRegion(FCanvas.Clip, Saved);
    NarrowCanvasClip(FCanvas, ClipRectangle);
  end;
  try
    RenderChildren(ContentNode, Style, ViewState);
  finally
    if Clipped then
      FCanvas.Clip := Saved;
  end;
end;

procedure TSvgRenderer.RenderUse(Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState);
var
  Target: TSvgNode;
  UseState: TSvgRenderState;
  TargetStyle: TCssComputedStyle;
  X, Y, Width, Height: Double;
  Box: TSvgViewBox;
  HasBox: Boolean;
  Ancestor: TSvgNode;
begin
  Target := FDocument.FindByReference(Node.Href);
  if (Target = nil) or not Target.IsElement or (FUseCount >= MaximumUseDepth) or OnUseStack(Target) then
    Exit;
  { A use may not refer to itself or an element it is inside. }
  Ancestor := Node;
  while Ancestor <> nil do
  begin
    if Ancestor = Target then
      Exit;
    Ancestor := Ancestor.Parent;
  end;
  X := AttributeLength(Node, 'x', DirectionHorizontal, State.Viewport, 0);
  Y := AttributeLength(Node, 'y', DirectionVertical, State.Viewport, 0);
  UseState := State;
  UseState.Transform := CombineTransforms(State.Transform, TranslationTransform(X, Y));
  UseState.Restyle := True;
  UseState.ParentStyle := Style;
  if FUseCount = Length(FUseStack) then
    SetLength(FUseStack, 2 * FUseCount + 4);
  FUseStack[FUseCount] := Target;
  Inc(FUseCount);
  try
    if Target.ElementKind in [SvgSymbol, SvgSvg] then
    begin
      TargetStyle := StyleFor(Target, UseState);
      if TargetStyle = nil then
        Exit;
      try
        if (Target.ElementKind = SvgSvg) and TargetStyle.IsDisplayNone then
          Exit;
        { The use's width and height win over the target's own. }
        Width := AttributeLength(Target, 'width', DirectionHorizontal, State.Viewport, State.Viewport.Width);
        Height := AttributeLength(Target, 'height', DirectionVertical, State.Viewport, State.Viewport.Height);
        Width := AttributeLength(Node, 'width', DirectionHorizontal, State.Viewport, Width);
        Height := AttributeLength(Node, 'height', DirectionVertical, State.Viewport, Height);
        HasBox := ParseViewBox(Target.Attribute('viewBox'), Box);
        if Target.ElementKind = SvgSvg then
          RenderViewport(Target, TargetStyle, ChildState(UseState, TargetStyle),
            AttributeLength(Target, 'x', DirectionHorizontal, State.Viewport, 0),
            AttributeLength(Target, 'y', DirectionVertical, State.Viewport, 0), Width, Height, HasBox, Box)
        else
          RenderViewport(Target, TargetStyle, ChildState(UseState, TargetStyle), 0, 0, Width, Height, HasBox, Box);
      finally
        TargetStyle.Release;
      end;
    end
    else
      RenderNode(Target, UseState);
  finally
    Dec(FUseCount);
  end;
end;

{ ---- layers, clips and masks ---- }

procedure TSvgRenderer.RenderInLayer(Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState;
  Opacity: Double; ClipNode, MaskNode: TSvgNode);
var
  Area, Wanted: TRectangle;
  Bounds: TPathBounds;
  Layer: TSurface;
  Saved: TCanvas;
  LayerState: TSvgRenderState;
  Mask, Other: TCoverageMask;
  HasMask: Boolean;
begin
  Area := RegionBounds(FCanvas.Clip);
  Bounds := ElementBounds(Node, Style, State.Transform, State, True);
  if Bounds.Empty then
    Exit;
  Wanted.Left := Floor(Bounds.Left) - 1;
  Wanted.Top := Floor(Bounds.Top) - 1;
  Wanted.Right := Ceil(Bounds.Right) + 1;
  Wanted.Bottom := Ceil(Bounds.Bottom) + 1;
  if not IntersectRectangles(Area, Wanted, Area) then
    Exit;
  if not CreateSurface(Layer, RectangleWidth(Area), RectangleHeight(Area), ColorTransparent) then
    Exit;
  try
    Saved := FCanvas;
    BeginCanvas(FCanvas, Layer);
    LayerState := State;
    LayerState.Transform := CombineTransforms(TranslationTransform(-Area.Left, -Area.Top), State.Transform);
    try
      RenderContent(Node, Style, LayerState, 1);
    finally
      FCanvas := Saved;
    end;
    HasMask := False;
    if ClipNode <> nil then
    begin
      Mask := BuildClipMask(ClipNode, Node, Style, State, Area, 0);
      HasMask := True;
    end;
    if MaskNode <> nil then
    begin
      Other := BuildLuminanceMask(MaskNode, Node, Style, State, Area);
      if HasMask then
        IntersectMasks(Mask, Other)
      else
        Mask := Other;
      HasMask := True;
    end;
    if HasMask then
      DrawSurfaceMasked(FCanvas, Layer, Area.Left, Area.Top, ByteOf(Opacity), @Mask)
    else
      DrawSurfaceMasked(FCanvas, Layer, Area.Left, Area.Top, ByteOf(Opacity), nil);
  finally
    FreeSurface(Layer);
  end;
end;

{ Mask's values become the union of themselves and Other's. }
procedure UniteMasks(var Mask: TCoverageMask; const Other: TCoverageMask);
var
  Index: Integer;
  A, B: LongWord;
begin
  for Index := 0 to High(Mask.Values) do
  begin
    A := Mask.Values[Index];
    B := Other.Values[Index];
    Mask.Values[Index] := A + B - (A * B + 127) div 255;
  end;
end;

function ObjectBoundingBoxTransform(const Box: TPathBounds): TAffineTransform;
begin
  Result := MakeTransform(Box.Right - Box.Left, 0, 0, Box.Bottom - Box.Top, Box.Left, Box.Top);
end;

function TSvgRenderer.BuildClipMask(ClipNode, Node: TSvgNode; Style: TCssComputedStyle;
  const State: TSvgRenderState; const Area: TRectangle; Depth: Integer): TCoverageMask;
var
  ClipTransform, ChildTransform: TAffineTransform;
  Box: TPathBounds;
  Child, Target: TSvgNode;
  ChildStyle, ClipStyle: TCssComputedStyle;
  ClipState: TSvgRenderState;
  Path: TPath;
  Shape: TCoverageShape;
  ChildMask: TCoverageMask;
  Runs: TSvgTextRuns;
  RunIndex: Integer;
  Inner: TSvgNode;
begin
  Result := UniformMask(Area, 0);
  if Depth > 8 then
    Exit;
  ClipTransform := State.Transform;
  if LowerCase(ClipNode.Attribute('clipPathUnits')) = 'objectboundingbox' then
  begin
    Box := ElementBounds(Node, Style, IdentityTransform, State, False);
    if Box.Empty or (Box.Right <= Box.Left) or (Box.Bottom <= Box.Top) then
      Exit;
    ClipTransform := CombineTransforms(ClipTransform, ObjectBoundingBoxTransform(Box));
  end;
  ClipTransform := CombineTransforms(ClipTransform, ElementTransform(ClipNode));
  ClipStyle := ClipNode.Style;
  ClipState := State;
  ClipState.Restyle := False;
  if ClipStyle <> nil then
    ClipState := ChildState(ClipState, ClipStyle);
  Child := ClipNode.FirstElementChild;
  while Child <> nil do
  begin
    Target := Child;
    ChildTransform := CombineTransforms(ClipTransform, ElementTransform(Child));
    { A use in a clip path stands for its target shape. }
    if Child.IsKind(SvgUse) then
    begin
      Target := FDocument.FindByReference(Child.Href);
      if Target <> nil then
      begin
        ChildTransform := CombineTransforms(ChildTransform, TranslationTransform(
          AttributeLength(Child, 'x', DirectionHorizontal, State.Viewport, 0),
          AttributeLength(Child, 'y', DirectionVertical, State.Viewport, 0)));
        ChildTransform := CombineTransforms(ChildTransform, ElementTransform(Target));
      end;
    end;
    if (Target <> nil) and (IsShapeKind(Target.ElementKind) or Target.IsKind(SvgText)) then
    begin
      ChildStyle := StyleFor(Target, ClipState);
      if (ChildStyle <> nil) and not ChildStyle.IsDisplayNone and IsStyleVisible(ChildStyle) then
      begin
        BeginShape(Shape);
        if Target.IsKind(SvgText) then
        begin
          FTextRestyle := False;
          Runs := LayoutText(Target, ChildStyle, @TextChildStyle, FDocument.FontSource,
            ChildState(ClipState, ChildStyle).Viewport);
          for RunIndex := 0 to High(Runs) do
            AddPolylinesToShape(Shape, FlattenPath(Runs[RunIndex].Path, ChildTransform, FillTolerance));
          FreeTextRuns(Runs);
        end
        else
        begin
          BeginPath(Path);
          if BuildShapePath(Target, ChildState(ClipState, ChildStyle).Viewport, Path) then
            AddPolylinesToShape(Shape, FlattenPath(Path, ChildTransform, FillTolerance));
        end;
        ChildMask := MaskFromShape(Shape, FillRuleOf(ChildStyle, cpClipRule), Area);
        if ChildMask.Values <> nil then
          UniteMasks(Result, ChildMask);
      end;
      if ChildStyle <> nil then
        ChildStyle.Release;
    end;
    Child := Child.NextElementSibling;
  end;
  { A clip path may itself be clipped. }
  if ClipStyle <> nil then
  begin
    Inner := ReferencedNode(FDocument, ReferenceOfUrl(ClipStyle, cpClipPath), SvgClipPath);
    if (Inner <> nil) and (Inner <> ClipNode) then
      IntersectMasks(Result, BuildClipMask(Inner, Node, Style, State, Area, Depth + 1));
  end;
end;

function FractionAttribute(Node: TSvgNode; const Name: string; Default: Double): Double;
begin
  if not ParseFraction(Node.Attribute(Name), Result) then
    Result := Default;
end;

function TSvgRenderer.BuildLuminanceMask(MaskNode, Node: TSvgNode; Style: TCssComputedStyle;
  const State: TSvgRenderState; const Area: TRectangle): TCoverageMask;
var
  Box: TPathBounds;
  NeedsBox: Boolean;
  UserUnits, ContentInBox: Boolean;
  RegionX, RegionY, RegionWidth, RegionHeight: Double;
  Layer: TSurface;
  Saved: TCanvas;
  MaskState: TSvgRenderState;
  ContentTransform: TAffineTransform;
  Row, Column, Index: Integer;
  Line: PLongWord;
  Color: TColor;
  Luminance: Double;
  AlphaOnly: Boolean;
  RegionShape: TCoverageShape;
  RegionPath: TPath;
  MaskStyle: TCssComputedStyle;
begin
  Result := UniformMask(Area, 0);
  UserUnits := LowerCase(MaskNode.Attribute('maskUnits')) = 'userspaceonuse';
  ContentInBox := LowerCase(MaskNode.Attribute('maskContentUnits')) = 'objectboundingbox';
  NeedsBox := not UserUnits or ContentInBox;
  Box := EmptyBounds;
  if NeedsBox then
  begin
    Box := ElementBounds(Node, Style, IdentityTransform, State, False);
    if Box.Empty or (Box.Right <= Box.Left) or (Box.Bottom <= Box.Top) then
      Exit;
  end;
  if UserUnits then
  begin
    RegionX := AttributeLength(MaskNode, 'x', DirectionHorizontal, State.Viewport, -0.1 * State.Viewport.Width);
    RegionY := AttributeLength(MaskNode, 'y', DirectionVertical, State.Viewport, -0.1 * State.Viewport.Height);
    RegionWidth := AttributeLength(MaskNode, 'width', DirectionHorizontal, State.Viewport, 1.2 * State.Viewport.Width);
    RegionHeight := AttributeLength(MaskNode, 'height', DirectionVertical, State.Viewport,
      1.2 * State.Viewport.Height);
  end
  else
  begin
    RegionX := Box.Left + FractionAttribute(MaskNode, 'x', -0.1) * (Box.Right - Box.Left);
    RegionY := Box.Top + FractionAttribute(MaskNode, 'y', -0.1) * (Box.Bottom - Box.Top);
    RegionWidth := FractionAttribute(MaskNode, 'width', 1.2) * (Box.Right - Box.Left);
    RegionHeight := FractionAttribute(MaskNode, 'height', 1.2) * (Box.Bottom - Box.Top);
  end;
  if (RegionWidth <= 0) or (RegionHeight <= 0) then
    Exit;
  ContentTransform := State.Transform;
  if ContentInBox then
    ContentTransform := CombineTransforms(ContentTransform, ObjectBoundingBoxTransform(Box));
  if not CreateSurface(Layer, RectangleWidth(Area), RectangleHeight(Area), ColorTransparent) then
    Exit;
  try
    Saved := FCanvas;
    BeginCanvas(FCanvas, Layer);
    MaskState := State;
    MaskState.Restyle := False;
    MaskState.Transform := CombineTransforms(TranslationTransform(-Area.Left, -Area.Top), ContentTransform);
    MaskStyle := MaskNode.Style;
    try
      if MaskStyle <> nil then
        RenderChildren(MaskNode, MaskStyle, MaskState);
    finally
      FCanvas := Saved;
    end;
    AlphaOnly := LowerCase(Trim(MaskNode.Attribute('mask-type'))) = 'alpha';
    Index := 0;
    for Row := 0 to Layer.Height - 1 do
    begin
      Line := SurfaceLine(Layer, Row);
      for Column := 0 to Layer.Width - 1 do
      begin
        Color := Line[Column];
        if AlphaOnly then
          Result.Values[Index] := AlphaOf(Color)
        else
        begin
          Luminance := 0.2125 * RedOf(Color) + 0.7154 * GreenOf(Color) + 0.0721 * BlueOf(Color);
          Result.Values[Index] := Round(Luminance * AlphaOf(Color) / 255);
        end;
        Inc(Index);
      end;
    end;
  finally
    FreeSurface(Layer);
  end;
  BeginPath(RegionPath);
  PathAddRectangle(RegionPath, RegionX, RegionY, RegionWidth, RegionHeight);
  BeginShape(RegionShape);
  AddPolylinesToShape(RegionShape, FlattenPath(RegionPath, State.Transform, FillTolerance));
  IntersectMasks(Result, MaskFromShape(RegionShape, FillRuleNonZero, Area));
end;

{ ---- bounds ---- }

function InflateBounds(const Bounds: TPathBounds; Amount: Double): TPathBounds;
begin
  Result := Bounds;
  if Bounds.Empty then
    Exit;
  Result.Left := Bounds.Left - Amount;
  Result.Top := Bounds.Top - Amount;
  Result.Right := Bounds.Right + Amount;
  Result.Bottom := Bounds.Bottom + Amount;
end;

function StrokeReach(Style: TCssComputedStyle; const State: TSvgRenderState; const Transform: TAffineTransform): Double;
var
  Stroke: TStrokeStyle;
begin
  Result := 0;
  if PaintOf(Style, cpStroke).Kind = SvgPaintNone then
    Exit;
  Stroke := StrokeStyleOf(Style, State.Viewport);
  Result := Stroke.Width / 2 * Max(Stroke.MiterLimit, 1.5);
  if not IsNonScalingStroke(Style) then
    Result := Result * Max(Sqrt(Sqr(Transform.A) + Sqr(Transform.B)), Sqrt(Sqr(Transform.C) + Sqr(Transform.D)));
end;

function TSvgRenderer.ChildBounds(Node: TSvgNode; const Transform: TAffineTransform; const State: TSvgRenderState;
  IncludeStroke: Boolean): TPathBounds;
var
  Child: TSvgNode;
  ChildStyle: TCssComputedStyle;
begin
  Result := EmptyBounds;
  Child := Node.FirstElementChild;
  while Child <> nil do
  begin
    if IsRenderedKind(Child.ElementKind) then
    begin
      ChildStyle := StyleFor(Child, State);
      if ChildStyle <> nil then
      begin
        if not ChildStyle.IsDisplayNone then
          UniteBounds(Result, ElementBounds(Child, ChildStyle, CombineTransforms(Transform, ElementTransform(Child)),
            ChildState(State, ChildStyle), IncludeStroke));
        ChildStyle.Release;
      end;
    end;
    Child := Child.NextElementSibling;
  end;
end;

function TSvgRenderer.ElementBounds(Node: TSvgNode; Style: TCssComputedStyle; const Transform: TAffineTransform;
  const State: TSvgRenderState; IncludeStroke: Boolean): TPathBounds;
var
  Path: TPath;
  Runs: TSvgTextRuns;
  Index: Integer;
  Inner: TSvgRenderState;
  Target: TSvgNode;
  Width, Height: Double;
begin
  Result := EmptyBounds;
  if FDepth >= MaximumDepth then
    Exit;
  Inc(FDepth);
  try
    Inner := ChildState(State, Style);
    case Node.ElementKind of
      SvgG, SvgAnchor, SvgSwitch:
        Result := ChildBounds(Node, Transform, Inner, IncludeStroke);
      SvgSvg:
        if Node = FDocument.Root then
          Result := RectangleBounds(0, 0, State.Viewport.Width, State.Viewport.Height, Transform)
        else
          Result := RectangleBounds(AttributeLength(Node, 'x', DirectionHorizontal, State.Viewport, 0),
            AttributeLength(Node, 'y', DirectionVertical, State.Viewport, 0),
            AttributeLength(Node, 'width', DirectionHorizontal, State.Viewport, State.Viewport.Width),
            AttributeLength(Node, 'height', DirectionVertical, State.Viewport, State.Viewport.Height), Transform);
      SvgUse:
        begin
          Target := FDocument.FindByReference(Node.Href);
          if (Target = nil) or OnUseStack(Target) or (FUseCount >= MaximumUseDepth) then
            Exit;
          if Target.ElementKind in [SvgSymbol, SvgSvg] then
          begin
            Width := AttributeLength(Node, 'width', DirectionHorizontal, State.Viewport, State.Viewport.Width);
            Height := AttributeLength(Node, 'height', DirectionVertical, State.Viewport, State.Viewport.Height);
            Result := RectangleBounds(AttributeLength(Node, 'x', DirectionHorizontal, State.Viewport, 0),
              AttributeLength(Node, 'y', DirectionVertical, State.Viewport, 0), Width, Height, Transform);
          end
          else
          begin
            if Length(FUseStack) <= FUseCount then
              SetLength(FUseStack, FUseCount + 4);
            FUseStack[FUseCount] := Target;
            Inc(FUseCount);
            try
              Inner.Restyle := True;
              Inner.Transform := CombineTransforms(Transform, TranslationTransform(
                AttributeLength(Node, 'x', DirectionHorizontal, State.Viewport, 0),
                AttributeLength(Node, 'y', DirectionVertical, State.Viewport, 0)));
              { The target is bounded as the use's only child. }
              Result := EmptyBounds;
              Style := StyleFor(Target, Inner);
              if Style <> nil then
              begin
                Result := ElementBounds(Target, Style, CombineTransforms(Inner.Transform, ElementTransform(Target)),
                  ChildState(Inner, Style), IncludeStroke);
                Style.Release;
              end;
            finally
              Dec(FUseCount);
            end;
          end;
        end;
      SvgText:
        begin
          FTextRestyle := State.Restyle;
          Runs := LayoutText(Node, Style, @TextChildStyle, FDocument.FontSource, Inner.Viewport);
          for Index := 0 to High(Runs) do
            UniteBounds(Result, PathTightBounds(Runs[Index].Path, Transform));
          FreeTextRuns(Runs);
          if IncludeStroke then
            Result := InflateBounds(Result, StrokeReach(Style, Inner, Transform));
        end;
      SvgImage:
        Result := RectangleBounds(AttributeLength(Node, 'x', DirectionHorizontal, State.Viewport, 0),
          AttributeLength(Node, 'y', DirectionVertical, State.Viewport, 0),
          AttributeLength(Node, 'width', DirectionHorizontal, State.Viewport, State.Viewport.Width),
          AttributeLength(Node, 'height', DirectionVertical, State.Viewport, State.Viewport.Height), Transform);
      else
        if IsShapeKind(Node.ElementKind) then
        begin
          BeginPath(Path);
          if BuildShapePath(Node, Inner.Viewport, Path) then
          begin
            Result := PathTightBounds(Path, Transform);
            if IncludeStroke then
              Result := InflateBounds(Result, StrokeReach(Style, Inner, Transform));
          end;
        end;
    end;
  finally
    Dec(FDepth);
  end;
end;

{ ---- paints ---- }

{ The node along a paint server's href chain (itself first) that has
  the attribute, nil if none does. }
function ServerWithAttribute(Document: TSvgDocument; Server: TSvgNode; const Name: string): TSvgNode;
var
  Steps: Integer;
begin
  Result := Server;
  Steps := 0;
  while (Result <> nil) and (Steps < 16) do
  begin
    if Result.HasAttribute(Name) then
      Exit;
    Result := Document.FindByReference(Result.Href);
    if (Result <> nil) and not (Result.ElementKind in [SvgLinearGradient, SvgRadialGradient, SvgPattern]) then
      Result := nil;
    Inc(Steps);
  end;
  Result := nil;
end;

function ServerAttribute(Document: TSvgDocument; Server: TSvgNode; const Name: string): string;
var
  Holder: TSvgNode;
begin
  Holder := ServerWithAttribute(Document, Server, Name);
  if Holder <> nil then
    Result := Holder.Attribute(Name)
  else
    Result := '';
end;

{ The first server along the chain with children of the kind. }
function ServerWithChildren(Document: TSvgDocument; Server: TSvgNode; Kind: TSvgElementKind;
  AnyElement: Boolean): TSvgNode;
var
  Steps: Integer;
  Child: TSvgNode;
begin
  Result := Server;
  Steps := 0;
  while (Result <> nil) and (Steps < 16) do
  begin
    Child := Result.FirstElementChild;
    while Child <> nil do
    begin
      if AnyElement or Child.IsKind(Kind) then
        Exit;
      Child := Child.NextElementSibling;
    end;
    Result := Document.FindByReference(Result.Href);
    if (Result <> nil) and not (Result.ElementKind in [SvgLinearGradient, SvgRadialGradient, SvgPattern]) then
      Result := nil;
    Inc(Steps);
  end;
  Result := nil;
end;

function GradientStops(Document: TSvgDocument; Server: TSvgNode): TGradientStops;
var
  Holder, Child: TSvgNode;
  Offset, Last: Double;
  Color: TColor;
begin
  Result := nil;
  Holder := ServerWithChildren(Document, Server, SvgStop, False);
  if Holder = nil then
    Exit;
  Last := 0;
  Child := Holder.FirstElementChild;
  while Child <> nil do
  begin
    if Child.IsKind(SvgStop) then
    begin
      if not ParseFraction(Child.Attribute('offset'), Offset) then
        Offset := 0;
      Offset := Max(0, Min(1, Offset));
      if Offset < Last then
        Offset := Last;
      Last := Offset;
      if Child.Style <> nil then
        Color := StopColorOf(Child.Style)
      else
        Color := ColorBlack;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)].Offset := Offset;
      Result[High(Result)].Color := Color;
    end;
    Child := Child.NextElementSibling;
  end;
end;

function GradientCoordinate(Document: TSvgDocument; Server: TSvgNode; const Name: string; InBox: Boolean;
  Direction: TSvgLengthDirection; const Viewport: TSvgViewport; Default: Double): Double;
var
  Text: string;
  Length: TSvgLength;
begin
  Text := ServerAttribute(Document, Server, Name);
  if Text = '' then
    Exit(Default);
  if InBox then
  begin
    if not ParseFraction(Text, Result) then
      Result := Default;
    Exit;
  end;
  if ParseLength(Text, Length) then
    Result := ResolveLength(Length, Direction, Viewport)
  else
    Result := Default;
end;

function TSvgRenderer.GradientPaint(Server: TSvgNode; const State: TSvgRenderState; const BoundingBox: TPathBounds;
  out Paint: TPaint): Boolean;
var
  Stops: TGradientStops;
  InBox: Boolean;
  Placement, GradientTransform, Inverse: TAffineTransform;
  Spread: TSpreadMethod;
  SpreadText: string;
  X1, Y1, X2, Y2, CentreX, CentreY, Radius, FocusX, FocusY, FocusRadius: Double;
  Distance: Double;
  Viewport: TSvgViewport;
  Color: TColor;
begin
  Result := False;
  Paint := Default(TPaint);
  Stops := GradientStops(FDocument, Server);
  if Length(Stops) = 0 then
    Exit;
  if Length(Stops) = 1 then
  begin
    Paint := SolidPaint(Stops[0].Color);
    Exit(True);
  end;
  InBox := LowerCase(ServerAttribute(FDocument, Server, 'gradientUnits')) <> 'userspaceonuse';
  Placement := State.Transform;
  if InBox then
  begin
    if BoundingBox.Empty or (BoundingBox.Right <= BoundingBox.Left) or (BoundingBox.Bottom <= BoundingBox.Top) then
      Exit;
    Placement := CombineTransforms(Placement, ObjectBoundingBoxTransform(BoundingBox));
  end;
  if not ParseTransformList(ServerAttribute(FDocument, Server, 'gradientTransform'), GradientTransform) then
    GradientTransform := IdentityTransform;
  Placement := CombineTransforms(Placement, GradientTransform);
  if not InvertTransform(Placement, Inverse) then
    Exit;
  SpreadText := LowerCase(ServerAttribute(FDocument, Server, 'spreadMethod'));
  if SpreadText = 'reflect' then
    Spread := SpreadReflect
  else if SpreadText = 'repeat' then
    Spread := SpreadRepeat
  else
    Spread := SpreadPad;
  Viewport := State.Viewport;
  if Server.IsKind(SvgLinearGradient) then
  begin
    X1 := GradientCoordinate(FDocument, Server, 'x1', InBox, DirectionHorizontal, Viewport, 0);
    Y1 := GradientCoordinate(FDocument, Server, 'y1', InBox, DirectionVertical, Viewport, 0);
    if InBox then
      X2 := GradientCoordinate(FDocument, Server, 'x2', InBox, DirectionHorizontal, Viewport, 1)
    else
      X2 := GradientCoordinate(FDocument, Server, 'x2', InBox, DirectionHorizontal, Viewport, Viewport.Width);
    Y2 := GradientCoordinate(FDocument, Server, 'y2', InBox, DirectionVertical, Viewport, 0);
    Paint := LinearGradientPaint(X1, Y1, X2, Y2, Stops, Spread, Inverse);
  end
  else
  begin
    if InBox then
    begin
      CentreX := GradientCoordinate(FDocument, Server, 'cx', True, DirectionHorizontal, Viewport, 0.5);
      CentreY := GradientCoordinate(FDocument, Server, 'cy', True, DirectionVertical, Viewport, 0.5);
      Radius := GradientCoordinate(FDocument, Server, 'r', True, DirectionOther, Viewport, 0.5);
    end
    else
    begin
      CentreX := GradientCoordinate(FDocument, Server, 'cx', False, DirectionHorizontal, Viewport, Viewport.Width / 2);
      CentreY := GradientCoordinate(FDocument, Server, 'cy', False, DirectionVertical, Viewport, Viewport.Height / 2);
      Radius := GradientCoordinate(FDocument, Server, 'r', False, DirectionOther, Viewport,
        Sqrt((Sqr(Viewport.Width) + Sqr(Viewport.Height)) / 2) / 2);
    end;
    FocusX := GradientCoordinate(FDocument, Server, 'fx', InBox, DirectionHorizontal, Viewport, CentreX);
    FocusY := GradientCoordinate(FDocument, Server, 'fy', InBox, DirectionVertical, Viewport, CentreY);
    FocusRadius := GradientCoordinate(FDocument, Server, 'fr', InBox, DirectionOther, Viewport, 0);
    if Radius <= 0 then
    begin
      { A gradient of no size shows its last colour. }
      GradientIsSolid(Stops, Color);
      Paint := SolidPaint(Stops[High(Stops)].Color);
      Exit(True);
    end;
    { A focal point outside the circle moves onto its edge (SVG 1.1). }
    Distance := Sqrt(Sqr(FocusX - CentreX) + Sqr(FocusY - CentreY));
    if (FocusRadius = 0) and (Distance > Radius * 0.999) then
    begin
      FocusX := CentreX + (FocusX - CentreX) * Radius * 0.999 / Distance;
      FocusY := CentreY + (FocusY - CentreY) * Radius * 0.999 / Distance;
    end;
    Paint := RadialGradientPaint(CentreX, CentreY, Radius, FocusX, FocusY, FocusRadius, Stops, Spread, Inverse);
  end;
  Result := True;
end;

function TSvgRenderer.PatternPaintOf(Server: TSvgNode; const State: TSvgRenderState; const BoundingBox: TPathBounds;
  out Paint: TPaint; out Tile: TSurface): Boolean;
var
  InBox, ContentInBox: Boolean;
  TileX, TileY, TileWidth, TileHeight: Double;
  PatternTransform, PatternToSurface, ContentToTile, TileToSurface, Inverse: TAffineTransform;
  ScaleX, ScaleY: Double;
  PixelWidth, PixelHeight: Integer;
  ContentHolder: TSvgNode;
  Box: TSvgViewBox;
  HasBox: Boolean;
  ViewBoxHolder: TSvgNode;
  Saved: TCanvas;
  TileState: TSvgRenderState;
  BoxValid: Boolean;
begin
  Result := False;
  Paint := Default(TPaint);
  Tile := Default(TSurface);
  if FDepth >= MaximumDepth div 2 then
    Exit;
  InBox := LowerCase(ServerAttribute(FDocument, Server, 'patternUnits')) <> 'userspaceonuse';
  ContentInBox := LowerCase(ServerAttribute(FDocument, Server, 'patternContentUnits')) = 'objectboundingbox';
  BoxValid := not BoundingBox.Empty and (BoundingBox.Right > BoundingBox.Left) and
    (BoundingBox.Bottom > BoundingBox.Top);
  if (InBox or ContentInBox) and not BoxValid then
    Exit;
  if InBox then
  begin
    TileX := BoundingBox.Left + GradientCoordinate(FDocument, Server, 'x', True, DirectionHorizontal, State.Viewport, 0) *
      (BoundingBox.Right - BoundingBox.Left);
    TileY := BoundingBox.Top + GradientCoordinate(FDocument, Server, 'y', True, DirectionVertical, State.Viewport, 0) *
      (BoundingBox.Bottom - BoundingBox.Top);
    TileWidth := GradientCoordinate(FDocument, Server, 'width', True, DirectionHorizontal, State.Viewport, 0) *
      (BoundingBox.Right - BoundingBox.Left);
    TileHeight := GradientCoordinate(FDocument, Server, 'height', True, DirectionVertical, State.Viewport, 0) *
      (BoundingBox.Bottom - BoundingBox.Top);
  end
  else
  begin
    TileX := GradientCoordinate(FDocument, Server, 'x', False, DirectionHorizontal, State.Viewport, 0);
    TileY := GradientCoordinate(FDocument, Server, 'y', False, DirectionVertical, State.Viewport, 0);
    TileWidth := GradientCoordinate(FDocument, Server, 'width', False, DirectionHorizontal, State.Viewport, 0);
    TileHeight := GradientCoordinate(FDocument, Server, 'height', False, DirectionVertical, State.Viewport, 0);
  end;
  if (TileWidth <= 0) or (TileHeight <= 0) then
    Exit;
  ContentHolder := ServerWithChildren(FDocument, Server, SvgUnknown, True);
  if ContentHolder = nil then
    Exit;
  if not ParseTransformList(ServerAttribute(FDocument, Server, 'patternTransform'), PatternTransform) then
    PatternTransform := IdentityTransform;
  PatternToSurface := CombineTransforms(State.Transform, PatternTransform);
  ScaleX := Sqrt(Sqr(PatternToSurface.A) + Sqr(PatternToSurface.B));
  ScaleY := Sqrt(Sqr(PatternToSurface.C) + Sqr(PatternToSurface.D));
  PixelWidth := Max(1, Min(MaximumTileSide, Ceil(TileWidth * ScaleX - 0.001)));
  PixelHeight := Max(1, Min(MaximumTileSide, Ceil(TileHeight * ScaleY - 0.001)));
  ViewBoxHolder := ServerWithAttribute(FDocument, Server, 'viewBox');
  HasBox := (ViewBoxHolder <> nil) and ParseViewBox(ViewBoxHolder.Attribute('viewBox'), Box) and (Box.Width > 0) and
    (Box.Height > 0);
  ContentToTile := ScalingTransform(PixelWidth / TileWidth, PixelHeight / TileHeight);
  if HasBox then
    ContentToTile := CombineTransforms(ContentToTile, ViewBoxTransform(Box,
      ParseAspectRatio(ServerAttribute(FDocument, Server, 'preserveAspectRatio')), 0, 0, TileWidth, TileHeight))
  else
  begin
    ContentToTile := CombineTransforms(ContentToTile, TranslationTransform(-TileX, -TileY));
    if ContentInBox then
      ContentToTile := CombineTransforms(ContentToTile, ObjectBoundingBoxTransform(BoundingBox));
  end;
  TileToSurface := CombineTransforms(PatternToSurface, CombineTransforms(TranslationTransform(TileX, TileY),
    ScalingTransform(TileWidth / PixelWidth, TileHeight / PixelHeight)));
  if not InvertTransform(TileToSurface, Inverse) then
    Exit;
  if not CreateSurface(Tile, PixelWidth, PixelHeight, ColorTransparent) then
    Exit;
  Saved := FCanvas;
  BeginCanvas(FCanvas, Tile);
  TileState := State;
  TileState.Restyle := False;
  TileState.Transform := ContentToTile;
  try
    if ContentHolder.Style <> nil then
      RenderChildren(ContentHolder, ContentHolder.Style, TileState);
  finally
    FCanvas := Saved;
  end;
  Paint := PatternPaint(Tile, Inverse);
  Result := True;
end;

function TSvgRenderer.ResolvePaint(Style: TCssComputedStyle; IsStroke: Boolean; const State: TSvgRenderState;
  const BoundingBox: TPathBounds; out Paint: TPaint; out Tile: TSurface): Boolean;
var
  Spec: TSvgPaintSpec;
  Server: TSvgNode;
begin
  Result := False;
  Tile := Default(TSurface);
  Paint := Default(TPaint);
  if IsStroke then
    Spec := PaintOf(Style, cpStroke)
  else
    Spec := PaintOf(Style, cpFill);
  case Spec.Kind of
    SvgPaintColor:
      begin
        Paint := SolidPaint(Spec.Color);
        Result := True;
      end;
    SvgPaintServer:
      begin
        Server := FDocument.FindByReference(Spec.Reference);
        if (Server <> nil) and (Server.ElementKind in [SvgLinearGradient, SvgRadialGradient]) then
          Result := GradientPaint(Server, State, BoundingBox, Paint)
        else if (Server <> nil) and Server.IsKind(SvgPattern) then
          Result := PatternPaintOf(Server, State, BoundingBox, Paint, Tile)
        else if Spec.FallbackKind = SvgPaintColor then
        begin
          Paint := SolidPaint(Spec.FallbackColor);
          Result := True;
        end;
      end;
  end;
end;

{ ---- drawing ---- }

procedure TSvgRenderer.FillPath(Style: TCssComputedStyle; const State: TSvgRenderState; const Path: TPath;
  Opacity: Double; const BoundingBox: TPathBounds);
var
  Paint: TPaint;
  Tile: TSurface;
  Shape: TCoverageShape;
begin
  if PaintOf(Style, cpFill).Kind = SvgPaintNone then
    Exit;
  Opacity := Opacity * OpacityOf(Style, cpFillOpacity);
  if Opacity <= 0 then
    Exit;
  if not ResolvePaint(Style, False, State, BoundingBox, Paint, Tile) then
    Exit;
  try
    BeginShape(Shape);
    AddPolylinesToShape(Shape, FlattenPath(Path, State.Transform, FillTolerance));
    FillShapeWithPaint(FCanvas, Shape, FillRuleOf(Style, cpFillRule), Paint, ByteOf(Opacity), nil);
  finally
    if Tile.Pixels <> nil then
      FreeSurface(Tile);
  end;
end;

procedure TSvgRenderer.StrokePath(Style: TCssComputedStyle; const State: TSvgRenderState; const Path: TPath;
  Opacity: Double; const BoundingBox: TPathBounds);
var
  Paint: TPaint;
  Tile: TSurface;
  Shape: TCoverageShape;
  Stroke: TStrokeStyle;
  Lines, Pieces: TPolylines;
  Dashes: TSvgDashes;
  Scale, Tolerance: Double;
  NonScaling: Boolean;
begin
  if PaintOf(Style, cpStroke).Kind = SvgPaintNone then
    Exit;
  Stroke := StrokeStyleOf(Style, State.Viewport);
  if Stroke.Width <= 0 then
    Exit;
  Opacity := Opacity * OpacityOf(Style, cpStrokeOpacity);
  if Opacity <= 0 then
    Exit;
  Scale := TransformScale(State.Transform);
  if Scale <= 1E-9 then
    Exit;
  if not ResolvePaint(Style, True, State, BoundingBox, Paint, Tile) then
    Exit;
  try
    NonScaling := IsNonScalingStroke(Style);
    if NonScaling then
    begin
      Tolerance := FillTolerance;
      Lines := FlattenPath(Path, State.Transform, Tolerance);
    end
    else
    begin
      Tolerance := FillTolerance / Scale;
      Lines := FlattenPath(Path, IdentityTransform, Tolerance);
    end;
    Dashes := DashesOf(Style, State.Viewport);
    if Dashes <> nil then
      Lines := DashPolylines(Lines, Dashes, DashOffsetOf(Style, State.Viewport));
    Pieces := StrokePolylines(Lines, Stroke, Tolerance);
    if not NonScaling then
      TransformPolylines(Pieces, State.Transform);
    BeginShape(Shape);
    AddPolylinesToShape(Shape, Pieces);
    FillShapeWithPaint(FCanvas, Shape, FillRuleNonZero, Paint, ByteOf(Opacity), nil);
  finally
    if Tile.Pixels <> nil then
      FreeSurface(Tile);
  end;
end;

procedure TSvgRenderer.DrawPath(Style: TCssComputedStyle; const State: TSvgRenderState; const Path: TPath;
  Opacity: Double; const BoundingBox: TPathBounds);
begin
  if StrokeBeforeFill(Style) then
  begin
    StrokePath(Style, State, Path, Opacity, BoundingBox);
    FillPath(Style, State, Path, Opacity, BoundingBox);
  end
  else
  begin
    FillPath(Style, State, Path, Opacity, BoundingBox);
    StrokePath(Style, State, Path, Opacity, BoundingBox);
  end;
end;

procedure TSvgRenderer.RenderShape(Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState;
  Opacity: Double);
var
  Path: TPath;
begin
  if not IsStyleVisible(Style) then
    Exit;
  BeginPath(Path);
  if not BuildShapePath(Node, State.Viewport, Path) then
    Exit;
  DrawPath(Style, State, Path, Opacity, PathTightBounds(Path, IdentityTransform));
end;

procedure TSvgRenderer.RenderText(Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState;
  Opacity: Double);
var
  Runs: TSvgTextRuns;
  Index: Integer;
  Box: TPathBounds;
begin
  FTextRestyle := State.Restyle;
  Runs := LayoutText(Node, Style, @TextChildStyle, FDocument.FontSource, State.Viewport);
  try
    Box := EmptyBounds;
    for Index := 0 to High(Runs) do
      UniteBounds(Box, PathTightBounds(Runs[Index].Path, IdentityTransform));
    for Index := 0 to High(Runs) do
      if IsStyleVisible(Runs[Index].Style) and (Runs[Index].Path.Count > 0) then
        DrawPath(Runs[Index].Style, State, Runs[Index].Path, Opacity, Box);
  finally
    FreeTextRuns(Runs);
  end;
end;

procedure TSvgRenderer.RenderImage(Node: TSvgNode; Style: TCssComputedStyle; const State: TSvgRenderState;
  Opacity: Double);
var
  Image, Pixels: TImage;
  X, Y, Width, Height: Double;
  NaturalWidth, NaturalHeight: Double;
  AspectRatio: TSvgAspectRatio;
  Box: TSvgViewBox;
  ImageToUser, ImageToSurface, Inverse: TAffineTransform;
  Scale: Double;
  Paint: TPaint;
  Path: TPath;
  Shape: TCoverageShape;
begin
  if not IsStyleVisible(Style) then
    Exit;
  Image := FDocument.Images.ImageFor(Node.Href);
  if (Image = nil) or (Image.Width <= 0) or (Image.Height <= 0) then
    Exit;
  NaturalWidth := Image.Width;
  NaturalHeight := Image.Height;
  X := AttributeLength(Node, 'x', DirectionHorizontal, State.Viewport, 0);
  Y := AttributeLength(Node, 'y', DirectionVertical, State.Viewport, 0);
  Width := AttributeLength(Node, 'width', DirectionHorizontal, State.Viewport, -1);
  Height := AttributeLength(Node, 'height', DirectionVertical, State.Viewport, -1);
  if (Width < 0) and (Height < 0) then
  begin
    Width := NaturalWidth;
    Height := NaturalHeight;
  end
  else if Width < 0 then
    Width := Height * NaturalWidth / NaturalHeight
  else if Height < 0 then
    Height := Width * NaturalHeight / NaturalWidth;
  if (Width <= 0) or (Height <= 0) then
    Exit;
  AspectRatio := ParseAspectRatio(Node.Attribute('preserveAspectRatio'));
  Box.X := 0;
  Box.Y := 0;
  Box.Width := NaturalWidth;
  Box.Height := NaturalHeight;
  ImageToUser := ViewBoxTransform(Box, AspectRatio, X, Y, Width, Height);
  ImageToSurface := CombineTransforms(State.Transform, ImageToUser);
  Pixels := Image;
  if Image is TScalableImage then
  begin
    { A vector picture is drawn again at the size it is shown. }
    Scale := TransformScale(ImageToSurface);
    Pixels := TScalableImage(Image).RenderedAt(Max(1, Round(NaturalWidth * Scale)),
      Max(1, Round(NaturalHeight * Scale)));
    if Pixels = nil then
      Pixels := Image;
    ImageToSurface := CombineTransforms(ImageToSurface, ScalingTransform(NaturalWidth / Pixels.Width,
      NaturalHeight / Pixels.Height));
  end;
  if not InvertTransform(ImageToSurface, Inverse) then
    Exit;
  Paint := PatternPaint(ImageSurface(Pixels), Inverse);
  Paint.TileRepeat := False;
  Paint.Smooth := not KeywordIn(Style.Keyword(cpImageRendering), [kwPixelated, kwCrispEdges, kwOptimizespeed]);
  BeginPath(Path);
  { What shows: the picture, within the viewport when it is sliced. }
  if AspectRatio.Slice then
    PathAddRectangle(Path, X, Y, Width, Height)
  else
    PathAppend(Path, RectanglePath(0, 0, NaturalWidth, NaturalHeight), ImageToUser);
  BeginShape(Shape);
  AddPolylinesToShape(Shape, FlattenPath(Path, State.Transform, FillTolerance));
  FillShapeWithPaint(FCanvas, Shape, FillRuleNonZero, Paint, ByteOf(Opacity), nil);
end;

{ ---- the document ---- }

procedure TSvgRenderer.Render(const Surface: TSurface; ViewportWidth, ViewportHeight: Double;
  SynthesizeViewBox: Boolean);
var
  State: TSvgRenderState;
  Root: TSvgNode;
begin
  Root := FDocument.Root;
  if (Root = nil) or (Root.Style = nil) or (ViewportWidth <= 0) or (ViewportHeight <= 0) or
     (Surface.Width <= 0) or (Surface.Height <= 0) then
    Exit;
  BeginCanvas(FCanvas, Surface);
  FHasRootViewBox := ParseViewBox(Root.Attribute('viewBox'), FRootViewBox);
  if not FHasRootViewBox and SynthesizeViewBox and FDocument.HasNaturalWidth and FDocument.HasNaturalHeight then
  begin
    FRootViewBox.X := 0;
    FRootViewBox.Y := 0;
    FRootViewBox.Width := FDocument.NaturalWidth;
    FRootViewBox.Height := FDocument.NaturalHeight;
    FHasRootViewBox := True;
  end;
  State.Transform := ScalingTransform(Surface.Width / ViewportWidth, Surface.Height / ViewportHeight);
  State.Viewport.Width := ViewportWidth;
  State.Viewport.Height := ViewportHeight;
  State.Viewport.FontSize := Root.Style.FontSize;
  State.ParentStyle := nil;
  State.Restyle := False;
  FDepth := 0;
  FUseCount := 0;
  RenderNode(Root, State);
end;

function RenderSvgToSurface(Document: TSvgDocument; Width, Height: LongInt; ViewportWidth,
  ViewportHeight: Double; SynthesizeViewBox: Boolean; out Surface: TSurface): Boolean;
var
  Renderer: TSvgRenderer;
begin
  Result := CreateSurface(Surface, Width, Height, ColorTransparent);
  if not Result then
    Exit;
  Renderer := TSvgRenderer.Create(Document);
  try
    Renderer.Render(Surface, ViewportWidth, ViewportHeight, SynthesizeViewBox);
  finally
    Renderer.Free;
  end;
end;

end.
