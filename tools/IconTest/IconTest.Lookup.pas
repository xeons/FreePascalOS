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
  The theme's lookup (Controls.IconFiles) on the real files: the size
  in pixels for each logical size and scale, the entry used for it (the
  same size, else the nearest larger, else the largest), the picture
  made exactly that size (the file's own when it has it, resampled when
  not), kept and handed out again, and a name with no file.
}
unit IconTest.Lookup;

{$mode objfpc}
{$H+}

interface

procedure CheckThemeLookup(const IconDirectory: string);

implementation

uses
  SysUtils,
  Image.Model,
  Controls.IconFiles,
  IconTest.Checks;

type
  TScaleCase = record
    LogicalSize: LongInt;
    Scale: Double;
    PixelSize: LongInt;
    EntrySize: LongInt;
  end;

const
  { Logical size and scale: the pixel size, and the entry it comes from. }
  ScaleCases: array[0..13] of TScaleCase = (
    (LogicalSize: 16; Scale: 1.0; PixelSize: 16; EntrySize: 16),
    (LogicalSize: 16; Scale: 1.25; PixelSize: 20; EntrySize: 20),
    (LogicalSize: 16; Scale: 1.5; PixelSize: 24; EntrySize: 24),
    (LogicalSize: 16; Scale: 1.75; PixelSize: 28; EntrySize: 32),
    (LogicalSize: 16; Scale: 2.0; PixelSize: 32; EntrySize: 32),
    (LogicalSize: 16; Scale: 3.0; PixelSize: 48; EntrySize: 48),
    (LogicalSize: 32; Scale: 1.0; PixelSize: 32; EntrySize: 32),
    (LogicalSize: 32; Scale: 1.25; PixelSize: 40; EntrySize: 40),
    (LogicalSize: 32; Scale: 1.5; PixelSize: 48; EntrySize: 48),
    (LogicalSize: 32; Scale: 2.0; PixelSize: 64; EntrySize: 64),
    (LogicalSize: 32; Scale: 3.0; PixelSize: 96; EntrySize: 96),
    (LogicalSize: 32; Scale: 4.0; PixelSize: 128; EntrySize: 96),
    (LogicalSize: 16; Scale: 0.75; PixelSize: 12; EntrySize: 16),
    (LogicalSize: 48; Scale: 1.0; PixelSize: 48; EntrySize: 48));

procedure CheckThemeLookup(const IconDirectory: string);
var
  Index: LongInt;
  IconFile: TIconFile;
  Entry: LongInt;
  Picture: TImage;
  Again: TImage;
  AllRight: Boolean;
  Case_: TScaleCase;
begin
  SetIconDirectory(IconDirectory);
  CheckEqual(Length(IconFileName('folder')) - Length(IconDirectory), Length('/folder.ico'), 'an icon''s file name');
  IconFile := FindIconFile('folder');
  Check(IconFile <> nil, 'the folder icon is found');
  if IconFile = nil then
    Exit;
  CheckEqual(IconFile.EntryCount, 8, 'the folder icon has its eight sizes');
  AllRight := True;
  for Index := 0 to High(ScaleCases) do
  begin
    Case_ := ScaleCases[Index];
    if IconPixelSize(Case_.LogicalSize, Case_.Scale) <> Case_.PixelSize then
    begin
      WriteLn('     ', Case_.LogicalSize, ' at ', Case_.Scale:0:2, ': ', IconPixelSize(Case_.LogicalSize, Case_.Scale),
        ' pixels');
      AllRight := False;
      Continue;
    end;
    Entry := IconFile.EntryForSize(Case_.PixelSize);
    if (Entry < 0) or (IconFile.EntryWidth(Entry) <> Case_.EntrySize) then
    begin
      WriteLn('     ', Case_.PixelSize, ' pixels from the wrong entry');
      AllRight := False;
      Continue;
    end;
    Picture := LoadThemeIcon('folder', Case_.LogicalSize, Case_.Scale);
    if (Picture = nil) or (Picture.Width <> Case_.PixelSize) or (Picture.Height <> Case_.PixelSize) then
    begin
      WriteLn('     ', Case_.PixelSize, ' pixels: no picture of that size');
      AllRight := False;
    end;
  end;
  Check(AllRight, 'each logical size and scale: its pixel size, from the right entry, made exactly that size');
  Picture := IconPicture('folder', 28);
  Again := IconPicture('folder', 28);
  Check((Picture <> nil) and (Picture = Again), 'a picture made for a size is kept and handed out again');
  Check((Picture <> nil) and ((Picture.Line(14)[14] shr 24) = 255) and ((Picture.Line(0)[0] shr 24) = 0),
    'the resampled picture keeps its alpha (clear corner, opaque middle)');
  Check(IconPicture('folder', 32) = IconPicture('folder', 32), 'an exact size is the file''s own picture');
  Check((FindIconFile('no-such-icon') = nil) and (IconPicture('no-such-icon', 16) = nil) and
    not IconFileExists('no-such-icon'), 'a name with no file has no picture');
  Check(FindIconFile('../folder') = nil, 'a name with a slash is no icon');
  ForgetIconFiles;
  Check(LoadThemeIcon('file-text', 16, 1.0) <> nil, 'read again after being forgotten');
end;

end.
