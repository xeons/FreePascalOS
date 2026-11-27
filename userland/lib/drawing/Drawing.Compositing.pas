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
  Compositing one colour onto another by any of the Porter-Duff
  operators and the blend modes of Compositing and Blending Level 1
  (the set canvas's globalCompositeOperation and CSS's mix-blend-mode
  name). Colours come and go not premultiplied ($AARRGGBB); the work is
  done premultiplied, in floating point for everything but plain
  source-over, which has an integer path.

  The operators: Fa and Fb weigh source and destination,
  co = cs * Fa + cb * Fb, ao = as * Fa + ab * Fb (premultiplied). The
  blend modes are source-over with the blended colour where both are
  present: co = cs (1 - ab) + cb (1 - as) + as ab B(Cb, Cs),
  ao = as + ab - as ab.
}
unit Drawing.Compositing;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors;

type
  TCompositeOperation = (
    CompositeSourceOver, CompositeSourceIn, CompositeSourceOut, CompositeSourceAtop,
    CompositeDestinationOver, CompositeDestinationIn, CompositeDestinationOut, CompositeDestinationAtop,
    CompositeLighter, CompositeCopy, CompositeXor,
    CompositeMultiply, CompositeScreen, CompositeOverlay, CompositeDarken, CompositeLighten,
    CompositeColorDodge, CompositeColorBurn, CompositeHardLight, CompositeSoftLight, CompositeDifference,
    CompositeExclusion, CompositeHue, CompositeSaturation, CompositeColor, CompositeLuminosity
  );

  { A colour premultiplied by its alpha, channels 0 to 1. }
  TPremultipliedColor = record
    Red, Green, Blue, Alpha: Single;
  end;

