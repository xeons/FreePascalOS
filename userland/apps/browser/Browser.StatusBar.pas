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
  The browser's status bar along the bottom: what is going on or the
  link under the pointer, then (from the right) the size grip, the
  security lock of a secure page (a click shows Page Info's Security
  tab), the zoom when it is not 100 %, the downloads running (a click
  opens the Downloads window), "Offline" while working offline, and a
  progress meter while the page loads.
}
unit Browser.StatusBar;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Drawing.Rectangles,
  Controls.Base;

type
  TBrowserStatusBar = class(TControl)
  private
    FStatus: string;
    FProgress: LongInt;
    FSecure: Boolean;
    FZoomText: string;
    FDownloadsText: string;
    FOffline: Boolean;
    FOnLockClick: TControlEvent;
    FOnDownloadsClick: TControlEvent;
    procedure SetStatus(const Value: string);
    procedure SetProgress(Value: LongInt);
    procedure SetSecure(Value: Boolean);
    procedure SetZoomText(const Value: string);
    procedure SetDownloadsText(const Value: string);
    procedure SetOffline(Value: Boolean);
    function GripBox: TRectangle;
    function LockBox: TRectangle;
    function ZoomBox: TRectangle;
    function DownloadsBox: TRectangle;
    function OfflineBox: TRectangle;
    function ProgressBox: TRectangle;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
  public
    constructor Create(AParent: TControl); override;
    function PreferredSize: TSize; override;
    function HintAt(X, Y: LongInt; out Area: TRectangle): string; override;
    property Status: string read FStatus write SetStatus;
    { 0 to 100 while loading; -1 none. }
    property Progress: LongInt read FProgress write SetProgress;
    property Secure: Boolean read FSecure write SetSecure;
    { '' at 100 %. }
    property ZoomText: string read FZoomText write SetZoomText;
    property DownloadsText: string read FDownloadsText write SetDownloadsText;
    property Offline: Boolean read FOffline write SetOffline;
    property OnLockClick: TControlEvent read FOnLockClick write FOnLockClick;
    property OnDownloadsClick: TControlEvent read FOnDownloadsClick write FOnDownloadsClick;
  end;

implementation

uses
  Math,
  Abi.SystemCalls,
  Drawing.Colors,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text,
  Controls.Painting,
  Controls.IconTheme,
  Controls.LayoutRules;

const
  BarHeight = 22;
  GripWidth = 16;
  LockWidth = 22;
  ProgressWidth = 100;
  Gap = 4;

constructor TBrowserStatusBar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FProgress := -1;
  Align := AlignBottom;
  SetBounds(0, 0, 400, BarHeight);
end;

function TBrowserStatusBar.PreferredSize: TSize;
begin
  Result := MakeSize(400, BarHeight);
end;

procedure TBrowserStatusBar.SetStatus(const Value: string);
begin
  if FStatus <> Value then
  begin
    FStatus := Value;
    Invalidate;
  end;
end;

procedure TBrowserStatusBar.SetProgress(Value: LongInt);
begin
  if FProgress <> Value then
  begin
    FProgress := Value;
    Invalidate;
  end;
end;

procedure TBrowserStatusBar.SetSecure(Value: Boolean);
begin
  if FSecure <> Value then
  begin
    FSecure := Value;
    Invalidate;
  end;
end;

procedure TBrowserStatusBar.SetZoomText(const Value: string);
begin
  if FZoomText <> Value then
  begin
    FZoomText := Value;
    Invalidate;
  end;
end;

procedure TBrowserStatusBar.SetDownloadsText(const Value: string);
begin
  if FDownloadsText <> Value then
  begin
    FDownloadsText := Value;
    Invalidate;
  end;
end;

procedure TBrowserStatusBar.SetOffline(Value: Boolean);
begin
  if FOffline <> Value then
  begin
    FOffline := Value;
    Invalidate;
  end;
end;

{ Pixels, right to left. }
function TBrowserStatusBar.GripBox: TRectangle;
begin
  Result := MakeRectangle(RectangleWidth(PixelBounds) - Scaled(GripWidth), 0, Scaled(GripWidth),
    RectangleHeight(PixelBounds));
end;

function TBrowserStatusBar.LockBox: TRectangle;
var
  Right: LongInt;
begin
  Right := GripBox.Left;
  if FSecure then
    Result := MakeRectangle(Right - Scaled(LockWidth), 0, Scaled(LockWidth), RectangleHeight(PixelBounds))
  else
    Result := MakeRectangle(Right, 0, 0, RectangleHeight(PixelBounds));
end;

function TBrowserStatusBar.ZoomBox: TRectangle;
var
  Width: LongInt;
begin
  Width := 0;
  if FZoomText <> '' then
    Width := TextWidth(ControlFace, FZoomText) + Scaled(2 * Gap);
  Result := MakeRectangle(LockBox.Left - Width, 0, Width, RectangleHeight(PixelBounds));
end;

function TBrowserStatusBar.DownloadsBox: TRectangle;
var
  Width: LongInt;
