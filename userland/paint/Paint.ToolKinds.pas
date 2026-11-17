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
  The tools, their names (with the mnemonic the Tools menu uses), what
  each does in a hint, the word the program prints for it, and which of
  the tool box's options each takes: a size (a brush's, a line's
  width), how a shape is filled, the fill's tolerance, a font.
}
unit Paint.ToolKinds;

{$mode objfpc}
{$H+}

interface

type
  TToolKind = (
    ToolSelect,
    ToolFreeFormSelect,
    ToolEraser,
    ToolFill,
    ToolPicker,
    ToolPencil,
    ToolBrush,
    ToolAirbrush,
    ToolText,
    ToolLine,
    ToolCurve,
    ToolRectangle,
    ToolPolygon,
    ToolEllipse,
    ToolRoundedRectangle
  );

  TToolOption = (OptionSize, OptionFillStyle, OptionTolerance, OptionFont);
  TToolOptionSet = set of TToolOption;

const
  ToolCaptions: array[TToolKind] of string = ('&Select', 'Free-for&m select', '&Eraser', '&Fill with colour',
    'Colour p&icker', 'Pe&ncil', '&Brush', '&Airbrush', '&Text', '&Line', '&Curve', '&Rectangle', 'Pol&ygon',
    'Elli&pse', 'R&ounded rectangle');
  ToolHints: array[TToolKind] of string = (
    'Select a rectangle: drag; drag the selection to move it (Ctrl copies)',
    'Select any shape: drag round it',
    'Eraser: paints the secondary colour',
    'Fill an area of like colour',
    'Pick a colour from the picture',
    'Pencil: one pixel wide',
    'Brush: round and smooth',
    'Airbrush: sprays dots',
    'Text: click where it goes',
    'Line (Shift: at 45 degrees)',
    'Curve: drag a line, then drag to bend it twice',
    'Rectangle (Shift: a square)',
    'Polygon: click each corner; Enter or a click on the first ends it',
    'Ellipse (Shift: a circle)',
    'Rounded rectangle (Shift: a square)');
  { What the program prints ("tool rectangle"). }
  ToolWords: array[TToolKind] of string = ('select', 'free-form-select', 'eraser', 'fill', 'picker', 'pencil',
    'brush', 'airbrush', 'text', 'line', 'curve', 'rectangle', 'polygon', 'ellipse', 'rounded-rectangle');

function ToolOptions(Kind: TToolKind): TToolOptionSet;
{ The tool printed as Word; False if none is. }
function ToolFromWord(const Word: string; out Kind: TToolKind): Boolean;

implementation

function ToolOptions(Kind: TToolKind): TToolOptionSet;
begin
  case Kind of
    ToolEraser, ToolBrush, ToolAirbrush, ToolLine, ToolCurve: Result := [OptionSize];
    ToolRectangle, ToolPolygon, ToolEllipse, ToolRoundedRectangle: Result := [OptionSize, OptionFillStyle];
    ToolFill: Result := [OptionTolerance];
    ToolText: Result := [OptionFont];
  else
    Result := [];
  end;
end;

function ToolFromWord(const Word: string; out Kind: TToolKind): Boolean;
var
  Candidate: TToolKind;
begin
  for Candidate := Low(TToolKind) to High(TToolKind) do
    if ToolWords[Candidate] = Word then
    begin
      Kind := Candidate;
      Exit(True);
    end;
  Kind := ToolPencil;
  Result := False;
end;

end.
