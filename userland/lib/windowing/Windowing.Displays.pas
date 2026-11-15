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
  The displays the display server has, as a program asks about them:
  where each is on the desktop, its size, scale and DPI, its modes; and
  changing a display's scale or mode (as a display's settings would).

  Each call sends a request and waits for its answer (other events that
  arrive meanwhile are kept, Windowing.Connection). The program must be
  connected (ConnectToDisplay).
}
unit Windowing.Displays;

{$mode objfpc}

interface

type
  TDisplayInformation = record
    { Its size in pixels, its DPI and scale. }
    Width: LongInt;
    Height: LongInt;
    Dpi: LongWord;
    ScalePercent: LongWord;
    { Its place and size on the desktop, in logical units. }
    Left: LongInt;
    Top: LongInt;
    LogicalWidth: LongInt;
    LogicalHeight: LongInt;
  end;

{ What the display numbered Number (0, the first) is like; False if
  there is no such display (or no answer). }
function DescribeDisplay(Number: LongInt; out Information: TDisplayInformation): Boolean;
{ How many displays there are. }
function CountDisplays: LongInt;
{ Asks for a new scale (100 to 400 percent) for a display, and gives
  what it is like then. }
function SetDisplayScale(Number: LongInt; Percent: LongWord; out Information: TDisplayInformation): Boolean;
{ Asks for one of the display's modes, and gives what it is like then
  (the size it had if the mode was refused). }
function SetDisplayMode(Number: LongInt; Width, Height: LongInt; out Information: TDisplayInformation): Boolean;
{ The display's mode numbered Index (from 0, smallest first); False past
  the end. Current: the display has it now. }
function DescribeDisplayMode(Number, Index: LongInt; out Width, Height: LongInt; out Current: Boolean): Boolean;
{ The display's work area: what the shell's taskbar leaves of it (all
  of it without a shell), in logical units of the desktop; False if
  there is no such display. }
function DescribeWorkArea(Number: LongInt; out Left, Top, Width, Height: LongInt): Boolean;
{ Moves a box Width x Height whose top left is (Left, Top), logical
  units, onto the display that point is on (or the nearest): all of it
  if it fits, its top left first. For placing dialogs and pop-ups. }
procedure KeepOnDisplay(var Left, Top: LongInt; Width, Height: LongInt);

implementation

uses
  Windowing.Protocol,
  Windowing.Connection;

const
  ReplyTimeout = 5000;

{ Sends Request and takes the EventDisplayDescribed that answers it. }
function AskForDescription(var Request: TWindowMessage; out Information: TDisplayInformation): Boolean;
var
  Reply: TWindowMessage;
begin
  FillChar(Information, SizeOf(Information), 0);
  SendRequest(Request, -1);
  if not WaitForEvent(EventDisplayDescribed, ReplyTimeout, Reply) or ((Reply.Flags and DisplayExists) = 0) then
    Exit(False);
  Information.Width := Reply.Width;
  Information.Height := Reply.Height;
  Information.Dpi := LongWord(Reply.Value);
  Information.ScalePercent := Reply.Code;
  Information.Left := Reply.Left;
  Information.Top := Reply.Top;
  Information.LogicalWidth := Reply.SurfaceWidth;
  Information.LogicalHeight := Reply.SurfaceHeight;
  Result := True;
end;

function DescribeDisplay(Number: LongInt; out Information: TDisplayInformation): Boolean;
var
  Request: TWindowMessage;
begin
  Request := NewMessage(RequestDescribeDisplay, 0);
  Request.Code := LongWord(Number);
  Result := AskForDescription(Request, Information);
end;

function DescribeWorkArea(Number: LongInt; out Left, Top, Width, Height: LongInt): Boolean;
var
  Request: TWindowMessage;
  Reply: TWindowMessage;