const
  { The operations' names as canvas and CSS write them. }
  CompositeOperationNames: array[TCompositeOperation] of string = (
    'source-over', 'source-in', 'source-out', 'source-atop',
    'destination-over', 'destination-in', 'destination-out', 'destination-atop',
    'lighter', 'copy', 'xor',
    'multiply', 'screen', 'overlay', 'darken', 'lighten',
    'color-dodge', 'color-burn', 'hard-light', 'soft-light', 'difference',
    'exclusion', 'hue', 'saturation', 'color', 'luminosity');

{ The operation named Name; False when there is none. }
function CompositeOperationFromName(const Name: string; out Operation: TCompositeOperation): Boolean;
{ Operations that change the destination where the source is
  transparent (copy, source-in, source-out, destination-in,
  destination-atop): a shape drawn with them affects everything. }
function CompositeOperationIsUnbounded(Operation: TCompositeOperation): Boolean;

function PremultiplyColor(Color: TColor): TPremultipliedColor;
function UnpremultiplyColor(const Value: TPremultipliedColor): TColor;

{ Source composited onto Destination by Operation. }
function CompositeColors(Destination, Source: TColor; Operation: TCompositeOperation): TColor;
{ Count pixels of Source composited onto Destination, each result
  then mixed with what the destination was by Weights[i]/255 (a clip's
  coverage; Weights nil: all 255). }
procedure CompositeSpan(Destination, Source: PLongWord; Weights: PByte; Count: LongInt;
  Operation: TCompositeOperation);

implementation

uses
  Math,
  Drawing.SpanBlending;

function CompositeOperationFromName(const Name: string; out Operation: TCompositeOperation): Boolean;
var
  Candidate: TCompositeOperation;
begin
  for Candidate := Low(TCompositeOperation) to High(TCompositeOperation) do
    if CompositeOperationNames[Candidate] = Name then
    begin
      Operation := Candidate;
      Exit(True);
    end;
  Operation := CompositeSourceOver;
  Result := False;
end;

function CompositeOperationIsUnbounded(Operation: TCompositeOperation): Boolean;
begin
  Result := Operation in [CompositeCopy, CompositeSourceIn, CompositeSourceOut, CompositeDestinationIn,
    CompositeDestinationAtop];
end;

function PremultiplyColor(Color: TColor): TPremultipliedColor;
var
  Alpha: Single;
begin
  Alpha := AlphaOf(Color) / 255;
  Result.Alpha := Alpha;
  Result.Red := RedOf(Color) / 255 * Alpha;
  Result.Green := GreenOf(Color) / 255 * Alpha;
  Result.Blue := BlueOf(Color) / 255 * Alpha;
end;

function ChannelByte(Value: Single): Byte; inline;
begin
  if Value <= 0 then
    Exit(0);
  if Value >= 1 then
    Exit(255);
  Result := Round(Value * 255);
end;

function UnpremultiplyColor(const Value: TPremultipliedColor): TColor;
var
  Alpha: Single;
begin
  Alpha := Value.Alpha;
  if Alpha <= 0.5 / 255 then
    Exit(ColorTransparent);
  if Alpha > 1 then
    Alpha := 1;
  Result := ArgbColor(ChannelByte(Alpha), ChannelByte(Value.Red / Alpha), ChannelByte(Value.Green / Alpha),
    ChannelByte(Value.Blue / Alpha));
end;

{ Separable blend functions of non-premultiplied channels: Backdrop is
  the destination, Source the source. }

function BlendHardLight(Backdrop, Source: Single): Single;
begin
  if Source <= 0.5 then
    Result := Backdrop * 2 * Source
  else
  begin
    Source := 2 * Source - 1;
    Result := Backdrop + Source - Backdrop * Source;
  end;
end;

function BlendSoftLight(Backdrop, Source: Single): Single;
var
  D: Single;
begin
  if Source <= 0.5 then
    Result := Backdrop - (1 - 2 * Source) * Backdrop * (1 - Backdrop)
  else
  begin
    if Backdrop <= 0.25 then
      D := ((16 * Backdrop - 12) * Backdrop + 4) * Backdrop
    else
      D := Sqrt(Backdrop);
    Result := Backdrop + (2 * Source - 1) * (D - Backdrop);
  end;
end;

function BlendChannel(Backdrop, Source: Single; Operation: TCompositeOperation): Single;
begin
  case Operation of
    CompositeMultiply:
      Result := Backdrop * Source;
    CompositeScreen:
      Result := Backdrop + Source - Backdrop * Source;
    CompositeOverlay:
      Result := BlendHardLight(Source, Backdrop);
    CompositeDarken:
      Result := Min(Backdrop, Source);
    CompositeLighten:
      Result := Max(Backdrop, Source);
    CompositeColorDodge:
      if Backdrop <= 0 then
        Result := 0
      else if Source >= 1 then
        Result := 1
      else
        Result := Min(1, Backdrop / (1 - Source));
    CompositeColorBurn:
      if Backdrop >= 1 then
        Result := 1
      else if Source <= 0 then
        Result := 0
      else
        Result := 1 - Min(1, (1 - Backdrop) / Source);
    CompositeHardLight:
      Result := BlendHardLight(Backdrop, Source);
    CompositeSoftLight:
      Result := BlendSoftLight(Backdrop, Source);
    CompositeDifference:
      Result := Abs(Backdrop - Source);
    CompositeExclusion:
      Result := Backdrop + Source - 2 * Backdrop * Source;
  else
    Result := Source;
  end;
end;

{ The non-separable blend modes' helpers (Compositing and Blending
  Level 1, 10.2). }

type
  TRgb = record
    Red, Green, Blue: Single;
  end;

function Luminosity(const C: TRgb): Single;
begin
  Result := 0.3 * C.Red + 0.59 * C.Green + 0.11 * C.Blue;
end;

function ClipColor(const C: TRgb): TRgb;
var
  L, N, X: Single;
begin
  Result := C;
  L := Luminosity(C);
  N := Min(C.Red, Min(C.Green, C.Blue));
  X := Max(C.Red, Max(C.Green, C.Blue));
  if (N < 0) and (L - N > 0) then
  begin
    Result.Red := L + (Result.Red - L) * L / (L - N);
    Result.Green := L + (Result.Green - L) * L / (L - N);
    Result.Blue := L + (Result.Blue - L) * L / (L - N);
  end;
  if (X > 1) and (X - L > 0) then
  begin
    Result.Red := L + (Result.Red - L) * (1 - L) / (X - L);
    Result.Green := L + (Result.Green - L) * (1 - L) / (X - L);
    Result.Blue := L + (Result.Blue - L) * (1 - L) / (X - L);
  end;
end;

