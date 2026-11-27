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
  everywhere. It is the inner step of nearly every drawing loop, so it
  is inline and takes the common cases first: an opaque or invisible
  source, then an opaque destination (a page or window backing), where
  the blend is a plain mix with no division. Only translucent over
  translucent needs the full formula, whose division by the result's
  alpha is a multiply by a reciprocal from a table.
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

function RgbColor(Red, Green, Blue: Byte): TColor; inline;
function ArgbColor(Alpha, Red, Green, Blue: Byte): TColor; inline;
function AlphaOf(Color: TColor): Byte; inline;
function RedOf(Color: TColor): Byte; inline;
function GreenOf(Color: TColor): Byte; inline;
function BlueOf(Color: TColor): Byte; inline;
{ Color with its alpha replaced. }
function WithAlpha(Color: TColor; Alpha: Byte): TColor; inline;
{ A * B / 255 rounded to nearest, for A * B up to 65535 (two channel
  values, or a channel and a weight). }
function MultiplyChannels(A, B: LongWord): LongWord; inline;
{ Color with its alpha multiplied by Opacity (0-255). }
function FadeColor(Color: TColor; Opacity: Byte): TColor; inline;

{ Source drawn over Destination. }
function BlendColors(Destination, Source: TColor): TColor; inline;
{ Source drawn over Destination when Destination is opaque (the result
  is too): each channel Source's alpha of the way to Source. }
function BlendOverOpaque(Destination, Source: TColor): TColor; inline;
{ Source drawn over Destination when neither is opaque or invisible:
  BlendColors' general case. }
function BlendTranslucentColors(Destination, Source: TColor): TColor;
{ The colour Weight/255 of the way from First to Second, every channel
  (alpha too). }
function MixColors(First, Second: TColor; Weight: Byte): TColor;

implementation

const
  { Bits of the fixed-point reciprocals in ReciprocalOfWeight. }
  ReciprocalShift = 42;

var
  { 2^ReciprocalShift / (Alpha * 255) rounded up, for every output alpha
    of BlendTranslucentColors (1 to 255; 0 unused). A numerator below
    2^25 times it, shifted down ReciprocalShift bits, is the whole
    quotient exactly: rounding up adds under numerator / 2^ReciprocalShift
    to it, less than 1 / (Alpha * 255), too little to reach the next
    whole number. }
  ReciprocalOfWeight: array[0..255] of QWord;

function ArgbColor(Alpha, Red, Green, Blue: Byte): TColor;
begin
  Result := (TColor(Alpha) shl 24) or (TColor(Red) shl 16) or (TColor(Green) shl 8) or Blue;
end;

function RgbColor(Red, Green, Blue: Byte): TColor;
begin
  Result := ArgbColor(AlphaOpaque, Red, Green, Blue);
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

{ X / 255 rounded is (X + 127) div 255; adding 128 and then that over
  256 before dividing by 256 gives the same for every X up to 65535
  with a shift instead of a division. }
function MultiplyChannels(A, B: LongWord): LongWord;
begin
  Result := A * B + 128;
  Result := (Result + (Result shr 8)) shr 8;
end;

{ MultiplyChannels written out: the compiler does not inline a call to
  it from within another inlined function in every build (position
  independent code, as userland is built). }
function FadeColor(Color: TColor; Opacity: Byte): TColor;
begin
  Result := (Color shr 24) * Opacity + 128;
  Result := (Color and $00FFFFFF) or ((((Result + (Result shr 8)) shr 8) and $FF) shl 24);
end;

{ Over an opaque pixel the result's alpha is 255 and each channel is
  (S * A + D * (255 - A)) / 255, rounded: the general formula with the
  output alpha cancelled. Red and blue are worked together in one word
  (each fits 16 bits) with MultiplyChannels' division done on both. }
function BlendOverOpaque(Destination, Source: TColor): TColor;
var
  SourceWeight: LongWord;
  DestinationWeight: LongWord;
  RedBlue: LongWord;
  Green: LongWord;
begin
  SourceWeight := Source shr 24;
  DestinationWeight := 255 - SourceWeight;
  RedBlue := (Source and $00FF00FF) * SourceWeight + (Destination and $00FF00FF) * DestinationWeight + $00800080;
  RedBlue := ((RedBlue + ((RedBlue shr 8) and $00FF00FF)) shr 8) and $00FF00FF;
  Green := ((Source shr 8) and $FF) * SourceWeight + ((Destination shr 8) and $FF) * DestinationWeight + 128;
  Green := (Green + (Green shr 8)) shr 8;
  Result := $FF000000 or RedBlue or (Green shl 8);
end;

{ Alpha is the top byte, so comparing whole colours tests it: at least
  $FF000000 is opaque, at most $00FFFFFF invisible. }
function BlendColors(Destination, Source: TColor): TColor;
begin
  if Source >= $FF000000 then
    Result := Source
  else if Source <= $00FFFFFF then
    Result := Destination
  else if Destination >= $FF000000 then
    Result := BlendOverOpaque(Destination, Source)
  else
    Result := BlendTranslucentColors(Destination, Source);
end;

function BlendTranslucentColors(Destination, Source: TColor): TColor;
var
  SourceAlpha: LongWord;
  OutputAlpha: LongWord;
  SourceWeight: LongWord;
  DestinationWeight: LongWord;
  Half: LongWord;
  Reciprocal: QWord;

  { One channel: the weighted sum of both over the result's alpha
    (times 255), rounded. }
  function BlendChannel(DestinationValue, SourceValue: LongWord): LongWord; inline;
  begin
    Result := LongWord((QWord(SourceValue * SourceWeight + DestinationValue * DestinationWeight + Half) *
      Reciprocal) shr ReciprocalShift);
    { The output alpha is rounded, so a full channel over a translucent
      one can come out a step above 255. }
    if Result > 255 then
      Result := 255;
  end;

begin
  SourceAlpha := AlphaOf(Source);
  { The source is not invisible, so neither is the result. }
  OutputAlpha := SourceAlpha + MultiplyChannels(AlphaOf(Destination), 255 - SourceAlpha);
  SourceWeight := SourceAlpha * 255;
  DestinationWeight := AlphaOf(Destination) * (255 - SourceAlpha);
  Half := OutputAlpha * 255 div 2;
  Reciprocal := ReciprocalOfWeight[OutputAlpha];
  Result := ArgbColor(OutputAlpha, BlendChannel(RedOf(Destination), RedOf(Source)),
    BlendChannel(GreenOf(Destination), GreenOf(Source)), BlendChannel(BlueOf(Destination), BlueOf(Source)));
end;

procedure MakeReciprocals;
var
  Alpha: LongWord;
  Divisor: QWord;
begin
  ReciprocalOfWeight[0] := 0;
  for Alpha := 1 to 255 do
  begin
    Divisor := Alpha * 255;
    ReciprocalOfWeight[Alpha] := (QWord(1) shl ReciprocalShift + Divisor - 1) div Divisor;
  end;
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

initialization
  MakeReciprocals;
end.
