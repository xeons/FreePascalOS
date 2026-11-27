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
  script reads geometry; nothing when nothing changed), then reads the
  boxes. A computed value that does not depend on layout brings only the
  styles up to date, as Gecko flushes only style for it. Its owner (the web view,
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
    function StylesReady: Boolean;
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
    function ComputedValue(Element: TElement; const PropertyName: string; const PseudoElement: string = ''): string;
      override;
    function TextRects(Node: TNode; StartOffset, EndOffset: Integer): TScriptRectArray; override;
    function CssAnimations(Element: TElement): TScriptCssAnimationArray; override;
    procedure ControlCssAnimation(Element: TElement; IsTransition: Boolean; const Name: string;
      Action: TScriptCssAnimationAction; Value: Double); override;
  end;

implementation

uses
  Web.Style.Animations,
  Css.ComputedStyle,
  Css.PropertyIds,
  Css.Properties,
  Css.Keywords,
  Css.Serialization,
  Web.Layout.Boxes,
  Web.Layout.BoxGeometry,
  Web.Layout.TextOffsets,
  Web.Layout.Transforms,
  Web.Paint.DisplayList,
  Web.Paint.Sticky,
  Web.Text.FontInstances,
  Web.Style.NodeData,
  Css.Selectors,
  SysUtils;

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

function TDocumentScriptLayout.StylesReady: Boolean;
begin
  Resolve;
  Result := Layout <> nil;
  if Result then
    Layout.UpdateStyles;
end;

{ Where the box is drawn rather than laid out: moved by position:
  relative (its own and its ancestors'), by the scroll offsets of the
  scroll containers it is in, and not by the viewport's when it is
  fixed (the caller takes the viewport's scroll off everything). }
{ How far a position: sticky box under the viewport is moved at the
  scroll offset now, found from its run in the display list the way
  painting, hit testing and the web view's text groups find it. }
procedure AddStickyOffset(Layout: TDocumentLayout; Painter: TDocumentPainter; Box: TLayoutBox;
  var OffsetX, OffsetY: Single);
var
  List: TDisplayList;
  Index: Integer;
  Item: PDisplayItem;
  ScrollX, ScrollY, StickyX, StickyY: Single;
begin
  if Painter = nil then
    Exit;
  Painter.Refresh;
  List := Painter.DisplayList;
  Layout.GetScrollOffset(nil, ScrollX, ScrollY);
  for Index := 0 to List.Count - 1 do
  begin
    Item := @List.Items[Index];
    if (Item^.Kind = diPushSticky) and (Item^.Box = Box) then
    begin
      StickyOffset(List.Stickies[Item^.Index], Item^.X, Item^.Y, Item^.Width, Item^.Height, ScrollX, ScrollY,
        Layout.ViewportWidth, Layout.ViewportHeight, StickyX, StickyY);
      OffsetX := OffsetX + StickyX;
      OffsetY := OffsetY + StickyY;
      Exit;
    end;
  end;
end;

procedure DrawnOffset(Layout: TDocumentLayout; Painter: TDocumentPainter; Box: TLayoutBox;
  out OffsetX, OffsetY: Single);
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
    if bfSticky in Current.Flags then
      AddStickyOffset(Layout, Painter, Current, OffsetX, OffsetY);
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
  DrawnOffset(Layout, Painter, Box, OffsetX, OffsetY);
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
    DrawnOffset(Layout, Painter, Layout.BoxOf(Element), OffsetX, OffsetY);
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

{ The resolved value of width or height (CSSOM 9): the used size of a
  rendered box the property applies to (not a non-replaced inline box),
  by its box-sizing; '' otherwise (the computed value is the answer). }
function UsedSize(Box: TLayoutBox; Id: TCssPropertyId): string;
var
  Size: Single;
begin
  Result := '';
  if (Box = nil) or (Box.Kind in [bkInline, bkText, bkLineBreak]) then
    Exit;
  if Id = cpWidth then
  begin
    Size := Box.Width;
    if Box.Style.Keyword(cpBoxSizing) <> kwBorderBox then
      Size := Box.ContentWidth;
  end
  else
  begin
    Size := Box.Height;
    if Box.Style.Keyword(cpBoxSizing) <> kwBorderBox then
      Size := Size - Box.Border[sideTop] - Box.Border[sideBottom] - Box.Padding[sideTop] - Box.Padding[sideBottom];
  end;
  if Size < 0 then
    Size := 0;
  Result := SerializeNumber(Size) + 'px';
end;

function TDocumentScriptLayout.CssAnimations(Element: TElement): TScriptCssAnimationArray;
var
  Infos: TCssAnimationInfoArray;
  Index: Integer;
begin
  Result := nil;
  if not Ready then
    Exit;
  Infos := Layout.Styler.Animations.Describe(Element);
  SetLength(Result, Length(Infos));
  for Index := 0 to High(Infos) do
  begin
    Result[Index].IsTransition := Infos[Index].IsTransition;
    Result[Index].Name := Infos[Index].Name;
    Result[Index].LocalTime := Infos[Index].LocalTime;
    Result[Index].Delay := Infos[Index].Delay;
    Result[Index].Duration := Infos[Index].Duration;
    Result[Index].Iterations := Infos[Index].Iterations;
    Result[Index].Direction := Infos[Index].Direction;
    Result[Index].Fill := Infos[Index].Fill;
    Result[Index].Paused := Infos[Index].Paused;
    Result[Index].Ended := Infos[Index].Ended;
  end;
end;

procedure TDocumentScriptLayout.ControlCssAnimation(Element: TElement; IsTransition: Boolean; const Name: string;
  Action: TScriptCssAnimationAction; Value: Double);
const
  Actions: array[TScriptCssAnimationAction] of TCssAnimationAction = (caPause, caPlay, caCancel, caSeek);
begin
  if not Ready then
    Exit;
  Layout.Styler.Animations.Control(Element, IsTransition, Name, Actions[Action], Value);
end;

{ getComputedStyle's pseudo-element argument: none for '' (and for a
  name without colons, as browsers take it), else ::name or the legacy
  :before, :after, :first-line and :first-letter; Valid False for any
  other. }
function ParsePseudoArgument(const Text: string; out Valid: Boolean): TCssPseudoElement;
var
  Name: string;
begin
  Valid := True;
  Result := peNone;
  if (Text = '') or (Text[1] <> ':') then
    Exit;
  Name := LowerCase(Text);
  if Copy(Name, 1, 2) = '::' then
    Delete(Name, 1, 2)
  else
  begin
    Delete(Name, 1, 1);
    if (Name <> 'before') and (Name <> 'after') and (Name <> 'first-line') and (Name <> 'first-letter') then
    begin
      Valid := False;
      Exit;
    end;
  end;
  Result := PseudoElementByName(Name);
  Valid := Result <> peNone;
end;

function TDocumentScriptLayout.ComputedValue(Element: TElement; const PropertyName: string;
  const PseudoElement: string): string;
var
  Style: TCssComputedStyle;
  Id: TCssPropertyId;
  Pseudo: TCssPseudoElement;
  Valid, NeedsLayout: Boolean;
begin
  Result := '';
  Pseudo := ParsePseudoArgument(PseudoElement, Valid);
  if not Valid then
    Exit;
  Id := PropertyByName(PropertyName);
  if Id = cpInvalid then
    Exit;
  { Only the used width and height are read from the boxes. }
  NeedsLayout := ((Id = cpWidth) or (Id = cpHeight)) and (Pseudo = peNone);
  if NeedsLayout then
  begin
    if not Ready then
      Exit;
  end
  else if not StylesReady then
    Exit;
  Style := Layout.Styler.StyleForScript(Element, Pseudo);
  if Style = nil then
    Exit;
  try
    if Id = cpCustom then
      Exit(Style.CustomProperty(PropertyName));
    if NeedsLayout then
    begin
      Result := UsedSize(Layout.BoxOf(Element), Id);
      if Result <> '' then
        Exit;
    end;
    Result := Style.SerializeProperty(Id);
  finally
    Style.Release;
  end;
end;

end.
