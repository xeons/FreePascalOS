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
  Turning and mirroring what the image viewer shows: rotations by
  quarter turns and flips, one after another, kept as a turn (how many
  quarter turns clockwise, after a horizontal mirror or not) and given
  to the picture box as one of EXIF's eight orientations (1 to 8,
  Image.Model's TImageOrientation in that order):

    turns, mirrored   0,no 1  0,yes 2  2,no 3  2,yes 4
                      3,yes 5 1,no 6   1,yes 7 3,no 8

  A flip after a turn mirrors what is seen: mirroring reverses the
  turns already made (a mirror image of a clockwise turn is an
  anticlockwise one).

  Plain logic: the host checks it (make apps-test).
}
unit ImageViewer.Orientations;

{$mode objfpc}
{$H+}

interface

type
  TViewTurn = record
    { Clockwise, 0 to 3. }
    QuarterTurns: LongInt;
    { Mirrored left to right before turning. }
    Mirrored: Boolean;
  end;

function NoTurn: TViewTurn;
function TurnedClockwise(const Turn: TViewTurn): TViewTurn;
function TurnedAnticlockwise(const Turn: TViewTurn): TViewTurn;
{ Mirrored left to right, or top to bottom, as it is seen. }
function FlippedHorizontally(const Turn: TViewTurn): TViewTurn;
function FlippedVertically(const Turn: TViewTurn): TViewTurn;
function IsNoTurn(const Turn: TViewTurn): Boolean;
{ EXIF's orientation value (1 to 8) for Turn. }
function ExifOrientationOf(const Turn: TViewTurn): LongInt;
{ The turn EXIF's orientation value Value (1 to 8) stands for; none for
  anything else. }
function TurnOfExif(Value: LongInt): TViewTurn;
{ Whether Turn swaps the picture's width and height. }
function TurnSwapsSides(const Turn: TViewTurn): Boolean;

implementation

function MakeTurn(QuarterTurns: LongInt; Mirrored: Boolean): TViewTurn;
begin
  Result.QuarterTurns := ((QuarterTurns mod 4) + 4) mod 4;
  Result.Mirrored := Mirrored;
end;

function NoTurn: TViewTurn;
begin
  Result := MakeTurn(0, False);
end;

function TurnedClockwise(const Turn: TViewTurn): TViewTurn;
begin
  Result := MakeTurn(Turn.QuarterTurns + 1, Turn.Mirrored);
end;

function TurnedAnticlockwise(const Turn: TViewTurn): TViewTurn;
begin
  Result := MakeTurn(Turn.QuarterTurns + 3, Turn.Mirrored);
end;

function FlippedHorizontally(const Turn: TViewTurn): TViewTurn;
begin
  Result := MakeTurn(4 - Turn.QuarterTurns, not Turn.Mirrored);
end;

function FlippedVertically(const Turn: TViewTurn): TViewTurn;
begin
  { A vertical flip is a horizontal one and a half turn. }
  Result := MakeTurn(6 - Turn.QuarterTurns, not Turn.Mirrored);
end;

function IsNoTurn(const Turn: TViewTurn): Boolean;
begin
  Result := (Turn.QuarterTurns = 0) and not Turn.Mirrored;
end;

function ExifOrientationOf(const Turn: TViewTurn): LongInt;
const
  Plain: array[0..3] of LongInt = (1, 6, 3, 8);
  Mirror: array[0..3] of LongInt = (2, 7, 4, 5);
begin
  if Turn.Mirrored then
    Result := Mirror[Turn.QuarterTurns]
  else
    Result := Plain[Turn.QuarterTurns];
end;

function TurnOfExif(Value: LongInt): TViewTurn;
var
  Turns: LongInt;
  Mirrored: Boolean;
begin
  for Mirrored := False to True do
    for Turns := 0 to 3 do
    begin
      Result := MakeTurn(Turns, Mirrored);
      if ExifOrientationOf(Result) = Value then
        Exit;
    end;
  Result := NoTurn;
end;

function TurnSwapsSides(const Turn: TViewTurn): Boolean;
begin
  Result := Odd(Turn.QuarterTurns);
end;

end.
