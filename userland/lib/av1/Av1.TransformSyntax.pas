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
  Transform sizes and types (specification sections 5.11.15 to 5.11.17,
  5.11.40, 5.11.47, 5.11.48 and the get_scan, compute_tx_type,
  get_tx_size functions): the transform size tree of a block, the
  transform type of each luma transform block and the scan order it
  implies.
}
unit Av1.TransformSyntax;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.SymbolDecoder, Av1.FrameContext, Av1.TileContext;

procedure ReadBlockTxSize(Tile: TTileContext);
procedure ReadTransformType(Tile: TTileContext; X4, Y4, TxSz: Integer);
function ComputeTxType(Tile: TTileContext; Plane, TxSz, BlockX, BlockY: Integer): Integer;
function GetTxSet(Tile: TTileContext; TxSz: Integer): Integer;
function GetScan(Tile: TTileContext; TxSz: Integer): TScanOrder;
function GetTxSize(Tile: TTileContext; Plane, TxSz: Integer): Integer;
function FindTxSize(W, H: Integer): Integer;

implementation

uses
  Av1.ToolStatistics;

const
  Tx_Type_In_Set_Intra: array[0..TX_SET_TYPES_INTRA - 1, 0..TX_TYPES - 1] of Byte = (
    (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
    (1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0),
    (1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0));
  Tx_Type_In_Set_Inter: array[0..TX_SET_TYPES_INTER - 1, 0..TX_TYPES - 1] of Byte = (
    (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
    (1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1),
    (1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0),
    (1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0));
  Filter_Intra_Mode_To_Intra_Dir: array[0..INTRA_FILTER_MODES - 1] of Integer =
    (DC_PRED, V_PRED, H_PRED, D157_PRED, DC_PRED);

function FindTxSize(W, H: Integer): Integer;
begin
  Result := 0;
  while Result < TX_SIZES_ALL do
  begin
    if (Tx_Width[Result] = W) and (Tx_Height[Result] = H) then
      Exit;
    Inc(Result);
  end;
end;

function GetAboveTxWidth(Tile: TTileContext; Row, Col: Integer): Integer;
var
  Above: PBlockInfo;
begin
  if (Row = Tile.MiRow) and not Tile.AvailU then
    Exit(64);
  Above := Tile.Frame.Block(Row - 1, Col);
  if (Row = Tile.MiRow) and Above^.Skip and Above^.IsInter then
    Exit(Block_Width(Above^.MiSize));
  Result := Tx_Width[Above^.InterTxSize];
end;

function GetLeftTxHeight(Tile: TTileContext; Row, Col: Integer): Integer;
var
  Left: PBlockInfo;
begin
  if (Col = Tile.MiCol) and not Tile.AvailL then
    Exit(64);
  Left := Tile.Frame.Block(Row, Col - 1);
  if (Col = Tile.MiCol) and Left^.Skip and Left^.IsInter then
    Exit(Block_Height(Left^.MiSize));
  Result := Tx_Height[Left^.InterTxSize];
end;

procedure ReadTxSize(Tile: TTileContext; AllowSelect: Boolean);
var
  MaxRectTxSize, MaxTxDepth, MaxTxWidth, MaxTxHeight, AboveW, LeftH, Context, TxDepth, Index: Integer;
  Frame: TFrameContext;
  Cdf: PWord;
  Symbols: Integer;
begin
  if Tile.Lossless then
  begin
    Tile.TxSize := TX_4X4;
    Exit;
  end;
  Frame := Tile.Frame;
  MaxRectTxSize := Max_Tx_Size_Rect[Tile.MiSize];
  MaxTxDepth := Max_Tx_Depth_Table[Tile.MiSize];
  Tile.TxSize := MaxRectTxSize;
  if (Tile.MiSize > BLOCK_4X4) and AllowSelect and (Tile.Header^.TxMode = TX_MODE_SELECT) then
  begin
    MaxTxWidth := Tx_Width[MaxRectTxSize];
    MaxTxHeight := Tx_Height[MaxRectTxSize];
    if Tile.AvailU and Frame.Block(Tile.MiRow - 1, Tile.MiCol)^.IsInter then
      AboveW := Block_Width(Frame.Block(Tile.MiRow - 1, Tile.MiCol)^.MiSize)
    else if Tile.AvailU then
      AboveW := GetAboveTxWidth(Tile, Tile.MiRow, Tile.MiCol)
    else
      AboveW := 0;
    if Tile.AvailL and Frame.Block(Tile.MiRow, Tile.MiCol - 1)^.IsInter then
      LeftH := Block_Height(Frame.Block(Tile.MiRow, Tile.MiCol - 1)^.MiSize)
    else if Tile.AvailL then
      LeftH := GetLeftTxHeight(Tile, Tile.MiRow, Tile.MiCol)
    else
      LeftH := 0;
    Context := Ord(AboveW >= MaxTxWidth) + Ord(LeftH >= MaxTxHeight);
    case MaxTxDepth of
      4:
        begin
          Cdf := @Tile.Cdf.Tx64x64Cdf[Context];
          Symbols := MAX_TX_DEPTH + 1;
        end;
      3:
        begin
          Cdf := @Tile.Cdf.Tx32x32Cdf[Context];
          Symbols := MAX_TX_DEPTH + 1;
        end;
      2:
        begin
          Cdf := @Tile.Cdf.Tx16x16Cdf[Context];
          Symbols := MAX_TX_DEPTH + 1;
        end;
    else
      Cdf := @Tile.Cdf.Tx8x8Cdf[Context];
      Symbols := MAX_TX_DEPTH;
    end;
    TxDepth := ReadSymbol(Tile.Symbols, Cdf, Symbols);
    for Index := 1 to TxDepth do
      Tile.TxSize := Split_Tx_Size[Tile.TxSize];
  end;
end;

procedure ReadVarTxSize(Tile: TTileContext; Row, Col, TxSz, Depth: Integer);
var
  TxfmSplit: Boolean;
  W4, H4, SubTxSz, StepW, StepH, I, J, Size, MaxTxSz, Context: Integer;
  Above, Left: Boolean;
begin
  if (Row >= Tile.Header^.MiRows) or (Col >= Tile.Header^.MiCols) then
    Exit;
  if (TxSz = TX_4X4) or (Depth = MAX_VARTX_DEPTH) then
    TxfmSplit := False
  else
  begin
    Above := GetAboveTxWidth(Tile, Row, Col) < Tx_Width[TxSz];
    Left := GetLeftTxHeight(Tile, Row, Col) < Tx_Height[TxSz];
    Size := Min(64, Max(Block_Width(Tile.MiSize), Block_Height(Tile.MiSize)));
    MaxTxSz := FindTxSize(Size, Size);
    Context := Ord(Tx_Size_Sqr_Up[TxSz] <> MaxTxSz) * 3 + (TX_SIZES - 1 - MaxTxSz) * 6 + Ord(Above) + Ord(Left);
    TxfmSplit := ReadSymbol(Tile.Symbols, @Tile.Cdf.TxfmSplitCdf[Context], 2) <> 0;
  end;
  W4 := Tx_Width[TxSz] div MI_SIZE;
  H4 := Tx_Height[TxSz] div MI_SIZE;
  if TxfmSplit then
  begin
    CountTool(toolTransformSplit);
    SubTxSz := Split_Tx_Size[TxSz];
    StepW := Tx_Width[SubTxSz] div MI_SIZE;
    StepH := Tx_Height[SubTxSz] div MI_SIZE;
    I := 0;
    while I < H4 do
    begin
      J := 0;
      while J < W4 do
      begin
        ReadVarTxSize(Tile, Row + I, Col + J, SubTxSz, Depth + 1);
        Inc(J, StepW);
      end;
      Inc(I, StepH);
    end;
  end
  else
  begin
    for I := 0 to H4 - 1 do
      for J := 0 to W4 - 1 do
        Tile.Frame.Block(Row + I, Col + J)^.InterTxSize := TxSz;
    Tile.TxSize := TxSz;
  end;
end;

procedure ReadBlockTxSize(Tile: TTileContext);
var
  Bw4, Bh4, MaxTxSz, TxW4, TxH4, Row, Col: Integer;
begin
  Bw4 := Num_4x4_Blocks_Wide[Tile.MiSize];
  Bh4 := Num_4x4_Blocks_High[Tile.MiSize];
  if (Tile.Header^.TxMode = TX_MODE_SELECT) and (Tile.MiSize > BLOCK_4X4) and Tile.is_inter and
    (not Tile.skip) and (not Tile.Lossless) then
  begin
    MaxTxSz := Max_Tx_Size_Rect[Tile.MiSize];
    TxW4 := Tx_Width[MaxTxSz] div MI_SIZE;
    TxH4 := Tx_Height[MaxTxSz] div MI_SIZE;
    Row := Tile.MiRow;
    while Row < Tile.MiRow + Bh4 do
    begin
      Col := Tile.MiCol;
      while Col < Tile.MiCol + Bw4 do
      begin
        ReadVarTxSize(Tile, Row, Col, MaxTxSz, 0);
        Inc(Col, TxW4);
      end;
      Inc(Row, TxH4);
    end;
  end
  else
  begin
    ReadTxSize(Tile, (not Tile.skip) or (not Tile.is_inter));
    for Row := Tile.MiRow to Tile.MiRow + Bh4 - 1 do
      for Col := Tile.MiCol to Tile.MiCol + Bw4 - 1 do
        Tile.Frame.Block(Row, Col)^.InterTxSize := Tile.TxSize;
  end;
end;

function GetTxSet(Tile: TTileContext; TxSz: Integer): Integer;
var
  TxSzSqr, TxSzSqrUp: Integer;
begin
  TxSzSqr := Tx_Size_Sqr[TxSz];
  TxSzSqrUp := Tx_Size_Sqr_Up[TxSz];
  if TxSzSqrUp > TX_32X32 then
    Exit(TX_SET_DCTONLY);
  if Tile.is_inter then
  begin
    if Tile.Header^.reduced_tx_set or (TxSzSqrUp = TX_32X32) then
      Result := TX_SET_INTER_3
    else if TxSzSqr = TX_16X16 then
      Result := TX_SET_INTER_2
    else
      Result := TX_SET_INTER_1;
  end
  else
  begin
    if TxSzSqrUp = TX_32X32 then
      Result := TX_SET_DCTONLY
    else if Tile.Header^.reduced_tx_set then
      Result := TX_SET_INTRA_2
    else if TxSzSqr = TX_16X16 then
      Result := TX_SET_INTRA_2
    else
      Result := TX_SET_INTRA_1;
  end;
end;

procedure ReadTransformType(Tile: TTileContext; X4, Y4, TxSz: Integer);
var
  TxSet, QIndex, TxType, IntraDir, I, J: Integer;
begin
  TxSet := GetTxSet(Tile, TxSz);
  if Tile.Header^.segmentation_enabled then
    QIndex := Tile.GetQIndex(True, Tile.segment_id)
  else
    QIndex := Tile.Header^.base_q_idx;
  if (TxSet > 0) and (QIndex > 0) then
  begin
    if Tile.is_inter then
    begin
      case TxSet of
        TX_SET_INTER_1:
          TxType := Tx_Type_Inter_Inv_Set1[ReadSymbol(Tile.Symbols,
            @Tile.Cdf.InterTxTypeSet1Cdf[Tx_Size_Sqr[TxSz]], 16)];
        TX_SET_INTER_2:
          TxType := Tx_Type_Inter_Inv_Set2[ReadSymbol(Tile.Symbols, @Tile.Cdf.InterTxTypeSet2Cdf, 12)];
      else
        TxType := Tx_Type_Inter_Inv_Set3[ReadSymbol(Tile.Symbols,
          @Tile.Cdf.InterTxTypeSet3Cdf[Tx_Size_Sqr[TxSz]], 2)];
      end;
    end
    else
    begin
      if Tile.use_filter_intra then
        IntraDir := Filter_Intra_Mode_To_Intra_Dir[Tile.filter_intra_mode]
      else
        IntraDir := Tile.YMode;
      if TxSet = TX_SET_INTRA_1 then
        TxType := Tx_Type_Intra_Inv_Set1[ReadSymbol(Tile.Symbols,
          @Tile.Cdf.IntraTxTypeSet1Cdf[Tx_Size_Sqr[TxSz], IntraDir], 7)]
      else
        TxType := Tx_Type_Intra_Inv_Set2[ReadSymbol(Tile.Symbols,
          @Tile.Cdf.IntraTxTypeSet2Cdf[Tx_Size_Sqr[TxSz], IntraDir], 5)];
    end;
  end
  else
    TxType := DCT_DCT;
  for I := 0 to (Tx_Width[TxSz] shr 2) - 1 do
    for J := 0 to (Tx_Height[TxSz] shr 2) - 1 do
      Tile.Frame.Block(Y4 + J, X4 + I)^.TxType := TxType;
end;

function IsTxTypeInSet(Tile: TTileContext; TxSet, TxType: Integer): Boolean;
begin
  if Tile.is_inter then
    Result := Tx_Type_In_Set_Inter[TxSet, TxType] <> 0
  else
    Result := Tx_Type_In_Set_Intra[TxSet, TxType] <> 0;
end;

function ComputeTxType(Tile: TTileContext; Plane, TxSz, BlockX, BlockY: Integer): Integer;
var
  TxSet, X4, Y4: Integer;
begin
  if Tile.Lossless or (Tx_Size_Sqr_Up[TxSz] > TX_32X32) then
    Exit(DCT_DCT);
  TxSet := GetTxSet(Tile, TxSz);
  if Plane = 0 then
    Exit(Tile.Frame.Block(BlockY, BlockX)^.TxType);
  if Tile.is_inter then
  begin
    X4 := Max(Tile.MiCol, BlockX shl Tile.Sequence^.subsampling_x);
    Y4 := Max(Tile.MiRow, BlockY shl Tile.Sequence^.subsampling_y);
    Result := Tile.Frame.Block(Y4, X4)^.TxType;
    if not IsTxTypeInSet(Tile, TxSet, Result) then
      Result := DCT_DCT;
    Exit;
  end;
  Result := Mode_To_Txfm[Tile.UVMode];
  if not IsTxTypeInSet(Tile, TxSet, Result) then
    Result := DCT_DCT;
end;

function GetMrowScan(TxSz: Integer): TScanOrder;
begin
  case TxSz of
    TX_4X4: Result := @Mrow_Scan_4x4;
    TX_4X8: Result := @Mrow_Scan_4x8;
    TX_8X4: Result := @Mrow_Scan_8x4;
    TX_8X8: Result := @Mrow_Scan_8x8;
    TX_8X16: Result := @Mrow_Scan_8x16;
    TX_16X8: Result := @Mrow_Scan_16x8;
    TX_16X16: Result := @Mrow_Scan_16x16;
    TX_4X16: Result := @Mrow_Scan_4x16;
  else
    Result := @Mrow_Scan_16x4;
  end;
end;

function GetMcolScan(TxSz: Integer): TScanOrder;
begin
  case TxSz of
    TX_4X4: Result := @Mcol_Scan_4x4;
    TX_4X8: Result := @Mcol_Scan_4x8;
    TX_8X4: Result := @Mcol_Scan_8x4;
    TX_8X8: Result := @Mcol_Scan_8x8;
    TX_8X16: Result := @Mcol_Scan_8x16;
    TX_16X8: Result := @Mcol_Scan_16x8;
    TX_16X16: Result := @Mcol_Scan_16x16;
    TX_4X16: Result := @Mcol_Scan_4x16;
  else
    Result := @Mcol_Scan_16x4;
  end;
end;

function GetDefaultScan(TxSz: Integer): TScanOrder;
begin
  case TxSz of
    TX_4X4: Result := @Default_Scan_4x4;
    TX_4X8: Result := @Default_Scan_4x8;
    TX_8X4: Result := @Default_Scan_8x4;
    TX_8X8: Result := @Default_Scan_8x8;
    TX_8X16: Result := @Default_Scan_8x16;
    TX_16X8: Result := @Default_Scan_16x8;
    TX_16X16: Result := @Default_Scan_16x16;
    TX_16X32: Result := @Default_Scan_16x32;
    TX_32X16: Result := @Default_Scan_32x16;
    TX_4X16: Result := @Default_Scan_4x16;
    TX_16X4: Result := @Default_Scan_16x4;
    TX_8X32: Result := @Default_Scan_8x32;
    TX_32X8: Result := @Default_Scan_32x8;
  else
    Result := @Default_Scan_32x32;
  end;
end;

function GetScan(Tile: TTileContext; TxSz: Integer): TScanOrder;
var
  TxType: Integer;
begin
  if TxSz = TX_16X64 then
    Exit(@Default_Scan_16x32);
  if TxSz = TX_64X16 then
    Exit(@Default_Scan_32x16);
  if Tx_Size_Sqr_Up[TxSz] = TX_64X64 then
    Exit(@Default_Scan_32x32);
  TxType := Tile.PlaneTxType;
  if TxType = IDTX then
    Exit(GetDefaultScan(TxSz));
  if (TxType = V_DCT) or (TxType = V_ADST) or (TxType = V_FLIPADST) then
    Result := GetMrowScan(TxSz)
  else if (TxType = H_DCT) or (TxType = H_ADST) or (TxType = H_FLIPADST) then
    Result := GetMcolScan(TxSz)
  else
    Result := GetDefaultScan(TxSz);
end;

function GetTxSize(Tile: TTileContext; Plane, TxSz: Integer): Integer;
var
  UvTx: Integer;
begin
  if Plane = 0 then
    Exit(TxSz);
  UvTx := Max_Tx_Size_Rect[Tile.GetPlaneResidualSize(Tile.MiSize, Plane)];
  if (Tx_Width[UvTx] = 64) or (Tx_Height[UvTx] = 64) then
  begin
    if Tx_Width[UvTx] = 16 then
      Exit(TX_16X32);
    if Tx_Height[UvTx] = 16 then
      Exit(TX_32X16);
    Exit(TX_32X32);
  end;
  Result := UvTx;
end;

end.
