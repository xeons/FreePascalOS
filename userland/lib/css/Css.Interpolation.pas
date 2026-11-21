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
  Interpolating computed values (CSS Values 4 "Combining values", CSS
  Transitions and Animations), by the animation type of each property
  in the property table: numbers, integers, lengths and percentages
  (mixed ones as length-percentages), colors (premultiplied sRGB),
  visibility, font weights, and transforms (function by function when
  the lists match, through 2D matrix decomposition otherwise; none is
  the identity of the other list's functions). Anything else is
  discrete: the caller flips at the middle.

  A style with some values replaced (the animated values over the
  cascaded style) is made by copying only the structs that change.
}
unit Css.Interpolation;

{$mode objfpc}
{$H+}

interface

uses
  Css.Colors, Css.Values, Css.PropertyIds, Css.ComputedValues, Css.ComputedStyle;

{ Value between From (Progress 0) and Target (1), a new reference;
  False when the two cannot be interpolated (discrete). CurrentFrom and
  CurrentTarget: the colors currentcolor stands for in each. }
function InterpolateComputed(Id: TCssPropertyId; const From, Target: TCssComputedValue;
  const CurrentFrom, CurrentTarget: TCssColor; Progress: Double; out Value: TCssComputedValue): Boolean;
{ Whether a property's values can be animated at all (not atNone). }
function IsAnimatable(Id: TCssPropertyId): Boolean;

type
  TCssValueOverride = record
    Id: TCssPropertyId;
    Value: TCssComputedValue;
  end;
  TCssValueOverrideArray = array of TCssValueOverride;

{ A new style: Base with the overrides' values (their references are
  taken). }
function StyleWithOverrides(Base: TCssComputedStyle; var Overrides: TCssValueOverrideArray;
  Count: Integer): TCssComputedStyle;

implementation

uses
  Math, Css.Keywords, Css.Units, Css.Properties, Css.StyleStructs, Css.TransformMatrices;

function IsAnimatable(Id: TCssPropertyId): Boolean;
begin
  Result := (Id > cpInvalid) and (Id <= High(TCssPhysicalId)) and (PropertyInfo(Id).Animation <> atNone);
end;

function Mix(A, B, Progress: Double): Double; inline;
begin
  Result := A + (B - A) * Progress;
end;

function BlankValue(Kind: TCssComputedKind): TCssComputedValue;
begin
  Result := Default(TCssComputedValue);
  Result.Kind := Kind;
end;

{ ---- colors ---- }

function ColorWords(const Value: TCssComputedValue; const Current: TCssColor; out Red, Green, Blue,
  Alpha: Double): Boolean;
var
  Resolved: TCssComputedValue;
begin
  Result := Value.Kind in [cvColor, cvCurrentColor];
  if not Result then
    Exit;
  if Value.Kind = cvCurrentColor then
    Resolved := ComputedColor(Current)
  else
    Resolved := Value;
  Red := Resolved.Red;
  Green := Resolved.Green;
  Blue := Resolved.Blue;
  Alpha := Resolved.Alpha;
end;

function InterpolateColor(const From, Target: TCssComputedValue; const CurrentFrom, CurrentTarget: TCssColor;
  Progress: Double; out Value: TCssComputedValue): Boolean;
var
  R1, G1, B1, A1, R2, G2, B2, A2, Alpha: Double;
begin
  Result := ColorWords(From, CurrentFrom, R1, G1, B1, A1) and ColorWords(Target, CurrentTarget, R2, G2, B2, A2);
  if not Result then
    Exit;
  { Premultiplied, then divided back. }
  Alpha := Mix(A1, A2, Progress);
  Value := BlankValue(cvColor);
  Value.Alpha := Round(EnsureRange(Alpha, 0, 65535));
  if Alpha <= 0 then
    Exit;
  Value.Red := Round(EnsureRange(Mix(R1 * A1, R2 * A2, Progress) / Alpha, 0, 65535));
  Value.Green := Round(EnsureRange(Mix(G1 * A1, G2 * A2, Progress) / Alpha, 0, 65535));
  Value.Blue := Round(EnsureRange(Mix(B1 * A1, B2 * A2, Progress) / Alpha, 0, 65535));
end;

{ ---- lengths ---- }

function LengthParts(const Value: TCssComputedValue; out Pixels, Percent: Double): Boolean;
begin
  Pixels := 0;
  Percent := 0;
  Result := True;
  case Value.Kind of
    cvLength: Pixels := Value.Number;
    cvPercentage: Percent := Value.Percent;
    cvLengthPercentage:
      begin
        Pixels := Value.Number;
        Percent := Value.Percent;
      end;
  else
    Result := False;
  end;
end;

function InterpolateLength(const From, Target: TCssComputedValue; Progress: Double;
  out Value: TCssComputedValue): Boolean;
