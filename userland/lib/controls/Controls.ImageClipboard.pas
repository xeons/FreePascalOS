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
  Images on the system clipboard, for any program: a libimage TImage
  as the clipboard's two image formats (Windowing.Clipboard), PNG (a
  whole PNG file) and raw pixels (DataFormatBgra: the width and height
  as 32-bit little-endian numbers, then blue, green, red and alpha a
  pixel, straight alpha, lines from the top: a TImage's own memory
  order), and back.

  WriteClipboardImage offers both, each made only when some program
  asks for it (encoding a PNG takes a while). ReadClipboardImage takes
  the raw pixels when they are there (exact and quick) and the PNG
  otherwise.
}
unit Controls.ImageClipboard;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Model,
  Windowing.DataTransfer;

type
  { An image offered as PNG and raw pixels; it owns the image. }
  TImageOffer = class(TDataOffer)
  private
    FImage: TImage;
  protected
    function Render(Format: LongWord): TBytes; override;
  public
    constructor Create(AImage: TImage);
    destructor Destroy; override;
  end;

{ The image as raw pixels, and back (nil if Data is not such pixels). }
function ImageToBgra(Image: TImage): TBytes;
function BgraToImage(const Data: TBytes): TImage;
{ Puts a copy of Image on the clipboard (as PNG and raw pixels). }
procedure WriteClipboardImage(Image: TImage);
{ The image on the clipboard (the caller frees it); nil if there is
  none or it cannot be read. }
function ReadClipboardImage: TImage;
function ClipboardHasImage: Boolean;

implementation

uses
  Windowing.Protocol,
  Windowing.Clipboard,
  Image.Errors,
  Image.Codecs,
  Image.Files;

const
  BgraHeaderSize = 8;

procedure PutLongWord(var Data: TBytes; Offset: LongInt; Value: LongWord);
begin
  Data[Offset] := Value and $FF;
  Data[Offset + 1] := (Value shr 8) and $FF;
  Data[Offset + 2] := (Value shr 16) and $FF;
  Data[Offset + 3] := (Value shr 24) and $FF;
end;

function GetLongWord(const Data: TBytes; Offset: LongInt): LongWord;
begin
  Result := LongWord(Data[Offset]) or (LongWord(Data[Offset + 1]) shl 8) or (LongWord(Data[Offset + 2]) shl 16) or
    (LongWord(Data[Offset + 3]) shl 24);
end;

function ImageToBgra(Image: TImage): TBytes;
var
  PixelBytes: QWord;
begin
  Result := nil;
  PixelBytes := QWord(Image.Width) * QWord(Image.Height) * 4;
  SetLength(Result, BgraHeaderSize + PixelBytes);
  PutLongWord(Result, 0, LongWord(Image.Width));
  PutLongWord(Result, 4, LongWord(Image.Height));
  if PixelBytes > 0 then
    Move(Image.Pixels^, Result[BgraHeaderSize], PixelBytes);
end;

function BgraToImage(const Data: TBytes): TImage;
var
  Width: LongWord;
  Height: LongWord;
  PixelBytes: QWord;
begin
  Result := nil;
  if Length(Data) < BgraHeaderSize then
    Exit;
  Width := GetLongWord(Data, 0);
  Height := GetLongWord(Data, 4);
  if not ImageSizeAllowed(Width, Height) then
    Exit;
  PixelBytes := QWord(Width) * QWord(Height) * 4;
  if QWord(Length(Data)) <> BgraHeaderSize + PixelBytes then
    Exit;
  Result := TImage.Create(Width, Height);
  Move(Data[BgraHeaderSize], Result.Pixels^, PixelBytes);
end;

constructor TImageOffer.Create(AImage: TImage);
begin
  inherited Create;
  FImage := AImage;
  AddLater(DataFormatPng);
  AddLater(DataFormatBgra);
end;

destructor TImageOffer.Destroy;
begin
  FImage.Free;
  inherited Destroy;
end;

function TImageOffer.Render(Format: LongWord): TBytes;
begin
  case Format of
    DataFormatPng: Result := EncodeImage(FImage, ImageFormatPng);
    DataFormatBgra: Result := ImageToBgra(FImage);
  else
    Result := nil;
  end;
end;

procedure WriteClipboardImage(Image: TImage);
begin
  WriteClipboard(TImageOffer.Create(Image.Clone));
end;

function ReadClipboardImage: TImage;
var
  Data: TBytes;
  Reason: TImageErrorReason;
begin
  Result := nil;
  if ReadClipboard(DataFormatBgra, Data) then
  begin
    Result := BgraToImage(Data);
    if Result <> nil then
      Exit;
  end;
  if ReadClipboard(DataFormatPng, Data) then
    if not TryLoadImage(Data, Result, Reason) then
      Result := nil;
end;

function ClipboardHasImage: Boolean;
begin
  Result := ClipboardHasFormat(DataFormatBgra) or ClipboardHasFormat(DataFormatPng);
end;

end.
