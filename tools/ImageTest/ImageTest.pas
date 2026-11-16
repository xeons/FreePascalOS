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
  ImageTest: libimage on the host.

    ImageTest <fixture-directory> [<written-directory>]

  The fixtures are made at build time by make-fixtures.py (BMP, DIB,
  ICO, CUR, GIF), make-jpeg-fixtures.py (JPEG), make-png-fixtures.py
  (PNG, APNG) and make-tiff-fixtures.py (TIFF), with Pillow; their
  references are Pillow's decoding or the pixels the files were made
  from. Every check prints a line; the exit code is 1 if any failed.
  Files the encoders write go into the written directory, each with its
  pixels beside it, for check-with-pillow.py.

  This is a host tool, built with the normal Free Pascal runtime library
  (and range checks, so a decoder reading outside its data is caught).
}
program ImageTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  ImageTest.Checks,
  ImageTest.Model,
  ImageTest.Bmp,
  ImageTest.Ico,
  ImageTest.Gif,
  ImageTest.Jpeg,
  ImageTest.Png,
  ImageTest.Apng,
  ImageTest.PngWriting,
  ImageTest.Tiff,
  ImageTest.Robustness;

begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: ImageTest <fixture-directory> [<written-directory>]');
    Halt(2);
  end;
  FixtureDirectory := ParamStr(1);
  if ParamCount >= 2 then
    WrittenDirectory := ParamStr(2);
  TestModel;
  TestBmp;
  TestIco;
  TestGif;
  TestJpeg;
  TestPng;
  TestApng;
  TestPngWriting;
  TestTiff;
  TestRobustness;
  FinishChecks('ImageTest');
end.