var
  P1, Q1, P2, Q2: Double;
begin
  Result := LengthParts(From, P1, Q1) and LengthParts(Target, P2, Q2);
  if not Result then
    Exit;
  if (From.Kind = cvLength) and (Target.Kind = cvLength) then
    Value := ComputedLength(Mix(P1, P2, Progress))
  else if (From.Kind = cvPercentage) and (Target.Kind = cvPercentage) then
    Value := ComputedPercentage(Mix(Q1, Q2, Progress))
  else
    Value := ComputedLengthPercentage(Mix(P1, P2, Progress), Mix(Q1, Q2, Progress));
end;

{ ---- transforms ---- }

function IsTransformArgument(Value: TCssValue): Boolean;
begin
  Result := (Value <> nil) and (Value.Kind in [vkNumber, vkInteger, vkPercentage, vkDimension]);
end;

{ A numeric argument between two of the same kind; nil when they differ. }
function MixArgument(A, B: TCssValue; Progress: Double): TCssValue;
begin
  Result := nil;
  if not IsTransformArgument(A) or not IsTransformArgument(B) then
    Exit;
  if (A.Kind in [vkNumber, vkInteger]) and (B.Kind in [vkNumber, vkInteger]) then
    Exit(NewNumber(Mix(A.Number, B.Number, Progress)));
  if (A.Kind = vkPercentage) and (B.Kind = vkPercentage) then
    Exit(NewPercentage(Mix(A.Number, B.Number, Progress)));
  if (A.Kind = vkDimension) and (B.Kind = vkDimension) then
  begin
    if A.UnitValue = B.UnitValue then
      Exit(NewDimension(Mix(A.Number, B.Number, Progress), A.UnitValue));
    if (UnitCategory(A.UnitValue) = UnitCategory(B.UnitValue)) and (CanonicalFactor(A.UnitValue) <> 0) and
      (CanonicalFactor(B.UnitValue) <> 0) then
      Exit(NewDimension(Mix(A.Number * CanonicalFactor(A.UnitValue), B.Number * CanonicalFactor(B.UnitValue),
        Progress), CanonicalUnit(UnitCategory(A.UnitValue))));
  end;
  { 0 against a dimension (rotate(0) to rotate(90deg)). }
  if (A.Kind in [vkNumber, vkInteger]) and (A.Number = 0) and (B.Kind = vkDimension) then
    Exit(NewDimension(Mix(0, B.Number, Progress), B.UnitValue));
  if (B.Kind in [vkNumber, vkInteger]) and (B.Number = 0) and (A.Kind = vkDimension) then
    Exit(NewDimension(Mix(A.Number, 0, Progress), A.UnitValue));
end;

{ The identity function of the kind Func is (for none against a list). }
function IdentityFunction(Func: TCssValue): TCssValue;
var
  Index: Integer;
  Name: string;
begin
  Name := Func.Text;
  Result := NewFunction(Name);
  if Name = 'matrix' then
  begin
    for Index := 0 to 5 do
      if Index in [0, 3] then
        Result.Add(NewNumber(1))
      else
        Result.Add(NewNumber(0));
  end
  else if Name = 'matrix3d' then
  begin
    for Index := 0 to 15 do
      if Index in [0, 5, 10, 15] then
        Result.Add(NewNumber(1))
      else
        Result.Add(NewNumber(0));
  end
  else if Copy(Name, 1, 5) = 'scale' then
  begin
    for Index := 0 to Func.Count - 1 do
      Result.Add(NewNumber(1));
  end
  else if Name = 'rotate3d' then
  begin
    for Index := 0 to 2 do
      Result.Add(Func.Items[Index].AddRef);
    Result.Add(NewDimension(0, cuDeg));
  end
  else if Name = 'perspective' then
    Result.Add(NewKeyword(kwNone))
  else
    for Index := 0 to Func.Count - 1 do
      if Func.Items[Index].Kind = vkDimension then
        Result.Add(NewDimension(0, Func.Items[Index].UnitValue))
      else if Func.Items[Index].Kind = vkPercentage then
        Result.Add(NewPercentage(0))
      else
        Result.Add(NewNumber(0));
end;

function FunctionsOf(Value: TCssValue): TCssValueArray;
begin
  Result := nil;
  if Value = nil then
    Exit;
  if Value.Kind = vkFunction then
  begin
    SetLength(Result, 1);
    Result[0] := Value;
  end
  else if Value.Kind = vkList then
    Result := Copy(Value.Items);
end;

{ The two lists function by function, nil when they do not match. }
function MixFunctionLists(const A, B: TCssValueArray; Progress: Double): TCssValue;
var
  Index, Argument: Integer;
  Func, Mixed: TCssValue;
