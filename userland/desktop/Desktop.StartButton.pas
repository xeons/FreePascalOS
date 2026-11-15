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
  The Start button at the taskbar's left end: the desktop's mark and a
  bold caption on a raised button, pressed in while its menu is open.
  A press opens the menu at once (OnClick), as a menu bar's heading
  does, so the release lands on the open menu's owner and chooses
  nothing.
}
unit Desktop.StartButton;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base;

type
  TStartButton = class(TControl)
  private
    FDown: Boolean;
    procedure SetDown(Value: Boolean);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
  public
    { The width it wants (logical units). }
    function PreferredWidth: LongInt;
    { Drawn pressed in (its menu is open). }
    property Down: Boolean read FDown write SetDown;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text,
  Desktop.SmallPictures;

const
  { Logical units. }
  MarkSize = 16;
  Spacing = 4;

function TStartButton.PreferredWidth: LongInt;
begin
  Result := Spacing + MarkSize + Spacing + Unscaled(TextWidth(ControlBoldFace, Text)) + 2 * Spacing;
end;

procedure TStartButton.SetDown(Value: Boolean);
begin
  if FDown = Value then
    Exit;
  FDown := Value;
  Invalidate;
end;

procedure TStartButton.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Shift: LongInt;
  Mark: TRectangle;
  Caption: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  Shift := 0;
  if FDown then
  begin
    DrawBevel(Canvas, Box, SunkenThemeBevel);
    Shift := 1;
  end
  else
    DrawBevel(Canvas, Box, RaisedThemeBevel);
  Mark := MakeRectangle(Scaled(Spacing) + Shift, (RectangleHeight(Box) - Scaled(MarkSize)) div 2 + Shift,
    Scaled(MarkSize), Scaled(MarkSize));
  DrawStartMark(Canvas, Mark);
  Caption := MakeRectangle(Mark.Right + Scaled(Spacing), Shift, RectangleWidth(Box) - Mark.Right - Scaled(Spacing),
    RectangleHeight(Box));
  DrawTextInBox(Canvas, ControlBoldFace, Text, Caption, AlignTextLeft, Theme.FaceText);
end;

procedure TStartButton.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if Button = ButtonLeft then
    Click;
end;

end.
