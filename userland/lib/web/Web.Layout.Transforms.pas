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
  A box's transform (CSS Transforms 1 and 2): the translate, rotate and
  scale properties, then the transform list, about the transform origin
  (of the border box), as one 2D matrix (libcss's Css.TransformMatrices
  flattens 3D functions).

  A transform that only translates is taken by layout as an offset of
  the box, like a relative position (the box and what is inside it are
  laid out, painted, hit and measured there: off-canvas menus, centring
  with translate(-50%, -50%), slides). Any other transform (scaling,
  rotation, skewing) is applied when painting: the box's stacking
  context is drawn through the matrix (Web.Paint.Builder makes a
  transform group), hit testing maps points back through it, and the
  bounds script asks for are those of the transformed border box.
}
unit Web.Layout.Transforms;

{$mode objfpc}
{$H+}

interface

uses
  Css.ComputedStyle, Css.TransformMatrices, Web.Layout.Boxes;

{ The box's translation (CSS px) for a border box of Width by Height,
  when its transform only translates; False when it has none or does
  more (then it is a paint transform). }
function TransformTranslation(Style: TCssComputedStyle; Width, Height: Single; out X, Y: Single): Boolean;
{ The box's transform does more than translate. }
function HasPaintTransform(Style: TCssComputedStyle): Boolean;
{ The transform of a box whose border box is at (BorderX, BorderY) of
  Width by Height, as a matrix of document coordinates. }
function BoxTransformMatrix(Style: TCssComputedStyle; BorderX, BorderY, Width, Height: Single): TCssMatrix2D;
{ The box's paint transform and those of its ancestors, combined (for
  a point of the box's own coordinates to the document's); False when
  none applies. }
function AccumulatedPaintTransform(Box: TLayoutBox; out Matrix: TCssMatrix2D): Boolean;
{ The bounding rectangle of a document rectangle of Box after the paint
  transforms of Box and its ancestors. }
procedure TransformRectangle(Box: TLayoutBox; var X, Y, Width, Height: Single);

implementation

uses
  Math, Css.Values, Css.Keywords, Css.Calc, Css.ComputedValues, Css.PropertyIds;

function DataOf(Style: TCssComputedStyle; Id: TCssPropertyId): TCssValue;
var
  Value: PCssComputedValue;
begin
  Result := nil;
  Value := Style.Value(Id);
  if (Value^.Kind = cvValue) and (Value^.Data <> nil) and not Value^.Data.IsKeyword(kwNone) then
    Result := Value^.Data;
end;

{ The translate property as a value (lengths may be stored as computed
  lengths rather than a tree). }
function HasTranslateProperty(Style: TCssComputedStyle; out Data: TCssValue): Boolean;
var
  Value: PCssComputedValue;
begin
  Data := DataOf(Style, cpTranslate);
  Value := Style.Value(cpTranslate);
  Result := (Data <> nil) or (Value^.Kind in [cvLength, cvPercentage, cvLengthPercentage, cvCalc]);
end;

function FunctionTranslates(Func: TCssValue): Boolean;
var
  Matrix: TCssMatrix2D;
begin
  if Func.Kind <> vkFunction then
    Exit(False);
  if (Func.Text = 'translate') or (Func.Text = 'translatex') or (Func.Text = 'translatey') or
    (Func.Text = 'translate3d') or (Func.Text = 'translatez') or (Func.Text = 'perspective') then
    Exit(True);
  if (Func.Text = 'matrix') or (Func.Text = 'matrix3d') or (Copy(Func.Text, 1, 5) = 'scale') or
    (Copy(Func.Text, 1, 6) = 'rotate') or (Copy(Func.Text, 1, 4) = 'skew') then
  begin
    Matrix := FunctionMatrix(Func, 0, 0, 16);
    Exit(IsTranslationMatrix(Matrix));
  end;
  Result := False;
end;

function HasPaintTransform(Style: TCssComputedStyle): Boolean;
var
  List: TCssValue;
  Index: Integer;
begin
  Result := False;
  if Style = nil then
    Exit;
  if (DataOf(Style, cpRotate) <> nil) and not IsTranslationMatrix(RotatePropertyMatrix(DataOf(Style, cpRotate))) then
    Exit(True);
  if (DataOf(Style, cpScale) <> nil) and not IsTranslationMatrix(ScalePropertyMatrix(DataOf(Style, cpScale))) then
    Exit(True);
  List := DataOf(Style, cpTransform);
  if List = nil then
    Exit;
  if List.Kind = vkFunction then
    Exit(not FunctionTranslates(List));
  if List.Kind = vkList then
    for Index := 0 to List.Count - 1 do
      if not FunctionTranslates(List.Items[Index]) then
        Exit(True);
end;

function TransformTranslation(Style: TCssComputedStyle; Width, Height: Single; out X, Y: Single): Boolean;
var
  Data: TCssValue;
  Matrix: TCssMatrix2D;
  Value: PCssComputedValue;
