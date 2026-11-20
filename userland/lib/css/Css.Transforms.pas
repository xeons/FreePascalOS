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
  Transforms (CSS Transforms Level 1 and 2): the transform functions,
  the transform property's list of them, and the individual translate,
  rotate and scale properties.

  A transform function is a function value named in lowercase with its
  arguments checked and typed (lengths, percentages, numbers, angles).
}
unit Css.Transforms;

{$mode objfpc}
{$H+}

interface

uses
  Css.Tokens, Css.Values;

{ none | <transform-function>+ }
function ParseTransformList(var Cursor: TCssTokenCursor): TCssValue;
function ParseTransformFunction(var Cursor: TCssTokenCursor): TCssValue;
{ none | <length-percentage> [<length-percentage> <length>?]? }
function ParseTranslateProperty(var Cursor: TCssTokenCursor): TCssValue;
{ none | <angle> | [x | y | z | three numbers] and an angle }
function ParseRotateProperty(var Cursor: TCssTokenCursor): TCssValue;
{ none | one to three numbers or percentages }
function ParseScaleProperty(var Cursor: TCssTokenCursor): TCssValue;

implementation

uses
  Css.Atoms, Css.Keywords, Css.Units, Css.ValueParser;

type
  TArgumentKind = (akLengthPercentage, akLength, akNumber, akNumberPercentage, akAngle, akAngleOrZero,
    akLengthOrNone);

function ParseArgument(var Cursor: TCssTokenCursor; Kind: TArgumentKind): TCssValue;
begin
  case Kind of
    akLengthPercentage: Result := ParseLengthPercentage(Cursor);
    akLength: Result := ParseLength(Cursor);
    akNumber: Result := ParseNumber(Cursor);
    akNumberPercentage:
      begin
        Result := ParseNumber(Cursor);
        if Result = nil then
          Result := ParsePercentage(Cursor);
      end;
    akAngle: Result := ParseAngle(Cursor, False);
    akAngleOrZero: Result := ParseAngle(Cursor, True);
    akLengthOrNone:
      begin
        Result := ParseKeyword(Cursor, [kwNone]);
        if Result = nil then
          Result := ParseLength(Cursor, True);
      end;
  else
    Result := nil;
  end;
end;

{ Arguments of the given kinds separated by commas; Minimum of them required. }
function ParseArguments(Contents: TCssTokenCursor; const Kinds: array of TArgumentKind; Minimum: Integer;
  Target: TCssValue): Boolean;
var
  Index: Integer;
  Argument: TCssValue;
begin
  Result := False;
  for Index := 0 to High(Kinds) do
  begin
    if Index > 0 then
    begin
      if Contents.AtEndIgnoringWhitespace and (Index >= Minimum) then
        Break;
      if not SkipComma(Contents) then
        Exit;
    end;
    Argument := ParseArgument(Contents, Kinds[Index]);
    if Argument = nil then
      Exit;
    Target.Add(Argument);
  end;
  Result := Contents.AtEndIgnoringWhitespace;
end;

function ParseRepeated(Contents: TCssTokenCursor; Kind: TArgumentKind; Count: Integer; Target: TCssValue): Boolean;
var
  Kinds: array of TArgumentKind;
  Index: Integer;
begin
  SetLength(Kinds, Count);
  for Index := 0 to Count - 1 do
    Kinds[Index] := Kind;
  Result := ParseArguments(Contents, Kinds, Count, Target);
end;

function ParseTransformFunction(var Cursor: TCssTokenCursor): TCssValue;
var
  Saved: Integer;
  Token: PCssToken;
  Name: string;
  Contents: TCssTokenCursor;
  Valid: Boolean;
