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
  The contents of libimage.so.

  Compiling this unit compiles every unit of the library; programs use
  the individual units (usually Image.Model, Image.Files and
  Image.Surfaces). libimage needs libdrawing and the runtime library,
  so it builds and is tested on the host as well (tools/ImageTest).
}
unit Image.Contents;

{$mode objfpc}

interface

uses
  Image.Errors,
  Image.Metadata,
  Image.Model,
  Image.Frames,
  Image.Surfaces,
  Image.Compositing,
  Image.Orientation,
  Image.Scaling,
  Image.ByteReaders,
  Image.ByteWriters,
  Image.Codecs,
  Image.Bmp.Headers,
  Image.Bmp.Masks,
  Image.Bmp.Rle,
  Image.Bmp.Reading,
  Image.Bmp.Writing,
  Image.Bmp.Codec,
  Image.Ico.Directory,
  Image.Ico.Reading,
  Image.Ico.Writing,
  Image.Ico.Codec,
  Image.Gif.Lzw,
  Image.Gif.LzwEncoding,
  Image.Gif.Blocks,
  Image.Gif.Reading,
  Image.Gif.Writing,
  Image.Gif.Codec,
  Image.Jpeg.Frames,
  Image.Jpeg.Huffman,
  Image.Jpeg.Idct,
  Image.Jpeg.Exif,
  Image.Jpeg.Markers,
  Image.Jpeg.Scans,
  Image.Jpeg.Baseline,
  Image.Jpeg.Progressive,
  Image.Jpeg.Upsampling,
  Image.Jpeg.Color,
  Image.Jpeg.Decoder,
  Image.Jpeg.StandardTables,
  Image.Jpeg.ForwardDct,
  Image.Jpeg.Encoding,
  Image.Jpeg.Codec,
  Image.StandardCodecs,
  Image.Files;

implementation

end.
