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
  One PNG picture (the default image, or an APNG frame) from its data
  stream: line after line decompressed, unfiltered in place against
  the line above (Image.Png.Filters) and turned into colours
  (Image.Png.Pixels); an interlaced picture pass after pass
  (Image.Png.Interlace), each pass's pixels written where they belong.

  Two line buffers serve the whole picture, swapped after every line;
  nothing is allocated per line or per pixel.
}
unit Image.Png.Reading;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Model,
  Image.Png.Header,
  Image.Png.Pixels,
  Image.Png.DataStream;

{ A picture of Width x Height in Info's colour type and depth (and
  Info's interlacing) from Stream. }
function DecodePngPicture(constref Info: TPngColorInfo; Width, Height: LongInt; Stream: TPngDataStream): TImage;

implementation

uses
  Image.Png.Filters,
  Image.Png.Interlace;

type
  { Two lines with their filter bytes: the one being read and the one
    above it. }
  TLineBuffers = record
    Storage: TBytes;
    Current: PByte;
    Previous: PByte;
  end;

procedure PrepareLines(out Lines: TLineBuffers; RowBytes: PtrInt);
begin
  Lines.Storage := nil;
  SetLength(Lines.Storage, 2 * (RowBytes + 1));
  Lines.Current := @Lines.Storage[0];
  Lines.Previous := @Lines.Storage[RowBytes + 1];
end;

{ Reads, unfilters and keeps the next line; its bytes start at
  Lines.Current + 1. }
procedure ReadLine(var Lines: TLineBuffers; Stream: TPngDataStream; RowBytes: PtrInt; Stride: LongInt);
var
  Swap: PByte;
begin
  Swap := Lines.Previous;
  Lines.Previous := Lines.Current;
  Lines.Current := Swap;
  Stream.Read(Lines.Current, RowBytes + 1);
  UnfilterRow(Lines.Current[0], Lines.Current + 1, Lines.Previous + 1, RowBytes, Stride);
end;

procedure DecodeProgressive(constref Info: TPngColorInfo; Image: TImage; Stream: TPngDataStream);
var
  Lines: TLineBuffers;
  Pass: LongInt;
  PassWidth: LongInt;
  PassHeight: LongInt;
  RowBytes: PtrInt;
  Line: LongInt;
  Target: PLongWord;
begin
  PrepareLines(Lines, PngRowBytes(Info.Header, Image.Width));
  for Pass := 0 to Adam7PassCount - 1 do
  begin
    PassWidth := Adam7PassWidth(Pass, Image.Width);
    PassHeight := Adam7PassHeight(Pass, Image.Height);
    if (PassWidth = 0) or (PassHeight = 0) then
      Continue;
    RowBytes := PngRowBytes(Info.Header, PassWidth);
    { The swap in ReadLine makes the zeroed buffer the line above. }
    FillChar(Lines.Current^, RowBytes + 1, 0);
    for Line := 0 to PassHeight - 1 do
    begin
      ReadLine(Lines, Stream, RowBytes, Info.Header.FilterStride);
      Target := Image.Line(Adam7Passes[Pass].FirstLine + Line * Adam7Passes[Pass].LineStep) +
        Adam7Passes[Pass].FirstColumn;
      ConvertPngRow(Info, Lines.Current + 1, Target, PassWidth, Adam7Passes[Pass].ColumnStep);
    end;
  end;
end;

procedure DecodeSequential(constref Info: TPngColorInfo; Image: TImage; Stream: TPngDataStream);
var
  Lines: TLineBuffers;
  RowBytes: PtrInt;
  Line: LongInt;
begin
  RowBytes := PngRowBytes(Info.Header, Image.Width);
  PrepareLines(Lines, RowBytes);
  { The swap in ReadLine makes this zeroed buffer the line above. }
  FillChar(Lines.Current^, RowBytes + 1, 0);
  for Line := 0 to Image.Height - 1 do
  begin
    ReadLine(Lines, Stream, RowBytes, Info.Header.FilterStride);
    ConvertPngRow(Info, Lines.Current + 1, Image.Line(Line), Image.Width, 1);
  end;
end;

function DecodePngPicture(constref Info: TPngColorInfo; Width, Height: LongInt; Stream: TPngDataStream): TImage;
begin
  Result := TImage.Create(Width, Height);
  try
    if Info.Header.Interlaced then
      DecodeProgressive(Info, Result, Stream)
    else
      DecodeSequential(Info, Result, Stream);
    Stream.Finish;
  except
    Result.Free;
    raise;
  end;
end;

end.