begin
  Width := 0;
  if FDownloadsText <> '' then
    Width := TextWidth(ControlFace, FDownloadsText) + Scaled(2 * Gap + 20);
  Result := MakeRectangle(ZoomBox.Left - Width, 0, Width, RectangleHeight(PixelBounds));
end;

function TBrowserStatusBar.OfflineBox: TRectangle;
var
  Width: LongInt;
begin
  Width := 0;
  if FOffline then
    Width := TextWidth(ControlFace, 'Offline') + Scaled(2 * Gap);
  Result := MakeRectangle(DownloadsBox.Left - Width, 0, Width, RectangleHeight(PixelBounds));
end;

function TBrowserStatusBar.ProgressBox: TRectangle;
var
  Width: LongInt;
begin
  Width := 0;
  if FProgress >= 0 then
    Width := Scaled(ProgressWidth + 2 * Gap);
  Result := MakeRectangle(OfflineBox.Left - Width, 0, Width, RectangleHeight(PixelBounds));
end;

procedure TBrowserStatusBar.Paint(var Canvas: TCanvas);
var
  Box, Part, Meter, Icon: TRectangle;
  Size: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  DrawEtchedHorizontalLine(Canvas, 0, Box.Right, 0);
  Size := Scaled(16);
  Part := MakeRectangle(Scaled(Gap), Box.Top + Scaled(2), ProgressBox.Left - Scaled(2 * Gap), RectangleHeight(Box) -
    Scaled(2));
  DrawTextInBox(Canvas, ControlFace, FStatus, Part, AlignTextLeft, Theme.FaceText);
  if FProgress >= 0 then
  begin
    Part := ProgressBox;
    Meter := MakeRectangle(Part.Left + Scaled(Gap), Part.Top + Scaled(6), Scaled(ProgressWidth),
      RectangleHeight(Part) - Scaled(10));
    FillRectangle(Canvas, Meter, Theme.Field);
    DrawSunkenEdge(Canvas, Meter);
    FillRectangle(Canvas, MakeRectangle(Meter.Left + 1, Meter.Top + 1, (RectangleWidth(Meter) - 2) *
      EnsureRange(FProgress, 0, 100) div 100, RectangleHeight(Meter) - 2), Theme.Selection);
  end;
  if FOffline then
  begin
    Part := OfflineBox;
    DrawEtchedVerticalLine(Canvas, Part.Left, Part.Top + Scaled(3), Part.Bottom - Scaled(2));
    DrawTextInBox(Canvas, ControlFace, 'Offline', Part, AlignTextCenter, Theme.FaceText);
  end;
  if FDownloadsText <> '' then
  begin
    Part := DownloadsBox;
    DrawEtchedVerticalLine(Canvas, Part.Left, Part.Top + Scaled(3), Part.Bottom - Scaled(2));
    Icon := MakeRectangle(Part.Left + Scaled(Gap), Part.Top + (RectangleHeight(Part) - Size) div 2, Size, Size);
    DrawThemeIcon(Canvas, 'folder-downloads', Icon);
    DrawTextInBox(Canvas, ControlFace, FDownloadsText, MakeRectangle(Icon.Right + Scaled(2), Part.Top,
      Part.Right - Icon.Right - Scaled(2), RectangleHeight(Part)), AlignTextLeft, Theme.FaceText);
  end;
  if FZoomText <> '' then
  begin
    Part := ZoomBox;
    DrawEtchedVerticalLine(Canvas, Part.Left, Part.Top + Scaled(3), Part.Bottom - Scaled(2));
    DrawTextInBox(Canvas, ControlFace, FZoomText, Part, AlignTextCenter, Theme.FaceText);
  end;
  if FSecure then
  begin
    Part := LockBox;
    DrawEtchedVerticalLine(Canvas, Part.Left, Part.Top + Scaled(3), Part.Bottom - Scaled(2));
    Icon := MakeRectangle(Part.Left + (RectangleWidth(Part) - Size) div 2, Part.Top + (RectangleHeight(Part) - Size) div 2,
      Size, Size);
    DrawThemeIcon(Canvas, 'action-lock', Icon);
  end;
  DrawSizeGrip(Canvas, GripBox);
end;

procedure TBrowserStatusBar.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  inherited PointerUp(X, Y, Button);
  if Button <> ButtonLeft then
    Exit;
  if FSecure and RectangleContainsPoint(LockBox, X, Y) and Assigned(FOnLockClick) then
    FOnLockClick(Self)
  else if (FDownloadsText <> '') and RectangleContainsPoint(DownloadsBox, X, Y) and Assigned(FOnDownloadsClick) then
    FOnDownloadsClick(Self);
end;

function TBrowserStatusBar.HintAt(X, Y: LongInt; out Area: TRectangle): string;
begin
  Area := MakeRectangle(0, 0, 0, 0);
  Result := '';
  if FSecure and RectangleContainsPoint(LockBox, X, Y) then
  begin
    Area := LockBox;
    Result := 'The page was sent over a secure connection: click for details';
  end
  else if (FDownloadsText <> '') and RectangleContainsPoint(DownloadsBox, X, Y) then
  begin
    Area := DownloadsBox;
    Result := 'Show the downloads';
  end;
end;

end.
