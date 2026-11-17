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
  The items of a list view: a row of texts (one per column, the first
  is the item's name), an icon (with a mark over it, for a link): a
  picture of the list view's image list (ImageIndex), else its own
  surface or a stock icon; whether it is selected, and a pointer for
  the program.

  An item tells the control it belongs to whenever it changes, so the
  control repaints (and announces a new selection) however the item was
  changed: through the list view or through the item itself.
}
unit Controls.ListItems;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Surfaces,
  Controls.Base,
  Controls.Icons,
  Controls.ImageList;

type
  TListItem = class;

  { What an item needs of its list view. }
  TListItemOwner = class(TControl)
  private
    FImages: TImageList;
    procedure SetImages(Value: TImageList);
  protected
    procedure ItemChanged(Item: TListItem; SelectionChanged: Boolean); virtual; abstract;
  public
    { The pictures items show by ImageIndex (shared: the list view does
      not own it). }
    property Images: TImageList read FImages write SetImages;
  end;

  TListItem = class
  private
    FOwner: TListItemOwner;
    FCells: TStringList;
    FIcon: TSurface;
    FIconKind: TStockIcon;
    FOverlay: TIconOverlay;
    FImageIndex: LongInt;
    FSelected: Boolean;
    FData: Pointer;
    function GetCell(Column: LongInt): string;
    procedure SetCell(Column: LongInt; const Value: string);
    procedure SetIcon(const Value: TSurface);
    procedure SetIconKind(Value: TStockIcon);
    procedure SetOverlay(Value: TIconOverlay);
    procedure SetImageIndex(Value: LongInt);
    procedure SetSelected(Value: Boolean);
    function GetCaption: string;
  public
    constructor Create(AOwner: TListItemOwner);
    destructor Destroy; override;
    function CellCount: LongInt;
    { Texts by column; past the last there are empty ones. }
    property Cells[Column: LongInt]: string read GetCell write SetCell;
    { The first column's text. }
    property Caption: string read GetCaption;
    { The program's own picture (it keeps the pixels); none (no pixels):
      the stock icon IconKind is drawn. }
    property Icon: TSurface read FIcon write SetIcon;
    property IconKind: TStockIcon read FIconKind write SetIconKind;
    { A mark over the icon (a symbolic link's arrow). }
    property Overlay: TIconOverlay read FOverlay write SetOverlay;
    { Its picture in the list view's Images (-1, the default: none; Icon
      or IconKind is drawn). }
    property ImageIndex: LongInt read FImageIndex write SetImageIndex;
    property Owner: TListItemOwner read FOwner;
    property Selected: Boolean read FSelected write SetSelected;
    property Data: Pointer read FData write FData;
  end;

implementation

procedure TListItemOwner.SetImages(Value: TImageList);
begin
  FImages := Value;
  Invalidate;
end;

constructor TListItem.Create(AOwner: TListItemOwner);
begin
  inherited Create;
  FOwner := AOwner;
  FCells := TStringList.Create;
  FIconKind := StockIconDocument;
  FImageIndex := -1;
end;

destructor TListItem.Destroy;
begin
  FCells.Free;
  inherited Destroy;
end;

function TListItem.CellCount: LongInt;
begin
  Result := FCells.Count;
end;

function TListItem.GetCell(Column: LongInt): string;
begin
  if (Column >= 0) and (Column < FCells.Count) then
    Result := FCells[Column]
  else
    Result := '';
end;

procedure TListItem.SetCell(Column: LongInt; const Value: string);
begin
  if Column < 0 then
    Exit;
  while FCells.Count <= Column do
    FCells.Add('');
  FCells[Column] := Value;
  if FOwner <> nil then
    FOwner.ItemChanged(Self, False);
end;

function TListItem.GetCaption: string;
begin
  Result := GetCell(0);
end;

procedure TListItem.SetIcon(const Value: TSurface);
begin
  FIcon := Value;
  if FOwner <> nil then
    FOwner.ItemChanged(Self, False);
end;

procedure TListItem.SetIconKind(Value: TStockIcon);
begin
  FIconKind := Value;
  if FOwner <> nil then
    FOwner.ItemChanged(Self, False);
end;

procedure TListItem.SetOverlay(Value: TIconOverlay);
begin
  FOverlay := Value;
  if FOwner <> nil then
    FOwner.ItemChanged(Self, False);
end;

procedure TListItem.SetImageIndex(Value: LongInt);
begin
  FImageIndex := Value;
  if FOwner <> nil then
    FOwner.ItemChanged(Self, False);
end;

procedure TListItem.SetSelected(Value: Boolean);
begin
  if FSelected = Value then
    Exit;
  FSelected := Value;
  if FOwner <> nil then
    FOwner.ItemChanged(Self, True);
end;

end.
