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
  The row of tabs under the toolbars, over the page: each tab shows its
  page's icon (a turning ring while it loads), its title cut with "..."
  and a close button; the new tab button follows the last tab, and the
  list of all tabs drops down from the button at the right. Tabs share
  the width, between 100 and 250 logical units each; when they do not
  fit at the narrowest, arrows at either end scroll them (so does the
  wheel).

  A click picks a tab, its cross or a middle click closes it, a double
  click on the empty part opens a new tab. A tab dragged along the row
  moves; dragged down off the window (or well below the row) it goes to
  a window of its own (OnTearOff). A right click asks for the tab's
  context menu (OnTabMenu). The chosen tab is drawn in the theme's
  header band (golden in Sunrise), raised on the face in Classic; the
  others are flat on a darker face.
}
unit Browser.TabStrip;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Canvas,
  Drawing.Rectangles,
  Image.Model,
  Controls.Base,
  Controls.Menus,
  Controls.Timers;

type
  TTabIndexEvent = procedure(Sender: TObject; Index: Integer) of object;
  TTabMoveEvent = procedure(Sender: TObject; FromIndex, ToIndex: Integer) of object;
  { X, Y: this control's pixels. }
  TTabMenuEvent = procedure(Sender: TObject; Index: Integer; X, Y: LongInt) of object;

  TTabStripItem = class
  public
    Title: string;
    { Not owned. }
    Icon: TImage;
    Loading: Boolean;
  end;

  TTabStrip = class(TControl)
  private
    FItems: TList;
    FActive: Integer;
    FHotTab: Integer;
    FHotClose: Boolean;
    FHotPart: Integer;
    FSpinTimer: TTimer;
    FSpinStep: Integer;
    FScroll: Integer;
    FPressTab: Integer;
    FPressX, FPressY: LongInt;
    FDragging: Boolean;
    FDropIndex: Integer;
    FLastClick: QWord;
    FListMenu: TMenuItem;
    FOnSelect: TTabIndexEvent;
    FOnClose: TTabIndexEvent;
    FOnNewTab: TControlEvent;
    FOnMove: TTabMoveEvent;
    FOnTearOff: TTabIndexEvent;
    FOnTabMenu: TTabMenuEvent;
    function GetItem(Index: Integer): TTabStripItem;
    function GetCount: Integer;
    procedure SetActive(Value: Integer);
    function Overflows: Boolean;
    function TabsLeft: LongInt;
    function TabsRight: LongInt;
    function TabWidth: LongInt;
    function MaximumScroll: Integer;
    function TabBox(Index: Integer): TRectangle;
    function CloseBox(Index: Integer): TRectangle;
    function NewTabBox: TRectangle;
    function ListBox: TRectangle;
    function LeftArrowBox: TRectangle;
    function RightArrowBox: TRectangle;
    procedure HitAt(X, Y: LongInt; out Tab: Integer; out OverClose: Boolean; out Part: Integer);
    procedure PaintTab(var Canvas: TCanvas; Index: Integer);
    procedure PaintSpinner(var Canvas: TCanvas; const Box: TRectangle);
    procedure PaintPartButton(var Canvas: TCanvas; const Box: TRectangle; Hot: Boolean);
    procedure SpinTimerFired(Sender: TTimer);
    procedure UpdateSpinTimer;
    procedure ScrollBy(Steps: Integer);
    procedure OpenListMenu;
    procedure ListItemChosen(Item: TMenuItem);
    function DropIndexAt(X: LongInt): Integer;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerLeave; override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure Wheel(Steps: LongInt); override;
    procedure ContextMenu(X, Y: LongInt; FromKeyboard: Boolean); override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    function Add(const Title: string): TTabStripItem;
    procedure Insert(Index: Integer; const Title: string);
    procedure Delete(Index: Integer);
    procedure Move(FromIndex, ToIndex: Integer);
    { The tab changed (title, icon, loading). }
    procedure ItemChanged(Index: Integer);
    { Scrolls so that tab Index shows. }
    procedure ShowTab(Index: Integer);
    function PreferredSize: TSize; override;
    function HintAt(X, Y: LongInt; out Area: TRectangle): string; override;
    property Count: Integer read GetCount;
    property Items[Index: Integer]: TTabStripItem read GetItem;
    property ActiveIndex: Integer read FActive write SetActive;
    property OnSelect: TTabIndexEvent read FOnSelect write FOnSelect;
    property OnClose: TTabIndexEvent read FOnClose write FOnClose;
    property OnNewTab: TControlEvent read FOnNewTab write FOnNewTab;
    property OnMove: TTabMoveEvent read FOnMove write FOnMove;
    property OnTearOff: TTabIndexEvent read FOnTearOff write FOnTearOff;
    property OnTabMenu: TTabMenuEvent read FOnTabMenu write FOnTabMenu;
  end;

implementation

uses
  Windowing.Windows,
  SysUtils,
  Math,
  Abi.SystemCalls,
  Drawing.Colors,
  Drawing.Scaling,
  Drawing.SmoothLines,
  Image.Surfaces,
  Image.Scalable,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Window,
  Controls.Text,
  Controls.Painting,
  Controls.LayoutRules,
  Browser.BookmarkMenus;

const
  StripHeight = 28;
  MaximumTabWidth = 250;
  MinimumTabWidth = 100;
  PartWidth = 22;
  IconSize = 16;
  TabGap = 2;
  TabPadding = 8;
  CloseSize = 16;
  SpinInterval = 90;
  DragThreshold = 6;
  { How far below the row a dragged tab must go to leave the window. }
  TearOffDistance = 40;
  DoubleClickMilliseconds = 400;
  { The parts besides tabs. }
  PartNone = 0;
  PartNewTab = 1;
  PartList = 2;
  PartLeftArrow = 3;
  PartRightArrow = 4;

constructor TTabStrip.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FItems := TList.Create;
  FActive := -1;
  FHotTab := -1;
  FPressTab := -1;
  FDropIndex := -1;
  FListMenu := TMenuItem.Create('');
  FSpinTimer := TTimer.Create(Self);
  FSpinTimer.Interval := SpinInterval;
  FSpinTimer.OnTimer := @SpinTimerFired;
end;

destructor TTabStrip.Destroy;
var
  Index: Integer;
begin
  FSpinTimer.Free;
  FListMenu.Free;
  for Index := 0 to FItems.Count - 1 do
    TTabStripItem(FItems[Index]).Free;
  FItems.Free;
  inherited Destroy;
end;

function TTabStrip.GetItem(Index: Integer): TTabStripItem;
begin
  Result := TTabStripItem(FItems[Index]);
end;

function TTabStrip.GetCount: Integer;
begin
  Result := FItems.Count;
end;

function TTabStrip.Add(const Title: string): TTabStripItem;
begin
  Result := TTabStripItem.Create;
  Result.Title := Title;
  FItems.Add(Result);
  Invalidate;
end;

procedure TTabStrip.Insert(Index: Integer; const Title: string);
var
  Item: TTabStripItem;
begin
  Item := TTabStripItem.Create;
  Item.Title := Title;
  FItems.Insert(Index, Item);
  if FActive >= Index then
    Inc(FActive);
  Invalidate;
end;

procedure TTabStrip.Delete(Index: Integer);
begin
  TTabStripItem(FItems[Index]).Free;
  FItems.Delete(Index);
  if FActive >= FItems.Count then
    FActive := FItems.Count - 1;
  FHotTab := -1;
  FScroll := EnsureRange(FScroll, 0, MaximumScroll);
  UpdateSpinTimer;
  Invalidate;
end;

procedure TTabStrip.Move(FromIndex, ToIndex: Integer);
begin
  if (FromIndex < 0) or (FromIndex >= FItems.Count) or (ToIndex < 0) or (ToIndex >= FItems.Count) then
    Exit;
  FItems.Move(FromIndex, ToIndex);
  Invalidate;
end;

procedure TTabStrip.SetActive(Value: Integer);
begin
  if Value = FActive then
    Exit;
  FActive := Value;
  ShowTab(Value);
  Invalidate;
end;

procedure TTabStrip.ItemChanged(Index: Integer);
begin
  UpdateSpinTimer;
  Invalidate;
end;

procedure TTabStrip.UpdateSpinTimer;
var
  Index: Integer;
  AnyLoading: Boolean;
begin
  AnyLoading := False;
  for Index := 0 to FItems.Count - 1 do
    if TTabStripItem(FItems[Index]).Loading then
      AnyLoading := True;
  FSpinTimer.Enabled := AnyLoading;
end;

procedure TTabStrip.SpinTimerFired(Sender: TTimer);
begin
  FSpinStep := (FSpinStep + 1) mod 12;
  Invalidate;
end;

function TTabStrip.PreferredSize: TSize;
begin
  Result.Width := 200;
  Result.Height := StripHeight;
end;

{ ---- geometry (pixels) ---- }

function TTabStrip.Overflows: Boolean;
var
  Room: LongInt;
begin
  Room := RectangleWidth(PixelBounds) - Scaled(2 * PartWidth + TabGap * 2);
  Result := FItems.Count * (Scaled(MinimumTabWidth) + Scaled(TabGap)) > Room;
end;

function TTabStrip.TabsLeft: LongInt;
begin
  if Overflows then
    Result := Scaled(PartWidth + TabGap)
  else
    Result := Scaled(TabGap);
end;

{ Where the tabs end: before the new tab button (when it follows them),
  the list button and, when scrolling, the right arrow. }
function TTabStrip.TabsRight: LongInt;
begin
  Result := RectangleWidth(PixelBounds) - Scaled(PartWidth) - Scaled(TabGap);
  if Overflows then
    Dec(Result, Scaled(2 * PartWidth))
  else
    Dec(Result, Scaled(PartWidth + TabGap));
end;

function TTabStrip.TabWidth: LongInt;
var
  Room: LongInt;
begin
  if FItems.Count = 0 then
    Exit(Scaled(MaximumTabWidth));
  Room := TabsRight - TabsLeft;
  Result := Min(Scaled(MaximumTabWidth), Room div FItems.Count - Scaled(TabGap));
  Result := Max(Scaled(MinimumTabWidth), Result);
end;

function TTabStrip.MaximumScroll: Integer;
var
  Shown: Integer;
begin
  if not Overflows then
    Exit(0);
  Shown := Max(1, (TabsRight - TabsLeft) div (TabWidth + Scaled(TabGap)));
  Result := Max(0, FItems.Count - Shown);
end;

function TTabStrip.TabBox(Index: Integer): TRectangle;
var
  Width: LongInt;
begin
  Width := TabWidth;
  Result := MakeRectangle(TabsLeft + (Index - FScroll) * (Width + Scaled(TabGap)), Scaled(3), Width,
    RectangleHeight(PixelBounds) - Scaled(3));
end;

function TTabStrip.CloseBox(Index: Integer): TRectangle;
var
  Box: TRectangle;
  Size: LongInt;
begin
  Box := TabBox(Index);
  Size := Scaled(CloseSize);
  Result := MakeRectangle(Box.Right - Scaled(TabPadding div 2) - Size, Box.Top + (RectangleHeight(Box) - Size) div 2,
    Size, Size);
end;

function TTabStrip.NewTabBox: TRectangle;
var
  Left: LongInt;
begin
  if Overflows then
    Left := RectangleWidth(PixelBounds) - Scaled(2 * PartWidth)
  else
    Left := TabsLeft + FItems.Count * (TabWidth + Scaled(TabGap));
  Result := MakeRectangle(Left, Scaled(5), Scaled(PartWidth - 2), RectangleHeight(PixelBounds) - Scaled(8));
end;

function TTabStrip.ListBox: TRectangle;
begin
  Result := MakeRectangle(RectangleWidth(PixelBounds) - Scaled(PartWidth), Scaled(5), Scaled(PartWidth - 2),
    RectangleHeight(PixelBounds) - Scaled(8));
end;

function TTabStrip.LeftArrowBox: TRectangle;
begin
  Result := MakeRectangle(Scaled(1), Scaled(5), Scaled(PartWidth - 2), RectangleHeight(PixelBounds) - Scaled(8));
end;

function TTabStrip.RightArrowBox: TRectangle;
begin
  Result := MakeRectangle(RectangleWidth(PixelBounds) - Scaled(3 * PartWidth), Scaled(5), Scaled(PartWidth - 2),
    RectangleHeight(PixelBounds) - Scaled(8));
end;

procedure TTabStrip.HitAt(X, Y: LongInt; out Tab: Integer; out OverClose: Boolean; out Part: Integer);
var
  Index: Integer;
begin
  Tab := -1;
  OverClose := False;
  Part := PartNone;
  if RectangleContainsPoint(ListBox, X, Y) then
    Part := PartList
  else if RectangleContainsPoint(NewTabBox, X, Y) then
    Part := PartNewTab
  else if Overflows and RectangleContainsPoint(LeftArrowBox, X, Y) then
    Part := PartLeftArrow
  else if Overflows and RectangleContainsPoint(RightArrowBox, X, Y) then
    Part := PartRightArrow;
  if Part <> PartNone then
    Exit;
  if (X < TabsLeft) or (X >= TabsRight) then
    Exit;
  for Index := FScroll to FItems.Count - 1 do
    if RectangleContainsPoint(TabBox(Index), X, Y) then
    begin
      Tab := Index;
      OverClose := RectangleContainsPoint(CloseBox(Index), X, Y);
      Exit;
    end;
end;

procedure TTabStrip.ShowTab(Index: Integer);
var
  Shown: Integer;
begin
  if (Index < 0) or not Overflows then
  begin
    FScroll := 0;
    Exit;
  end;
  Shown := Max(1, (TabsRight - TabsLeft) div (TabWidth + Scaled(TabGap)));
  if Index < FScroll then
    FScroll := Index
  else if Index >= FScroll + Shown then
    FScroll := Index - Shown + 1;
  FScroll := EnsureRange(FScroll, 0, MaximumScroll);
end;

procedure TTabStrip.ScrollBy(Steps: Integer);
begin
  FScroll := EnsureRange(FScroll + Steps, 0, MaximumScroll);
  Invalidate;
end;

{ ---- painting ---- }

procedure TTabStrip.PaintSpinner(var Canvas: TCanvas; const Box: TRectangle);
var
  Index: Integer;
  CenterX, CenterY, Radius, Angle, DotX, DotY: Double;
  Dot: LongInt;
  Color: TColor;
begin
  CenterX := (Box.Left + Box.Right) / 2;
  CenterY := (Box.Top + Box.Bottom) / 2;
  Radius := RectangleWidth(Box) * 0.38;
  Dot := Max(2, RectangleWidth(Box) div 6);
  for Index := 0 to 7 do
  begin
    Angle := (FSpinStep - Index) * Pi / 6;
    DotX := CenterX + Radius * Cos(Angle);
    DotY := CenterY + Radius * Sin(Angle);
    Color := WithAlpha(Theme.Selection, 255 - Index * 28);
    FillRectangle(Canvas, MakeRectangle(Round(DotX) - Dot div 2, Round(DotY) - Dot div 2, Dot, Dot), Color);
  end;
end;

procedure TTabStrip.PaintTab(var Canvas: TCanvas; Index: Integer);
var
  Item: TTabStripItem;
  Box, IconBox, TextBox, Cross: TRectangle;
  Active: Boolean;
  TextColor, CrossColor: TColor;
  Size, Inset: LongInt;
  Icon: TImage;
begin
  Item := Items[Index];
  Box := TabBox(Index);
  if (Box.Right <= TabsLeft) or (Box.Left >= TabsRight) then
    Exit;
  Active := Index = FActive;
  if Active then
  begin
    if Theme.HeaderBandsShown then
    begin
      DrawHeaderBand(Canvas, Box, BandHeader);
      TextColor := HeaderBandText(BandHeader);
    end
    else
    begin
      FillRectangle(Canvas, Box, Theme.Face);
      DrawRaisedEdge(Canvas, MakeRectangle(Box.Left, Box.Top, RectangleWidth(Box), RectangleHeight(Box) + Scaled(2)));
      TextColor := Theme.FaceText;
    end;
  end
  else
  begin
    if Index = FHotTab then
      FillRectangle(Canvas, Box, Theme.HotButtonFace)
    else
      FillRectangle(Canvas, Box, Theme.Light);
    DrawRectangleOutline(Canvas, Box, Theme.Shadow);
    TextColor := Theme.FaceText;
  end;
  Size := Scaled(IconSize);
  IconBox := MakeRectangle(Box.Left + Scaled(TabPadding), Box.Top + (RectangleHeight(Box) - Size) div 2, Size, Size);
  if Item.Loading then
    PaintSpinner(Canvas, IconBox)
  else if Item.Icon <> nil then
  begin
    { A vector icon (SVG) is drawn again at the size shown. }
    Icon := Item.Icon;
    if Icon is TScalableImage then
      Icon := TScalableImage(Icon).RenderedAt(Size, Size);
    if Icon = nil then
      Icon := Item.Icon;
    DrawSurfaceScaled(Canvas, ImageSurface(Icon), MakeRectangle(0, 0, Icon.Width, Icon.Height), IconBox, True);
  end
  else
  begin
    { A page without an icon: a small sheet. }
    Inset := Max(1, Size div 8);
    FillRectangle(Canvas, MakeRectangle(IconBox.Left + Inset * 2, IconBox.Top + Inset, Size - Inset * 4, Size - Inset * 2),
      Theme.Field);
    DrawRectangleOutline(Canvas, MakeRectangle(IconBox.Left + Inset * 2, IconBox.Top + Inset, Size - Inset * 4,
      Size - Inset * 2), Theme.Shadow);
  end;
  Cross := CloseBox(Index);
  TextBox := MakeRectangle(IconBox.Right + Scaled(6), Box.Top, Cross.Left - IconBox.Right - Scaled(8),
    RectangleHeight(Box));
  if Active then
    DrawTextInBox(Canvas, ControlBoldFace, Item.Title, TextBox, AlignTextLeft, TextColor)
  else
    DrawTextInBox(Canvas, ControlFace, Item.Title, TextBox, AlignTextLeft, TextColor);
  CrossColor := TextColor;
  if (Index = FHotTab) and FHotClose then
  begin
    FillRectangle(Canvas, Cross, WithAlpha(Theme.DarkShadow, 60));
    CrossColor := Theme.FaceText;
  end;
  Inset := Max(3, RectangleWidth(Cross) div 4);
  DrawSmoothLine(Canvas, Cross.Left + Inset, Cross.Top + Inset, Cross.Right - Inset, Cross.Bottom - Inset,
    Max(1, Scaled(15) div 10), CrossColor);
  DrawSmoothLine(Canvas, Cross.Right - Inset, Cross.Top + Inset, Cross.Left + Inset, Cross.Bottom - Inset,
    Max(1, Scaled(15) div 10), CrossColor);
end;

procedure TTabStrip.PaintPartButton(var Canvas: TCanvas; const Box: TRectangle; Hot: Boolean);
begin
  if Hot then
  begin
    FillRectangle(Canvas, Box, Theme.HotButtonFace);
    DrawRectangleOutline(Canvas, Box, Theme.Shadow);
  end;
end;

procedure TTabStrip.Paint(var Canvas: TCanvas);
var
  Width, Height, Index, Middle, Arm, Thickness, X: LongInt;
  Box: TRectangle;
  Clipped: TCanvas;
begin
  Width := RectangleWidth(PixelBounds);
  Height := RectangleHeight(PixelBounds);
  FillRectangle(Canvas, MakeRectangle(0, 0, Width, Height), Theme.Face);
  DrawHorizontalLine(Canvas, 0, Width, Height - 1, Theme.Shadow);
  Clipped := Canvas;
  NarrowCanvasClip(Clipped, MakeRectangle(TabsLeft, 0, TabsRight - TabsLeft, Height));
  for Index := 0 to FItems.Count - 1 do
    if Index <> FActive then
      PaintTab(Clipped, Index);
  if (FActive >= 0) and (FActive < FItems.Count) then
    PaintTab(Clipped, FActive);
  if FDragging and (FDropIndex >= 0) then
  begin
    if FDropIndex < FItems.Count then
      X := TabBox(FDropIndex).Left - Scaled(1)
    else
      X := TabBox(FItems.Count - 1).Right + Scaled(1);
    FillRectangle(Clipped, MakeRectangle(X - Scaled(1), Scaled(2), Max(2, Scaled(3)), Height - Scaled(4)),
      Theme.Selection);
  end;
  { The new tab button: a plus. }
  Box := NewTabBox;
  PaintPartButton(Canvas, Box, FHotPart = PartNewTab);
  Middle := (Box.Left + Box.Right) div 2;
  Arm := Scaled(5);
  Thickness := Max(2, Scaled(2));
  FillRectangle(Canvas, MakeRectangle(Middle - Arm, (Box.Top + Box.Bottom - Thickness) div 2, Arm * 2, Thickness),
    Theme.FaceText);
  FillRectangle(Canvas, MakeRectangle(Middle - Thickness div 2, (Box.Top + Box.Bottom) div 2 - Arm, Thickness, Arm * 2),
    Theme.FaceText);
  { The list of all tabs. }
  Box := ListBox;
  PaintPartButton(Canvas, Box, FHotPart = PartList);
  DrawArrowGlyph(Canvas, Box, ArrowDown, Max(3, Scaled(4)), Theme.FaceText);
  if Overflows then
  begin
    Box := LeftArrowBox;
    PaintPartButton(Canvas, Box, FHotPart = PartLeftArrow);
    if FScroll > 0 then
      DrawArrowGlyph(Canvas, Box, ArrowLeft, Max(3, Scaled(4)), Theme.FaceText)
    else
      DrawArrowGlyph(Canvas, Box, ArrowLeft, Max(3, Scaled(4)), Theme.DisabledText);
    Box := RightArrowBox;
    PaintPartButton(Canvas, Box, FHotPart = PartRightArrow);
    if FScroll < MaximumScroll then
      DrawArrowGlyph(Canvas, Box, ArrowRight, Max(3, Scaled(4)), Theme.FaceText)
    else
      DrawArrowGlyph(Canvas, Box, ArrowRight, Max(3, Scaled(4)), Theme.DisabledText);
  end;
end;

{ ---- the pointer ---- }

function TTabStrip.DropIndexAt(X: LongInt): Integer;
var
  Index: Integer;
  Box: TRectangle;
begin
  for Index := FScroll to FItems.Count - 1 do
  begin
    Box := TabBox(Index);
    if X < (Box.Left + Box.Right) div 2 then
      Exit(Index);
  end;
  Result := FItems.Count;
end;

procedure TTabStrip.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Tab, Part: Integer;
  OverClose: Boolean;
  Now: QWord;
begin
  FPressTab := -1;
  if Button <> ButtonLeft then
    Exit;
  HitAt(X, Y, Tab, OverClose, Part);
  case Part of
    PartLeftArrow:
      ScrollBy(-1);
    PartRightArrow:
      ScrollBy(1);
    PartList:
      OpenListMenu;
  end;
  if Part <> PartNone then
    Exit;
  if Tab < 0 then
  begin
    { A double click on the empty part: a new tab. }
    Now := GetTickCount64;
    if (Now - FLastClick < DoubleClickMilliseconds) and Assigned(FOnNewTab) then
    begin
      FLastClick := 0;
      FOnNewTab(Self);
    end
    else
      FLastClick := Now;
    Exit;
  end;
  if OverClose then
    Exit;
  FPressTab := Tab;
  FPressX := X;
  FPressY := Y;
  FDragging := False;
  if Assigned(FOnSelect) then
    FOnSelect(Self, Tab);
end;

procedure TTabStrip.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Tab, Part: Integer;
  OverClose: Boolean;
begin
  inherited PointerMove(X, Y, Buttons);
  if (FPressTab >= 0) and ((Buttons and (LongWord(1) shl ButtonLeft)) <> 0) then
  begin
    if not FDragging and ((Abs(X - FPressX) >= Scaled(DragThreshold)) or (Abs(Y - FPressY) >= Scaled(DragThreshold))) then
      FDragging := True;
    if FDragging then
    begin
      FDropIndex := DropIndexAt(X);
      Invalidate;
    end;
    Exit;
  end;
  HitAt(X, Y, Tab, OverClose, Part);
  if (Tab <> FHotTab) or (OverClose <> FHotClose) or (Part <> FHotPart) then
  begin
    FHotTab := Tab;
    FHotClose := OverClose;
    FHotPart := Part;
    Invalidate;
  end;
end;

procedure TTabStrip.PointerLeave;
begin
  inherited PointerLeave;
  FHotTab := -1;
  FHotClose := False;
  FHotPart := PartNone;
  Invalidate;
end;

procedure TTabStrip.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Tab, Part, Target, Source: Integer;
  OverClose, Outside: Boolean;
begin
  inherited PointerUp(X, Y, Button);
  if FDragging and (Button = ButtonLeft) then
  begin
    Source := FPressTab;
    FDragging := False;
    FPressTab := -1;
    FDropIndex := -1;
    Invalidate;
    Outside := (Y > RectangleHeight(PixelBounds) + Scaled(TearOffDistance)) or (Y < -Scaled(TearOffDistance)) or
      (Host = nil);
    if not Outside and (Host <> nil) and (Host.OwnerWindow is TControlWindow) then
      Outside := (PixelBounds.Left + X < 0) or (PixelBounds.Left + X >= TControlWindow(Host.OwnerWindow).Root.PixelBounds.Right);
    if Outside then
    begin
      if Assigned(FOnTearOff) and (FItems.Count > 1) then
        FOnTearOff(Self, Source);
      Exit;
    end;
    Target := DropIndexAt(X);
    if Target > Source then
      Dec(Target);
    if (Target <> Source) and Assigned(FOnMove) then
      FOnMove(Self, Source, EnsureRange(Target, 0, FItems.Count - 1));
    Exit;
  end;
  FPressTab := -1;
  HitAt(X, Y, Tab, OverClose, Part);
  if (Part = PartNewTab) and (Button = ButtonLeft) then
  begin
    if Assigned(FOnNewTab) then
      FOnNewTab(Self);
    Exit;
  end;
  if Tab < 0 then
    Exit;
  if (Button = ButtonMiddle) or ((Button = ButtonLeft) and OverClose) then
    if Assigned(FOnClose) then
      FOnClose(Self, Tab);
end;

procedure TTabStrip.Wheel(Steps: LongInt);
begin
  if Overflows then
    ScrollBy(Steps)
  else
    inherited Wheel(Steps);
end;

procedure TTabStrip.ContextMenu(X, Y: LongInt; FromKeyboard: Boolean);
var
  Tab, Part: Integer;
  OverClose: Boolean;
begin
  HitAt(X, Y, Tab, OverClose, Part);
  if FromKeyboard then
    Tab := FActive;
  if Assigned(FOnTabMenu) then
    FOnTabMenu(Self, Tab, X, Y);
end;

procedure TTabStrip.OpenListMenu;
var
  Index: Integer;
  Item: TMenuItem;
  Window: TControlWindow;
  Box: TRectangle;
begin
  FListMenu.Clear;
  for Index := 0 to FItems.Count - 1 do
  begin
    Item := FListMenu.Add(MenuCaption(Items[Index].Title), @ListItemChosen);
    Item.Tag := Index;
    Item.Checked := Index = FActive;
  end;
  if (Host = nil) or not (Host.OwnerWindow is TControlWindow) then
    Exit;
  Window := TControlWindow(Host.OwnerWindow);
  Box := ListBox;
  ShowPopupMenu(Window, FListMenu, Window.ScreenLeft + Unscaled(PixelBounds.Left + Box.Right) - 200,
    Window.ScreenTop + Unscaled(PixelBounds.Top + Box.Bottom));
end;

procedure TTabStrip.ListItemChosen(Item: TMenuItem);
begin
  if Assigned(FOnSelect) then
    FOnSelect(Self, Item.Tag);
end;

function TTabStrip.HintAt(X, Y: LongInt; out Area: TRectangle): string;
var
  Tab, Part: Integer;
  OverClose: Boolean;
begin
  HitAt(X, Y, Tab, OverClose, Part);
  Area := MakeRectangle(0, 0, 0, 0);
  case Part of
    PartNewTab:
      begin
        Area := NewTabBox;
        Exit('Open a new tab (Ctrl+T)');
      end;
    PartList:
      begin
        Area := ListBox;
        Exit('List all tabs');
      end;
    PartLeftArrow, PartRightArrow:
      Exit('Scroll the tabs');
  end;
  if Tab < 0 then
    Exit('');
  if OverClose then
  begin
    Area := CloseBox(Tab);
    Exit('Close tab (Ctrl+W)');
  end;
  Area := TabBox(Tab);
  Result := Items[Tab].Title;
end;

end.
