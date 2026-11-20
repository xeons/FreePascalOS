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
  SVG's attribute micro-syntaxes: numbers (with SVG's tolerant
  separators: "1-2" is two numbers, "1.5.5" is 1.5 and .5), lengths with
  units (user units, px, %, em, ex, rem, pt, pc, in, cm, mm, Q), number
  and length lists, viewBox, preserveAspectRatio and transform lists
  (matrix, translate, scale, rotate with a centre, skewX, skewY), and
  the transform a viewBox and preserveAspectRatio give a viewport.
}
unit Svg.Numbers;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Drawing.Transforms;

type
  TSvgNumberScanner = record
    Text: string;
    Position: Integer;
  end;

  TSvgLengthUnit = (LengthUserUnits, LengthPixels, LengthPercent, LengthEm, LengthEx, LengthRem, LengthPoints,
    LengthPicas, LengthInches, LengthCentimetres, LengthMillimetres, LengthQuarterMillimetres);

  TSvgLength = record
    Value: Double;
    UnitKind: TSvgLengthUnit;
  end;

  TSvgLengths = array of TSvgLength;
  TSvgNumbers = array of Double;

  { What a percentage is of: the viewport's width, height or its
    normalized diagonal (sqrt((w^2 + h^2) / 2)). }
  TSvgLengthDirection = (DirectionHorizontal, DirectionVertical, DirectionOther);

  TSvgViewBox = record
    X, Y, Width, Height: Double;
  end;

  TSvgAlign = (AlignNone, AlignXMinYMin, AlignXMidYMin, AlignXMaxYMin, AlignXMinYMid, AlignXMidYMid,
    AlignXMaxYMid, AlignXMinYMax, AlignXMidYMax, AlignXMaxYMax);

  TSvgAspectRatio = record
    Align: TSvgAlign;
    Slice: Boolean;
  end;

  TSvgViewport = record
    Width, Height: Double;
    FontSize: Double;
  end;

procedure BeginScan(out Scanner: TSvgNumberScanner; const Text: string);
procedure SkipSpaces(var Scanner: TSvgNumberScanner);
{ Spaces and at most one comma. }
procedure SkipSeparator(var Scanner: TSvgNumberScanner);
function ScanAtEnd(var Scanner: TSvgNumberScanner): Boolean;
function ScanNumber(var Scanner: TSvgNumberScanner; out Value: Double): Boolean;
{ A flag of an arc command: one character, 0 or 1. }
function ScanFlag(var Scanner: TSvgNumberScanner; out Value: Boolean): Boolean;

function ParseNumber(const Text: string; out Value: Double): Boolean;
function ParseLength(const Text: string; out Length: TSvgLength): Boolean;
function MakeLength(Value: Double; UnitKind: TSvgLengthUnit): TSvgLength;
function ParseNumberList(const Text: string): TSvgNumbers;
function ParseLengthList(const Text: string): TSvgLengths;
{ The length in user units. }
function ResolveLength(const Length: TSvgLength; Direction: TSvgLengthDirection;
  const Viewport: TSvgViewport): Double;
{ A number, or a percentage as a fraction (for objectBoundingBox values
  and gradient offsets). }
function ParseFraction(const Text: string; out Value: Double): Boolean;

function ParseViewBox(const Text: string; out Box: TSvgViewBox): Boolean;
function ParseAspectRatio(const Text: string): TSvgAspectRatio;
function DefaultAspectRatio: TSvgAspectRatio;
{ The transform that puts Box into the viewport at (X, Y) of Width x
  Height as the aspect ratio says. }
function ViewBoxTransform(const Box: TSvgViewBox; const AspectRatio: TSvgAspectRatio;
  X, Y, Width, Height: Double): TAffineTransform;
{ False (and the identity) when the list is malformed. }
function ParseTransformList(const Text: string; out Transform: TAffineTransform): Boolean;

implementation

uses
  Math;

