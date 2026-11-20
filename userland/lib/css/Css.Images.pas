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
  <image> and <position> (CSS Images Level 3 and 4, CSS Values 4):
  url(), the gradients (linear, radial, conic and their repeating
  forms, with an optional "in <color space>"), and image-set().

  A gradient is a function value whose comma separated arguments are,
  first, its configuration (a space separated list, left out when it
  is all defaults) and then the color stops: each a list of a color and
  up to two positions, or a lone position for a transition hint.
}
unit Css.Images;

{$mode objfpc}
{$H+}

interface

uses
  Css.Tokens, Css.Values;

function ParseImage(var Cursor: TCssTokenCursor): TCssValue;
{ A <position> (one to four values) as a list of its two parts; each
  part a keyword, a length-percentage, or an edge keyword followed by
  an offset (a list). }
function ParsePosition(var Cursor: TCssTokenCursor): TCssValue;
{ A position of exactly one or two values (background-position-x and -y
  take the parts). }
function IsGradientFunction(const LowerName: string): Boolean;

implementation

uses
  Css.Atoms, Css.Keywords, Css.Units, Css.ValueParser, Css.ColorParser, Css.Colors;

function IsGradientFunction(const LowerName: string): Boolean;
begin
  Result := (LowerName = 'linear-gradient') or (LowerName = 'repeating-linear-gradient') or
    (LowerName = 'radial-gradient') or (LowerName = 'repeating-radial-gradient') or
    (LowerName = 'conic-gradient') or (LowerName = 'repeating-conic-gradient');
end;

{ ---- <position> ---- }

function IsHorizontalKeyword(Keyword: TCssKeyword): Boolean;
begin
  Result := (Keyword = kwLeft) or (Keyword = kwRight);
end;

function IsVerticalKeyword(Keyword: TCssKeyword): Boolean;
begin
  Result := (Keyword = kwTop) or (Keyword = kwBottom);
end;

function ParsePosition(var Cursor: TCssTokenCursor): TCssValue;
var
  Parts: array[0..3] of TCssValue;
  Count, Index, Saved: Integer;
  Keyword: TCssKeyword;
  HorizontalPart, VerticalPart, Swap: TCssValue;
  First, Second: TCssKeyword;

  function KeywordOf(Value: TCssValue): TCssKeyword;
  begin
    if (Value <> nil) and (Value.Kind = vkKeyword) then
      Result := Value.Keyword
    else
      Result := kwInvalid;
  end;

  procedure ReleaseParts;
  var
    PartIndex: Integer;
  begin
    for PartIndex := 0 to 3 do
      ReleaseValue(Parts[PartIndex]);
  end;

  function Pair(Edge, Offset: TCssValue): TCssValue;
  begin
    if Offset = nil then
      Exit(Edge);
    Result := NewListOf(lsSpace, [Edge, Offset]);
  end;

