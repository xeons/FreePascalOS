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
  The row of tabs above the page: each tab shows its page's icon (a
  turning ring while it loads), its title cut with "..." and a close
  button; a "+" after the last opens a new tab. A click picks a tab, a
  click on its cross or a middle click closes it. The chosen tab is
  drawn in the theme's header band (golden in Sunrise), raised on the
  face in Classic; the others are flat on a darker face. Tabs share the
  width, up to 220 logical units each.
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
  Controls.Timers;

type
  TTabIndexEvent = procedure(Sender: TObject; Index: Integer) of object;

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
    FHotNew: Boolean;
    FSpinTimer: TTimer;
    FSpinStep: Integer;
    FOnSelect: TTabIndexEvent;
    FOnClose: TTabIndexEvent;
    FOnNewTab: TControlEvent;
    function GetItem(Index: Integer): TTabStripItem;
    function GetCount: Integer;
    procedure SetActive(Value: Integer);
    function TabWidth: LongInt;
    function TabBox(Index: Integer): TRectangle;
    function CloseBox(Index: Integer): TRectangle;
    function NewTabBox: TRectangle;
    procedure HitAt(X, Y: LongInt; out Tab: Integer; out OverClose, OverNew: Boolean);
    procedure PaintTab(var Canvas: TCanvas; Index: Integer);
    procedure PaintSpinner(var Canvas: TCanvas; const Box: TRectangle);
    procedure SpinTimerFired(Sender: TTimer);
    procedure UpdateSpinTimer;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerLeave; override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    function Add(const Title: string): TTabStripItem;
    procedure Insert(Index: Integer; const Title: string);
    procedure Delete(Index: Integer);
    { The tab changed (title, icon, loading). }
    procedure ItemChanged(Index: Integer);
    function PreferredSize: TSize; override;
    function HintAt(X, Y: LongInt; out Area: TRectangle): string; override;
    property Count: Integer read GetCount;
    property Items[Index: Integer]: TTabStripItem read GetItem;
    property ActiveIndex: Integer read FActive write SetActive;
    property OnSelect: TTabIndexEvent read FOnSelect write FOnSelect;
    property OnClose: TTabIndexEvent read FOnClose write FOnClose;
    property OnNewTab: TControlEvent read FOnNewTab write FOnNewTab;
  end;

implementation

uses
  Math,
  Abi.SystemCalls,
  Drawing.Colors,
  Drawing.Scaling,
  Drawing.SmoothLines,
  Image.Surfaces,
  Image.Scalable,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text,
  Controls.Painting;

const
  StripHeight = 30;
  MaximumTabWidth = 220;
  MinimumTabWidth = 48;
  NewTabWidth = 30;
  IconSize = 16;
  TabGap = 2;
  TabPadding = 8;
  CloseSize = 16;
  SpinInterval = 90;

constructor TTabStrip.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FItems := TList.Create;
  FActive := -1;
  FHotTab := -1;
  FSpinTimer := TTimer.Create(Self);
  FSpinTimer.Interval := SpinInterval;
  FSpinTimer.OnTimer := @SpinTimerFired;
end;

destructor TTabStrip.Destroy;
var
  Index: Integer;
begin
  FSpinTimer.Free;
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
  UpdateSpinTimer;
  Invalidate;
end;

procedure TTabStrip.SetActive(Value: Integer);
begin
  if Value = FActive then
    Exit;
  FActive := Value;
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

{ Pixels. }
function TTabStrip.TabWidth: LongInt;
var
  Room: LongInt;
begin
  if FItems.Count = 0 then
    Exit(Scaled(MaximumTabWidth));
  Room := RectangleWidth(PixelBounds) - Scaled(NewTabWidth + TabGap * 2);
  Result := Min(Scaled(MaximumTabWidth), Room div FItems.Count - Scaled(TabGap));
  Result := Max(Scaled(MinimumTabWidth), Result);
end;

function TTabStrip.TabBox(Index: Integer): TRectangle;
var
  Width: LongInt;
