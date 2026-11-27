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
  Save As for the image viewer: the format comes from the name's
  extension (PNG when there is none): PNG, JPEG, BMP, WebP (lossless),
  TIFF or GIF. JPEG asks for a quality (1 to 100) in a small dialog laid
  out by a table panel. What is saved is the picture as shown: turned as
  the view turns it, the animation's frame shown for a format of one
  frame, the whole animation for PNG (APNG) and WebP when it is not
  turned.
}
unit ImageViewer.Saving;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  Image.Model;

{ Asks for a file and a quality, and saves Image, or Shown (the picture
  as the view shows it: turned, the animation's frame) when Image is
  turned (Turned) or cannot be written whole. True and the path if it
  was saved; a failure is told in a message box. }
function SaveImageAs(Owner: TWindow; Image, Shown: TImage; Turned: Boolean;
  const StartFolder, SuggestedName: string; out SavedPath: string): Boolean;
{ The format a file name's extension asks for (PNG for none); False for
  one the viewer cannot write. }
function SaveFormatOfName(const Name: string; out Format: LongInt): Boolean;

implementation

uses
  SysUtils,
  Image.Errors,
  Image.Codecs,
  Image.Frames,
  Image.Files,
  Controls.Base,
  Controls.Labels,
  Controls.NumericUpDown,
  Controls.TablePanel,
  Controls.TableArrangement,
  Controls.LayoutRules,
  Controls.CommonDialogs,
  Controls.MessageBoxes,
  Controls.FileDialog,
  ImageViewer.Output;

const
  SaveFilter = '*.png;*.jpg;*.jpeg;*.bmp;*.webp;*.tif;*.tiff;*.gif';
  DefaultJpegQuality = 90;
  QualityDialogWidth = 280;
  QualityDialogHeight = 110;

type
  TQualityDialog = class(TCommonDialog)
  private
    FQuality: TNumericUpDown;
  protected
    procedure Showing; override;
  public
    constructor CreateQualityDialog(AOwner: TWindow; Quality: LongInt);
    property Quality: TNumericUpDown read FQuality;
  end;

constructor TQualityDialog.CreateQualityDialog(AOwner: TWindow; Quality: LongInt);
var
  Table: TTableLayoutPanel;
  Caption: TLabel;
begin
  inherited CreateDialog('JPEG Quality', QualityDialogWidth, QualityDialogHeight, AOwner);
  Table := TTableLayoutPanel.Create(Root);
  Table.SetBounds(DialogMargin, DialogMargin, QualityDialogWidth - 2 * DialogMargin, 30);
  Table.Anchors := [akLeft, akTop, akRight];
  Table.AddColumn(TrackAutoSize);
  Table.AddColumn(TrackPercent, 1);
  Table.AddRow(TrackAutoSize);
  Caption := TLabel.Create(Table);
  Caption.Text := '&Quality (1 to 100):';
  Caption.AutoSize := True;
  Caption.Anchors := [akLeft];
  Caption.Margins := MakeSpacing(0, 0, 8, 0);
  FQuality := TNumericUpDown.Create(Table);
  FQuality.Minimum := 1;
  FQuality.Maximum := 100;
  FQuality.Value := Quality;
  FQuality.AutoSize := True;
  FQuality.Anchors := [akLeft, akRight];
  Table.SetCell(Caption, 0, 0);
  Table.SetCell(FQuality, 1, 0);
  AddOkAndCancel(QualityDialogWidth, QualityDialogHeight);
end;

procedure TQualityDialog.Showing;
begin
  FocusControl(FQuality);
  inherited Showing;
end;

function AskQuality(Owner: TWindow; out Quality: LongInt): Boolean;
var
  Dialog: TQualityDialog;
begin
  Quality := DefaultJpegQuality;
  Dialog := TQualityDialog.CreateQualityDialog(Owner, DefaultJpegQuality);
  try
    Result := Dialog.Execute;
    if Result then
      Quality := Dialog.Quality.IntegerValue;
  finally
    Dialog.Free;
  end;
end;

function SaveFormatOfName(const Name: string; out Format: LongInt): Boolean;
var
  Extension: string;
  Found: TImageFormat;
begin
  Extension := LowerCase(ExtractFileExt(Name));
  if Extension = '' then
    Found := ImageFormatPng
  else
    Found := ImageFormatFromName(Copy(Extension, 2, Length(Extension)));
  Format := Ord(Found);
  Result := Found in [ImageFormatPng, ImageFormatJpeg, ImageFormatBmp, ImageFormatWebp, ImageFormatTiff,
    ImageFormatGif];
end;

{ What to write: the animation itself (PNG and WebP, not turned), else
  the picture as shown. }
function ImageToWrite(Image, Shown: TImage; Turned: Boolean; Format: TImageFormat): TImage;
begin
  if (Image is TAnimatedImage) and (Format in [ImageFormatPng, ImageFormatWebp]) and not Turned then
    Result := Image
  else
    Result := Shown;
end;

function SaveImageAs(Owner: TWindow; Image, Shown: TImage; Turned: Boolean;
  const StartFolder, SuggestedName: string; out SavedPath: string): Boolean;
var
  Chosen: string;
  FormatNumber: LongInt;
  Format: TImageFormat;
  Quality: LongInt;
  Written: TImage;
begin
  Result := False;
  SavedPath := '';
  if not ChooseFileToSave('Save As', StartFolder, SaveFilter, Chosen, SuggestedName) then
    Exit;
  if ExtractFileExt(Chosen) = '' then
    Chosen := Chosen + '.png';
  if not SaveFormatOfName(Chosen, FormatNumber) then
  begin
    ShowMessageBox('Image Viewer', 'Images cannot be saved as ' + ExtractFileExt(Chosen) + ' files.'#10 +
      'Use .png, .jpg, .bmp, .webp, .tif or .gif.', MessageOk, SignWarning, Owner);
    Exit;
  end;
  Format := TImageFormat(FormatNumber);
  Quality := DefaultJpegQuality;
  if (Format = ImageFormatJpeg) and not AskQuality(Owner, Quality) then
    Exit;
  Written := ImageToWrite(Image, Shown, Turned, Format);
  try
    SaveImage(Written, Chosen, Format, Quality);
  except
    on Error: Exception do
    begin
      ShowMessageBox('Image Viewer', 'Cannot save ' + Chosen + ':'#10 + Error.Message, MessageOk, SignError, Owner);
      Exit;
    end;
  end;
  Say('saved ' + Chosen + ' ' + ImageFormatName(Format) + ' ' + IntToStr(Quality));
  SavedPath := Chosen;
  Result := True;
end;

end.
