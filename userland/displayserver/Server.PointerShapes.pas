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
  The pointer's shapes (Pointer* in Windowing.Protocol): small patterns
  of black, white and clear pixels, with a hotspot, the pixel that is
  where the pointer points.

  The shapes built in here are the ones the system disk's files in
  /lib/pointers start as (Server.PointerFiles reads those over them),
  so the pointer has every shape even without the files.
}
unit Server.PointerShapes;

{$mode objfpc}

interface

uses
  Windowing.Protocol;

const
  MaximumPointerSize = 32;
  { A pattern's pixels. }
  PointerBlack = '#';
  PointerWhite = '.';

type
  TPointerRow = string[MaximumPointerSize];
  TPointerPattern = record
    Width: LongInt;
    Height: LongInt;
    HotspotX: LongInt;
    HotspotY: LongInt;
    { Height rows of Width characters: PointerBlack, PointerWhite, or
      anything else for clear. }
    Rows: array[0..MaximumPointerSize - 1] of TPointerRow;
  end;

var
  PointerPatterns: array[0..PointerShapeCount - 1] of TPointerPattern;

{ Puts the built-in shapes in PointerPatterns. }
procedure UseBuiltInPointers;
{ Makes a pattern of Rows (cut to the maximum size); False if it is empty
  or the hotspot is outside it. }
function MakePointerPattern(const Rows: array of TPointerRow; HotspotX, HotspotY: LongInt;
  out Pattern: TPointerPattern): Boolean;

implementation

const
  Arrow: array[0..18] of TPointerRow = (
    '#           ',
    '##          ',
    '#.#         ',
    '#..#        ',
    '#...#       ',
    '#....#      ',
    '#.....#     ',
    '#......#    ',
    '#.......#   ',
    '#........#  ',
    '#.........# ',
    '#......#####',
    '#...#..#    ',
    '#..# #..#   ',
    '#.#  #..#   ',
    '##    #..#  ',
    '#     #..#  ',
    '       #..# ',
    '        ##  ');
  ResizeHorizontal: array[0..8] of TPointerRow = (
    '    #       #    ',
    '   ##       ##   ',
    '  #.#########.#  ',
    ' #.............# ',
    '#...............#',
    ' #.............# ',
    '  #.#########.#  ',
    '   ##       ##   ',
    '    #       #    ');
  ResizeVertical: array[0..16] of TPointerRow = (
    '    #    ',
    '   #.#   ',
    '  #...#  ',
    ' #.....# ',
    '###...###',
    '  #...#  ',
    '  #...#  ',
    '  #...#  ',
    '  #...#  ',
    '  #...#  ',
    '  #...#  ',
    '  #...#  ',
    '###...###',
    ' #.....# ',
    '  #...#  ',
    '   #.#   ',
    '    #    ');
  ResizeDiagonalDown: array[0..16] of TPointerRow = (
    '#######          ',
    '#.....#          ',
    '#....#           ',
    '#....#           ',
    '#.....#          ',
    '#..#...#         ',
    '#.# #...#        ',
    '##   #...#       ',
    '      #...#      ',
    '       #...#   ##',
    '        #...# #.#',
    '         #...#..#',
    '          #.....#',
    '           #....#',
    '           #....#',
    '          #.....#',
    '          #######');
  ResizeDiagonalUp: array[0..16] of TPointerRow = (
    '          #######',
    '          #.....#',
    '           #....#',
    '           #....#',
    '          #.....#',
    '         #...#..#',
    '        #...# #.#',
    '       #...#   ##',
    '      #...#      ',
    '##   #...#       ',
    '#.# #...#        ',
    '#..#...#         ',
    '#.....#          ',
    '#....#           ',
    '#....#           ',
    '#.....#          ',
    '#######          ');
  TextBeam: array[0..15] of TPointerRow = (
    ' ... ... ',
    '.###.###.',
    ' ...#... ',
    '   .#.   ',
    '   .#.   ',
    '   .#.   ',
    '   .#.   ',
    '   .#.   ',
    '   .#.   ',
    '   .#.   ',
    '   .#.   ',
    '   .#.   ',
    '   .#.   ',
    ' ...#... ',
    '.###.###.',
    ' ... ... ');
  Busy: array[0..11] of TPointerRow = (
    '###########',
    ' #.......# ',
    ' #.......# ',
    '  #.....#  ',
    '   #...#   ',
    '    #.#    ',
    '    #.#    ',
    '   #...#   ',
    '  #.....#  ',
    ' #...#...# ',
    ' #..###..# ',
    '###########');

function MakePointerPattern(const Rows: array of TPointerRow; HotspotX, HotspotY: LongInt;
  out Pattern: TPointerPattern): Boolean;
var
  Index: LongInt;
begin
  Pattern.Width := 0;
  Pattern.Height := 0;
  for Index := 0 to High(Rows) do
  begin
    if Index = MaximumPointerSize then
      Break;
    Pattern.Rows[Index] := Rows[Index];
    if Length(Rows[Index]) > Pattern.Width then
      Pattern.Width := Length(Rows[Index]);
    Inc(Pattern.Height);
  end;
  Pattern.HotspotX := HotspotX;
  Pattern.HotspotY := HotspotY;
  Result := (Pattern.Width > 0) and (HotspotX >= 0) and (HotspotX < Pattern.Width) and (HotspotY >= 0) and
    (HotspotY < Pattern.Height);
end;

procedure UseBuiltInPointers;
begin
  MakePointerPattern(Arrow, 0, 0, PointerPatterns[PointerArrow]);
  MakePointerPattern(ResizeHorizontal, 8, 4, PointerPatterns[PointerResizeHorizontal]);
  MakePointerPattern(ResizeVertical, 4, 8, PointerPatterns[PointerResizeVertical]);
  MakePointerPattern(ResizeDiagonalDown, 8, 8, PointerPatterns[PointerResizeDiagonalDown]);
  MakePointerPattern(ResizeDiagonalUp, 8, 8, PointerPatterns[PointerResizeDiagonalUp]);
  MakePointerPattern(TextBeam, 4, 8, PointerPatterns[PointerTextBeam]);
  MakePointerPattern(Busy, 5, 6, PointerPatterns[PointerBusy]);
end;

initialization
  UseBuiltInPointers;
end.