begin
  Result := nil;
  Saved := Cursor.Position;
  Count := 0;
  for Index := 0 to 3 do
    Parts[Index] := nil;
  while Count < 4 do
  begin
    Keyword := PeekKeyword(Cursor);
    if KeywordIn(Keyword, [kwLeft, kwRight, kwTop, kwBottom, kwCenter]) then
      Parts[Count] := ParseKeyword(Cursor, [])
    else
      Parts[Count] := ParseLengthPercentage(Cursor);
    if Parts[Count] = nil then
      Break;
    Inc(Count);
  end;
  case Count of
    1:
      begin
        if IsVerticalKeyword(KeywordOf(Parts[0])) then
          Result := NewListOf(lsSpace, [NewKeyword(kwCenter), Parts[0]])
        else
          Result := NewListOf(lsSpace, [Parts[0], NewKeyword(kwCenter)]);
        Exit;
      end;
    2:
      begin
        First := KeywordOf(Parts[0]);
        Second := KeywordOf(Parts[1]);
        if IsVerticalKeyword(First) or IsHorizontalKeyword(Second) then
        begin
          { "top left": swap, but "top 10px" or "10px left" are invalid. }
          if (IsVerticalKeyword(First) and (Second <> kwInvalid) and not IsVerticalKeyword(Second)) or
            (IsHorizontalKeyword(Second) and (First <> kwInvalid) and not IsHorizontalKeyword(First)) then
          begin
            Swap := Parts[0];
            Parts[0] := Parts[1];
            Parts[1] := Swap;
          end
          else
          begin
            ReleaseParts;
            Cursor.Position := Saved;
            Exit;
          end;
        end;
        if IsVerticalKeyword(KeywordOf(Parts[0])) or IsHorizontalKeyword(KeywordOf(Parts[1])) then
        begin
          ReleaseParts;
          Cursor.Position := Saved;
          Exit;
        end;
        Result := NewListOf(lsSpace, [Parts[0], Parts[1]]);
        Exit;
      end;
    3, 4:
      begin
        { Edge keywords, each optionally followed by an offset. }
        HorizontalPart := nil;
        VerticalPart := nil;
        Index := 0;
        while Index < Count do
        begin
          Keyword := KeywordOf(Parts[Index]);
          if Keyword = kwInvalid then
            Break;
          Swap := nil;
          if (Index + 1 < Count) and (KeywordOf(Parts[Index + 1]) = kwInvalid) then
          begin
            if Keyword = kwCenter then
              Break;
            Swap := Parts[Index + 1];
          end;
          if IsHorizontalKeyword(Keyword) and (HorizontalPart = nil) then
            HorizontalPart := Pair(Parts[Index], Swap)
          else if IsVerticalKeyword(Keyword) and (VerticalPart = nil) then
            VerticalPart := Pair(Parts[Index], Swap)
          else if (Keyword = kwCenter) and (Swap = nil) then
          begin
            if HorizontalPart = nil then
              HorizontalPart := Parts[Index]
            else if VerticalPart = nil then
              VerticalPart := Parts[Index]
            else
              Break;
          end
          else
            Break;
          Parts[Index] := nil;
          if Swap <> nil then
          begin
            Parts[Index + 1] := nil;
            Inc(Index);
          end;
          Inc(Index);
        end;
        if (Index = Count) and (HorizontalPart <> nil) and (VerticalPart <> nil) then
        begin
          ReleaseParts;
          Result := NewListOf(lsSpace, [HorizontalPart, VerticalPart]);
          Exit;
        end;
        ReleaseValue(HorizontalPart);
        ReleaseValue(VerticalPart);
      end;
  end;
  ReleaseParts;
  Cursor.Position := Saved;
end;

{ ---- gradients ---- }

function ParseStopPosition(var Cursor: TCssTokenCursor; Conic: Boolean): TCssValue;
begin
  if Conic then
    Result := ParseDimension(Cursor, ucAngle, True, False, True)
  else
    Result := ParseLengthPercentage(Cursor);
end;

{ One color stop "<color> <position> twice at most" or a hint "<position>". }
function ParseStop(Cursor: TCssTokenCursor; Conic: Boolean; out IsHint: Boolean): TCssValue;
var
  Color, Position: TCssValue;
begin
  Result := nil;
  IsHint := False;
  Position := ParseStopPosition(Cursor, Conic);
  if Position <> nil then
  begin
    Color := ParseColor(Cursor);
    if Color = nil then
    begin
      if not Cursor.AtEndIgnoringWhitespace then
      begin
        Position.Release;
        Exit;
      end;
      IsHint := True;
      Exit(Position);
    end;
    Result := NewListOf(lsSpace, [Color, Position]);
  end
  else
  begin
    Color := ParseColor(Cursor);
    if Color = nil then
      Exit;
    Result := NewListOf(lsSpace, [Color]);
    Position := ParseStopPosition(Cursor, Conic);
    if Position <> nil then
    begin
      Result.Add(Position);
      Position := ParseStopPosition(Cursor, Conic);
      if Position <> nil then
        Result.Add(Position);
    end;
  end;
  if not Cursor.AtEndIgnoringWhitespace then
    ReleaseValue(Result);
end;

{ "in <space> [<hue-method> hue]?" appended to Configuration. }
function ParseColorInterpolation(var Cursor: TCssTokenCursor; Configuration: TCssValue): Boolean;
var
  Space: TCssColorSpace;
  Keyword: TCssKeyword;
  Saved: Integer;