function SetLuminosity(const C: TRgb; L: Single): TRgb;
var
  D: Single;
begin
  D := L - Luminosity(C);
  Result.Red := C.Red + D;
  Result.Green := C.Green + D;
  Result.Blue := C.Blue + D;
  Result := ClipColor(Result);
end;

function Saturation(const C: TRgb): Single;
begin
  Result := Max(C.Red, Max(C.Green, C.Blue)) - Min(C.Red, Min(C.Green, C.Blue));
end;

procedure SwapIndexes(var First, Second: Integer);
var
  Kept: Integer;
begin
  Kept := First;
  First := Second;
  Second := Kept;
end;

function SetSaturation(const C: TRgb; S: Single): TRgb;
var
  Values: array[0..2] of Single;
  Order: array[0..2] of Integer;
  Highest, Middle, Lowest: Integer;
begin
  Values[0] := C.Red;
  Values[1] := C.Green;
  Values[2] := C.Blue;
  Order[0] := 0;
  Order[1] := 1;
  Order[2] := 2;
  { The indexes by value, smallest first. }
  if Values[Order[0]] > Values[Order[1]] then
    SwapIndexes(Order[0], Order[1]);
  if Values[Order[1]] > Values[Order[2]] then
    SwapIndexes(Order[1], Order[2]);
  if Values[Order[0]] > Values[Order[1]] then
    SwapIndexes(Order[0], Order[1]);
  Lowest := Order[0];
  Middle := Order[1];
  Highest := Order[2];
  if Values[Highest] > Values[Lowest] then
  begin
    Values[Middle] := (Values[Middle] - Values[Lowest]) * S / (Values[Highest] - Values[Lowest]);
    Values[Highest] := S;
  end
  else
  begin
    Values[Middle] := 0;
    Values[Highest] := 0;
  end;
  Values[Lowest] := 0;
  Result.Red := Values[0];
  Result.Green := Values[1];
  Result.Blue := Values[2];
end;

function BlendNonSeparable(const Backdrop, Source: TRgb; Operation: TCompositeOperation): TRgb;
begin
  case Operation of
    CompositeHue:
      Result := SetLuminosity(SetSaturation(Source, Saturation(Backdrop)), Luminosity(Backdrop));
    CompositeSaturation:
      Result := SetLuminosity(SetSaturation(Backdrop, Saturation(Source)), Luminosity(Backdrop));
    CompositeColor:
      Result := SetLuminosity(Source, Luminosity(Backdrop));
  else
    Result := SetLuminosity(Backdrop, Luminosity(Source));
  end;
end;

function BlendPremultiplied(const Destination, Source: TPremultipliedColor;
  Operation: TCompositeOperation): TPremultipliedColor;
var
  Backdrop, Blended, SourceColor: TRgb;
  Both: Single;
begin
  if Source.Alpha <= 0 then
    Exit(Destination);
  if Destination.Alpha <= 0 then
    Exit(Source);
  Backdrop.Red := Destination.Red / Destination.Alpha;
  Backdrop.Green := Destination.Green / Destination.Alpha;
  Backdrop.Blue := Destination.Blue / Destination.Alpha;
  SourceColor.Red := Source.Red / Source.Alpha;
  SourceColor.Green := Source.Green / Source.Alpha;
  SourceColor.Blue := Source.Blue / Source.Alpha;
  if Operation in [CompositeHue, CompositeSaturation, CompositeColor, CompositeLuminosity] then
    Blended := BlendNonSeparable(Backdrop, SourceColor, Operation)
  else
  begin
    Blended.Red := BlendChannel(Backdrop.Red, SourceColor.Red, Operation);
    Blended.Green := BlendChannel(Backdrop.Green, SourceColor.Green, Operation);
    Blended.Blue := BlendChannel(Backdrop.Blue, SourceColor.Blue, Operation);
  end;
  Both := Source.Alpha * Destination.Alpha;
  Result.Red := Source.Red * (1 - Destination.Alpha) + Destination.Red * (1 - Source.Alpha) + Both * Blended.Red;
  Result.Green := Source.Green * (1 - Destination.Alpha) + Destination.Green * (1 - Source.Alpha) +
    Both * Blended.Green;
  Result.Blue := Source.Blue * (1 - Destination.Alpha) + Destination.Blue * (1 - Source.Alpha) +
    Both * Blended.Blue;
  Result.Alpha := Source.Alpha + Destination.Alpha - Both;