begin
  Left := 0;
  Top := 0;
  Width := 0;
  Height := 0;
  Request := NewMessage(RequestDescribeWorkArea, 0);
  Request.Code := LongWord(Number);
  SendRequest(Request, -1);
  if not WaitForEvent(EventWorkArea, ReplyTimeout, Reply) or ((Reply.Flags and DisplayExists) = 0) then
    Exit(False);
  Left := Reply.Left;
  Top := Reply.Top;
  Width := Reply.Width;
  Height := Reply.Height;
  Result := True;
end;

function CountDisplays: LongInt;
var
  Information: TDisplayInformation;
begin
  Result := 0;
  while DescribeDisplay(Result, Information) do
    Inc(Result);
end;

function SetDisplayScale(Number: LongInt; Percent: LongWord; out Information: TDisplayInformation): Boolean;
var
  Request: TWindowMessage;
begin
  Request := NewMessage(RequestSetScale, 0);
  Request.Code := Percent;
  Request.Value := Number;
  Result := AskForDescription(Request, Information);
end;

function SetDisplayMode(Number: LongInt; Width, Height: LongInt; out Information: TDisplayInformation): Boolean;
var
  Request: TWindowMessage;
begin
  Request := NewMessage(RequestSetDisplayMode, 0);
  Request.Code := LongWord(Number);
  Request.Width := Width;
  Request.Height := Height;
  Result := AskForDescription(Request, Information);
end;

function DescribeDisplayMode(Number, Index: LongInt; out Width, Height: LongInt; out Current: Boolean): Boolean;
var
  Request: TWindowMessage;
  Reply: TWindowMessage;
begin
  Width := 0;
  Height := 0;
  Current := False;
  Request := NewMessage(RequestDescribeDisplayMode, 0);
  Request.Code := LongWord(Number);
  Request.Value := Index;
  SendRequest(Request, -1);
  if not WaitForEvent(EventDisplayMode, ReplyTimeout, Reply) or (Reply.Width <= 0) then
    Exit(False);
  Width := Reply.Width;
  Height := Reply.Height;
  Current := (Reply.Flags and DisplayModeCurrent) <> 0;
  Result := True;
end;

{ How far (Left, Top) is from the display, squared (0 on it). }
function DistanceSquared(const Information: TDisplayInformation; Left, Top: LongInt): Int64;
var
  DeltaX: Int64;
  DeltaY: Int64;
begin
  DeltaX := 0;
  DeltaY := 0;
  if Left < Information.Left then
    DeltaX := Information.Left - Left
  else if Left >= Information.Left + Information.LogicalWidth then
    DeltaX := Left - (Information.Left + Information.LogicalWidth) + 1;
  if Top < Information.Top then
    DeltaY := Information.Top - Top
  else if Top >= Information.Top + Information.LogicalHeight then
    DeltaY := Top - (Information.Top + Information.LogicalHeight) + 1;
  Result := DeltaX * DeltaX + DeltaY * DeltaY;
end;

procedure KeepOnDisplay(var Left, Top: LongInt; Width, Height: LongInt);
var
  Number: LongInt;
  Information: TDisplayInformation;
  Nearest: TDisplayInformation;
  Distance: Int64;
  Best: Int64;
begin
  Best := High(Int64);
  Number := 0;
  while DescribeDisplay(Number, Information) do
  begin
    Distance := DistanceSquared(Information, Left, Top);
    if Distance < Best then
    begin
      Best := Distance;
      Nearest := Information;
    end;
    Inc(Number);
  end;
  if Number = 0 then
    Exit;
  if Left + Width > Nearest.Left + Nearest.LogicalWidth then
    Left := Nearest.Left + Nearest.LogicalWidth - Width;
  if Top + Height > Nearest.Top + Nearest.LogicalHeight then
    Top := Nearest.Top + Nearest.LogicalHeight - Height;
  if Left < Nearest.Left then
    Left := Nearest.Left;
  if Top < Nearest.Top then
    Top := Nearest.Top;
end;

end.
