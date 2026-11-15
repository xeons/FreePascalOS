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

  A window may have an owner, another window of the same program (a
  dialog's is the window it asks for). An owned window is always above
  its owner: raising the owner raises the windows it owns above it, in
  the order they were in, so a dialog never disappears behind the window
  it belongs to. An owned window counts as topmost if its owner does.
  The owner can change later (ChangeOwner), the same rule kept.
}
unit Server.Windows;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Drawing.Surfaces,
  Windowing.Protocol;

type
  { A rectangle of a client area with a pointer shape of its own. }
  TPointerArea = record
    { Surface pixels; empty if the area is not used. }
    Bounds: TRectangle;
    Shape: LongWord;
  end;

  PServerWindow = ^TServerWindow;
  TServerWindow = record
    Id: LongWord;
    { The program that made it (a PClient, Server.Clients). }
    Client: Pointer;
    { The window it belongs to, kept above (nil: none). }
    OwnerWindow: PServerWindow;
    Flags: LongWord;
    Title: array[0..TitleCapacity - 1] of Char;
    { The client area's top left on the screen, in pixels. }
    ClientLeft: LongInt;
    ClientTop: LongInt;
    Surface: TSurface;
    Section: Int64;
    Visible: Boolean;
    { Hidden because its owner was; shown again with it. }
    HiddenWithOwner: Boolean;
    { It is never activated and gets no input (a modal dialog's owner). }
    Disabled: Boolean;
    Maximized: Boolean;
    { The client area before it was maximized. }
    RestoreBounds: TRectangle;
    { The pointer's shape over the client area, and over the areas the
      program set (Server.PointerAreas). }
    PointerShape: LongWord;
    PointerAreas: array[1..MaximumPointerAreas] of TPointerArea;
  end;

const
  MaximumWindows = 256;

var
  Windows: array[0..MaximumWindows - 1] of PServerWindow;
  WindowCount: LongInt;

{ A new window record of Client's at the top (below topmost ones; owned
  by OwnerWindow if not nil), or nil. }
function AddWindow(Client: Pointer; Flags: LongWord; OwnerWindow: PServerWindow): PServerWindow;
{ Takes it out of the list and frees it (its surface already unmapped);
  the windows it owned have no owner any more. }
procedure RemoveWindow(Window: PServerWindow);
{ Brings the window to the top of its layer, and the windows it owns
  (and theirs) above it. }
procedure RaiseWindow(Window: PServerWindow);
{ True if Window belongs to Owner, directly or through other windows. }
function IsOwnedBy(Window, Owner: PServerWindow): Boolean;
{ Gives the window another owner (nil: none; never one it owns), and
  raises it if that leaves it below its owner or in the wrong layer. }
procedure ChangeOwner(Window, Owner: PServerWindow);
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

{ Topmost itself, or owned by a topmost window (it must stay above it). }
function IsTopmost(Window: PServerWindow): Boolean;
begin
  Result := False;
  while Window <> nil do
  begin
    if (Window^.Flags and WindowTopmost) <> 0 then
      Exit(True);
    Window := Window^.OwnerWindow;
  end;
end;

function IsOwnedBy(Window, Owner: PServerWindow): Boolean;
begin
  Result := False;
  if Window = nil then
    Exit;
  Window := Window^.OwnerWindow;
  while Window <> nil do
  begin
    if Window = Owner then
      Exit(True);
    Window := Window^.OwnerWindow;
  end;
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

function AddWindow(Client: Pointer; Flags: LongWord; OwnerWindow: PServerWindow): PServerWindow;
begin
  if WindowCount = MaximumWindows then
    Exit(nil);
  New(Result);
  FillChar(Result^, SizeOf(Result^), 0);
  Result^.Id := NextWindowId;
  Inc(NextWindowId);
  Result^.Client := Client;
  Result^.OwnerWindow := OwnerWindow;
  Result^.Flags := Flags;
  Result^.Section := -1;
  InsertAt(Result, TopPlaceFor(Result));
end;

procedure RemoveWindow(Window: PServerWindow);
var
  Index: LongInt;
begin
  TakeOut(Window);
  for Index := 0 to WindowCount - 1 do
    if Windows[Index]^.OwnerWindow = Window then
      Windows[Index]^.OwnerWindow := nil;
  Dispose(Window);
end;

procedure RaiseWindow(Window: PServerWindow);
var
  Owned: array[0..MaximumWindows - 1] of PServerWindow;
  OwnedCount: LongInt;
  Index: LongInt;
begin
  TakeOut(Window);
  InsertAt(Window, TopPlaceFor(Window));
  { The windows it owns directly, bottom first, each raised in turn (with
    the ones they own), so they end above it in the order they had. }
  OwnedCount := 0;
  for Index := 0 to WindowCount - 1 do
    if Windows[Index]^.OwnerWindow = Window then
    begin
      Owned[OwnedCount] := Windows[Index];
      Inc(OwnedCount);
    end;
  for Index := 0 to OwnedCount - 1 do
    RaiseWindow(Owned[Index]);
end;

procedure ChangeOwner(Window, Owner: PServerWindow);
var
  WasTopmost: Boolean;
begin
  if (Owner = Window) or IsOwnedBy(Owner, Window) then
    Exit;
  WasTopmost := IsTopmost(Window);
  Window^.OwnerWindow := Owner;
  if (WasTopmost <> IsTopmost(Window)) or ((Owner <> nil) and (IndexOf(Window) < IndexOf(Owner))) then
    RaiseWindow(Window);
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
