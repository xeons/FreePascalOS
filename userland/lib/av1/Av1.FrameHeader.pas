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
  The frame header (specification section 5.9, uncompressed_header):
  what is read and what follows from it, with the specification's names
  (syntax elements in lower case, derived variables in mixed case).
  Av1.FrameHeaderParsing reads it.
}
unit Av1.FrameHeader;

{$mode objfpc}

interface

uses
  Av1.Constants;

type
  TFilmGrainParams = record
    apply_grain: Boolean;
    grain_seed: Integer;
    update_grain: Boolean;
    num_y_points: Integer;
    point_y_value: array[0..15] of Integer;
    point_y_scaling: array[0..15] of Integer;
    chroma_scaling_from_luma: Boolean;
    num_cb_points: Integer;
    point_cb_value: array[0..15] of Integer;
    point_cb_scaling: array[0..15] of Integer;
    num_cr_points: Integer;
    point_cr_value: array[0..15] of Integer;
    point_cr_scaling: array[0..15] of Integer;
    grain_scaling_minus_8: Integer;
    ar_coeff_lag: Integer;
    ar_coeffs_y_plus_128: array[0..23] of Integer;
    ar_coeffs_cb_plus_128: array[0..24] of Integer;
    ar_coeffs_cr_plus_128: array[0..24] of Integer;
    ar_coeff_shift_minus_6: Integer;
    grain_scale_shift: Integer;
    cb_mult, cb_luma_mult, cb_offset: Integer;
    cr_mult, cr_luma_mult, cr_offset: Integer;
    overlap_flag: Boolean;
    clip_to_restricted_range: Boolean;
  end;

  TGlobalMotionParams = array[0..TOTAL_REFS_PER_FRAME - 1, 0..5] of Integer;
  TSegmentationFeatures = record
    FeatureEnabled: array[0..MAX_SEGMENTS - 1, 0..SEG_LVL_MAX - 1] of Boolean;
    FeatureData: array[0..MAX_SEGMENTS - 1, 0..SEG_LVL_MAX - 1] of Integer;
  end;
  TLoopFilterDeltas = record
    loop_filter_ref_deltas: array[0..TOTAL_REFS_PER_FRAME - 1] of Integer;
    loop_filter_mode_deltas: array[0..1] of Integer;
  end;

  TFrameHeader = record
    show_existing_frame: Boolean;
    frame_to_show_map_idx: Integer;
    frame_type: Integer;
    FrameIsIntra: Boolean;
    show_frame: Boolean;
    showable_frame: Boolean;
    error_resilient_mode: Boolean;
    disable_cdf_update: Boolean;
    allow_screen_content_tools: Integer;
    force_integer_mv: Integer;
    current_frame_id: Integer;
    frame_size_override_flag: Boolean;
    OrderHint: Integer;
    primary_ref_frame: Integer;
    refresh_frame_flags: Integer;
    allow_intrabc: Boolean;
    ref_frame_idx: array[0..REFS_PER_FRAME - 1] of Integer;
    frame_refs_short_signaling: Boolean;
    allow_high_precision_mv: Boolean;
    is_motion_mode_switchable: Boolean;
    use_ref_frame_mvs: Boolean;
    interpolation_filter: Integer;
    OrderHints: array[0..TOTAL_REFS_PER_FRAME - 1] of Integer;
    RefFrameSignBias: array[0..TOTAL_REFS_PER_FRAME - 1] of Integer;
    disable_frame_end_update_cdf: Boolean;
    { frame_size( ), superres_params( ), render_size( ) }
    FrameWidth, FrameHeight: Integer;
    UpscaledWidth: Integer;
    RenderWidth, RenderHeight: Integer;
    use_superres: Boolean;
    SuperresDenom: Integer;
    MiCols, MiRows: Integer;
    { tile_info( ) }
    TileColsLog2, TileRowsLog2: Integer;
    TileCols, TileRows: Integer;
    MiColStarts: array[0..MAX_TILE_COLS] of Integer;
    MiRowStarts: array[0..MAX_TILE_ROWS] of Integer;
    context_update_tile_id: Integer;
    TileSizeBytes: Integer;
    { quantization_params( ) }
    base_q_idx: Integer;
    DeltaQYDc, DeltaQUDc, DeltaQUAc, DeltaQVDc, DeltaQVAc: Integer;
    using_qmatrix: Boolean;
    qm_y, qm_u, qm_v: Integer;
    { segmentation_params( ) }
    segmentation_enabled: Boolean;
    segmentation_update_map: Boolean;
    segmentation_temporal_update: Boolean;
    segmentation_update_data: Boolean;
    Segmentation: TSegmentationFeatures;
    SegIdPreSkip: Boolean;
    LastActiveSegId: Integer;
    { delta_q_params( ), delta_lf_params( ) }
    delta_q_present: Boolean;
    delta_q_res: Integer;
    delta_lf_present: Boolean;
    delta_lf_res: Integer;
    delta_lf_multi: Boolean;
    { lossless }
    CodedLossless, AllLossless: Boolean;
    LosslessArray: array[0..MAX_SEGMENTS - 1] of Boolean;
    SegQMLevel: array[0..2, 0..MAX_SEGMENTS - 1] of Integer;
    { loop_filter_params( ) }
    loop_filter_level: array[0..3] of Integer;
    loop_filter_sharpness: Integer;
    loop_filter_delta_enabled: Boolean;
    LoopFilterDeltas: TLoopFilterDeltas;
    { cdef_params( ) }
    CdefDamping: Integer;
    cdef_bits: Integer;
    cdef_y_pri_strength, cdef_y_sec_strength: array[0..7] of Integer;
    cdef_uv_pri_strength, cdef_uv_sec_strength: array[0..7] of Integer;
    { lr_params( ) }
    FrameRestorationType: array[0..2] of Integer;
    UsesLr: Boolean;
    LoopRestorationSize: array[0..2] of Integer;
    { read_tx_mode( ), frame_reference_mode( ), skip_mode_params( ) }
    TxMode: Integer;
    reference_select: Boolean;
    skip_mode_present: Boolean;
    SkipModeFrame: array[0..1] of Integer;
    allow_warped_motion: Boolean;
    reduced_tx_set: Boolean;
    { global_motion_params( ) }
    GmType: array[0..TOTAL_REFS_PER_FRAME - 1] of Integer;
    gm_params: TGlobalMotionParams;
    PrevGmParams: TGlobalMotionParams;
    { film_grain_params( ) }
    FilmGrain: TFilmGrainParams;
    { OBU extension of the frame header }
    temporal_id, spatial_id: Integer;
  end;

implementation

end.
