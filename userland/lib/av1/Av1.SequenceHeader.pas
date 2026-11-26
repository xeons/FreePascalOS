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
  The sequence header OBU (specification section 5.5): profile, the
  largest frame size, the tools the sequence may use, the colour
  configuration, timing and decoder model information. The fields have
  the specification's names; the decoder picks operating point 0.
}
unit Av1.SequenceHeader;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils, Av1.Common, Av1.Constants, Av1.BitReader;

type
  TSequenceHeader = record
    seq_profile: Integer;
    still_picture: Boolean;
    reduced_still_picture_header: Boolean;
    timing_info_present_flag: Boolean;
    decoder_model_info_present_flag: Boolean;
    equal_picture_interval: Boolean;
    buffer_delay_length_minus_1: Integer;
    buffer_removal_time_length_minus_1: Integer;
    frame_presentation_time_length_minus_1: Integer;
    operating_points_cnt_minus_1: Integer;
    operating_point_idc: array[0..31] of Integer;
    seq_level_idx: array[0..31] of Integer;
    decoder_model_present_for_this_op: array[0..31] of Boolean;
    OperatingPointIdc: Integer;
    frame_width_bits_minus_1: Integer;
    frame_height_bits_minus_1: Integer;
    max_frame_width_minus_1: Integer;
    max_frame_height_minus_1: Integer;
    frame_id_numbers_present_flag: Boolean;
    delta_frame_id_length_minus_2: Integer;
    additional_frame_id_length_minus_1: Integer;
    use_128x128_superblock: Boolean;
    enable_filter_intra: Boolean;
    enable_intra_edge_filter: Boolean;
    enable_interintra_compound: Boolean;
    enable_masked_compound: Boolean;
    enable_warped_motion: Boolean;
    enable_dual_filter: Boolean;
    enable_order_hint: Boolean;
    enable_jnt_comp: Boolean;
    enable_ref_frame_mvs: Boolean;
    seq_force_screen_content_tools: Integer;
    seq_force_integer_mv: Integer;
    OrderHintBits: Integer;
    enable_superres: Boolean;
    enable_cdef: Boolean;
    enable_restoration: Boolean;
    { color_config( ) }
    BitDepth: Integer;
    mono_chrome: Boolean;
    NumPlanes: Integer;
    color_primaries: Integer;
    transfer_characteristics: Integer;
    matrix_coefficients: Integer;
    color_range: Boolean;
    subsampling_x: Integer;
    subsampling_y: Integer;
    chroma_sample_position: Integer;
    separate_uv_delta_q: Boolean;
    film_grain_params_present: Boolean;
    { timing_info( ) }
    num_units_in_display_tick: LongWord;
    time_scale: LongWord;
  end;

procedure ParseSequenceHeader(var Reader: TBitReader; out Header: TSequenceHeader);

implementation

procedure ParseColorConfig(var Reader: TBitReader; var Header: TSequenceHeader);
var
  HighBitdepth: Boolean;
begin
  HighBitdepth := ReadFlag(Reader);
  if (Header.seq_profile = 2) and HighBitdepth then
  begin
    if ReadFlag(Reader) then
      Header.BitDepth := 12
    else
      Header.BitDepth := 10;
  end
  else if HighBitdepth then
    Header.BitDepth := 10
  else
    Header.BitDepth := 8;
  if Header.seq_profile = 1 then
    Header.mono_chrome := False
  else
    Header.mono_chrome := ReadFlag(Reader);
  if Header.mono_chrome then
    Header.NumPlanes := 1
  else
    Header.NumPlanes := 3;
  if ReadFlag(Reader) then
  begin
    Header.color_primaries := ReadBits(Reader, 8);
    Header.transfer_characteristics := ReadBits(Reader, 8);
    Header.matrix_coefficients := ReadBits(Reader, 8);
  end
  else
  begin
    Header.color_primaries := CP_UNSPECIFIED;
    Header.transfer_characteristics := TC_UNSPECIFIED;
    Header.matrix_coefficients := MC_UNSPECIFIED;
  end;
  if Header.mono_chrome then
  begin
    Header.color_range := ReadFlag(Reader);
    Header.subsampling_x := 1;
    Header.subsampling_y := 1;
    Header.chroma_sample_position := CSP_UNKNOWN;
    Header.separate_uv_delta_q := False;
    Exit;
  end
  else if (Header.color_primaries = CP_BT_709) and (Header.transfer_characteristics = TC_SRGB)
    and (Header.matrix_coefficients = MC_IDENTITY) then
  begin
    Header.color_range := True;
    Header.subsampling_x := 0;
    Header.subsampling_y := 0;
  end
  else
  begin
    Header.color_range := ReadFlag(Reader);
    if Header.seq_profile = 0 then
    begin
      Header.subsampling_x := 1;
      Header.subsampling_y := 1;
    end
    else if Header.seq_profile = 1 then
    begin
      Header.subsampling_x := 0;
      Header.subsampling_y := 0;
    end
    else if Header.BitDepth = 12 then
    begin
      Header.subsampling_x := ReadBit(Reader);
      if Header.subsampling_x <> 0 then
        Header.subsampling_y := ReadBit(Reader)
      else
        Header.subsampling_y := 0;
    end
    else
    begin
      Header.subsampling_x := 1;
      Header.subsampling_y := 0;
    end;
    if (Header.subsampling_x <> 0) and (Header.subsampling_y <> 0) then
      Header.chroma_sample_position := ReadBits(Reader, 2);
  end;
  Header.separate_uv_delta_q := ReadFlag(Reader);
end;

procedure ParseSequenceHeader(var Reader: TBitReader; out Header: TSequenceHeader);
var
  Index: Integer;
  InitialDisplayDelayPresent: Boolean;
