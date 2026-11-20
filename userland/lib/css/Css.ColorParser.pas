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
  Parsing <color> (CSS Color Level 4 and 5): hex colors, named colors,
  transparent, currentcolor, system colors, rgb()/rgba(), hsl()/hsla()
  (legacy comma and modern space syntax), hwb(), lab(), lch(), oklab(),
  oklch(), color() in every predefined space, and color-mix().

  Absolute colors become color values; currentcolor and system colors
  stay keywords (resolved when styles are computed); a color-mix() of
  something that is not absolute stays a color-mix function until then.
}
unit Css.ColorParser;

{$mode objfpc}
{$H+}

interface

uses
  Css.Tokens, Css.Colors, Css.Values;

function ParseColor(var Cursor: TCssTokenCursor): TCssValue;
function ParseColorText(const Text: string): TCssValue;
{ The absolute color of a parsed color value, given the current color
  and the color scheme. False when Value is not a color. }
function ResolveColor(Value: TCssValue; const CurrentColor: TCssColor; Dark: Boolean; out Color: TCssColor): Boolean;

implementation

uses
  Math, Css.Atoms, Css.Keywords, Css.Units, Css.Calc, Css.Tokenizer, Css.ValueParser;

type
  TChannel = record
    Value: Double;
    Missing: Boolean;
    Percent: Boolean;
    IsAngle: Boolean;
  end;
  TChannels = array[0..3] of TChannel;

function HexValue(Character: Char; out Value: Integer): Boolean;
begin
  Result := True;
  case Character of
    '0'..'9': Value := Ord(Character) - Ord('0');
    'a'..'f': Value := Ord(Character) - Ord('a') + 10;
    'A'..'F': Value := Ord(Character) - Ord('A') + 10;
  else
    Result := False;
  end;
end;

function ParseHex(const Text: string; out Color: TCssColor): Boolean;
var
  Digits: array[0..7] of Integer;
  Index: Integer;
begin
  Result := False;
  if not (Length(Text) in [3, 4, 6, 8]) then
    Exit;
  for Index := 1 to Length(Text) do
    if not HexValue(Text[Index], Digits[Index - 1]) then
      Exit;
  case Length(Text) of
    3: Color := MakeRgbColor(Digits[0] * 17 / 255, Digits[1] * 17 / 255, Digits[2] * 17 / 255, 1);
    4: Color := MakeRgbColor(Digits[0] * 17 / 255, Digits[1] * 17 / 255, Digits[2] * 17 / 255, Digits[3] * 17 / 255);
    6: Color := MakeRgbColor((Digits[0] * 16 + Digits[1]) / 255, (Digits[2] * 16 + Digits[3]) / 255,
      (Digits[4] * 16 + Digits[5]) / 255, 1);
  else
    Color := MakeRgbColor((Digits[0] * 16 + Digits[1]) / 255, (Digits[2] * 16 + Digits[3]) / 255,
      (Digits[4] * 16 + Digits[5]) / 255, (Digits[6] * 16 + Digits[7]) / 255);
  end;
  Result := True;
end;

{ One channel: a number, percentage, angle, 'none' or a math function. }
function ParseChannel(var Cursor: TCssTokenCursor; out Channel: TChannel): Boolean;
var
  Token: PCssToken;
  UnitValue: TCssUnit;
  Node: TCssCalcNode;
  Category: TCssUnitCategory;
begin
  Channel := Default(TChannel);
  Result := False;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  case Token^.Kind of
    tkNumber: Channel.Value := Token^.Number;
    tkPercentage:
      begin
        Channel.Value := Token^.Number;
        Channel.Percent := True;
      end;
    tkDimension:
      begin
        UnitValue := UnitByName(Token^.Text);
        if UnitCategory(UnitValue) <> ucAngle then
          Exit;
        Channel.Value := Token^.Number * CanonicalFactor(UnitValue);
        Channel.IsAngle := True;
      end;
    tkIdent:
      if AsciiSameText(Token^.Text, 'none') then
        Channel.Missing := True
      else
        Exit;
    tkFunction:
      begin
        for Category in [ucNumber, ucPercent, ucAngle] do
        begin
          Node := ParseMathFunction(Cursor, Category, ucPercent);
          if Node <> nil then
          begin
            try
              Channel.Value := EvaluateCalc(Node, nil, nil);
            finally
              Node.Free;
            end;
            Channel.Percent := Category = ucPercent;
            Channel.IsAngle := Category = ucAngle;
            Exit(True);
          end;
        end;
        Exit;
      end;
  else
    Exit;
  end;
  Inc(Cursor.Position);
  Result := True;
