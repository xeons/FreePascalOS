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
  ICO and CUR as decoders and encoders for the registry.

  Decoding a whole file gives its largest entry (the deepest of equal
  sizes), PNG entries through the PNG decoder like the rest.
  To pick an entry by size use Image.Ico.Directory and
  Image.Ico.Reading directly. Encoding writes the image as an icon of
  one entry (Image.Ico.Writing writes several).
}
unit Image.Ico.Codec;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Model,
  Image.Codecs,
  Image.Ico.Directory,
  Image.Ico.Reading,
  Image.Ico.Writing;

type
  TIcoDecoder = class(TImageDecoder)
  public
    class function Format: TImageFormat; override;
    class function CanDecode(const Data: TBytes): Boolean; override;
    function Decode(const Data: TBytes): TImage; override;
  end;

  TCurDecoder = class(TIcoDecoder)
  public
    class function Format: TImageFormat; override;
    class function CanDecode(const Data: TBytes): Boolean; override;
  end;

  TIcoEncoder = class(TImageEncoder)
  public
    class function Format: TImageFormat; override;
    function Encode(Image: TImage): TBytes; override;
  end;

  TCurEncoder = class(TImageEncoder)
  public
    class function Format: TImageFormat; override;
    function Encode(Image: TImage): TBytes; override;
  end;

{ The largest picture of an icon or cursor file, as decoding gives it. }
function DecodeIconFile(const Data: TBytes): TImage;

implementation

function DecodeIconFile(const Data: TBytes): TImage;
var
  Directory: TIconDirectory;
begin
  Directory := TIconDirectory.Create(Data);
  try
    Result := DecodeIconEntry(Directory, Directory.LargestEntry(False));
  finally
    Directory.Free;
  end;
end;

class function TIcoDecoder.Format: TImageFormat;
begin
  Result := ImageFormatIco;
end;

class function TIcoDecoder.CanDecode(const Data: TBytes): Boolean;
begin
  Result := LooksLikeIconFile(Data, IconTypeIcon);
end;

function TIcoDecoder.Decode(const Data: TBytes): TImage;
begin
  Result := DecodeIconFile(Data);
end;

class function TCurDecoder.Format: TImageFormat;
begin
  Result := ImageFormatCur;
end;

class function TCurDecoder.CanDecode(const Data: TBytes): Boolean;
begin
  Result := LooksLikeIconFile(Data, IconTypeCursor);
end;

class function TIcoEncoder.Format: TImageFormat;
begin
  Result := ImageFormatIco;
end;

function TIcoEncoder.Encode(Image: TImage): TBytes;
begin
  Result := EncodeIconFile([Image], False);
end;

class function TCurEncoder.Format: TImageFormat;
begin
  Result := ImageFormatCur;
end;

function TCurEncoder.Encode(Image: TImage): TBytes;
begin
  Result := EncodeIconFile([Image], True);
end;

end.
