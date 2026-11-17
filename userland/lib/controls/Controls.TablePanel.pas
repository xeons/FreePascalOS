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
  Table layout panels: children in the cells of a grid of columns and
  rows, a form's captions and fields lined up without positions.

  Each column and row is sized one way (Controls.TableArrangement):
  Absolute (logical units), AutoSize (to the largest child in it) or
  Percent (a share of what the others leave). AddColumn and AddRow give
  the styles; a track without one is AutoSize. A child goes in the cell
  SetCell gives it (spanning SetSpan columns and rows), or else in the
  first free cell, row by row, in the order the children were made;
  when no cell is free the table grows by a row (GrowStyle
  GrowAddRows, the default), by a column, or not at all (the child is
  then not shown).

  Within its cell a child keeps its Margins clear and is placed by its
  Anchors: left and right together stretch it across the cell, one of
  them puts it at that side, neither centres it (the same up and down);
  docked to the client area it fills the cell, docked to a side it
  stretches along that side. With AutoSize the table takes the size its
  tracks need. It does not scroll itself (see Controls.FlowPanel).
}
unit Controls.TablePanel;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Rectangles,
  Controls.Base,
  Controls.Panels,
  Controls.TableArrangement;

type
  TTableCellEntry = record
    Control: TControl;
    Column: LongInt;
    Row: LongInt;
    ColumnSpan: LongInt;
    RowSpan: LongInt;
    { A cell given (SetCell) rather than found. }
    Fixed: Boolean;
  end;

  TTableLayoutPanel = class(TPanel)
  private
    FColumnStyles: TTrackStyles;
    FRowStyles: TTrackStyles;
    FEntries: array of TTableCellEntry;
    FGrowStyle: TTableGrowStyle;
    function EntryIndex(Control: TControl; AddIfMissing: Boolean): LongInt;
    procedure ForgetGoneChildren;
    function TableChildren: TList;
    { Finds every child's cell, growing the styles as the table grows. }
    function Placements(Kids: TList): TCellPlacements;
    function ScaledStyles(const Styles: TTrackStyles): TTrackStyles;
    { Each child's extent along both axes (pixels or logical units,
      margins in), as spans of tracks. }
    procedure MeasureSpans(Kids: TList; const Cells: TCellPlacements; InPixels: Boolean;
      out ColumnSpans, RowSpans: TTrackSpans);
    function ChildAnchorsInCell(Child: TControl; out Fill: Boolean): TAnchors;
    function GetColumnCount: LongInt;
    function GetRowCount: LongInt;
    procedure SetColumnCount(Value: LongInt);
    procedure SetRowCount(Value: LongInt);
    procedure SetGrowStyle(Value: TTableGrowStyle);
  protected
    procedure PlaceChildren(const Area: TRectangle); override;
    procedure PlaceOneChild(Child: TControl); override;
  public
    { A column (or row) at the end, sized as Sizing says: Value is logical
      units for TrackAbsolute, the share for TrackPercent. }
    procedure AddColumn(Sizing: TTrackSizing; Value: LongInt = 0);
    procedure AddRow(Sizing: TTrackSizing; Value: LongInt = 0);
    procedure SetColumnStyle(Index: LongInt; Sizing: TTrackSizing; Value: LongInt = 0);
    procedure SetRowStyle(Index: LongInt; Sizing: TTrackSizing; Value: LongInt = 0);
    { Puts Control (a child) in a cell of its own choosing. }
    procedure SetCell(Control: TControl; Column, Row: LongInt);
    procedure SetSpan(Control: TControl; ColumnSpan, RowSpan: LongInt);
    { Where Control is (False if it has no cell). }
    function CellOf(Control: TControl; out Column, Row: LongInt): Boolean;
    function PreferredSize: TSize; override;
    { Setting a count adds AutoSize tracks or takes the last ones away. }
    property ColumnCount: LongInt read GetColumnCount write SetColumnCount;
    property RowCount: LongInt read GetRowCount write SetRowCount;
    property GrowStyle: TTableGrowStyle read FGrowStyle write SetGrowStyle;
  end;

implementation