end;

{ The channels of a color function: three (or four in legacy syntax)
  separated by commas, or three separated by spaces and an optional
  "/ alpha". Count is 3 or 4; Legacy says commas were used. }
function ParseChannels(Contents: TCssTokenCursor; AllowLegacy: Boolean; out Channels: TChannels;
  out Count: Integer; out Legacy: Boolean): Boolean;
var
  Index: Integer;
begin
  Result := False;
  Count := 0;
  Legacy := False;
  for Index := 0 to 3 do
    Channels[Index] := Default(TChannel);
  if not ParseChannel(Contents, Channels[0]) then
    Exit;
  Count := 1;
  Contents.SkipWhitespace;
  if Contents.PeekKind = tkComma then
  begin
    if not AllowLegacy or Channels[0].Missing then
      Exit;
    Legacy := True;
    while Contents.PeekKind = tkComma do
    begin
      Inc(Contents.Position);
      if (Count = 4) or not ParseChannel(Contents, Channels[Count]) or Channels[Count].Missing then
        Exit;
      Inc(Count);
      Contents.SkipWhitespace;
    end;
    Result := Contents.AtEnd and (Count >= 3);
    Exit;
  end;
  while Count < 3 do
  begin
    if not ParseChannel(Contents, Channels[Count]) then
      Exit;
    Inc(Count);
  end;
  Contents.SkipWhitespace;
  if IsDelimToken(Contents.Peek, '/') then
  begin
    Inc(Contents.Position);
    if not ParseChannel(Contents, Channels[3]) then
      Exit;
    Count := 4;
  end;
  Result := Contents.AtEndIgnoringWhitespace;
end;

function Clamp(Value, Low, High: Double): Double;
begin
  Result := Max(Low, Min(High, Value));
end;

{ The alpha channel (0..1). }
function AlphaOf(const Channels: TChannels; Count: Integer; var Mask: Byte): Double;
begin
  if Count < 4 then
    Exit(1);
  if Channels[3].Missing then
  begin
    Mask := Mask or 8;
    Exit(0);
  end;
  if Channels[3].Percent then
    Result := Clamp(Channels[3].Value / 100, 0, 1)
  else
    Result := Clamp(Channels[3].Value, 0, 1);
end;

function ChannelValue(const Channel: TChannel; PercentReference: Double; Index: Integer; var Mask: Byte): Double;
begin
  if Channel.Missing then
  begin
    Mask := Mask or (1 shl Index);
    Exit(0);
  end;
  if Channel.Percent then
    Result := Channel.Value * PercentReference / 100
  else
    Result := Channel.Value;
end;

function HueValue(const Channel: TChannel; Index: Integer; var Mask: Byte): Double;
begin
  if Channel.Missing then
  begin
    Mask := Mask or (1 shl Index);
    Exit(0);
  end;
  Result := Channel.Value;
  Result := Result - 360 * Floor(Result / 360);
end;

function ParseRgb(Contents: TCssTokenCursor; out Color: TCssColor): Boolean;
var
  Channels: TChannels;
  Count, Index: Integer;
  Legacy: Boolean;
  Mask: Byte;
  Values: array[0..2] of Double;
begin
  Result := False;
  if not ParseChannels(Contents, True, Channels, Count, Legacy) then
    Exit;
  if Legacy then
    for Index := 1 to 2 do
      if Channels[Index].Percent <> Channels[0].Percent then
        Exit;
  Mask := 0;
  for Index := 0 to 2 do
  begin
    if Channels[Index].IsAngle then
      Exit;
    Values[Index] := Clamp(ChannelValue(Channels[Index], 255, Index, Mask), 0, 255) / 255;
  end;
  Color := MakeRgbColor(Values[0], Values[1], Values[2], AlphaOf(Channels, Count, Mask));
  Color.MissingMask := Mask;
  Result := True;