begin
  Result := False;
  Saved := Cursor.Position;
  if PeekKeyword(Cursor) <> kwIn then
    Exit;
  Cursor.NextNonWhitespace;
  Keyword := PeekKeyword(Cursor);
  if not ColorSpaceByKeyword(Keyword, Space) then
  begin
    Cursor.Position := Saved;
    Exit;
  end;
  Cursor.NextNonWhitespace;
  Configuration.Add(NewKeyword(kwIn));
  Configuration.Add(NewKeyword(Keyword));
  Keyword := PeekKeyword(Cursor);
  if KeywordIn(Keyword, [kwShorter, kwLonger, kwIncreasing, kwDecreasing]) and IsPolarSpace(Space) then
  begin
    Cursor.NextNonWhitespace;
    if PeekKeyword(Cursor) <> kwHue then
    begin
      Cursor.Position := Saved;
      Exit;
    end;
    Cursor.NextNonWhitespace;
    Configuration.Add(NewKeyword(Keyword));
    Configuration.Add(NewKeyword(kwHue));
  end;
  Result := True;
end;

function ParseLinearConfiguration(Cursor: TCssTokenCursor; Configuration: TCssValue): Boolean;
var
  Angle, Side: TCssValue;
  Keyword: TCssKeyword;
  Sides: Integer;
begin
  Result := False;
  ParseColorInterpolation(Cursor, Configuration);
  Angle := ParseAngle(Cursor, True);
  if Angle <> nil then
    Configuration.Add(Angle)
  else if PeekKeyword(Cursor) = kwTo then
  begin
    Cursor.NextNonWhitespace;
    Configuration.Add(NewKeyword(kwTo));
    Sides := 0;
    repeat
      Keyword := PeekKeyword(Cursor);
      if not KeywordIn(Keyword, [kwLeft, kwRight, kwTop, kwBottom]) then
        Break;
      Side := ParseKeyword(Cursor, []);
      Configuration.Add(Side);
      Inc(Sides);
    until Sides = 2;
    if Sides = 0 then
      Exit;
    if (Sides = 2) and ((IsHorizontalKeyword(Configuration.Items[Configuration.Count - 1].Keyword) =
      IsHorizontalKeyword(Configuration.Items[Configuration.Count - 2].Keyword))) then
      Exit;
  end;
  if Configuration.Count > 0 then
    ParseColorInterpolation(Cursor, Configuration);
  Result := (Configuration.Count > 0) and Cursor.AtEndIgnoringWhitespace;
end;

function ParseRadialConfiguration(Cursor: TCssTokenCursor; Configuration: TCssValue): Boolean;
var
  Keyword: TCssKeyword;
  Shape: TCssKeyword;
  Size, Position: TCssValue;
  Sizes: Integer;
begin
  Result := False;
  ParseColorInterpolation(Cursor, Configuration);
  Shape := kwInvalid;
  Sizes := 0;
  repeat
    Keyword := PeekKeyword(Cursor);
    if ((Keyword = kwCircle) or (Keyword = kwEllipse)) and (Shape = kwInvalid) then
    begin
      Shape := Keyword;
      Configuration.Add(ParseKeyword(Cursor, []));
      Continue;
    end;
    if KeywordIn(Keyword, [kwClosestSide, kwClosestCorner, kwFarthestSide, kwFarthestCorner]) and (Sizes = 0) then
    begin
      Configuration.Add(ParseKeyword(Cursor, []));
      Sizes := 3;
      Continue;
    end;
    if Sizes < 2 then
    begin
      Size := ParseLengthPercentage(Cursor, True);
      if Size <> nil then
      begin
        Configuration.Add(Size);
        Inc(Sizes);
        Continue;
      end;
    end;
    Break;
  until False;
  { A circle's size is one length; an ellipse's two length-percentages. }
  if (Sizes = 2) and (Shape = kwCircle) then
    Exit;
  if (Sizes = 1) and (Shape = kwEllipse) then
    Exit;
  if PeekKeyword(Cursor) = kwAt then
  begin
    Cursor.NextNonWhitespace;
    Position := ParsePosition(Cursor);
    if Position = nil then
      Exit;
    Configuration.Add(NewKeyword(kwAt));
    Configuration.Add(Position);
  end;
  if Configuration.Count > 0 then
    ParseColorInterpolation(Cursor, Configuration);
  Result := (Configuration.Count > 0) and Cursor.AtEndIgnoringWhitespace;
end;

function ParseConicConfiguration(Cursor: TCssTokenCursor; Configuration: TCssValue): Boolean;
var
  Angle, Position: TCssValue;
