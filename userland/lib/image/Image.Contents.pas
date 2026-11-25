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
  Image.Surfaces). libimage needs libdrawing, libcompression (PNG and
  TIFF) and the runtime library, so it builds and is tested on the host as well (tools/ImageTest).
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
  Image.Scalable,
  Image.PictureColors,
  Image.Compositing,
  Image.Orientation,
  Image.Scaling,
  Image.Resampling,
  { Colour management }
  Image.ColorProfiles.Numbers,
  Image.ColorProfiles.Matrices,
  Image.ColorProfiles.Curves,
  Image.ColorProfiles.Luts,
  Image.ColorProfiles.Reading,
  Image.ColorProfiles.Transforms,
  Image.ColorProfiles,
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
  { PNG and APNG }
  Image.Png.Chunks,
  Image.Png.Header,
  Image.Png.Filters,
  Image.Png.Interlace,
  Image.Png.Pixels,
  Image.Png.DataStream,
  Image.Png.Reading,
  Image.Png.Ancillary,
  Image.Png.Animation,
  Image.Png.Decoder,
  Image.Png.ColorTable,
  Image.Png.DataWriter,
  Image.Png.MetadataWriting,
  Image.Png.Writing,
  Image.Png.Codec,
  { TIFF }
  Image.Tiff.Tags,
  Image.Tiff.Directory,
  Image.Tiff.Pages,
  Image.Tiff.PackBits,
  Image.Tiff.Lzw,
  Image.Tiff.LzwEncoding,
  Image.Tiff.Predictor,
  Image.Tiff.FloatSamples,
  Image.Tiff.CcittCodes,
  Image.Tiff.Ccitt,
  Image.Tiff.Decompression,
  Image.Tiff.Strips,
  Image.Tiff.Samples,
  Image.Tiff.Color,
  Image.Tiff.Photometric,
  Image.Tiff.Jpeg,
  Image.Tiff.OldJpeg,
  Image.Tiff.Reading,
  Image.Tiff.Writing,
  Image.Tiff.Codec,
  { WebP }
  Image.WebP.Container,
  Image.WebP.LosslessBits,
  Image.WebP.PrefixCodes,
  Image.WebP.LosslessTransforms,
  Image.WebP.LosslessDecoder,
  Image.WebP.BoolDecoder,
  Image.WebP.LossyTables,
  Image.WebP.LossyHeader,
  Image.WebP.LossyResiduals,
  Image.WebP.LossyPrediction,
  Image.WebP.LossyTransforms,
  Image.WebP.LoopFilter,
  Image.WebP.LossyDecoder,
  Image.WebP.YuvConversion,
  Image.WebP.Alpha,
  Image.WebP.Decoder,
  Image.WebP.LosslessBitWriter,
  Image.WebP.PrefixCodeWriting,
  Image.WebP.BackwardReferences,
  Image.WebP.LosslessEncoder,
  Image.WebP.Writing,
  Image.WebP.Codec,
  { JPEG XL }
  Image.Jxl.BitReader,
  Image.Jxl.Prefix,
  Image.Jxl.AnsHistograms,
  Image.Jxl.Entropy,
  Image.Jxl.Permutation,
  Image.Jxl.UpsamplingWeights,
  Image.Jxl.Headers,
  Image.Jxl.Icc,
  Image.Jxl.FrameHeader,
  Image.Jxl.Planes,
  Image.Jxl.Modular.Channels,
  Image.Jxl.Modular.Tree,
  Image.Jxl.Modular.Weighted,
  Image.Jxl.Modular.Predictors,
  Image.Jxl.Modular.Squeeze,
  Image.Jxl.Modular.Palette,
  Image.Jxl.Modular.Transforms,
  Image.Jxl.Modular.Decoding,
  Image.Jxl.ModularFrame,
  Image.Jxl.VarDct,
  Image.Jxl.Gaborish,
  Image.Jxl.EdgePreserving,
  Image.Jxl.Noise,
  Image.Jxl.Xyb,
  Image.Jxl.Upsampling,
  Image.Jxl.Blending,
  Image.Jxl.Patches,
  Image.Jxl.FrameDecoder,
  Image.Jxl.Canvas,
  Image.Jxl.Output,
  Image.Jxl.Container,
  Image.Jxl.Decoder,
  Image.Jxl.Codec,
  Image.StandardCodecs,
  Image.FloodFill,
  Image.Areas,
  Image.Transforms,
  Image.Files;

implementation

end.