end;

function ParseHslOrHwb(Contents: TCssTokenCursor; IsHwb: Boolean; out Color: TCssColor): Boolean;
var
  Channels: TChannels;
  Count, Index: Integer;
  Legacy: Boolean;
  Mask: Byte;
  Second, Third: Double;
begin
  Result := False;
  if not ParseChannels(Contents, not IsHwb, Channels, Count, Legacy) then
    Exit;
  if Channels[0].Percent or Channels[1].IsAngle or Channels[2].IsAngle then
    Exit;
  if Legacy and not (Channels[1].Percent and Channels[2].Percent) then
    Exit;
  Mask := 0;
  Second := Max(0, ChannelValue(Channels[1], 100, 1, Mask));
  Third := ChannelValue(Channels[2], 100, 2, Mask);
  if IsHwb then
    Third := Max(0, Third)
  else
    Third := Clamp(Third, 0, 100);
  if IsHwb then
    Color := MakeColor(csHwb, HueValue(Channels[0], 0, Mask), Second, Third, AlphaOf(Channels, Count, Mask))
  else
    Color := MakeColor(csHsl, HueValue(Channels[0], 0, Mask), Second, Third, AlphaOf(Channels, Count, Mask));
  Color.MissingMask := Mask;
  Color.Legacy := True;
  { The legacy forms are sRGB colors (serialized as rgb()). }
  if Mask = 0 then
  begin
    Color := ConvertColor(Color, csSrgb);
    Color.Legacy := True;
  end;
  Result := True;
end;

function ParseLabLike(Contents: TCssTokenCursor; Space: TCssColorSpace; out Color: TCssColor): Boolean;
var
  Channels: TChannels;
  Count: Integer;
  Legacy: Boolean;
  Mask: Byte;
  LightnessReference, ChromaReference: Double;
  Lightness, Second, Third: Double;
begin
  Result := False;
  if not ParseChannels(Contents, False, Channels, Count, Legacy) then
    Exit;
  if Channels[0].IsAngle or Channels[1].IsAngle then
    Exit;
  Mask := 0;
  if Space in [csLab, csLch] then
    LightnessReference := 100
  else
    LightnessReference := 1;
  case Space of
    csLab: ChromaReference := 125;
    csLch: ChromaReference := 150;
  else
    ChromaReference := 0.4;
  end;
  Lightness := Clamp(ChannelValue(Channels[0], LightnessReference, 0, Mask), 0, LightnessReference);
  Second := ChannelValue(Channels[1], ChromaReference, 1, Mask);
  if Space in [csLch, csOklch] then
  begin
    if Channels[2].Percent then
      Exit;
    Second := Max(0, Second);
    Third := HueValue(Channels[2], 2, Mask);
  end
  else
  begin
    if Channels[2].IsAngle then
      Exit;
    Third := ChannelValue(Channels[2], ChromaReference, 2, Mask);
  end;
  Color := MakeColor(Space, Lightness, Second, Third, AlphaOf(Channels, Count, Mask));
  Color.MissingMask := Mask;
  Result := True;
end;

function ParseColorFunctionSpace(Contents: TCssTokenCursor; out Color: TCssColor): Boolean;
var
  Token: PCssToken;
  Space: TCssColorSpace;
  Channels: TChannels;
  Count, Index: Integer;
  Legacy: Boolean;
  Mask: Byte;
  Values: array[0..2] of Double;
begin
  Result := False;
  Token := Contents.NextNonWhitespace;
  if (Token^.Kind <> tkIdent) or
    not ColorSpaceByKeyword(KeywordOfAtom(FindAtom(AsciiLowercase(Token^.Text))), Space) or
    (Space in [csHsl, csHwb, csLab, csLch, csOklab, csOklch]) then
    Exit;
  if not ParseChannels(Contents, False, Channels, Count, Legacy) then
    Exit;
  Mask := 0;
  for Index := 0 to 2 do
  begin
    if Channels[Index].IsAngle then
      Exit;
    Values[Index] := ChannelValue(Channels[Index], 1, Index, Mask);
  end;
  Color := MakeColor(Space, Values[0], Values[1], Values[2], AlphaOf(Channels, Count, Mask));
  Color.MissingMask := Mask;
  Result := True;
