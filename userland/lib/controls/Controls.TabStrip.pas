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
  Tab strips: a row of document tabs along the top of a window, each a
  view the window can show (a file manager's folders, a browser's
  pages). Unlike a tab control it holds no pages: the program shows
  what the active tab stands for.

  A tab has a caption, a picture from the strip's Images, a hint and a
  pointer of the program's own (Data). The tabs share the strip's width,
  each between a minimum and a maximum (Controls.TabStripLayout), their
  captions cut with "...". A "+" button follows the last tab (OnNewTab);
  the active tab and the one under the pointer have a close button
  (OnCloseTab), as does a middle click. Pressing a tab makes it active
  (OnChange: only what the user does is announced, not ActiveIndex set
  by the program). Dragged sideways a tab moves among the others as it
  goes (OnTabMoved, for each step); dragged out of the strip, above or
  below it, and let go there it asks to become a window of its own
  (OnTabDraggedOut, with where on the screen it was let go). A right
  click (or the context menu key) gives OnTabContextMenu.

  With header bands (Sunrise) the strip is recessed, the active tab is
  the face colour running down into the content below with a gold line
  along its top, and the others are flat between thin separators; the
  classic look has bevelled tabs like a tab control's.
}
unit Controls.TabStrip;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.Base,
  Controls.ImageList;

