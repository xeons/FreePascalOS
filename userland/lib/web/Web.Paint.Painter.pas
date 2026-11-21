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
  Painting and hit testing a document: what a web view calls.

  TDocumentPainter keeps the display list of a TDocumentLayout and
  builds it again only when the layout's paint version moved (a
  restyle, a relayout, an image, a scroll of an inner container).
  Paint draws a rectangle of the viewport onto a surface at the
  viewport's scroll offset; HitTest finds the node drawn topmost at a
  viewport point, walking the same list (clips and fixed boxes
  included).
}
unit Web.Paint.Painter;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Surfaces, Drawing.Rectangles, Web.Dom, Web.Layout.Boxes, Web.Layout.Document, Web.Paint.DisplayList;

type
  THitTestResult = record
    { The node drawn there (a text node for text), nil for the canvas. }
    Node: TNode;
    { The nearest element at or above Node. }
    Element: TElement;
    Box: TLayoutBox;
    { The point in the document (CSS px). }
    DocumentX, DocumentY: Single;
  end;

  TDocumentPainter = class
  private
    FLayout: TDocumentLayout;
    FList: TDisplayList;
    FBuiltVersion: LongWord;
    FBuilt: Boolean;
  public
    constructor Create(Layout: TDocumentLayout);
    destructor Destroy; override;
    { Builds the display list if the layout changed (after Layout.Update). }
    procedure Refresh;
    { Draws Damage (device pixels of Surface, which shows the viewport). }
    procedure Paint(const Surface: TSurface; const Damage: TRectangle);
    { The same for a surface whose device pixel (0, 0) shows the
      viewport's device pixel (ShiftX, ShiftY): a frame's document
      painted into the part of its box that is visible. }
    procedure PaintShifted(const Surface: TSurface; const Damage: TRectangle; ShiftX, ShiftY: LongInt);
    { The node at a viewport point (CSS px). }
    function HitTest(X, Y: Single): THitTestResult;
    property DisplayList: TDisplayList read FList;
    { The layout's display list version the list was built at. }
    property BuiltVersion: LongWord read FBuiltVersion;
  end;

implementation

uses
  Web.Profiling,
  Math, Web.Paint.Builder, Web.Paint.Raster, Web.Paint.Sticky;

constructor TDocumentPainter.Create(Layout: TDocumentLayout);
begin
  inherited Create;
  FLayout := Layout;
  FList := TDisplayList.Create;
end;

destructor TDocumentPainter.Destroy;
begin
  FList.Free;
  inherited Destroy;
end;

procedure TDocumentPainter.Refresh;
begin
  if FBuilt and (FBuiltVersion = FLayout.DisplayListVersion) then
    Exit;
  EnterPhase(PhasePaint);
  try
    BuildDisplayList(FLayout.Root, FLayout.Resources, FList);
  finally
    LeavePhase;
  end;
  FBuiltVersion := FLayout.DisplayListVersion;
  FBuilt := True;
end;

procedure TDocumentPainter.Paint(const Surface: TSurface; const Damage: TRectangle);
begin
  PaintShifted(Surface, Damage, 0, 0);
end;

procedure TDocumentPainter.PaintShifted(const Surface: TSurface; const Damage: TRectangle; ShiftX, ShiftY: LongInt);
var
  View: TRasterView;
  ScrollX, ScrollY: Single;
begin
  Refresh;
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  View.ScrollX := ScrollX;
  View.ScrollY := ScrollY;
  View.ShiftX := ShiftX;
  View.ShiftY := ShiftY;
  View.Scale := FLayout.Scale;
  View.ViewportWidth := FLayout.ViewportWidth;
  View.ViewportHeight := FLayout.ViewportHeight;
  View.Damage := Damage;
  EnterPhase(PhasePaint);
  try
    RasterizeDisplayList(FList, Surface, View);
  finally
    LeavePhase;
  end;
end;

function TDocumentPainter.HitTest(X, Y: Single): THitTestResult;
type
  TClip = record
    Left, Top, Right, Bottom: Single;
  end;
  TOriginPoint = record
    X, Y: Single;
  end;
var
  Clips: array of TClip;
  ClipCount, Index: Integer;
  Origins: array of TOriginPoint;
  OriginDepth: Integer;
  Item: PDisplayItem;
  ScrollX, ScrollY, PointX, PointY, OriginX, OriginY, OffsetX, OffsetY: Single;
  Inside: Boolean;
  Box: TLayoutBox;
  Node: TNode;
begin
  Result := Default(THitTestResult);
  Refresh;
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  Result.DocumentX := X + ScrollX;
  Result.DocumentY := Y + ScrollY;
  Clips := nil;
  SetLength(Clips, 16);
  ClipCount := 0;
  Origins := nil;
  OriginDepth := 0;
  OriginX := ScrollX;
  OriginY := ScrollY;
  Box := nil;
  for Index := 0 to FList.Count - 1 do
  begin
    Item := @FList.Items[Index];
    PointX := X + OriginX;
    PointY := Y + OriginY;
    case Item^.Kind of
      diPushClip:
        begin
          if ClipCount >= Length(Clips) then
            SetLength(Clips, ClipCount * 2);
          Clips[ClipCount].Left := Item^.X;
          Clips[ClipCount].Top := Item^.Y;
          Clips[ClipCount].Right := Item^.X + Item^.Width;
          Clips[ClipCount].Bottom := Item^.Y + Item^.Height;
          if ClipCount > 0 then
          begin
            Clips[ClipCount].Left := Max(Clips[ClipCount].Left, Clips[ClipCount - 1].Left);
            Clips[ClipCount].Top := Max(Clips[ClipCount].Top, Clips[ClipCount - 1].Top);
            Clips[ClipCount].Right := Min(Clips[ClipCount].Right, Clips[ClipCount - 1].Right);
            Clips[ClipCount].Bottom := Min(Clips[ClipCount].Bottom, Clips[ClipCount - 1].Bottom);
          end;
          Inc(ClipCount);
        end;
      diPopClip:
        if ClipCount > 0 then
          Dec(ClipCount);
      diPushFixed, diPushSticky:
        begin
          if OriginDepth >= Length(Origins) then
            SetLength(Origins, OriginDepth * 2 + 4);
          Origins[OriginDepth].X := OriginX;
          Origins[OriginDepth].Y := OriginY;
          Inc(OriginDepth);
          if Item^.Kind = diPushFixed then
          begin
            OriginX := 0;
            OriginY := 0;
          end
          else
          begin
            StickyOffset(FList.Stickies[Item^.Index], Item^.X, Item^.Y, Item^.Width, Item^.Height, OriginX,
              OriginY, FLayout.ViewportWidth, FLayout.ViewportHeight, OffsetX, OffsetY);
            OriginX := OriginX - OffsetX;
            OriginY := OriginY - OffsetY;
          end;
        end;
      diPopFixed, diPopSticky:
        if OriginDepth > 0 then
        begin
          Dec(OriginDepth);
          OriginX := Origins[OriginDepth].X;
          OriginY := Origins[OriginDepth].Y;
        end;
      diPushOpacity, diPopOpacity:
        ;
    else
      begin
        Inside := (PointX >= Item^.X) and (PointX < Item^.X + Item^.Width) and (PointY >= Item^.Y) and
          (PointY < Item^.Y + Item^.Height);
        if Inside and (ClipCount > 0) then
          Inside := (PointX >= Clips[ClipCount - 1].Left) and (PointX < Clips[ClipCount - 1].Right) and
            (PointY >= Clips[ClipCount - 1].Top) and (PointY < Clips[ClipCount - 1].Bottom);
        if Inside and (Item^.Box <> nil) then
          Box := Item^.Box;
      end;
    end;
  end;
  Result.Box := Box;
  while (Box <> nil) and (Box.Node = nil) do
    Box := Box.Parent;
  if Box = nil then
    Exit;
  Node := Box.Node;
  Result.Node := Node;
  while (Node <> nil) and not Node.IsElement do
    Node := Node.ParentNode;
  Result.Element := TElement(Node);
end;

end.
