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
  Tooltips: a few words (a line, or several: a line break in the text
  starts a new one) in a small box that show what something is while
  the pointer rests on it.

  A tooltip is a window without a frame that never takes the keyboard,
  owned by the window it describes (so above it, and topmost with a
  topmost one such as a taskbar). It is placed above the point it is
  about, centred on it and kept on the display, so it does not come
  between the pointer and the thing pointed at. A program has one
  tooltip at a time: showing another replaces it. When to show and hide
  it (after the pointer has rested a moment, when it leaves) is the
  caller's: a control window's hint manager (Controls.Hints) does it
  for the controls' Hint texts.
}
unit Controls.Tooltips;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

{ Shows Text for Owner, centred on X with its bottom just above Y
  (screen positions, logical units). }
procedure ShowTooltip(Owner: TWindow; const Text: string; X, Y: LongInt);
{ The same, below BelowY instead when there is no room above AboveY on
  the display. }
procedure ShowTooltipNear(Owner: TWindow; const Text: string; X, AboveY, BelowY: LongInt);
procedure HideTooltip;
function TooltipShown: Boolean;

implementation

uses
  Classes,
  Drawing.Rectangles,
  Drawing.Canvas,
  Windowing.Protocol,
  Windowing.Theme,
  Windowing.Connection,
  Windowing.Displays,
  Controls.Text,
  Controls.Painting;

const
  { Logical units: around the text, and between the box and the point. }
  Padding = 4;
  Gap = 2;
  { ShowTooltipNear's BelowY for staying above, kept on the display. }
  NoPlaceBelow = Low(LongInt);

type
  TTooltipWindow = class(TWindow)
  private
    FLines: TStringList;
  protected
    procedure Paint(var Canvas: TCanvas; const Area: TRectangle); override;
  public
    constructor CreateTooltip(Described: TWindow; Lines: TStringList; Left, Top, Width, Height: LongInt);
    destructor Destroy; override;
  end;

var
  Tooltip: TTooltipWindow;

constructor TTooltipWindow.CreateTooltip(Described: TWindow; Lines: TStringList; Left, Top, Width,
  Height: LongInt);
begin
  FLines := Lines;
  inherited Create('', Left, Top, Width, Height, WindowTopmost or WindowNoActivate, Described);
end;

destructor TTooltipWindow.Destroy;
begin
  inherited Destroy;
  FLines.Free;
end;

procedure TTooltipWindow.Paint(var Canvas: TCanvas; const Area: TRectangle);
var
  Box: TRectangle;
  Inner: TRectangle;
  Alignment: THorizontalAlignment;
  LineHeight: LongInt;
  Index: LongInt;
begin
  Box := MakeRectangle(0, 0, PixelWidth, PixelHeight);
  FillRectangle(Canvas, Box, Theme.Tooltip);
  DrawThickOutline(Canvas, Box, BevelLine, Theme.TooltipBorder);
  Inner := InflateRectangle(Box, -Scaled(Padding));
  LineHeight := TextHeight(ControlFace);
  { One line is centred; several are read from the left. }
  Alignment := AlignTextCenter;
  if FLines.Count > 1 then
    Alignment := AlignTextLeft;
  for Index := 0 to FLines.Count - 1 do
    DrawTextInBox(Canvas, ControlFace, FLines[Index], MakeRectangle(Inner.Left, Inner.Top + Index * LineHeight,
      RectangleWidth(Inner), LineHeight), Alignment, Theme.TooltipText);
end;

{ Text's lines (at line breaks; a carriage return before one is dropped). }
function SplitLines(const Text: string): TStringList;
var
  Line: string;
  Index: LongInt;
begin
  Result := TStringList.Create;
  Line := '';
  for Index := 1 to Length(Text) do
    if Text[Index] = #10 then
    begin
      Result.Add(Line);
      Line := '';
    end
    else if Text[Index] <> #13 then
      Line := Line + Text[Index];
  Result.Add(Line);
end;

procedure ShowTooltipNear(Owner: TWindow; const Text: string; X, AboveY, BelowY: LongInt);
var
  Lines: TStringList;
  Width: LongInt;
  Height: LongInt;
  Left: LongInt;
  Top: LongInt;
  Wanted: LongInt;
  Index: LongInt;
  LineWidth: LongInt;
begin
  HideTooltip;
  if Owner <> nil then
    Owner.PrepareToReceive;
  Lines := SplitLines(Text);
  Width := 0;
  for Index := 0 to Lines.Count - 1 do
  begin
    LineWidth := Unscaled(TextWidth(ControlFace, Lines[Index]));
    if LineWidth > Width then
      Width := LineWidth;
  end;
  { (Unscaled may round a pixel short: one spare unit keeps the text whole.) }
  Width := Width + 1 + 2 * Padding;
  Height := Unscaled(Lines.Count * TextHeight(ControlFace)) + 1 + 2 * Padding;
  Left := X - Width div 2;
  Wanted := AboveY - Gap - Height;
  Top := Wanted;
  KeepOnDisplay(Left, Top, Width, Height);
  if (Top > Wanted) and (BelowY <> NoPlaceBelow) then
  begin
    Left := X - Width div 2;
    Top := BelowY + Gap;
    KeepOnDisplay(Left, Top, Width, Height);
  end;
  Tooltip := TTooltipWindow.CreateTooltip(Owner, Lines, Left, Top, Width, Height);
  Tooltip.Show;
end;

procedure ShowTooltip(Owner: TWindow; const Text: string; X, Y: LongInt);
begin
  ShowTooltipNear(Owner, Text, X, Y, NoPlaceBelow);
end;

procedure HideTooltip;
begin
  Tooltip.Free;
  Tooltip := nil;
end;

function TooltipShown: Boolean;
begin
  Result := Tooltip <> nil;
end;

end.
