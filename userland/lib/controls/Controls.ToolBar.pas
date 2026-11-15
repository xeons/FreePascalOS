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
  Toolbars: a strip of flat buttons along the top of a window.

  A tool button shows its text (or whatever its OnPaint draws); it looks
  raised while the pointer is over it, pressed while held, and clicks
  when let go on it. A toggle button stays down until clicked again
  (Down). Separators are gaps with an etched line.
}
unit Controls.ToolBar;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base;

type
  TToolButton = class(TControl)
  private
    FHovered: Boolean;
    FHeld: Boolean;
    FIsToggle: Boolean;
    FDown: Boolean;
    FIsSeparator: Boolean;
    procedure SetDown(Value: Boolean);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerEnter; override;
    procedure PointerLeave; override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
  public
    property IsToggle: Boolean read FIsToggle write FIsToggle;
    property Down: Boolean read FDown write SetDown;
    property IsSeparator: Boolean read FIsSeparator;
  end;

  TToolBar = class(TControl)
  private
    FNextLeft: LongInt;
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    constructor Create(AParent: TControl); override;
    { A button of Width logical units after the last. }
    function AddButton(const AText: string; Width: LongInt; AOnClick: TControlEvent = nil): TToolButton;
    procedure AddSeparator;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text;

const
  ToolBarHeight = 26;
  ButtonHeight = 22;
  SeparatorWidth = 8;

procedure TToolButton.SetDown(Value: Boolean);
begin
  if FDown = Value then
    Exit;
  FDown := Value;
  Invalidate;
  Changed;
end;

procedure TToolButton.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Shift: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  if FIsSeparator then
  begin
    DrawVerticalLine(Canvas, RectangleWidth(Box) div 2 - 1, 2, RectangleHeight(Box) - 2, Theme.Shadow);
    DrawVerticalLine(Canvas, RectangleWidth(Box) div 2, 2, RectangleHeight(Box) - 2, Theme.Highlight);
    Exit;
  end;
  Shift := 0;
  if (FHeld and FHovered) or FDown then
  begin
    if FDown and not FHeld then
      FillRectangle(Canvas, Box, Theme.Light);
    DrawEdge(Canvas, Box, Theme.Shadow, Theme.Highlight);
    Shift := 1;
  end
  else if FHovered and Enabled then
    DrawEdge(Canvas, Box, Theme.Highlight, Theme.Shadow);
  if Enabled then
    DrawTextInBox(Canvas, ControlFace, Text, OffsetRectangle(InflateRectangle(Box, -Scaled(3)), Shift, Shift),
      AlignTextCenter, Theme.FaceText)
  else
    DrawDisabledText(Canvas, ControlFace, Text, (RectangleWidth(Box) - TextWidth(ControlFace, Text)) div 2,
      (RectangleHeight(Box) - TextHeight(ControlFace)) div 2);
end;

procedure TToolButton.PointerEnter;
begin
  FHovered := True;
  Invalidate;
end;

procedure TToolButton.PointerLeave;
begin
  FHovered := False;
  Invalidate;
end;

procedure TToolButton.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if (Button <> ButtonLeft) or FIsSeparator then
    Exit;
  FHeld := True;
  Invalidate;
end;

procedure TToolButton.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Inside: Boolean;
begin
  if not FHeld then
    Exit;
  FHeld := False;
  Inside := (X >= 0) and (Y >= 0) and (X < RectangleWidth(PixelBounds)) and (Y < RectangleHeight(PixelBounds));
  FHovered := Inside;
  Invalidate;
  if not Inside then
    Exit;
  if FIsToggle then
    Down := not FDown;
  Click;
end;

constructor TToolBar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  SetBounds(0, 0, 0, ToolBarHeight);
  Align := AlignTop;
  FNextLeft := 2;
end;

function TToolBar.AddButton(const AText: string; Width: LongInt; AOnClick: TControlEvent): TToolButton;
begin
  Result := TToolButton.Create(Self);
  Result.Text := AText;
  Result.OnClick := AOnClick;
  Result.SetBounds(FNextLeft, (ToolBarHeight - ButtonHeight) div 2, Width, ButtonHeight);
  FNextLeft := FNextLeft + Width + 1;
end;

procedure TToolBar.AddSeparator;
var
  Separator: TToolButton;
begin
  Separator := TToolButton.Create(Self);
  Separator.FIsSeparator := True;
  Separator.SetBounds(FNextLeft, (ToolBarHeight - ButtonHeight) div 2, SeparatorWidth, ButtonHeight);
  FNextLeft := FNextLeft + SeparatorWidth;
end;

procedure TToolBar.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  DrawHorizontalLine(Canvas, 0, Box.Right, Box.Bottom - 2, Theme.Shadow);
  DrawHorizontalLine(Canvas, 0, Box.Right, Box.Bottom - 1, Theme.Highlight);
end;

end.
