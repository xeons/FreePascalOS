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
  Moving a window by copying what stays the same.

  When a window moves, the part of it that was visible and is visible
  again at the new place is the same picture shifted: those pixels are
  copied within the back buffer, and only the rest of the old and new
  places is drawn again (what became uncovered, and what of the window
  was hidden before). Dragging a big window then costs a copy instead
  of drawing every window under it again.

  A pixel can be copied only if the back buffer has it right: it is not
  waiting to be drawn again (pending damage, such as a program's new
  drawing or the pointer's old place), no window above covers it at the
  old place or the new one, and it is on the screen at both. The pointer
  and a resize outline are drawn over everything, so their places are
  damaged first and never copied.

  The copy may overlap itself, so it goes a line at a time in the order
  that never reads a pixel already written: from the bottom up when the
  window moves down, from the top down otherwise, and within a line from
  the right when it moves right.

  For testing, CheckingMoves makes every compose after a move draw the
  whole screen again and compare: the picture must be exactly the same.
}
unit Server.WindowMoves;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Server.Windows;

var
  { Compare each move's picture with a full redraw (displayserver
    --check-moves). }
  CheckingMoves: Boolean;

{ The visible window has moved from OldFrame to where it is now: copies
  what can be copied and damages the rest. }
procedure MoveWindowPixels(Window: PServerWindow; const OldFrame: TRectangle);
{ When checking: if a window moved since the last check, draws the whole
  screen again and compares it with what the moves left (call after
  Compose). }
procedure CheckMovesAgainstFullRedraw;
{ When checking: prints how many moves were compared and how many
  differed. }
procedure ReportMoveChecks;

implementation

uses
  Drawing.Regions,
  Drawing.Surfaces,
  Sys.Format,
  Sys.Streams,
  Server.Screen,
  Server.Cursor,
  Server.Composer;

var
  MovedSinceCheck: Boolean;
  ChecksMade: LongWord;
  ChecksDiffering: LongWord;
  Snapshot: array of LongWord;

{ What the windows above Window cover. }
procedure CollectCovering(Window: PServerWindow; out Covering: TRegion);
var
  Index: LongInt;
  Above: Boolean;
begin
  ClearRegion(Covering);
  Above := False;
  for Index := 0 to WindowCount - 1 do
  begin
    if Above and Windows[Index]^.Visible then
      AddRectangleToRegion(Covering, FrameRectangle(Windows[Index]));
    if Windows[Index] = Window then
      Above := True;
  end;
end;

{ The spans of Region on line Y (left edges and right edges), sorted
  from the left. }
procedure SpansOnLine(const Region: TRegion; Y: LongInt; var Lefts, Rights: array of LongInt; out Count: LongInt);
var
  Index: LongInt;
  Place: LongInt;
  Rectangle: TRectangle;
begin
  Count := 0;
  for Index := 0 to Region.Count - 1 do
  begin
    Rectangle := Region.Rectangles[Index];
    if (Y < Rectangle.Top) or (Y >= Rectangle.Bottom) then
      Continue;
    { Kept in order by inserting each in its place. }
    Place := Count;
    while (Place > 0) and (Lefts[Place - 1] > Rectangle.Left) do
    begin
      Lefts[Place] := Lefts[Place - 1];
      Rights[Place] := Rights[Place - 1];
      Dec(Place);
    end;
    Lefts[Place] := Rectangle.Left;
    Rights[Place] := Rectangle.Right;
    Inc(Count);
  end;
end;

{ Copies one line of Region in the back buffer from DeltaX, DeltaY
  pixels away (Lefts and Rights: room for a span per rectangle). }
procedure CopyLine(const Region: TRegion; Y, DeltaX, DeltaY: LongInt; var Lefts, Rights: array of LongInt);
var
  Count: LongInt;
  Step: LongInt;
  Target: PLongWord;
  Source: PLongWord;
begin
  SpansOnLine(Region, Y, Lefts, Rights, Count);
  if Count = 0 then
    Exit;
  Target := SurfaceLine(BackBuffer, Y);
  Source := SurfaceLine(BackBuffer, Y - DeltaY);
  if DeltaX > 0 then
    for Step := Count - 1 downto 0 do
      Move(Source[Lefts[Step] - DeltaX], Target[Lefts[Step]], (Rights[Step] - Lefts[Step]) * SizeOf(LongWord))
  else
    for Step := 0 to Count - 1 do
      Move(Source[Lefts[Step] - DeltaX], Target[Lefts[Step]], (Rights[Step] - Lefts[Step]) * SizeOf(LongWord));
end;

