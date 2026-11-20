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
  The cascade (CSS Cascading and Inheritance Level 5): from the
  declaration blocks that apply to an element to one cascaded value
  per property.

  Each applying block takes part with its normal declarations and with
  its important ones. They are ordered by origin and importance (user
  agent, user, author normal; then author, user, user agent important),
  then element-attached declarations (the style attribute) over rules,
  then cascade layer (later layers win for normal declarations, earlier
  ones for important declarations), then specificity, then order of
  appearance. Walking them from the highest priority down, the first
  declaration of a property wins; 'revert' skips the rest of its origin
  and 'revert-layer' the rest of its layer.

  Logical properties are mapped to physical ones with the element's
  writing mode and direction, which are cascaded first.
}
unit Css.Cascade;

{$mode objfpc}
{$H+}

interface

uses
  Css.Atoms, Css.Values, Css.PropertyIds, Css.Properties, Css.Declarations, Css.Stylesheets;

type
  TCssCascadeItem = record
    Block: TCssDeclarationBlock;
    Important: Boolean;
    Origin: TCssOrigin;
    ElementAttached: Boolean;
    LayerRank: Word;
    Specificity: LongWord;
    Order: LongInt;
  end;
  TCssCascadeItemArray = array of TCssCascadeItem;

  TCssCascadedValues = record
    Values: array[TCssPhysicalId] of TCssValue;
    CustomNames: array of TCssAtom;
    CustomValues: array of TCssValue;
    CustomCount: Integer;
    WritingMode: TCssWritingMode;
    RightToLeft: Boolean;
  end;

