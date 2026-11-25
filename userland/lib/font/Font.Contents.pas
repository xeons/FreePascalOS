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
  The contents of libfont.so.

  Compiling this unit compiles every unit of the library; programs use
  the individual units. Everything but Font.Files (which reads files
  through libsystem) builds and is tested on the host as well
  (tools/DrawingTest).
}
unit Font.Contents;

{$mode objfpc}

interface

uses
  Font.Faces,
  Font.Psf,
  Font.Coverage,
  Font.FontData,
  Font.Outlines,
  Font.CharacterMaps,
  Font.GlyphData,
  Font.Kerning,
  Font.TrueType,
  Font.CffData,
  Font.CffCharStrings,
  Font.CffOutlines,
  Font.ColorBitmaps,
  Font.Summaries,
  Font.Configuration,
  Font.GlyphDrawing,
  Font.Hinting,
  Font.GlyphRendering,
  Font.GlyphCache,
  Font.OutlineFaces,
  Font.Utf8,
  Font.Text,
  Font.Files;

implementation

end.