uses
  Windowing.Connection,
  Controls.LayoutRules;

procedure AddStyle(var Styles: TTrackStyles; Sizing: TTrackSizing; Value: LongInt);
begin
  SetLength(Styles, Length(Styles) + 1);
  Styles[High(Styles)] := MakeTrackStyle(Sizing, Value);
end;

procedure ResizeStyles(var Styles: TTrackStyles; Count: LongInt);
var
  Old: LongInt;
  Index: LongInt;
begin
  if Count < 0 then
    Count := 0;
  Old := Length(Styles);
  SetLength(Styles, Count);
  for Index := Old to Count - 1 do
    Styles[Index] := MakeTrackStyle(TrackAutoSize, 0);
end;

procedure TTableLayoutPanel.AddColumn(Sizing: TTrackSizing; Value: LongInt);
begin
  AddStyle(FColumnStyles, Sizing, Value);
  RequestLayout;
end;

procedure TTableLayoutPanel.AddRow(Sizing: TTrackSizing; Value: LongInt);
begin
  AddStyle(FRowStyles, Sizing, Value);
  RequestLayout;
end;

procedure TTableLayoutPanel.SetColumnStyle(Index: LongInt; Sizing: TTrackSizing; Value: LongInt);
begin
  if Index < 0 then
    Exit;
  if Index >= Length(FColumnStyles) then
    ResizeStyles(FColumnStyles, Index + 1);
  FColumnStyles[Index] := MakeTrackStyle(Sizing, Value);
  RequestLayout;
end;

procedure TTableLayoutPanel.SetRowStyle(Index: LongInt; Sizing: TTrackSizing; Value: LongInt);
begin
  if Index < 0 then
    Exit;
  if Index >= Length(FRowStyles) then
    ResizeStyles(FRowStyles, Index + 1);
  FRowStyles[Index] := MakeTrackStyle(Sizing, Value);
  RequestLayout;
end;

function TTableLayoutPanel.GetColumnCount: LongInt;
begin
  Result := Length(FColumnStyles);
end;

function TTableLayoutPanel.GetRowCount: LongInt;
begin
  Result := Length(FRowStyles);
end;

procedure TTableLayoutPanel.SetColumnCount(Value: LongInt);
begin
  ResizeStyles(FColumnStyles, Value);
  RequestLayout;
end;

procedure TTableLayoutPanel.SetRowCount(Value: LongInt);
begin
  ResizeStyles(FRowStyles, Value);
  RequestLayout;
end;

procedure TTableLayoutPanel.SetGrowStyle(Value: TTableGrowStyle);
begin
  FGrowStyle := Value;
  RequestLayout;
end;

function TTableLayoutPanel.EntryIndex(Control: TControl; AddIfMissing: Boolean): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(FEntries) do
    if FEntries[Index].Control = Control then
      Exit(Index);
  if not AddIfMissing then
    Exit(-1);
  SetLength(FEntries, Length(FEntries) + 1);
  Result := High(FEntries);
  FEntries[Result].Control := Control;
  FEntries[Result].Column := -1;
  FEntries[Result].Row := -1;
  FEntries[Result].ColumnSpan := 1;
  FEntries[Result].RowSpan := 1;
  FEntries[Result].Fixed := False;
end;

procedure TTableLayoutPanel.SetCell(Control: TControl; Column, Row: LongInt);
var
  Index: LongInt;
begin
  Index := EntryIndex(Control, True);
  FEntries[Index].Column := Column;
  FEntries[Index].Row := Row;
  FEntries[Index].Fixed := (Column >= 0) and (Row >= 0);
  RequestLayout;
end;

procedure TTableLayoutPanel.SetSpan(Control: TControl; ColumnSpan, RowSpan: LongInt);
var
  Index: LongInt;
begin
  Index := EntryIndex(Control, True);
  if ColumnSpan < 1 then
    ColumnSpan := 1;
  if RowSpan < 1 then
    RowSpan := 1;
  FEntries[Index].ColumnSpan := ColumnSpan;
  FEntries[Index].RowSpan := RowSpan;
  RequestLayout;
end;

