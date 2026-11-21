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
  The rendering of a child navigable (an iframe's or frame's content):
  TFrameView is the child's navigable observer and the parent's
  embedded content. For each document the child shows it keeps a
  TDocumentLayout and a TDocumentPainter, put in the parent document's
  resources under the frame element, so the parent's layout gives it
  the frame's content box size (its viewport; the parent's scale, so
  zoom and DPI are inherited) and brings it up to date, and the
  parent's raster paints it into the frame's box at its own scroll
  offset, with a thin scroll bar when it overflows (unless the element
  says scrolling="no").

  The layout sink makes one for each child navigable of a rendered page
  (TLayoutResourceSink.CreateChildSink), so the web view, webbrowse and
  webrender show frames without knowing about them; input goes through
  the view's own hit testing (HitTestThroughFrames finds the innermost
  frame's node and where that frame's viewport is).
}
unit Web.Frames.Views;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Drawing.Surfaces,
  Drawing.Rectangles,
  Image.Model,
  Web.Dom,
  Web.Layout.EmbeddedContent,
  Web.Layout.Document,
  Web.Paint.Painter,
  Web.Script.Layout,
  Web.Navigation.Windows,
  Web.Navigation.Navigables;

type
  TFrameView = class(TEmbeddedContent)
  private
    FNavigable: TNavigable;
    FSink: TObject;
    FObserver: TNavigableObserver;
    FContainer: TElement;
    FParentDocument: TDocument;
    FDocument: TDocument;
    FLayout: TDocumentLayout;
    FPainter: TDocumentPainter;
    FWidth, FHeight, FScale: Single;
    FPendingFragment: TElement;
    FHasPendingFragment: Boolean;
    FHasPendingRestore: Boolean;
    FRestoreX, FRestoreY: Single;
    FScrollVersion: LongWord;
    procedure Release;
    procedure Adopt(Document: TDocument);
    procedure Register;
    procedure Unregister;
    procedure ApplyPendingScroll;
    procedure PaintScrollBars(const Surface: TSurface; OriginX, OriginY: LongInt; const Clip: TRectangle);
  public
    { Sink: the child's TLayoutResourceSink (not owned). }
    constructor Create(Navigable: TNavigable; Sink: TObject);
    destructor Destroy; override;
    { The navigable's document changed (nil: it is being taken away). }
    procedure DocumentChanged(Document: TDocument);
    procedure ScrollToFragment(Element: TElement);
    procedure RestoreScrollPosition(X, Y: Double);
    procedure SetViewport(Width, Height, Scale: Single); override;
    function NeedsUpdate: Boolean; override;
    procedure Update; override;
    function PaintVersion: LongWord; override;
    procedure PaintInto(const Surface: TSurface; OriginX, OriginY: LongInt; const Clip: TRectangle); override;
    function ContentDocument: TDocument; override;
    { Whether the element lets its document scroll (scrolling="no"
      does not). }
    function Scrollable: Boolean;
    { Scrolls the frame's viewport by CSS pixels; False when it could
      not move that way (the wheel goes on to the parent). }
    function ScrollViewportBy(DeltaX, DeltaY: Single): Boolean;
    { The node at a point of the frame's viewport (CSS px). }
    function HitTest(X, Y: Single): THitTestResult;
    property Navigable: TNavigable read FNavigable;
    property Container: TElement read FContainer;
    property ParentDocument: TDocument read FParentDocument;
    property Layout: TDocumentLayout read FLayout;
    property Painter: TDocumentPainter read FPainter;
    property Observer: TNavigableObserver read FObserver;
  end;

  { Script's layout questions in a frame's document: the frame view of
    the document asked about, found when needed (a frame's document is
    laid out by its view, not by the embedder). }
  TFrameScriptLayout = class(TDocumentScriptLayout)
  private
    FDocument: TDocument;
  protected
    procedure Resolve; override;
  public
    constructor Create(Document: TDocument);
  end;

  { One frame on the way from a view's viewport to a node: the frame,
    and where its viewport's top left is in the outer viewport (CSS px
    of the top-level viewport). }
  TFrameStep = record
    View: TFrameView;
    OriginX, OriginY: Single;
  end;
  TFramePath = array of TFrameStep;

{ The frame view showing Document, nil if none (a top-level document). }
function FrameViewOfDocument(Document: TDocument): TFrameView;
{ The frame view an element (an iframe) shows, nil if none. }
function FrameViewOfElement(Element: TElement): TFrameView;
{ Hit testing that goes into frames: the innermost document's node at a
  point of the top-level viewport (CSS px), and the frames passed on the
  way (empty when the point is in the top-level document). }
function HitTestThroughFrames(Painter: TDocumentPainter; Layout: TDocumentLayout; X, Y: Single;
  out Path: TFramePath): THitTestResult;
{ Where a document's viewport is in the top-level viewport (CSS px):
  (0, 0) for the top-level document (TopLayout's); False when it is a
  frame's that is not laid out. Layout: the document's own layout. }
function DocumentViewportOrigin(TopLayout: TDocumentLayout; Document: TDocument; out OriginX, OriginY: Single;
  out Layout: TDocumentLayout): Boolean;

implementation

uses
  Math,
  Drawing.Colors,
  Drawing.Canvas,
  Web.Atoms,
  Web.Layout.Boxes,
  Web.Layout.Resources,
  Web.Loading.LayoutSink;

type
  { The child navigable's observer: hands its news to the view. }
  TFrameViewObserver = class(TNavigableObserver)
  public
    View: TFrameView;
    procedure DocumentChanged(Navigable: TNavigable; Document: TDocument; Window: TWebWindow); override;
    procedure ScrollToFragment(Navigable: TNavigable; Element: TElement); override;
    procedure RestoreScrollPosition(Navigable: TNavigable; X, Y: Double); override;
  end;

var
  AllViews: TList;

const
  ScrollBarThickness = 4;

procedure TFrameViewObserver.DocumentChanged(Navigable: TNavigable; Document: TDocument; Window: TWebWindow);
begin
  View.DocumentChanged(Document);
end;

procedure TFrameViewObserver.ScrollToFragment(Navigable: TNavigable; Element: TElement);
begin
  View.ScrollToFragment(Element);
end;

procedure TFrameViewObserver.RestoreScrollPosition(Navigable: TNavigable; X, Y: Double);
begin
  View.RestoreScrollPosition(X, Y);
end;

{ TFrameView }

constructor TFrameView.Create(Navigable: TNavigable; Sink: TObject);
begin
  inherited Create;
  FNavigable := Navigable;
  FSink := Sink;
  FContainer := Navigable.Container;
  FContainer.Retain;
  FParentDocument := FContainer.NodeDocument;
  FParentDocument.Retain;
  FWidth := 300;
  FHeight := 150;
  FScale := 1;
  FObserver := TFrameViewObserver.Create;
  TFrameViewObserver(FObserver).View := Self;
  AllViews.Add(Self);
end;

destructor TFrameView.Destroy;
begin
  AllViews.Remove(Self);
  Release;
  FObserver.Free;
  FContainer.Release;
  FParentDocument.Release;
  inherited Destroy;
end;

procedure TFrameView.Register;
begin
  DocumentResourcesOf(FParentDocument).SetElementFrame(FContainer, Self);
end;

procedure TFrameView.Unregister;
var
  Resources: TDocumentResources;
begin
  Resources := DocumentResourcesOf(FParentDocument);
  if Resources.ElementFrame(FContainer) = Self then
    Resources.SetElementFrame(FContainer, nil);
end;

procedure TFrameView.Release;
begin
  if FDocument = nil then
    Exit;
  Unregister;
  if FPendingFragment <> nil then
    FPendingFragment.Release;
  FPendingFragment := nil;
  FHasPendingFragment := False;
  FHasPendingRestore := False;
  FreeAndNil(FPainter);
  FreeAndNil(FLayout);
  TLayoutResourceSink(FSink).DocumentGoing(FDocument);
  FreeDocumentResources(FDocument);
  FDocument.Release;
  FDocument := nil;
end;

procedure TFrameView.Adopt(Document: TDocument);
begin
  FDocument := Document;
  FDocument.Retain;
  TLayoutResourceSink(FSink).PrepareDocument(Document);
  FLayout := TDocumentLayout.Create(Document);
  FLayout.SetViewport(FWidth, FHeight, FScale);
  FPainter := TDocumentPainter.Create(FLayout);
  Register;
end;

procedure TFrameView.DocumentChanged(Document: TDocument);
begin
  if Document = FDocument then
    Exit;
  Release;
  if Document <> nil then
    Adopt(Document);
end;

procedure TFrameView.ScrollToFragment(Element: TElement);
begin
  if FPendingFragment <> nil then
    FPendingFragment.Release;
  FPendingFragment := Element;
  if Element <> nil then
    Element.Retain;
  FHasPendingFragment := True;
end;

procedure TFrameView.RestoreScrollPosition(X, Y: Double);
begin
  FHasPendingRestore := True;
  FRestoreX := X;
  FRestoreY := Y;
end;

procedure TFrameView.SetViewport(Width, Height, Scale: Single);
begin
  if (Width = FWidth) and (Height = FHeight) and (Scale = FScale) then
    Exit;
  FWidth := Width;
  FHeight := Height;
  FScale := Scale;
  TLayoutResourceSink(FSink).SetViewport(Width, Height, Scale);
  if FLayout <> nil then
    FLayout.SetViewport(Width, Height, Scale);
end;

function TFrameView.NeedsUpdate: Boolean;
begin
  Result := (FLayout <> nil) and (FLayout.NeedsUpdate or FHasPendingFragment or FHasPendingRestore);
end;

procedure TFrameView.Update;
begin
  if FLayout = nil then
    Exit;
  if FLayout.NeedsUpdate then
    FLayout.Update;
  ApplyPendingScroll;
end;

procedure TFrameView.ApplyPendingScroll;
var
  X, Y, Width, Height: Single;
begin
  if FHasPendingRestore then
  begin
    FHasPendingRestore := False;
    FLayout.SetScrollOffset(nil, FRestoreX, FRestoreY);
  end;
  if not FHasPendingFragment then
    Exit;
  FHasPendingFragment := False;
  if FPendingFragment = nil then
    FLayout.SetScrollOffset(nil, 0, 0)
  else
  begin
    if FPendingFragment.IsConnected and FLayout.NodeBounds(FPendingFragment, X, Y, Width, Height) then
      FLayout.SetScrollOffset(nil, X, Y);
    FPendingFragment.Release;
    FPendingFragment := nil;
  end;
end;

function TFrameView.PaintVersion: LongWord;
begin
  if FLayout = nil then
    Result := FScrollVersion
  else
    Result := LongWord((QWord(FLayout.PaintVersion) + FScrollVersion) and $FFFFFFFF);
end;

function TFrameView.ContentDocument: TDocument;
begin
  Result := FDocument;
end;

function TFrameView.Scrollable: Boolean;
var
  Value: string;
begin
  Value := LowerCase(Trim(FContainer.GetAttribute('scrolling')));
  Result := (Value <> 'no') and (Value <> 'off');
end;

procedure TFrameView.PaintInto(const Surface: TSurface; OriginX, OriginY: LongInt; const Clip: TRectangle);
var
  Part: TSurface;
begin
  if (FPainter = nil) or RectangleIsEmpty(Clip) then
    Exit;
  if FLayout.NeedsUpdate then
    Update;
  Part := SurfaceOnPixels(Surface.Pixels + PtrInt(Clip.Top) * Surface.Stride + Clip.Left, RectangleWidth(Clip),
    RectangleHeight(Clip), Surface.Stride * 4);
  FPainter.PaintShifted(Part, MakeRectangle(0, 0, Part.Width, Part.Height), Clip.Left - OriginX, Clip.Top - OriginY);
  if Scrollable then
    PaintScrollBars(Surface, OriginX, OriginY, Clip);
end;

{ A thin bar along the right (and bottom) edge when the document is
  larger than the frame. }
procedure TFrameView.PaintScrollBars(const Surface: TSurface; OriginX, OriginY: LongInt; const Clip: TRectangle);
var
  Canvas: TCanvas;
  ScrollX, ScrollY, DocumentWidth, DocumentHeight: Single;
  Thickness, Track, Thumb, Start: LongInt;
  Area: TRectangle;
begin
  DocumentWidth := FLayout.DocumentWidth;
  DocumentHeight := FLayout.DocumentHeight;
  if (DocumentHeight <= FHeight + 0.5) and (DocumentWidth <= FWidth + 0.5) then
    Exit;
  BeginCanvas(Canvas, Surface);
  NarrowCanvasClip(Canvas, Clip);
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  Thickness := Max(2, Round(ScrollBarThickness * FScale));
  if DocumentHeight > FHeight + 0.5 then
  begin
    Track := Round(FHeight * FScale);
    Thumb := Max(Thickness * 2, Round(Track * FHeight / DocumentHeight));
    Start := Round((Track - Thumb) * ScrollY / Max(1, DocumentHeight - FHeight));
    Area := MakeRectangle(OriginX + Round(FWidth * FScale) - Thickness, OriginY + Start, Thickness, Thumb);
    FillRectangle(Canvas, Area, ArgbColor(150, 96, 96, 96));
  end;
  if DocumentWidth > FWidth + 0.5 then
  begin
    Track := Round(FWidth * FScale);
    Thumb := Max(Thickness * 2, Round(Track * FWidth / DocumentWidth));
    Start := Round((Track - Thumb) * ScrollX / Max(1, DocumentWidth - FWidth));
    Area := MakeRectangle(OriginX + Start, OriginY + Round(FHeight * FScale) - Thickness, Thumb, Thickness);
    FillRectangle(Canvas, Area, ArgbColor(150, 96, 96, 96));
  end;
end;

function TFrameView.ScrollViewportBy(DeltaX, DeltaY: Single): Boolean;
var
  OldX, OldY, NewX, NewY: Single;
begin
  Result := False;
  if (FLayout = nil) or not Scrollable then
    Exit;
  FLayout.GetScrollOffset(nil, OldX, OldY);
  FLayout.SetScrollOffset(nil, OldX + DeltaX, OldY + DeltaY);
  FLayout.GetScrollOffset(nil, NewX, NewY);
  Result := (Abs(NewX - OldX) > 0.01) or (Abs(NewY - OldY) > 0.01);
  if Result then
    Inc(FScrollVersion);
end;

function TFrameView.HitTest(X, Y: Single): THitTestResult;
begin
  Result := Default(THitTestResult);
  if FPainter = nil then
    Exit;
  if FLayout.NeedsUpdate then
    Update;
  Result := FPainter.HitTest(X, Y);
end;

{ TFrameScriptLayout }

constructor TFrameScriptLayout.Create(Document: TDocument);
begin
  inherited Create;
  FDocument := Document;
end;

procedure TFrameScriptLayout.Resolve;
var
  View: TFrameView;
begin
  View := FrameViewOfDocument(FDocument);
  if View = nil then
  begin
    Layout := nil;
    Painter := nil;
    Exit;
  end;
  Layout := View.Layout;
  Painter := View.Painter;
end;

{ Lookups }

function FrameViewOfDocument(Document: TDocument): TFrameView;
var
  Index: Integer;
begin
  if Document <> nil then
    for Index := 0 to AllViews.Count - 1 do
      if TFrameView(AllViews[Index]).FDocument = Document then
        Exit(TFrameView(AllViews[Index]));
  Result := nil;
end;

function FrameViewOfElement(Element: TElement): TFrameView;
var
  Index: Integer;
begin
  if Element <> nil then
    for Index := 0 to AllViews.Count - 1 do
      if (TFrameView(AllViews[Index]).FContainer = Element) and (TFrameView(AllViews[Index]).FDocument <> nil) then
        Exit(TFrameView(AllViews[Index]));
  Result := nil;
end;

{ Where the content box of a frame element is in its document's viewport. }
function FrameContentOrigin(Layout: TDocumentLayout; Element: TElement; out X, Y: Single): Boolean;
var
  Box: TLayoutBox;
  BoxX, BoxY, ScrollX, ScrollY: Single;
begin
  X := 0;
  Y := 0;
  Box := Layout.BoxOf(Element);
  Result := Box <> nil;
  if not Result then
    Exit;
  Box.AbsolutePosition(BoxX, BoxY);
  Layout.GetScrollOffset(nil, ScrollX, ScrollY);
  X := BoxX + Box.ContentLeft - ScrollX;
  Y := BoxY + Box.ContentTop - ScrollY;
end;

function HitTestThroughFrames(Painter: TDocumentPainter; Layout: TDocumentLayout; X, Y: Single;
  out Path: TFramePath): THitTestResult;
var
  View: TFrameView;
  OriginX, OriginY, ContentX, ContentY: Single;
  Depth: Integer;
begin
  Path := nil;
  Result := Painter.HitTest(X, Y);
  OriginX := 0;
  OriginY := 0;
  Depth := 0;
  while (Result.Element <> nil) and (Depth < 16) do
  begin
    View := FrameViewOfElement(Result.Element);
    if (View = nil) or (View.Layout = nil) or not FrameContentOrigin(Layout, Result.Element, ContentX, ContentY) then
      Break;
    { Only the content box shows the frame's document (not its border). }
    if (X - OriginX < ContentX) or (Y - OriginY < ContentY) or (X - OriginX >= ContentX + View.FWidth) or
       (Y - OriginY >= ContentY + View.FHeight) then
      Break;
    OriginX := OriginX + ContentX;
    OriginY := OriginY + ContentY;
    SetLength(Path, Length(Path) + 1);
    Path[High(Path)].View := View;
    Path[High(Path)].OriginX := OriginX;
    Path[High(Path)].OriginY := OriginY;
    Layout := View.Layout;
    Result := View.HitTest(X - OriginX, Y - OriginY);
    Inc(Depth);
  end;
end;

function DocumentViewportOrigin(TopLayout: TDocumentLayout; Document: TDocument; out OriginX, OriginY: Single;
  out Layout: TDocumentLayout): Boolean;
var
  View: TFrameView;
  OuterLayout: TDocumentLayout;
  X, Y: Single;
  Depth: Integer;
begin
  OriginX := 0;
  OriginY := 0;
  Layout := nil;
  if TopLayout = nil then
    Exit(False);
  if Document = TopLayout.Document then
  begin
    Layout := TopLayout;
    Exit(True);
  end;
  View := FrameViewOfDocument(Document);
  if (View = nil) or (View.Layout = nil) then
    Exit(False);
  Layout := View.Layout;
  Depth := 0;
  while Depth < 16 do
  begin
    if View.FParentDocument = TopLayout.Document then
      OuterLayout := TopLayout
    else if FrameViewOfDocument(View.FParentDocument) <> nil then
      OuterLayout := FrameViewOfDocument(View.FParentDocument).Layout
    else
      OuterLayout := nil;
    if (OuterLayout = nil) or not FrameContentOrigin(OuterLayout, View.FContainer, X, Y) then
      Exit(False);
    OriginX := OriginX + X;
    OriginY := OriginY + Y;
    if OuterLayout = TopLayout then
      Exit(True);
    View := FrameViewOfDocument(View.FParentDocument);
    Inc(Depth);
  end;
  Result := False;
end;

initialization
  AllViews := TList.Create;

finalization
  AllViews.Free;

end.
