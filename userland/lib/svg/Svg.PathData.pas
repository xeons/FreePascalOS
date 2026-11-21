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
  SVG path data (SVG 2 9.3): the commands M, L, H, V, C, S, Q, T, A, Z
  in absolute (upper case) and relative (lower case) forms, with
  implicit repetitions (more numbers after a command repeat it; after a
  moveto they are linetos), the smooth curves' reflected control points
  and arcs with their compact flags ("a1 1 0 00 1 1"). An error ends the
  path where it happened, keeping what came before, as SVG says.
}
unit Svg.PathData;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Paths;

{ Adds the path data's subpaths to Path. }
procedure ParsePathData(const Data: string; var Path: TPath);
{ The points of a polyline or polygon's points attribute (an odd count
  drops the last number). }
procedure ParsePointsInto(const Data: string; var Path: TPath; Closed: Boolean);

implementation

uses
  Svg.Numbers;

procedure ParsePathData(const Data: string; var Path: TPath);
var
  Scanner: TSvgNumberScanner;
  Command: Char;
  Previous: Char;
  Relative: Boolean;
  CurrentX, CurrentY: Double;
  StartX, StartY: Double;
  ControlX, ControlY: Double;
  ReflectedX, ReflectedY: Double;
  Values: array[0..6] of Double;
  LargeArc, Sweep: Boolean;
  BaseX, BaseY: Double;
  First: Boolean;

  function ReadNumbers(Count: Integer): Boolean;
  var
    Index: Integer;
  begin
    for Index := 0 to Count - 1 do
    begin
      SkipSeparator(Scanner);
      if not ScanNumber(Scanner, Values[Index]) then
        Exit(False);
    end;
    Result := True;
  end;

  function ReadArc: Boolean;
  begin
    Result := False;
    if not ReadNumbers(3) then
      Exit;
    SkipSeparator(Scanner);
    if not ScanFlag(Scanner, LargeArc) then
      Exit;
    SkipSeparator(Scanner);
    if not ScanFlag(Scanner, Sweep) then
      Exit;
    SkipSeparator(Scanner);
    if not ScanNumber(Scanner, Values[3]) then
      Exit;
    SkipSeparator(Scanner);
    Result := ScanNumber(Scanner, Values[4]);
  end;

  function NextIsNumber: Boolean;
  begin
    SkipSeparator(Scanner);
    Result := (Scanner.Position <= Length(Scanner.Text)) and
      (Scanner.Text[Scanner.Position] in ['0'..'9', '+', '-', '.']);
  end;

