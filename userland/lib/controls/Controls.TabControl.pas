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
  Tab controls: pages on top of each other, chosen by tabs along the
  top.

  AddPage gives a new page (a control to put others on) under a tab;
  clicking a tab, or Ctrl+Tab and the Left and Right arrows while the
  tab control has the focus, shows another page. A new page shown is
  announced (OnChange, NotifyChanged).
}
unit Controls.TabControl;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Canvas,
  Controls.Base;

type
  TTabControl = class(TControl)
  private
    FPages: TList;
    FPageIndex: LongInt;
    function TabHeight: LongInt;
    function TabLeft(Index: LongInt): LongInt;
    function TabWidth(Index: LongInt): LongInt;
    function GetPage(Index: LongInt): TControl;
    function GetPageCount: LongInt;
    procedure SetPageIndex(Value: LongInt);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure Layout; override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    function AddPage(const Caption: string): TControl;
    property PageCount: LongInt read GetPageCount;
    property Pages[Index: LongInt]: TControl read GetPage;
    property PageIndex: LongInt read FPageIndex write SetPageIndex;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text,
  Controls.Panels;

constructor TTabControl.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  FPages := TList.Create;
  FPageIndex := -1;
end;

destructor TTabControl.Destroy;
begin
  FPages.Free;
  inherited Destroy;
end;

function TTabControl.GetPage(Index: LongInt): TControl;
begin
  Result := TControl(FPages[Index]);
end;

function TTabControl.GetPageCount: LongInt;
begin
  Result := FPages.Count;
end;

function TTabControl.TabHeight: LongInt;
begin
  Result := TextHeight(ControlFace) + Scaled(8);
end;

function TTabControl.TabWidth(Index: LongInt): LongInt;
begin
  Result := TextWidth(ControlFace, Pages[Index].Text) + Scaled(16);
end;

function TTabControl.TabLeft(Index: LongInt): LongInt;
var
  Position: LongInt;
begin
  Result := Scaled(2);
  for Position := 0 to Index - 1 do
    Result := Result + TabWidth(Position);
end;

function TTabControl.AddPage(const Caption: string): TControl;
begin
  Result := TPanel.Create(Self);
  Result.Text := Caption;
  FPages.Add(Result);
  Result.Visible := FPages.Count = 1;
  if FPageIndex < 0 then
    FPageIndex := 0;
  Layout;
  Invalidate;
end;

procedure TTabControl.Layout;
var
  Index: LongInt;
  Area: TRectangle;
begin
  { Each page fills the space under the tabs, inside the frame. }
  Area := MakeRectangle(Unscaled(3), Unscaled(TabHeight + 3), Unscaled(RectangleWidth(PixelBounds) - 6),
    Unscaled(RectangleHeight(PixelBounds) - TabHeight - 6));
  for Index := 0 to FPages.Count - 1 do
    Pages[Index].AssignBounds(Area.Left, Area.Top, RectangleWidth(Area), RectangleHeight(Area));
  inherited Layout;
end;

procedure TTabControl.SetPageIndex(Value: LongInt);
var
  Index: LongInt;
begin
  if (Value < 0) or (Value >= FPages.Count) or (Value = FPageIndex) then
    Exit;
  FPageIndex := Value;
  for Index := 0 to FPages.Count - 1 do
    Pages[Index].Visible := Index = Value;
  Invalidate;
  Changed;
end;

procedure TTabControl.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Frame: TRectangle;
  Index: LongInt;
  Tab: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  Frame := MakeRectangle(0, TabHeight, RectangleWidth(Box), RectangleHeight(Box) - TabHeight);
  DrawBevel(Canvas, Frame, RaisedThemeBevel);
  for Index := 0 to FPages.Count - 1 do
  begin
    Tab := MakeRectangle(TabLeft(Index), Scaled(2), TabWidth(Index), TabHeight - Scaled(2));
    if Index = FPageIndex then
      { The chosen tab stands out and joins its page. }
      Tab := MakeRectangle(Tab.Left - Scaled(2), 0, RectangleWidth(Tab) + Scaled(4), TabHeight + 2);
    FillRectangle(Canvas, Tab, Theme.Face);
    DrawHorizontalLine(Canvas, Tab.Left + 2, Tab.Right - 2, Tab.Top, Theme.Highlight);
    DrawVerticalLine(Canvas, Tab.Left, Tab.Top + 2, Tab.Bottom, Theme.Highlight);
    DrawPixel(Canvas, Tab.Left + 1, Tab.Top + 1, Theme.Highlight);
    DrawVerticalLine(Canvas, Tab.Right - 1, Tab.Top + 2, Tab.Bottom, Theme.DarkShadow);
    DrawVerticalLine(Canvas, Tab.Right - 2, Tab.Top + 1, Tab.Bottom, Theme.Shadow);
    DrawTextInBox(Canvas, ControlFace, Pages[Index].Text, Tab, AlignTextCenter, Theme.FaceText);
    if (Index = FPageIndex) and Focused then
      DrawFocusFrame(Canvas, InflateRectangle(Tab, -Scaled(3)), Theme.FaceText);
  end;
end;

procedure TTabControl.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Index: LongInt;
begin
  if (Button <> ButtonLeft) or (Y >= TabHeight) then
    Exit;
  for Index := 0 to FPages.Count - 1 do
    if (X >= TabLeft(Index)) and (X < TabLeft(Index) + TabWidth(Index)) then
      PageIndex := Index;
end;

function TTabControl.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  Result := True;
  if Code = KeyArrowLeft then
    PageIndex := FPageIndex - 1
  else if Code = KeyArrowRight then
    PageIndex := FPageIndex + 1
  else if (Code = KeyTab) and ((Modifiers and ModifierControl) <> 0) then
    PageIndex := (FPageIndex + 1) mod FPages.Count
  else
    Result := False;
end;

end.
