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
  Answers to script's layout questions from a document layout (CSSOM View and
  getComputedStyle, libweb's TScriptLayout): every question first brings
  style and layout up to date (a synchronous layout, as browsers do when
  script reads geometry), then reads the boxes. Its owner (the web view,
  webbrowse) points it at its
  current layout and painter (nil between documents: no boxes).
}
unit Web.Script.Layout;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom,
  Web.ScriptEnvironment,
  Web.Layout.Document,
  Web.Paint.Painter;

type
  TDocumentScriptLayout = class(TScriptLayout)
  private
    function Ready: Boolean;
  protected
    { Points Layout and Painter at the document's layout before a
      question (a frame's: Web.Frames.Views); the embedder's own sets
      them itself. }
    procedure Resolve; virtual;
  public
    Layout: TDocumentLayout;
    Painter: TDocumentPainter;
    { The view scrolled (it repaints): called after ScrollTo. }
    OnScrolled: procedure of object;
    function BorderBox(Element: TElement; out X, Y, Width, Height: Double): Boolean; override;
    function ClientRects(Element: TElement): TScriptRectArray; override;
    function ScrollGeometry(Element: TElement; out ClientLeft, ClientTop, ClientWidth, ClientHeight, ScrollWidth,
      ScrollHeight, ScrollLeft, ScrollTop: Double): Boolean; override;
    procedure ScrollTo(Element: TElement; Left, Top: Double); override;
    procedure ViewportScroll(out Left, Top: Double); override;
    function ElementAtPoint(X, Y: Double): TElement; override;
    function ComputedValue(Element: TElement; const PropertyName: string): string; override;
    function TextRects(Node: TNode; StartOffset, EndOffset: Integer): TScriptRectArray; override;
  end;

implementation

uses
  Css.ComputedStyle,
  Css.PropertyIds,
  Css.Properties,
  Web.Layout.Boxes,
  Web.Layout.BoxGeometry,
  Web.Layout.TextOffsets,
  Web.Layout.Transforms,
  Web.Text.FontInstances,
  Web.Style.NodeData;

procedure TDocumentScriptLayout.Resolve;
begin
end;

function TDocumentScriptLayout.Ready: Boolean;
begin
  Resolve;
  Result := Layout <> nil;
  if Result and Layout.NeedsUpdate then
    Layout.Update;
end;

{ Where the box is drawn rather than laid out: moved by position:
  relative (its own and its ancestors'), by the scroll offsets of the
  scroll containers it is in, and not by the viewport's when it is
  fixed (the caller takes the viewport's scroll off everything). }
procedure DrawnOffset(Layout: TDocumentLayout; Box: TLayoutBox; out OffsetX, OffsetY: Single);
var
  Current: TLayoutBox;
  ViewportX, ViewportY: Single;
  Fixed: Boolean;
begin
  OffsetX := 0;
  OffsetY := 0;
  Fixed := False;
  Current := Box;
  while Current <> nil do
  begin
    if Current.Kind <> bkInline then
    begin
      OffsetX := OffsetX + Current.RelativeX;
      OffsetY := OffsetY + Current.RelativeY;
    end;
    if (Current <> Box) and (bfScrollContainer in Current.Flags) and (Current.Kind <> bkViewport) then
    begin
      OffsetX := OffsetX - Current.ScrollX;
      OffsetY := OffsetY - Current.ScrollY;
    end;
    if bfFixed in Current.Flags then
      Fixed := True;
    Current := Current.Parent;
  end;
  if Fixed then
  begin
    Layout.GetScrollOffset(nil, ViewportX, ViewportY);
    OffsetX := OffsetX + ViewportX;
    OffsetY := OffsetY + ViewportY;
  end;
end;

function TDocumentScriptLayout.ClientRects(Element: TElement): TScriptRectArray;
var
  Box: TLayoutBox;
  Rectangles: TBoxRectangleArray;
  OffsetX, OffsetY, RectX, RectY, RectWidth, RectHeight: Single;
  Index: Integer;
begin
  Result := nil;
  if not Ready then
    Exit;
  Box := Layout.BoxOf(Element);
  if Box = nil then
    Exit;
  Rectangles := BoxRectangles(Box);
  DrawnOffset(Layout, Box, OffsetX, OffsetY);
  SetLength(Result, Length(Rectangles));
  for Index := 0 to High(Rectangles) do
  begin
    RectX := Rectangles[Index].X + OffsetX;
    RectY := Rectangles[Index].Y + OffsetY;
    RectWidth := Rectangles[Index].Width;
    RectHeight := Rectangles[Index].Height;
    TransformRectangle(Box, RectX, RectY, RectWidth, RectHeight);
    Result[Index].X := RectX;
    Result[Index].Y := RectY;
    Result[Index].Width := RectWidth;
    Result[Index].Height := RectHeight;
  end;
end;

function TDocumentScriptLayout.BorderBox(Element: TElement; out X, Y, Width, Height: Double): Boolean;
var
  BoxX, BoxY, BoxWidth, BoxHeight, OffsetX, OffsetY: Single;
begin
  X := 0;
  Y := 0;
  Width := 0;
  Height := 0;
  Result := Ready and Layout.NodeBounds(Element, BoxX, BoxY, BoxWidth, BoxHeight);
  if Result then
  begin
    DrawnOffset(Layout, Layout.BoxOf(Element), OffsetX, OffsetY);
    BoxX := BoxX + OffsetX;
    BoxY := BoxY + OffsetY;
    { Scaled, turned or skewed: the bounds of what is drawn. }
    TransformRectangle(Layout.BoxOf(Element), BoxX, BoxY, BoxWidth, BoxHeight);
    X := BoxX;
    Y := BoxY;
    Width := BoxWidth;
    Height := BoxHeight;
  end;
end;

function TDocumentScriptLayout.ScrollGeometry(Element: TElement; out ClientLeft, ClientTop, ClientWidth, ClientHeight,
  ScrollWidth, ScrollHeight, ScrollLeft, ScrollTop: Double): Boolean;
var
  Box: TLayoutBox;
begin
  ClientLeft := 0;
  ClientTop := 0;
  ClientWidth := 0;
  ClientHeight := 0;
  ScrollWidth := 0;
  ScrollHeight := 0;
  ScrollLeft := 0;
  ScrollTop := 0;
  Result := False;
  if not Ready then
    Exit;
  Box := Layout.BoxOf(Element);
  if (Box = nil) or (Box.Kind in [bkInline, bkText]) then
    Exit;
  ClientLeft := Box.Border[sideLeft];
  ClientTop := Box.Border[sideTop];
  ClientWidth := Box.Width - Box.Border[sideLeft] - Box.Border[sideRight];
  ClientHeight := Box.Height - Box.Border[sideTop] - Box.Border[sideBottom];
  if ClientWidth < 0 then
    ClientWidth := 0;
  if ClientHeight < 0 then
    ClientHeight := 0;
  if bfScrollContainer in Box.Flags then
  begin
    ScrollWidth := Box.ScrollWidth;
    ScrollHeight := Box.ScrollHeight;
    ScrollLeft := Box.ScrollX;
    ScrollTop := Box.ScrollY;
  end;
  if Element = Element.NodeDocument.DocumentElement then
  begin
    ScrollWidth := Layout.DocumentWidth;
    ScrollHeight := Layout.DocumentHeight;
  end;
  if ScrollWidth < ClientWidth then
    ScrollWidth := ClientWidth;
  if ScrollHeight < ClientHeight then
    ScrollHeight := ClientHeight;
  Result := True;
end;

procedure TDocumentScriptLayout.ScrollTo(Element: TElement; Left, Top: Double);
begin
  if not Ready then
    Exit;
  Layout.SetScrollOffset(Element, Left, Top);
  if Assigned(OnScrolled) then
    OnScrolled;
end;

procedure TDocumentScriptLayout.ViewportScroll(out Left, Top: Double);
var
  X, Y: Single;
begin
  Left := 0;
  Top := 0;
  Resolve;
  if Layout = nil then
    Exit;
  Layout.GetScrollOffset(nil, X, Y);
  Left := X;
  Top := Y;
end;

function TDocumentScriptLayout.ElementAtPoint(X, Y: Double): TElement;
begin
  Result := nil;
  if not Ready or (Painter = nil) then
    Exit;
  Painter.Refresh;
  Result := Painter.HitTest(X, Y).Element;
end;

function TDocumentScriptLayout.TextRects(Node: TNode; StartOffset, EndOffset: Integer): TScriptRectArray;
var
  Box: TLayoutBox;
  TextBox: TTextBox;
  Container: TLayoutBox;
  Fragment: PLineFragment;
  Font: TTextFont;
  ContainerX, ContainerY: Single;
  StartByte, EndByte, FragmentStart, FragmentEnd, From, Till, Index: Integer;
  Left, Right: Double;
begin
  Result := nil;
  if not Ready then
    Exit;
  Box := Layout.BoxOf(Node);
  if not (Box is TTextBox) then
    Exit;
  TextBox := TTextBox(Box);
  Container := Box.Parent;
  while (Container <> nil) and ((Container.Kind = bkInline) or (Container.Inline = nil)) do
    Container := Container.Parent;
  if Container = nil then
    Exit;
  Container.AbsolutePosition(ContainerX, ContainerY);
  StartByte := SourceToRenderedOffset(TextBox.SourceText, TextBox.Text, StartOffset);
  EndByte := SourceToRenderedOffset(TextBox.SourceText, TextBox.Text, EndOffset);
  Font := TextFontOf(TextBox.Style);
  for Index := 0 to Container.Inline.FragmentCount - 1 do
  begin
    Fragment := @Container.Inline.Fragments[Index];
    if (Fragment^.Box <> TObject(TextBox)) or (Fragment^.Kind <> fkText) then
      Continue;
    FragmentStart := Fragment^.TextStart - 1;
    FragmentEnd := FragmentStart + Fragment^.TextLength;
    From := StartByte;
    if From < FragmentStart then
      From := FragmentStart;
    Till := EndByte;
    if Till > FragmentEnd then
      Till := FragmentEnd;
    if (Till < From) or ((Till = From) and (StartByte <> EndByte)) then
      Continue;
    Left := Fragment^.X;
    Right := Fragment^.X;
    if Font <> nil then
    begin
      Left := Left + Font.MeasureText(TextBox.Text, FragmentStart + 1, From - FragmentStart);
      Right := Right + Font.MeasureText(TextBox.Text, FragmentStart + 1, Till - FragmentStart);
    end;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].X := ContainerX + Left;
    Result[High(Result)].Y := ContainerY + Fragment^.Y;
    Result[High(Result)].Width := Right - Left;
    Result[High(Result)].Height := Fragment^.Height;
  end;
end;

function TDocumentScriptLayout.ComputedValue(Element: TElement; const PropertyName: string): string;
var
  Style: TCssComputedStyle;
  Id: TCssPropertyId;
begin
  Result := '';
  if not Ready then
    Exit;
  Style := StyleOf(Element);
  if Style = nil then
    Exit;
  Id := PropertyByName(PropertyName);
  if Id = cpCustom then
    Exit(Style.CustomProperty(PropertyName));
  if Id = cpInvalid then
    Exit;
  Result := Style.SerializeProperty(Id);
end;

end.