type
  TTabStripEvent = procedure(Sender: TControl; Index: LongInt) of object;
  TTabMovedEvent = procedure(Sender: TControl; FromIndex, ToIndex: LongInt) of object;
  { (ScreenX, ScreenY): where it was let go, logical units of the screen
    (where a new window would go). }
  TTabDraggedOutEvent = procedure(Sender: TControl; Index: LongInt; ScreenX, ScreenY: LongInt) of object;
  { (X, Y): the strip's own pixels. }
  TTabContextMenuEvent = procedure(Sender: TControl; Index: LongInt; X, Y: LongInt) of object;

  TStripTab = record
    Caption: string;
    ImageIndex: LongInt;
    Hint: string;
    Data: Pointer;
  end;

  TTabStrip = class(TControl)
  private
    FTabs: array of TStripTab;
    FActiveIndex: LongInt;
    FImages: TImageList;
    { Under the pointer: a tab, its close button, the "+" button. }
    FHotIndex: LongInt;
    FHotClose: Boolean;
    FHotNewTab: Boolean;
    { Pressed: a tab's close button, the "+" button, a tab with the
      middle button. }
    FPressedClose: LongInt;
    FPressedNewTab: Boolean;
    FMiddlePressed: LongInt;
    { A tab held with the left button: which, where it was pressed and
      held from, whether it is being dragged and whether out. }
    FHeldIndex: LongInt;
    FPressX: LongInt;
    FPressY: LongInt;
    FGrabOffset: LongInt;
    FDragX: LongInt;
    FDragging: Boolean;
    FDraggedOut: Boolean;
    FOnNewTab: TControlEvent;
    FOnCloseTab: TTabStripEvent;
    FOnTabMoved: TTabMovedEvent;
    FOnTabDraggedOut: TTabDraggedOutEvent;
    FOnTabContextMenu: TTabContextMenuEvent;
    function GetTabCount: LongInt;
    function GetCaption(Index: LongInt): string;
    procedure SetCaption(Index: LongInt; const Value: string);
    function GetImageIndex(Index: LongInt): LongInt;
    procedure SetImageIndex(Index, Value: LongInt);
    function GetTabHint(Index: LongInt): string;
    procedure SetTabHint(Index: LongInt; const Value: string);
    function GetData(Index: LongInt): Pointer;
    procedure SetData(Index: LongInt; Value: Pointer);
    procedure SetActiveIndex(Value: LongInt);
    procedure SetImages(Value: TImageList);
    function ValidIndex(Index: LongInt): Boolean;
    function FirstLeft: LongInt;
    function TabTop: LongInt;
    function TabWidth: LongInt;
    function TabAt(X, Y: LongInt): LongInt;
    function HasCloseButton(Index: LongInt): Boolean;
    function CloseButtonAt(Index, X, Y: LongInt): Boolean;
    function DraggedLeft: LongInt;
    procedure UpdateHot(X, Y: LongInt);
    procedure DragTo(X, Y: LongInt);
    procedure ClearHeld;
    procedure PaintBackground(var Canvas: TCanvas);
    procedure PaintTab(var Canvas: TCanvas; Index: LongInt; const Tab: TRectangle);
    procedure PaintTabFace(var Canvas: TCanvas; Index: LongInt; const Tab: TRectangle);
    procedure PaintTabContent(var Canvas: TCanvas; Index: LongInt; const Tab: TRectangle);
    procedure PaintNewTabButton(var Canvas: TCanvas);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure PointerLeave; override;
    procedure ContextMenu(X, Y: LongInt; FromKeyboard: Boolean); override;
  public
    constructor Create(AParent: TControl); override;
    { A new tab after the last; its index. }
    function AddTab(const Caption: string; ImageIndex: LongInt = -1): LongInt;
    { A new tab at Index (the ones from there move up); Index. }
    function InsertTab(Index: LongInt; const Caption: string; ImageIndex: LongInt = -1): LongInt;
    { Takes tab Index away; the active tab stays the same one if it was
      another, else the one that took its place (or the new last). Not
      announced. }
    procedure DeleteTab(Index: LongInt);
    { Moves tab FromIndex to ToIndex (the active one stays active). }
    procedure MoveTab(FromIndex, ToIndex: LongInt);
    procedure Clear;
    { The tab at (X, Y) of the strip's pixels (-1: none). }
    function TabIndexAt(X, Y: LongInt): LongInt;
    { Where tab Index, its close button and the "+" button are (the
      strip's pixels; an empty rectangle for a tab without a close
      button now). }
    function TabBounds(Index: LongInt): TRectangle;
    function CloseButtonBounds(Index: LongInt): TRectangle;
    function NewTabButtonBounds: TRectangle;
    function HintAt(X, Y: LongInt; out Area: TRectangle): string; override;
    function PreferredSize: TSize; override;
    property TabCount: LongInt read GetTabCount;
    property TabCaption[Index: LongInt]: string read GetCaption write SetCaption;
    property TabImageIndex[Index: LongInt]: LongInt read GetImageIndex write SetImageIndex;
    property TabHint[Index: LongInt]: string read GetTabHint write SetTabHint;
    property TabData[Index: LongInt]: Pointer read GetData write SetData;
    { -1 with no tabs. Setting it repaints (OnChange is for the user's
      choices). }
    property ActiveIndex: LongInt read FActiveIndex write SetActiveIndex;
    { The tabs' pictures (shared: the strip does not own it). }
    property Images: TImageList read FImages write SetImages;
    property OnNewTab: TControlEvent read FOnNewTab write FOnNewTab;
    property OnCloseTab: TTabStripEvent read FOnCloseTab write FOnCloseTab;
    property OnTabMoved: TTabMovedEvent read FOnTabMoved write FOnTabMoved;
    property OnTabDraggedOut: TTabDraggedOutEvent read FOnTabDraggedOut write FOnTabDraggedOut;
    property OnTabContextMenu: TTabContextMenuEvent read FOnTabContextMenu write FOnTabContextMenu;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Colors,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Icons,
  Controls.Text,
  Controls.Window,
  Controls.LayoutRules,
  Controls.Painting,
  Controls.PartPainting,
  Controls.TabStripLayout;

const
  { Logical units. }
  StripHeight = 34;
  StripTabTop = 5;
  StripMargin = 6;
  MinimumTabWidth = 100;
  MaximumTabWidth = 240;
  SmallestTabWidth = 40;
  TabPadding = 9;
  TabImageGap = 7;
  CloseButtonSize = 18;
  CloseGlyphSize = 8;
  NewTabButtonSize = 26;
  NewTabGap = 4;
  PlusGlyphSize = 10;
  { A tab narrower than this shows a close button only when active. }
  CloseButtonRoom = 72;
  { How far the pointer moves before a press becomes a drag, and how
    far beyond the strip a tab dragged out must go. }
  DragThreshold = 5;
  DragOutThreshold = 24;
  AccentHeight = 3;

constructor TTabStrip.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FActiveIndex := -1;
  FHotIndex := -1;
  FPressedClose := -1;
  FMiddlePressed := -1;
  FHeldIndex := -1;
  SetBounds(0, 0, 0, StripHeight);
  Align := AlignTop;
end;

function TTabStrip.PreferredSize: TSize;
begin
  Result := MakeSize(Bounds.Right - Bounds.Left, StripHeight);
end;

{ --- the tabs ------------------------------------------------------------------- }

function TTabStrip.ValidIndex(Index: LongInt): Boolean;
begin
  Result := (Index >= 0) and (Index < Length(FTabs));
end;

function TTabStrip.GetTabCount: LongInt;
begin
  Result := Length(FTabs);
end;

function TTabStrip.GetCaption(Index: LongInt): string;
begin
  Result := '';
  if ValidIndex(Index) then
    Result := FTabs[Index].Caption;
end;

procedure TTabStrip.SetCaption(Index: LongInt; const Value: string);
begin
  if not ValidIndex(Index) then
    Exit;
  FTabs[Index].Caption := Value;
  Invalidate;
end;

function TTabStrip.GetImageIndex(Index: LongInt): LongInt;
begin
  Result := -1;
  if ValidIndex(Index) then
    Result := FTabs[Index].ImageIndex;
end;

procedure TTabStrip.SetImageIndex(Index, Value: LongInt);
begin
  if not ValidIndex(Index) then
    Exit;
  FTabs[Index].ImageIndex := Value;
  Invalidate;
end;

function TTabStrip.GetTabHint(Index: LongInt): string;
begin
  Result := '';
  if ValidIndex(Index) then
    Result := FTabs[Index].Hint;
end;

procedure TTabStrip.SetTabHint(Index: LongInt; const Value: string);
begin
  if ValidIndex(Index) then
    FTabs[Index].Hint := Value;
end;

function TTabStrip.GetData(Index: LongInt): Pointer;
begin
  Result := nil;
  if ValidIndex(Index) then
    Result := FTabs[Index].Data;
end;

procedure TTabStrip.SetData(Index: LongInt; Value: Pointer);
begin
  if ValidIndex(Index) then
    FTabs[Index].Data := Value;
end;

procedure TTabStrip.SetActiveIndex(Value: LongInt);
begin
  if not ValidIndex(Value) then
    Value := -1;
  if (Value = -1) and (Length(FTabs) > 0) then
    Exit;
  if Value = FActiveIndex then
    Exit;
  FActiveIndex := Value;
  Invalidate;
end;

procedure TTabStrip.SetImages(Value: TImageList);
begin
  FImages := Value;
  Invalidate;
end;

function TTabStrip.AddTab(const Caption: string; ImageIndex: LongInt): LongInt;
begin
  Result := InsertTab(Length(FTabs), Caption, ImageIndex);
end;

function TTabStrip.InsertTab(Index: LongInt; const Caption: string; ImageIndex: LongInt): LongInt;
var
  Position: LongInt;
begin
  if Index < 0 then
    Index := 0;
  if Index > Length(FTabs) then
    Index := Length(FTabs);
  SetLength(FTabs, Length(FTabs) + 1);
  Position := High(FTabs);
  while Position > Index do
  begin
    FTabs[Position] := FTabs[Position - 1];
    Dec(Position);
  end;
  FTabs[Index].Caption := Caption;
  FTabs[Index].ImageIndex := ImageIndex;
  FTabs[Index].Hint := '';
  FTabs[Index].Data := nil;
  if FActiveIndex < 0 then
    FActiveIndex := 0
  else if Index <= FActiveIndex then
    Inc(FActiveIndex);
  Invalidate;
  Result := Index;
end;

procedure TTabStrip.DeleteTab(Index: LongInt);
var
  Position: LongInt;
begin
  if not ValidIndex(Index) then
    Exit;
  ClearHeld;
  for Position := Index to High(FTabs) - 1 do
    FTabs[Position] := FTabs[Position + 1];
  SetLength(FTabs, Length(FTabs) - 1);
  if Index < FActiveIndex then
    Dec(FActiveIndex);
  if FActiveIndex >= Length(FTabs) then
    FActiveIndex := High(FTabs);
  FHotIndex := -1;
  FHotClose := False;
  Invalidate;
end;

procedure TTabStrip.MoveTab(FromIndex, ToIndex: LongInt);
var
  Moving: TStripTab;
  Position: LongInt;
begin
  if not ValidIndex(FromIndex) or not ValidIndex(ToIndex) or (FromIndex = ToIndex) then
    Exit;
  Moving := FTabs[FromIndex];
  if FromIndex < ToIndex then
    for Position := FromIndex to ToIndex - 1 do
      FTabs[Position] := FTabs[Position + 1]
  else
    for Position := FromIndex downto ToIndex + 1 do
      FTabs[Position] := FTabs[Position - 1];
  FTabs[ToIndex] := Moving;
  { The active tab is the same tab where it now is. }
  if FActiveIndex = FromIndex then
    FActiveIndex := ToIndex
  else if (FromIndex < FActiveIndex) and (ToIndex >= FActiveIndex) then
    Dec(FActiveIndex)
  else if (FromIndex > FActiveIndex) and (ToIndex <= FActiveIndex) then
    Inc(FActiveIndex);
  Invalidate;
end;

procedure TTabStrip.Clear;
begin
  ClearHeld;
  FTabs := nil;
  FActiveIndex := -1;
  FHotIndex := -1;
  Invalidate;
end;

{ --- geometry (pixels) ------------------------------------------------------------- }

function TTabStrip.FirstLeft: LongInt;
begin
  Result := Scaled(StripMargin);
end;

function TTabStrip.TabTop: LongInt;
begin
  Result := Scaled(StripTabTop);
end;

function TTabStrip.TabWidth: LongInt;
var
  Available: LongInt;
begin
  Available := RectangleWidth(PixelBounds) - FirstLeft - Scaled(NewTabGap + NewTabButtonSize + StripMargin);
  Result := StripTabWidth(Length(FTabs), Available, Scaled(MinimumTabWidth), Scaled(MaximumTabWidth),
    Scaled(SmallestTabWidth));
end;

function TTabStrip.TabBounds(Index: LongInt): TRectangle;
begin
  Result := MakeRectangle(FirstLeft + Index * TabWidth, TabTop, TabWidth, RectangleHeight(PixelBounds) - TabTop);
end;

function TTabStrip.HasCloseButton(Index: LongInt): Boolean;
begin
  Result := ValidIndex(Index) and ((Index = FActiveIndex) or
    ((Index = FHotIndex) and (TabWidth >= Scaled(CloseButtonRoom))));
end;

{ The close button's place in a tab drawn at Tab. }
function CloseBoxIn(const Tab: TRectangle): TRectangle;
var
  Size: LongInt;
begin
  Size := Scaled(CloseButtonSize);
  Result := MakeRectangle(Tab.Right - Scaled(TabPadding div 2) - Size,
    Tab.Top + (RectangleHeight(Tab) - Size) div 2, Size, Size);
end;

function TTabStrip.CloseButtonBounds(Index: LongInt): TRectangle;
begin
  if not HasCloseButton(Index) then
    Exit(MakeRectangle(0, 0, 0, 0));
  Result := CloseBoxIn(TabBounds(Index));
end;

function TTabStrip.NewTabButtonBounds: TRectangle;
var
  Size: LongInt;
  Height: LongInt;
begin
  Size := Scaled(NewTabButtonSize);
  Height := RectangleHeight(PixelBounds) - TabTop;
  Result := MakeRectangle(FirstLeft + Length(FTabs) * TabWidth + Scaled(NewTabGap),
    TabTop + (Height - Size) div 2, Size, Size);
end;

function TTabStrip.TabAt(X, Y: LongInt): LongInt;
begin
  if (Y < TabTop) or (Y >= RectangleHeight(PixelBounds)) then
    Exit(-1);
  Result := StripTabAt(X, FirstLeft, TabWidth, Length(FTabs));
end;

function TTabStrip.TabIndexAt(X, Y: LongInt): LongInt;
begin
  Result := TabAt(X, Y);
end;

function TTabStrip.CloseButtonAt(Index, X, Y: LongInt): Boolean;
begin
  Result := HasCloseButton(Index) and RectangleContainsPoint(CloseButtonBounds(Index), X, Y);
end;

function TTabStrip.DraggedLeft: LongInt;
begin
  Result := DraggedTabLeft(FDragX, FGrabOffset, FirstLeft, TabWidth, Length(FTabs));
end;

function TTabStrip.HintAt(X, Y: LongInt; out Area: TRectangle): string;
var
  Index: LongInt;
begin
  Result := '';
  Area := MakeRectangle(0, 0, 0, 0);
  if not ShowHint then
    Exit;
  if RectangleContainsPoint(NewTabButtonBounds, X, Y) then
  begin
    Area := NewTabButtonBounds;
    Exit('New tab');
  end;
  Index := TabAt(X, Y);
  if Index < 0 then
    Exit;
  if CloseButtonAt(Index, X, Y) then
  begin
    Area := CloseButtonBounds(Index);
    Exit('Close tab');
  end;
  Area := TabBounds(Index);
  Result := FTabs[Index].Hint;
  if Result = '' then
    Result := FTabs[Index].Caption;
end;

{ --- the pointer ------------------------------------------------------------------- }

procedure TTabStrip.UpdateHot(X, Y: LongInt);
var
  Index: LongInt;
  Close: Boolean;
  NewTab: Boolean;
begin
  Index := TabAt(X, Y);
  { The hot tab first: whether it has a close button depends on it. }
  if Index <> FHotIndex then
  begin
    FHotIndex := Index;
    Invalidate;
  end;
  Close := (Index >= 0) and CloseButtonAt(Index, X, Y);
  NewTab := RectangleContainsPoint(NewTabButtonBounds, X, Y);
  if (Close <> FHotClose) or (NewTab <> FHotNewTab) then
  begin
    FHotClose := Close;
    FHotNewTab := NewTab;
    Invalidate;
  end;
end;

procedure TTabStrip.ClearHeld;
begin
  FHeldIndex := -1;
  FDragging := False;
  FDraggedOut := False;
  FPressedClose := -1;
  FPressedNewTab := False;
  FMiddlePressed := -1;
end;

procedure TTabStrip.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Index: LongInt;
begin
  UpdateHot(X, Y);
  Index := TabAt(X, Y);
  if Button = ButtonMiddle then
  begin
    FMiddlePressed := Index;
    Exit;
  end;
  if Button <> ButtonLeft then
    Exit;
  if RectangleContainsPoint(NewTabButtonBounds, X, Y) then
  begin
    FPressedNewTab := True;
    Invalidate;
    Exit;
  end;
  if Index < 0 then
    Exit;
  if CloseButtonAt(Index, X, Y) then
  begin
    FPressedClose := Index;
    Invalidate;
    Exit;
  end;
  if Index <> FActiveIndex then
  begin
    FActiveIndex := Index;
    Invalidate;
    Changed;
  end;
  FHeldIndex := Index;
  FPressX := X;
  FPressY := Y;
  FGrabOffset := X - TabBounds(Index).Left;
  FDragX := X;
end;

{ The held tab follows the pointer: among the others while in the strip,
  marked out once well above or below it. }
procedure TTabStrip.DragTo(X, Y: LongInt);
var
  Target: LongInt;
  FromIndex: LongInt;
  WasOut: Boolean;
begin
  if not FDragging then
  begin
    if (Abs(X - FPressX) < Scaled(DragThreshold)) and (Abs(Y - FPressY) < Scaled(DragThreshold)) then
      Exit;
    FDragging := True;
  end;
  FDragX := X;
  WasOut := FDraggedOut;
  FDraggedOut := IsDraggedOut(Y, RectangleHeight(PixelBounds), Scaled(DragOutThreshold));
  if WasOut <> FDraggedOut then
    Invalidate;
  if not FDraggedOut then
  begin
    Target := StripDropIndex(DraggedLeft, FirstLeft, TabWidth, Length(FTabs));
    if Target <> FHeldIndex then
    begin
      FromIndex := FHeldIndex;
      MoveTab(FromIndex, Target);
      FHeldIndex := Target;
      if Assigned(FOnTabMoved) then
        FOnTabMoved(Self, FromIndex, Target);
    end;
  end;
  Invalidate;
end;

procedure TTabStrip.PointerMove(X, Y: LongInt; Buttons: LongWord);
begin
  if (FHeldIndex >= 0) and ValidIndex(FHeldIndex) then
  begin
    DragTo(X, Y);
    Exit;
  end;
  UpdateHot(X, Y);
end;

procedure TTabStrip.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Index: LongInt;
  Window: TControlWindow;
  ScreenX: LongInt;
  ScreenY: LongInt;
begin
  Index := TabAt(X, Y);
  if Button = ButtonMiddle then
  begin
    if (FMiddlePressed >= 0) and (FMiddlePressed = Index) and Assigned(FOnCloseTab) then
      FOnCloseTab(Self, Index);
    FMiddlePressed := -1;
    Exit;
  end;
  if Button <> ButtonLeft then
    Exit;
  if FPressedNewTab then
  begin
    FPressedNewTab := False;
    Invalidate;
    if RectangleContainsPoint(NewTabButtonBounds, X, Y) and Assigned(FOnNewTab) then
      FOnNewTab(Self);
    Exit;
  end;
  if FPressedClose >= 0 then
  begin
    Index := FPressedClose;
    FPressedClose := -1;
    Invalidate;
    if CloseButtonAt(Index, X, Y) and Assigned(FOnCloseTab) then
      FOnCloseTab(Self, Index);
    Exit;
  end;
  if FHeldIndex < 0 then
    Exit;
  Index := FHeldIndex;
  if FDragging and FDraggedOut and Assigned(FOnTabDraggedOut) then
  begin
    ScreenX := 0;
    ScreenY := 0;
    if (Host <> nil) and (Host.OwnerWindow is TControlWindow) then
    begin
      Window := TControlWindow(Host.OwnerWindow);
      ScreenX := Window.ScreenLeft + Unscaled(PixelBounds.Left + X);
      ScreenY := Window.ScreenTop + Unscaled(PixelBounds.Top + Y);
    end;
    ClearHeld;
    Invalidate;
    FOnTabDraggedOut(Self, Index, ScreenX, ScreenY);
    Exit;
  end;
  ClearHeld;
  UpdateHot(X, Y);
  Invalidate;
end;

procedure TTabStrip.PointerLeave;
begin
  if FHeldIndex >= 0 then
    Exit;
  FHotIndex := -1;
  FHotClose := False;
  FHotNewTab := False;
  Invalidate;
end;

procedure TTabStrip.ContextMenu(X, Y: LongInt; FromKeyboard: Boolean);
var
  Index: LongInt;
  Tab: TRectangle;
begin
  if FromKeyboard then
  begin
    Index := FActiveIndex;
    if Index >= 0 then
    begin
      Tab := TabBounds(Index);
      X := Tab.Left;
      Y := Tab.Bottom;
    end;
  end
  else
    Index := TabAt(X, Y);
  if (Index >= 0) and Assigned(FOnTabContextMenu) then
    FOnTabContextMenu(Self, Index, X, Y)
  else
    inherited ContextMenu(X, Y, FromKeyboard);
end;

{ --- painting ---------------------------------------------------------------------- }

{ The strip behind the tabs and the line along its bottom, which the
  active tab breaks. }
procedure TTabStrip.PaintBackground(var Canvas: TCanvas);
var
  Box: TRectangle;
  Line: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  Line := BevelLine;
  if Theme.HeaderBandsShown then
  begin
    FillRectangle(Canvas, Box, MixColors(Theme.Face, Theme.Shadow, 70));
    FillRectangle(Canvas, MakeRectangle(0, Box.Bottom - Line, Box.Right, Line), Theme.Shadow);
  end
  else
  begin
    FillRectangle(Canvas, Box, Theme.Face);
    FillRectangle(Canvas, MakeRectangle(0, Box.Bottom - Line, Box.Right, Line), Theme.Highlight);
  end;
end;

procedure TTabStrip.PaintTabFace(var Canvas: TCanvas; Index: LongInt; const Tab: TRectangle);
var
  Line: LongInt;
  Active: Boolean;
  Face: TRectangle;
begin
  Line := BevelLine;
  Active := Index = FActiveIndex;
  if Theme.HeaderBandsShown then
  begin
    if Active then
    begin
      { The face colour running down into the content, a shadow line
        each side (the top corners cut) and the gold accent on top. }
      FillRectangle(Canvas, MakeRectangle(Tab.Left + Line, Tab.Top + Line, RectangleWidth(Tab) - 2 * Line,
        RectangleHeight(Tab) - Line), Theme.Face);
      FillRectangle(Canvas, MakeRectangle(Tab.Left, Tab.Top + 2 * Line, Line, RectangleHeight(Tab) - 2 * Line),
        Theme.Shadow);
      FillRectangle(Canvas, MakeRectangle(Tab.Right - Line, Tab.Top + 2 * Line, Line, RectangleHeight(Tab) - 2 * Line),
        Theme.Shadow);
      FillVerticalGradient(Canvas, MakeRectangle(Tab.Left + Line, Tab.Top, RectangleWidth(Tab) - 2 * Line,
        Scaled(AccentHeight)), Theme.HeaderBandTop, Theme.HeaderBandBottom);
      FillRectangle(Canvas, MakeRectangle(Tab.Left + Line, Tab.Top, RectangleWidth(Tab) - 2 * Line, Line),
        Theme.HeaderBandEdge);
    end
    else
    begin
      if (Index = FHotIndex) or (Index = FHeldIndex) then
        FillRectangle(Canvas, MakeRectangle(Tab.Left + Line, Tab.Top + Line, RectangleWidth(Tab) - 2 * Line,
          RectangleHeight(Tab) - 2 * Line), MixColors(Theme.Face, Theme.HotButtonFace, 128));
      { A thin separator after it, unless beside the active tab. }
      if (Index + 1 <> FActiveIndex) and (Index <> FActiveIndex) then
        FillRectangle(Canvas, MakeRectangle(Tab.Right - Line, Tab.Top + Scaled(6), Line,
          RectangleHeight(Tab) - Scaled(12)), Theme.Shadow);
    end;
    Exit;
  end;
  { Classic: a raised tab, the active one taller and joined to what is
    below; the others stand a little lower. }
  Face := Tab;
  if not Active then
    Face.Top := Face.Top + Scaled(2);
  if Active then
    FillRectangle(Canvas, MakeRectangle(Face.Left + Line, Face.Top + Line, RectangleWidth(Face) - 2 * Line,
      RectangleHeight(Face) - Line), Theme.Face)
  else
  begin
    if Index = FHotIndex then
      FillRectangle(Canvas, MakeRectangle(Face.Left + Line, Face.Top + Line, RectangleWidth(Face) - 3 * Line,
        RectangleHeight(Face) - 2 * Line), Theme.HotButtonFace);
    Face.Bottom := Face.Bottom - Line;
  end;
  FillRectangle(Canvas, MakeRectangle(Face.Left, Face.Top + 2 * Line, Line, RectangleHeight(Face) - 2 * Line),
    Theme.Highlight);
  FillRectangle(Canvas, MakeRectangle(Face.Left + 2 * Line, Face.Top, RectangleWidth(Face) - 4 * Line, Line),
    Theme.Highlight);
  FillRectangle(Canvas, MakeRectangle(Face.Left + Line, Face.Top + Line, Line, Line), Theme.Highlight);
  FillRectangle(Canvas, MakeRectangle(Face.Right - Line, Face.Top + 2 * Line, Line, RectangleHeight(Face) - 2 * Line),
    Theme.DarkShadow);
  FillRectangle(Canvas, MakeRectangle(Face.Right - 2 * Line, Face.Top + Line, Line, RectangleHeight(Face) - Line),
    Theme.Shadow);
end;

{ The picture, the caption cut with "..." and the close button. }
procedure TTabStrip.PaintTabContent(var Canvas: TCanvas; Index: LongInt; const Tab: TRectangle);
var
  Content: TRectangle;
  Picture: TRectangle;
  Close: TRectangle;
  Size: LongInt;
  Look: TPartLook;
  Middle: LongInt;
begin
  Content := MakeRectangle(Tab.Left + Scaled(TabPadding), Tab.Top, RectangleWidth(Tab) - 2 * Scaled(TabPadding),
    RectangleHeight(Tab));
  if not Theme.HeaderBandsShown and (Index <> FActiveIndex) then
    Content.Top := Content.Top + Scaled(2);
  Middle := Content.Top + RectangleHeight(Content) div 2;
  if HasCloseButton(Index) then
  begin
    Close := CloseBoxIn(Tab);
    Close := OffsetRectangle(Close, 0, Middle - (Close.Top + Close.Bottom) div 2);
    Look := PartNormal;
    if FPressedClose = Index then
      Look := PartPressed
    else if FHotClose and (FHotIndex = Index) then
      Look := PartHot;
    DrawPartFace(Canvas, Close, Look);
    DrawCrossGlyph(Canvas, Close, Scaled(CloseGlyphSize), Theme.FaceText);
    Content.Right := Close.Left - Scaled(2);
  end;
  Size := Scaled(SmallIconSize);
  if (FImages <> nil) and FImages.ValidIndex(FTabs[Index].ImageIndex) and (RectangleWidth(Content) >= Size) then
  begin
    Picture := MakeRectangle(Content.Left, Middle - Size div 2, Size, Size);
    FImages.DrawInBox(Canvas, FTabs[Index].ImageIndex, Picture);
    Content.Left := Picture.Right + Scaled(TabImageGap);
  end;
  if RectangleWidth(Content) > 0 then
    DrawTextInBox(Canvas, ControlFace, FTabs[Index].Caption, Content, AlignTextLeft, Theme.FaceText);
end;

procedure TTabStrip.PaintTab(var Canvas: TCanvas; Index: LongInt; const Tab: TRectangle);
var
  Inner: TCanvas;
begin
  Inner := Canvas;
  NarrowCanvasClip(Inner, Tab);
  PaintTabFace(Inner, Index, Tab);
  PaintTabContent(Inner, Index, Tab);
end;

procedure TTabStrip.PaintNewTabButton(var Canvas: TCanvas);
var
  Box: TRectangle;
  Look: TPartLook;
begin
  Box := NewTabButtonBounds;
  Look := PartNormal;
  if FPressedNewTab and FHotNewTab then
    Look := PartPressed
  else if FHotNewTab then
    Look := PartHot;
  DrawPartFace(Canvas, Box, Look);
  DrawPlusGlyph(Canvas, Box, Scaled(PlusGlyphSize), Theme.FaceText);
end;

procedure TTabStrip.Paint(var Canvas: TCanvas);
var
  Index: LongInt;
  Tab: TRectangle;
begin
  PaintBackground(Canvas);
  for Index := 0 to High(FTabs) do
    if (Index <> FActiveIndex) and not (FDragging and (Index = FHeldIndex)) then
      PaintTab(Canvas, Index, TabBounds(Index));
  { The active tab over its neighbours; a dragged one over everything,
    where the pointer has it (nowhere while it is out of the strip). }
  if ValidIndex(FActiveIndex) and not (FDragging and (FActiveIndex = FHeldIndex)) then
    PaintTab(Canvas, FActiveIndex, TabBounds(FActiveIndex));
  PaintNewTabButton(Canvas);
  if FDragging and ValidIndex(FHeldIndex) and not FDraggedOut then
  begin
    Tab := TabBounds(FHeldIndex);
    Tab := OffsetRectangle(Tab, DraggedLeft - Tab.Left, 0);
    PaintTab(Canvas, FHeldIndex, Tab);
  end;
end;

end.
