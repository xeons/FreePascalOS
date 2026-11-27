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
  What each group of a display list draws: for every push item, the
  bounds (document CSS pixels, in the coordinates of the push) of the
  ink of the items up to its matching pop, so that the rasterizer can
  make a group's surface only as big as its content, not as its clip
  (as Gecko and WebRender size their layers).

  An item's ink is its bounds, widened where drawing reaches beyond
  them: a shadow by its blur, text by its font size (glyphs overhang
  their line box). A nested group adds what shows of it: a clip's
  content within the clip's rectangle (the clip's rectangle when the
  content is not known), a transform's bounds through the transform, a
  filter's content as far around as its blurs reach. A fixed or sticky
  subtree (drawn at another origin) makes a group's extent unknown;
  the rasterizer then uses the clip.

  Worked out once per list revision, when it is first painted.
}
unit Web.Paint.GroupExtents;

{$mode objfpc}
{$H+}

interface

uses
  Web.Paint.DisplayList;

{ The list's GroupExtents, worked out if the list changed since. }
procedure EnsureGroupExtents(List: TDisplayList);

implementation

uses
  Math, Css.TransformMatrices, Web.Paint.Filters;

function EmptyExtent: TGroupExtent;
begin
  Result.Left := Infinity;
  Result.Top := Infinity;
  Result.Right := -Infinity;
  Result.Bottom := -Infinity;
  Result.Bounded := True;
  Result.PopIndex := -1;
end;

function UnknownExtent: TGroupExtent;
begin
  Result := EmptyExtent;
  Result.Bounded := False;
end;

function ExtentIsEmpty(const Extent: TGroupExtent): Boolean;
begin
  Result := Extent.Bounded and ((Extent.Left >= Extent.Right) or (Extent.Top >= Extent.Bottom));
end;

procedure IncludeRectangle(var Extent: TGroupExtent; Left, Top, Right, Bottom: Single);
begin
  if (Left >= Right) or (Top >= Bottom) then
    Exit;
  Extent.Left := Min(Extent.Left, Left);
  Extent.Top := Min(Extent.Top, Top);
  Extent.Right := Max(Extent.Right, Right);
  Extent.Bottom := Max(Extent.Bottom, Bottom);
end;

{ Extent takes in Part (what a nested group or an item draws). }
procedure IncludeExtent(var Extent: TGroupExtent; const Part: TGroupExtent);
begin
  if not Part.Bounded then
    Extent.Bounded := False
  else if not ExtentIsEmpty(Part) then
    IncludeRectangle(Extent, Part.Left, Part.Top, Part.Right, Part.Bottom);
end;

{ How far an item's drawing reaches beyond its bounds (CSS px). }
function InkMargin(List: TDisplayList; const Item: TDisplayItem): Single;
begin
  Result := 0;
  case Item.Kind of
    diShadow:
      Result := List.Shadows[Item.Index].Blur;
    diText:
      if List.Texts[Item.Index].Font <> nil then
        Result := List.Texts[Item.Index].Font.Size;
  end;
end;

function ItemExtent(List: TDisplayList; const Item: TDisplayItem): TGroupExtent;
var
  Margin: Single;
begin
  Result := EmptyExtent;
  if Item.Kind = diHitArea then
    Exit;
  Margin := InkMargin(List, Item);
  IncludeRectangle(Result, Item.X - Margin, Item.Y - Margin, Item.X + Item.Width + Margin,
    Item.Y + Item.Height + Margin);
end;

{ A transform group shows its bounds (what it draws, untransformed)
  through its matrix. }
function TransformedExtent(List: TDisplayList; const Item: TDisplayItem): TGroupExtent;
var
  Matrix: TCssMatrix2D;
  Corner: Integer;
  CornerX, CornerY, PointX, PointY: Double;
begin
  Result := EmptyExtent;
  if (Item.Width <= 0) or (Item.Height <= 0) then
    Exit;
  Matrix := List.Transforms[Item.Index];
  for Corner := 0 to 3 do
  begin
    CornerX := Item.X + (Corner mod 2) * Item.Width;
    CornerY := Item.Y + (Corner div 2) * Item.Height;
    PointX := Matrix.A * CornerX + Matrix.C * CornerY + Matrix.E;
    PointY := Matrix.B * CornerX + Matrix.D * CornerY + Matrix.F;
    Result.Left := Min(Result.Left, PointX);
    Result.Top := Min(Result.Top, PointY);
    Result.Right := Max(Result.Right, PointX);
    Result.Bottom := Max(Result.Bottom, PointY);
  end;
  if (Result.Left >= Result.Right) or (Result.Top >= Result.Bottom) then
    Result := EmptyExtent;
end;

{ How far a filter's blurs spread its content (CSS px): the three box
  blurs of a Gaussian reach less than three standard deviations, and a
  pixel or two for rounding. }
function FilterSpread(const Operations: TFilterOperations): Single;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to High(Operations) do
    if Operations[Index].Kind = foBlur then
      Result := Result + 3 * Operations[Index].Amount + 2;
end;

function SpreadExtent(const Content: TGroupExtent; Spread: Single): TGroupExtent;
begin
  Result := Content;
  if Content.Bounded and not ExtentIsEmpty(Content) then
  begin
    Result.Left := Content.Left - Spread;
    Result.Top := Content.Top - Spread;
    Result.Right := Content.Right + Spread;
    Result.Bottom := Content.Bottom + Spread;
  end;
end;

{ What a finished group (its content's extent worked out) adds to the
  group around it. }
function GroupContribution(List: TDisplayList; const Push: TDisplayItem; const Content: TGroupExtent): TGroupExtent;
begin
  case Push.Kind of
    diPushClip:
      begin
        { The clip applies in device pixels when it is pushed: whatever
          happens inside, nothing shows outside its rectangle. }
        Result := EmptyExtent;
        if not Content.Bounded then
          IncludeRectangle(Result, Push.X, Push.Y, Push.X + Push.Width, Push.Y + Push.Height)
        else if not ExtentIsEmpty(Content) then
          IncludeRectangle(Result, Max(Content.Left, Push.X), Max(Content.Top, Push.Y),
            Min(Content.Right, Push.X + Push.Width), Min(Content.Bottom, Push.Y + Push.Height));
      end;
    diPushTransform:
      Result := TransformedExtent(List, Push);
    diPushFilter:
      Result := SpreadExtent(Content, FilterSpread(List.Filters[Push.Index]));
    diPushFixed, diPushSticky:
      Result := UnknownExtent;
  else
    Result := Content;
  end;
end;

function IsPush(Kind: TDisplayItemKind): Boolean;
begin
  Result := Kind in [diPushClip, diPushOpacity, diPushFixed, diPushSticky, diPushMask, diPushMaskLayer,
    diPushFilter, diPushTransform];
end;

function IsPop(Kind: TDisplayItemKind): Boolean;
begin
  Result := Kind in [diPopClip, diPopOpacity, diPopFixed, diPopSticky, diPopMask, diPopMaskLayer, diPopFilter,
    diPopTransform];
end;

procedure ComputeGroupExtents(List: TDisplayList);
var
  Open: array of Integer;
  OpenCount, Index, Push: Integer;
  Item: PDisplayItem;
  Part: TGroupExtent;
begin
  SetLength(List.GroupExtents, List.Count);
  Open := nil;
  SetLength(Open, 16);
  OpenCount := 0;
  for Index := 0 to List.Count - 1 do
  begin
    Item := @List.Items[Index];
    if IsPush(Item^.Kind) then
    begin
      List.GroupExtents[Index] := EmptyExtent;
      if OpenCount >= Length(Open) then
        SetLength(Open, OpenCount * 2);
      Open[OpenCount] := Index;
      Inc(OpenCount);
    end
    else if IsPop(Item^.Kind) then
    begin
      if OpenCount = 0 then
        Continue;
      Dec(OpenCount);
      Push := Open[OpenCount];
      List.GroupExtents[Push].PopIndex := Index;
      if OpenCount > 0 then
      begin
        Part := GroupContribution(List, List.Items[Push], List.GroupExtents[Push]);
        IncludeExtent(List.GroupExtents[Open[OpenCount - 1]], Part);
      end;
    end
    else if (OpenCount > 0) and (Item^.Kind <> diMaskContent) then
      IncludeExtent(List.GroupExtents[Open[OpenCount - 1]], ItemExtent(List, Item^));
  end;
end;

procedure EnsureGroupExtents(List: TDisplayList);
begin
  if (List.GroupExtentsRevision = List.Revision) and (Length(List.GroupExtents) >= List.Count) then
    Exit;
  ComputeGroupExtents(List);
  List.GroupExtentsRevision := List.Revision;
end;

end.
