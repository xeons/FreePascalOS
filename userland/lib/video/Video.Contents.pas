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
  The contents of libvideo.so: the VP8 and VP9 decoders, their libmedia
  video decoder classes (Video.MediaDecoders), the IVF reader and the
  worker threads they decode on. Compiling this unit compiles all of
  them.
}
unit Video.Contents;

{$mode objfpc}

interface

uses
  Video.BoolDecoder,
  Video.Ivf,
  Video.WorkerPool,
  Vp8.Tables,
  Vp8.FrameHeader,
  Vp8.Modes,
  Vp8.Residuals,
  Vp8.Transforms,
  Vp8.IntraPrediction,
  Vp8.InterPrediction,
  Vp8.LoopFilter,
  Vp8.Pictures,
  Vp8.Reconstruction,
  Vp8.Decoder,
  Vp9.Tables,
  Vp9.ScanTables,
  Vp9.QuantizerTables,
  Vp9.FilterTables,
  Vp9.Probabilities,
  Vp9.BitReader,
  Vp9.ModeInfo,
  Vp9.Pictures,
  Vp9.Transforms,
  Vp9.IntraPrediction,
  Vp9.InterPrediction,
  Vp9.LoopFilter,
  Vp9.Residuals,
  Vp9.FrameState,
  Vp9.Modes,
  Vp9.TileState,
  Vp9.BlockReconstruction,
  Vp9.TileDecoder,
  Vp9.FrameHeader,
  Vp9.Decoder,
  Video.MediaDecoders;

implementation

end.
