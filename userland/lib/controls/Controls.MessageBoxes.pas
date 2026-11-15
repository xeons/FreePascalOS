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
  OK when it is the only button).
}
unit Controls.MessageBoxes;

{$mode objfpc}
{$H+}

interface

type
  TMessageButtons = (MessageOk, MessageOkCancel, MessageYesNo, MessageYesNoCancel);
  TMessageSign = (SignNone, SignInformation, SignWarning, SignError, SignQuestion);

function ShowMessageBox(const Title, Text: string; Buttons: TMessageButtons = MessageOk;
  Sign: TMessageSign = SignInformation): LongInt;

implementation

uses
  Classes,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Drawing.Shapes,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Base,
  Controls.Text,
  Controls.Labels,
  Controls.Buttons,
  Controls.Dialogs;

const
  Margin = 12;
  SignSize = 32;
  ButtonWidth = 75;
  ButtonHeight = 23;
  ButtonGap = 6;
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

procedure TSignControl.Paint(var Canvas: TCanvas);
var
  Size: LongInt;
  Box: TRectangle;
  Triangle: array[0..2] of TPoint;
  Middle: LongInt;
  Stroke: LongInt;
  Offset: LongInt;
begin
  Size := RectangleHeight(PixelBounds);
  Box := MakeRectangle(0, 0, Size, Size);
  Middle := Size div 2;
  Stroke := Size div 8;
  case FSign of
    SignInformation, SignQuestion:
      begin
        if FSign = SignInformation then
          FillEllipse(Canvas, Box, InformationColor)
        else
          FillEllipse(Canvas, Box, QuestionColor);
        DrawEllipseOutline(Canvas, Box, Theme.DarkShadow);
        if FSign = SignInformation then
        begin
          { An "i": a dot over a bar. }
          FillRectangle(Canvas, MakeRectangle(Middle - Stroke div 2, Size div 5, Stroke, Stroke), MarkLight);
          FillRectangle(Canvas, MakeRectangle(Middle - Stroke div 2, Size * 2 div 5, Stroke, Size * 2 div 5), MarkLight);
        end
        else
          DrawTextInBox(Canvas, ControlBoldFace, '?', Box, AlignTextCenter, MarkLight);
      end;
    SignWarning:
      begin
        Triangle[0] := MakePoint(Middle, 0);
        Triangle[1] := MakePoint(Size, Size);
        Triangle[2] := MakePoint(0, Size);
        FillPolygon(Canvas, Triangle, WarningColor);
        DrawPolygonOutline(Canvas, [MakePoint(Middle, 0), MakePoint(Size - 1, Size - 1), MakePoint(0, Size - 1)],
          Theme.DarkShadow);
        { A "!": a bar over a dot. }
        FillRectangle(Canvas, MakeRectangle(Middle - Stroke div 2, Size * 3 div 10, Stroke, Size * 2 div 5), MarkDark);
        FillRectangle(Canvas, MakeRectangle(Middle - Stroke div 2, Size * 4 div 5, Stroke, Stroke), MarkDark);
      end;
    SignError:
      begin
        FillEllipse(Canvas, Box, ErrorColor);
        DrawEllipseOutline(Canvas, Box, Theme.DarkShadow);
        { A cross, Stroke pixels thick. }
        for Offset := -(Stroke div 2) to Stroke div 2 do
        begin
          DrawLine(Canvas, Size * 3 div 10 + Offset, Size * 3 div 10, Size * 7 div 10 + Offset, Size * 7 div 10, MarkLight);
          DrawLine(Canvas, Size * 7 div 10 + Offset, Size * 3 div 10, Size * 3 div 10 + Offset, Size * 7 div 10, MarkLight);
        end;
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

function ShowMessageBox(const Title, Text: string; Buttons: TMessageButtons; Sign: TMessageSign): LongInt;
const
  Captions: array[TMessageButtons, 0..2] of string = (('OK', '', ''), ('OK', 'Cancel', ''), ('Yes', 'No', ''),
    ('Yes', 'No', 'Cancel'));
  Results: array[TMessageButtons, 0..2] of LongInt = ((ResultOk, 0, 0), (ResultOk, ResultCancel, 0),
    (ResultYes, ResultNo, 0), (ResultYes, ResultNo, ResultCancel));
  Counts: array[TMessageButtons] of LongInt = (1, 2, 2, 3);
var
  Dialog: TDialog;
  Lines: TStringList;
  Index: LongInt;
  LineHeight: LongInt;
  TextWidthLogical: LongInt;
  TextHeightLogical: LongInt;
  TextLeft: LongInt;
  ContentHeight: LongInt;
  Width: LongInt;
  Height: LongInt;
  ButtonsWidth: LongInt;
  ButtonLeft: LongInt;
  SignControl: TSignControl;
  LineLabel: TLabel;
begin
  ConnectToDisplay;
  Lines := TStringList.Create;
  try
    SplitLines(Text, Lines);
    LineHeight := Unscaled(TextHeight(ControlFace)) + 2;
    TextWidthLogical := 0;
    for Index := 0 to Lines.Count - 1 do
      if Unscaled(TextWidth(ControlFace, Lines[Index])) > TextWidthLogical then
        TextWidthLogical := Unscaled(TextWidth(ControlFace, Lines[Index])) + 2;
    TextHeightLogical := Lines.Count * LineHeight;
    TextLeft := Margin;
    if Sign <> SignNone then
      TextLeft := Margin + SignSize + Margin;
    ContentHeight := TextHeightLogical;
    if (Sign <> SignNone) and (SignSize > ContentHeight) then
      ContentHeight := SignSize;
    ButtonsWidth := Counts[Buttons] * ButtonWidth + (Counts[Buttons] - 1) * ButtonGap;
    Width := TextLeft + TextWidthLogical + Margin;
    if Width < ButtonsWidth + 2 * Margin then
      Width := ButtonsWidth + 2 * Margin;
    Height := Margin + ContentHeight + Margin + ButtonHeight + Margin;
    Dialog := TDialog.CreateDialog(Title, Width, Height);
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
        LineLabel.Text := Lines[Index];
        LineLabel.SetBounds(TextLeft, Margin + (ContentHeight - TextHeightLogical) div 2 + Index * LineHeight,
          TextWidthLogical, LineHeight);
      end;
      ButtonLeft := (Width - ButtonsWidth) div 2;
      for Index := 0 to Counts[Buttons] - 1 do
        Dialog.AddButton(Captions[Buttons, Index], Results[Buttons, Index],
          ButtonLeft + Index * (ButtonWidth + ButtonGap), Height - Margin - ButtonHeight, ButtonWidth, ButtonHeight,
          Index = 0, Index = Counts[Buttons] - 1);
      Dialog.FocusControl(Dialog.DefaultControl);
      Result := Dialog.ShowModal;
      { The close button means the cancelling button. }
      if Result = ResultCancel then
        Result := Results[Buttons, Counts[Buttons] - 1];
    finally
      Dialog.Free;
    end;
  finally
    Lines.Free;
  end;
end;

end.