function TTableLayoutPanel.CellOf(Control: TControl; out Column, Row: LongInt): Boolean;
var
  Index: LongInt;
begin
  { Up to date: the cells are found when laying out. }
  PixelBounds;
  Index := EntryIndex(Control, False);
  Column := -1;
  Row := -1;
  if Index >= 0 then
  begin
    Column := FEntries[Index].Column;
    Row := FEntries[Index].Row;
  end;
  Result := Column >= 0;
end;

{ Entries of controls that are no longer children are dropped (one made
  later at the same address must not inherit a cell). }
procedure TTableLayoutPanel.ForgetGoneChildren;
var
  Index: LongInt;
  Child: LongInt;
  Found: Boolean;
begin
  Index := 0;
  while Index <= High(FEntries) do
  begin
    Found := False;
    for Child := 0 to ChildCount - 1 do
      if Children[Child] = FEntries[Index].Control then
        Found := True;
    if Found then
      Inc(Index)
    else
      Delete(FEntries, Index, 1);
  end;
end;

function TTableLayoutPanel.TableChildren: TList;
var
  Index: LongInt;
begin
  Result := TList.Create;
  for Index := 0 to ChildCount - 1 do
    if Children[Index].Visible and CountsInExtent(Children[Index]) then
      Result.Add(Children[Index]);
end;

function TTableLayoutPanel.Placements(Kids: TList): TCellPlacements;
var
  Index: LongInt;
  Entry: LongInt;
  Columns: LongInt;
  Rows: LongInt;
begin
  ForgetGoneChildren;
  Result := nil;
  SetLength(Result, Kids.Count);
  for Index := 0 to Kids.Count - 1 do
  begin
    Entry := EntryIndex(TControl(Kids[Index]), True);
    Result[Index].Column := FEntries[Entry].Column;
    Result[Index].Row := FEntries[Entry].Row;
    Result[Index].ColumnSpan := FEntries[Entry].ColumnSpan;
    Result[Index].RowSpan := FEntries[Entry].RowSpan;
    Result[Index].Fixed := FEntries[Entry].Fixed;
  end;
  Columns := Length(FColumnStyles);
  Rows := Length(FRowStyles);
  AssignFreeCells(Result, Columns, Rows, FGrowStyle);
  { Fixed cells beyond the styles given grow the table too. }
  for Index := 0 to High(Result) do
    if Result[Index].Column >= 0 then
    begin
      if Result[Index].Column + 1 > Columns then
        Columns := Result[Index].Column + 1;
      if Result[Index].Row + 1 > Rows then
        Rows := Result[Index].Row + 1;
    end;
  if Columns > Length(FColumnStyles) then
    ResizeStyles(FColumnStyles, Columns);
  if Rows > Length(FRowStyles) then
    ResizeStyles(FRowStyles, Rows);
  for Index := 0 to Kids.Count - 1 do
  begin
    Entry := EntryIndex(TControl(Kids[Index]), False);
    if not FEntries[Entry].Fixed then
    begin
      FEntries[Entry].Column := Result[Index].Column;
      FEntries[Entry].Row := Result[Index].Row;
    end;
  end;
end;

function TTableLayoutPanel.ScaledStyles(const Styles: TTrackStyles): TTrackStyles;
var
  Index: LongInt;
begin
  Result := Copy(Styles);
  for Index := 0 to High(Result) do
    if Result[Index].Sizing = TrackAbsolute then
      Result[Index].Value := Scaled(Result[Index].Value);
end;

function TTableLayoutPanel.ChildAnchorsInCell(Child: TControl; out Fill: Boolean): TAnchors;
begin
  Fill := Child.Align = AlignClient;
  case Child.Align of
    AlignTop: Result := [akLeft, akRight, akTop];
    AlignBottom: Result := [akLeft, akRight, akBottom];
    AlignLeft: Result := [akLeft, akTop, akBottom];
    AlignRight: Result := [akRight, akTop, akBottom];
  else
    Result := Child.Anchors;
  end;
end;