end;

{ ---- color-mix() ---- }

type
  TMixArguments = record
    Space: TCssColorSpace;
    Hue: THueInterpolation;
    Colors: array[0..1] of TCssValue;
    Percents: array[0..1] of Double;
    HasPercent: array[0..1] of Boolean;
  end;

procedure ReleaseMix(var Mix: TMixArguments);
begin
  ReleaseValue(Mix.Colors[0]);
  ReleaseValue(Mix.Colors[1]);
end;

{ "in <space> [<hue-method> hue]?" }
function ParseInterpolation(var Cursor: TCssTokenCursor; var Mix: TMixArguments): Boolean;
var
  Keyword: TCssKeyword;
  Token: PCssToken;
begin
  Result := False;
  Mix.Hue := hiShorter;
  Token := Cursor.NextNonWhitespace;
  if (Token^.Kind <> tkIdent) or not AsciiSameText(Token^.Text, 'in') then
    Exit;
  Token := Cursor.NextNonWhitespace;
  if Token^.Kind <> tkIdent then
    Exit;
  if not ColorSpaceByKeyword(KeywordOfAtom(FindAtom(AsciiLowercase(Token^.Text))), Mix.Space) then
    Exit;
  Keyword := PeekKeyword(Cursor);
  if KeywordIn(Keyword, [kwShorter, kwLonger, kwIncreasing, kwDecreasing]) then
  begin
    if not IsPolarSpace(Mix.Space) then
      Exit;
    Cursor.NextNonWhitespace;
    case Keyword of
      kwLonger: Mix.Hue := hiLonger;
      kwIncreasing: Mix.Hue := hiIncreasing;
      kwDecreasing: Mix.Hue := hiDecreasing;
    else
      Mix.Hue := hiShorter;
    end;
    if PeekKeyword(Cursor) <> kwHue then
      Exit;
    Cursor.NextNonWhitespace;
  end;
  Result := Cursor.AtEndIgnoringWhitespace;
end;

{ "<color> && <percentage [0,100]>?" }
function ParseMixPart(Cursor: TCssTokenCursor; var Mix: TMixArguments; Index: Integer): Boolean;
var
  Token: PCssToken;
begin
  Result := False;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  if Token^.Kind = tkPercentage then
  begin
    Mix.Percents[Index] := Token^.Number;
    Mix.HasPercent[Index] := True;
    Inc(Cursor.Position);
  end;
  Mix.Colors[Index] := ParseColor(Cursor);
  if Mix.Colors[Index] = nil then
    Exit;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  if (Token^.Kind = tkPercentage) and not Mix.HasPercent[Index] then
  begin
    Mix.Percents[Index] := Token^.Number;
    Mix.HasPercent[Index] := True;
    Inc(Cursor.Position);
  end;
  if Mix.HasPercent[Index] and ((Mix.Percents[Index] < 0) or (Mix.Percents[Index] > 100)) then
    Exit;
  Result := Cursor.AtEndIgnoringWhitespace;
end;

function ParseMixArguments(Contents: TCssTokenCursor; out Mix: TMixArguments): Boolean;
var
  Parts: array[0..2] of TCssTokenCursor;
  Count, Start: Integer;
  Finished: Boolean;
begin
  Result := False;
  Mix := Default(TMixArguments);
  Count := 0;
  Start := Contents.Position;
  repeat
    Finished := Contents.AtEnd;
    if not Finished then
      if Contents.Next^.Kind <> tkComma then
        Continue;
    if Count = 3 then
      Exit;
    if Finished then
      Parts[Count] := TCssTokenCursor.CreateRange(Contents.Tokens, Start, Contents.Stop)
    else
      Parts[Count] := TCssTokenCursor.CreateRange(Contents.Tokens, Start, Contents.Position - 1);
    Inc(Count);
    Start := Contents.Position;
  until Finished;
  if Count <> 3 then
    Exit;
  if not ParseInterpolation(Parts[0], Mix) then
    Exit;
  if not ParseMixPart(Parts[1], Mix, 0) or not ParseMixPart(Parts[2], Mix, 1) then
  begin
    ReleaseMix(Mix);
    Exit;
  end;
  { Both percentages zero is invalid. }
  if Mix.HasPercent[0] and Mix.HasPercent[1] and (Mix.Percents[0] + Mix.Percents[1] = 0) then
  begin
    ReleaseMix(Mix);
    Exit;
  end;
  Result := True;
