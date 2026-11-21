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
  A preview pane: shows what a file holds without opening it in a
  program. Previewers (TPreviewProvider) each say which files they can
  show and make the control that shows one; the host asks them in the
  order they were added (a program adds its own first, before the
  built-in ones, to take over a type) and shows the first that accepts.

  Built in: pictures (any format libimage reads, fitted, animations
  playing) and text (the first PreviewTextLimit bytes of a file that is
  UTF-8 without zero bytes, read-only, in the monospaced face for code).
  The web view's previewer for HTML lives with the web view (it needs
  libwebview), the file manager's summaries (a folder's contents, a
  sound's length) are TPreviewSummary, which any previewer may return:
  a large icon, a title and lines of "name: value".

  With nothing to show the pane says why in its middle ("Select a file
  to preview.", "No preview available.").
}
unit Controls.PreviewHost;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Canvas,
  Controls.Base,
  Controls.Icons;

const
  PreviewTextLimit = 256 * 1024;

type
  TPreviewProvider = class
  public
    { Whether this previewer shows the file at Path (Extension: small
      letters, no dot). }
    function CanPreview(const Path, Extension: string): Boolean; virtual; abstract;
    { The control showing it, made in Parent (nil if it could not be
      read after all). }
    function CreatePreview(Parent: TControl; const Path: string): TControl; virtual; abstract;
  end;

  TImagePreviewProvider = class(TPreviewProvider)
  public
    function CanPreview(const Path, Extension: string): Boolean; override;
    function CreatePreview(Parent: TControl; const Path: string): TControl; override;
  end;

  TTextPreviewProvider = class(TPreviewProvider)
  public
    function CanPreview(const Path, Extension: string): Boolean; override;
    function CreatePreview(Parent: TControl; const Path: string): TControl; override;
  end;

  { A summary: a large icon, a title and lines of "name: value". }
  TPreviewSummary = class(TControl)
  private
    FTitle: string;
    FIconName: string;
    FIconKind: TStockIcon;
    FNames: TStringList;
    FValues: TStringList;
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    procedure SetTitle(const Title, IconName: string; IconKind: TStockIcon);
    procedure AddLine(const Name, Value: string);
  end;

  TPreviewHost = class(TControl)
  private
    FProviders: TList;
    FPreview: TControl;
    FMessage: string;
    FPath: string;
    procedure DropPreview;
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    { Adds a previewer (the host owns it); AtFront: asked before the
      others. }
    procedure AddProvider(Provider: TPreviewProvider; AtFront: Boolean = False);
    { Shows the file at Path; False (and the message) if none can. }
    function ShowFile(const Path: string): Boolean;
    { Shows a control made elsewhere (a summary), which the host takes. }
    procedure ShowControl(Control: TControl);
    procedure ShowMessage(const MessageText: string);
    property Path: string read FPath;
    property Preview: TControl read FPreview;
  end;

{ Whether the first bytes of the file at Path look like text (UTF-8, no
  zero byte). }
function FileLooksLikeText(const Path: string): Boolean;

implementation

uses
  SysUtils,
  Drawing.Rectangles,
  Drawing.Colors,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text,
  Controls.IconTheme,
  Controls.Painting,
  Controls.PictureBox,
  Controls.PictureGeometry,
  Controls.TextEdit,
  Image.Files,
  Image.Codecs;

const
  NothingSelectedText = 'Select a file to preview.';
  NoPreviewText = 'No preview available.';
  SummaryIconSize = 64;

function ReadFileStart(const Path: string; Limit: LongInt): TBytes;
var
  Stream: TFileStream;
  Count: LongInt;
begin
  Result := nil;
  try
    Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      Count := Stream.Size;
      if Count > Limit then
        Count := Limit;
      SetLength(Result, Count);
      if Count > 0 then
        Stream.ReadBuffer(Result[0], Count);
    finally
      Stream.Free;
    end;
  except
    on Exception do
      Result := nil;
  end;
end;

