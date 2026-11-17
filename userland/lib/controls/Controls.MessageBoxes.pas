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
  Message boxes: a dialog with a message, a sign of what kind it is,
  and buttons to answer.

  ShowMessageBox lays it out for its text (lines split at line feeds):
  the sign at the left, the text beside it, the buttons centred below.
  It returns the button pressed (Controls.Dialogs' Result values);
  Escape and the close button give the cancelling one (Cancel, No, or
  OK when it is the only button). Given an owner, the box is centred on
  it and stays above it; the owner is disabled while the box is open.

  ShowChoiceBox is the same with buttons of the caller's own (each as
  wide as its caption needs) and, if asked for, a check box under the
  text ("Do this for every file"): it returns the index of the button
  pressed and leaves whether the box was checked in the options. Its
  OnShowing hears of the dialog just before it appears (to tell where
  its buttons are, say).
}
unit Controls.MessageBoxes;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  Controls.Dialogs;

type
  TMessageButtons = (MessageOk, MessageOkCancel, MessageYesNo, MessageYesNoCancel);
  TMessageSign = (SignNone, SignInformation, SignWarning, SignError, SignQuestion);
  TChoiceBoxEvent = procedure(Dialog: TDialog) of object;

  TChoiceBoxOptions = record
    { The buttons' captions, left to right (mnemonics allowed); the
      first is pressed by Enter. }
    Captions: array of string;
    { The button Escape and the close button press. }
    CancelIndex: LongInt;
    { A check box under the text ('' for none), and whether it is
      checked (when the box opens, and as it was left). }
    CheckBoxText: string;
    Checked: Boolean;
    OnShowing: TChoiceBoxEvent;
  end;

function ShowMessageBox(const Title, Text: string; Buttons: TMessageButtons = MessageOk;
  Sign: TMessageSign = SignInformation; Owner: TWindow = nil): LongInt;
{ The index of the button pressed. }
function ShowChoiceBox(const Title, Text: string; var Options: TChoiceBoxOptions; Sign: TMessageSign = SignQuestion;
  Owner: TWindow = nil): LongInt;

implementation

uses
  Classes,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Drawing.Rasterizer,
  Drawing.SmoothLines,
  Drawing.SmoothShapes,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Base,
  Controls.Text,
  Controls.Labels,
  Controls.Buttons,
  Controls.Toggles,
  Controls.IconTheme;

const
  Margin = 12;
  SignSize = 32;
  ButtonWidth = 75;
  ButtonHeight = 23;
  ButtonGap = 6;
  CheckBoxHeight = 20;
  { Dialog results of the buttons: the first is this, the next one more
    (clear of ResultCancel, which the close button gives). }
  FirstChoiceResult = 100;
  InformationColor = $FF2F6DB5;
  WarningColor = $FFE8B400;
  ErrorColor = $FFC0302C;
  QuestionColor = $FF3C8CC8;
  MarkLight = $FFFFFFFF;
  MarkDark = $FF000000;

type
  { The sign: a coloured shape with a mark in it, at any size. }
  TSignControl = class(TControl)
  private
    FSign: TMessageSign;
  protected
    procedure Paint(var Canvas: TCanvas); override;
  end;

