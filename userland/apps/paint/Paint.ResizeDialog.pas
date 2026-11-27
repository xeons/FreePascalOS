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
  Image > Resize and skew: stretch the picture to a new size, in percent
  or in pixels (the proportions kept unless Keep proportions is cleared:
  changing one side changes the other), and slant it by an angle across
  and up and down (degrees). Laid out by a table of captions and boxes.
}
unit Paint.ResizeDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

type
  TResizeChoice = record
    NewWidth: LongInt;
    NewHeight: LongInt;
    SkewHorizontal: LongInt;
    SkewVertical: LongInt;
  end;

{ Asks how to resize and skew a Width x Height picture; True and the
  choice if OK was pressed. }
function AskForResize(Owner: TWindow; Width, Height: LongInt; out Choice: TResizeChoice): Boolean;

implementation

uses
  Controls.Base,
  Controls.Labels,
  Controls.Toggles,
  Controls.NumericUpDown,
  Controls.TablePanel,
  Controls.TableArrangement,
  Controls.CommonDialogs,
  Paint.ResizeMath,
  Paint.Output;

const
  DialogWidth = 330;
  DialogHeight = 210;
  RowHeight = 26;
  CaptionColumnWidth = 170;
  FieldWidth = 100;
  FieldHeight = 22;
  LargestSkew = 89;
  LargestPercent = 1000;
  LargestSide = 16384;

type
  TResizeDialog = class(TCommonDialog)
  private
    FWidth: LongInt;
    FHeight: LongInt;
    FPercentButton: TRadioButton;
    FPixelsButton: TRadioButton;
    FHorizontalBox: TNumericUpDown;
    FVerticalBox: TNumericUpDown;
    FKeepBox: TCheckBox;
    FSkewHorizontalBox: TNumericUpDown;
    FSkewVerticalBox: TNumericUpDown;
    FMatching: Boolean;
    function Units: TResizeUnit;
    function AddRow(Table: TTableLayoutPanel; const Caption: string; Minimum, Maximum, Row: LongInt): TNumericUpDown;
    procedure UnitsChanged(Sender: TControl);
    procedure HorizontalChanged(Sender: TControl);
    procedure VerticalChanged(Sender: TControl);
  protected
    procedure Showing; override;
  public
    constructor CreateResizeDialog(AOwner: TWindow; AWidth, AHeight: LongInt);
    function Choice: TResizeChoice;
  end;

constructor TResizeDialog.CreateResizeDialog(AOwner: TWindow; AWidth, AHeight: LongInt);
var
  Table: TTableLayoutPanel;
  Row: LongInt;
begin
  inherited CreateDialog('Resize and skew', DialogWidth, DialogHeight, AOwner);
  FWidth := AWidth;
  FHeight := AHeight;
  Table := TTableLayoutPanel.Create(Root);
  Table.SetBounds(DialogMargin, DialogMargin, DialogWidth - 2 * DialogMargin,
    DialogHeight - 3 * DialogMargin - DialogButtonHeight);
  Table.AddColumn(TrackAbsolute, CaptionColumnWidth);
  Table.AddColumn(TrackPercent, 100);
  for Row := 1 to 6 do
    Table.AddRow(TrackAbsolute, RowHeight);
  FPercentButton := TRadioButton.Create(Table);
  FPercentButton.Text := 'By &percentage';
  FPercentButton.AutoSize := True;
  FPercentButton.Anchors := [akLeft];
  FPercentButton.Checked := True;
  FPercentButton.OnChange := @UnitsChanged;
  Table.SetCell(FPercentButton, 0, 0);
  FPixelsButton := TRadioButton.Create(Table);
  FPixelsButton.Text := 'By pi&xels';
  FPixelsButton.AutoSize := True;
  FPixelsButton.Anchors := [akLeft];
  FPixelsButton.OnChange := @UnitsChanged;
  Table.SetCell(FPixelsButton, 1, 0);
  FHorizontalBox := AddRow(Table, '&Horizontal:', 1, LargestPercent, 1);
  FHorizontalBox.Value := 100;
  FHorizontalBox.OnValueChanged := @HorizontalChanged;
  FVerticalBox := AddRow(Table, '&Vertical:', 1, LargestPercent, 2);
  FVerticalBox.Value := 100;
  FVerticalBox.OnValueChanged := @VerticalChanged;
  FKeepBox := TCheckBox.Create(Table);
  FKeepBox.Text := '&Keep proportions';
  FKeepBox.AutoSize := True;
  FKeepBox.Anchors := [akLeft];
  FKeepBox.Checked := True;
  Table.SetCell(FKeepBox, 0, 3);
  Table.SetSpan(FKeepBox, 2, 1);
  FSkewHorizontalBox := AddRow(Table, 'Skew hori&zontally (deg.):', -LargestSkew, LargestSkew, 4);
  FSkewVerticalBox := AddRow(Table, 'Skew ve&rtically (deg.):', -LargestSkew, LargestSkew, 5);
  AddOkAndCancel(DialogWidth, DialogHeight);
