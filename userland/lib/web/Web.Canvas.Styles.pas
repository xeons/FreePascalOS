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
  Fill and stroke styles (HTML Standard 4.12.5.1.10): CSS colours
  parsed with libcss and serialized as the standard asks (#rrggbb when
  opaque, else rgba(r, g, b, a) with the shortest alpha that comes back
  to the same byte), CanvasGradient (linear, radial, conic, with colour
  stops in offset order and the order they were added) and
  CanvasPattern (a copy of the image's pixels, the repetition, the
  pattern's own transform). A style becomes a libdrawing paint for a
  device-space fill given the transform current when it is used.
}
unit Web.Canvas.Styles;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Drawing.Colors,
  Drawing.Surfaces,
  Drawing.Transforms,
  Drawing.Paints,
  Image.Model,
  Web.Canvas.Shared;

type
  ECanvasSyntaxError = class(Exception);

  TCanvasGradientKind = (GradientLinear, GradientRadial, GradientConic);

  TCanvasGradient = class(TCanvasSharedObject)
  public
    Kind: TCanvasGradientKind;
    { Linear: (X0, Y0) to (X1, Y1). Radial: circles (X0, Y0, R0) and
      (X1, Y1, R1). Conic: centre (X0, Y0), StartAngle. }
    X0, Y0, R0, X1, Y1, R1: Double;
    StartAngle: Double;
    Stops: TGradientStops;
    { addColorStop: ECanvasIndexSizeError-like range errors are the
      caller's; Color already parsed. }
    procedure AddStop(Offset: Double; Color: TColor);
  end;

  TCanvasPatternRepetition = (RepeatBoth, RepeatX, RepeatY, RepeatNone);

  TCanvasPattern = class(TCanvasSharedObject)
  public
    Image: TImage;
    Repetition: TCanvasPatternRepetition;
    Transform: TAffineTransform;
    { Made from an image script may not read: using it taints. }
    OriginClean: Boolean;
    { Takes Image. }
    constructor Create(AImage: TImage; ARepetition: TCanvasPatternRepetition);
    destructor Destroy; override;
  end;

  TCanvasStyleKind = (StyleColor, StyleGradient, StylePattern);

  { A fill or stroke style; a gradient or pattern is referenced (see
    AssignStyle and ReleaseStyle). }
  TCanvasPaintStyle = record
    Kind: TCanvasStyleKind;
    Color: TColor;
    Gradient: TCanvasGradient;
    Pattern: TCanvasPattern;
  end;

{ A CSS colour; CurrentColor is what currentcolor means here. False when
  Text is not a colour. }
function ParseCanvasColor(const Text: string; CurrentColor: TColor; out Color: TColor): Boolean;
function SerializeCanvasColor(Color: TColor): string;
{ 'repeat', 'repeat-x', 'repeat-y', 'no-repeat', or '' (repeat). }
function ParsePatternRepetition(const Text: string; out Repetition: TCanvasPatternRepetition): Boolean;

function ColorStyle(Color: TColor): TCanvasPaintStyle;
{ Target takes Source's style (and a reference to its object). }
procedure AssignStyle(var Target: TCanvasPaintStyle; const Source: TCanvasPaintStyle);
procedure RetainStyle(const Style: TCanvasPaintStyle);
procedure ReleaseStyle(var Style: TCanvasPaintStyle);

{ The style as a paint for device pixels when UserToDevice is the
  transform; False when it paints nothing (a degenerate gradient, a
  singular transform). Smooth: patterns are sampled between pixels. }
function StylePaint(const Style: TCanvasPaintStyle; const UserToDevice: TAffineTransform; Smooth: Boolean;
  out Paint: TPaint): Boolean;

implementation

uses
  Math,
  Css.Colors,
  Css.Values,
  Css.ColorParser;

procedure TCanvasGradient.AddStop(Offset: Double; Color: TColor);
var
  Index, Position: Integer;
begin
  Position := Length(Stops);
  while (Position > 0) and (Stops[Position - 1].Offset > Offset) do
    Dec(Position);
  SetLength(Stops, Length(Stops) + 1);
  Index := High(Stops);
  while Index > Position do
  begin
    Stops[Index] := Stops[Index - 1];
    Dec(Index);
  end;
  Stops[Position].Offset := Offset;
  Stops[Position].Color := Color;
end;

constructor TCanvasPattern.Create(AImage: TImage; ARepetition: TCanvasPatternRepetition);
begin
  inherited Create;
  Image := AImage;
  Repetition := ARepetition;
  Transform := IdentityTransform;
  OriginClean := True;
end;

destructor TCanvasPattern.Destroy;
begin
  Image.Free;
  inherited Destroy;
end;

function ParseCanvasColor(const Text: string; CurrentColor: TColor; out Color: TColor): Boolean;
var
  Value: TCssValue;
  Current, Resolved: TCssColor;
  Rgba: TCssRgba8;
begin
  Color := ColorBlack;
  Value := ParseColorText(Text);
  if Value = nil then
    Exit(False);
  try
    Current := MakeRgbColor(RedOf(CurrentColor) / 255, GreenOf(CurrentColor) / 255, BlueOf(CurrentColor) / 255,
      AlphaOf(CurrentColor) / 255);
    Result := ResolveColor(Value, Current, False, Resolved);
    if Result then
    begin
      Rgba := ColorToRgba8(Resolved);
      Color := ArgbColor(Rgba.Alpha, Rgba.Red, Rgba.Green, Rgba.Blue);
    end;
  finally
    ReleaseValue(Value);
  end;
end;

function AlphaText(Alpha: Byte): string;
var
  Digits: Integer;
  Value: Double;
begin
  if Alpha = 0 then
    Exit('0');
  for Digits := 1 to 4 do
  begin
    Value := RoundTo(Alpha / 255, -Digits);
    if Round(Value * 255) = Alpha then
      Exit(FormatFloat('0.' + StringOfChar('#', Digits), Value, DefaultFormatSettings));
  end;
  Result := FormatFloat('0.######', Alpha / 255, DefaultFormatSettings);
end;

function SerializeCanvasColor(Color: TColor): string;
begin
  if AlphaOf(Color) = 255 then
    Result := '#' + LowerCase(IntToHex(RedOf(Color), 2) + IntToHex(GreenOf(Color), 2) + IntToHex(BlueOf(Color), 2))
  else
    Result := 'rgba(' + IntToStr(RedOf(Color)) + ', ' + IntToStr(GreenOf(Color)) + ', ' + IntToStr(BlueOf(Color)) +
      ', ' + AlphaText(AlphaOf(Color)) + ')';
end;

function ParsePatternRepetition(const Text: string; out Repetition: TCanvasPatternRepetition): Boolean;
begin
  Result := True;
  if (Text = '') or (Text = 'repeat') then
    Repetition := RepeatBoth
  else if Text = 'repeat-x' then
    Repetition := RepeatX
  else if Text = 'repeat-y' then
    Repetition := RepeatY
  else if Text = 'no-repeat' then
    Repetition := RepeatNone
  else
  begin
    Repetition := RepeatBoth;
    Result := False;
  end;
end;

function ColorStyle(Color: TColor): TCanvasPaintStyle;
begin
  Result.Kind := StyleColor;
  Result.Color := Color;
  Result.Gradient := nil;
  Result.Pattern := nil;
end;

procedure RetainStyle(const Style: TCanvasPaintStyle);
begin
  if Style.Gradient <> nil then
    Style.Gradient.Retain;
  if Style.Pattern <> nil then
    Style.Pattern.Retain;
end;

procedure ReleaseStyle(var Style: TCanvasPaintStyle);
begin
  ReleaseShared(Style.Gradient);
  ReleaseShared(Style.Pattern);
end;

procedure AssignStyle(var Target: TCanvasPaintStyle; const Source: TCanvasPaintStyle);
begin
  RetainStyle(Source);
  ReleaseStyle(Target);
  Target := Source;
end;

function StylePaint(const Style: TCanvasPaintStyle; const UserToDevice: TAffineTransform; Smooth: Boolean;
  out Paint: TPaint): Boolean;
var
  ToUser, PatternToDevice, ToPattern: TAffineTransform;
  Gradient: TCanvasGradient;
  Single_: TColor;
begin
  Paint := SolidPaint(ColorTransparent);
  case Style.Kind of
    StyleColor:
      begin
        Paint := SolidPaint(Style.Color);
        Exit(True);
      end;
    StyleGradient:
      begin
        Gradient := Style.Gradient;
        if not InvertTransform(UserToDevice, ToUser) then
          Exit(False);
        if Length(Gradient.Stops) = 0 then
          Exit(False);
        case Gradient.Kind of
          GradientLinear:
            begin
              if (Gradient.X0 = Gradient.X1) and (Gradient.Y0 = Gradient.Y1) then
                Exit(False);
              Paint := LinearGradientPaint(Gradient.X0, Gradient.Y0, Gradient.X1, Gradient.Y1, Gradient.Stops,
                SpreadPad, ToUser);
            end;
          GradientRadial:
            begin
              if (Gradient.X0 = Gradient.X1) and (Gradient.Y0 = Gradient.Y1) and (Gradient.R0 = Gradient.R1) then
                Exit(False);
              Paint := RadialGradientPaint(Gradient.X1, Gradient.Y1, Gradient.R1, Gradient.X0, Gradient.Y0,
                Gradient.R0, Gradient.Stops, SpreadPad, ToUser);
            end;
        else
          Paint := ConicGradientPaint(Gradient.X0, Gradient.Y0, Gradient.StartAngle, Gradient.Stops, ToUser);
        end;
        if (Length(Gradient.Stops) = 1) or GradientIsSolid(Gradient.Stops, Single_) then
        begin
          if Gradient.Kind <> GradientRadial then
          begin
            Paint := SolidPaint(Gradient.Stops[0].Color);
            Exit(True);
          end;
        end;
        Paint.InterpolateUnpremultiplied := True;
        PreparePaint(Paint);
        Result := True;
      end;
  else
    begin
      if (Style.Pattern.Image = nil) or (Style.Pattern.Image.Width = 0) or (Style.Pattern.Image.Height = 0) then
        Exit(False);
      PatternToDevice := CombineTransforms(UserToDevice, Style.Pattern.Transform);
      if not InvertTransform(PatternToDevice, ToPattern) then
        Exit(False);
      Paint := PatternPaint(SurfaceOnPixels(Style.Pattern.Image.Pixels, Style.Pattern.Image.Width,
        Style.Pattern.Image.Height, Style.Pattern.Image.Width * 4), ToPattern);
      Paint.TileRepeat := Style.Pattern.Repetition <> RepeatNone;
      Paint.NoRepeatX := Style.Pattern.Repetition = RepeatY;
      Paint.NoRepeatY := Style.Pattern.Repetition = RepeatX;
      Paint.Smooth := Smooth;
      Result := True;
    end;
  end;
end;

end.
