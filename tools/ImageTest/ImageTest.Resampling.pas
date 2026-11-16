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
  Resampling (Image.Resampling): Lanczos-3, bilinear and box against
  Pillow's resize of the same picture, shrunk and enlarged (within 2;
  Pillow rounds to 8 bits between its passes); every filter keeps a
  flat colour flat; transparent pixels lend no colour (premultiplied
  alpha); the Mitchell kernel's known values and its sum of 1; sizes.
}
unit ImageTest.Resampling;

{$mode objfpc}
{$H+}

interface

procedure TestResampling;

implementation

uses
  SysUtils,
  Image.Model,
  Image.Files,
  Image.Scaling,
  Image.Resampling,
  ImageTest.Checks;

const
  FilterNames: array[TResamplingFilter] of string = ('box', 'triangle', 'Mitchell', 'Lanczos-3');

procedure CheckAgainstPillow(const SourceName, ReferenceName: string; Width, Height: LongInt;
  Filter: TResamplingFilter);
var
  Source: TImage;
  Scaled: TImage;
begin
  Source := nil;
  Scaled := nil;
  try
    try
      Source := LoadImage(FixtureBytes(SourceName));
      Scaled := ResampleImage(Source, Width, Height, Filter);
    except
      on Error: Exception do
        Note(ReferenceName + ': ' + Error.Message);
    end;
    CheckImageMatchesReference('resampled ' + ReferenceName, Scaled, ReferenceName + '.rgba', 2, 0.3);
  finally
    Scaled.Free;
    Source.Free;
  end;
end;

function IsFlat(Image: TImage; Color: LongWord): Boolean;
var
  X: LongInt;
  Y: LongInt;
begin
  for Y := 0 to Image.Height - 1 do
    for X := 0 to Image.Width - 1 do
      if Image.GetPixel(X, Y) <> Color then
        Exit(False);
  Result := True;
end;

procedure TestFlatColor;
var
  Flat: TImage;
  Scaled: TImage;
  Filter: TResamplingFilter;
  Flatness: Boolean;
begin
  Flat := TImage.Create(37, 23);
  try
    Flat.Fill($C0336699);
    for Filter := Low(TResamplingFilter) to High(TResamplingFilter) do
    begin
      Scaled := ResampleImage(Flat, 11, 7, Filter);
      Flatness := IsFlat(Scaled, $C0336699);
      Scaled.Free;
      Scaled := ResampleImage(Flat, 80, 51, Filter);
      Flatness := Flatness and IsFlat(Scaled, $C0336699);
      Scaled.Free;
      Check(Flatness, 'resampling keeps a flat colour flat: ' + FilterNames[Filter]);
    end;
  finally
    Flat.Free;
  end;
end;

{ Opaque red beside transparent black: whatever is not transparent
  after resampling is still pure red. }
procedure TestNoFringes;
var
  Source: TImage;
  Scaled: TImage;
  Filter: TResamplingFilter;
  X: LongInt;
  Y: LongInt;
  Pixel: LongWord;
  Clean: Boolean;
  SeenTranslucent: Boolean;
begin
  Source := TImage.Create(40, 10);
  try
    for Y := 0 to 9 do
      for X := 0 to 39 do
        if X < 17 then
          Source.SetPixel(X, Y, $FFFF0000)
        else
          Source.SetPixel(X, Y, $00000000);
    for Filter := Low(TResamplingFilter) to High(TResamplingFilter) do
    begin
      Scaled := ResampleImage(Source, 13, 4, Filter);
      Clean := True;
      SeenTranslucent := False;
      for Y := 0 to Scaled.Height - 1 do
        for X := 0 to Scaled.Width - 1 do
        begin
          Pixel := Scaled.GetPixel(X, Y);
          if (Pixel shr 24) = 0 then
            Continue;
          if (Pixel shr 24) < 255 then
            SeenTranslucent := True;
          if ((Pixel shr 16) and $FF < 254) or ((Pixel shr 8) and $FF > 1) or (Pixel and $FF > 1) then
            Clean := False;
        end;
      Scaled.Free;
      Check(Clean and (SeenTranslucent or (Filter = ResamplingBox)),
        'resampling with premultiplied alpha leaves no dark fringe: ' + FilterNames[Filter]);
    end;
  finally
    Source.Free;
  end;
end;

procedure TestKernels;
var
  Offset: Double;
  Sum: Double;
  Tap: LongInt;
  Worst: Double;
begin
  Check(Abs(ResamplingKernel(ResamplingMitchell, 0) - 8 / 9) < 1e-9, 'Mitchell kernel at 0 is 8/9');
  Check(Abs(ResamplingKernel(ResamplingMitchell, 1) - 1 / 18) < 1e-9, 'Mitchell kernel at 1 is 1/18');
  Check(ResamplingKernel(ResamplingMitchell, 2) = 0, 'Mitchell kernel ends at 2');
  Check((Abs(ResamplingKernel(ResamplingLanczos3, 0) - 1) < 1e-9) and (Abs(ResamplingKernel(ResamplingLanczos3, 1)) <
    1e-9) and (ResamplingKernel(ResamplingLanczos3, 3) = 0), 'Lanczos-3 kernel: 1 at 0, 0 at 1, ends at 3');
  Worst := 0;
  Offset := 0;
  while Offset < 1 do
  begin
    Sum := 0;
    for Tap := -3 to 3 do
      Sum := Sum + ResamplingKernel(ResamplingMitchell, Offset + Tap);
    if Abs(Sum - 1) > Worst then
      Worst := Abs(Sum - 1);
    Offset := Offset + 0.05;
  end;
  Check(Worst < 1e-9, 'Mitchell kernel sums to 1 at every offset');
end;

procedure TestSizes;
var
  Source: TImage;
  Scaled: TImage;
begin
  Source := TImage.Create(400, 300);
  try
    Scaled := ThumbnailImage(Source, 100, 100, ResamplingLanczos3);
    try
      Check((Scaled.Width = 100) and (Scaled.Height = 75), 'filtered thumbnail size');
    finally
      Scaled.Free;
    end;
    Scaled := ScaleImage(Source, 1, 1, ResamplingMitchell);
    try
      Check((Scaled.Width = 1) and (Scaled.Height = 1), 'resampled to one pixel');
    finally
      Scaled.Free;
    end;
  finally
    Source.Free;
  end;
end;

procedure TestResampling;
begin
  CheckAgainstPillow('resample-source.png', 'resample-lanczos-down', 40, 25, ResamplingLanczos3);
  CheckAgainstPillow('resample-small.png', 'resample-lanczos-up', 70, 50, ResamplingLanczos3);
  CheckAgainstPillow('resample-source.png', 'resample-bilinear-down', 45, 30, ResamplingTriangle);
  CheckAgainstPillow('resample-source.png', 'resample-box-down', 32, 20, ResamplingBox);
  TestFlatColor;
  TestNoFringes;
  TestKernels;
  TestSizes;
end;

end.