begin
  Result := False;
  ParseColorInterpolation(Cursor, Configuration);
  if PeekKeyword(Cursor) = kwFrom then
  begin
    Cursor.NextNonWhitespace;
    Angle := ParseAngle(Cursor, True);
    if Angle = nil then
      Exit;
    Configuration.Add(NewKeyword(kwFrom));
    Configuration.Add(Angle);
  end;
  if PeekKeyword(Cursor) = kwAt then
  begin
    Cursor.NextNonWhitespace;
    Position := ParsePosition(Cursor);
    if Position = nil then
      Exit;
    Configuration.Add(NewKeyword(kwAt));
    Configuration.Add(Position);
  end;
  if Configuration.Count > 0 then
    ParseColorInterpolation(Cursor, Configuration);
  Result := (Configuration.Count > 0) and Cursor.AtEndIgnoringWhitespace;
end;

function ParseGradient(const LowerName: string; Contents: TCssTokenCursor): TCssValue;
var
  Pieces: TCssTokenCursorArray;
  Configuration, Stop: TCssValue;
  First, Index, ColorStops: Integer;
  Conic, IsHint, PreviousWasHint: Boolean;
begin
  Result := nil;
  Pieces := SplitAtCommas(Contents);
  if Length(Pieces) < 2 then
    Exit;
  Conic := Pos('conic', LowerName) > 0;
  Result := NewFunction(LowerName);
  Configuration := NewList(lsSpace);
  if Pos('linear', LowerName) > 0 then
    First := Ord(ParseLinearConfiguration(Pieces[0], Configuration))
  else if Pos('radial', LowerName) > 0 then
    First := Ord(ParseRadialConfiguration(Pieces[0], Configuration))
  else
    First := Ord(ParseConicConfiguration(Pieces[0], Configuration));
  if First = 1 then
    Result.Add(Configuration)
  else
    Configuration.Release;
  ColorStops := 0;
  PreviousWasHint := True;
  for Index := First to High(Pieces) do
  begin
    Stop := ParseStop(Pieces[Index], Conic, IsHint);
    { Hints only between two color stops. }
    if (Stop = nil) or (IsHint and PreviousWasHint) then
    begin
      ReleaseValue(Stop);
      ReleaseValue(Result);
      Exit;
    end;
    if not IsHint then
      Inc(ColorStops);
    PreviousWasHint := IsHint;
    Result.Add(Stop);
  end;
  if (ColorStops < 2) or PreviousWasHint then
    ReleaseValue(Result);
end;

function ParseImageSet(Contents: TCssTokenCursor): TCssValue;
var
  Pieces: TCssTokenCursorArray;
  Index: Integer;
  Option, Image, Resolution: TCssValue;
begin
  Result := NewFunction('image-set');
  Pieces := SplitAtCommas(Contents);
  for Index := 0 to High(Pieces) do
  begin
    Image := ParseStringValue(Pieces[Index]);
    if Image = nil then
      Image := ParseImage(Pieces[Index]);
    if Image = nil then
    begin
      ReleaseValue(Result);
      Exit;
    end;
    Option := NewListOf(lsSpace, [Image]);
    Resolution := ParseDimension(Pieces[Index], ucResolution, False, True, False);
    if Resolution <> nil then
      Option.Add(Resolution);
    if not Pieces[Index].AtEndIgnoringWhitespace then
    begin
      Option.Release;
      ReleaseValue(Result);
      Exit;
    end;
    Result.Add(Option);
  end;
  if Result.Count = 0 then
    ReleaseValue(Result);
end;

function ParseImage(var Cursor: TCssTokenCursor): TCssValue;
var
  Saved: Integer;
  Token: PCssToken;
  Lower: string;
begin
  Result := ParseUrlValue(Cursor);
  if Result <> nil then
    Exit;
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  if Token^.Kind = tkFunction then
  begin
    Lower := AsciiLowercase(Token^.Text);
    Cursor.Next;
    if IsGradientFunction(Lower) then
      Result := ParseGradient(Lower, Cursor.Contents(Token))
    else if (Lower = 'image-set') or (Lower = '-webkit-image-set') then
      Result := ParseImageSet(Cursor.Contents(Token));
    if Result <> nil then
      Exit;
  end;
  Cursor.Position := Saved;
end;

end.
