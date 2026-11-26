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
  The contents of libav1.so, the AV1 video decoder.

  Compiling this unit compiles every unit of the library; programs use
  Av1.Decoder (TAv1Decoder) and libmedia's Media.Frames, or libmedia's
  video decoder registry through Av1.MediaDecoder. libav1 needs only
  libmedia and the runtime library, so it builds and is tested on the
  host as well
  (tools/Av1Test, against streams made by the host's AV1 encoders and
  decoded by its reference decoder).
}
unit Av1.Contents;

{$mode objfpc}

interface

uses
  Media.Frames,
  Av1.Common, Av1.Constants, Av1.Tables, Av1.QuantizerMatrices, Av1.DefaultCdfs, Av1.CdfContext,
  Av1.BitReader, Av1.SymbolDecoder, Av1.SequenceHeader, Av1.FrameHeader, Av1.FrameHeaderParsing,
  Av1.Picture, Av1.References, Av1.FrameContext, Av1.TileContext,
  Av1.BlockFlagsSyntax, Av1.IntraModeSyntax, Av1.PaletteSyntax, Av1.ReferenceFrameSyntax,
  Av1.MotionVectorSyntax, Av1.InterModeSyntax, Av1.TransformSyntax, Av1.CoefficientSyntax,
  Av1.ResidualDecoding, Av1.BlockDecoding, Av1.TileDecoding,
  Av1.MvCandidates, Av1.MvPrediction, Av1.WarpSamples, Av1.MotionField,
  Av1.IntraEdges, Av1.IntraPrediction, Av1.PalettePrediction, Av1.ChromaFromLuma,
  Av1.MotionVectorScaling, Av1.BlockInterPrediction, Av1.Warp, Av1.CompoundMasks, Av1.Obmc, Av1.InterPrediction,
  Av1.InverseTransform, Av1.Reconstruction,
  Av1.LoopFilterSamples, Av1.LoopFilter, Av1.Cdef, Av1.SuperRes, Av1.RestorationWindow, Av1.Wiener,
  Av1.SelfGuided, Av1.LoopRestoration, Av1.PostFilters,
  Av1.FilmGrainNoise, Av1.FilmGrainScaling, Av1.FilmGrain, Av1.Output,
  Av1.ToolStatistics, Av1.FrameDecoding, Av1.Decoder, Av1.MediaDecoder;

implementation

end.
