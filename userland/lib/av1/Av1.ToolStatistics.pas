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
  Counts of the coding tools the decoder met, so that the conformance
  test can show which tools its streams exercise. The counting is
  compiled in only with AV1_TOOL_STATISTICS defined (the host test);
  otherwise CountTool does nothing.
}
unit Av1.ToolStatistics;

{$mode objfpc}

interface

type
  TAv1Tool = (
    toolKeyFrame, toolInterFrame, toolIntraOnlyFrame, toolSwitchFrame, toolShowExistingFrame,
    toolErrorResilient, toolShortRefSignaling, toolReferenceSelect, toolTemporalMvs, toolSkipModeFrame,
    toolMultipleTiles, toolSuperblock128, toolSuperres, toolScaledReference, toolLossless, toolQuantizerMatrix,
    toolSegmentation, toolDeltaQ, toolDeltaLf, toolLoopFilter, toolCdef, toolWiener, toolSelfGuided, toolFilmGrain,
    toolIntraDirectional, toolAngleDelta, toolSmooth, toolPaeth, toolChromaFromLuma, toolFilterIntra,
    toolPaletteY, toolPaletteUv, toolIntraBlockCopy,
    toolSingleReference, toolCompoundReference, toolUnidirectionalCompound, toolSkipMode, toolNewMv, toolGlobalMv,
    toolGlobalMotionWarp, toolLocalWarp, toolObmc, toolInterIntra, toolInterIntraWedge, toolCompoundWedge,
    toolCompoundDiffWeighted, toolCompoundDistance, toolDualFilter,
    toolTransform64, toolTransformRectangular, toolTransformIdentity, toolTransformFlipAdst, toolTransformSplit,
    toolWalshHadamard
  );

const
  ToolNames: array[TAv1Tool] of string = (
    'key frames', 'inter frames', 'intra-only frames', 'switch frames', 'show_existing_frame',
    'error resilient mode', 'short reference signaling', 'reference_select', 'temporal motion vectors',
    'skip mode allowed', 'several tiles', '128x128 superblocks', 'superres', 'scaled references', 'lossless',
    'quantizer matrices', 'segmentation', 'delta q', 'delta loop filter', 'deblocking', 'CDEF',
    'Wiener restoration', 'self-guided restoration', 'film grain',
    'directional intra', 'angle deltas', 'smooth intra', 'Paeth', 'chroma from luma', 'filter intra',
    'luma palette', 'chroma palette', 'intra block copy',
    'single reference', 'compound reference', 'unidirectional compound', 'skip mode', 'NEWMV', 'GLOBALMV',
    'global motion warp', 'local warp', 'OBMC', 'inter-intra', 'wedge inter-intra', 'wedge compound',
    'difference weighted compound', 'distance weighted compound', 'dual filter',
    '64-point transforms', 'rectangular transforms', 'identity transforms', 'flipped ADST', 'transform split',
    'Walsh-Hadamard');

var
  ToolCounts: array[TAv1Tool] of LongInt;

procedure CountTool(Tool: TAv1Tool); inline;

implementation

procedure CountTool(Tool: TAv1Tool);
begin
{$ifdef AV1_TOOL_STATISTICS}
  InterLockedIncrement(ToolCounts[Tool]);
{$endif}
end;

end.
