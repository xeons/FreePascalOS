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
  What an item view (Controls.ItemView) shows: items, the columns of the
  details view, and the groups items are gathered in.

  An item is a row of texts, one per column (the first is its name), an
  icon (a theme icon by name, else a stock icon, with a mark over it),
  and perhaps a thumbnail (a picture of what it holds, drawn instead of
  the icon at the larger sizes; the surface belongs to whoever set it,
  a thumbnail cache say). It may be dimmed (cut, waiting to be pasted,
  or hidden), belongs to a group (an index into the view's groups, -1
  for none) and carries a pointer for the program.

  A column has a caption, a width (logical units), an alignment (sizes
  to the right) and may be hidden: the program offers the hidden ones
  on the header's context menu. A group has a caption ("Today",
  "Folders") and can be collapsed.

  Changing an item tells its view, so it paints again.
}
unit Controls.ItemViewItems;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Surfaces,
  Controls.Base,
  Controls.Icons,
  Controls.Text;

type
  TItemViewItem = class;

  { What an item needs of its view. }
  TItemViewOwner = class(TControl)
  protected
    procedure ItemChanged(Item: TItemViewItem; SelectionChanged: Boolean); virtual; abstract;
  end;

  TItemViewItem = class
  private
    FOwner: TItemViewOwner;
    FCells: TStringList;
    FIconName: string;
    FIconKind: TStockIcon;
    FOverlay: TIconOverlay;
    FThumbnail: TSurface;
    FSelected: Boolean;
    FDimmed: Boolean;
    FGroup: LongInt;
    FMeter: LongInt;
    FData: Pointer;
    function GetCell(Column: LongInt): string;
    procedure SetCell(Column: LongInt; const Value: string);
    function GetCaption: string;
    procedure SetIconName(const Value: string);
    procedure SetIconKind(Value: TStockIcon);
    procedure SetOverlay(Value: TIconOverlay);
    procedure SetThumbnail(const Value: TSurface);
    procedure SetSelected(Value: Boolean);
    procedure SetDimmed(Value: Boolean);
    procedure SetMeter(Value: LongInt);
    procedure Changed(SelectionChanged: Boolean);
  public
    constructor Create(AOwner: TItemViewOwner);
    destructor Destroy; override;
    function HasThumbnail: Boolean;
    procedure ClearThumbnail;
    property Cells[Column: LongInt]: string read GetCell write SetCell;
    property Caption: string read GetCaption;
    { A theme icon's name ('' for the stock icon IconKind). }
    property IconName: string read FIconName write SetIconName;
    property IconKind: TStockIcon read FIconKind write SetIconKind;
    property Overlay: TIconOverlay read FOverlay write SetOverlay;
    property Thumbnail: TSurface read FThumbnail write SetThumbnail;
    property Selected: Boolean read FSelected write SetSelected;
    property Dimmed: Boolean read FDimmed write SetDimmed;
    { Set before the items are laid out (the view sorts by group). }
    property Group: LongInt read FGroup write FGroup;
    { A bar under the name in tiles and content (a disk's space used),
      0 to 1000; -1 (the default) for none. }
    property Meter: LongInt read FMeter write SetMeter;
    property Data: Pointer read FData write FData;
    property Owner: TItemViewOwner read FOwner;
  end;

  TItemColumn = record
    Caption: string;
    { Logical units. }
    Width: LongInt;
    Alignment: THorizontalAlignment;
    Visible: Boolean;
    { The program's own (which property the column shows). }
    Tag: PtrInt;
  end;
  TItemColumns = array of TItemColumn;

  TItemGroup = record
    Caption: string;
    Collapsed: Boolean;
  end;
  TItemGroups = array of TItemGroup;

implementation

constructor TItemViewItem.Create(AOwner: TItemViewOwner);
begin
  inherited Create;
  FOwner := AOwner;
  FCells := TStringList.Create;
  FIconKind := StockIconFile;
  FGroup := -1;
  FMeter := -1;
end;

destructor TItemViewItem.Destroy;
begin
  FCells.Free;
  inherited Destroy;
end;

procedure TItemViewItem.Changed(SelectionChanged: Boolean);
begin
  if FOwner <> nil then
    FOwner.ItemChanged(Self, SelectionChanged);
end;

function TItemViewItem.GetCell(Column: LongInt): string;
begin
  if (Column >= 0) and (Column < FCells.Count) then
    Result := FCells[Column]
  else
    Result := '';
end;

procedure TItemViewItem.SetCell(Column: LongInt; const Value: string);
begin
  if Column < 0 then
    Exit;
  while FCells.Count <= Column do
    FCells.Add('');
  FCells[Column] := Value;
  Changed(False);
end;

function TItemViewItem.GetCaption: string;
begin
  Result := GetCell(0);
end;

procedure TItemViewItem.SetIconName(const Value: string);
begin
  FIconName := Value;
  Changed(False);
end;

procedure TItemViewItem.SetIconKind(Value: TStockIcon);
begin
  FIconKind := Value;
  Changed(False);
end;

procedure TItemViewItem.SetOverlay(Value: TIconOverlay);
begin
  FOverlay := Value;
  Changed(False);
end;

procedure TItemViewItem.SetThumbnail(const Value: TSurface);
begin
  FThumbnail := Value;
  Changed(False);
end;

function TItemViewItem.HasThumbnail: Boolean;
begin
  Result := (FThumbnail.Pixels <> nil) and (FThumbnail.Width > 0) and (FThumbnail.Height > 0);
end;

procedure TItemViewItem.ClearThumbnail;
begin
  FThumbnail := Default(TSurface);
  Changed(False);
end;

procedure TItemViewItem.SetSelected(Value: Boolean);
begin
  if FSelected = Value then
    Exit;
  FSelected := Value;
  Changed(True);
end;

procedure TItemViewItem.SetDimmed(Value: Boolean);
begin
  if FDimmed = Value then
    Exit;
  FDimmed := Value;
  Changed(False);
end;

procedure TItemViewItem.SetMeter(Value: LongInt);
begin
  if Value > 1000 then
    Value := 1000;
  FMeter := Value;
  Changed(False);
end;

end.
