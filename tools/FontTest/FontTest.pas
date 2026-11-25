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
  FontTest: libfont's TrueType fonts on the host, against FreeType.

    FontTest <fixtures-directory>

  The directory is what make-font-fixtures.py made: small fonts put
  together byte by byte, broken copies of them, and references.txt,
  FreeType's and HarfBuzz's answers for those and for DejaVu Sans
  (whose files the references name). Parsing and kerning are checked
  in FontTest.Parsing, rendering and hinting in FontTest.Rendering, the
  text API, the glyph cache and gamma-correct blending in FontTest.Text, CFF, collections, colour
  emoji, WOFF2 and the font configuration in FontTest.OpenType.
  Every check prints a line; the exit code is 1 if any failed.

  This is a host tool, built with the normal Free Pascal runtime library.
}
program FontTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  FontTest.Checks,
  FontTest.References,
  FontTest.Parsing,
  FontTest.Rendering,
  FontTest.Text,
  FontTest.OpenType;

var
  Directory: string;
  References: TReferences;
  Fonts: TNamedFonts;

begin
  if ParamCount <> 1 then
  begin
    WriteLn('usage: FontTest <fixtures-directory>');
    Halt(2);
  end;
  Directory := ParamStr(1);
  References := ReadReferences(IncludeTrailingPathDelimiter(Directory) + 'references.txt');
  Check('references read', Length(References) > 1000);
  Fonts := OpenReferenceFonts(Directory, References);
  TestParsing(Directory, References, Fonts);
  TestRendering(References, Fonts);
  TestText(References, Fonts);
  TestOpenType(Directory, References, Fonts);
  WriteLn(Format('[font] %d checks, %d failed', [Checks, Failures]));
  if Failures > 0 then
    Halt(1);
end.