begin
  Result := nil;
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  if Token^.Kind <> tkFunction then
    Exit;
  Cursor.Next;
  Contents := Cursor.Contents(Token);
  Name := AsciiLowercase(Token^.Text);
  Result := NewFunction(Name);
  if Name = 'matrix' then Valid := ParseRepeated(Contents, akNumber, 6, Result)
  else if Name = 'matrix3d' then Valid := ParseRepeated(Contents, akNumber, 16, Result)
  else if Name = 'translate' then Valid := ParseArguments(Contents, [akLengthPercentage, akLengthPercentage], 1, Result)
  else if (Name = 'translatex') or (Name = 'translatey') then
    Valid := ParseArguments(Contents, [akLengthPercentage], 1, Result)
  else if Name = 'translatez' then Valid := ParseArguments(Contents, [akLength], 1, Result)
  else if Name = 'translate3d' then
    Valid := ParseArguments(Contents, [akLengthPercentage, akLengthPercentage, akLength], 3, Result)
  else if Name = 'scale' then Valid := ParseArguments(Contents, [akNumberPercentage, akNumberPercentage], 1, Result)
  else if (Name = 'scalex') or (Name = 'scaley') or (Name = 'scalez') then
    Valid := ParseArguments(Contents, [akNumberPercentage], 1, Result)
  else if Name = 'scale3d' then Valid := ParseRepeated(Contents, akNumberPercentage, 3, Result)
  else if (Name = 'rotate') or (Name = 'rotatex') or (Name = 'rotatey') or (Name = 'rotatez') then
    Valid := ParseArguments(Contents, [akAngleOrZero], 1, Result)
  else if Name = 'rotate3d' then
    Valid := ParseArguments(Contents, [akNumber, akNumber, akNumber, akAngleOrZero], 4, Result)
  else if Name = 'skew' then Valid := ParseArguments(Contents, [akAngleOrZero, akAngleOrZero], 1, Result)
  else if (Name = 'skewx') or (Name = 'skewy') then Valid := ParseArguments(Contents, [akAngleOrZero], 1, Result)
  else if Name = 'perspective' then Valid := ParseArguments(Contents, [akLengthOrNone], 1, Result)
  else
    Valid := False;
  if not Valid then
  begin
    ReleaseValue(Result);
    Cursor.Position := Saved;
  end;
end;

function ParseTransformList(var Cursor: TCssTokenCursor): TCssValue;
var
  Item: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNone]);
  if Result <> nil then
    Exit;
  Result := NewList(lsSpace);
  repeat
    Item := ParseTransformFunction(Cursor);
    if Item = nil then
      Break;
    Result.Add(Item);
  until False;
  if Result.Count = 0 then
    ReleaseValue(Result);
end;

function ParseTranslateProperty(var Cursor: TCssTokenCursor): TCssValue;
var
  Item: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNone]);
  if Result <> nil then
    Exit;
  Item := ParseLengthPercentage(Cursor);
  if Item = nil then
    Exit;
  Result := NewListOf(lsSpace, [Item]);
  Item := ParseLengthPercentage(Cursor);
  if Item <> nil then
  begin
    Result.Add(Item);
    Item := ParseLength(Cursor);
    if Item <> nil then
      Result.Add(Item);
  end;
end;

function ParseRotateProperty(var Cursor: TCssTokenCursor): TCssValue;
var
  Angle, Axis, Number: TCssValue;
  Index: Integer;
begin
  Result := ParseKeyword(Cursor, [kwNone]);
  if Result <> nil then
    Exit;
  Angle := ParseAngle(Cursor, True);
  Axis := ParseKeyword(Cursor, [kwX, kwY, kwZ]);
  if Axis = nil then
  begin
    Number := ParseNumber(Cursor);
    if Number <> nil then
    begin
      Axis := NewListOf(lsSpace, [Number]);
      for Index := 1 to 2 do
      begin
        Number := ParseNumber(Cursor);
        if Number = nil then
        begin
          Axis.Release;
          ReleaseValue(Angle);
          Exit;
        end;
        Axis.Add(Number);
      end;
    end;
  end;
  if Angle = nil then
    Angle := ParseAngle(Cursor, True);
  if Angle = nil then
  begin
    ReleaseValue(Axis);
    Exit;
  end;
  if Axis = nil then
    Exit(Angle);
  Result := NewListOf(lsSpace, [Axis, Angle]);
end;

function ParseScaleProperty(var Cursor: TCssTokenCursor): TCssValue;
var
  Item: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNone]);
  if Result <> nil then
    Exit;
  Result := NewList(lsSpace);
  while Result.Count < 3 do
  begin
    Item := ParseNumber(Cursor);
    if Item = nil then
      Item := ParsePercentage(Cursor);
    if Item = nil then
      Break;
    Result.Add(Item);
  end;
  if Result.Count = 0 then
    ReleaseValue(Result);
end;

end.
