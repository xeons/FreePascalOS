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
  dialogtour - the common dialogs of libcontrols, for trying and
  testing them

  dialogtour

  A window with a button for each common dialog: open a file (starting
  at /), save a file (starting at /tmp, showing *.txt), choose a colour
  and choose a font. Prints what happens, a line each:

    place NAME X Y        where NAME is on the screen (pixels): the
                          buttons and the client area's top left
                          (tour-client) at start; a dialog's controls when it
                          appears (and the file dialogs' rows and client
                          area, dialog-client, whenever they show a
                          folder)
    opened PATH           the open dialog's choice
    saved PATH            the save dialog's choice
    color RRGGBB          the colour dialog's choice
    font TENTHS WEIGHT    the font dialog's choice (tenths of a point,
                          bold or regular)
    cancelled NAME        a dialog was cancelled
  It ends when its window is closed.
}
program DialogTour;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Streams,
  Drawing.Colors,
  Drawing.Rectangles,
  Windowing.Connection,
  Windowing.Windows,
  Controls.Base,
  Controls.Window,
  Controls.Labels,
  Controls.Buttons,
  Controls.ListView,
  Controls.CommonDialogs,
  Controls.FileDialog,
  Controls.ColorDialog,
  Controls.FontDialog;

type
  TTourWindow = class(TControlWindow)
  private
    FOpenButton: TButton;
    FSaveButton: TButton;
    FColorButton: TButton;
    FFontButton: TButton;
    FResult: TLabel;
    FColor: TColor;
    FPointTenths: LongWord;
    FBold: Boolean;
    function AddTourButton(const Caption: string; Top: LongInt): TButton;
    procedure OpenClicked(Sender: TControl);
    procedure SaveClicked(Sender: TControl);
    procedure ColorClicked(Sender: TControl);
    procedure FontClicked(Sender: TControl);
    procedure FolderShown(Dialog: TCommonDialog);
    procedure FolderChanged(Dialog: TCommonDialog);
    procedure ColorDialogShowing(Dialog: TCommonDialog);
    procedure FontDialogShowing(Dialog: TCommonDialog);
    procedure Report(const Text: string);
  public
    constructor Create;
    procedure TellPlaces;
  end;

procedure Say(const Text: string);
begin
  PrintStringLine(Text);
  FlushStream(StandardOutput);
end;

{ Where the point (X, Y) of Control (its pixels) is on the screen. }
procedure TellPlace(const Name: string; Window: TWindow; Control: TControl; X, Y: LongInt);
begin
  Say(Format('place %s %d %d', [Name, Scaled(Window.ScreenLeft) + Control.PixelBounds.Left + X,
    Scaled(Window.ScreenTop) + Control.PixelBounds.Top + Y]));
end;

procedure TellMiddle(const Name: string; Window: TWindow; Control: TControl);
begin
  TellPlace(Name, Window, Control, RectangleWidth(Control.PixelBounds) div 2,
    RectangleHeight(Control.PixelBounds) div 2);
end;

constructor TTourWindow.Create;
begin
  inherited Create('Dialog tour', 60, 40, 240, 180);
  IconName := 'app-dialogs';
  FOpenButton := AddTourButton('Open...', 12);
  FOpenButton.OnClick := @OpenClicked;
  FSaveButton := AddTourButton('Save...', 42);
  FSaveButton.OnClick := @SaveClicked;
  FColorButton := AddTourButton('Colour...', 72);
  FColorButton.OnClick := @ColorClicked;
  FFontButton := AddTourButton('Font...', 102);
  FFontButton.OnClick := @FontClicked;
  FResult := TLabel.Create(Root);
  FResult.SetBounds(12, 140, 216, 20);
  FColor := $FF336699;
  FPointTenths := 90;
end;

function TTourWindow.AddTourButton(const Caption: string; Top: LongInt): TButton;
begin
  Result := TButton.Create(Root);
  Result.Text := Caption;
  Result.SetBounds(12, Top, 100, 24);
end;

procedure TTourWindow.TellPlaces;
begin
  TellMiddle('open-button', Self, FOpenButton);
  TellMiddle('save-button', Self, FSaveButton);
  TellMiddle('color-button', Self, FColorButton);
  TellMiddle('font-button', Self, FFontButton);
  TellPlace('tour-client', Self, Root, 0, 0);
end;

procedure TTourWindow.Report(const Text: string);
begin
  Say(Text);
  FResult.Text := Text;
end;

procedure TTourWindow.FolderShown(Dialog: TCommonDialog);
var
  FileDialog: TFileDialog;
  List: TListView;
  Row: LongInt;
  Name: string;
