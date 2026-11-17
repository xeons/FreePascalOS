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
  The notification area at the taskbar's right end: a sunken panel with
  the programs' notification icons (Windowing.Notifications; the display
  server passes them on as EventNotificationIconChanged) and the clock.

  Icons stand left to right in the order they came. An icon's tooltip
  is its hint (HintAt), which the taskbar window's hints show when the
  pointer rests on it (Controls.Hints); a click on one is told
  (OnIconClicked:
  the volume's opens the volume control, the network's the list of
  interfaces). Changes are said on the standard output
  ("notification N TEXT", "notification-gone N").
}
unit Desktop.NotificationArea;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Windowing.Protocol,
  Controls.Base;

type
  TNotificationIcon = record
    Number: LongWord;
    Picture: LongWord;
    Tooltip: string;
  end;

  TNotificationArea = class(TControl)
  private
    FIcons: array of TNotificationIcon;
    FClock: string;
    FOnIconClicked: TControlEvent;
    FClicked: LongInt;
    function GetIconCount: LongInt;
    function GetIcon(Index: LongInt): TNotificationIcon;
    function IconAt(X, Y: LongInt): LongInt;
    procedure RemoveIcon(Index: LongInt);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
  public
    { Takes an EventNotificationIconChanged. }
    procedure TakeChange(const Message: TWindowMessage);
    procedure SetClock(const TimeText: string);
    { The width it wants for its icons and the clock (logical units). }
    function PreferredWidth: LongInt;
    { Icon Index's place and the clock's, in the control's pixels. }
    function IconBounds(Index: LongInt): TRectangle;
    function ClockBounds: TRectangle;
    property IconCount: LongInt read GetIconCount;
    property Icons[Index: LongInt]: TNotificationIcon read GetIcon;
    property Clock: string read FClock;
    { An icon's tooltip, about the icon. }
    function HintAt(X, Y: LongInt; out Area: TRectangle): string; override;
    { The icon clicked last (for OnIconClicked). }
    property Clicked: LongInt read FClicked;
    property OnIconClicked: TControlEvent read FOnIconClicked write FOnIconClicked;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text,
  Desktop.SmallPictures,
  Desktop.Clock,
  Desktop.Report;

const
  { Logical units. }
  IconSize = 16;
  IconGap = 4;
  Padding = 6;

function TNotificationArea.GetIconCount: LongInt;
begin
  Result := Length(FIcons);
end;

function TNotificationArea.GetIcon(Index: LongInt): TNotificationIcon;
begin
  Result := FIcons[Index];
end;

function TNotificationArea.PreferredWidth: LongInt;
begin
  Result := Padding + Length(FIcons) * (IconSize + IconGap) + Unscaled(TextWidth(ControlFace, WidestClockText)) + Padding;
end;

function TNotificationArea.IconBounds(Index: LongInt): TRectangle;
begin
  Result := MakeRectangle(Scaled(Padding + Index * (IconSize + IconGap)),
    (RectangleHeight(PixelBounds) - Scaled(IconSize)) div 2, Scaled(IconSize), Scaled(IconSize));
end;

function TNotificationArea.ClockBounds: TRectangle;
var
  Left: LongInt;
begin
  Left := Scaled(Padding + Length(FIcons) * (IconSize + IconGap));
  Result := MakeRectangle(Left, 0, RectangleWidth(PixelBounds) - Left - Scaled(Padding), RectangleHeight(PixelBounds));
end;

function TNotificationArea.IconAt(X, Y: LongInt): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(FIcons) do
    if RectangleContainsPoint(IconBounds(Index), X, Y) then
      Exit(Index);
  Result := -1;
end;

function TNotificationArea.HintAt(X, Y: LongInt; out Area: TRectangle): string;
var
  Index: LongInt;
begin
  Area := MakeRectangle(0, 0, 0, 0);
  Result := '';
  Index := IconAt(X, Y);
  if Index < 0 then
    Exit;
  Area := IconBounds(Index);
  Result := FIcons[Index].Tooltip;
end;

procedure TNotificationArea.SetClock(const TimeText: string);
begin
  if TimeText = FClock then
    Exit;
  FClock := TimeText;
  Say('clock ' + TimeText);
  Invalidate;
end;

procedure TNotificationArea.RemoveIcon(Index: LongInt);
begin
  Say(Format('notification-gone %u', [FIcons[Index].Number]));
  while Index < High(FIcons) do
  begin
    FIcons[Index] := FIcons[Index + 1];
    Inc(Index);
  end;
  SetLength(FIcons, Length(FIcons) - 1);
end;

procedure TNotificationArea.TakeChange(const Message: TWindowMessage);
var
  Index: LongInt;
begin
  Index := 0;
  while (Index < Length(FIcons)) and (FIcons[Index].Number <> Message.Code) do
    Inc(Index);
  if Message.Value = 0 then
  begin
    if Index < Length(FIcons) then
      RemoveIcon(Index);
  end
  else
  begin
    if Index = Length(FIcons) then
    begin
      SetLength(FIcons, Index + 1);
      FIcons[Index].Number := Message.Code;
    end;
    FIcons[Index].Picture := Message.Flags;
    FIcons[Index].Tooltip := MessageText(Message);
    Say(Format('notification %u %s', [Message.Code, FIcons[Index].Tooltip]));
  end;
  Invalidate;
end;

procedure TNotificationArea.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Index: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.TrayFace);
  DrawEdge(Canvas, Box, Theme.Shadow, Theme.Highlight);
  for Index := 0 to High(FIcons) do
    DrawNotificationPicture(Canvas, FIcons[Index].Picture, IconBounds(Index));
  DrawTextInBox(Canvas, ControlFace, FClock, ClockBounds, AlignTextRight, Theme.TrayText);
end;

procedure TNotificationArea.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  if Button <> ButtonLeft then
    Exit;
  FClicked := IconAt(X, Y);
  if (FClicked >= 0) and Assigned(FOnIconClicked) then
    FOnIconClicked(Self);
end;

end.