{ Adds a block's normal and important declarations as cascade items. }
procedure AddCascadeBlock(var Items: TCssCascadeItemArray; var Count: Integer; Block: TCssDeclarationBlock;
  Origin: TCssOrigin; ElementAttached: Boolean; LayerRank: Word; Specificity: LongWord; Order: LongInt);
{ Cascades Items[0..Count - 1] (reordered by priority on the way). The
  parent's writing mode and direction are what 'inherit' gives them. }
procedure RunCascade(var Items: TCssCascadeItemArray; Count: Integer; ParentWritingMode: TCssWritingMode;
  ParentRightToLeft: Boolean; out Cascaded: TCssCascadedValues);
function HigherPriority(const A, B: TCssCascadeItem): Boolean;

implementation

uses
  Css.Keywords;

procedure AddCascadeBlock(var Items: TCssCascadeItemArray; var Count: Integer; Block: TCssDeclarationBlock;
  Origin: TCssOrigin; ElementAttached: Boolean; LayerRank: Word; Specificity: LongWord; Order: LongInt);

  procedure Add(Important: Boolean);
  begin
    if Count >= Length(Items) then
      SetLength(Items, Count * 2 + 16);
    Items[Count].Block := Block;
    Items[Count].Important := Important;
    Items[Count].Origin := Origin;
    Items[Count].ElementAttached := ElementAttached;
    Items[Count].LayerRank := LayerRank;
    Items[Count].Specificity := Specificity;
    Items[Count].Order := Order;
    Inc(Count);
  end;

begin
  if (Block = nil) or (Block.Count = 0) then
    Exit;
  if Block.HasNormal then
    Add(False);
  if Block.HasImportant then
    Add(True);
end;

function Tier(const Item: TCssCascadeItem): Integer; inline;
begin
  if Item.Important then
    Result := 5 - Ord(Item.Origin)
  else
    Result := Ord(Item.Origin);
end;

function HigherPriority(const A, B: TCssCascadeItem): Boolean;
var
  TierA, TierB: Integer;
begin
  TierA := Tier(A);
  TierB := Tier(B);
  if TierA <> TierB then
    Exit(TierA > TierB);
  if A.ElementAttached <> B.ElementAttached then
    Exit(A.ElementAttached);
  if A.LayerRank <> B.LayerRank then
  begin
    if A.Important then
      Exit(A.LayerRank < B.LayerRank)
    else
      Exit(A.LayerRank > B.LayerRank);
  end;
  if A.Specificity <> B.Specificity then
    Exit(A.Specificity > B.Specificity);
  Result := A.Order > B.Order;
end;

procedure SortByPriority(var Items: TCssCascadeItemArray; Count: Integer);
var
  Index, Other: Integer;
  Item: TCssCascadeItem;
begin
  for Index := 1 to Count - 1 do
  begin
    Item := Items[Index];
    Other := Index - 1;
    while (Other >= 0) and HigherPriority(Item, Items[Other]) do
    begin
      Items[Other + 1] := Items[Other];
      Dec(Other);
    end;
    Items[Other + 1] := Item;
  end;
end;

type
  TSkipKind = (skipNone, skipOrigin, skipLayer);
  TSkip = record
    Kind: TSkipKind;
    Origin: TCssOrigin;
    Important: Boolean;
    ElementAttached: Boolean;
    LayerRank: Word;
  end;

function Skipped(const Skip: TSkip; const Item: TCssCascadeItem): Boolean; inline;
begin
  case Skip.Kind of
    skipOrigin: Result := Item.Origin = Skip.Origin;
    skipLayer:
      Result := (Item.Origin = Skip.Origin) and (Item.Important = Skip.Important) and
        (Item.LayerRank = Skip.LayerRank) and (Item.ElementAttached = Skip.ElementAttached);
  else
    Result := False;
  end;
end;

procedure SetSkip(var Skip: TSkip; Kind: TSkipKind; const Item: TCssCascadeItem);
begin
  Skip.Kind := Kind;
  Skip.Origin := Item.Origin;
  Skip.Important := Item.Important;
  Skip.ElementAttached := Item.ElementAttached;
  Skip.LayerRank := Item.LayerRank;
end;

function WritingModeOf(Keyword: TCssKeyword; Parent: TCssWritingMode): TCssWritingMode;
begin
  case Keyword of
    kwHorizontalTb: Result := wmHorizontalTb;
    kwVerticalRl: Result := wmVerticalRl;
    kwVerticalLr: Result := wmVerticalLr;
    kwSidewaysRl: Result := wmSidewaysRl;
    kwSidewaysLr: Result := wmSidewaysLr;
    kwInitial: Result := wmHorizontalTb;
  else
    Result := Parent;
  end;
end;

{ The winning keyword of one property among the items, kwInvalid if none. }
function FirstKeyword(const Items: TCssCascadeItemArray; Count: Integer; Id: TCssPropertyId): TCssKeyword;
var
  Index: Integer;
  Declaration: PCssDeclaration;
begin
  for Index := 0 to Count - 1 do
  begin
    Declaration := Items[Index].Block.Find(Id);
    if (Declaration <> nil) and (Declaration^.Important = Items[Index].Important) then
    begin
      if Declaration^.Value.Kind = vkKeyword then
        Exit(Declaration^.Value.Keyword);
      Exit(kwInherit);
    end;
  end;
  Result := kwInvalid;
end;

procedure RunCascade(var Items: TCssCascadeItemArray; Count: Integer; ParentWritingMode: TCssWritingMode;
  ParentRightToLeft: Boolean; out Cascaded: TCssCascadedValues);
var
  Skips: array[TCssPhysicalId] of TSkip;
  CustomSkips: array of TSkip;
  CustomDecided: array of Boolean;
  ItemIndex, DeclarationIndex, CustomIndex: Integer;
  Item: ^TCssCascadeItem;
  Declaration: PCssDeclaration;
  Id: TCssPropertyId;
  Value: TCssValue;
  Keyword: TCssKeyword;
  Found: Boolean;
begin
  FillChar(Cascaded.Values, SizeOf(Cascaded.Values), 0);
  Cascaded.CustomNames := nil;
  Cascaded.CustomValues := nil;
  Cascaded.CustomCount := 0;
  FillChar(Skips, SizeOf(Skips), 0);
  CustomSkips := nil;
  CustomDecided := nil;
  SortByPriority(Items, Count);
  { Writing mode and direction first: logical properties need them. }
  Keyword := FirstKeyword(Items, Count, cpWritingMode);
  Cascaded.WritingMode := WritingModeOf(Keyword, ParentWritingMode);
  Keyword := FirstKeyword(Items, Count, cpDirection);
  case Keyword of
    kwRtl: Cascaded.RightToLeft := True;
    kwLtr, kwInitial: Cascaded.RightToLeft := False;
  else
    Cascaded.RightToLeft := ParentRightToLeft;
  end;
  for ItemIndex := 0 to Count - 1 do
  begin
    Item := @Items[ItemIndex];
    for DeclarationIndex := 0 to Item^.Block.Count - 1 do
    begin
      Declaration := Item^.Block.Item(DeclarationIndex);
      if Declaration^.Important <> Item^.Important then
        Continue;
      Value := Declaration^.Value;
      Id := Declaration^.Id;
      if Id = cpCustom then
      begin
        { Custom properties cascade by name. }
        Found := False;
        for CustomIndex := 0 to Cascaded.CustomCount - 1 do
          if Cascaded.CustomNames[CustomIndex] = Declaration^.CustomName then
          begin
            Found := True;
            Break;
          end;
        if not Found then
        begin
          CustomIndex := Cascaded.CustomCount;
          Inc(Cascaded.CustomCount);
          SetLength(Cascaded.CustomNames, Cascaded.CustomCount);
          SetLength(Cascaded.CustomValues, Cascaded.CustomCount);
          SetLength(CustomSkips, Cascaded.CustomCount);
          SetLength(CustomDecided, Cascaded.CustomCount);
          Cascaded.CustomNames[CustomIndex] := Declaration^.CustomName;
          Cascaded.CustomValues[CustomIndex] := nil;
          CustomSkips[CustomIndex].Kind := skipNone;
          CustomDecided[CustomIndex] := False;
        end;
        if CustomDecided[CustomIndex] or Skipped(CustomSkips[CustomIndex], Item^) then
          Continue;
        if Value.IsKeyword(kwRevert) then
          SetSkip(CustomSkips[CustomIndex], skipOrigin, Item^)
        else if Value.IsKeyword(kwRevertLayer) then
          SetSkip(CustomSkips[CustomIndex], skipLayer, Item^)
        else
        begin
          Cascaded.CustomValues[CustomIndex] := Value;
          CustomDecided[CustomIndex] := True;
        end;
        Continue;
      end;
      if IsLogical(Id) then
        Id := PhysicalProperty(Id, Cascaded.WritingMode, Cascaded.RightToLeft);
      if (Id <= cpInvalid) or (Id > High(TCssPhysicalId)) then
        Continue;
      if (Cascaded.Values[Id] <> nil) or Skipped(Skips[Id], Item^) then
        Continue;
      if Value.IsKeyword(kwRevert) then
      begin
        { The user agent origin has nothing below it: like unset. }
        SetSkip(Skips[Id], skipOrigin, Item^);
        Continue;
      end;
      if Value.IsKeyword(kwRevertLayer) then
      begin
        SetSkip(Skips[Id], skipLayer, Item^);
        Continue;
      end;
      Cascaded.Values[Id] := Value;
    end;
  end;
end;

end.
