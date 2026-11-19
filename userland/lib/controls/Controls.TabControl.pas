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
  tab control has the focus, shows another page, as does Alt and the
  mnemonic in a page's caption ("&Lists"). A new page shown is
  announced (OnChange, NotifyChanged). A tab may show a picture of the
  tab control's image list before its caption (Images,
  PageImageIndex).
}
unit Controls.TabControl;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.Base,
  Controls.ImageList;

type
  TTabControl = class(TControl)
  private
    FPages: TList;
    FPageIndex: LongInt;
    FImages: TImageList;
    FPageImages: array of LongInt;
    procedure SetImages(Value: TImageList);
    function GetPageImageIndex(Index: LongInt): LongInt;
    procedure SetPageImageIndex(Index, Value: LongInt);
    function TabHasImage(Index: LongInt): Boolean;
    function TabHeight: LongInt;
    function TabLeft(Index: LongInt): LongInt;
    function TabWidth(Index: LongInt): LongInt;
    function GetPage(Index: LongInt): TControl;
    function GetPageCount: LongInt;
    procedure SetPageIndex(Value: LongInt);
    procedure PaintTab(var Canvas: TCanvas; Index: LongInt);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure Layout; override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    function AddPage(const Caption: string): TControl;
    { Where page Index's tab is (pixels of the tab control). }
    function TabBounds(Index: LongInt): TRectangle;
    function MatchesMnemonic(Character: LongWord): Boolean; override;
    procedure ActivateMnemonic(Character: LongWord); override;
    function PreferredSize: TSize; override;
    property PageCount: LongInt read GetPageCount;
    property Pages[Index: LongInt]: TControl read GetPage;
    property PageIndex: LongInt read FPageIndex write SetPageIndex;
    { The tabs' pictures (shared: the tab control does not own it). }
    property Images: TImageList read FImages write SetImages;
    { Page Index's tab's picture in Images (-1, the default: none). }
    property PageImageIndex[Index: LongInt]: LongInt read GetPageImageIndex write SetPageImageIndex;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text,
  Controls.Icons,
  Controls.Panels,
  Controls.LayoutRules,
  Controls.Painting;

const
  { Logical units between a tab's picture and its caption. }
  ImageGap = 4;

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
  Result := MnemonicTextWidth(ControlFace, Pages[Index].Text) + Scaled(16);
  if TabHasImage(Index) then
    Result := Result + Scaled(SmallIconSize + ImageGap);
end;

function TTabControl.TabHasImage(Index: LongInt): Boolean;
begin
  Result := (FImages <> nil) and FImages.ValidIndex(GetPageImageIndex(Index));
end;

procedure TTabControl.SetImages(Value: TImageList);
begin
  FImages := Value;
  Invalidate;
end;

function TTabControl.GetPageImageIndex(Index: LongInt): LongInt;
begin
  Result := -1;
  if (Index >= 0) and (Index < Length(FPageImages)) then
    Result := FPageImages[Index];
end;

procedure TTabControl.SetPageImageIndex(Index, Value: LongInt);
begin
  if (Index < 0) or (Index >= Length(FPageImages)) then
    Exit;
  FPageImages[Index] := Value;
  Invalidate;
end;

function TTabControl.TabLeft(Index: LongInt): LongInt;
var
  Position: LongInt;
begin
  Result := Scaled(2);
  for Position := 0 to Index - 1 do
    Result := Result + TabWidth(Position);
end;

function TTabControl.TabBounds(Index: LongInt): TRectangle;
begin
  Result := MakeRectangle(TabLeft(Index), 0, TabWidth(Index), TabHeight);
end;

function TTabControl.AddPage(const Caption: string): TControl;
begin
  Result := TPanel.Create(Self);
  Result.Text := Caption;
  FPages.Add(Result);
  SetLength(FPageImages, FPages.Count);
  FPageImages[FPages.Count - 1] := -1;
  Result.Visible := FPages.Count = 1;
  if FPageIndex < 0 then
    FPageIndex := 0;
  Layout;
  Invalidate;
end;

function TTabControl.MatchesMnemonic(Character: LongWord): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to FPages.Count - 1 do
    if MnemonicMatches(Pages[Index].Text, Character) then
      Exit(True);
  Result := False;
end;

procedure TTabControl.ActivateMnemonic(Character: LongWord);
var
  Index: LongInt;
begin
  for Index := 0 to FPages.Count - 1 do
    if MnemonicMatches(Pages[Index].Text, Character) then
    begin
      PageIndex := Index;
      Exit;
    end;
end;

{ Every tab in a row, and the largest page's preferred size under them,
  inside the frame. }
function TTabControl.PreferredSize: TSize;
var
  Index: LongInt;
  Tabs: LongInt;
  Page: TSize;
  Largest: TSize;
begin
  Tabs := 0;
  Largest := MakeSize(0, 0);
  for Index := 0 to FPages.Count - 1 do
  begin
    Tabs := Tabs + PixelsToLogicalCeiling(TabWidth(Index));
    Page := Pages[Index].PreferredSize;
    if Page.cx > Largest.cx then
      Largest.cx := Page.cx;
    if Page.cy > Largest.cy then
      Largest.cy := Page.cy;
  end;
  if Largest.cx + 6 > Tabs + 4 then
    Tabs := Largest.cx + 2;
  Result := MakeSize(Tabs + 4, PixelsToLogicalCeiling(TabHeight) + Largest.cy + 6);
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

{ Tab Index: a raised tab with rounded top corners, its lit left and top
  edges and shaded right edge each a bevel line thick. The chosen one is
  larger, stands higher and runs down over the frame's top edge, so it
  joins its page with no line between them; its picture and caption
  stay in the middle of the part above the frame, and the focus frame,
  when it has the focus, goes around them. }
procedure TTabControl.PaintTab(var Canvas: TCanvas; Index: LongInt);
var
  Tab: TRectangle;
  Face: TRectangle;
  Content: TRectangle;
  Picture: TRectangle;
  Caption: TRectangle;
  Line: LongInt;
  Corner: LongInt;
  Size: LongInt;
  ContentWidth: LongInt;
  TextWidthOfCaption: LongInt;
  State: TImageDrawState;
  Chosen: Boolean;
begin
  Chosen := Index = FPageIndex;
  Line := BevelLine;
  Corner := 2 * Line;
  Tab := MakeRectangle(TabLeft(Index), Scaled(2), TabWidth(Index), TabHeight - Scaled(2));
  if Chosen then
    Tab := MakeRectangle(Tab.Left - Scaled(2), 0, RectangleWidth(Tab) + Scaled(4), TabHeight + BevelWidth);
  { The face, leaving the rounded corners to what is behind. }
  FillRectangle(Canvas, MakeRectangle(Tab.Left + Line, Tab.Top + Line, RectangleWidth(Tab) - 2 * Line,
    RectangleHeight(Tab) - Line), Theme.Face);
  { Left and top edges lit, the corner between them cut by a step. }
  FillRectangle(Canvas, MakeRectangle(Tab.Left, Tab.Top + Corner, Line, RectangleHeight(Tab) - Corner),
    Theme.Highlight);
  FillRectangle(Canvas, MakeRectangle(Tab.Left + Corner, Tab.Top, RectangleWidth(Tab) - 2 * Corner, Line),
    Theme.Highlight);
  FillRectangle(Canvas, MakeRectangle(Tab.Left + Line, Tab.Top + Line, Line, Line), Theme.Highlight);
  { The right edge: a dark outer line and a shadow inside it. }
  FillRectangle(Canvas, MakeRectangle(Tab.Right - Line, Tab.Top + Corner, Line, RectangleHeight(Tab) - Corner),
    Theme.DarkShadow);
  FillRectangle(Canvas, MakeRectangle(Tab.Right - 2 * Line, Tab.Top + Line, Line, RectangleHeight(Tab) - Line),
    Theme.Shadow);
  { Where the picture and caption go: the tab above the frame. }
  Face := MakeRectangle(Tab.Left + Line, Tab.Top + Line, RectangleWidth(Tab) - 3 * Line, TabHeight - Tab.Top - Line);
  TextWidthOfCaption := MnemonicTextWidth(ControlFace, Pages[Index].Text);
  ContentWidth := TextWidthOfCaption;
  Size := Scaled(SmallIconSize);
  if TabHasImage(Index) then
    ContentWidth := ContentWidth + Size + Scaled(ImageGap);
  Content := MakeRectangle(Face.Left + (RectangleWidth(Face) - ContentWidth) div 2, Face.Top, ContentWidth,
    RectangleHeight(Face));
  Caption := Content;
  if TabHasImage(Index) then
  begin
    Picture := MakeRectangle(Content.Left, Face.Top + (RectangleHeight(Face) - Size) div 2, Size, Size);
    State := ImageDrawNormal;
    if not Enabled then
      State := ImageDrawDisabled;
    FImages.DrawInBox(Canvas, FPageImages[Index], Picture, State);
    Caption.Left := Picture.Right + Scaled(ImageGap);
  end;
  DrawMnemonicTextInBox(Canvas, ControlFace, Pages[Index].Text, Caption, AlignTextLeft, Theme.FaceText);
  if Chosen and Focused then
    DrawFocusFrame(Canvas, MakeRectangle(Content.Left - Scaled(3), Face.Top + Scaled(2), ContentWidth + Scaled(6),
      RectangleHeight(Face) - Scaled(4)), Theme.FaceText);
end;

procedure TTabControl.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Frame: TRectangle;
  Index: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  Frame := MakeRectangle(0, TabHeight, RectangleWidth(Box), RectangleHeight(Box) - TabHeight);
  DrawRaisedBevel(Canvas, Frame);
  { The chosen tab last: it overlaps its neighbours, not they it. }
  for Index := 0 to FPages.Count - 1 do
    if Index <> FPageIndex then
      PaintTab(Canvas, Index);
  if (FPageIndex >= 0) and (FPageIndex < FPages.Count) then
    PaintTab(Canvas, FPageIndex);
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