function BytesLookLikeText(const Bytes: TBytes): Boolean;
var
  Index: LongInt;
  Follow: LongInt;
  Value: Byte;
begin
  Index := 0;
  while Index < Length(Bytes) do
  begin
    Value := Bytes[Index];
    if Value = 0 then
      Exit(False);
    if Value < $80 then
      Follow := 0
    else if (Value and $E0) = $C0 then
      Follow := 1
    else if (Value and $F0) = $E0 then
      Follow := 2
    else if (Value and $F8) = $F0 then
      Follow := 3
    else
      Exit(False);
    Inc(Index);
    while Follow > 0 do
    begin
      { A character cut off at the end of what was read is fine. }
      if Index >= Length(Bytes) then
        Exit(True);
      if (Bytes[Index] and $C0) <> $80 then
        Exit(False);
      Inc(Index);
      Dec(Follow);
    end;
  end;
  Result := True;
end;

function FileLooksLikeText(const Path: string): Boolean;
begin
  Result := BytesLookLikeText(ReadFileStart(Path, 4096));
end;

{ --- Pictures ------------------------------------------------------------------------------- }

function TImagePreviewProvider.CanPreview(const Path, Extension: string): Boolean;
begin
  Result := DetectFileFormat(ReadFileStart(Path, 64)) <> ImageFormatUnknown;
  if not Result then
    Result := Extension = 'svg';
end;

function TImagePreviewProvider.CreatePreview(Parent: TControl; const Path: string): TControl;
var
  Box: TPictureBox;
begin
  Box := TPictureBox.Create(Parent);
  Box.SizeMode := PictureSizeZoom;
  if not Box.LoadFromFile(Path) then
  begin
    Box.Free;
    Exit(nil);
  end;
  Result := Box;
end;

{ --- Text ------------------------------------------------------------------------------------ }

function TTextPreviewProvider.CanPreview(const Path, Extension: string): Boolean;
begin
  Result := FileLooksLikeText(Path);
end;

function TTextPreviewProvider.CreatePreview(Parent: TControl; const Path: string): TControl;
var
  Edit: TTextEdit;
  Bytes: TBytes;
  Text: string;
begin
  Bytes := ReadFileStart(Path, PreviewTextLimit);
  Text := '';
  SetLength(Text, Length(Bytes));
  if Length(Bytes) > 0 then
    Move(Bytes[0], Text[1], Length(Bytes));
  Edit := TTextEdit.Create(Parent);
  Edit.ReadOnly := True;
  Edit.WordWrap := True;
  Edit.Lines.Text := Text;
  Result := Edit;
end;

{ --- Summaries ------------------------------------------------------------------------------- }

constructor TPreviewSummary.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FNames := TStringList.Create;
  FValues := TStringList.Create;
  FIconKind := StockIconFile;
end;

destructor TPreviewSummary.Destroy;
begin
  FNames.Free;
  FValues.Free;
  inherited Destroy;
end;

procedure TPreviewSummary.SetTitle(const Title, IconName: string; IconKind: TStockIcon);
begin
  FTitle := Title;
  FIconName := IconName;
  FIconKind := IconKind;
  Invalidate;
end;

procedure TPreviewSummary.AddLine(const Name, Value: string);
begin
  FNames.Add(Name);
  FValues.Add(Value);
  Invalidate;
end;

procedure TPreviewSummary.Paint(var Canvas: TCanvas);
var
  Width: LongInt;
  Size: LongInt;
  Icon: TRectangle;
  Y: LongInt;
  Index: LongInt;
  LineHeight: LongInt;
  NameWidth: LongInt;
  Quiet: TColor;