end;

function CompositePremultiplied(const Destination, Source: TPremultipliedColor;
  Operation: TCompositeOperation): TPremultipliedColor;
var
  Fa, Fb: Single;
begin
  case Operation of
    CompositeSourceOver: begin Fa := 1; Fb := 1 - Source.Alpha; end;
    CompositeSourceIn: begin Fa := Destination.Alpha; Fb := 0; end;
    CompositeSourceOut: begin Fa := 1 - Destination.Alpha; Fb := 0; end;
    CompositeSourceAtop: begin Fa := Destination.Alpha; Fb := 1 - Source.Alpha; end;
    CompositeDestinationOver: begin Fa := 1 - Destination.Alpha; Fb := 1; end;
    CompositeDestinationIn: begin Fa := 0; Fb := Source.Alpha; end;
    CompositeDestinationOut: begin Fa := 0; Fb := 1 - Source.Alpha; end;
    CompositeDestinationAtop: begin Fa := 1 - Destination.Alpha; Fb := Source.Alpha; end;
    CompositeLighter: begin Fa := 1; Fb := 1; end;
    CompositeCopy: begin Fa := 1; Fb := 0; end;
    CompositeXor: begin Fa := 1 - Destination.Alpha; Fb := 1 - Source.Alpha; end;
  else
    Exit(BlendPremultiplied(Destination, Source, Operation));
  end;
  Result.Red := Source.Red * Fa + Destination.Red * Fb;
  Result.Green := Source.Green * Fa + Destination.Green * Fb;
  Result.Blue := Source.Blue * Fa + Destination.Blue * Fb;
  Result.Alpha := Source.Alpha * Fa + Destination.Alpha * Fb;
  if Operation = CompositeLighter then
  begin
    Result.Red := Min(Result.Red, 1);
    Result.Green := Min(Result.Green, 1);
    Result.Blue := Min(Result.Blue, 1);
    Result.Alpha := Min(Result.Alpha, 1);
  end;
end;

function CompositeColors(Destination, Source: TColor; Operation: TCompositeOperation): TColor;
begin
  if Operation = CompositeSourceOver then
    Exit(BlendColors(Destination, Source));
  Result := UnpremultiplyColor(CompositePremultiplied(PremultiplyColor(Destination), PremultiplyColor(Source),
    Operation));
end;

function MixPremultiplied(const First, Second: TPremultipliedColor; Weight: Single): TPremultipliedColor; inline;
begin
  Result.Red := First.Red + (Second.Red - First.Red) * Weight;
  Result.Green := First.Green + (Second.Green - First.Green) * Weight;
  Result.Blue := First.Blue + (Second.Blue - First.Blue) * Weight;
  Result.Alpha := First.Alpha + (Second.Alpha - First.Alpha) * Weight;
end;

procedure CompositeSpan(Destination, Source: PLongWord; Weights: PByte; Count: LongInt;
  Operation: TCompositeOperation);
var
  Index: LongInt;
  Weight: Byte;
  Before, After: TPremultipliedColor;
begin
  { Plain source over, the usual case, as one run. }
  if (Operation = CompositeSourceOver) and (Weights = nil) then
  begin
    BlendPixelSpan(Destination, Source, Count);
    Exit;
  end;
  for Index := 0 to Count - 1 do
  begin
    if Weights <> nil then
      Weight := Weights[Index]
    else
      Weight := 255;
    if Weight = 0 then
      Continue;
    if Operation = CompositeSourceOver then
    begin
      if AlphaOf(Source[Index]) = 0 then
        Continue;
      if Weight = 255 then
        Destination[Index] := BlendColors(Destination[Index], Source[Index])
      else
        Destination[Index] := BlendColors(Destination[Index], FadeColor(Source[Index], Weight));
      Continue;
    end;
    Before := PremultiplyColor(Destination[Index]);
    After := CompositePremultiplied(Before, PremultiplyColor(Source[Index]), Operation);
    if Weight < 255 then
      After := MixPremultiplied(Before, After, Weight / 255);
    Destination[Index] := UnpremultiplyColor(After);
  end;
end;

end.