end;

function MixResolved(const Mix: TMixArguments; const First, Second: TCssColor): TCssColor;
var
  P1, P2, Sum, Scale: Double;
begin
  if Mix.HasPercent[0] and Mix.HasPercent[1] then
  begin
    P1 := Mix.Percents[0];
    P2 := Mix.Percents[1];
  end
  else if Mix.HasPercent[0] then
  begin
    P1 := Mix.Percents[0];
    P2 := 100 - P1;
  end
  else if Mix.HasPercent[1] then
  begin
    P2 := Mix.Percents[1];
    P1 := 100 - P2;
  end
  else
  begin
    P1 := 50;
    P2 := 50;
  end;
  Sum := P1 + P2;
  Scale := 1;
  if Sum < 100 then
    Scale := Sum / 100;
  Result := MixColors(Mix.Space, Mix.Hue, First, P1 / Sum, Second, P2 / Sum, Scale);
end;

{ The unresolved form: color-mix(in <space> ..., <color> <p>?, <color> <p>?) }
function MixAsValue(const Mix: TMixArguments; Contents: TCssTokenCursor): TCssValue;
var
  Interpolation, Part: TCssValue;
  Index: Integer;
begin
  Result := NewFunction('color-mix');
  Interpolation := NewList(lsSpace);
  Interpolation.Add(NewKeyword(kwIn));
  Interpolation.Add(NewCustomIdent(ColorSpaceName(Mix.Space)));
  if Mix.Hue <> hiShorter then
  begin
    case Mix.Hue of
      hiLonger: Interpolation.Add(NewKeyword(kwLonger));
      hiIncreasing: Interpolation.Add(NewKeyword(kwIncreasing));
    else
      Interpolation.Add(NewKeyword(kwDecreasing));
    end;
    Interpolation.Add(NewKeyword(kwHue));
  end;
  Result.Add(Interpolation);
  for Index := 0 to 1 do
  begin
    Part := NewList(lsSpace);
    Part.Add(Mix.Colors[Index].AddRef);
    if Mix.HasPercent[Index] then
      Part.Add(NewPercentage(Mix.Percents[Index]));
    Result.Add(Part);
  end;
end;

function ParseColorMix(Contents: TCssTokenCursor): TCssValue;
var
  Mix: TMixArguments;
begin
  Result := nil;
  if not ParseMixArguments(Contents, Mix) then
    Exit;
  try
    if (Mix.Colors[0].Kind = vkColor) and (Mix.Colors[1].Kind = vkColor) then
      Result := NewColor(MixResolved(Mix, Mix.Colors[0].Color, Mix.Colors[1].Color))
    else
      Result := MixAsValue(Mix, Contents);
  finally
    ReleaseMix(Mix);
  end;
end;

function ParseColor(var Cursor: TCssTokenCursor): TCssValue;
var
  Saved: Integer;
  Token: PCssToken;
  Lower: string;
  Color: TCssColor;
  Keyword: TCssKeyword;
  Contents: TCssTokenCursor;
  Parsed: Boolean;
