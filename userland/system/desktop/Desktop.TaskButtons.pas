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
  A taskbar button: one for each window of another program, with the
  window's icon (Desktop.TaskIcons; a small window mark if it has none)
  and its title. The active window's button is drawn
  pressed in, on a lighter face, its title bold; a minimized window's
  title is drawn in the shadow colour. A click (let go over it) is
  OnClick; a right click, when let go, OnContextMenu (so the release
  does not choose from the menu it opens).
}
unit Desktop.TaskButtons;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.Base;

type
  TTaskButton = class(TControl)
  private
    FWindowId: LongWord;
    FActive: Boolean;
    FMinimized: Boolean;
    FIconVersion: LongWord;
    FHeld: Boolean;
    FOnContextMenu: TPointerEvent;
    function Contains(X, Y: LongInt): Boolean;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
  public
    { Takes what the window list says of the window. }
    procedure ShowState(const Title: string; Active, Minimized: Boolean; IconVersion: LongWord);
    { Where the window's icon is drawn (its pixels). }
    function IconBox: TRectangle;
    property WindowId: LongWord read FWindowId write FWindowId;
    property Active: Boolean read FActive;
    property Minimized: Boolean read FMinimized;
    { X, Y: where the right button was let go (its pixels). }
    property OnContextMenu: TPointerEvent read FOnContextMenu write FOnContextMenu;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Colors,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text,
  Desktop.TaskIcons,
  Desktop.SmallPictures;

const
  { Logical units. }
  MarkSize = 16;
  Spacing = 4;

function TTaskButton.Contains(X, Y: LongInt): Boolean;
begin
  Result := (X >= 0) and (Y >= 0) and (X < RectangleWidth(PixelBounds)) and (Y < RectangleHeight(PixelBounds));
end;

procedure TTaskButton.ShowState(const Title: string; Active, Minimized: Boolean; IconVersion: LongWord);
begin
  if (Title = Text) and (Active = FActive) and (Minimized = FMinimized) and (IconVersion = FIconVersion) then
    Exit;
  FIconVersion := IconVersion;
  FActive := Active;
  FMinimized := Minimized;
  Text := Title;
  Invalidate;
end;

function TTaskButton.IconBox: TRectangle;
var
  Shift: LongInt;
begin
  Shift := 0;
  if FActive or FHeld then
    Shift := 1;
  Result := MakeRectangle(Scaled(Spacing) + Shift, (RectangleHeight(PixelBounds) - Scaled(MarkSize)) div 2 + Shift,
    Scaled(MarkSize), Scaled(MarkSize));
end;

procedure TTaskButton.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Shift: LongInt;
  Mark: TRectangle;
  Caption: TRectangle;
  Pressed: Boolean;
  TextColor: TColor;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  Pressed := FActive or FHeld;
  Shift := 0;
  if Pressed then
  begin
    FillRectangle(Canvas, Box, Theme.TaskButtonActiveFace);
    DrawBevel(Canvas, Box, SunkenThemeBevel);
    Shift := 1;
  end
  else
  begin
    FillRectangle(Canvas, Box, Theme.TaskbarFace);
    DrawBevel(Canvas, Box, RaisedThemeBevel);
  end;
  Mark := IconBox;
  if not DrawTaskIcon(Canvas, FWindowId, Mark) then
    DrawTaskWindowMark(Canvas, Mark);
  Caption := MakeRectangle(Mark.Right + Scaled(Spacing), Shift,
    RectangleWidth(Box) - Mark.Right - 2 * Scaled(Spacing), RectangleHeight(Box));
  TextColor := Theme.TaskbarText;
  if FMinimized then
    TextColor := Theme.Shadow;
  if FActive then
    DrawTextInBox(Canvas, ControlBoldFace, Text, Caption, AlignTextLeft, TextColor)
  else
    DrawTextInBox(Canvas, ControlFace, Text, Caption, AlignTextLeft, TextColor);
end;

procedure TTaskButton.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if Button <> ButtonLeft then
    Exit;
  FHeld := True;
  Invalidate;
end;

procedure TTaskButton.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  if (Button = ButtonRight) and Contains(X, Y) then
  begin
    if Assigned(FOnContextMenu) then
      FOnContextMenu(Self, X, Y, Button);
    Exit;
  end;
  if (Button <> ButtonLeft) or not FHeld then
    Exit;
  FHeld := False;
  Invalidate;
  if Contains(X, Y) then
    Click;
end;

end.