begin
  BeginScan(Scanner, Data);
  CurrentX := 0;
  CurrentY := 0;
  StartX := 0;
  StartY := 0;
  ControlX := 0;
  ControlY := 0;
  Previous := ' ';
  Command := ' ';
  First := True;
  repeat
    SkipSpaces(Scanner);
    if Scanner.Position > Length(Scanner.Text) then
      Break;
    if Scanner.Text[Scanner.Position] in ['A'..'Z', 'a'..'z'] then
    begin
      Command := Scanner.Text[Scanner.Position];
      Inc(Scanner.Position);
    end
    else if (Command = ' ') or (Command in ['Z', 'z']) or not NextIsNumber then
      Break
    else if Command = 'M' then
      Command := 'L'
    else if Command = 'm' then
      Command := 'l';
    { The first command must be a moveto. }
    if First and not (Command in ['M', 'm']) then
      Break;
    First := False;
    Relative := Command in ['a'..'z'];
    if Relative then
    begin
      BaseX := CurrentX;
      BaseY := CurrentY;
    end
    else
    begin
      BaseX := 0;
      BaseY := 0;
    end;
    case UpCase(Command) of
      'M':
        begin
          if not ReadNumbers(2) then
            Break;
          CurrentX := BaseX + Values[0];
          CurrentY := BaseY + Values[1];
          StartX := CurrentX;
          StartY := CurrentY;
          PathMoveTo(Path, CurrentX, CurrentY);
        end;
      'L':
        begin
          if not ReadNumbers(2) then
            Break;
          CurrentX := BaseX + Values[0];
          CurrentY := BaseY + Values[1];
          PathLineTo(Path, CurrentX, CurrentY);
        end;
      'H':
        begin
          if not ReadNumbers(1) then
            Break;
          CurrentX := BaseX + Values[0];
          PathLineTo(Path, CurrentX, CurrentY);
        end;
      'V':
        begin
          if not ReadNumbers(1) then
            Break;
          CurrentY := BaseY + Values[0];
          PathLineTo(Path, CurrentX, CurrentY);
        end;
      'C':
        begin
          if not ReadNumbers(6) then
            Break;
          ControlX := BaseX + Values[2];
          ControlY := BaseY + Values[3];
          CurrentX := BaseX + Values[4];
          CurrentY := BaseY + Values[5];
          PathCubicTo(Path, BaseX + Values[0], BaseY + Values[1], ControlX, ControlY, CurrentX, CurrentY);
        end;
      'S':
        begin
          if not ReadNumbers(4) then
            Break;
          { The first control point reflects the last curve's second. }
          if UpCase(Previous) in ['C', 'S'] then
          begin
            ReflectedX := 2 * CurrentX - ControlX;
            ReflectedY := 2 * CurrentY - ControlY;
          end
          else
          begin
            ReflectedX := CurrentX;
            ReflectedY := CurrentY;
          end;
          ControlX := BaseX + Values[0];
          ControlY := BaseY + Values[1];
          CurrentX := BaseX + Values[2];
          CurrentY := BaseY + Values[3];
          PathCubicTo(Path, ReflectedX, ReflectedY, ControlX, ControlY, CurrentX, CurrentY);
        end;
      'Q':
        begin
          if not ReadNumbers(4) then
            Break;
          ControlX := BaseX + Values[0];
          ControlY := BaseY + Values[1];
          CurrentX := BaseX + Values[2];
          CurrentY := BaseY + Values[3];
          PathQuadraticTo(Path, ControlX, ControlY, CurrentX, CurrentY);
        end;
      'T':
        begin
          if not ReadNumbers(2) then
            Break;
          if UpCase(Previous) in ['Q', 'T'] then
          begin
            ControlX := 2 * CurrentX - ControlX;
            ControlY := 2 * CurrentY - ControlY;
          end
          else
          begin
            ControlX := CurrentX;
            ControlY := CurrentY;
          end;
          CurrentX := BaseX + Values[0];
          CurrentY := BaseY + Values[1];
          PathQuadraticTo(Path, ControlX, ControlY, CurrentX, CurrentY);
        end;
      'A':
        begin
          if not ReadArc then
            Break;
          PathArcTo(Path, Values[0], Values[1], Values[2], LargeArc, Sweep, BaseX + Values[3], BaseY + Values[4]);
          CurrentX := BaseX + Values[3];
          CurrentY := BaseY + Values[4];
        end;
      'Z':
        begin
          PathClose(Path);
          CurrentX := StartX;
          CurrentY := StartY;
          { A command after Z without its own moveto starts at the
            subpath's start (TPath does that). }
        end;
      else
        Break;
    end;
    Previous := Command;
  until False;
end;

procedure ParsePointsInto(const Data: string; var Path: TPath; Closed: Boolean);
var
  Numbers: TSvgNumbers;
  Index: Integer;
begin
  Numbers := ParseNumberList(Data);
  if Length(Numbers) < 2 then
    Exit;
  PathMoveTo(Path, Numbers[0], Numbers[1]);
  Index := 2;
  while Index + 1 < Length(Numbers) do
  begin
    PathLineTo(Path, Numbers[Index], Numbers[Index + 1]);
    Inc(Index, 2);
  end;
  if Closed then
    PathClose(Path);
end;

end.