procedure TTableLayoutPanel.MeasureSpans(Kids: TList; const Cells: TCellPlacements; InPixels: Boolean;
  out ColumnSpans, RowSpans: TTrackSpans);
var
  Index: LongInt;
  Child: TControl;
  Size: TSize;
  Margin: TSpacing;
begin
  ColumnSpans := nil;
  RowSpans := nil;
  for Index := 0 to Kids.Count - 1 do
  begin
    if Cells[Index].Column < 0 then
      Continue;
    Child := TControl(Kids[Index]);
    Size := ChildSize(Child);
    Margin := Child.Margins;
    if InPixels then
    begin
      Size := MakeSize(Scaled(Size.cx), Scaled(Size.cy));
      Margin := Child.ScaledMargin;
    end;
    SetLength(ColumnSpans, Length(ColumnSpans) + 1);
    ColumnSpans[High(ColumnSpans)] := MakeTrackSpan(Cells[Index].Column, Cells[Index].ColumnSpan,
      Size.cx + SpacingWidth(Margin));
    SetLength(RowSpans, Length(RowSpans) + 1);
    RowSpans[High(RowSpans)] := MakeTrackSpan(Cells[Index].Row, Cells[Index].RowSpan, Size.cy + SpacingHeight(Margin));
  end;
end;

procedure TTableLayoutPanel.PlaceChildren(const Area: TRectangle);
var
  TableKids: TList;
  Cells: TCellPlacements;
  ColumnSpans: TTrackSpans;
  RowSpans: TTrackSpans;
  ColumnOffsets: TTrackSizes;
  RowOffsets: TTrackSizes;
  Index: LongInt;
  Child: TControl;
  Cell: TRectangle;
  Size: TSize;
  Fill: Boolean;
  CellAnchors: TAnchors;
begin
  for Index := 0 to ChildCount - 1 do
    if not Children[Index].Visible then
      PlaceChild(Children[Index], MakeRectangle(Area.Left, Area.Top, 0, 0));
  TableKids := TableChildren;
  try
    Cells := Placements(TableKids);
    MeasureSpans(TableKids, Cells, True, ColumnSpans, RowSpans);
    ColumnOffsets := TrackOffsets(Area.Left, MeasureTracks(ScaledStyles(FColumnStyles), ColumnSpans,
      RectangleWidth(Area)));
    RowOffsets := TrackOffsets(Area.Top, MeasureTracks(ScaledStyles(FRowStyles), RowSpans, RectangleHeight(Area)));
    for Index := 0 to TableKids.Count - 1 do
    begin
      Child := TControl(TableKids[Index]);
      if Cells[Index].Column < 0 then
      begin
        PlaceChild(Child, MakeRectangle(Area.Left, Area.Top, 0, 0));
        Continue;
      end;
      Cell := CellRectangle(ColumnOffsets, RowOffsets, Cells[Index].Column, Cells[Index].Row,
        Cells[Index].ColumnSpan, Cells[Index].RowSpan);
      Size := ChildSize(Child);
      CellAnchors := ChildAnchorsInCell(Child, Fill);
      PlaceChild(Child, PlaceInCell(Cell, MakeSize(Scaled(Size.cx), Scaled(Size.cy)), Child.ScaledMargin, CellAnchors,
        Fill, Child.ScaledConstraints));
    end;
  finally
    TableKids.Free;
  end;
end;

procedure TTableLayoutPanel.PlaceOneChild(Child: TControl);
begin
  PlaceChildren(ClientPixelArea);
end;

function TTableLayoutPanel.PreferredSize: TSize;
var
  TableKids: TList;
  Cells: TCellPlacements;
  ColumnSpans: TTrackSpans;
  RowSpans: TTrackSpans;
begin
  TableKids := TableChildren;
  try
    Cells := Placements(TableKids);
    MeasureSpans(TableKids, Cells, False, ColumnSpans, RowSpans);
    Result := MakeSize(TracksContentExtent(FColumnStyles, ColumnSpans) + SpacingWidth(ContentPadding),
      TracksContentExtent(FRowStyles, RowSpans) + SpacingHeight(ContentPadding));
  finally
    TableKids.Free;
  end;
end;

end.
