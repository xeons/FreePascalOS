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
  Grid layout (CSS Grid Layout 1) in its basic form.

  The explicit grid comes from grid-template-columns/rows (lengths,
  percentages, fr, auto, min-content, max-content, minmax(), fit-content(),
  repeat() with a count or auto-fill/auto-fit) and grid-template-areas;
  items are placed by their grid-row/column lines (numbers, negative
  ones from the end, span, area names), the rest by the auto-placement
  cursor (row or column flow, sparse); implicit tracks take
  grid-auto-rows/columns.

  Track sizing, simplified from the specification's algorithm: fixed
  tracks take their size; intrinsic tracks their items' min-content
  contributions (an item spanning several tracks spreads what it needs
  beyond them), then grow towards their max-content limits while there
  is free space; fr tracks share what is left (none smaller than its
  items' minimum); auto tracks are stretched by what remains. Columns
  are sized first, rows with the items laid out at their column widths.
  Items are stretched to their areas or aligned (justify-self,
  align-self), the tracks distributed by justify-content and
  align-content, gaps between.
}
unit Web.Layout.Grid;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes, Web.Layout.Context;

procedure LayoutGridContainer(Box: TLayoutBox; const Input: TLayoutInput);

implementation

uses
  Math, SysUtils, Css.ComputedStyle, Css.ComputedValues, Css.Values, Css.Units, Css.Keywords, Css.PropertyIds,
  Web.Layout.Values, Web.Layout.Sizing, Web.Layout.Dispatch;

type
  TTrackKind = (tkFixed, tkPercent, tkFlex, tkAuto, tkMinContent, tkMaxContent, tkFitContent);

  TTrackSize = record
    MinKind, MaxKind: TTrackKind;
    MinValue, MaxValue: Single;
  end;

  TTrack = record
    Size: TTrackSize;
    Base, Limit: Single;
    Position: Single;
  end;
  TTrackArray = array of TTrack;

  TGridArea = record
    Name: string;
    RowStart, RowEnd, ColumnStart, ColumnEnd: Integer;
  end;

  TGridItem = record
    Box: TLayoutBox;
    Order: Integer;
    { 0 based, end exclusive; -1 while auto. }
    RowStart, RowEnd, ColumnStart, ColumnEnd: Integer;
  end;

  TGridState = record
    Box: TLayoutBox;
    Input: TLayoutInput;
    Columns, Rows: TTrackArray;
    ExplicitColumns, ExplicitRows: Integer;
    AutoColumns, AutoRows: array of TTrackSize;
    Areas: array of TGridArea;
    Items: array of TGridItem;
    ColumnGap, RowGap: Single;
    ColumnFlow: Boolean;
  end;

function SizeFromValue(Value: TCssValue; Basis: Single): TTrackSize;

  procedure One(Item: TCssValue; out Kind: TTrackKind; out Amount: Single);
  begin
    Kind := tkAuto;
    Amount := 0;
    if Item = nil then
      Exit;
    case Item.Kind of
      vkDimension:
        if Item.UnitValue = cuFr then
        begin
          Kind := tkFlex;
          Amount := Item.Number;
        end
        else
        begin
          Kind := tkFixed;
          Amount := Item.Number;
        end;
      vkNumber, vkInteger:
        begin
          Kind := tkFixed;
          Amount := Item.Number;
        end;
      vkPercentage:
        if Basis >= 0 then
        begin
          Kind := tkFixed;
          Amount := Item.Number * Basis / 100;
        end;
      vkKeyword:
        case Item.Keyword of
          kwMinContent: Kind := tkMinContent;
          kwMaxContent: Kind := tkMaxContent;
        end;
    end;
  end;

