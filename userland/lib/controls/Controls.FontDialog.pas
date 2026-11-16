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
  The font dialog: a user picks a family (the theme's proportional text
  family or its monospaced one), a size, in points, and bold or
  regular, seeing a sample of the text as it will look.

  The sizes listed are the ones the family's fonts come in, at this
  display's DPI: the system has faces of some pixel sizes only, so
  each listed size is the smallest whole point size (or half, if no
  whole one fits) that picks that face. A size between two would only
  look like the smaller one. The sample is drawn with the very face a
  program asking for that size gets (Windowing.Fonts).

  ChooseFont does it in one call; TFontDialog is there for a program
  that wants more (where the sizes are, say).
}
unit Controls.FontDialog;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Windowing.Fonts,
  Controls.Base,
  Controls.ListBox,
  Controls.ComboBox,
  Controls.Toggles,
  Controls.CommonDialogs;

type
  { The sample text, in a given size and weight, on a field. }
  TFontPreview = class(TControl)
  private
    FFamily: TFontFamily;
    FPointTenths: LongWord;
    FBold: Boolean;
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    procedure ShowFont(Family: TFontFamily; PointTenths: LongWord; Bold: Boolean);
  end;

  TFontDialog = class(TCommonDialog)
  private
    FSizes: array of LongWord;
    FFamilyBox: TComboBox;
    FSizeList: TListBox;
    FBoldBox: TCheckBox;
    FPreview: TFontPreview;
    procedure BuildControls;
    procedure ListSizes;
    procedure ChoiceChanged(Sender: TControl);
    procedure FamilyChanged(Sender: TControl);
    function GetFamily: TFontFamily;
    procedure SetFamily(Value: TFontFamily);
    function GetPointTenths: LongWord;
    procedure SetPointTenths(Value: LongWord);
    function GetBold: Boolean;
    procedure SetBold(Value: Boolean);
  public
    constructor CreateFontDialog(const ATitle: string; InitialPointTenths: LongWord; InitialBold: Boolean;
      InitialFamily: TFontFamily = FontFamilyText);
    { Which family: changing it lists that family's sizes (keeping the
      size chosen as near as they allow). }
    property Family: TFontFamily read GetFamily write SetFamily;
    { The size chosen, in tenths of a point: one of the sizes listed
      (setting another chooses the listed one that looks the same). }
    property PointTenths: LongWord read GetPointTenths write SetPointTenths;
    property Bold: Boolean read GetBold write SetBold;
    property FamilyBox: TComboBox read FFamilyBox;
    property SizeList: TListBox read FSizeList;
    property BoldBox: TCheckBox read FBoldBox;
    property Preview: TFontPreview read FPreview;
  end;

{ The text for a size in tenths of a point: "9", "10.5". }
function PointSizeText(PointTenths: LongWord): string;
{ Shows a font dialog starting at PointTenths and Bold; True and the
  choice in them if OK ended it. }
function ChooseFont(var PointTenths: LongWord; var Bold: Boolean): Boolean;
{ The same with a choice of family too. }
function ChooseFontOfFamily(var Family: TFontFamily; var PointTenths: LongWord; var Bold: Boolean): Boolean;

implementation

uses
  SysUtils,
  Drawing.Rectangles,
  Drawing.Bevels,
  Font.Faces,
  Font.Text,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Labels;

const
  SampleText = 'AaBbYyZz 0123';
  DialogWidth = 360;
  DialogHeight = 278;
  FamilyTop = 26;
  FamilyWidth = 200;
  SizeCaptionTop = 56;
  ListTop = 74;
  ListWidth = 100;
  ListHeight = 160;
  RightLeft = 120;
  RightWidth = 232;
  PreviewTop = 118;
  PreviewHeight = 116;
  { Sizes are looked for up to this, in tenths of a point. }
  LargestPointTenths = 2000;

function PointSizeText(PointTenths: LongWord): string;
begin
  Result := IntToStr(PointTenths div 10);
  if PointTenths mod 10 <> 0 then
    Result := Result + '.' + IntToStr(PointTenths mod 10);
end;

{ The pixel size of the face a program gets for PointTenths (known
  without reading the face). }