begin
  X := 0;
  Y := 0;
  Result := False;
  if HasPaintTransform(Style) then
    Exit;
  if HasTranslateProperty(Style, Data) then
  begin
    Result := True;
    if Data <> nil then
    begin
      Matrix := TranslatePropertyMatrix(Data, Width, Height, Style.FontSize);
      X := X + Matrix.E;
      Y := Y + Matrix.F;
    end
    else
    begin
      Value := Style.Value(cpTranslate);
      X := X + ResolveComputed(Value^, Width);
    end;
  end;
  Data := DataOf(Style, cpTransform);
  if Data <> nil then
  begin
    Result := True;
    Matrix := TransformListMatrix(Data, Width, Height, Style.FontSize);
    X := X + Matrix.E;
    Y := Y + Matrix.F;
  end;
end;

{ One component of transform-origin against a size. }
function OriginPart(Value: TCssValue; Size, FontSize: Double): Double;
begin
  Result := Size / 2;
  if Value = nil then
    Exit;
  if Value.Kind = vkKeyword then
    case Value.Keyword of
      kwLeft, kwTop: Result := 0;
      kwRight, kwBottom: Result := Size;
    else
      Result := Size / 2;
    end
  else
    Result := ArgumentPixels(Value, Size, FontSize);
end;

function BoxTransformMatrix(Style: TCssComputedStyle; BorderX, BorderY, Width, Height: Single): TCssMatrix2D;
var
  Origin: TCssValue;
  OriginX, OriginY: Double;
  Data: TCssValue;
  Value: PCssComputedValue;
  Inner: TCssMatrix2D;
begin
  Result := IdentityMatrix;
  if Style = nil then
    Exit;
  OriginX := Width / 2;
  OriginY := Height / 2;
  Origin := DataOf(Style, cpTransformOrigin);
  if (Origin <> nil) and (Origin.Kind = vkList) and (Origin.Count >= 2) then
  begin
    OriginX := OriginPart(Origin.Items[0], Width, Style.FontSize);
    OriginY := OriginPart(Origin.Items[1], Height, Style.FontSize);
  end;
  Inner := IdentityMatrix;
  if HasTranslateProperty(Style, Data) then
  begin
    if Data <> nil then
      Inner := TranslatePropertyMatrix(Data, Width, Height, Style.FontSize)
    else
    begin
      Value := Style.Value(cpTranslate);
      Inner.E := ResolveComputed(Value^, Width);
    end;
  end;
  Data := DataOf(Style, cpRotate);
  if Data <> nil then
    Inner := MultiplyMatrices(Inner, RotatePropertyMatrix(Data));
  Data := DataOf(Style, cpScale);
  if Data <> nil then
    Inner := MultiplyMatrices(Inner, ScalePropertyMatrix(Data));
  Data := DataOf(Style, cpTransform);
  if Data <> nil then
    Inner := MultiplyMatrices(Inner, TransformListMatrix(Data, Width, Height, Style.FontSize));
  OriginX := OriginX + BorderX;
  OriginY := OriginY + BorderY;
  Result.E := OriginX;
  Result.F := OriginY;
  Result := MultiplyMatrices(Result, Inner);
  Inner := IdentityMatrix;
  Inner.E := -OriginX;
  Inner.F := -OriginY;
  Result := MultiplyMatrices(Result, Inner);
end;

function AccumulatedPaintTransform(Box: TLayoutBox; out Matrix: TCssMatrix2D): Boolean;
var
  Current: TLayoutBox;
  X, Y: Single;
begin
  Matrix := IdentityMatrix;
  Result := False;
  Current := Box;
  while Current <> nil do
  begin
    if not (Current.Kind in [bkInline, bkText, bkLineBreak]) and HasPaintTransform(Current.Style) then
    begin
      Current.AbsolutePosition(X, Y);
      Matrix := MultiplyMatrices(BoxTransformMatrix(Current.Style, X, Y, Current.Width, Current.Height), Matrix);
      Result := True;
    end;
    Current := Current.Parent;
  end;
end;

procedure TransformRectangle(Box: TLayoutBox; var X, Y, Width, Height: Single);
var
  Matrix: TCssMatrix2D;
  Corners: array[0..3, 0..1] of Double;
  Index: Integer;
  MinX, MinY, MaxX, MaxY, PointX, PointY: Double;
begin
  if not AccumulatedPaintTransform(Box, Matrix) then
    Exit;
  Corners[0, 0] := X;
  Corners[0, 1] := Y;
  Corners[1, 0] := X + Width;
  Corners[1, 1] := Y;
  Corners[2, 0] := X;
  Corners[2, 1] := Y + Height;
  Corners[3, 0] := X + Width;
  Corners[3, 1] := Y + Height;
  MinX := Infinity;
  MinY := Infinity;
  MaxX := -Infinity;
  MaxY := -Infinity;
  for Index := 0 to 3 do
  begin
    PointX := Matrix.A * Corners[Index, 0] + Matrix.C * Corners[Index, 1] + Matrix.E;
    PointY := Matrix.B * Corners[Index, 0] + Matrix.D * Corners[Index, 1] + Matrix.F;
    MinX := Min(MinX, PointX);
    MinY := Min(MinY, PointY);
    MaxX := Max(MaxX, PointX);
    MaxY := Max(MaxY, PointY);
  end;
  X := MinX;
  Y := MinY;
  Width := MaxX - MinX;
  Height := MaxY - MinY;
end;

end.
