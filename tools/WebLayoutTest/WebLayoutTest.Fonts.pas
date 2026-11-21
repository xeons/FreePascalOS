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
  Font choice: the unicode-range descriptor read, a face restricted to
  its range, a family split into subsets drawing Latin text with the
  Latin subset, and a character the face lacks drawn with the default
  (proportional) family rather than the first face listed (the
  monospace one): www.rust-lang.org was drawn all in DejaVu Sans Mono.
}
unit WebLayoutTest.Fonts;

{$mode objfpc}
{$H+}

interface

procedure CheckFontChoice;

implementation

uses
  SysUtils, Classes, TestChecks, Font.TrueType, Web.Text.Fonts, Web.Text.UnicodeRanges;

function ReadFile(const Path: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function FamilyOf(Face: TFontFaceEntry): string;
begin
  if Face = nil then
    Result := 'none'
  else
    Result := Face.Family;
end;

procedure CheckFontChoice;
var
  Ranges: TUnicodeRangeArray;
  Library_: TFontLibrary;
  Latin, Cyrillic, Face: TFontFaceEntry;
  Data: TBytes;
begin
  Ranges := ParseUnicodeRanges('U+0000-00FF, U+0131, U+4??, bogus, U+1F600');
  Check((Length(Ranges) = 4) and RangesCover(Ranges, $41) and RangesCover(Ranges, $131) and
    RangesCover(Ranges, $4AB) and not RangesCover(Ranges, $500) and RangesCover(Ranges, $1F600) and
    not RangesCover(Ranges, $132), 'fonts: unicode-range items, a wildcard, a bad item skipped');
  Check(RangesCover(nil, $10000), 'fonts: no unicode-range covers everything');
  Library_ := WebFontLibrary;
  Face := Library_.FallbackFace(Ord('a'), 400, False);
  Check((Face <> nil) and (Face.Family = Library_.DefaultFamily),
    'fonts: a fallback character comes from the default family (' + FamilyOf(Face) + ')');
  { A web family in two subsets (made of the same file). }
  Data := ReadFile(IncludeTrailingPathDelimiter(WebFontDirectory) + 'dejavu-sans' + PathDelim + 'DejaVuSans.ttf');
  Cyrillic := TFontFaceEntry.CreateFromFont('subset test', LoadTrueTypeFont(Data), 400, False);
  Cyrillic.Ranges := ParseUnicodeRanges('U+0400-04FF');
  Library_.AddFace(Cyrillic);
  Latin := TFontFaceEntry.CreateFromFont('subset test', LoadTrueTypeFont(Data), 400, False);
  Latin.Ranges := ParseUnicodeRanges('U+0000-00FF');
  Library_.AddFace(Latin);
  Check(not Cyrillic.HasGlyph(Ord('a')) and Cyrillic.HasGlyph($416), 'fonts: a face draws only its range');
  Check(Library_.FindFace('subset test', 400, False) = Latin, 'fonts: the Latin subset leads its family');
  Check(Library_.FindFaceFor('subset test', $416, 400, False) = Cyrillic,
    'fonts: a character outside it comes from the subset that has it');
end;

end.
