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
    { The shadow tree nesting of the tree the declarations come from
      (0: the document; CSS Cascade 5's context: for normal declarations
      the outer tree wins, for important ones the inner). }
    ShadowDepth: Word;
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
  Origin: TCssOrigin; ElementAttached: Boolean; LayerRank: Word; Specificity: LongWord; Order: LongInt;
  ShadowDepth: Word = 0);
{ Cascades Items[0..Count - 1] (reordered by priority on the way). The
  parent's writing mode and direction are what 'inherit' gives them. }
procedure RunCascade(var Items: TCssCascadeItemArray; Count: Integer; ParentWritingMode: TCssWritingMode;
  ParentRightToLeft: Boolean; out Cascaded: TCssCascadedValues);
function HigherPriority(const A, B: TCssCascadeItem): Boolean;

implementation

uses
  Css.Keywords, Css.PointerMaps;

procedure AddCascadeBlock(var Items: TCssCascadeItemArray; var Count: Integer; Block: TCssDeclarationBlock;
  Origin: TCssOrigin; ElementAttached: Boolean; LayerRank: Word; Specificity: LongWord; Order: LongInt;
  ShadowDepth: Word);

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
    Items[Count].ShadowDepth := ShadowDepth;
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
  if A.ShadowDepth <> B.ShadowDepth then
  begin
    if A.Important then
      Exit(A.ShadowDepth > B.ShadowDepth)
    else
      Exit(A.ShadowDepth < B.ShadowDepth);
  end;
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

type
  { HigherPriority as two numbers, the larger the higher: the origin
    and importance tier, the shadow tree context, element-attached,
    the layer and the specificity packed into Major, order of
    appearance in Minor. }
  TPriorityKey = record
    Major: QWord;
    Minor: Int64;
  end;
  TPriorityKeyArray = array of TPriorityKey;

function PriorityKey(const Item: TCssCascadeItem): TPriorityKey; inline;
var
  ShadowRank, LayerRank: QWord;
begin
  if Item.Important then
  begin
    ShadowRank := Item.ShadowDepth;
    LayerRank := High(Word) - Item.LayerRank;
  end
  else
  begin
    ShadowRank := High(Word) - Item.ShadowDepth;
    LayerRank := Item.LayerRank;
  end;
  Result.Major := (QWord(Tier(Item)) shl 61) or (ShadowRank shl 45) or (QWord(Ord(Item.ElementAttached)) shl 44) or
    (LayerRank shl 28) or (QWord(Item.Specificity) and $0FFFFFFF);
  Result.Minor := Item.Order;
end;

function KeyAbove(const A, B: TPriorityKey): Boolean; inline;
begin
  Result := (A.Major > B.Major) or ((A.Major = B.Major) and (A.Minor > B.Minor));
end;

{ Specificities this large (over 255 ids, classes or types) do not fit
  the packed key: compared field by field. }
function KeysFit(const Items: TCssCascadeItemArray; Count: Integer): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    if Items[Index].Specificity > $0FFFFFFF then
      Exit(False);
  Result := True;
end;

procedure SortByPriority(var Items: TCssCascadeItemArray; Count: Integer);
var
  Index, Other: Integer;
  Item: TCssCascadeItem;
  Keys: array of TPriorityKey;
  Key: TPriorityKey;
begin
  if not KeysFit(Items, Count) then
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
    Exit;
  end;
  Keys := nil;
  SetLength(Keys, Count);
  for Index := 0 to Count - 1 do
    Keys[Index] := PriorityKey(Items[Index]);
  for Index := 1 to Count - 1 do
  begin
    Item := Items[Index];
    Key := Keys[Index];
    Other := Index - 1;
    while (Other >= 0) and KeyAbove(Key, Keys[Other]) do
    begin
      Items[Other + 1] := Items[Other];
      Keys[Other + 1] := Keys[Other];
      Dec(Other);
    end;
    Items[Other + 1] := Item;
    Keys[Other + 1] := Key;
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

  TPhysicalSkips = array[TCssPhysicalId] of TSkip;

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

type
  { The custom properties met so far while cascading one element: what
    'revert' skips for each and whether it is decided, and an index by
    name once there are many (a root declaring hundreds of variables
    would otherwise search them all for each declaration). }
  TCustomCascade = record
    Skips: array of TSkip;
    Decided: array of Boolean;
    Index: TCssPointerMap;
  end;

const
  { Names searched in order below this many, by the index above. }
  CustomIndexThreshold = 16;

{ The slot of custom property Name in Cascaded, added when new. }
function CustomSlot(var Cascaded: TCssCascadedValues; var Custom: TCustomCascade; Name: TCssAtom): Integer;
var
  Slot: PtrInt;
  Index: Integer;
begin
  if Custom.Index <> nil then
  begin
    if Custom.Index.TryGet(Pointer(PtrUInt(Name)), Slot) then
      Exit(Slot);
  end
  else
    for Index := 0 to Cascaded.CustomCount - 1 do
      if Cascaded.CustomNames[Index] = Name then
        Exit(Index);
  Result := Cascaded.CustomCount;
  Inc(Cascaded.CustomCount);
  if Cascaded.CustomCount > Length(Cascaded.CustomNames) then
  begin
    SetLength(Cascaded.CustomNames, Cascaded.CustomCount * 2 + 4);
    SetLength(Cascaded.CustomValues, Length(Cascaded.CustomNames));
    SetLength(Custom.Skips, Length(Cascaded.CustomNames));
    SetLength(Custom.Decided, Length(Cascaded.CustomNames));
  end;
  Cascaded.CustomNames[Result] := Name;
  Cascaded.CustomValues[Result] := nil;
  Custom.Skips[Result].Kind := skipNone;
  Custom.Decided[Result] := False;
  if Custom.Index <> nil then
    Custom.Index.Put(Pointer(PtrUInt(Name)), Result)
  else if Cascaded.CustomCount >= CustomIndexThreshold then
  begin
    Custom.Index := TCssPointerMap.Create;
    for Index := 0 to Cascaded.CustomCount - 1 do
      Custom.Index.Put(Pointer(PtrUInt(Cascaded.CustomNames[Index])), Index);
  end;
end;

{ Custom properties cascade by name. }
procedure CascadeCustom(var Cascaded: TCssCascadedValues; var Custom: TCustomCascade; const Item: TCssCascadeItem;
  Declaration: PCssDeclaration);
var
  Slot: Integer;
  Value: TCssValue;
begin
  Slot := CustomSlot(Cascaded, Custom, Declaration^.CustomName);
  if Custom.Decided[Slot] or Skipped(Custom.Skips[Slot], Item) then
    Exit;
  Value := Declaration^.Value;
  if Value.IsKeyword(kwRevert) then
    SetSkip(Custom.Skips[Slot], skipOrigin, Item)
  else if Value.IsKeyword(kwRevertLayer) then
    SetSkip(Custom.Skips[Slot], skipLayer, Item)
  else
  begin
    Cascaded.CustomValues[Slot] := Value;
    Custom.Decided[Slot] := True;
  end;
end;

{ A longhand (mapped to its physical property) unless decided already. }
procedure CascadeLonghand(var Cascaded: TCssCascadedValues; var Skips: TPhysicalSkips; const Item: TCssCascadeItem;
  Declaration: PCssDeclaration);
var
  Id: TCssPropertyId;
  Value: TCssValue;
begin
  Id := Declaration^.Id;
  if IsLogical(Id) then
    Id := PhysicalProperty(Id, Cascaded.WritingMode, Cascaded.RightToLeft);
  if (Id <= cpInvalid) or (Id > High(TCssPhysicalId)) then
    Exit;
  if (Cascaded.Values[Id] <> nil) or Skipped(Skips[Id], Item) then
    Exit;
  Value := Declaration^.Value;
  if Value.IsKeyword(kwRevert) then
    { The user agent origin has nothing below it: like unset. }
    SetSkip(Skips[Id], skipOrigin, Item)
  else if Value.IsKeyword(kwRevertLayer) then
    SetSkip(Skips[Id], skipLayer, Item)
  else
    Cascaded.Values[Id] := Value;
end;

{ Writing mode and direction first: logical properties need them. }
procedure CascadeWritingMode(const Items: TCssCascadeItemArray; Count: Integer; ParentWritingMode: TCssWritingMode;
  ParentRightToLeft: Boolean; var Cascaded: TCssCascadedValues);
begin
  Cascaded.WritingMode := WritingModeOf(FirstKeyword(Items, Count, cpWritingMode), ParentWritingMode);
  case FirstKeyword(Items, Count, cpDirection) of
    kwRtl: Cascaded.RightToLeft := True;
    kwLtr, kwInitial: Cascaded.RightToLeft := False;
  else
    Cascaded.RightToLeft := ParentRightToLeft;
  end;
end;

procedure RunCascade(var Items: TCssCascadeItemArray; Count: Integer; ParentWritingMode: TCssWritingMode;
  ParentRightToLeft: Boolean; out Cascaded: TCssCascadedValues);
var
  Skips: TPhysicalSkips;
  Custom: TCustomCascade;
  ItemIndex, DeclarationIndex: Integer;
  Item: ^TCssCascadeItem;
  Declaration: PCssDeclaration;
begin
  FillChar(Cascaded.Values, SizeOf(Cascaded.Values), 0);
  Cascaded.CustomNames := nil;
  Cascaded.CustomValues := nil;
  Cascaded.CustomCount := 0;
  FillChar(Skips, SizeOf(Skips), 0);
  Custom := Default(TCustomCascade);
  SortByPriority(Items, Count);
  CascadeWritingMode(Items, Count, ParentWritingMode, ParentRightToLeft, Cascaded);
  try
    for ItemIndex := 0 to Count - 1 do
    begin
      Item := @Items[ItemIndex];
      for DeclarationIndex := 0 to Item^.Block.Count - 1 do
      begin
        Declaration := Item^.Block.Item(DeclarationIndex);
        if Declaration^.Important <> Item^.Important then
          Continue;
        if Declaration^.Id = cpCustom then
          CascadeCustom(Cascaded, Custom, Item^, Declaration)
        else
          CascadeLonghand(Cascaded, Skips, Item^, Declaration);
      end;
    end;
  finally
    Custom.Index.Free;
  end;
end;

end.
