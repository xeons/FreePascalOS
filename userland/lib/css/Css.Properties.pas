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
  Looking properties up: names (with the legacy aliases), table rows,
  where each longhand's computed value lives (its group and slot), and
  the logical properties' mapping to physical ones.
}
unit Css.Properties;

{$mode objfpc}
{$H+}

interface

uses
  Css.PropertyIds;

type
  TCssWritingMode = (wmHorizontalTb, wmVerticalRl, wmVerticalLr, wmSidewaysRl, wmSidewaysLr);

  { The four sides in logical terms. }
  TCssLogicalSide = (lsBlockStart, lsBlockEnd, lsInlineStart, lsInlineEnd);
  TCssPhysicalSide = (psTop, psRight, psBottom, psLeft);

function PropertyName(Id: TCssPropertyId): string;
{ The property a (case-insensitive) name stands for; cpCustom for
  "--name", cpInvalid for unknown names. }
function PropertyByName(const Name: string): TCssPropertyId;
function PropertyInfo(Id: TCssPropertyId): TCssPropertyInfo;
function PropertyGroup(Id: TCssPropertyId): TCssPropertyGroup;
function IsInheritedProperty(Id: TCssPropertyId): Boolean;
{ A longhand's slot within its group's struct. }
function PropertySlot(Id: TCssPropertyId): Integer;
{ The number of properties stored in a group. }
function GroupSize(Group: TCssPropertyGroup): Integer;
{ The property stored in a group's slot. }
function PropertyAtSlot(Group: TCssPropertyGroup; Slot: Integer): TCssPropertyId;
function IsCustomPropertyName(const Name: string): Boolean;

{ The physical side a logical side is in a writing mode and direction. }
function PhysicalSide(Side: TCssLogicalSide; WritingMode: TCssWritingMode; RightToLeft: Boolean): TCssPhysicalSide;
{ The physical property a logical longhand stands for. }
function PhysicalProperty(Id: TCssPropertyId; WritingMode: TCssWritingMode; RightToLeft: Boolean): TCssPropertyId;

implementation

uses
  TypInfo, Css.Atoms, Css.PropertyTable;

var
  Names: array[TCssPropertyId] of string;
  SortedNames: array of string;
  SortedIds: array of TCssPropertyId;
  Slots: array[TCssPropertyId] of Integer;
  GroupSizes: array[TCssPropertyGroup] of Integer;
  SlotProperties: array[TCssPropertyGroup] of array of TCssPropertyId;

function KebabName(const Identifier: string): string;
var
  Index: Integer;
  Character: Char;
begin
  Result := '';
  for Index := 3 to Length(Identifier) do
  begin
    Character := Identifier[Index];
    if Character in ['A'..'Z'] then
    begin
      if Result <> '' then
        Result := Result + '-';
      Result := Result + Chr(Ord(Character) + 32);
    end
    else
      Result := Result + Character;
  end;
end;

function PropertyName(Id: TCssPropertyId): string;
begin
  Result := Names[Id];
end;

function IsCustomPropertyName(const Name: string): Boolean;
begin
  Result := (Length(Name) > 2) and (Name[1] = '-') and (Name[2] = '-');
end;

function Alias(const Lower: string): TCssPropertyId;
begin
  if Lower = 'word-wrap' then Result := cpOverflowWrap
  else if Lower = 'grid-gap' then Result := cpGap
  else if Lower = 'grid-row-gap' then Result := cpRowGap
  else if Lower = 'grid-column-gap' then Result := cpColumnGap
  else if Lower = 'font-width' then Result := cpFontStretch
  else if Lower = '-webkit-appearance' then Result := cpAppearance
  else if Lower = '-webkit-box-sizing' then Result := cpBoxSizing
  else if Lower = '-webkit-transform' then Result := cpTransform
  else if Lower = '-webkit-transform-origin' then Result := cpTransformOrigin
  else if Lower = '-webkit-transition' then Result := cpTransition
  else if Lower = '-webkit-animation' then Result := cpAnimation
  else if Lower = '-webkit-user-select' then Result := cpUserSelect
  else if Lower = '-webkit-flex' then Result := cpFlex
  else if Lower = '-webkit-border-radius' then Result := cpBorderRadius
  else if Lower = '-webkit-box-shadow' then Result := cpBoxShadow
  else if Lower = '-webkit-filter' then Result := cpFilter
  else if Lower = '-webkit-backdrop-filter' then Result := cpBackdropFilter
  else if Lower = '-webkit-mask-image' then Result := cpMaskImage
  else if Lower = '-webkit-mask-position' then Result := cpMaskPosition
  else if Lower = '-webkit-mask-position-x' then Result := cpMaskPositionX
  else if Lower = '-webkit-mask-position-y' then Result := cpMaskPositionY
  else if Lower = '-webkit-mask-size' then Result := cpMaskSize
  else if Lower = '-webkit-mask-repeat' then Result := cpMaskRepeat
  else if Lower = '-webkit-mask-origin' then Result := cpMaskOrigin
  else if Lower = '-webkit-mask-clip' then Result := cpMaskClip
  else if Lower = '-webkit-mask' then Result := cpMask
  else
    Result := cpInvalid;
end;

function PropertyByName(const Name: string): TCssPropertyId;
var
  Lower: string;
  Low, High, Middle: Integer;
begin
  if IsCustomPropertyName(Name) then
    Exit(cpCustom);
  Lower := AsciiLowercase(Name);
  Low := 0;
  High := System.High(SortedNames);
  while Low <= High do
  begin
    Middle := (Low + High) div 2;
    if SortedNames[Middle] = Lower then
      Exit(SortedIds[Middle]);
    if SortedNames[Middle] < Lower then
      Low := Middle + 1
    else
      High := Middle - 1;
  end;
  Result := Alias(Lower);
end;

function PropertyInfo(Id: TCssPropertyId): TCssPropertyInfo;
begin
  Result := PropertyTable[Id];
end;

function PropertyGroup(Id: TCssPropertyId): TCssPropertyGroup;
begin
  Result := PropertyTable[Id].Group;
end;

function IsInheritedProperty(Id: TCssPropertyId): Boolean;
begin
  Result := PropertyTable[Id].Group in InheritedGroups;
end;

function PropertySlot(Id: TCssPropertyId): Integer;
begin
  Result := Slots[Id];
end;

function GroupSize(Group: TCssPropertyGroup): Integer;
begin
  Result := GroupSizes[Group];
end;

function PropertyAtSlot(Group: TCssPropertyGroup; Slot: Integer): TCssPropertyId;
begin
  Result := SlotProperties[Group][Slot];
end;

function PhysicalSide(Side: TCssLogicalSide; WritingMode: TCssWritingMode; RightToLeft: Boolean): TCssPhysicalSide;
begin
  case WritingMode of
    wmHorizontalTb:
      case Side of
        lsBlockStart: Result := psTop;
        lsBlockEnd: Result := psBottom;
        lsInlineStart: if RightToLeft then Result := psRight else Result := psLeft;
      else
        if RightToLeft then Result := psLeft else Result := psRight;
      end;
    wmVerticalRl, wmSidewaysRl:
      case Side of
        lsBlockStart: Result := psRight;
        lsBlockEnd: Result := psLeft;
        lsInlineStart: if RightToLeft then Result := psBottom else Result := psTop;
      else
        if RightToLeft then Result := psTop else Result := psBottom;
      end;
    wmVerticalLr:
      case Side of
        lsBlockStart: Result := psLeft;
        lsBlockEnd: Result := psRight;
        lsInlineStart: if RightToLeft then Result := psBottom else Result := psTop;
      else
        if RightToLeft then Result := psTop else Result := psBottom;
      end;
  else
    { sideways-lr: the inline direction runs bottom to top }
    case Side of
      lsBlockStart: Result := psLeft;
      lsBlockEnd: Result := psRight;
      lsInlineStart: if RightToLeft then Result := psTop else Result := psBottom;
    else
      if RightToLeft then Result := psBottom else Result := psTop;
    end;
  end;
end;

function SideProperty(First: TCssPropertyId; Side: TCssPhysicalSide): TCssPropertyId;
begin
  { First is the property for the top; right, bottom and left follow. }
  Result := TCssPropertyId(Ord(First) + Ord(Side));
end;

function PhysicalProperty(Id: TCssPropertyId; WritingMode: TCssWritingMode; RightToLeft: Boolean): TCssPropertyId;
var
  Side: TCssLogicalSide;
  Vertical: Boolean;
  StartSide, EndSide: TCssPhysicalSide;
  BlockStart, InlineStart: TCssPhysicalSide;
begin
  Vertical := WritingMode <> wmHorizontalTb;
  case Id of
    cpMarginBlockStart..cpBorderInlineEndColor:
      begin
        Side := TCssLogicalSide((Ord(Id) - Ord(cpMarginBlockStart)) mod 4);
        case (Ord(Id) - Ord(cpMarginBlockStart)) div 4 of
          0: Result := SideProperty(cpMarginTop, PhysicalSide(Side, WritingMode, RightToLeft));
          1: Result := SideProperty(cpPaddingTop, PhysicalSide(Side, WritingMode, RightToLeft));
          2: Result := SideProperty(cpTop, PhysicalSide(Side, WritingMode, RightToLeft));
          3: Result := SideProperty(cpBorderTopWidth, PhysicalSide(Side, WritingMode, RightToLeft));
          4: Result := SideProperty(cpBorderTopStyle, PhysicalSide(Side, WritingMode, RightToLeft));
        else
          Result := SideProperty(cpBorderTopColor, PhysicalSide(Side, WritingMode, RightToLeft));
        end;
      end;
    cpInlineSize: if Vertical then Result := cpHeight else Result := cpWidth;
    cpBlockSize: if Vertical then Result := cpWidth else Result := cpHeight;
    cpMinInlineSize: if Vertical then Result := cpMinHeight else Result := cpMinWidth;
    cpMinBlockSize: if Vertical then Result := cpMinWidth else Result := cpMinHeight;
    cpMaxInlineSize: if Vertical then Result := cpMaxHeight else Result := cpMaxWidth;
    cpMaxBlockSize: if Vertical then Result := cpMaxWidth else Result := cpMaxHeight;
    cpBorderStartStartRadius, cpBorderStartEndRadius, cpBorderEndStartRadius, cpBorderEndEndRadius:
      begin
        { border-<block>-<inline>-radius }
        if (Id = cpBorderStartStartRadius) or (Id = cpBorderStartEndRadius) then
          BlockStart := PhysicalSide(lsBlockStart, WritingMode, RightToLeft)
        else
          BlockStart := PhysicalSide(lsBlockEnd, WritingMode, RightToLeft);
        if (Id = cpBorderStartStartRadius) or (Id = cpBorderEndStartRadius) then
          InlineStart := PhysicalSide(lsInlineStart, WritingMode, RightToLeft)
        else
          InlineStart := PhysicalSide(lsInlineEnd, WritingMode, RightToLeft);
        { Order the two sides as vertical (top/bottom) then horizontal. }
        if BlockStart in [psTop, psBottom] then
        begin
          StartSide := BlockStart;
          EndSide := InlineStart;
        end
        else
        begin
          StartSide := InlineStart;
          EndSide := BlockStart;
        end;
        if StartSide = psTop then
        begin
          if EndSide = psLeft then Result := cpBorderTopLeftRadius else Result := cpBorderTopRightRadius;
        end
        else if EndSide = psLeft then
          Result := cpBorderBottomLeftRadius
        else
          Result := cpBorderBottomRightRadius;
      end;
  else
    Result := Id;
  end;
end;

procedure Initialize;
var
  Id: TCssPropertyId;
  Count, Index, Other: Integer;
  SwapName: string;
  SwapId: TCssPropertyId;
  Group: TCssPropertyGroup;
begin
  Count := 0;
  SetLength(SortedNames, Ord(High(TCssPropertyId)) + 1);
  SetLength(SortedIds, Length(SortedNames));
  for Id := Succ(cpInvalid) to Pred(cpCustom) do
  begin
    Names[Id] := KebabName(GetEnumName(TypeInfo(TCssPropertyId), Ord(Id)));
    { cpWebkitLineClamp is -webkit-line-clamp. }
    if Copy(Names[Id], 1, 7) = 'webkit-' then
      Names[Id] := '-' + Names[Id];
    SortedNames[Count] := Names[Id];
    SortedIds[Count] := Id;
    Inc(Count);
  end;
  SetLength(SortedNames, Count);
  SetLength(SortedIds, Count);
  { Insertion sort: a few hundred names, once. }
  for Index := 1 to Count - 1 do
  begin
    Other := Index;
    while (Other > 0) and (SortedNames[Other - 1] > SortedNames[Other]) do
    begin
      SwapName := SortedNames[Other - 1];
      SortedNames[Other - 1] := SortedNames[Other];
      SortedNames[Other] := SwapName;
      SwapId := SortedIds[Other - 1];
      SortedIds[Other - 1] := SortedIds[Other];
      SortedIds[Other] := SwapId;
      Dec(Other);
    end;
  end;
  for Group := Low(TCssPropertyGroup) to High(TCssPropertyGroup) do
    GroupSizes[Group] := 0;
  for Id := Low(TCssPropertyId) to High(TCssPropertyId) do
  begin
    Slots[Id] := -1;
    Group := PropertyTable[Id].Group;
    if Group = pgNone then
      Continue;
    Slots[Id] := GroupSizes[Group];
    SetLength(SlotProperties[Group], GroupSizes[Group] + 1);
    SlotProperties[Group][GroupSizes[Group]] := Id;
    Inc(GroupSizes[Group]);
  end;
end;

initialization
  Initialize;
end.
