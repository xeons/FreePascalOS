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
  The dialog that asks for a picture's size in pixels: for File > New,
  and for Image > Properties (with what is known of the picture above
  the size: changing the size there makes the canvas larger, the new
  part in the secondary colour, or cuts it). Laid out by a table: the
  captions in a column as wide as the widest, the boxes filling the
  rest.
}
unit Paint.ImageSizeDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

const
  LargestPictureSide = 16384;

{ Asks for a size starting at Width x Height; Details ('' for none) is
  shown above. True and the size if OK was pressed. }
function AskForImageSize(Owner: TWindow; const Title, Details: string; var Width, Height: LongInt): Boolean;

implementation

uses
  Controls.Base,
  Controls.Labels,
  Controls.NumericUpDown,
  Controls.TablePanel,
  Controls.TableArrangement,
  Controls.CommonDialogs,
  Paint.Output;

const
  DialogWidth = 280;
  RowHeight = 26;
  DetailsRowHeight = 36;
  CaptionColumnWidth = 70;
  FieldWidth = 100;
  FieldHeight = 22;

type
  TImageSizeDialog = class(TCommonDialog)
  private
    FWidthBox: TNumericUpDown;
    FHeightBox: TNumericUpDown;
    function AddSizeRow(Table: TTableLayoutPanel; const Caption: string; Value, Row: LongInt): TNumericUpDown;
  protected
    procedure Showing; override;
  public
    constructor CreateSizeDialog(AOwner: TWindow; const ATitle, Details: string; AWidth, AHeight: LongInt);
  end;

function DialogHeightFor(const Details: string): LongInt;
begin
  Result := 2 * RowHeight + 2 * DialogMargin + DialogButtonHeight + DialogMargin;
  if Details <> '' then
    Inc(Result, DetailsRowHeight);
end;

constructor TImageSizeDialog.CreateSizeDialog(AOwner: TWindow; const ATitle, Details: string;
  AWidth, AHeight: LongInt);
var
  Table: TTableLayoutPanel;
  Message: TLabel;
  Height: LongInt;
  FirstRow: LongInt;
begin
  Height := DialogHeightFor(Details);
  inherited CreateDialog(ATitle, DialogWidth, Height, AOwner);
  Table := TTableLayoutPanel.Create(Root);
  Table.SetBounds(DialogMargin, DialogMargin, DialogWidth - 2 * DialogMargin,
    Height - 3 * DialogMargin - DialogButtonHeight);
  Table.AddColumn(TrackAbsolute, CaptionColumnWidth);
  Table.AddColumn(TrackPercent, 100);
  if Details <> '' then
  begin
    Table.AddRow(TrackAbsolute, DetailsRowHeight);
    Message := TLabel.Create(Table);
    Message.ShowsMnemonic := False;
    Message.Text := Details;
    Message.AutoSize := True;
    Message.Anchors := [akLeft, akTop];
    Table.SetCell(Message, 0, 0);
    Table.SetSpan(Message, 2, 1);
  end;
  FirstRow := Table.RowCount;
  Table.AddRow(TrackAbsolute, RowHeight);
  Table.AddRow(TrackAbsolute, RowHeight);
  FWidthBox := AddSizeRow(Table, '&Width:', AWidth, FirstRow);
  FHeightBox := AddSizeRow(Table, '&Height:', AHeight, FirstRow + 1);
  AddOkAndCancel(DialogWidth, Height);
end;

function TImageSizeDialog.AddSizeRow(Table: TTableLayoutPanel; const Caption: string; Value,
  Row: LongInt): TNumericUpDown;
var
  Text: TLabel;
begin
  Text := TLabel.Create(Table);
  Text.Text := Caption;
  Text.AutoSize := True;
  Text.Anchors := [akLeft];
  Table.SetCell(Text, 0, Row);
  Result := TNumericUpDown.Create(Table);
  Table.SetCell(Result, 1, Row);
  Result.SetBounds(0, 0, FieldWidth, FieldHeight);
  Result.Anchors := [akLeft, akRight];
  Result.SetRange(1, LargestPictureSide);
  Result.Value := Value;
end;

procedure TImageSizeDialog.Showing;
begin
  FocusControl(FWidthBox.Editor);
  FWidthBox.Editor.SelectAll;
  inherited Showing;
  Say('dialog ' + Title);
end;

function AskForImageSize(Owner: TWindow; const Title, Details: string; var Width, Height: LongInt): Boolean;
var
  Dialog: TImageSizeDialog;
begin
  Dialog := TImageSizeDialog.CreateSizeDialog(Owner, Title, Details, Width, Height);
  try
    Result := Dialog.Execute;
    if Result then
    begin
      Dialog.FWidthBox.Validate;
      Dialog.FHeightBox.Validate;
      Width := Dialog.FWidthBox.IntegerValue;
      Height := Dialog.FHeightBox.IntegerValue;
    end;
  finally
    Dialog.Free;
  end;
end;

end.
