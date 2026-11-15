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
  Windows: what the server knows of each, and their order.

  A window is its client area (the program's surface, mapped from the
  section the program gave, at a place on the screen in pixels) and,
  if framed, the frame around it (Server.Frames draws it). The list is
  in stacking order, bottom first; topmost windows stay above the rest.
}
unit Server.Windows;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Drawing.Surfaces,
  Windowing.Protocol;

type
  PServerWindow = ^TServerWindow;
  TServerWindow = record
    Id: LongWord;
    { The client that made it (Server.Clients). }
    Owner: Pointer;
    Flags: LongWord;
    Title: array[0..TitleCapacity - 1] of Char;
    { The client area's top left on the screen, in pixels. }
    ClientLeft: LongInt;
    ClientTop: LongInt;
    Surface: TSurface;
    Section: Int64;
    Visible: Boolean;
    Maximized: Boolean;
    { The client area before it was maximized. }
    RestoreBounds: TRectangle;
  end;

const
  MaximumWindows = 256;

var
  Windows: array[0..MaximumWindows - 1] of PServerWindow;
  WindowCount: LongInt;

{ A new window record at the top (below topmost ones), or nil. }
function AddWindow(Owner: Pointer; Flags: LongWord): PServerWindow;
{ Takes it out of the list and frees it (its surface already unmapped). }
procedure RemoveWindow(Window: PServerWindow);
procedure RaiseWindow(Window: PServerWindow);
function FindWindow(Id: LongWord): PServerWindow;

function ClientRectangle(Window: PServerWindow): TRectangle;
{ The whole window, frame included. }
function FrameRectangle(Window: PServerWindow): TRectangle;
function IsFramed(Window: PServerWindow): Boolean;
{ The topmost visible window whose frame holds (X, Y), or nil. }
function WindowAt(X, Y: LongInt): PServerWindow;

implementation

uses
  Windowing.Theme,
  Server.Theme;

var
  NextWindowId: LongWord = 1;

function IsTopmost(Window: PServerWindow): Boolean;
begin
  Result := (Window^.Flags and WindowTopmost) <> 0;
end;

function IndexOf(Window: PServerWindow): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to WindowCount - 1 do
    if Windows[Index] = Window then
      Exit(Index);
  Result := -1;
end;

{ Where a window goes when it is raised: the top, or below the topmost
  windows if it is not one. }
function TopPlaceFor(Window: PServerWindow): LongInt;
begin
  Result := WindowCount;
  if not IsTopmost(Window) then
    while (Result > 0) and IsTopmost(Windows[Result - 1]) do
      Dec(Result);
end;

procedure InsertAt(Window: PServerWindow; Place: LongInt);
var
  Index: LongInt;
begin
  Index := WindowCount;
  while Index > Place do
  begin
    Windows[Index] := Windows[Index - 1];
    Dec(Index);
  end;
  Windows[Place] := Window;
  Inc(WindowCount);
end;

procedure TakeOut(Window: PServerWindow);
var
  Index: LongInt;
begin
  Index := IndexOf(Window);
  if Index < 0 then
    Exit;
  while Index + 1 < WindowCount do
  begin
    Windows[Index] := Windows[Index + 1];
    Inc(Index);
  end;
  Dec(WindowCount);
end;

function AddWindow(Owner: Pointer; Flags: LongWord): PServerWindow;
begin
  if WindowCount = MaximumWindows then
    Exit(nil);
  New(Result);
  FillChar(Result^, SizeOf(Result^), 0);
  Result^.Id := NextWindowId;
  Inc(NextWindowId);
  Result^.Owner := Owner;
  Result^.Flags := Flags;
  Result^.Section := -1;
  InsertAt(Result, TopPlaceFor(Result));
end;

procedure RemoveWindow(Window: PServerWindow);
begin
  TakeOut(Window);
  Dispose(Window);
end;

procedure RaiseWindow(Window: PServerWindow);
begin
  TakeOut(Window);
  InsertAt(Window, TopPlaceFor(Window));
end;

function FindWindow(Id: LongWord): PServerWindow;
var
  Index: LongInt;
begin
  for Index := 0 to WindowCount - 1 do
    if Windows[Index]^.Id = Id then
      Exit(Windows[Index]);
  Result := nil;
end;

function IsFramed(Window: PServerWindow): Boolean;
begin
  Result := (Window^.Flags and WindowFramed) <> 0;
end;

function ClientRectangle(Window: PServerWindow): TRectangle;
begin
  Result := MakeRectangle(Window^.ClientLeft, Window^.ClientTop, Window^.Surface.Width, Window^.Surface.Height);
end;

function FrameRectangle(Window: PServerWindow): TRectangle;
var
  Border: LongInt;
begin
  Result := ClientRectangle(Window);
  if not IsFramed(Window) then
    Exit;
  Border := ScaledMetric(Theme.BorderWidth);
  Result.Left := Result.Left - Border;
  Result.Right := Result.Right + Border;
  Result.Bottom := Result.Bottom + Border;
  Result.Top := Result.Top - Border - ScaledMetric(Theme.TitleHeight);
end;

function WindowAt(X, Y: LongInt): PServerWindow;
var
  Index: LongInt;
begin
  for Index := WindowCount - 1 downto 0 do
    if Windows[Index]^.Visible and RectangleContainsPoint(FrameRectangle(Windows[Index]), X, Y) then
      Exit(Windows[Index]);
  Result := nil;
end;

end.