begin
  Result.MinKind := tkAuto;
  Result.MaxKind := tkAuto;
  Result.MinValue := 0;
  Result.MaxValue := 0;
  if Value = nil then
    Exit;
  if (Value.Kind = vkFunction) and (Value.Text = 'minmax') and (Value.Count >= 2) then
  begin
    One(Value.Items[0], Result.MinKind, Result.MinValue);
    One(Value.Items[1], Result.MaxKind, Result.MaxValue);
    if Result.MinKind = tkFlex then
      Result.MinKind := tkAuto;
  end
  else if (Value.Kind = vkFunction) and (Value.Text = 'fit-content') and (Value.Count >= 1) then
  begin
    Result.MinKind := tkAuto;
    Result.MaxKind := tkFitContent;
    One(Value.Items[0], Result.MinKind, Result.MaxValue);
    Result.MinKind := tkAuto;
  end
  else
  begin
    One(Value, Result.MinKind, Result.MinValue);
    Result.MaxKind := Result.MinKind;
    Result.MaxValue := Result.MinValue;
    { A flexible track's minimum is auto. }
    if Result.MinKind = tkFlex then
    begin
      Result.MinKind := tkAuto;
      Result.MinValue := 0;
    end;
  end;
end;

function IsLineNames(Value: TCssValue): Boolean;
begin
  Result := (Value.Kind = vkList) and (Value.Text = '[');
end;

procedure AddTrack(var Tracks: TTrackArray; const Size: TTrackSize);
begin
  SetLength(Tracks, Length(Tracks) + 1);
  Tracks[High(Tracks)].Size := Size;
end;

function FixedMinimum(const Size: TTrackSize): Single;
begin
  if Size.MinKind = tkFixed then
    Result := Size.MinValue
  else if Size.MaxKind = tkFixed then
    Result := Size.MaxValue
  else
    Result := 0;
end;

procedure ExpandTracks(Template: PCssComputedValue; Available, Gap: Single; var Tracks: TTrackArray);
var
  List, Item, Inner: TCssValue;
  Index, Repeat_, Count, Part: Integer;
  Pattern: array of TTrackSize;
  Used: Single;
  AutoRepeat: Boolean;
begin
  Tracks := nil;
  if Template^.Kind in [cvLength, cvPercentage, cvLengthPercentage, cvCalc] then
  begin
    { One track given as a plain length. }
    SetLength(Tracks, 1);
    Tracks[0].Size := SizeFromValue(nil, Available);
    if (Template^.Kind = cvLength) or (Available >= 0) then
    begin
      Tracks[0].Size.MinKind := tkFixed;
      Tracks[0].Size.MaxKind := tkFixed;
      Tracks[0].Size.MinValue := ResolveComputed(Template^, Max(Available, 0));
      Tracks[0].Size.MaxValue := Tracks[0].Size.MinValue;
    end;
    Exit;
  end;
  if (Template^.Kind <> cvValue) or (Template^.Data = nil) then
    Exit;
  List := Template^.Data;
  if List.Kind <> vkList then
  begin
    AddTrack(Tracks, SizeFromValue(List, Available));
    Exit;
  end;
  for Index := 0 to List.Count - 1 do
  begin
    Item := List.Items[Index];
    if IsLineNames(Item) then
      Continue;
    if (Item.Kind = vkFunction) and (Item.Text = 'repeat') and (Item.Count >= 2) then
    begin
      Pattern := nil;
      Inner := Item.Items[1];
      if Inner.Kind = vkList then
      begin
        for Part := 0 to Inner.Count - 1 do
          if not IsLineNames(Inner.Items[Part]) then
          begin
            SetLength(Pattern, Length(Pattern) + 1);
            Pattern[High(Pattern)] := SizeFromValue(Inner.Items[Part], Available);
          end;
      end
      else
      begin
        SetLength(Pattern, 1);
        Pattern[0] := SizeFromValue(Inner, Available);
      end;
      if Length(Pattern) = 0 then
        Continue;
      AutoRepeat := Item.Items[0].Kind = vkKeyword;
      if AutoRepeat then
      begin
        { As many as fit in the available size (at least one). }
        Used := 0;
        for Part := 0 to High(Pattern) do
          Used := Used + Max(FixedMinimum(Pattern[Part]), 1) + Gap;
        if (Available > 0) and (Used > 0) then
          Count := Max(1, Floor((Available + Gap) / Used))
        else
          Count := 1;
      end
      else
        Count := Max(1, Round(Item.Items[0].Number));
      for Repeat_ := 1 to Count do
        for Part := 0 to High(Pattern) do
          AddTrack(Tracks, Pattern[Part]);
    end
    else
      AddTrack(Tracks, SizeFromValue(Item, Available));
  end;
end;

function AutoSizes(Value: PCssComputedValue; Available: Single): TTrackArray;
begin
  Result := nil;
  if Value^.Kind = cvKeyword then
  begin
    SetLength(Result, 1);
    Result[0].Size := SizeFromValue(nil, Available);
    Exit;
  end;
  ExpandTracks(Value, Available, 0, Result);
  if Length(Result) = 0 then
  begin
    SetLength(Result, 1);
    Result[0].Size := SizeFromValue(nil, Available);
  end;
end;

procedure ReadAreas(var State: TGridState);
var
  Value: PCssComputedValue;
  Row, Column: Integer;
  Text, Name: string;
  Names: TStringArray;
  Found, Index: Integer;
  Rows: TCssValue;
  RowCount: Integer;
begin
  State.Areas := nil;
  Value := State.Box.Style.Value(cpGridTemplateAreas);
  if (Value^.Kind <> cvValue) or (Value^.Data = nil) then
    Exit;
  Rows := Value^.Data;
  if Rows.Kind = vkList then
    RowCount := Rows.Count
  else
    RowCount := 1;
  for Row := 0 to RowCount - 1 do
  begin
    if Rows.Kind = vkList then
      Text := Rows.Items[Row].Text
    else
      Text := Rows.Text;
    Names := Text.Split([' ', #9, #10], TStringSplitOptions.ExcludeEmpty);
    for Column := 0 to High(Names) do
    begin
      Name := Names[Column];
      if (Name = '') or (Name[1] = '.') then
        Continue;
      Found := -1;
      for Index := 0 to High(State.Areas) do
        if State.Areas[Index].Name = Name then
          Found := Index;
      if Found < 0 then
      begin
        SetLength(State.Areas, Length(State.Areas) + 1);
        Found := High(State.Areas);
        State.Areas[Found].Name := Name;
        State.Areas[Found].RowStart := Row;
        State.Areas[Found].ColumnStart := Column;
      end;
      State.Areas[Found].RowEnd := Max(State.Areas[Found].RowEnd, Row + 1);
      State.Areas[Found].ColumnEnd := Max(State.Areas[Found].ColumnEnd, Column + 1);
    end;
  end;
end;

function FindArea(const State: TGridState; const Name: string; out Area: TGridArea): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(State.Areas) do
    if State.Areas[Index].Name = Name then
    begin
      Area := State.Areas[Index];
      Exit(True);
    end;
  Result := False;
end;

{ A grid-row/column start or end: the line (0 based) or -1 for auto,
  and a span. }
procedure ReadLine(const State: TGridState; Value: PCssComputedValue; IsStart, IsRow: Boolean; ExplicitCount: Integer;
  out Line, Span: Integer);
var
  Data, Item: TCssValue;
  Index: Integer;
  Number: Integer;
  Name: string;
  Area: TGridArea;
  HasSpan: Boolean;
begin
  Line := -1;
  Span := 0;
  case Value^.Kind of
    cvInteger, cvNumber:
      begin
        Number := Round(Value^.Number);
        if Number > 0 then
          Line := Number - 1
        else if Number < 0 then
          Line := Max(0, ExplicitCount + 1 + Number);
        Exit;
      end;
    cvValue:
      begin
        Data := Value^.Data;
        if Data = nil then
          Exit;
        HasSpan := False;
        Number := 0;
        Name := '';
        if Data.Kind = vkList then
        begin
          for Index := 0 to Data.Count - 1 do
          begin
            Item := Data.Items[Index];
            if Item.IsKeyword(kwSpan) then
              HasSpan := True
            else if Item.Kind in [vkInteger, vkNumber] then
              Number := Round(Item.Number)
            else if Item.Kind = vkCustomIdent then
              Name := Item.Text;
          end;
        end
        else if Data.Kind = vkCustomIdent then
          Name := Data.Text
        else if Data.Kind in [vkInteger, vkNumber] then
          Number := Round(Data.Number);
        if HasSpan then
        begin
          Span := Max(1, Number);
          Exit;
        end;
        if (Name <> '') and FindArea(State, Name, Area) then
        begin
          if IsRow then
          begin
            if IsStart then
              Line := Area.RowStart
            else
              Line := Area.RowEnd;
          end
          else if IsStart then
            Line := Area.ColumnStart
          else
            Line := Area.ColumnEnd;
          Exit;
        end;
        if Number > 0 then
          Line := Number - 1
        else if Number < 0 then
          Line := Max(0, ExplicitCount + 1 + Number);
      end;
  end;
end;

procedure ResolveAxis(const State: TGridState; Box: TLayoutBox; IsRow: Boolean; ExplicitCount: Integer;
  out Start, Finish: Integer);
var
  StartLine, StartSpan, EndLine, EndSpan: Integer;
  StartId, EndId: TCssPropertyId;
  Area: TGridArea;
  Value: PCssComputedValue;
begin
  if IsRow then
  begin
    StartId := cpGridRowStart;
    EndId := cpGridRowEnd;
  end
  else
  begin
    StartId := cpGridColumnStart;
    EndId := cpGridColumnEnd;
  end;
  ReadLine(State, Box.Style.Value(StartId), True, IsRow, ExplicitCount, StartLine, StartSpan);
  ReadLine(State, Box.Style.Value(EndId), False, IsRow, ExplicitCount, EndLine, EndSpan);
  { grid-area: name with an auto end: the area's end. }
  Value := Box.Style.Value(StartId);
  if (EndLine < 0) and (EndSpan = 0) and (Value^.Kind = cvValue) and (Value^.Data <> nil) and
     (Value^.Data.Kind = vkCustomIdent) and FindArea(State, Value^.Data.Text, Area) then
  begin
    if IsRow then
      EndLine := Area.RowEnd
    else
      EndLine := Area.ColumnEnd;
  end;
  if (StartLine >= 0) and (EndLine > StartLine) then
  begin
    Start := StartLine;
    Finish := EndLine;
  end
  else if (StartLine >= 0) and (EndSpan > 0) then
  begin
    Start := StartLine;
    Finish := StartLine + EndSpan;
  end
  else if StartLine >= 0 then
  begin
    Start := StartLine;
    Finish := StartLine + 1;
  end
  else if (EndLine >= 0) and (StartSpan > 0) then
  begin
    Start := Max(0, EndLine - StartSpan);
    Finish := EndLine;
  end
  else if EndLine > 0 then
  begin
    Start := EndLine - 1;
    Finish := EndLine;
  end
  else
  begin
    { Auto: Finish holds the span. }
    Start := -1;
    Finish := Max(1, Max(StartSpan, EndSpan));
  end;
end;

procedure CollectItems(var State: TGridState);
var
  Child: TLayoutBox;
  Count, Index, Other: Integer;
  Item: TGridItem;
begin
  Count := 0;
  State.Items := nil;
  Child := State.Box.FirstChild;
  while Child <> nil do
  begin
    if Child.IsAbsolutelyPositioned then
    begin
      Child.StaticX := State.Box.ContentLeft;
      Child.StaticY := State.Box.ContentTop;
      if (bfFixed in Child.Flags) and (State.Input.FixedBoxes <> nil) then
        State.Input.FixedBoxes.Add(Child)
      else if State.Input.Positioned <> nil then
        State.Input.Positioned.Add(Child);
    end
    else
    begin
      SetLength(State.Items, Count + 1);
      State.Items[Count].Box := Child;
      State.Items[Count].Order := Round(Child.Style.Value(cpOrder)^.Number);
      Inc(Count);
    end;
    Child := Child.NextSibling;
  end;
  for Index := 1 to Count - 1 do
  begin
    Item := State.Items[Index];
    Other := Index - 1;
    while (Other >= 0) and (State.Items[Other].Order > Item.Order) do
    begin
      State.Items[Other + 1] := State.Items[Other];
      Dec(Other);
    end;
    State.Items[Other + 1] := Item;
  end;
end;

{ Grows Tracks to hold index Count - 1 with implicit tracks. }
procedure EnsureTracks(var Tracks: TTrackArray; Count: Integer; const AutoSizesList: TTrackArray);
var
  Index: Integer;
begin
  Index := Length(Tracks);
  while Length(Tracks) < Count do
  begin
    SetLength(Tracks, Length(Tracks) + 1);
    Tracks[High(Tracks)].Size := AutoSizesList[Index mod Length(AutoSizesList)].Size;
    Inc(Index);
  end;
end;

procedure PlaceItems(var State: TGridState; const AutoColumnSizes, AutoRowSizes: TTrackArray);
var
  Index, Span, CursorRow, CursorColumn, Major, Minor, MinorCount: Integer;
  Item: ^TGridItem;
  Occupied: array of array of Boolean;

  function Free(Row, Column, RowSpan, ColumnSpan: Integer): Boolean;
  var
    R, C: Integer;
  begin
    for R := Row to Row + RowSpan - 1 do
      for C := Column to Column + ColumnSpan - 1 do
        if (R < Length(Occupied)) and (C < Length(Occupied[R])) and Occupied[R][C] then
          Exit(False);
    Result := True;
  end;

  procedure Mark(Row, Column, RowSpan, ColumnSpan: Integer);
  var
    R, C: Integer;
  begin
    if Length(Occupied) < Row + RowSpan then
      SetLength(Occupied, Row + RowSpan);
    for R := Row to Row + RowSpan - 1 do
    begin
      if Length(Occupied[R]) < Column + ColumnSpan then
        SetLength(Occupied[R], Column + ColumnSpan);
      for C := Column to Column + ColumnSpan - 1 do
        Occupied[R][C] := True;
    end;
  end;

begin
  Occupied := nil;
  for Index := 0 to High(State.Items) do
  begin
    Item := @State.Items[Index];
    ResolveAxis(State, Item^.Box, True, State.ExplicitRows, Item^.RowStart, Item^.RowEnd);
    ResolveAxis(State, Item^.Box, False, State.ExplicitColumns, Item^.ColumnStart, Item^.ColumnEnd);
    if (Item^.RowStart >= 0) and (Item^.ColumnStart >= 0) then
      Mark(Item^.RowStart, Item^.ColumnStart, Item^.RowEnd - Item^.RowStart, Item^.ColumnEnd - Item^.ColumnStart);
  end;
  { The auto-placement cursor (sparse). }
  if State.ColumnFlow then
    MinorCount := Max(1, State.ExplicitRows)
  else
    MinorCount := Max(1, State.ExplicitColumns);
  CursorRow := 0;
  CursorColumn := 0;
  for Index := 0 to High(State.Items) do
  begin
    Item := @State.Items[Index];
    if (Item^.RowStart >= 0) and (Item^.ColumnStart >= 0) then
      Continue;
    if not State.ColumnFlow then
    begin
      if Item^.RowStart >= 0 then
      begin
        { A definite row: the first free column in it. }
        Span := Item^.ColumnEnd;
        Minor := 0;
        while not Free(Item^.RowStart, Minor, Item^.RowEnd - Item^.RowStart, Span) do
          Inc(Minor);
        Item^.ColumnStart := Minor;
        Item^.ColumnEnd := Minor + Span;
      end
      else if Item^.ColumnStart >= 0 then
      begin
        Span := Item^.RowEnd;
        Major := CursorRow;
        while not Free(Major, Item^.ColumnStart, Span, Item^.ColumnEnd - Item^.ColumnStart) do
          Inc(Major);
        Item^.RowStart := Major;
        Item^.RowEnd := Major + Span;
      end
      else
      begin
        Span := Item^.ColumnEnd;
        Major := CursorRow;
        Minor := CursorColumn;
        repeat
          if Minor + Span > Max(MinorCount, Span) then
          begin
            Minor := 0;
            Inc(Major);
          end;
          if Free(Major, Minor, Item^.RowEnd, Span) then
            Break;
          Inc(Minor);
        until False;
        Item^.RowStart := Major;
        Item^.RowEnd := Major + Item^.RowEnd;
        Item^.ColumnStart := Minor;
        Item^.ColumnEnd := Minor + Span;
        CursorRow := Major;
        CursorColumn := Minor + Span;
      end;
    end
    else
    begin
      if Item^.ColumnStart >= 0 then
      begin
        Span := Item^.RowEnd;
        Minor := 0;
        while not Free(Minor, Item^.ColumnStart, Span, Item^.ColumnEnd - Item^.ColumnStart) do
          Inc(Minor);
        Item^.RowStart := Minor;
        Item^.RowEnd := Minor + Span;
      end
      else
      begin
        Span := Item^.RowEnd;
        if Item^.RowStart >= 0 then
        begin
          Major := CursorColumn;
          while not Free(Item^.RowStart, Major, Item^.RowEnd - Item^.RowStart, Item^.ColumnEnd) do
            Inc(Major);
          Item^.ColumnEnd := Major + Item^.ColumnEnd;
          Item^.ColumnStart := Major;
        end
        else
        begin
          Major := CursorColumn;
          Minor := CursorRow;
          repeat
            if Minor + Span > Max(MinorCount, Span) then
            begin
              Minor := 0;
              Inc(Major);
            end;
            if Free(Minor, Major, Span, Item^.ColumnEnd) then
              Break;
            Inc(Minor);
          until False;
          Item^.RowStart := Minor;
          Item^.RowEnd := Minor + Span;
          Item^.ColumnEnd := Major + Item^.ColumnEnd;
          Item^.ColumnStart := Major;
          CursorColumn := Major;
          CursorRow := Minor + Span;
        end;
      end;
    end;
    Mark(Item^.RowStart, Item^.ColumnStart, Item^.RowEnd - Item^.RowStart, Item^.ColumnEnd - Item^.ColumnStart);
  end;
  for Index := 0 to High(State.Items) do
  begin
    EnsureTracks(State.Columns, State.Items[Index].ColumnEnd, AutoColumnSizes);
    EnsureTracks(State.Rows, State.Items[Index].RowEnd, AutoRowSizes);
  end;
end;

function IsIntrinsic(Kind: TTrackKind): Boolean; inline;
begin
  Result := Kind in [tkAuto, tkMinContent, tkMaxContent, tkFitContent];
end;

{ Sizes Tracks for the items' contributions (MinSizes, MaxSizes per item
  along this axis) in Available (-1 indefinite). }
procedure SizeTracks(var Tracks: TTrackArray; const Starts, Ends: array of Integer; const MinSizes,
  MaxSizes: array of Single; Available, Gap: Single; Stretch: Boolean);
var
  Index, Item, Track, Count, FlexibleCount: Integer;
  Need, Have, Extra, Free, FlexSum, FlexUnit, Used: Single;
  Done: Boolean;
  Guard: Integer;
begin
  for Index := 0 to High(Tracks) do
    with Tracks[Index] do
    begin
      if Size.MinKind = tkFixed then
        Base := Size.MinValue
      else
        Base := 0;
      if Size.MaxKind = tkFixed then
        Limit := Max(Size.MaxValue, Base)
      else if Size.MaxKind = tkFlex then
        Limit := Base
      else
        Limit := -1;
    end;
  { Items in one track. }
  for Item := 0 to High(Starts) do
  begin
    if Ends[Item] - Starts[Item] <> 1 then
      Continue;
    Track := Starts[Item];
    if IsIntrinsic(Tracks[Track].Size.MinKind) then
    begin
      if Tracks[Track].Size.MinKind = tkMaxContent then
        Tracks[Track].Base := Max(Tracks[Track].Base, MaxSizes[Item])
      else
        Tracks[Track].Base := Max(Tracks[Track].Base, MinSizes[Item]);
    end;
    if IsIntrinsic(Tracks[Track].Size.MaxKind) then
    begin
      if Tracks[Track].Size.MaxKind = tkMinContent then
        Tracks[Track].Limit := Max(Tracks[Track].Limit, MinSizes[Item])
      else if Tracks[Track].Size.MaxKind = tkFitContent then
        Tracks[Track].Limit := Max(Tracks[Track].Limit, Min(MaxSizes[Item], Max(MinSizes[Item],
          Tracks[Track].Size.MaxValue)))
      else
        Tracks[Track].Limit := Max(Tracks[Track].Limit, MaxSizes[Item]);
    end
    else if Tracks[Track].Size.MaxKind = tkFlex then
      Tracks[Track].Base := Max(Tracks[Track].Base, MinSizes[Item]);
  end;
  { Items spanning several tracks spread what they need. }
  for Item := 0 to High(Starts) do
  begin
    if Ends[Item] - Starts[Item] <= 1 then
      Continue;
    Have := Gap * (Ends[Item] - Starts[Item] - 1);
    Count := 0;
    for Track := Starts[Item] to Ends[Item] - 1 do
    begin
      Have := Have + Tracks[Track].Base;
      if IsIntrinsic(Tracks[Track].Size.MinKind) then
        Inc(Count);
    end;
    Need := MinSizes[Item];
    if (Need > Have) and (Count > 0) then
    begin
      Extra := (Need - Have) / Count;
      for Track := Starts[Item] to Ends[Item] - 1 do
        if IsIntrinsic(Tracks[Track].Size.MinKind) then
          Tracks[Track].Base := Tracks[Track].Base + Extra;
    end;
  end;
  for Index := 0 to High(Tracks) do
    if (Tracks[Index].Limit >= 0) and (Tracks[Index].Limit < Tracks[Index].Base) then
      Tracks[Index].Limit := Tracks[Index].Base;
  { Grow intrinsic tracks towards their limits while there is room. }
  Used := Gap * Max(0, Length(Tracks) - 1);
  for Index := 0 to High(Tracks) do
    Used := Used + Tracks[Index].Base;
  if Available >= 0 then
    Free := Available - Used
  else
    Free := 1e9;
  Guard := 0;
  while (Free > 0.01) and (Guard < 20) do
  begin
    Inc(Guard);
    Count := 0;
    for Index := 0 to High(Tracks) do
      if (Tracks[Index].Size.MaxKind <> tkFlex) and (Tracks[Index].Limit > Tracks[Index].Base + 0.01) then
        Inc(Count);
    if Count = 0 then
      Break;
    Extra := Free / Count;
    Done := True;
    for Index := 0 to High(Tracks) do
      if (Tracks[Index].Size.MaxKind <> tkFlex) and (Tracks[Index].Limit > Tracks[Index].Base + 0.01) then
      begin
        Have := Min(Extra, Tracks[Index].Limit - Tracks[Index].Base);
        Tracks[Index].Base := Tracks[Index].Base + Have;
        Free := Free - Have;
        Done := False;
      end;
    if Done then
      Break;
  end;
  if Available < 0 then
  begin
    { Indefinite: flexible tracks take their items' sizes in proportion. }
    FlexUnit := 0;
    for Index := 0 to High(Tracks) do
      if (Tracks[Index].Size.MaxKind = tkFlex) and (Tracks[Index].Size.MaxValue > 0) then
        FlexUnit := Max(FlexUnit, Tracks[Index].Base / Tracks[Index].Size.MaxValue);
    for Index := 0 to High(Tracks) do
      if Tracks[Index].Size.MaxKind = tkFlex then
        Tracks[Index].Base := Max(Tracks[Index].Base, FlexUnit * Tracks[Index].Size.MaxValue);
    Exit;
  end;
  { fr tracks share the rest; one whose minimum is larger keeps it. }
  Free := Available - Gap * Max(0, Length(Tracks) - 1);
  FlexSum := 0;
  FlexibleCount := 0;
  for Index := 0 to High(Tracks) do
    if Tracks[Index].Size.MaxKind = tkFlex then
    begin
      FlexSum := FlexSum + Tracks[Index].Size.MaxValue;
      Inc(FlexibleCount);
    end
    else
      Free := Free - Tracks[Index].Base;
  if FlexibleCount > 0 then
  begin
    Guard := 0;
    repeat
      Inc(Guard);
      if FlexSum < 1 then
        FlexUnit := Max(0, Free)
      else
        FlexUnit := Max(0, Free) / FlexSum;
      Done := True;
      for Index := 0 to High(Tracks) do
        if (Tracks[Index].Size.MaxKind = tkFlex) and (Tracks[Index].Limit >= 0) and
           (Tracks[Index].Base > FlexUnit * Tracks[Index].Size.MaxValue + 0.01) then
        begin
          { Too big to flex: treated as fixed. }
          Free := Free - Tracks[Index].Base;
          FlexSum := FlexSum - Tracks[Index].Size.MaxValue;
          Tracks[Index].Limit := -2;
          Done := False;
        end;
    until Done or (Guard > 20);
    for Index := 0 to High(Tracks) do
      if (Tracks[Index].Size.MaxKind = tkFlex) and (Tracks[Index].Limit <> -2) then
        Tracks[Index].Base := FlexUnit * Tracks[Index].Size.MaxValue;
  end
  else if Stretch then
  begin
    { Stretch auto tracks by what is left. }
    Count := 0;
    for Index := 0 to High(Tracks) do
      if Tracks[Index].Size.MaxKind = tkAuto then
        Inc(Count);
    if (Count > 0) and (Free > 0) then
      for Index := 0 to High(Tracks) do
        if Tracks[Index].Size.MaxKind = tkAuto then
          Tracks[Index].Base := Tracks[Index].Base + Free / Count;
  end;
end;

procedure PositionTracks(var Tracks: TTrackArray; Gap, Available: Single; Distribution: TCssKeyword);
var
  Index: Integer;
  Used, Free, Position, Between: Single;
begin
  Used := Gap * Max(0, Length(Tracks) - 1);
  for Index := 0 to High(Tracks) do
    Used := Used + Tracks[Index].Base;
  Free := 0;
  if Available >= 0 then
    Free := Available - Used;
  Position := 0;
  Between := 0;
  if (Free > 0) and (Length(Tracks) > 0) then
    case Distribution of
      kwCenter: Position := Free / 2;
      kwEnd, kwFlexEnd: Position := Free;
      kwSpaceBetween:
        if Length(Tracks) > 1 then
          Between := Free / (Length(Tracks) - 1);
      kwSpaceAround:
        begin
          Between := Free / Length(Tracks);
          Position := Between / 2;
        end;
      kwSpaceEvenly:
        begin
          Between := Free / (Length(Tracks) + 1);
          Position := Between;
        end;
    end;
  for Index := 0 to High(Tracks) do
  begin
    Tracks[Index].Position := Position;
    Position := Position + Tracks[Index].Base + Gap + Between;
  end;
end;

function TrackSpan(const Tracks: TTrackArray; Start, Finish: Integer): Single;
begin
  if Finish <= Start then
    Exit(0);
  Result := Tracks[Finish - 1].Position + Tracks[Finish - 1].Base - Tracks[Start].Position;
end;

function KeywordOf(Style: TCssComputedStyle; Id: TCssPropertyId): TCssKeyword;
var
  Value: PCssComputedValue;
  Index: Integer;
begin
  Value := Style.Value(Id);
  if Value^.Kind = cvKeyword then
    Exit(TCssKeyword(Value^.Keyword));
  Result := kwNormal;
  if (Value^.Kind = cvValue) and (Value^.Data <> nil) then
    for Index := 0 to Value^.Data.Count - 1 do
      if not KeywordIn(Value^.Data.Items[Index].Keyword, [kwSafe, kwUnsafe, kwFirst, kwLast, kwLegacy]) then
        Exit(Value^.Data.Items[Index].Keyword);
end;

procedure LayItemOut(var State: TGridState; Box: TLayoutBox; Width, Height: Single; Shrink: Boolean;
  ContainingHeight: Single);
var
  ChildInput: TLayoutInput;
begin
  ChildInput := MakeChildInput(State.Input, Width, ContainingHeight, wmFixed);
  ChildInput.Floats := nil;
  ChildInput.BfcX := 0;
  ChildInput.BfcY := 0;
  if Shrink then
  begin
    ChildInput.WidthMode := wmShrinkToFit;
    ChildInput.AvailableWidth := Width;
  end
  else
    ChildInput.FixedWidth := Width;
  ChildInput.FixedHeight := Height;
  LayoutBox(Box, ChildInput);
end;

procedure LayoutGridContainer(Box: TLayoutBox; const Input: TLayoutInput);
var
  State: TGridState;
  AutoColumnSizes, AutoRowSizes: TTrackArray;
  Count, Index: Integer;
  Starts, Ends: array of Integer;
  MinSizes, MaxSizes: array of Single;
  ContentHeight, AreaWidth, AreaHeight, ItemWidth, ItemHeight, OffsetX, OffsetY, Free: Single;
  Item: ^TGridItem;
  ItemBox: TLayoutBox;
  JustifySelf, AlignSelf: TCssKeyword;
  StretchWidth, StretchHeight: Boolean;
  MinWidth, MaxWidth: Single;
begin
  ComputeUsedWidth(Box, Input);
  Box.FirstBaseline := -1;
  Box.LastBaseline := -1;
  State.Box := Box;
  State.Input := Input;
  ContentHeight := DefiniteContentHeight(Box, Input);
  if IsAutoValue(Box.Style, cpColumnGap) then
    State.ColumnGap := 0
  else
    State.ColumnGap := LengthOf(Box.Style, cpColumnGap, Box.ContentWidth);
  if IsAutoValue(Box.Style, cpRowGap) then
    State.RowGap := 0
  else
    State.RowGap := LengthOf(Box.Style, cpRowGap, Max(ContentHeight, 0));
  State.ColumnFlow := KeywordOf(Box.Style, cpGridAutoFlow) = kwColumn;
  ReadAreas(State);
  ExpandTracks(Box.Style.Value(cpGridTemplateColumns), Box.ContentWidth, State.ColumnGap, State.Columns);
  ExpandTracks(Box.Style.Value(cpGridTemplateRows), ContentHeight, State.RowGap, State.Rows);
  for Index := 0 to High(State.Areas) do
  begin
    while Length(State.Columns) < State.Areas[Index].ColumnEnd do
      AddTrack(State.Columns, SizeFromValue(nil, -1));
    while Length(State.Rows) < State.Areas[Index].RowEnd do
      AddTrack(State.Rows, SizeFromValue(nil, -1));
  end;
  State.ExplicitColumns := Length(State.Columns);
  State.ExplicitRows := Length(State.Rows);
  AutoColumnSizes := AutoSizes(Box.Style.Value(cpGridAutoColumns), Box.ContentWidth);
  AutoRowSizes := AutoSizes(Box.Style.Value(cpGridAutoRows), ContentHeight);
  CollectItems(State);
  PlaceItems(State, AutoColumnSizes, AutoRowSizes);
  Count := Length(State.Items);
  SetLength(Starts, Count);
  SetLength(Ends, Count);
  SetLength(MinSizes, Count);
  SetLength(MaxSizes, Count);
  { Columns from the items' min/max-content widths. }
  for Index := 0 to Count - 1 do
  begin
    Item := @State.Items[Index];
    ResolveBoxEdges(Item^.Box, Box.ContentWidth);
    IntrinsicWidths(Item^.Box, MinWidth, MaxWidth);
    Starts[Index] := Item^.ColumnStart;
    Ends[Index] := Item^.ColumnEnd;
    MinSizes[Index] := MinWidth + Item^.Box.Margin[sideLeft] + Item^.Box.Margin[sideRight];
    MaxSizes[Index] := MaxWidth + Item^.Box.Margin[sideLeft] + Item^.Box.Margin[sideRight];
  end;
  SizeTracks(State.Columns, Starts, Ends, MinSizes, MaxSizes, Box.ContentWidth, State.ColumnGap,
    KeywordIn(KeywordOf(Box.Style, cpJustifyContent), [kwNormal, kwStretch]));
  PositionTracks(State.Columns, State.ColumnGap, Box.ContentWidth, KeywordOf(Box.Style, cpJustifyContent));
  { Rows from the items laid out at their column widths. }
  for Index := 0 to Count - 1 do
  begin
    Item := @State.Items[Index];
    AreaWidth := TrackSpan(State.Columns, Item^.ColumnStart, Item^.ColumnEnd);
    ItemBox := Item^.Box;
    JustifySelf := KeywordOf(ItemBox.Style, cpJustifySelf);
    if KeywordIn(JustifySelf, [kwAuto, kwNormal]) then
      JustifySelf := KeywordOf(Box.Style, cpJustifyItems);
    StretchWidth := KeywordIn(JustifySelf, [kwNormal, kwStretch, kwAuto, kwLegacy]) and
      IsAutoValue(ItemBox.Style, cpWidth) and (ItemBox.Kind <> bkReplaced);
    LayItemOut(State, ItemBox, Max(0, AreaWidth - ItemBox.Margin[sideLeft] - ItemBox.Margin[sideRight]), -1,
      not StretchWidth, ContentHeight);
    Starts[Index] := Item^.RowStart;
    Ends[Index] := Item^.RowEnd;
    MinSizes[Index] := ItemBox.MarginBoxHeight;
    MaxSizes[Index] := ItemBox.MarginBoxHeight;
  end;
  SizeTracks(State.Rows, Starts, Ends, MinSizes, MaxSizes, ContentHeight, State.RowGap,
    KeywordIn(KeywordOf(Box.Style, cpAlignContent), [kwNormal, kwStretch]));
  { The container's height, then the rows' positions in it. }
  Free := State.RowGap * Max(0, Length(State.Rows) - 1);
  for Index := 0 to High(State.Rows) do
    Free := Free + State.Rows[Index].Base;
  ComputeUsedHeight(Box, Input, Free);
  PositionTracks(State.Rows, State.RowGap, Box.ContentHeight, KeywordOf(Box.Style, cpAlignContent));
  { Items in their areas. }
  for Index := 0 to Count - 1 do
  begin
    Item := @State.Items[Index];
    ItemBox := Item^.Box;
    AreaWidth := TrackSpan(State.Columns, Item^.ColumnStart, Item^.ColumnEnd);
    AreaHeight := TrackSpan(State.Rows, Item^.RowStart, Item^.RowEnd);
    JustifySelf := KeywordOf(ItemBox.Style, cpJustifySelf);
    if KeywordIn(JustifySelf, [kwAuto, kwNormal]) then
      JustifySelf := KeywordOf(Box.Style, cpJustifyItems);
    AlignSelf := KeywordOf(ItemBox.Style, cpAlignSelf);
    if KeywordIn(AlignSelf, [kwAuto, kwNormal]) then
      AlignSelf := KeywordOf(Box.Style, cpAlignItems);
    StretchWidth := KeywordIn(JustifySelf, [kwNormal, kwStretch, kwAuto, kwLegacy]) and
      IsAutoValue(ItemBox.Style, cpWidth) and (ItemBox.Kind <> bkReplaced);
    StretchHeight := KeywordIn(AlignSelf, [kwNormal, kwStretch, kwAuto]) and IsAutoValue(ItemBox.Style, cpHeight) and
      (ItemBox.Kind <> bkReplaced);
    ItemWidth := Max(0, AreaWidth - ItemBox.Margin[sideLeft] - ItemBox.Margin[sideRight]);
    ItemHeight := -1;
    if StretchHeight then
      ItemHeight := Max(0, AreaHeight - ItemBox.Margin[sideTop] - ItemBox.Margin[sideBottom]);
    if StretchHeight and (Abs(ItemHeight - ItemBox.Height) > 0.01) then
    begin
      ItemBox.MarkNeedsLayout;
      LayItemOut(State, ItemBox, ItemWidth, ItemHeight, not StretchWidth, ContentHeight);
    end;
    OffsetX := 0;
    Free := AreaWidth - ItemBox.MarginBoxWidth;
    if Free > 0 then
      case JustifySelf of
        kwCenter: OffsetX := Free / 2;
        kwEnd, kwFlexEnd, kwSelfEnd, kwRight: OffsetX := Free;
      end;
    OffsetY := 0;
    Free := AreaHeight - ItemBox.MarginBoxHeight;
    if Free > 0 then
      case AlignSelf of
        kwCenter: OffsetY := Free / 2;
        kwEnd, kwFlexEnd, kwSelfEnd: OffsetY := Free;
      end;
    ItemBox.X := Box.ContentLeft + State.Columns[Item^.ColumnStart].Position + OffsetX + ItemBox.Margin[sideLeft];
    ItemBox.Y := Box.ContentTop + State.Rows[Item^.RowStart].Position + OffsetY + ItemBox.Margin[sideTop];
    if (Box.FirstBaseline < 0) and (ItemBox.FirstBaseline >= 0) and (Item^.RowStart = 0) then
      Box.FirstBaseline := ItemBox.Y + ItemBox.FirstBaseline;
  end;
  if (Box.FirstBaseline < 0) and (Count > 0) then
    Box.FirstBaseline := State.Items[0].Box.Y + State.Items[0].Box.Height;
  Box.LastBaseline := Box.FirstBaseline;
  Box.TopPositive := Max(Box.Margin[sideTop], 0);
  Box.TopNegative := Min(Box.Margin[sideTop], 0);
  Box.BottomPositive := Max(Box.Margin[sideBottom], 0);
  Box.BottomNegative := Min(Box.Margin[sideBottom], 0);
  Box.CollapsesThrough := False;
end;

end.