begin
  Result := nil;
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  case Token^.Kind of
    tkHash:
      if ParseHex(Token^.Text, Color) then
      begin
        Inc(Cursor.Position);
        Exit(NewColor(Color));
      end;
    tkIdent:
      begin
        Lower := AsciiLowercase(Token^.Text);
        if FindNamedColor(Lower, Color) then
        begin
          Inc(Cursor.Position);
          Exit(NewColor(Color));
        end;
        Keyword := KeywordOfAtom(FindAtom(Lower));
        if Keyword = kwTransparent then
        begin
          Inc(Cursor.Position);
          Exit(NewColor(TransparentColor));
        end;
        if (Keyword = kwCurrentcolor) or IsSystemColorKeyword(Keyword) then
        begin
          Inc(Cursor.Position);
          Exit(NewKeyword(Keyword));
        end;
      end;
    tkFunction:
      begin
        Lower := AsciiLowercase(Token^.Text);
        Cursor.Next;
        Contents := Cursor.Contents(Token);
        Parsed := False;
        if (Lower = 'rgb') or (Lower = 'rgba') then
          Parsed := ParseRgb(Contents, Color)
        else if (Lower = 'hsl') or (Lower = 'hsla') then
          Parsed := ParseHslOrHwb(Contents, False, Color)
        else if Lower = 'hwb' then
          Parsed := ParseHslOrHwb(Contents, True, Color)
        else if Lower = 'lab' then
          Parsed := ParseLabLike(Contents, csLab, Color)
        else if Lower = 'lch' then
          Parsed := ParseLabLike(Contents, csLch, Color)
        else if Lower = 'oklab' then
          Parsed := ParseLabLike(Contents, csOklab, Color)
        else if Lower = 'oklch' then
          Parsed := ParseLabLike(Contents, csOklch, Color)
        else if Lower = 'color' then
          Parsed := ParseColorFunctionSpace(Contents, Color)
        else if Lower = 'color-mix' then
        begin
          Result := ParseColorMix(Contents);
          if Result <> nil then
            Exit;
        end;
        if Parsed then
          Exit(NewColor(Color));
      end;
  end;
  Cursor.Position := Saved;
end;

function ParseColorText(const Text: string): TCssValue;
var
  Cursor: TCssTokenCursor;
begin
  Cursor := TCssTokenCursor.Create(TokenizeCss(Text));
  Result := ParseColor(Cursor);
  if (Result <> nil) and not Cursor.AtEndIgnoringWhitespace then
    ReleaseValue(Result);
end;

function ResolveColor(Value: TCssValue; const CurrentColor: TCssColor; Dark: Boolean; out Color: TCssColor): Boolean;
var
  Mix: TMixArguments;
  First, Second: TCssColor;
  Interpolation, Part: TCssValue;
  Index, Item: Integer;
  Keyword: TCssKeyword;
  Space: TCssColorSpace;
begin
  Result := False;
  Color := TransparentColor;
  if Value = nil then
    Exit;
  case Value.Kind of
    vkColor:
      begin
        Color := Value.Color;
        Exit(True);
      end;
    vkKeyword:
      begin
        if Value.Keyword = kwCurrentcolor then
          Color := CurrentColor
        else if IsSystemColorKeyword(Value.Keyword) then
          Color := SystemColor(Value.Keyword, Dark)
        else
          Exit;
        Exit(True);
      end;
    vkFunction:
      if (Value.Text = 'color-mix') and (Value.Count = 3) then
      begin
        Mix := Default(TMixArguments);
        Interpolation := Value.Items[0];
        Mix.Space := csSrgb;
        Mix.Hue := hiShorter;
        for Item := 0 to Interpolation.Count - 1 do
        begin
          if Interpolation.Items[Item].Kind = vkCustomIdent then
          begin
            for Space := Low(TCssColorSpace) to High(TCssColorSpace) do
              if ColorSpaceName(Space) = Interpolation.Items[Item].Text then
                Mix.Space := Space;
          end
          else
          begin
            Keyword := Interpolation.Items[Item].Keyword;
            if Keyword = kwLonger then Mix.Hue := hiLonger
            else if Keyword = kwIncreasing then Mix.Hue := hiIncreasing
            else if Keyword = kwDecreasing then Mix.Hue := hiDecreasing;
          end;
        end;
        for Index := 0 to 1 do
        begin
          Part := Value.Items[Index + 1];
          if Part.Count >= 2 then
          begin
            Mix.HasPercent[Index] := True;
            Mix.Percents[Index] := Part.Items[1].Number;
          end;
        end;
        if not ResolveColor(Value.Items[1].Items[0], CurrentColor, Dark, First) or
          not ResolveColor(Value.Items[2].Items[0], CurrentColor, Dark, Second) then
          Exit;
        Color := MixResolved(Mix, First, Second);
        Result := True;
      end;
  end;
end;

end.