end;

function TResizeDialog.AddRow(Table: TTableLayoutPanel; const Caption: string; Minimum, Maximum,
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
  Result.SetBounds(0, 0, FieldWidth, FieldHeight);
  Result.Anchors := [akLeft, akRight];
  Result.SetRange(Minimum, Maximum);
  Table.SetCell(Result, 1, Row);
end;

function TResizeDialog.Units: TResizeUnit;
begin
  if FPixelsButton.Checked then
    Result := ResizeByPixels
  else
    Result := ResizeByPercent;
end;

procedure TResizeDialog.UnitsChanged(Sender: TControl);
begin
  if not TRadioButton(Sender).Checked then
    Exit;
  FMatching := True;
  try
    if Units = ResizeByPixels then
    begin
      FHorizontalBox.SetRange(1, LargestSide);
      FVerticalBox.SetRange(1, LargestSide);
      FHorizontalBox.Value := FWidth;
      FVerticalBox.Value := FHeight;
    end
    else
    begin
      FHorizontalBox.SetRange(1, LargestPercent);
      FVerticalBox.SetRange(1, LargestPercent);
      FHorizontalBox.Value := 100;
      FVerticalBox.Value := 100;
    end;
  finally
    FMatching := False;
  end;
end;

procedure TResizeDialog.HorizontalChanged(Sender: TControl);
begin
  if FMatching or not FKeepBox.Checked then
    Exit;
  FMatching := True;
  try
    FVerticalBox.Value := MatchingVertical(FWidth, FHeight, Units, FHorizontalBox.IntegerValue);
  finally
    FMatching := False;
  end;
end;

procedure TResizeDialog.VerticalChanged(Sender: TControl);
begin
  if FMatching or not FKeepBox.Checked then
    Exit;
  FMatching := True;
  try
    FHorizontalBox.Value := MatchingHorizontal(FWidth, FHeight, Units, FVerticalBox.IntegerValue);
  finally
    FMatching := False;
  end;
end;

procedure TResizeDialog.Showing;
begin
  FocusControl(FHorizontalBox.Editor);
  inherited Showing;
  Say('dialog ' + Title);
end;

function TResizeDialog.Choice: TResizeChoice;
begin
  FHorizontalBox.Validate;
  FVerticalBox.Validate;
  FSkewHorizontalBox.Validate;
  FSkewVerticalBox.Validate;
  ResizedSize(FWidth, FHeight, Units, FHorizontalBox.IntegerValue, FVerticalBox.IntegerValue, Result.NewWidth,
    Result.NewHeight);
  Result.SkewHorizontal := FSkewHorizontalBox.IntegerValue;
  Result.SkewVertical := FSkewVerticalBox.IntegerValue;
end;

function AskForResize(Owner: TWindow; Width, Height: LongInt; out Choice: TResizeChoice): Boolean;
var
  Dialog: TResizeDialog;
begin
  Dialog := TResizeDialog.CreateResizeDialog(Owner, Width, Height);
  try
    Result := Dialog.Execute;
    Choice := Dialog.Choice;
  finally
    Dialog.Free;
  end;
end;

end.