begin
  { Every row that shows (names with spaces cannot be told apart in a
    place line, so they are left out), and OK. }
  FileDialog := TFileDialog(Dialog);
  List := FileDialog.FileList;
  for Row := 0 to List.RowCount - 1 do
  begin
    Name := List.Cells[Row, 0];
    if List.RowMiddle(Row) >= RectangleHeight(List.PixelBounds) then
      Break;
    if Pos(' ', Name) = 0 then
      TellPlace('file-' + Name, Dialog, List, Scaled(40), List.RowMiddle(Row));
  end;
  TellMiddle('file-ok', Dialog, Dialog.OkButton);
  TellPlace('dialog-client', Dialog, Dialog.Root, 0, 0);
end;

{ The list was read again (another program changed the folder): every
  row it has now. }
procedure TTourWindow.FolderChanged(Dialog: TCommonDialog);
var
  List: TListView;
  Row: LongInt;
begin
  List := TFileDialog(Dialog).FileList;
  Say('folder changed');
  for Row := 0 to List.RowCount - 1 do
    Say('row ' + List.Cells[Row, 0]);
end;

procedure TTourWindow.OpenClicked(Sender: TControl);
var
  Dialog: TOpenFileDialog;
begin
  Dialog := TOpenFileDialog.CreateFileDialog('Open', '/', '');
  try
    Dialog.OnFolderShown := @FolderShown;
    Dialog.OnFolderChanged := @FolderChanged;
    FolderShown(Dialog);
    if Dialog.Execute then
      Report('opened ' + Dialog.Path)
    else
      Report('cancelled open');
  finally
    Dialog.Free;
  end;
end;

procedure TTourWindow.SaveClicked(Sender: TControl);
var
  Path: string;
begin
  if ChooseFileToSave('Save', '/tmp', '*.txt', Path) then
    Report('saved ' + Path)
  else
    Report('cancelled save');
end;

procedure TTourWindow.ColorDialogShowing(Dialog: TCommonDialog);
var
  Index: LongInt;
begin
  for Index := 0 to BasicColorCount - 1 do
    TellMiddle('color-' + IntToStr(Index), Dialog, TColorDialog(Dialog).BasicSwatches[Index]);
  TellMiddle('color-ok', Dialog, Dialog.OkButton);
end;

procedure TTourWindow.ColorClicked(Sender: TControl);
var
  Dialog: TColorDialog;
begin
  Dialog := TColorDialog.CreateColorDialog('Colour', FColor);
  try
    Dialog.OnShowing := @ColorDialogShowing;
    if Dialog.Execute then
    begin
      FColor := Dialog.Color;
      Report('color ' + IntToHex(FColor and $FFFFFF, 6));
    end
    else
      Report('cancelled color');
  finally
    Dialog.Free;
  end;
end;

procedure TTourWindow.FontDialogShowing(Dialog: TCommonDialog);
var
  FontDialog: TFontDialog;
  Index: LongInt;
  ItemHeight: LongInt;
  Middle: LongInt;
begin
  { The sizes that show in the list (from its top row; one whose middle
    is past the bottom cannot be clicked). }
  FontDialog := TFontDialog(Dialog);
  ItemHeight := FontDialog.SizeList.ItemHeight;
  for Index := FontDialog.SizeList.TopIndex to FontDialog.SizeList.Items.Count - 1 do
  begin
    Middle := 2 + (Index - FontDialog.SizeList.TopIndex) * ItemHeight + ItemHeight div 2;
    if Middle >= RectangleHeight(FontDialog.SizeList.PixelBounds) - 2 then
      Break;
    TellPlace('size-' + FontDialog.SizeList.Items[Index], Dialog, FontDialog.SizeList, Scaled(30), Middle);
  end;
  TellPlace('bold', Dialog, FontDialog.BoldBox, Scaled(8), RectangleHeight(FontDialog.BoldBox.PixelBounds) div 2);
  TellMiddle('font-ok', Dialog, Dialog.OkButton);
end;

procedure TTourWindow.FontClicked(Sender: TControl);
const
  Weights: array[Boolean] of string = ('regular', 'bold');
var
  Dialog: TFontDialog;
begin
  Dialog := TFontDialog.CreateFontDialog('Font', FPointTenths, FBold);
  try
    Dialog.OnShowing := @FontDialogShowing;
    if Dialog.Execute then
    begin
      FPointTenths := Dialog.PointTenths;
      FBold := Dialog.Bold;
      Report('font ' + IntToStr(FPointTenths) + ' ' + Weights[FBold]);
    end
    else
      Report('cancelled font');
  finally
    Dialog.Free;
  end;
end;

var
  Window: TTourWindow;
begin
  Window := TTourWindow.Create;
  Window.Show;
  Window.TellPlaces;
  RunMessageLoop;
end.