const
  { The theme's icon of each sign (drawn as shapes without it). }
  SignIconNames: array[TMessageSign] of string = ('', 'dialog-information', 'dialog-warning', 'dialog-error',
    'dialog-question');

{ The theme's picture of the sign at the control's size; without it the
  sign is drawn anti-aliased: round and slanted edges come out smooth at
  any size, the marks' upright bars stay on whole pixels. }
procedure TSignControl.Paint(var Canvas: TCanvas);
var
  Size: LongInt;
  Box: TRectangle;
  Triangle: array[0..2] of TPrecisePoint;
  Outline: array[0..2] of TPrecisePoint;
  Middle: LongInt;
  Stroke: LongInt;
  CrossStart: Double;
  CrossEnd: Double;
begin
  Size := RectangleHeight(PixelBounds);
  Box := MakeRectangle(0, 0, Size, Size);
  if (FSign <> SignNone) and DrawThemeIcon(Canvas, SignIconNames[FSign], Box) then
    Exit;
  Middle := Size div 2;
  Stroke := Size div 8;
  case FSign of
    SignInformation, SignQuestion:
      begin
        if FSign = SignInformation then
          FillSmoothEllipse(Canvas, Box, InformationColor)
        else
          FillSmoothEllipse(Canvas, Box, QuestionColor);
        DrawSmoothEllipseOutline(Canvas, Box, 1, Theme.DarkShadow);
        if FSign = SignInformation then
        begin
          { An "i": a dot over a bar. }
          FillSmoothEllipse(Canvas, MakeRectangle(Middle - Stroke div 2, Size div 5, Stroke, Stroke), MarkLight);
          FillRectangle(Canvas, MakeRectangle(Middle - Stroke div 2, Size * 2 div 5, Stroke, Size * 2 div 5), MarkLight);
        end
        else
          DrawTextInBox(Canvas, ControlBoldFace, '?', Box, AlignTextCenter, MarkLight);
      end;
    SignWarning:
      begin
        Triangle[0] := PrecisePoint(Size / 2, 0);
        Triangle[1] := PrecisePoint(Size, Size);
        Triangle[2] := PrecisePoint(0, Size);
        FillSmoothPolygon(Canvas, Triangle, WarningColor);
        { The outline through pixel centres just inside the triangle. }
        Outline[0] := PrecisePoint((Size - 1) / 2, 0.5);
        Outline[1] := PrecisePoint(Size - 1, Size - 1);
        Outline[2] := PrecisePoint(0, Size - 1);
        DrawSmoothPolygonOutline(Canvas, Outline, 1, Theme.DarkShadow);
        { A "!": a bar over a dot. }
        FillRectangle(Canvas, MakeRectangle(Middle - Stroke div 2, Size * 3 div 10, Stroke, Size * 2 div 5), MarkDark);
        FillSmoothEllipse(Canvas, MakeRectangle(Middle - Stroke div 2, Size * 4 div 5, Stroke, Stroke), MarkDark);
      end;
    SignError:
      begin
        FillSmoothEllipse(Canvas, Box, ErrorColor);
        DrawSmoothEllipseOutline(Canvas, Box, 1, Theme.DarkShadow);
        { A cross, Stroke pixels thick, from three tenths of the way to
          seven tenths (as pixel centres). }
        CrossStart := Size * 0.3;
        CrossEnd := Size * 0.7 - 1;
        DrawSmoothLine(Canvas, CrossStart, CrossStart, CrossEnd, CrossEnd, Stroke, MarkLight);
        DrawSmoothLine(Canvas, CrossEnd, CrossStart, CrossStart, CrossEnd, Stroke, MarkLight);
      end;
  end;
end;

procedure SplitLines(const Text: string; Lines: TStringList);
var
  Start: LongInt;
  Index: LongInt;
begin
  Start := 1;
  for Index := 1 to Length(Text) do
    if Text[Index] = #10 then
    begin
      Lines.Add(Copy(Text, Start, Index - Start));
      Start := Index + 1;
    end;
  Lines.Add(Copy(Text, Start, Length(Text) - Start + 1));
end;

{ How wide a button must be for Caption. }
function ButtonWidthFor(const Caption: string): LongInt;
begin
  Result := Unscaled(TextWidth(ControlFace, TextWithoutMnemonic(Caption))) + 20;
  if Result < ButtonWidth then
    Result := ButtonWidth;
end;

function ShowChoiceBox(const Title, Text: string; var Options: TChoiceBoxOptions; Sign: TMessageSign;
  Owner: TWindow): LongInt;
var
  Dialog: TDialog;
  Lines: TStringList;
  Index: LongInt;
  Count: LongInt;
  LineHeight: LongInt;
  TextWidthLogical: LongInt;
  TextHeightLogical: LongInt;
  TextLeft: LongInt;
  ContentHeight: LongInt;
  CheckRoom: LongInt;
  Width: LongInt;
  Height: LongInt;
  ButtonsWidth: LongInt;
  ButtonLeft: LongInt;
  SignControl: TSignControl;
  LineLabel: TLabel;
  CheckBox: TCheckBox;
  Chosen: LongInt;
begin
  ConnectToDisplay;
  Count := Length(Options.Captions);
  Lines := TStringList.Create;
  try
    SplitLines(Text, Lines);
    LineHeight := Unscaled(TextHeight(ControlFace)) + 2;
    TextWidthLogical := 0;
    for Index := 0 to Lines.Count - 1 do
      if Unscaled(TextWidth(ControlFace, Lines[Index])) > TextWidthLogical then
        TextWidthLogical := Unscaled(TextWidth(ControlFace, Lines[Index])) + 2;
    CheckRoom := 0;
    if Options.CheckBoxText <> '' then
    begin
      CheckRoom := CheckBoxHeight + 6;
      if Unscaled(TextWidth(ControlFace, TextWithoutMnemonic(Options.CheckBoxText))) + 28 > TextWidthLogical then
        TextWidthLogical := Unscaled(TextWidth(ControlFace, TextWithoutMnemonic(Options.CheckBoxText))) + 28;
    end;
    TextHeightLogical := Lines.Count * LineHeight;
    TextLeft := Margin;
    if Sign <> SignNone then
      TextLeft := Margin + SignSize + Margin;
    ContentHeight := TextHeightLogical;
    if (Sign <> SignNone) and (SignSize > ContentHeight) then
      ContentHeight := SignSize;
    ButtonsWidth := 0;
    for Index := 0 to Count - 1 do
      ButtonsWidth := ButtonsWidth + ButtonWidthFor(Options.Captions[Index]) + ButtonGap;
    if Count > 0 then
      ButtonsWidth := ButtonsWidth - ButtonGap;
    Width := TextLeft + TextWidthLogical + Margin;
    if Width < ButtonsWidth + 2 * Margin then
      Width := ButtonsWidth + 2 * Margin;
    Height := Margin + ContentHeight + CheckRoom + Margin + ButtonHeight + Margin;
    Dialog := TDialog.CreateDialog(Title, Width, Height, Owner);
    try
      if Sign <> SignNone then
      begin
        SignControl := TSignControl.Create(Dialog.Root);
        SignControl.FSign := Sign;
        SignControl.SetBounds(Margin, Margin, SignSize, SignSize);
      end;
      for Index := 0 to Lines.Count - 1 do
      begin
        LineLabel := TLabel.Create(Dialog.Root);
        LineLabel.ShowsMnemonic := False;
        LineLabel.Text := Lines[Index];
        LineLabel.SetBounds(TextLeft, Margin + (ContentHeight - TextHeightLogical) div 2 + Index * LineHeight,
          TextWidthLogical, LineHeight);
      end;
      CheckBox := nil;
      if Options.CheckBoxText <> '' then
      begin
        CheckBox := TCheckBox.Create(Dialog.Root);
        CheckBox.Text := Options.CheckBoxText;
        CheckBox.Checked := Options.Checked;
        CheckBox.SetBounds(TextLeft, Margin + ContentHeight + 6, TextWidthLogical, CheckBoxHeight);
      end;
      ButtonLeft := (Width - ButtonsWidth) div 2;
      for Index := 0 to Count - 1 do
      begin
        Dialog.AddButton(Options.Captions[Index], FirstChoiceResult + Index, ButtonLeft,
          Height - Margin - ButtonHeight, ButtonWidthFor(Options.Captions[Index]), ButtonHeight, Index = 0,
          Index = Options.CancelIndex);
        ButtonLeft := ButtonLeft + ButtonWidthFor(Options.Captions[Index]) + ButtonGap;
      end;
      Dialog.FocusControl(Dialog.DefaultControl);
      if Assigned(Options.OnShowing) then
        Options.OnShowing(Dialog);
      Chosen := Dialog.ShowModal - FirstChoiceResult;
      { The close button means the cancelling button. }
      if (Chosen < 0) or (Chosen >= Count) then
        Chosen := Options.CancelIndex;
      if CheckBox <> nil then
        Options.Checked := CheckBox.Checked;
      Result := Chosen;
    finally
      Dialog.Free;
    end;
  finally
    Lines.Free;
  end;
end;

function ShowMessageBox(const Title, Text: string; Buttons: TMessageButtons; Sign: TMessageSign;
  Owner: TWindow): LongInt;
const
  { OK and Cancel need no mnemonic: Enter and Escape press them. }
  Captions: array[TMessageButtons, 0..2] of string = (('OK', '', ''), ('OK', 'Cancel', ''), ('&Yes', '&No', ''),
    ('&Yes', '&No', 'Cancel'));
  Results: array[TMessageButtons, 0..2] of LongInt = ((ResultOk, 0, 0), (ResultOk, ResultCancel, 0),
    (ResultYes, ResultNo, 0), (ResultYes, ResultNo, ResultCancel));
  Counts: array[TMessageButtons] of LongInt = (1, 2, 2, 3);
var
  Options: TChoiceBoxOptions;
  Index: LongInt;
begin
  Options := Default(TChoiceBoxOptions);
  SetLength(Options.Captions, Counts[Buttons]);
  for Index := 0 to Counts[Buttons] - 1 do
    Options.Captions[Index] := Captions[Buttons, Index];
  Options.CancelIndex := Counts[Buttons] - 1;
  Result := Results[Buttons, ShowChoiceBox(Title, Text, Options, Sign, Owner)];
end;

end.