begin
  Width := RectangleWidth(PixelBounds);
  FillRectangle(Canvas, MakeRectangle(0, 0, Width, RectangleHeight(PixelBounds)), Theme.Field);
  Size := Scaled(SummaryIconSize);
  Icon := MakeRectangle((Width - Size) div 2, Scaled(16), Size, Size);
  if (FIconName = '') or not DrawThemeIcon(Canvas, FIconName, Icon) then
    DrawStockIcon(Canvas, FIconKind, Icon);
  Y := Icon.Bottom + Scaled(10);
  LineHeight := TextHeight(ControlFace) + Scaled(4);
  DrawTextInBox(Canvas, ControlBoldFace, FTitle, MakeRectangle(Scaled(8), Y, Width - Scaled(16), LineHeight),
    AlignTextCenter, Theme.FieldText);
  Y := Y + LineHeight + Scaled(8);
  NameWidth := 0;
  for Index := 0 to FNames.Count - 1 do
    if TextWidth(ControlFace, FNames[Index]) > NameWidth then
      NameWidth := TextWidth(ControlFace, FNames[Index]);
  if NameWidth > Width div 2 then
    NameWidth := Width div 2;
  Quiet := MixColors(Theme.Field, Theme.FieldText, 150);
  for Index := 0 to FNames.Count - 1 do
  begin
    DrawTextInBox(Canvas, ControlFace, FNames[Index], MakeRectangle(Scaled(10), Y, NameWidth, LineHeight),
      AlignTextLeft, Quiet);
    DrawTextInBox(Canvas, ControlFace, FValues[Index], MakeRectangle(Scaled(18) + NameWidth, Y,
      Width - NameWidth - Scaled(26), LineHeight), AlignTextLeft, Theme.FieldText);
    Y := Y + LineHeight;
  end;
end;

{ --- The host -------------------------------------------------------------------------------- }

constructor TPreviewHost.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FProviders := TList.Create;
  FMessage := NothingSelectedText;
end;

destructor TPreviewHost.Destroy;
var
  Index: LongInt;
begin
  for Index := 0 to FProviders.Count - 1 do
    TPreviewProvider(FProviders[Index]).Free;
  FProviders.Free;
  inherited Destroy;
end;

procedure TPreviewHost.AddProvider(Provider: TPreviewProvider; AtFront: Boolean);
begin
  if AtFront then
    FProviders.Insert(0, Provider)
  else
    FProviders.Add(Provider);
end;

procedure TPreviewHost.DropPreview;
begin
  if FPreview <> nil then
    FreeAndNil(FPreview);
end;

procedure TPreviewHost.ShowControl(Control: TControl);
begin
  if Control <> FPreview then
    DropPreview;
  FPreview := Control;
  if FPreview <> nil then
  begin
    FPreview.Align := AlignClient;
    RequestLayout;
  end;
  Invalidate;
end;

procedure TPreviewHost.ShowMessage(const MessageText: string);
begin
  DropPreview;
  FPath := '';
  FMessage := MessageText;
  Invalidate;
end;

function TPreviewHost.ShowFile(const Path: string): Boolean;
var
  Index: LongInt;
  Provider: TPreviewProvider;
  Extension: string;
  Made: TControl;
begin
  if (Path = FPath) and (FPreview <> nil) then
    Exit(True);
  DropPreview;
  FPath := Path;
  Extension := LowerCase(ExtractFileExt(Path));
  if Copy(Extension, 1, 1) = '.' then
    Delete(Extension, 1, 1);
  for Index := 0 to FProviders.Count - 1 do
  begin
    Provider := TPreviewProvider(FProviders[Index]);
    if not Provider.CanPreview(Path, Extension) then
      Continue;
    Made := Provider.CreatePreview(Self, Path);
    if Made <> nil then
    begin
      ShowControl(Made);
      Exit(True);
    end;
  end;
  FMessage := NoPreviewText;
  Invalidate;
  Result := False;
end;

procedure TPreviewHost.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Field);
  if FPreview = nil then
    DrawTextInBox(Canvas, ControlFace, FMessage, MakeRectangle(Scaled(8), Box.Top, RectangleWidth(Box) - Scaled(16),
      RectangleHeight(Box)), AlignTextCenter, MixColors(Theme.Field, Theme.FieldText, 150));
end;

end.