begin
  FillChar(Header, SizeOf(Header), 0);
  Header.seq_profile := ReadBits(Reader, 3);
  if Header.seq_profile > 2 then
    RaiseAv1Error('unknown profile ' + IntToStr(Header.seq_profile));
  Header.still_picture := ReadFlag(Reader);
  Header.reduced_still_picture_header := ReadFlag(Reader);
  if Header.reduced_still_picture_header then
  begin
    Header.operating_point_idc[0] := 0;
    Header.seq_level_idx[0] := ReadBits(Reader, 5);
  end
  else
  begin
    Header.timing_info_present_flag := ReadFlag(Reader);
    if Header.timing_info_present_flag then
    begin
      Header.num_units_in_display_tick := ReadBits(Reader, 32);
      Header.time_scale := ReadBits(Reader, 32);
      Header.equal_picture_interval := ReadFlag(Reader);
      if Header.equal_picture_interval then
        ReadUvlc(Reader);
      Header.decoder_model_info_present_flag := ReadFlag(Reader);
      if Header.decoder_model_info_present_flag then
      begin
        Header.buffer_delay_length_minus_1 := ReadBits(Reader, 5);
        ReadBits(Reader, 32);
        Header.buffer_removal_time_length_minus_1 := ReadBits(Reader, 5);
        Header.frame_presentation_time_length_minus_1 := ReadBits(Reader, 5);
      end;
    end;
    InitialDisplayDelayPresent := ReadFlag(Reader);
    Header.operating_points_cnt_minus_1 := ReadBits(Reader, 5);
    for Index := 0 to Header.operating_points_cnt_minus_1 do
    begin
      Header.operating_point_idc[Index] := ReadBits(Reader, 12);
      Header.seq_level_idx[Index] := ReadBits(Reader, 5);
      if Header.seq_level_idx[Index] > 7 then
        ReadBit(Reader);
      if Header.decoder_model_info_present_flag then
      begin
        Header.decoder_model_present_for_this_op[Index] := ReadFlag(Reader);
        if Header.decoder_model_present_for_this_op[Index] then
        begin
          ReadBits(Reader, Header.buffer_delay_length_minus_1 + 1);
          ReadBits(Reader, Header.buffer_delay_length_minus_1 + 1);
          ReadBit(Reader);
        end;
      end;
      if InitialDisplayDelayPresent then
        if ReadFlag(Reader) then
          ReadBits(Reader, 4);
    end;
  end;
  Header.OperatingPointIdc := Header.operating_point_idc[0];
  Header.frame_width_bits_minus_1 := ReadBits(Reader, 4);
  Header.frame_height_bits_minus_1 := ReadBits(Reader, 4);
  Header.max_frame_width_minus_1 := ReadBits(Reader, Header.frame_width_bits_minus_1 + 1);
  Header.max_frame_height_minus_1 := ReadBits(Reader, Header.frame_height_bits_minus_1 + 1);
  { The largest frames of the highest level are 16384 by 8704. }
  if (Header.max_frame_width_minus_1 >= 16384) or (Header.max_frame_height_minus_1 >= 16384) then
    RaiseAv1Error('frames larger than 16384 samples on a side');
  if Header.reduced_still_picture_header then
    Header.frame_id_numbers_present_flag := False
  else
    Header.frame_id_numbers_present_flag := ReadFlag(Reader);
  if Header.frame_id_numbers_present_flag then
  begin
    Header.delta_frame_id_length_minus_2 := ReadBits(Reader, 4);
    Header.additional_frame_id_length_minus_1 := ReadBits(Reader, 3);
  end;
  Header.use_128x128_superblock := ReadFlag(Reader);
  Header.enable_filter_intra := ReadFlag(Reader);
  Header.enable_intra_edge_filter := ReadFlag(Reader);
  if Header.reduced_still_picture_header then
  begin
    Header.seq_force_screen_content_tools := SELECT_SCREEN_CONTENT_TOOLS;
    Header.seq_force_integer_mv := SELECT_INTEGER_MV;
    Header.OrderHintBits := 0;
  end
  else
  begin
    Header.enable_interintra_compound := ReadFlag(Reader);
    Header.enable_masked_compound := ReadFlag(Reader);
    Header.enable_warped_motion := ReadFlag(Reader);
    Header.enable_dual_filter := ReadFlag(Reader);
    Header.enable_order_hint := ReadFlag(Reader);
    if Header.enable_order_hint then
    begin
      Header.enable_jnt_comp := ReadFlag(Reader);
      Header.enable_ref_frame_mvs := ReadFlag(Reader);
    end;
    if ReadFlag(Reader) then
      Header.seq_force_screen_content_tools := SELECT_SCREEN_CONTENT_TOOLS
    else
      Header.seq_force_screen_content_tools := ReadBit(Reader);
    if Header.seq_force_screen_content_tools > 0 then
    begin
      if ReadFlag(Reader) then
        Header.seq_force_integer_mv := SELECT_INTEGER_MV
      else
        Header.seq_force_integer_mv := ReadBit(Reader);
    end
    else
      Header.seq_force_integer_mv := SELECT_INTEGER_MV;
    if Header.enable_order_hint then
      Header.OrderHintBits := ReadBits(Reader, 3) + 1
    else
      Header.OrderHintBits := 0;
  end;
  Header.enable_superres := ReadFlag(Reader);
  Header.enable_cdef := ReadFlag(Reader);
  Header.enable_restoration := ReadFlag(Reader);
  ParseColorConfig(Reader, Header);
  Header.film_grain_params_present := ReadFlag(Reader);
end;

end.