begin
  Result := nil;
  if Length(A) <> Length(B) then
    Exit;
  Result := NewList(lsSpace);
  for Index := 0 to High(A) do
  begin
    if (A[Index].Kind <> vkFunction) or (B[Index].Kind <> vkFunction) or (A[Index].Text <> B[Index].Text) or
      (A[Index].Count <> B[Index].Count) then
    begin
      Result.Release;
      Exit(nil);
    end;
    Func := NewFunction(A[Index].Text);
    for Argument := 0 to A[Index].Count - 1 do
    begin
      if A[Index].Items[Argument].Kind = vkKeyword then
        Mixed := A[Index].Items[Argument].AddRef
      else
        Mixed := MixArgument(A[Index].Items[Argument], B[Index].Items[Argument], Progress);
      if Mixed = nil then
      begin
        Func.Release;
        Result.Release;
        Exit(nil);
      end;
      Func.Add(Mixed);
    end;
    Result.Add(Func);
  end;
end;

function MatrixFunction(const Matrix: TCssMatrix2D): TCssValue;
begin
  Result := NewFunction('matrix');
  Result.Add(NewNumber(Matrix.A));
  Result.Add(NewNumber(Matrix.B));
  Result.Add(NewNumber(Matrix.C));
  Result.Add(NewNumber(Matrix.D));
  Result.Add(NewNumber(Matrix.E));
  Result.Add(NewNumber(Matrix.F));
end;

function InterpolateTransformLists(FromData, TargetData: TCssValue; Progress: Double): TCssValue;
var
  A, B, Identity: TCssValueArray;
  Index: Integer;
  FromMatrix, TargetMatrix: TCssMatrix2D;
begin
  A := FunctionsOf(FromData);
  B := FunctionsOf(TargetData);
  if (Length(A) = 0) and (Length(B) = 0) then
    Exit(NewKeyword(kwNone));
  Identity := nil;
  if Length(A) = 0 then
  begin
    SetLength(Identity, Length(B));
    for Index := 0 to High(B) do
      Identity[Index] := IdentityFunction(B[Index]);
    Result := MixFunctionLists(Identity, B, Progress);
  end
  else if Length(B) = 0 then
  begin
    SetLength(Identity, Length(A));
    for Index := 0 to High(A) do
      Identity[Index] := IdentityFunction(A[Index]);
    Result := MixFunctionLists(A, Identity, Progress);
  end
  else
    Result := MixFunctionLists(A, B, Progress);
  for Index := 0 to High(Identity) do
    Identity[Index].Release;
  if Result <> nil then
    Exit;
  { Lists that do not match: through matrices (percentages of the box
    are not known here: they count as 0). }
  FromMatrix := TransformListMatrix(FromData, 0, 0, 16);
  TargetMatrix := TransformListMatrix(TargetData, 0, 0, 16);
  Result := NewListOf(lsSpace, [MatrixFunction(InterpolateMatrices(FromMatrix, TargetMatrix, Progress))]);
end;

