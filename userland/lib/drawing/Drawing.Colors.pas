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
  Colours: a LongWord $AARRGGBB, alpha 255 opaque and 0 transparent, not
  premultiplied. In memory that is blue, green, red, alpha: the order of
  most framebuffers, so an opaque colour is also the display's pixel.

  BlendColors puts a colour over another the usual way ("source over"),
  in integers, rounding to nearest, so results are exact and the same
  everywhere.
}
unit Drawing.Colors;

{$mode objfpc}

interface

type
  TColor = LongWord;

const
  ColorTransparent: TColor = $00000000;
  ColorBlack: TColor = $FF000000;
  ColorWhite: TColor = $FFFFFFFF;
  AlphaOpaque = 255;

function RgbColor(Red, Green, Blue: Byte): TColor;
function ArgbColor(Alpha, Red, Green, Blue: Byte): TColor;
function AlphaOf(Color: TColor): Byte;
function RedOf(Color: TColor): Byte;
function GreenOf(Color: TColor): Byte;
function BlueOf(Color: TColor): Byte;
{ Color with its alpha replaced. }
function WithAlpha(Color: TColor; Alpha: Byte): TColor;
{ Color with its alpha multiplied by Opacity (0-255). }
function FadeColor(Color: TColor; Opacity: Byte): TColor;

{ Source drawn over Destination. }
function BlendColors(Destination, Source: TColor): TColor;
{ The colour Weight/255 of the way from First to Second, every channel
  (alpha too). }
function MixColors(First, Second: TColor; Weight: Byte): TColor;

implementation

function RgbColor(Red, Green, Blue: Byte): TColor;
begin
  Result := ArgbColor(AlphaOpaque, Red, Green, Blue);
end;

function ArgbColor(Alpha, Red, Green, Blue: Byte): TColor;
begin
  Result := (TColor(Alpha) shl 24) or (TColor(Red) shl 16) or (TColor(Green) shl 8) or Blue;
end;

function AlphaOf(Color: TColor): Byte;
begin
  Result := Byte(Color shr 24);
end;

function RedOf(Color: TColor): Byte;
begin
  Result := Byte(Color shr 16);
end;

function GreenOf(Color: TColor): Byte;
begin
  Result := Byte(Color shr 8);
end;

function BlueOf(Color: TColor): Byte;
begin
  Result := Byte(Color);
end;

function WithAlpha(Color: TColor; Alpha: Byte): TColor;
begin
  Result := (Color and $00FFFFFF) or (TColor(Alpha) shl 24);
end;

{ A * B / 255, rounded to nearest. }
function MultiplyChannels(A, B: LongWord): LongWord;
begin
  Result := (A * B + 127) div 255;
end;

function FadeColor(Color: TColor; Opacity: Byte): TColor;
begin
  Result := WithAlpha(Color, Byte(MultiplyChannels(AlphaOf(Color), Opacity)));
end;

function BlendColors(Destination, Source: TColor): TColor;
var
  SourceAlpha: LongWord;
  DestinationAlpha: LongWord;
  OutputAlpha: LongWord;

  { One channel: the weighted sum of both over the result's alpha. }
  function BlendChannel(DestinationValue, SourceValue: LongWord): LongWord;
  var
    Weighted: LongWord;
  begin
    Weighted := SourceValue * SourceAlpha * 255 + DestinationValue * DestinationAlpha * (255 - SourceAlpha);
    Result := (Weighted + OutputAlpha * 255 div 2) div (OutputAlpha * 255);
  end;

begin
  SourceAlpha := AlphaOf(Source);
  if SourceAlpha = AlphaOpaque then
    Exit(Source);
  if SourceAlpha = 0 then
    Exit(Destination);
  DestinationAlpha := AlphaOf(Destination);
  OutputAlpha := SourceAlpha + MultiplyChannels(DestinationAlpha, 255 - SourceAlpha);
  if OutputAlpha = 0 then
    Exit(ColorTransparent);
  Result := ArgbColor(OutputAlpha, BlendChannel(RedOf(Destination), RedOf(Source)),
    BlendChannel(GreenOf(Destination), GreenOf(Source)), BlendChannel(BlueOf(Destination), BlueOf(Source)));
end;

function MixColors(First, Second: TColor; Weight: Byte): TColor;

  function MixChannel(FirstValue, SecondValue: LongWord): Byte;
  begin
    Result := Byte((FirstValue * (255 - Weight) + SecondValue * Weight + 127) div 255);
  end;

begin
  Result := ArgbColor(MixChannel(AlphaOf(First), AlphaOf(Second)), MixChannel(RedOf(First), RedOf(Second)),
    MixChannel(GreenOf(First), GreenOf(Second)), MixChannel(BlueOf(First), BlueOf(Second)));
end;

end.
