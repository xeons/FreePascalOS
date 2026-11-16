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
  in stacking order, bottom first, in three layers: desktop windows
  (the shell's, WindowDesktop) at the bottom, then ordinary windows, and
  topmost windows above the rest. Raising a window brings it to the top
  of its layer only, so a desktop never covers anything.

  A window is on one screen at a time (Server.Desktop: the one holding
  the middle of its frame); its frame is drawn at that screen's scale,
  and its program draws its surface at it.

  A window may have an owner, another window of the same program (a
  dialog's is the window it asks for). An owned window is always above
  its owner: raising the owner raises the windows it owns above it, in
  the order they were in, so a dialog never disappears behind the window
  it belongs to. An owned window counts as topmost if its owner does;
  one owned by a desktop window is an ordinary window (a dialog of the
  desktop must not stay under everything).
  The owner can change later (ChangeOwner), the same rule kept.
}
unit Server.Windows;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Surfaces,
  Windowing.Protocol,
  Server.Screen;


type
  { A rectangle of a client area with a pointer shape of its own. }
  TPointerArea = record
    { Surface pixels; empty if the area is not used. }
    Bounds: TRectangle;
    Shape: LongWord;
  end;

  TServerWindow = class
  public
    Id: LongWord;
    { The program that made it (a TClient, Server.Clients). }
    Client: TObject;
    { The window it belongs to, kept above (nil: none). }
    OwnerWindow: TServerWindow;
    Flags: LongWord;
    Title: string;
    { The screen it is on (its number). }
    ScreenNumber: LongInt;
    { The client area's top left on the desktop, in pixels. }
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
    { Hidden by minimizing: the shell keeps it in its list, to restore. }
    Minimized: Boolean;
    { What the shell was last told about it (Server.Shell): whether it
      was told at all, and the flags, display and title it heard. }
    ToldShell: Boolean;
    ToldFlags: LongWord;
    ToldScreen: LongInt;
    ToldTitle: string;
    { The client area before it was maximized. }
    RestoreBounds: TRectangle;
    { The pointer's shape over the client area, and over the areas the
      program set (Server.PointerAreas). }
    PointerShape: LongWord;
    PointerAreas: array[1..MaximumPointerAreas] of TPointerArea;
    constructor Create(WindowId: LongWord; Owner: TObject; WindowFlags: LongWord; OwningWindow: TServerWindow);
  end;

  TServerWindowArray = array of TServerWindow;

var
  { Every window, in stacking order, bottom first. }
  Windows: TServerWindowArray;

function WindowCount: LongInt;
{ A new window of Client's at the top (below topmost ones; owned by
  OwnerWindow if not nil). }
function AddWindow(Client: TObject; Flags: LongWord; OwnerWindow: TServerWindow): TServerWindow;
{ Takes it out of the list and frees it (its surface already unmapped);
  the windows it owned have no owner any more. }
procedure RemoveWindow(Window: TServerWindow);
{ Brings the window to the top of its layer, and the windows it owns
  (and theirs) above it. }
procedure RaiseWindow(Window: TServerWindow);
{ True if Window belongs to Owner, directly or through other windows. }
function IsOwnedBy(Window, Owner: TServerWindow): Boolean;
{ Gives the window another owner (nil: none; never one it owns), and
  raises it if that leaves it below its owner or in the wrong layer. }
procedure ChangeOwner(Window, Owner: TServerWindow);
function FindWindow(Id: LongWord): TServerWindow;

{ The screen it is on, and that screen's scale. }
function WindowScreen(Window: TServerWindow): PScreen;
function WindowScale(Window: TServerWindow): LongWord;
{ A metric (logical units) in pixels at the window's scale. }
function WindowMetric(Window: TServerWindow; Value: LongInt): LongInt;
function ClientRectangle(Window: TServerWindow): TRectangle;
{ The whole window, frame included. }
function FrameRectangle(Window: TServerWindow): TRectangle;
function IsFramed(Window: TServerWindow): Boolean;
{ The topmost visible window whose frame holds (X, Y), or nil; while the
  screen is locked, only the lock screen's windows count
  (Server.ScreenLock). }
function WindowAt(X, Y: LongInt): TServerWindow;

implementation

uses
  Windowing.Theme,
  Server.Theme,
  Server.ScreenLock;

var
  NextWindowId: LongWord = 1;

constructor TServerWindow.Create(WindowId: LongWord; Owner: TObject; WindowFlags: LongWord;
  OwningWindow: TServerWindow);
begin
  inherited Create;
  Id := WindowId;
  Client := Owner;
  Flags := WindowFlags;
  OwnerWindow := OwningWindow;
  Section := -1;
end;

function WindowCount: LongInt;
begin
  Result := Length(Windows);
end;

function IndexOfWindow(Window: TServerWindow): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(Windows) do
    if Windows[Index] = Window then
      Exit(Index);
  Result := -1;
end;

procedure TakeOut(Window: TServerWindow);
var
  Index: LongInt;
begin
  Index := IndexOfWindow(Window);
  if Index >= 0 then
    Delete(Windows, Index, 1);
end;

type
  TLayer = (LayerDesktop, LayerOrdinary, LayerTopmost);

{ Topmost itself, or owned by a topmost window (it must stay above it). }
function IsTopmost(Window: TServerWindow): Boolean;
begin
  Result := False;
  while Window <> nil do
  begin
    if (Window.Flags and WindowTopmost) <> 0 then
      Exit(True);
    Window := Window.OwnerWindow;
  end;
end;

function LayerOf(Window: TServerWindow): TLayer;
begin
  if IsTopmost(Window) then
    Result := LayerTopmost
  else if (Window.Flags and WindowDesktop) <> 0 then
    Result := LayerDesktop
  else
    Result := LayerOrdinary;
end;

function IsOwnedBy(Window, Owner: TServerWindow): Boolean;
begin
  Result := False;
  if Window = nil then
    Exit;
  Window := Window.OwnerWindow;
  while Window <> nil do
  begin
    if Window = Owner then
      Exit(True);
    Window := Window.OwnerWindow;
  end;
end;


{ Where a window goes when it is raised: the top of its layer, below
  every window of a higher layer. }
function TopPlaceFor(Window: TServerWindow): LongInt;
var
  Layer: TLayer;
begin
  Layer := LayerOf(Window);
  Result := Length(Windows);
  while (Result > 0) and (LayerOf(Windows[Result - 1]) > Layer) do
    Dec(Result);
end;

function AddWindow(Client: TObject; Flags: LongWord; OwnerWindow: TServerWindow): TServerWindow;
begin
  Result := TServerWindow.Create(NextWindowId, Client, Flags, OwnerWindow);
  Inc(NextWindowId);
  Insert(Result, Windows, TopPlaceFor(Result));
end;

procedure RemoveWindow(Window: TServerWindow);
var
  Index: LongInt;
begin
  TakeOut(Window);
  for Index := 0 to High(Windows) do
    if Windows[Index].OwnerWindow = Window then
      Windows[Index].OwnerWindow := nil;
  Window.Free;
end;

procedure RaiseWindow(Window: TServerWindow);
var
  Owned: TServerWindowArray;
  Index: LongInt;
begin
  TakeOut(Window);
  Insert(Window, Windows, TopPlaceFor(Window));
  { The windows it owns directly, bottom first, each raised in turn (with
    the ones they own), so they end above it in the order they had. }
  Owned := nil;
  for Index := 0 to High(Windows) do
    if Windows[Index].OwnerWindow = Window then
      Insert(Windows[Index], Owned, Length(Owned));
  for Index := 0 to High(Owned) do
    RaiseWindow(Owned[Index]);
end;

procedure ChangeOwner(Window, Owner: TServerWindow);
var
  OldLayer: TLayer;
begin
  if (Owner = Window) or IsOwnedBy(Owner, Window) then
    Exit;
  OldLayer := LayerOf(Window);
  Window.OwnerWindow := Owner;
  if (OldLayer <> LayerOf(Window)) or ((Owner <> nil) and (IndexOfWindow(Window) < IndexOfWindow(Owner))) then
    RaiseWindow(Window);
end;

function FindWindow(Id: LongWord): TServerWindow;
var
  Index: LongInt;
begin
  for Index := 0 to High(Windows) do
    if Windows[Index].Id = Id then
      Exit(Windows[Index]);
  Result := nil;
end;

function IsFramed(Window: TServerWindow): Boolean;
begin
  Result := (Window.Flags and WindowFramed) <> 0;
end;

function WindowScreen(Window: TServerWindow): PScreen;
begin
  Result := ScreenByNumber(Window.ScreenNumber);
  if Result = nil then
    Result := @Screens[0];
end;

function WindowScale(Window: TServerWindow): LongWord;
begin
  Result := WindowScreen(Window)^.ScalePercent;
end;

function WindowMetric(Window: TServerWindow; Value: LongInt): LongInt;
begin
  Result := ScaledMetric(Value, WindowScale(Window));
end;

function ClientRectangle(Window: TServerWindow): TRectangle;
begin
  Result := MakeRectangle(Window.ClientLeft, Window.ClientTop, Window.Surface.Width, Window.Surface.Height);
end;

function FrameRectangle(Window: TServerWindow): TRectangle;
var
  Border: LongInt;
begin
  Result := ClientRectangle(Window);
  if not IsFramed(Window) then
    Exit;
  Border := WindowMetric(Window, Theme.BorderWidth);
  Result.Left := Result.Left - Border;
  Result.Right := Result.Right + Border;
  Result.Bottom := Result.Bottom + Border;
  Result.Top := Result.Top - Border - WindowMetric(Window, Theme.TitleHeight);
end;

function WindowAt(X, Y: LongInt): TServerWindow;
var
  Index: LongInt;
begin
  for Index := WindowCount - 1 downto 0 do
    if Windows[Index].Visible and WindowUsable(Windows[Index]) and
       RectangleContainsPoint(FrameRectangle(Windows[Index]), X, Y) then
      Exit(Windows[Index]);
  Result := nil;
end;

end.