{ The translate, rotate and scale properties: item by item (none is 0
  or 1 of the other's items). }
function InterpolatePropertyList(Id: TCssPropertyId; FromData, TargetData: TCssValue; Progress: Double): TCssValue;
var
  A, B: TCssValueArray;
  Index: Integer;
  Mixed: TCssValue;

  function ItemsOf(Value: TCssValue): TCssValueArray;
  begin
    Result := nil;
    if (Value = nil) or (Value.Kind = vkKeyword) then
      Exit;
    if Value.Kind = vkList then
      Result := Copy(Value.Items)
    else
    begin
      SetLength(Result, 1);
      Result[0] := Value;
    end;
  end;

  function Neutral(Like: TCssValue): TCssValue;
  begin
    if Id = cpScale then
      Result := NewNumber(1)
    else if Like.Kind = vkDimension then
      Result := NewDimension(0, Like.UnitValue)
    else if Like.Kind = vkPercentage then
      Result := NewPercentage(0)
    else
      Result := NewNumber(0);
  end;

var
  Neutrals: TCssValueArray;
begin
  A := ItemsOf(FromData);
  B := ItemsOf(TargetData);
  if (Length(A) = 0) and (Length(B) = 0) then
    Exit(NewKeyword(kwNone));
  Neutrals := nil;
  if Length(A) = 0 then
  begin
    SetLength(Neutrals, Length(B));
    for Index := 0 to High(B) do
      Neutrals[Index] := Neutral(B[Index]);
    A := Neutrals;
  end
  else if Length(B) = 0 then
  begin
    SetLength(Neutrals, Length(A));
    for Index := 0 to High(A) do
      Neutrals[Index] := Neutral(A[Index]);
    B := Neutrals;
  end;
  Result := nil;
  if Length(A) = Length(B) then
  begin
    Result := NewList(lsSpace);
    for Index := 0 to High(A) do
    begin
      if A[Index].Kind in [vkKeyword, vkList] then
        Mixed := A[Index].AddRef
      else
        Mixed := MixArgument(A[Index], B[Index], Progress);
      if Mixed = nil then
      begin
        Result.Release;
        Result := nil;
        Break;
      end;
      Result.Add(Mixed);
    end;
  end;
  for Index := 0 to High(Neutrals) do
    Neutrals[Index].Release;
end;

function DataOf(const Value: TCssComputedValue): TCssValue;
begin
  if (Value.Kind = cvValue) and (Value.Data <> nil) and not
    ((Value.Data.Kind = vkKeyword) and (Value.Data.Keyword = kwNone)) then
    Result := Value.Data
  else
    Result := nil;
end;

function InterpolateTransform(Id: TCssPropertyId; const From, Target: TCssComputedValue; Progress: Double;
  out Value: TCssComputedValue): Boolean;
var
  Mixed: TCssValue;
begin
  Result := (From.Kind in [cvValue, cvKeyword]) and (Target.Kind in [cvValue, cvKeyword]);
  if not Result then
    Exit;
  if Id = cpTransform then
    Mixed := InterpolateTransformLists(DataOf(From), DataOf(Target), Progress)
  else
    Mixed := InterpolatePropertyList(Id, DataOf(From), DataOf(Target), Progress);
  if Mixed = nil then
    Exit(False);
  Value := ComputedTree(Mixed);
end;

{ ---- the dispatch ---- }

function NumberOf(const Value: TCssComputedValue; out Number: Double): Boolean;
begin
  Result := Value.Kind in [cvNumber, cvInteger];
  if Result then
    Number := Value.Number
  else
    Number := 0;
end;

function InterpolateComputed(Id: TCssPropertyId; const From, Target: TCssComputedValue;
  const CurrentFrom, CurrentTarget: TCssColor; Progress: Double; out Value: TCssComputedValue): Boolean;
var
  A, B: Double;
begin
  Value := Default(TCssComputedValue);
  Result := False;
  if not IsAnimatable(Id) then
    Exit;
  case PropertyInfo(Id).Animation of
    atNumber, atFontWeight:
      if NumberOf(From, A) and NumberOf(Target, B) then
      begin
        Value := ComputedNumber(Mix(A, B, Progress));
        if From.Kind = cvInteger then
          Value.Kind := cvInteger;
        Result := True;
      end;
    atInteger:
      if NumberOf(From, A) and NumberOf(Target, B) then
      begin
        Value := ComputedInteger(Round(Mix(A, B, Progress)));
        Result := True;
      end;
    atLength:
      Result := InterpolateLength(From, Target, Progress, Value);
    atColor:
      Result := InterpolateColor(From, Target, CurrentFrom, CurrentTarget, Progress, Value);
    atVisibility:
      begin
        { Visible throughout when either end is visible. }
        if (Progress > 0) and (Progress < 1) and (IsComputedKeyword(From, kwVisible) or
          IsComputedKeyword(Target, kwVisible)) then
          Value := ComputedKeyword(kwVisible)
        else if Progress < 0.5 then
          Value := From
        else
          Value := Target;
        AddRefComputed(Value);
        Result := True;
      end;
    atTransform:
      Result := InterpolateTransform(Id, From, Target, Progress, Value);
  end;
end;

function StyleWithOverrides(Base: TCssComputedStyle; var Overrides: TCssValueOverrideArray;
  Count: Integer): TCssComputedStyle;
var
  Group: TCssStructGroup;
  Copied: array[TCssStructGroup] of Boolean;
  Index, Slot: Integer;
  Struct: PCssStyleStruct;
begin
  Result := TCssComputedStyle.Create;
  for Group := Low(TCssStructGroup) to High(TCssStructGroup) do
  begin
    Result.Structs[Group] := Base.Structs[Group];
    AddRefStruct(Result.Structs[Group]);
    Copied[Group] := False;
  end;
  if Base.Custom <> nil then
    Result.Custom := Base.Custom.AddRef;
  Result.PseudoElement := Base.PseudoElement;
  for Index := 0 to Count - 1 do
  begin
    Group := PropertyGroup(Overrides[Index].Id);
    if not Copied[Group] then
    begin
      Struct := CopyStruct(Result.Structs[Group]);
      ReleaseStruct(Result.Structs[Group]);
      Result.Structs[Group] := Struct;
      Copied[Group] := True;
    end;
    Slot := PropertySlot(Overrides[Index].Id);
    ReleaseComputed(Result.Structs[Group]^.Values[Slot]);
    Result.Structs[Group]^.Values[Slot] := Overrides[Index].Value;
    Overrides[Index].Value := Default(TCssComputedValue);
  end;
end;

end.