const
  Spaces = [' ', #9, #10, #12, #13];

procedure BeginScan(out Scanner: TSvgNumberScanner; const Text: string);
begin
  Scanner.Text := Text;
  Scanner.Position := 1;
end;

procedure SkipSpaces(var Scanner: TSvgNumberScanner);
begin
  while (Scanner.Position <= Length(Scanner.Text)) and (Scanner.Text[Scanner.Position] in Spaces) do
    Inc(Scanner.Position);
end;

procedure SkipSeparator(var Scanner: TSvgNumberScanner);
begin
  SkipSpaces(Scanner);
  if (Scanner.Position <= Length(Scanner.Text)) and (Scanner.Text[Scanner.Position] = ',') then
  begin
    Inc(Scanner.Position);
    SkipSpaces(Scanner);
  end;
end;

function ScanAtEnd(var Scanner: TSvgNumberScanner): Boolean;
begin
  SkipSpaces(Scanner);
  Result := Scanner.Position > Length(Scanner.Text);
end;

function ScanNumber(var Scanner: TSvgNumberScanner; out Value: Double): Boolean;
var
  Index: Integer;
  Start: Integer;
  Text: string;
  Mantissa: Double;
  Scale: Double;
  Negative: Boolean;
  HasDigits: Boolean;
  Exponent: Integer;
  ExponentNegative: Boolean;
  ExponentStart: Integer;
begin
  Value := 0;
  Text := Scanner.Text;
  Index := Scanner.Position;
  Start := Index;
  Negative := False;
  if (Index <= Length(Text)) and (Text[Index] in ['+', '-']) then
  begin
    Negative := Text[Index] = '-';
    Inc(Index);
  end;
  Mantissa := 0;
  HasDigits := False;
  while (Index <= Length(Text)) and (Text[Index] in ['0'..'9']) do
  begin
    Mantissa := Mantissa * 10 + (Ord(Text[Index]) - Ord('0'));
    HasDigits := True;
    Inc(Index);
  end;
  if (Index <= Length(Text)) and (Text[Index] = '.') and (Index < Length(Text)) and
     (Text[Index + 1] in ['0'..'9']) then
  begin
    Inc(Index);
    Scale := 0.1;
    while (Index <= Length(Text)) and (Text[Index] in ['0'..'9']) do
    begin
      Mantissa := Mantissa + (Ord(Text[Index]) - Ord('0')) * Scale;
      Scale := Scale / 10;
      HasDigits := True;
      Inc(Index);
    end;
  end
  else if (Index <= Length(Text)) and (Text[Index] = '.') and HasDigits then
    Inc(Index);
  if not HasDigits then
  begin
    Scanner.Position := Start;
    Exit(False);
  end;
  { An exponent only when digits follow (so "1em" is 1 and a unit). }
  if (Index < Length(Text)) and (Text[Index] in ['e', 'E']) then
  begin
    ExponentStart := Index + 1;
    ExponentNegative := False;
    if (ExponentStart <= Length(Text)) and (Text[ExponentStart] in ['+', '-']) then
    begin
      ExponentNegative := Text[ExponentStart] = '-';
      Inc(ExponentStart);
    end;
    if (ExponentStart <= Length(Text)) and (Text[ExponentStart] in ['0'..'9']) then
    begin
      Exponent := 0;
      Index := ExponentStart;
      while (Index <= Length(Text)) and (Text[Index] in ['0'..'9']) do
      begin
        if Exponent < 1000 then
          Exponent := Exponent * 10 + (Ord(Text[Index]) - Ord('0'));
        Inc(Index);
      end;
      if Exponent > 300 then
        Exponent := 300;
      if ExponentNegative then
        Mantissa := Mantissa * Power(10, -Exponent)
      else
        Mantissa := Mantissa * Power(10, Exponent);
    end;
  end;
  if Negative then
    Mantissa := -Mantissa;
  Value := Mantissa;
  Scanner.Position := Index;
  Result := True;
end;

function ScanFlag(var Scanner: TSvgNumberScanner; out Value: Boolean): Boolean;
begin
  SkipSpaces(Scanner);
  Value := False;
  if (Scanner.Position <= Length(Scanner.Text)) and (Scanner.Text[Scanner.Position] in ['0', '1']) then
  begin
    Value := Scanner.Text[Scanner.Position] = '1';
    Inc(Scanner.Position);
    Exit(True);
  end;
  Result := False;
end;

function ParseNumber(const Text: string; out Value: Double): Boolean;
var
  Scanner: TSvgNumberScanner;
begin
  BeginScan(Scanner, Text);
  SkipSpaces(Scanner);
  Result := ScanNumber(Scanner, Value) and ScanAtEnd(Scanner);
end;

function MakeLength(Value: Double; UnitKind: TSvgLengthUnit): TSvgLength;
begin
  Result.Value := Value;
  Result.UnitKind := UnitKind;
end;

function UnitByName(const Name: string; out UnitKind: TSvgLengthUnit): Boolean;
var
  Lower: string;
begin
  Lower := LowerCase(Name);
  Result := True;
  if Lower = '' then UnitKind := LengthUserUnits
  else if Lower = 'px' then UnitKind := LengthPixels
  else if Lower = '%' then UnitKind := LengthPercent
  else if Lower = 'em' then UnitKind := LengthEm
  else if Lower = 'ex' then UnitKind := LengthEx
  else if Lower = 'rem' then UnitKind := LengthRem
  else if Lower = 'pt' then UnitKind := LengthPoints
  else if Lower = 'pc' then UnitKind := LengthPicas
  else if Lower = 'in' then UnitKind := LengthInches
  else if Lower = 'cm' then UnitKind := LengthCentimetres
  else if Lower = 'mm' then UnitKind := LengthMillimetres
  else if Lower = 'q' then UnitKind := LengthQuarterMillimetres
  else
    Result := False;
end;

function ScanLength(var Scanner: TSvgNumberScanner; out Length: TSvgLength): Boolean;
var
  Start: Integer;
begin
  Length := MakeLength(0, LengthUserUnits);
  if not ScanNumber(Scanner, Length.Value) then
    Exit(False);
  Start := Scanner.Position;
  while (Scanner.Position <= System.Length(Scanner.Text)) and
        (Scanner.Text[Scanner.Position] in ['a'..'z', 'A'..'Z', '%']) do
    Inc(Scanner.Position);
  Result := UnitByName(Copy(Scanner.Text, Start, Scanner.Position - Start), Length.UnitKind);
end;

function ParseLength(const Text: string; out Length: TSvgLength): Boolean;
var
  Scanner: TSvgNumberScanner;
begin
  BeginScan(Scanner, Text);
  SkipSpaces(Scanner);
  Result := ScanLength(Scanner, Length) and ScanAtEnd(Scanner);
end;

function ParseNumberList(const Text: string): TSvgNumbers;
var
  Scanner: TSvgNumberScanner;
  Value: Double;
begin
  Result := nil;
  BeginScan(Scanner, Text);
  SkipSpaces(Scanner);
  while not ScanAtEnd(Scanner) do
  begin
    if not ScanNumber(Scanner, Value) then
      Break;
    SetLength(Result, System.Length(Result) + 1);
    Result[High(Result)] := Value;
    SkipSeparator(Scanner);
  end;
end;

function ParseLengthList(const Text: string): TSvgLengths;
var
  Scanner: TSvgNumberScanner;
  Value: TSvgLength;
begin
  Result := nil;
  BeginScan(Scanner, Text);
  SkipSpaces(Scanner);
  while not ScanAtEnd(Scanner) do
  begin
    if not ScanLength(Scanner, Value) then
      Break;
    SetLength(Result, System.Length(Result) + 1);
    Result[High(Result)] := Value;
    SkipSeparator(Scanner);
  end;
end;

function ResolveLength(const Length: TSvgLength; Direction: TSvgLengthDirection;
  const Viewport: TSvgViewport): Double;
begin
  case Length.UnitKind of
    LengthPercent:
      case Direction of
        DirectionHorizontal: Result := Length.Value * Viewport.Width / 100;
        DirectionVertical: Result := Length.Value * Viewport.Height / 100;
        else
          Result := Length.Value * Sqrt((Sqr(Viewport.Width) + Sqr(Viewport.Height)) / 2) / 100;
      end;
    LengthEm: Result := Length.Value * Viewport.FontSize;
    LengthEx: Result := Length.Value * Viewport.FontSize / 2;
    LengthRem: Result := Length.Value * 16;
    LengthPoints: Result := Length.Value * 4 / 3;
    LengthPicas: Result := Length.Value * 16;
    LengthInches: Result := Length.Value * 96;
    LengthCentimetres: Result := Length.Value * 96 / 2.54;
    LengthMillimetres: Result := Length.Value * 96 / 25.4;
    LengthQuarterMillimetres: Result := Length.Value * 96 / 101.6;
    else
      Result := Length.Value;
  end;
end;

function ParseFraction(const Text: string; out Value: Double): Boolean;
var
  Scanner: TSvgNumberScanner;
begin
  BeginScan(Scanner, Text);
  SkipSpaces(Scanner);
  if not ScanNumber(Scanner, Value) then
    Exit(False);
  if (Scanner.Position <= System.Length(Scanner.Text)) and (Scanner.Text[Scanner.Position] = '%') then
  begin
    Value := Value / 100;
    Inc(Scanner.Position);
  end;
  Result := ScanAtEnd(Scanner);
end;

function ParseViewBox(const Text: string; out Box: TSvgViewBox): Boolean;
var
  Numbers: TSvgNumbers;
begin
  Box := Default(TSvgViewBox);
  Numbers := ParseNumberList(Text);
  if System.Length(Numbers) <> 4 then
    Exit(False);
  Box.X := Numbers[0];
  Box.Y := Numbers[1];
  Box.Width := Numbers[2];
  Box.Height := Numbers[3];
  Result := (Box.Width >= 0) and (Box.Height >= 0);
end;

function DefaultAspectRatio: TSvgAspectRatio;
begin
  Result.Align := AlignXMidYMid;
  Result.Slice := False;
end;

function ParseAspectRatio(const Text: string): TSvgAspectRatio;
const
  Names: array[TSvgAlign] of string = ('none', 'xminymin', 'xmidymin', 'xmaxymin', 'xminymid', 'xmidymid',
    'xmaxymid', 'xminymax', 'xmidymax', 'xmaxymax');
var
  Words: TStringArray;
  Align: TSvgAlign;
  Index: Integer;
  Word: string;
begin
  Result := DefaultAspectRatio;
  Words := LowerCase(Trim(Text)).Split([' ', #9, #10, #13], TStringSplitOptions.ExcludeEmpty);
  Index := 0;
  if (System.Length(Words) > 0) and (Words[0] = 'defer') then
    Inc(Index);
  if Index >= System.Length(Words) then
    Exit;
  Word := Words[Index];
  for Align := Low(TSvgAlign) to High(TSvgAlign) do
    if Names[Align] = Word then
    begin
      Result.Align := Align;
      Break;
    end;
  if (Index + 1 < System.Length(Words)) and (Words[Index + 1] = 'slice') then
    Result.Slice := True;
end;

function ViewBoxTransform(const Box: TSvgViewBox; const AspectRatio: TSvgAspectRatio;
  X, Y, Width, Height: Double): TAffineTransform;
var
  ScaleX, ScaleY: Double;
  TranslateX, TranslateY: Double;
  Horizontal, Vertical: Integer;
begin
  if (Box.Width <= 0) or (Box.Height <= 0) then
    Exit(TranslationTransform(X, Y));
  ScaleX := Width / Box.Width;
  ScaleY := Height / Box.Height;
  if AspectRatio.Align <> AlignNone then
  begin
    if AspectRatio.Slice then
      ScaleX := Max(ScaleX, ScaleY)
    else
      ScaleX := Min(ScaleX, ScaleY);
    ScaleY := ScaleX;
  end;
  TranslateX := X - Box.X * ScaleX;
  TranslateY := Y - Box.Y * ScaleY;
  if AspectRatio.Align <> AlignNone then
  begin
    { 0: min, 1: mid, 2: max along each axis. }
    Horizontal := (Ord(AspectRatio.Align) - 1) mod 3;
    Vertical := (Ord(AspectRatio.Align) - 1) div 3;
    if Horizontal = 1 then
      TranslateX := TranslateX + (Width - Box.Width * ScaleX) / 2
    else if Horizontal = 2 then
      TranslateX := TranslateX + (Width - Box.Width * ScaleX);
    if Vertical = 1 then
      TranslateY := TranslateY + (Height - Box.Height * ScaleY) / 2
    else if Vertical = 2 then
      TranslateY := TranslateY + (Height - Box.Height * ScaleY);
  end;
  Result := MakeTransform(ScaleX, 0, 0, ScaleY, TranslateX, TranslateY);
end;

function ParseTransformList(const Text: string; out Transform: TAffineTransform): Boolean;
var
  Scanner: TSvgNumberScanner;
  Start: Integer;
  Name: string;
  Arguments: array[0..5] of Double;
  Count: Integer;
  Step: TAffineTransform;
begin
  Transform := IdentityTransform;
  BeginScan(Scanner, Text);
  Result := False;
  repeat
    SkipSeparator(Scanner);
    if Scanner.Position > System.Length(Scanner.Text) then
      Break;
    Start := Scanner.Position;
    while (Scanner.Position <= System.Length(Scanner.Text)) and
          (Scanner.Text[Scanner.Position] in ['a'..'z', 'A'..'Z']) do
      Inc(Scanner.Position);
    Name := Copy(Scanner.Text, Start, Scanner.Position - Start);
    SkipSpaces(Scanner);
    if (Name = '') or (Scanner.Position > System.Length(Scanner.Text)) or
       (Scanner.Text[Scanner.Position] <> '(') then
    begin
      Transform := IdentityTransform;
      Exit;
    end;
    Inc(Scanner.Position);
    Count := 0;
    SkipSpaces(Scanner);
    while (Count < 6) and ScanNumber(Scanner, Arguments[Count]) do
    begin
      Inc(Count);
      SkipSeparator(Scanner);
    end;
    SkipSpaces(Scanner);
    if (Scanner.Position > System.Length(Scanner.Text)) or (Scanner.Text[Scanner.Position] <> ')') then
    begin
      Transform := IdentityTransform;
      Exit;
    end;
    Inc(Scanner.Position);
    if (Name = 'matrix') and (Count = 6) then
      Step := MakeTransform(Arguments[0], Arguments[1], Arguments[2], Arguments[3], Arguments[4], Arguments[5])
    else if (Name = 'translate') and (Count in [1, 2]) then
    begin
      if Count = 1 then
        Arguments[1] := 0;
      Step := TranslationTransform(Arguments[0], Arguments[1]);
    end
    else if (Name = 'scale') and (Count in [1, 2]) then
    begin
      if Count = 1 then
        Arguments[1] := Arguments[0];
      Step := ScalingTransform(Arguments[0], Arguments[1]);
    end
    else if (Name = 'rotate') and (Count in [1, 3]) then
    begin
      Step := RotationTransform(Arguments[0]);
      if Count = 3 then
        Step := CombineTransforms(TranslationTransform(Arguments[1], Arguments[2]),
          CombineTransforms(Step, TranslationTransform(-Arguments[1], -Arguments[2])));
    end
    else if (Name = 'skewX') and (Count = 1) then
      Step := SkewXTransform(Arguments[0])
    else if (Name = 'skewY') and (Count = 1) then
      Step := SkewYTransform(Arguments[0])
    else
    begin
      Transform := IdentityTransform;
      Exit;
    end;
    Transform := CombineTransforms(Transform, Step);
  until False;
  Result := True;
end;

end.
