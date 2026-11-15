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
  The font dialog: a user picks a size, in points, and bold or regular,
  seeing a sample of the text as it will look.

  The sizes listed are the ones the system's fonts come in, at this
  display's DPI: the system has bitmap faces of a few pixel heights, so
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
  Controls.Base,
  Controls.ListBox,
  Controls.Toggles,
  Controls.CommonDialogs;

type
  { The sample text, in a given size and weight, on a field. }
  TFontPreview = class(TControl)
  private
    FPointTenths: LongWord;
    FBold: Boolean;
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    procedure ShowFont(PointTenths: LongWord; Bold: Boolean);
  end;

  TFontDialog = class(TCommonDialog)
  private
    FSizes: array of LongWord;
    FSizeList: TListBox;
    FBoldBox: TCheckBox;
    FPreview: TFontPreview;
    procedure BuildControls;
    procedure ListSizes;
    procedure ChoiceChanged(Sender: TControl);
    function GetPointTenths: LongWord;
    procedure SetPointTenths(Value: LongWord);
    function GetBold: Boolean;
    procedure SetBold(Value: Boolean);
  public
    constructor CreateFontDialog(const ATitle: string; InitialPointTenths: LongWord; InitialBold: Boolean);
    { The size chosen, in tenths of a point: one of the sizes listed
      (setting another chooses the listed one that looks the same). }
    property PointTenths: LongWord read GetPointTenths write SetPointTenths;
    property Bold: Boolean read GetBold write SetBold;
    property SizeList: TListBox read FSizeList;
    property BoldBox: TCheckBox read FBoldBox;
    property Preview: TFontPreview read FPreview;
  end;

{ The text for a size in tenths of a point: "9", "10.5". }
function PointSizeText(PointTenths: LongWord): string;
{ Shows a font dialog starting at PointTenths and Bold; True and the
  choice in them if OK ended it. }
function ChooseFont(var PointTenths: LongWord; var Bold: Boolean): Boolean;

implementation

uses
  SysUtils,
  Drawing.Rectangles,
  Drawing.Bevels,
  Font.Psf,
  Font.Text,
  Windowing.Theme,
  Windowing.Fonts,
  Windowing.Connection,
  Controls.Labels;

const
  SampleText = 'AaBbYyZz 0123';
  DialogWidth = 360;
  DialogHeight = 230;
  ListTop = 26;
  ListWidth = 100;
  ListHeight = 160;
  RightLeft = 120;
  RightWidth = 232;
  PreviewTop = 70;
  PreviewHeight = 116;
  { Sizes are looked for up to this, in tenths of a point. }
  LargestPointTenths = 2000;

function PointSizeText(PointTenths: LongWord): string;
begin
  Result := IntToStr(PointTenths div 10);
  if PointTenths mod 10 <> 0 then
    Result := Result + '.' + IntToStr(PointTenths mod 10);
end;

{ The height of the face a program gets for PointTenths. }
function FaceHeightFor(PointTenths: LongWord): LongInt;
var
  Face: PFontFace;
begin
  Face := FontFace(PointTenths, False);
  if Face = nil then
    Result := 0
  else
    Result := Face^.Height;
end;

{ The smallest size in steps of Step tenths that picks the face Height
  pixels high; 0 if none does. (Sizes too small for any face pick the
  smallest one too; they are not that face's size.) }
function SmallestSizeFor(Height: LongInt; Step: LongWord): LongWord;
var
  Size: LongWord;
begin
  Size := Step;
  while Size <= LargestPointTenths do
  begin
    if (PixelHeightFor(Size, DisplayDpi) >= Height) and (FaceHeightFor(Size) = Height) then
      Exit(Size);
    Size := Size + Step;
  end;
  Result := 0;
end;

{ --- TFontPreview ---------------------------------------------------------- }

procedure TFontPreview.ShowFont(PointTenths: LongWord; Bold: Boolean);
begin
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
  Face := FontFace(FPointTenths, FBold);
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

constructor TFontDialog.CreateFontDialog(const ATitle: string; InitialPointTenths: LongWord; InitialBold: Boolean);
begin
  inherited CreateDialog(ATitle, DialogWidth, DialogHeight);
  BuildControls;
  ListSizes;
  SetPointTenths(InitialPointTenths);
  SetBold(InitialBold);
  FSizeList.OnChange := @ChoiceChanged;
  FBoldBox.OnChange := @ChoiceChanged;
  ChoiceChanged(nil);
end;

procedure TFontDialog.BuildControls;
var
  Caption: TLabel;
begin
  Caption := TLabel.Create(Root);
  Caption.Text := 'Size (points):';
  Caption.SetBounds(DialogMargin, DialogMargin, ListWidth + 8, 16);
  FSizeList := TListBox.Create(Root);
  FSizeList.SetBounds(DialogMargin, ListTop, ListWidth, ListHeight);
  FBoldBox := TCheckBox.Create(Root);
  FBoldBox.Text := 'Bold';
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
  for Index := 0 to SystemFaceCount - 1 do
  begin
    if SystemFace(Index)^.Bold then
      Continue;
    Height := SystemFace(Index)^.Height;
    Size := SmallestSizeFor(Height, 10);
    if Size = 0 then
      Size := SmallestSizeFor(Height, 5);
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
begin
  Wanted := FaceHeightFor(Value);
  for Index := 0 to High(FSizes) do
    if FaceHeightFor(FSizes[Index]) = Wanted then
    begin
      FSizeList.ItemIndex := Index;
      Exit;
    end;
  if Length(FSizes) > 0 then
    FSizeList.ItemIndex := 0;
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
  FPreview.ShowFont(GetPointTenths, GetBold);
end;

function ChooseFont(var PointTenths: LongWord; var Bold: Boolean): Boolean;
var
  Dialog: TFontDialog;
begin
  Dialog := TFontDialog.CreateFontDialog('Font', PointTenths, Bold);
  try
    Result := Dialog.Execute;
    if Result then
    begin
      PointTenths := Dialog.PointTenths;
      Bold := Dialog.Bold;
    end;
  finally
    Dialog.Free;
  end;
end;

end.
