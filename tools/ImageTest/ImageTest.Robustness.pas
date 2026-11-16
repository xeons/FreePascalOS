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
  Damaged BMP, ICO, CUR, GIF, PNG and APNG files: every good fixture
  cut at many lengths and with bytes changed at random (the same each
  run). Each must load or be refused with EImageError; anything else (an access
  violation, a range error with range checks on) fails. One check per
  fixture, so a failure names the file and the damage.
}
unit ImageTest.Robustness;

{$mode objfpc}
{$H+}

interface

procedure TestRobustness;

implementation

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.Files,
  ImageTest.Checks;

const
  Fixtures: array[0..26] of string = (
    'bmp1.bmp', 'bmp4.bmp', 'bmp8-core.bmp', 'bmp16-565.bmp', 'bmp24.bmp', 'bmp32-v5.bmp',
    'bmp32-alphabitfields.bmp', 'bmp-rle8.bmp', 'bmp-rle4.bmp', 'bmp32-profile.bmp', 'dib4.dib',
    'icon-multi.ico', 'pointer.cur', 'icon-png-mixed.ico', 'icon-png-only.ico', 'anim.gif', 'noise.gif',
    'png-c0-d1-i.png', 'png-c3-d4.png', 'png-c6-d16-i.png', 'png-c2-d8.png', 'png-trns-rgb16.png',
    'png-metadata.png', 'png-idat-bytes.png', 'apng-default-frame.png', 'apng-default-separate.png',
    'apng-palette.png');
  CutsPerFile = 24;
  DamagesPerFile = 40;

var
  RandomState: LongWord = 12345;

function NextRandom(Limit: LongWord): LongWord;
begin
  RandomState := RandomState * 1103515245 + 12345;
  Result := (RandomState shr 8) mod Limit;
end;

{ An empty string when Data loads or is refused properly; what went
  wrong otherwise. }
function TryDamaged(const Data: TBytes): string;
var
  Image: TImage;
begin
  Result := '';
  Image := nil;
  try
    Image := LoadImage(Data);
  except
    on EImageError do
      ;
    on Error: Exception do
      Result := Error.ClassName + ': ' + Error.Message;
  end;
  Image.Free;
end;

procedure TestFixture(const Name: string);
var
  Good: TBytes;
  Damaged: TBytes;
  Index: LongInt;
  Changes: LongInt;
  Change: LongInt;
  Problem: string;
  Description: string;
begin
  Good := FixtureBytes(Name);
  Problem := '';
  Description := '';
  for Index := 1 to CutsPerFile do
  begin
    if Problem <> '' then
      Break;
    Damaged := Copy(Good, 0, (Int64(Length(Good)) * Index) div (CutsPerFile + 1));
    Problem := TryDamaged(Damaged);
    Description := 'cut at ' + IntToStr(Length(Damaged));
  end;
  for Index := 1 to DamagesPerFile do
  begin
    if Problem <> '' then
      Break;
    Damaged := Copy(Good);
    Changes := 1 + NextRandom(8);
    for Change := 1 to Changes do
      Damaged[NextRandom(Length(Damaged))] := NextRandom(256);
    Problem := TryDamaged(Damaged);
    Description := 'damage ' + IntToStr(Index);
  end;
  Check(Problem = '', 'damaged ' + Name + ' loads or is refused');
  if Problem <> '' then
    Note(Description + ': ' + Problem);
end;

procedure TestRobustness;
var
  Index: LongInt;
begin
  for Index := Low(Fixtures) to High(Fixtures) do
    TestFixture(Fixtures[Index]);
end;

end.
