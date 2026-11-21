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
  A document's rendering: style, boxes and layout kept up to date.

  TDocumentLayout is what a web view holds per document. It owns the
  styler (Web.Style.Resolver) and the box tree, listens to the styler's
  change reports and to the document's resources, and Update brings
  everything up to date for the current viewport: restyle what is
  dirty, rebuild the box children of the elements whose boxes changed
  (boxes of untouched subtrees are kept and moved over), resolve
  counters and generated text, lay out what is dirty (clean subtrees
  laid out for the same input are skipped), the fixed boxes, and the
  scrollable overflow of every scroll container.

  The viewport is in CSS pixels; Scale is the device pixels per CSS
  pixel (the system's DPI scale), which media queries see as resolution
  and painting uses.
}
unit Web.Layout.Document;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom, Css.ElementAdapter, Css.ComputedStyle, Web.Style.Resolver, Web.Layout.Resources, Web.Layout.Boxes,
  Web.Layout.TreeBuilder, Web.Layout.Context;

type
  TScrollContainerInfo = record
    Box: TLayoutBox;
    { The element (nil for the viewport). }
    Node: TNode;
    { The padding box in document coordinates (CSS px). }
    X, Y, Width, Height: Single;
    ScrollWidth, ScrollHeight: Single;
    ScrollX, ScrollY: Single;
    { Whether it shows a scroll bar along that axis: overflow auto or
      scroll there, and the box is visible (visibility, no transparent
      ancestor). overflow: hidden scrolls only from script. }
    BarX, BarY: Boolean;
  end;
  TScrollContainerArray = array of TScrollContainerInfo;

  TDocumentLayout = class
  private
    FDocument: TDocument;
    FResources: TDocumentResources;
    FStyler: TDocumentStyler;
    FBuilder: TBoxTreeBuilder;
    FRoot: TLayoutBox;
    FViewportWidth, FViewportHeight, FScale: Single;
    FFullRebuild: Boolean;
    FBoxesChanged: Boolean;
    FLayoutDirty: Boolean;
    FPaintVersion: LongWord;
    { How many of the paint version's steps were the viewport scrolling
      (which leaves the display list as it was). }
    FViewportScrolls: LongWord;
    FFixedBoxes: TPositionedList;
    FDarkScheme: Boolean;
    procedure StyleChanged(Element: TElement; Change: TStyleChangeKind);
    procedure TextChanged(Node: TNode);
    procedure NodeRemoved(Node: TNode);
    procedure ChildrenChanged(Node: TNode);
    procedure AttributeChanged(Node: TNode);
    procedure ResourcesChanged(Change: TResourceChange);
    procedure MarkBoxesOf(Node: TNode);
    procedure TakeElementImage(Box: TReplacedBox; Element: TElement);
    procedure TakePaintStyles(Box: TLayoutBox; Element: TElement; Style: TCssComputedStyle);
    procedure RebuildDirtyBoxes(Node: TNode);
    procedure UpdateBoxes;
    procedure ApplyEnvironment;
    procedure ComputeScrollExtents;
  public
    constructor Create(Document: TDocument; Resources: TDocumentResources = nil);
    destructor Destroy; override;
    { The viewport in CSS pixels and the device scale. }
    procedure SetViewport(Width, Height, Scale: Single);
    procedure SetDarkColorScheme(Dark: Boolean);
    { Brings style, boxes and layout up to date. }
    procedure Update;
    { Whether Update has work to do. }
    function NeedsUpdate: Boolean;
    { The document's size (the viewport's scrollable overflow). }
    function DocumentWidth: Single;
    function DocumentHeight: Single;
    { Every scroll container (the viewport first). }
    function ScrollContainers: TScrollContainerArray;
    { Scrolls a container (Node nil: the viewport); clamped. }
    procedure SetScrollOffset(Node: TNode; X, Y: Single);
    procedure GetScrollOffset(Node: TNode; out X, Y: Single);
    { The element's principal box (nil if it has none). }
    function BoxOf(Node: TNode): TLayoutBox;
    { The border box of a node's box in document coordinates. }
    function NodeBounds(Node: TNode; out X, Y, Width, Height: Single): Boolean;
    { Sets dynamic states (hover, focus ...) for :hover and friends. }
    procedure SetElementStates(Element: TElement; States: TCssElementStates);
    property Document: TDocument read FDocument;
    property Styler: TDocumentStyler read FStyler;
    property Resources: TDocumentResources read FResources;
    property Root: TLayoutBox read FRoot;
    property ViewportWidth: Single read FViewportWidth;
    property ViewportHeight: Single read FViewportHeight;
    property Scale: Single read FScale;
    { Changes whenever what painting would draw changed. }
    property PaintVersion: LongWord read FPaintVersion;
    { Changes whenever the display list would change: the paint version
      without the viewport's own scrolling (painted at an offset). }
    function DisplayListVersion: LongWord;
  end;

implementation

uses
  Web.Profiling,
  Math, Web.Atoms, Css.MediaQueries, Css.Keywords, Css.PropertyIds, Web.Style.NodeData, Web.Layout.Counters, Web.Layout.Dispatch,
  Web.Layout.Positioned, Web.Text.FontInstances, Web.Svg.InlineImages;

constructor TDocumentLayout.Create(Document: TDocument; Resources: TDocumentResources);
begin
  inherited Create;
  FDocument := Document;
  if Resources = nil then
    Resources := DocumentResourcesOf(Document);
  FResources := Resources;
  FStyler := TDocumentStyler.Create(Document, Resources);
  FStyler.OnStyleChanged := @StyleChanged;
  FStyler.OnTextChanged := @TextChanged;
  FStyler.OnNodeRemoved := @NodeRemoved;
  FStyler.OnChildrenChanged := @ChildrenChanged;
  FStyler.OnElementAttributeChanged := @AttributeChanged;
  FResources.AddListener(@ResourcesChanged);
  FBuilder := TBoxTreeBuilder.Create(FStyler, Resources);
  FFixedBoxes := TPositionedList.Create;
  FViewportWidth := 800;
  FViewportHeight := 600;
  FScale := 1;
  FFullRebuild := True;
  FLayoutDirty := True;
  ApplyEnvironment;
end;

destructor TDocumentLayout.Destroy;
begin
  FResources.RemoveListener(@ResourcesChanged);
  FreeBoxTree(FRoot);
  FRoot := nil;
  FBuilder.Free;
  FStyler.Free;
  FFixedBoxes.Free;
  inherited Destroy;
end;

procedure TDocumentLayout.ApplyEnvironment;
var
  Environment: TCssMediaEnvironment;
begin
  Environment := DefaultMediaEnvironment;
  Environment.Width := FViewportWidth;
  Environment.Height := FViewportHeight;
  Environment.DeviceWidth := FViewportWidth;
  Environment.DeviceHeight := FViewportHeight;
  Environment.Resolution := FScale;
  Environment.DarkColorScheme := FDarkScheme;
  FStyler.SetEnvironment(Environment);
end;

procedure TDocumentLayout.SetViewport(Width, Height, Scale: Single);
begin
  if (Width = FViewportWidth) and (Height = FViewportHeight) and (Scale = FScale) then
    Exit;
  FViewportWidth := Width;
  FViewportHeight := Height;
  FScale := Scale;
  ApplyEnvironment;
  FLayoutDirty := True;
  if FRoot <> nil then
    FRoot.MarkNeedsLayout;
end;

procedure TDocumentLayout.SetDarkColorScheme(Dark: Boolean);
begin
  if Dark = FDarkScheme then
    Exit;
  FDarkScheme := Dark;
  ApplyEnvironment;
end;

procedure TDocumentLayout.SetElementStates(Element: TElement; States: TCssElementStates);
begin
  FStyler.SetElementStates(Element, States);
end;

function TDocumentLayout.BoxOf(Node: TNode): TLayoutBox;
var
  Data: PNodeData;
begin
  Data := ExistingNodeData(Node);
  if Data = nil then
    Result := nil
  else
    Result := TLayoutBox(Data^.Box);
end;

{ Marks for rebuilding the children of the nearest box at or above Node. }
procedure TDocumentLayout.MarkBoxesOf(Node: TNode);
var
  Current: TNode;
  Box: TLayoutBox;
begin
  Current := Node;
  while Current <> nil do
  begin
    if Current = FDocument then
    begin
      FFullRebuild := True;
      Exit;
    end;
    Box := BoxOf(Current);
    if (Box <> nil) and (Box.Kind <> bkReplaced) then
    begin
      MarkBoxesDirty(Current);
      FBoxesChanged := True;
      Exit;
    end;
    if (Box <> nil) and (Box.Kind = bkReplaced) then
    begin
      Box.MarkNeedsLayout;
      FLayoutDirty := True;
      Exit;
    end;
    Current := Current.ParentNode;
  end;
end;

procedure TDocumentLayout.StyleChanged(Element: TElement; Change: TStyleChangeKind);
var
  Box: TLayoutBox;
  Data: PNodeData;
begin
  if FFullRebuild or (FRoot = nil) then
    Exit;
  Inc(FPaintVersion);
  Box := BoxOf(Element);
  Data := ExistingNodeData(Element);
  if (Change = scBoxes) or (Box = nil) then
  begin
    if Element.ParentNode <> nil then
      MarkBoxesOf(Element.ParentNode);
    Exit;
  end;
  { Same boxes, new style. }
  if (Data <> nil) and (Box.Style <> Data^.Style) then
  begin
    Box.Style.Release;
    Box.Style := Data^.Style.AddRef;
  end;
  if (Change = scPaint) and (Data <> nil) then
  begin
    { Only painting changes: the boxes take the new styles, no layout. }
    TakePaintStyles(Box, Element, Data^.Style);
    Exit;
  end;
  if Box.Kind = bkReplaced then
    Box.MarkNeedsLayout
  else
    MarkBoxesOf(Element);
  FLayoutDirty := True;
end;

{ The text boxes of Element's own text and the anonymous boxes between
  take the element's new style. }
procedure TDocumentLayout.TakePaintStyles(Box: TLayoutBox; Element: TElement; Style: TCssComputedStyle);
var
  Child: TLayoutBox;
  NewStyle: TCssComputedStyle;
begin
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if (Child.Kind = bkText) and (Child.Node <> nil) and (Child.Node.ParentNode = Element) then
      NewStyle := Style
    else if (bfAnonymous in Child.Flags) and (Child.Node = nil) and not (Child is TTextBox) then
      NewStyle := FBuilder.AnonymousStyleFor(Box.Style)
    else
      NewStyle := nil;
    if (NewStyle <> nil) and (Child.Style <> NewStyle) then
    begin
      Child.Style.Release;
      Child.Style := NewStyle.AddRef;
    end;
    if (bfAnonymous in Child.Flags) and (Child.Node = nil) then
      TakePaintStyles(Child, Element, Style);
    Child := Child.NextSibling;
  end;
end;

procedure TDocumentLayout.TextChanged(Node: TNode);
var
  Box: TLayoutBox;
begin
  Inc(FPaintVersion);
  Box := BoxOf(Node);
  if Box <> nil then
  begin
    Box.MarkNeedsLayout;
    FLayoutDirty := True;
  end
  else if Node.ParentNode <> nil then
    MarkBoxesOf(Node.ParentNode);
end;

procedure TDocumentLayout.NodeRemoved(Node: TNode);
var
  Box, Next: TLayoutBox;
begin
  { The boxes stay until their parent's children are built again; they
    must not reach the node, which may be freed before that. }
  Box := BoxOf(Node);
  while Box <> nil do
  begin
    Next := Box.NextForNode;
    Box.Node := nil;
    Box.NextForNode := nil;
    Box := Next;
  end;
  Inc(FPaintVersion);
end;

procedure TDocumentLayout.ChildrenChanged(Node: TNode);
begin
  Inc(FPaintVersion);
  MarkBoxesOf(Node);
end;

procedure TDocumentLayout.AttributeChanged(Node: TNode);
var
  Box: TLayoutBox;
begin
  Box := BoxOf(Node);
  if (Box <> nil) and (Box.Kind = bkReplaced) then
  begin
    TakeElementImage(TReplacedBox(Box), TElement(Node));
    Box.MarkNeedsLayout;
    FLayoutDirty := True;
  end
  else if (Box <> nil) and (Box.Kind = bkTableCell) then
  begin
    Box.MarkNeedsLayout;
    FLayoutDirty := True;
  end
  else if TElement(Node).IsHtmlElement(AtomInput) or TElement(Node).IsHtmlElement(AtomSelect) then
    MarkBoxesOf(Node);
  Inc(FPaintVersion);
end;

procedure TDocumentLayout.ResourcesChanged(Change: TResourceChange);
var
  Node: TNode;
  Box: TLayoutBox;
begin
  Inc(FPaintVersion);
  if Change = rcFonts then
  begin
    { Faces changed under the fonts: everything is measured again. }
    FFullRebuild := True;
    FLayoutDirty := True;
    Exit;
  end;
  if Change <> rcImages then
    Exit;
  { Images arrived: replaced boxes take them and are laid out again. }
  if FRoot = nil then
    Exit;
  Node := FDocument;
  while Node <> nil do
  begin
    Box := BoxOf(Node);
    if (Box <> nil) and (Box is TReplacedBox) and Node.IsElement then
      if (TReplacedBox(Box).Image <> FResources.ElementImage(TElement(Node))) and
         not IsOutermostSvgElement(TElement(Node)) then
      begin
        TakeElementImage(TReplacedBox(Box), TElement(Node));
        Box.MarkNeedsLayout;
        FLayoutDirty := True;
      end;
    Node := Node.NextInTree(FDocument);
  end;
end;

procedure TDocumentLayout.TakeElementImage(Box: TReplacedBox; Element: TElement);
begin
  Box.Image := FResources.ElementImage(Element);
  { Inline SVG has no loaded image: it draws its own subtree. }
  if Box.Image = nil then
    Box.Image := FBuilder.OwnImageOf(Element);
  if not FResources.ElementImageNaturalSize(Element, Box.NaturalWidth, Box.NaturalHeight) then
  begin
    Box.NaturalWidth := 0;
    Box.NaturalHeight := 0;
  end;
end;

procedure TDocumentLayout.RebuildDirtyBoxes(Node: TNode);
var
  Data: PNodeData;
  Child: TNode;
  Box: TLayoutBox;
begin
  Data := ExistingNodeData(Node);
  if Data = nil then
    Exit;
  if ndBoxesDirty in Data^.Flags then
  begin
    Box := TLayoutBox(Data^.Box);
    if Box <> nil then
      FBuilder.BuildChildren(Box);
    Data^.Flags := Data^.Flags - [ndBoxesDirty, ndDescendantBoxesDirty];
    Exit;
  end;
  if not (ndDescendantBoxesDirty in Data^.Flags) then
    Exit;
  Exclude(Data^.Flags, ndDescendantBoxesDirty);
  Child := Node.FirstChild;
  while Child <> nil do
  begin
    RebuildDirtyBoxes(Child);
    Child := Child.NextSibling;
  end;
end;

function TDocumentLayout.NeedsUpdate: Boolean;
var
  Data: PNodeData;
begin
  Data := ExistingNodeData(FDocument);
  Result := FFullRebuild or FBoxesChanged or FLayoutDirty or (FRoot = nil) or
    ((Data <> nil) and ((ndDescendantStyleDirty in Data^.Flags) or (ndDescendantBoxesDirty in Data^.Flags)));
  if (FRoot <> nil) and ([bfNeedsLayout, bfChildNeedsLayout] * FRoot.Flags <> []) then
    Result := True;
end;

procedure TDocumentLayout.Update;
var
  Input: TLayoutInput;
  Viewport: TLayoutBox;
begin
  EnterPhase(PhaseStyle);
  try
    FStyler.UpdateStyles;
  finally
    LeavePhase;
  end;
  EnterPhase(PhaseBoxes);
  try
    UpdateBoxes;
  finally
    LeavePhase;
  end;
  Viewport := FRoot;
  if FLayoutDirty or ([bfNeedsLayout, bfChildNeedsLayout] * Viewport.Flags <> []) then
  begin
    EnterPhase(PhaseLayout);
    try
      FillChar(Input, SizeOf(Input), 0);
      Input.AvailableWidth := FViewportWidth;
      Input.ContainingHeight := FViewportHeight;
      Input.WidthMode := wmStretch;
      Input.FixedWidth := -1;
      Input.FixedHeight := -1;
      Input.ViewportWidth := FViewportWidth;
      Input.ViewportHeight := FViewportHeight;
      FFixedBoxes.Clear;
      Input.FixedBoxes := FFixedBoxes;
      LayoutBox(Viewport, Input);
      LayoutPositionedBoxes(Viewport, FFixedBoxes, Input);
      ComputeScrollExtents;
      FLayoutDirty := False;
      Inc(FPaintVersion);
    finally
      LeavePhase;
    end;
  end;
end;

{ The box tree brought up to date with the styles: built whole the first
  time (and after a full rebuild), else the dirty subtrees again. }
procedure TDocumentLayout.UpdateBoxes;
var
  Data: PNodeData;
begin
  if FFullRebuild or (FRoot = nil) then
  begin
    FreeBoxTree(FRoot);
    FBuilder.ClearCaches;
    FRoot := FBuilder.BuildTree(FDocument);
    FFullRebuild := False;
    FBoxesChanged := True;
    Data := NodeDataOf(FDocument);
    Data^.Flags := Data^.Flags - [ndBoxesDirty, ndDescendantBoxesDirty];
  end
  else if FBoxesChanged then
    RebuildDirtyBoxes(FDocument);
  if FBoxesChanged then
  begin
    ResolveGeneratedContent(FRoot);
    FBoxesChanged := False;
    Inc(FPaintVersion);
  end;
end;

{ The scrollable overflow of each scroll container (and the viewport):
  the union of its descendants' border boxes, from its padding box. }
procedure ExtentOf(Box: TLayoutBox; OffsetX, OffsetY: Single; var Right, Bottom: Single);
var
  Child: TLayoutBox;
  ChildX, ChildY, InnerRight, InnerBottom: Single;
  Index: Integer;
  Fragment: PLineFragment;
begin
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if Child.Kind = bkInline then
      ExtentOf(Child, OffsetX, OffsetY, Right, Bottom)
    else if not (bfFixed in Child.Flags) then
    begin
      ChildX := OffsetX + Child.X + Child.RelativeX;
      ChildY := OffsetY + Child.Y + Child.RelativeY;
      if Child.Kind <> bkText then
      begin
        if ChildX + Child.Width > Right then
          Right := ChildX + Child.Width;
        if ChildY + Child.Height > Bottom then
          Bottom := ChildY + Child.Height;
      end;
      if not (bfClipsOverflow in Child.Flags) then
        ExtentOf(Child, ChildX, ChildY, Right, Bottom);
      if bfScrollContainer in Child.Flags then
      begin
        InnerRight := 0;
        InnerBottom := 0;
        ExtentOf(Child, -Child.Border[sideLeft], -Child.Border[sideTop], InnerRight, InnerBottom);
        Child.ScrollWidth := Max(InnerRight + Child.Padding[sideRight], Child.Width - Child.Border[sideLeft] -
          Child.Border[sideRight]);
        Child.ScrollHeight := Max(InnerBottom + Child.Padding[sideBottom], Child.Height - Child.Border[sideTop] -
          Child.Border[sideBottom]);
      end;
    end;
    Child := Child.NextSibling;
  end;
  if Box.Inline <> nil then
    for Index := 0 to Box.Inline.FragmentCount - 1 do
    begin
      Fragment := @Box.Inline.Fragments[Index];
      if OffsetX + Fragment^.X + Fragment^.Width > Right then
        Right := OffsetX + Fragment^.X + Fragment^.Width;
      if OffsetY + Fragment^.Y + Fragment^.Height > Bottom then
        Bottom := OffsetY + Fragment^.Y + Fragment^.Height;
    end;
end;

procedure TDocumentLayout.ComputeScrollExtents;
var
  Right, Bottom: Single;
begin
  Right := 0;
  Bottom := 0;
  ExtentOf(FRoot, 0, 0, Right, Bottom);
  FRoot.ScrollWidth := Max(Right, FViewportWidth);
  FRoot.ScrollHeight := Max(Bottom, FViewportHeight);
  SetScrollOffset(nil, FRoot.ScrollX, FRoot.ScrollY);
end;

function TDocumentLayout.DocumentWidth: Single;
begin
  if FRoot = nil then
    Result := 0
  else
    Result := FRoot.ScrollWidth;
end;

function TDocumentLayout.DocumentHeight: Single;
begin
  if FRoot = nil then
    Result := 0
  else
    Result := FRoot.ScrollHeight;
end;

function ShowsBar(Style: TCssComputedStyle; Id: TCssPropertyId): Boolean;
begin
  Result := (Style <> nil) and KeywordIn(Style.Keyword(Id), [kwAuto, kwScroll]);
end;

procedure CollectScrollers(Box: TLayoutBox; var List: TScrollContainerArray; var Count: Integer;
  Transparent: Boolean);
var
  Child: TLayoutBox;
  X, Y: Single;
  Hidden, Shown: Boolean;
begin
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    Hidden := Transparent or ((Child.Style <> nil) and (Child.Style.Value(cpOpacity)^.Number <= 0));
    if bfScrollContainer in Child.Flags then
    begin
      if Count >= Length(List) then
        SetLength(List, Count * 2 + 4);
      Child.AbsolutePosition(X, Y);
      List[Count].Box := Child;
      List[Count].Node := Child.Node;
      List[Count].X := X + Child.Border[sideLeft];
      List[Count].Y := Y + Child.Border[sideTop];
      List[Count].Width := Child.Width - Child.Border[sideLeft] - Child.Border[sideRight];
      List[Count].Height := Child.Height - Child.Border[sideTop] - Child.Border[sideBottom];
      List[Count].ScrollWidth := Child.ScrollWidth;
      List[Count].ScrollHeight := Child.ScrollHeight;
      List[Count].ScrollX := Child.ScrollX;
      List[Count].ScrollY := Child.ScrollY;
      Shown := not Hidden and (Child.Style <> nil) and (Child.Style.Keyword(cpVisibility) = kwVisible);
      List[Count].BarX := Shown and ShowsBar(Child.Style, cpOverflowX);
      List[Count].BarY := Shown and ShowsBar(Child.Style, cpOverflowY);
      Inc(Count);
    end;
    CollectScrollers(Child, List, Count, Hidden);
    Child := Child.NextSibling;
  end;
end;

function TDocumentLayout.ScrollContainers: TScrollContainerArray;
var
  Count: Integer;
begin
  Result := nil;
  if FRoot = nil then
    Exit;
  SetLength(Result, 4);
  Result[0].Box := FRoot;
  Result[0].Node := nil;
  Result[0].X := 0;
  Result[0].Y := 0;
  Result[0].Width := FViewportWidth;
  Result[0].Height := FViewportHeight;
  Result[0].ScrollWidth := FRoot.ScrollWidth;
  Result[0].ScrollHeight := FRoot.ScrollHeight;
  Result[0].ScrollX := FRoot.ScrollX;
  Result[0].ScrollY := FRoot.ScrollY;
  Result[0].BarX := True;
  Result[0].BarY := True;
  Count := 1;
  CollectScrollers(FRoot, Result, Count, False);
  SetLength(Result, Count);
end;

procedure TDocumentLayout.SetScrollOffset(Node: TNode; X, Y: Single);
var
  Box: TLayoutBox;
  Width, Height: Single;
begin
  if Node = nil then
  begin
    Box := FRoot;
    Width := FViewportWidth;
    Height := FViewportHeight;
  end
  else
  begin
    Box := BoxOf(Node);
    if (Box = nil) or not (bfScrollContainer in Box.Flags) then
      Exit;
    Width := Box.Width - Box.Border[sideLeft] - Box.Border[sideRight];
    Height := Box.Height - Box.Border[sideTop] - Box.Border[sideBottom];
  end;
  if Box = nil then
    Exit;
  X := Min(X, Box.ScrollWidth - Width);
  Y := Min(Y, Box.ScrollHeight - Height);
  if X < 0 then
    X := 0;
  if Y < 0 then
    Y := 0;
  if (X <> Box.ScrollX) or (Y <> Box.ScrollY) then
  begin
    Box.ScrollX := X;
    Box.ScrollY := Y;
    Inc(FPaintVersion);
    if Node = nil then
      Inc(FViewportScrolls);
  end;
end;

function TDocumentLayout.DisplayListVersion: LongWord;
begin
  Result := FPaintVersion - FViewportScrolls;
end;

procedure TDocumentLayout.GetScrollOffset(Node: TNode; out X, Y: Single);
var
  Box: TLayoutBox;
begin
  X := 0;
  Y := 0;
  if Node = nil then
    Box := FRoot
  else
    Box := BoxOf(Node);
  if Box = nil then
    Exit;
  X := Box.ScrollX;
  Y := Box.ScrollY;
end;

function TDocumentLayout.NodeBounds(Node: TNode; out X, Y, Width, Height: Single): Boolean;
var
  Box: TLayoutBox;
begin
  Box := BoxOf(Node);
  X := 0;
  Y := 0;
  Width := 0;
  Height := 0;
  Result := Box <> nil;
  if not Result then
    Exit;
  Box.AbsolutePosition(X, Y);
  Width := Box.Width;
  Height := Box.Height;
end;

end.
