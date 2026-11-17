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
  The quality a JPEG is saved at (1 to 100: smaller files or better
  pictures), asked before saving one: a slider and a box for the
  number, kept in step, in a table.
}
unit Paint.QualityDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

{ Asks for a quality starting at Quality; True and the quality if OK
  was pressed. }
function AskForJpegQuality(Owner: TWindow; var Quality: LongInt): Boolean;

implementation

uses
  Controls.Base,
  Controls.Labels,
  Controls.Slider,
  Controls.NumericUpDown,
  Controls.TablePanel,
  Controls.TableArrangement,
  Controls.CommonDialogs,
  Paint.Output;

const
  DialogWidth = 300;
  DialogHeight = 112;
  RowHeight = 30;
  CaptionColumnWidth = 60;
  NumberColumnWidth = 64;
  FieldHeight = 22;

type
  TQualityDialog = class(TCommonDialog)
  private
    FSlider: TSlider;
    FNumberBox: TNumericUpDown;
    FMatching: Boolean;
    procedure SliderChanged(Sender: TControl);
    procedure NumberChanged(Sender: TControl);
  protected
    procedure Showing; override;
  public
    constructor CreateQualityDialog(AOwner: TWindow; Quality: LongInt);
  end;

constructor TQualityDialog.CreateQualityDialog(AOwner: TWindow; Quality: LongInt);
var
  Table: TTableLayoutPanel;
  Caption: TLabel;
begin
  inherited CreateDialog('JPEG quality', DialogWidth, DialogHeight, AOwner);
  Table := TTableLayoutPanel.Create(Root);
  Table.SetBounds(DialogMargin, DialogMargin, DialogWidth - 2 * DialogMargin, 2 * RowHeight);
  Table.AddColumn(TrackAbsolute, CaptionColumnWidth);
  Table.AddColumn(TrackPercent, 100);
  Table.AddColumn(TrackAbsolute, NumberColumnWidth);
  Table.AddRow(TrackAbsolute, RowHeight);
  Caption := TLabel.Create(Table);
  Caption.Text := '&Quality:';
  Caption.AutoSize := True;
  Caption.Anchors := [akLeft];
  Table.SetCell(Caption, 0, 0);
  FSlider := TSlider.Create(Table);
  FSlider.Align := AlignClient;
  FSlider.Anchors := [akLeft, akRight];
  FSlider.SetRange(1, 100);
  FSlider.PageStep := 10;
  FSlider.Position := Quality;
  FSlider.OnChange := @SliderChanged;
  Table.SetCell(FSlider, 1, 0);
  FNumberBox := TNumericUpDown.Create(Table);
  FNumberBox.SetBounds(0, 0, NumberColumnWidth - 4, FieldHeight);
  FNumberBox.Anchors := [akLeft, akRight];
  FNumberBox.SetRange(1, 100);
  FNumberBox.Value := Quality;
  FNumberBox.OnValueChanged := @NumberChanged;
  Table.SetCell(FNumberBox, 2, 0);
  AddOkAndCancel(DialogWidth, DialogHeight);
end;

procedure TQualityDialog.SliderChanged(Sender: TControl);
begin
  if FMatching then
    Exit;
  FMatching := True;
  FNumberBox.Value := FSlider.Position;
  FMatching := False;
end;

procedure TQualityDialog.NumberChanged(Sender: TControl);
begin
  if FMatching then
    Exit;
  FMatching := True;
  FSlider.Position := FNumberBox.IntegerValue;
  FMatching := False;
end;

procedure TQualityDialog.Showing;
begin
  FocusControl(FSlider);
  inherited Showing;
  Say('dialog ' + Title);
end;

function AskForJpegQuality(Owner: TWindow; var Quality: LongInt): Boolean;
var
  Dialog: TQualityDialog;
begin
  Dialog := TQualityDialog.CreateQualityDialog(Owner, Quality);
  try
    Result := Dialog.Execute;
    if Result then
    begin
      Dialog.FNumberBox.Validate;
      Quality := Dialog.FNumberBox.IntegerValue;
    end;
  finally
    Dialog.Free;
  end;
end;

end.