function FaceSizeFor(Family: TFontFamily; PointTenths: LongWord): LongInt;
begin
  Result := FamilyFaceSize(Family, PointTenths, False);
end;

{ The smallest size in steps of Step tenths that picks the face Height
  pixels high; 0 if none does. (Sizes too small for any face pick the
  smallest one too; they are not that face's size.) }
function SmallestSizeFor(Family: TFontFamily; Height: LongInt; Step: LongWord): LongWord;
var
  Size: LongWord;
begin
  Size := Step;
  while Size <= LargestPointTenths do
  begin
    if (PixelHeightFor(Size, DisplayDpi) >= Height) and (FaceSizeFor(Family, Size) = Height) then
      Exit(Size);
    Size := Size + Step;
  end;
  Result := 0;
end;

{ --- TFontPreview ---------------------------------------------------------- }

procedure TFontPreview.ShowFont(Family: TFontFamily; PointTenths: LongWord; Bold: Boolean);
begin
  FFamily := Family;
  FPointTenths := PointTenths;
  FBold := Bold;
  Invalidate;
end;

procedure TFontPreview.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Inner: TCanvas;
  Face: PFontFace;
  Left: LongInt;
  Top: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Field);
  DrawBevel(Canvas, Box, SunkenThemeBevel);
  Face := FamilyFontFace(FFamily, FPointTenths, FBold);
  if Face = nil then
    Exit;
  Inner := Canvas;
  NarrowCanvasClip(Inner, InflateRectangle(Box, -2));
  { Centred; a sample wider than the box starts at its left edge, so
    its beginning shows. }
  Left := (RectangleWidth(Box) - MeasureText(Face^, SampleText)) div 2;
  if Left < Scaled(4) then
    Left := Scaled(4);
  Top := (RectangleHeight(Box) - Face^.Height) div 2;
  DrawText(Inner, Face^, Left, Top, SampleText, Theme.FieldText);
end;

{ --- TFontDialog ----------------------------------------------------------- }

constructor TFontDialog.CreateFontDialog(const ATitle: string; InitialPointTenths: LongWord; InitialBold: Boolean;
  InitialFamily: TFontFamily);
begin
  inherited CreateDialog(ATitle, DialogWidth, DialogHeight);
  BuildControls;
  FFamilyBox.ItemIndex := Ord(InitialFamily);
  ListSizes;
  SetPointTenths(InitialPointTenths);
  SetBold(InitialBold);
  FSizeList.OnChange := @ChoiceChanged;
  FBoldBox.OnChange := @ChoiceChanged;
  FFamilyBox.OnChange := @FamilyChanged;
  ChoiceChanged(nil);
end;

procedure TFontDialog.BuildControls;
var
  Caption: TLabel;
begin
  Caption := TLabel.Create(Root);
  Caption.Text := '&Font:';
  Caption.SetBounds(DialogMargin, DialogMargin, FamilyWidth, 16);
  FFamilyBox := TComboBox.Create(Root);
  FFamilyBox.SetBounds(DialogMargin, FamilyTop, FamilyWidth, 22);
  FFamilyBox.Items.Add(FamilyName(FontFamilyText));
  FFamilyBox.Items.Add(FamilyName(FontFamilyFixed));
  Caption := TLabel.Create(Root);
  Caption.Text := '&Size (points):';
  Caption.SetBounds(DialogMargin, SizeCaptionTop, ListWidth + 8, 16);
  FSizeList := TListBox.Create(Root);
  FSizeList.SetBounds(DialogMargin, ListTop, ListWidth, ListHeight);
  FBoldBox := TCheckBox.Create(Root);
  FBoldBox.Text := '&Bold';
  FBoldBox.SetBounds(RightLeft, ListTop, RightWidth, 20);
  Caption := TLabel.Create(Root);
  Caption.Text := 'Sample:';
  Caption.SetBounds(RightLeft, PreviewTop - 18, RightWidth, 16);
  FPreview := TFontPreview.Create(Root);
  FPreview.SetBounds(RightLeft, PreviewTop, RightWidth, PreviewHeight);
  AddOkAndCancel(DialogWidth, DialogHeight);
end;

procedure TFontDialog.ListSizes;
var
  Index: LongInt;
  Height: LongInt;
  Size: LongWord;
  Known: LongInt;
  AlreadyListed: Boolean;
begin
  { Each regular face's height once, smallest first (the faces may come
    in any order, bold and regular mixed). }
  FSizes := nil;
  for Index := 0 to FamilyFaceCount(GetFamily) - 1 do
  begin
    if FamilyFace(GetFamily, Index)^.Bold then
      Continue;
    Height := FamilyFace(GetFamily, Index)^.Size;
    Size := SmallestSizeFor(GetFamily, Height, 10);
    if Size = 0 then
      Size := SmallestSizeFor(GetFamily, Height, 5);
    if Size = 0 then
      Continue;
    AlreadyListed := False;
    for Known := 0 to High(FSizes) do
      if FSizes[Known] = Size then
        AlreadyListed := True;
    if AlreadyListed then
      Continue;
    SetLength(FSizes, Length(FSizes) + 1);
    Known := High(FSizes);
    while (Known > 0) and (FSizes[Known - 1] > Size) do
    begin
      FSizes[Known] := FSizes[Known - 1];
      Dec(Known);
    end;
    FSizes[Known] := Size;
  end;
  FSizeList.Items.Clear;
  for Index := 0 to High(FSizes) do
    FSizeList.Items.Add(PointSizeText(FSizes[Index]));