begin
  Width := TabWidth;
  Result := MakeRectangle(Scaled(TabGap) + Index * (Width + Scaled(TabGap)), Scaled(4), Width,
    RectangleHeight(PixelBounds) - Scaled(4));
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
  Left := Scaled(TabGap) + FItems.Count * (TabWidth + Scaled(TabGap));
  Result := MakeRectangle(Left, Scaled(6), Scaled(NewTabWidth - 4), RectangleHeight(PixelBounds) - Scaled(10));
end;

procedure TTabStrip.HitAt(X, Y: LongInt; out Tab: Integer; out OverClose, OverNew: Boolean);
var
  Index: Integer;
begin
  Tab := -1;
  OverClose := False;
  OverNew := RectangleContainsPoint(NewTabBox, X, Y);
  if OverNew then
    Exit;
  for Index := 0 to FItems.Count - 1 do
    if RectangleContainsPoint(TabBox(Index), X, Y) then
    begin
      Tab := Index;
      OverClose := RectangleContainsPoint(CloseBox(Index), X, Y);
      Exit;
    end;
end;

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

procedure TTabStrip.Paint(var Canvas: TCanvas);
var
  Width, Height, Index, Middle, Arm, Thickness: LongInt;
  Box: TRectangle;
begin
  Width := RectangleWidth(PixelBounds);
  Height := RectangleHeight(PixelBounds);
  FillRectangle(Canvas, MakeRectangle(0, 0, Width, Height), Theme.Face);
  DrawHorizontalLine(Canvas, 0, Width, Height - 1, Theme.Shadow);
  for Index := 0 to FItems.Count - 1 do
    if Index <> FActive then
      PaintTab(Canvas, Index);
  if (FActive >= 0) and (FActive < FItems.Count) then
    PaintTab(Canvas, FActive);
  Box := NewTabBox;
  if FHotNew then
  begin
    FillRectangle(Canvas, Box, Theme.HotButtonFace);
    DrawRectangleOutline(Canvas, Box, Theme.Shadow);
  end;
  Middle := (Box.Left + Box.Right) div 2;
  Arm := Scaled(6);
  Thickness := Max(2, Scaled(2));
  FillRectangle(Canvas, MakeRectangle(Middle - Arm, (Box.Top + Box.Bottom - Thickness) div 2, Arm * 2, Thickness),
    Theme.FaceText);
  FillRectangle(Canvas, MakeRectangle(Middle - Thickness div 2, (Box.Top + Box.Bottom) div 2 - Arm, Thickness, Arm * 2),
    Theme.FaceText);
end;

procedure TTabStrip.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Tab: Integer;
  OverClose, OverNew: Boolean;
begin
  inherited PointerMove(X, Y, Buttons);
  HitAt(X, Y, Tab, OverClose, OverNew);
  if (Tab <> FHotTab) or (OverClose <> FHotClose) or (OverNew <> FHotNew) then
  begin
    FHotTab := Tab;
    FHotClose := OverClose;
    FHotNew := OverNew;
    Invalidate;
  end;
end;

procedure TTabStrip.PointerLeave;
begin
  inherited PointerLeave;
  FHotTab := -1;
  FHotClose := False;
  FHotNew := False;
  Invalidate;
end;

procedure TTabStrip.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Tab: Integer;
  OverClose, OverNew: Boolean;
begin
  inherited PointerUp(X, Y, Button);
  HitAt(X, Y, Tab, OverClose, OverNew);
  if OverNew and (Button = ButtonLeft) then
  begin
    if Assigned(FOnNewTab) then
      FOnNewTab(Self);
    Exit;
  end;
  if Tab < 0 then
    Exit;
  if (Button = ButtonMiddle) or ((Button = ButtonLeft) and OverClose) then
  begin
    if Assigned(FOnClose) then
      FOnClose(Self, Tab);
  end
  else if Button = ButtonLeft then
  begin
    if Assigned(FOnSelect) then
      FOnSelect(Self, Tab);
  end;
end;

function TTabStrip.HintAt(X, Y: LongInt; out Area: TRectangle): string;
var
  Tab: Integer;
  OverClose, OverNew: Boolean;
begin
  HitAt(X, Y, Tab, OverClose, OverNew);
  Area := MakeRectangle(0, 0, 0, 0);
  if OverNew then
  begin
    Area := NewTabBox;
    Exit('New tab (Ctrl+T)');
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
