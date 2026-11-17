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
  The tools that work with a pixel's colour: the fill bucket paints the
  area of like colour around the pixel pressed (Image.FloodFill, within
  the tool box's tolerance), and the picker takes the colour under the
  pointer as the primary colour (the secondary with the right button)
  while the button is held, then hands back to the tool used before.
}
unit Paint.FillTools;

{$mode objfpc}
{$H+}

interface

uses
  Paint.Tools;

type
  TFillTool = class(TPaintTool)
  public
    procedure PointerDown(X, Y: Double; Button, Modifiers: LongWord); override;
  end;

  TPickerTool = class(TPaintTool)
  private
    FButton: LongWord;
    FPicking: Boolean;
    procedure Pick(X, Y: Double);
  public
    { The tool to hand back to. }
    PreviousTool: LongInt;
    procedure PointerDown(X, Y: Double; Button, Modifiers: LongWord); override;
    procedure PointerMove(X, Y: Double; Buttons, Modifiers: LongWord); override;
    procedure PointerUp(X, Y: Double; Button, Modifiers: LongWord); override;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Colors,
  Drawing.Rectangles,
  Image.FloodFill,
  Paint.ToolKinds;

procedure TFillTool.PointerDown(X, Y: Double; Button, Modifiers: LongWord);
var
  Changed: TRectangle;
begin
  BeginEdit;
  Changed := FloodFill(Image, PixelOf(X), PixelOf(Y), ColorFor(Button),
    ToleranceFromPercent(FSession.Settings.TolerancePercent));
  Touch(Changed);
  if RectangleIsEmpty(Changed) then
    CancelEdit
  else
    CommitEdit('Fill');
end;

procedure TPickerTool.Pick(X, Y: Double);
var
  PixelX: LongInt;
  PixelY: LongInt;
  Color: TColor;
begin
  PixelX := PixelOf(X);
  PixelY := PixelOf(Y);
  if (PixelX < 0) or (PixelY < 0) or (PixelX >= Image.Width) or (PixelY >= Image.Height) then
    Exit;
  Color := Image.GetPixel(PixelX, PixelY);
  if FButton = ButtonRight then
    FSession.SecondaryColor := Color
  else
    FSession.PrimaryColor := Color;
end;

procedure TPickerTool.PointerDown(X, Y: Double; Button, Modifiers: LongWord);
begin
  FButton := Button;
  FPicking := True;
  Pick(X, Y);
end;

procedure TPickerTool.PointerMove(X, Y: Double; Buttons, Modifiers: LongWord);
begin
  if FPicking then
    Pick(X, Y);
end;

procedure TPickerTool.PointerUp(X, Y: Double; Button, Modifiers: LongWord);
begin
  if not FPicking then
    Exit;
  FPicking := False;
  Pick(X, Y);
  if (PreviousTool >= Ord(Low(TToolKind))) and (PreviousTool <= Ord(High(TToolKind))) and
     (TToolKind(PreviousTool) <> ToolPicker) then
    FSession.WantTool(TToolKind(PreviousTool));
end;

end.
