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
  The text tool's dialog: the text to place, and the font it is drawn
  in (the font dialog picks the family, size and weight; what was
  chosen shows beside its button). The text box has the keyboard when
  it appears, so the text can be typed and Enter pressed.
}
unit Paint.TextDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

{ Asks for a text, starting with Text and the font given (Family a
  Windowing.Fonts TFontFamily, as its number); True and the choices if
  OK was pressed. }
function AskForText(Owner: TWindow; var Text: string; var Family: LongInt; var PointTenths: LongWord;
  var Bold: Boolean): Boolean;
{ Asks for the font alone (the tool box's Font button). }
function AskForTextFont(var Family: LongInt; var PointTenths: LongWord; var Bold: Boolean): Boolean;
{ "DejaVu Sans, 24 pt, bold". }
function FontDescription(Family: LongInt; PointTenths: LongWord; Bold: Boolean): string;

implementation

uses
  Windowing.Fonts,
  Controls.Base,
  Controls.LayoutRules,
  Controls.Labels,
  Controls.EditBox,
  Controls.Buttons,
  Controls.FontDialog,
  Controls.TablePanel,
  Controls.TableArrangement,
  Controls.CommonDialogs,
  Paint.Output;

const
  DialogWidth = 360;
  DialogHeight = 104;
  RowHeight = 28;
  CaptionColumnWidth = 50;
  ButtonColumnWidth = 84;
  FieldHeight = 22;

type
  TTextDialog = class(TCommonDialog)
  private
    FTextBox: TEditBox;
    FFontLabel: TLabel;
    FFamily: LongInt;
    FPointTenths: LongWord;
    FBold: Boolean;
    procedure FontClicked(Sender: TControl);
  protected
    procedure Showing; override;
  public
    constructor CreateTextDialog(AOwner: TWindow; const AText: string; AFamily: LongInt; APointTenths: LongWord;
      ABold: Boolean);
  end;

function ValidFamily(Family: LongInt): TFontFamily;
begin
  if (Family < Ord(Low(TFontFamily))) or (Family > Ord(High(TFontFamily))) then
    Result := FontFamilyText
  else
    Result := TFontFamily(Family);
end;

function FontDescription(Family: LongInt; PointTenths: LongWord; Bold: Boolean): string;
begin
  Result := FamilyName(ValidFamily(Family)) + ', ' + PointSizeText(PointTenths) + ' pt';
  if Bold then
    Result := Result + ', bold';
end;

function AskForTextFont(var Family: LongInt; var PointTenths: LongWord; var Bold: Boolean): Boolean;
var
  Chosen: TFontFamily;
begin
  Chosen := ValidFamily(Family);
  Result := ChooseFontOfFamily(Chosen, PointTenths, Bold);
  if Result then
    Family := Ord(Chosen);
end;

constructor TTextDialog.CreateTextDialog(AOwner: TWindow; const AText: string; AFamily: LongInt;
  APointTenths: LongWord; ABold: Boolean);
var
  Table: TTableLayoutPanel;
  Caption: TLabel;
  FontButton: TButton;
begin
  inherited CreateDialog('Text', DialogWidth, DialogHeight, AOwner);
  FFamily := AFamily;
  FPointTenths := APointTenths;
  FBold := ABold;
  Table := TTableLayoutPanel.Create(Root);
  Table.SetBounds(DialogMargin, DialogMargin, DialogWidth - 2 * DialogMargin, 2 * RowHeight);
  Table.AddColumn(TrackAbsolute, CaptionColumnWidth);
  Table.AddColumn(TrackPercent, 100);
  Table.AddColumn(TrackAbsolute, ButtonColumnWidth);
  Table.AddRow(TrackAbsolute, RowHeight);
  Table.AddRow(TrackAbsolute, RowHeight);
  Caption := TLabel.Create(Table);
  Caption.Text := '&Text:';
  Caption.AutoSize := True;
  Caption.Anchors := [akLeft];
  Table.SetCell(Caption, 0, 0);
  FTextBox := TEditBox.Create(Table);
  FTextBox.Text := AText;
  FTextBox.SetBounds(0, 0, 100, FieldHeight);
  FTextBox.Anchors := [akLeft, akRight];
  Table.SetCell(FTextBox, 1, 0);
  Table.SetSpan(FTextBox, 2, 1);
  FFontLabel := TLabel.Create(Table);
  FFontLabel.ShowsMnemonic := False;
  FFontLabel.Text := FontDescription(FFamily, FPointTenths, FBold);
  FFontLabel.AutoSize := True;
  FFontLabel.Anchors := [akLeft];
  Table.SetCell(FFontLabel, 0, 1);
  Table.SetSpan(FFontLabel, 2, 1);
  FontButton := TButton.Create(Table);
  FontButton.Text := '&Font...';
  FontButton.AutoSize := True;
  FontButton.Anchors := [akRight];
  FontButton.Margins := MakeSpacing(6, 0, 0, 0);
  FontButton.OnClick := @FontClicked;
  Table.SetCell(FontButton, 2, 1);
  AddOkAndCancel(DialogWidth, DialogHeight);
end;

procedure TTextDialog.FontClicked(Sender: TControl);
begin
  if AskForTextFont(FFamily, FPointTenths, FBold) then
    FFontLabel.Text := FontDescription(FFamily, FPointTenths, FBold);
end;

procedure TTextDialog.Showing;
begin
  FocusControl(FTextBox);
  FTextBox.SelectAll;
  inherited Showing;
  Say('dialog ' + Title);
end;

function AskForText(Owner: TWindow; var Text: string; var Family: LongInt; var PointTenths: LongWord;
  var Bold: Boolean): Boolean;
var
  Dialog: TTextDialog;
begin
  Dialog := TTextDialog.CreateTextDialog(Owner, Text, Family, PointTenths, Bold);
  try
    Result := Dialog.Execute;
    if Result then
    begin
      Text := Dialog.FTextBox.Text;
      Family := Dialog.FFamily;
      PointTenths := Dialog.FPointTenths;
      Bold := Dialog.FBold;
    end;
  finally
    Dialog.Free;
  end;
end;

end.