end;

function TFontDialog.GetPointTenths: LongWord;
begin
  if FSizeList.ItemIndex >= 0 then
    Result := FSizes[FSizeList.ItemIndex]
  else
    Result := Theme.TextPoints;
end;

procedure TFontDialog.SetPointTenths(Value: LongWord);
var
  Index: LongInt;
  Wanted: LongInt;
  Nearest: LongInt;
begin
  Wanted := FaceSizeFor(GetFamily, Value);
  for Index := 0 to High(FSizes) do
    if FaceSizeFor(GetFamily, FSizes[Index]) = Wanted then
    begin
      FSizeList.ItemIndex := Index;
      Exit;
    end;
  { No listed size looks the same (another family's size): the nearest. }
  Nearest := -1;
  for Index := 0 to High(FSizes) do
    if (Nearest < 0) or (Abs(LongInt(FSizes[Index]) - LongInt(Value)) <
       Abs(LongInt(FSizes[Nearest]) - LongInt(Value))) then
      Nearest := Index;
  if Nearest >= 0 then
    FSizeList.ItemIndex := Nearest;
end;

function TFontDialog.GetFamily: TFontFamily;
begin
  if FFamilyBox.ItemIndex = Ord(FontFamilyFixed) then
    Result := FontFamilyFixed
  else
    Result := FontFamilyText;
end;

procedure TFontDialog.SetFamily(Value: TFontFamily);
begin
  FFamilyBox.ItemIndex := Ord(Value);
end;

procedure TFontDialog.FamilyChanged(Sender: TControl);
var
  Chosen: LongWord;
begin
  Chosen := GetPointTenths;
  ListSizes;
  SetPointTenths(Chosen);
  ChoiceChanged(nil);
end;

function TFontDialog.GetBold: Boolean;
begin
  Result := FBoldBox.Checked;
end;

procedure TFontDialog.SetBold(Value: Boolean);
begin
  FBoldBox.Checked := Value;
end;

procedure TFontDialog.ChoiceChanged(Sender: TControl);
begin
  FPreview.ShowFont(GetFamily, GetPointTenths, GetBold);
end;

function ChooseFontOfFamily(var Family: TFontFamily; var PointTenths: LongWord; var Bold: Boolean): Boolean;
var
  Dialog: TFontDialog;
begin
  Dialog := TFontDialog.CreateFontDialog('Font', PointTenths, Bold, Family);
  try
    Result := Dialog.Execute;
    if Result then
    begin
      Family := Dialog.Family;
      PointTenths := Dialog.PointTenths;
      Bold := Dialog.Bold;
    end;
  finally
    Dialog.Free;
  end;
end;

function ChooseFont(var PointTenths: LongWord; var Bold: Boolean): Boolean;
var
  Family: TFontFamily;
begin
  Family := FontFamilyText;
  Result := ChooseFontOfFamily(Family, PointTenths, Bold);
end;

end.