{ Every pixel of Region (the new place) from DeltaX, DeltaY pixels away. }
procedure CopyRegionPixels(const Region: TRegion; DeltaX, DeltaY: LongInt);
var
  Bounds: TRectangle;
  Y: LongInt;
  Lefts: array of LongInt;
  Rights: array of LongInt;
begin
  Bounds := RegionBounds(Region);
  SetLength(Lefts, Region.Count);
  SetLength(Rights, Region.Count);
  if DeltaY > 0 then
    for Y := Bounds.Bottom - 1 downto Bounds.Top do
      CopyLine(Region, Y, DeltaX, DeltaY, Lefts, Rights)
  else
    for Y := Bounds.Top to Bounds.Bottom - 1 do
      CopyLine(Region, Y, DeltaX, DeltaY, Lefts, Rights);
end;

procedure DamageRegion(const Region: TRegion);
var
  Index: LongInt;
begin
  for Index := 0 to Region.Count - 1 do
    AddDamage(Region.Rectangles[Index]);
end;

procedure MoveWindowPixels(Window: PServerWindow; const OldFrame: TRectangle);
var
  NewFrame: TRectangle;
  DeltaX: LongInt;
  DeltaY: LongInt;
  Covering: TRegion;
  Pending: TRegion;
  Copied: TRegion;
  Redrawn: TRegion;
begin
  NewFrame := FrameRectangle(Window);
  DeltaX := NewFrame.Left - OldFrame.Left;
  DeltaY := NewFrame.Top - OldFrame.Top;
  AddDamage(CursorRectangle);
  if OutlineVisible then
    AddDamage(Outline);
  CollectCovering(Window, Covering);
  CopyDamage(Pending);
  { The old place's pixels that are right and the window's... }
  SetRegionToRectangle(Copied, OldFrame);
  IntersectRegionWithRectangle(Copied, ScreenBounds);
  SubtractRegionFromRegion(Copied, Covering);
  SubtractRegionFromRegion(Copied, Pending);
  { ...where they go, where the window shows and nothing waits to be
    drawn anyway. }
  OffsetRegion(Copied, DeltaX, DeltaY);
  IntersectRegionWithRectangle(Copied, ScreenBounds);
  SubtractRegionFromRegion(Copied, Covering);
  SubtractRegionFromRegion(Copied, Pending);
  if not RegionIsEmpty(Copied) then
  begin
    CopyRegionPixels(Copied, DeltaX, DeltaY);
    AddPresentOnly(Copied);
  end;
  SetRegionToRectangle(Redrawn, OldFrame);
  AddRectangleToRegion(Redrawn, NewFrame);
  SubtractRegionFromRegion(Redrawn, Copied);
  DamageRegion(Redrawn);
  MovedSinceCheck := True;
end;

procedure CheckMovesAgainstFullRedraw;
var
  Y: LongInt;
  X: LongInt;
  Line: PLongWord;
  Differing: Int64;
  FirstX: LongInt;
  FirstY: LongInt;
begin
  if not CheckingMoves or not MovedSinceCheck then
    Exit;
  MovedSinceCheck := False;
  SetLength(Snapshot, BackBuffer.Width * BackBuffer.Height);
  for Y := 0 to BackBuffer.Height - 1 do
    Move(SurfaceLine(BackBuffer, Y)^, Snapshot[Y * BackBuffer.Width], BackBuffer.Width * SizeOf(LongWord));
  AddDamage(ScreenBounds);
  Compose;
  Differing := 0;
  FirstX := 0;
  FirstY := 0;
  for Y := 0 to BackBuffer.Height - 1 do
  begin
    Line := SurfaceLine(BackBuffer, Y);
    for X := 0 to BackBuffer.Width - 1 do
      if Line[X] <> Snapshot[Y * BackBuffer.Width + X] then
      begin
        if Differing = 0 then
        begin
          FirstX := X;
          FirstY := Y;
        end;
        Inc(Differing);
      end;
  end;
  Inc(ChecksMade);
  if Differing = 0 then
    Exit;
  Inc(ChecksDiffering);
  WriteFormatted(StandardOutput, 'displayserver: a move left %d pixels unlike a full redraw (the first at %d,%d)'#10,
    [ArgumentNumber(Differing), ArgumentNumber(FirstX), ArgumentNumber(FirstY)]);
  FlushStream(StandardOutput);
end;

procedure ReportMoveChecks;
begin
  if not CheckingMoves then
    Exit;
  WriteFormatted(StandardOutput, 'displayserver: %u moves compared with a full redraw, %u differed'#10,
    [ArgumentUnsigned(ChecksMade), ArgumentUnsigned(ChecksDiffering)]);
  FlushStream(StandardOutput);
end;

end.
