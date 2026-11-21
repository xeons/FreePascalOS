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
  The translation part of a box's transform (CSS Transforms 1 and 2):
  the translate property, then the transform list's translate(),
  translateX(), translateY(), translate3d() and the translation of a
  matrix() or matrix3d() whose other entries are the identity's. Layout
  adds it to the box's offset like a relative position, so the box and
  what is inside it are painted, hit and measured there (off-canvas
  menus, centring with translate(-50%, -50%), slides). Percentages are
  of the box's border box. Scaling, rotation and skewing are not drawn:
  a list with them still moves by its translations.
}
unit Web.Layout.Transforms;

{$mode objfpc}
{$H+}

interface

uses
  Css.ComputedStyle;

{ The box's translation (CSS px) for a border box of Width by Height;
  False when the box has no transform or translate. }
function TransformTranslation(Style: TCssComputedStyle; Width, Height: Single; out X, Y: Single): Boolean;

implementation

uses
  Css.Values,
  Css.Units,
  Css.Calc,
  Css.ComputedValues,
  Css.PropertyIds;

{ A length-percentage argument against Basis; 0 when it is neither. }
function ArgumentLength(Value: TCssValue; Basis: Single): Single;
var
  Pixels, Percent: Double;
begin
  Result := 0;
  case Value.Kind of
    vkDimension:
      if Value.UnitValue = cuPx then
        Result := Value.Number;
    vkPercentage:
      Result := Value.Number * Basis / 100;
    vkCalc:
      if CalcAsLengthPercentage(Value.Calc, Pixels, Percent) then
        Result := Pixels + Percent * Basis / 100;
  end;
end;

function ArgumentNumber(Value: TCssValue): Double;
begin
  if Value.Kind in [vkNumber, vkInteger] then
    Result := Value.Number
  else
    Result := 0;
end;

{ matrix(a, b, c, d, e, f) and matrix3d's sixteen numbers: the
  translation when the rest is the identity. }
procedure AddMatrixTranslation(Matrix: TCssValue; var X, Y: Single);
var
  Index: Integer;
  Values: array[0..15] of Double;
begin
  for Index := 0 to 15 do
    Values[Index] := 0;
  for Index := 0 to Matrix.Count - 1 do
    if Index <= 15 then
      Values[Index] := ArgumentNumber(Matrix.Items[Index]);
  if Matrix.Count = 6 then
  begin
    if (Values[0] = 1) and (Values[1] = 0) and (Values[2] = 0) and (Values[3] = 1) then
    begin
      X := X + Values[4];
      Y := Y + Values[5];
    end;
  end
  else if Matrix.Count = 16 then
  begin
    if (Values[0] = 1) and (Values[1] = 0) and (Values[4] = 0) and (Values[5] = 1) then
    begin
      X := X + Values[12];
      Y := Y + Values[13];
    end;
  end;
end;

procedure AddFunctionTranslation(Func: TCssValue; Width, Height: Single; var X, Y: Single);
begin
  if Func.Kind <> vkFunction then
    Exit;
  if (Func.Text = 'translate') or (Func.Text = 'translate3d') then
  begin
    if Func.Count >= 1 then
      X := X + ArgumentLength(Func.Items[0], Width);
    if Func.Count >= 2 then
      Y := Y + ArgumentLength(Func.Items[1], Height);
  end
  else if (Func.Text = 'translatex') and (Func.Count >= 1) then
    X := X + ArgumentLength(Func.Items[0], Width)
  else if (Func.Text = 'translatey') and (Func.Count >= 1) then
    Y := Y + ArgumentLength(Func.Items[0], Height)
  else if (Func.Text = 'matrix') or (Func.Text = 'matrix3d') then
    AddMatrixTranslation(Func, X, Y);
end;

function TransformTranslation(Style: TCssComputedStyle; Width, Height: Single; out X, Y: Single): Boolean;
var
  Value: PCssComputedValue;
  List: TCssValue;
  Index: Integer;
begin
  X := 0;
  Y := 0;
  Result := False;
  { translate: x [y [z]] }
  Value := Style.Value(cpTranslate);
  if (Value^.Kind = cvValue) and (Value^.Data <> nil) then
  begin
    Result := True;
    List := Value^.Data;
    if List.Kind = vkList then
    begin
      if List.Count >= 1 then
        X := X + ArgumentLength(List.Items[0], Width);
      if List.Count >= 2 then
        Y := Y + ArgumentLength(List.Items[1], Height);
    end
    else
      X := X + ArgumentLength(List, Width);
  end
  else if Value^.Kind in [cvLength, cvPercentage, cvLengthPercentage, cvCalc] then
  begin
    Result := True;
    X := X + ResolveComputed(Value^, Width);
  end;
  Value := Style.Value(cpTransform);
  if (Value^.Kind = cvValue) and (Value^.Data <> nil) then
  begin
    Result := True;
    List := Value^.Data;
    if List.Kind = vkList then
    begin
      for Index := 0 to List.Count - 1 do
        AddFunctionTranslation(List.Items[Index], Width, Height, X, Y);
    end
    else
      AddFunctionTranslation(List, Width, Height, X, Y);
  end;
end;

end.
