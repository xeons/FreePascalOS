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
  The coefficients of a transform block (specification section 5.11.39,
  coeffs( )) with the contexts of section 8.3.2: all_zero, the end of
  block, the base levels in reverse scan order, the ranges, the signs and
  the Golomb coded remainders. The transform class and the context
  tables are worked out once per block rather than once per coefficient
  as the specification writes it; the results are the same.
}
unit Av1.CoefficientSyntax;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.SymbolDecoder, Av1.FrameContext, Av1.TileContext;

{ coeffs( plane, startX, startY, txSz ): returns eob; fills Tile.Quant
  and Tile.PlaneTxType. }
function ReadCoefficients(Tile: TTileContext; Plane, StartX, StartY, TxSz: Integer): Integer;

implementation

uses
  Av1.TransformSyntax, Av1.ToolStatistics;

procedure CountTransformTools(Tile: TTileContext; TxSz: Integer);
var
  TxType: Integer;
begin
  TxType := Tile.PlaneTxType;
  if Tile.Lossless then
    CountTool(toolWalshHadamard);
  if Tx_Size_Sqr_Up[TxSz] = TX_64X64 then
    CountTool(toolTransform64);
  if Tx_Width[TxSz] <> Tx_Height[TxSz] then
    CountTool(toolTransformRectangular);
  if (TxType = IDTX) or (TxType >= V_DCT) then
    CountTool(toolTransformIdentity);
  if (TxType = FLIPADST_DCT) or (TxType = DCT_FLIPADST) or (TxType = FLIPADST_FLIPADST) or
    (TxType = ADST_FLIPADST) or (TxType = FLIPADST_ADST) or (TxType = V_FLIPADST) or (TxType = H_FLIPADST) then
    CountTool(toolTransformFlipAdst);
end;

const
  Coeff_Base_Pos_Ctx_Offset: array[0..2] of Integer =
    (SIG_COEF_CONTEXTS_2D, SIG_COEF_CONTEXTS_2D + 5, SIG_COEF_CONTEXTS_2D + 10);
  Mag_Ref_Offset_With_Tx_Class: array[0..2, 0..2, 0..1] of Integer = (
    ((0, 1), (1, 0), (1, 1)),
    ((0, 1), (1, 0), (0, 2)),
    ((0, 1), (1, 0), (2, 0)));

function GetTxClass(TxType: Integer): Integer;
begin
  if (TxType = V_DCT) or (TxType = V_ADST) or (TxType = V_FLIPADST) then
    Result := TX_CLASS_VERT
  else if (TxType = H_DCT) or (TxType = H_ADST) or (TxType = H_FLIPADST) then
    Result := TX_CLASS_HORIZ
  else
    Result := TX_CLASS_2D;
end;

function AllZeroContext(Tile: TTileContext; Plane, TxSz, X4, Y4, W4, H4: Integer): Integer;
var
  MaxX4, MaxY4, W, H, BlockSize, Bw, Bh, Top, Left, K, Above: Integer;
begin
  MaxX4 := Tile.Header^.MiCols;
  MaxY4 := Tile.Header^.MiRows;
  if Plane > 0 then
  begin
    MaxX4 := MaxX4 shr Tile.Sequence^.subsampling_x;
    MaxY4 := MaxY4 shr Tile.Sequence^.subsampling_y;
  end;
  W := Tx_Width[TxSz];
  H := Tx_Height[TxSz];
  BlockSize := Tile.GetPlaneResidualSize(Tile.MiSize, Plane);
  Bw := Block_Width(BlockSize);
  Bh := Block_Height(BlockSize);
  if Plane = 0 then
  begin
    Top := 0;
    Left := 0;
    for K := 0 to W4 - 1 do
      if X4 + K < MaxX4 then
        Top := Max(Top, Tile.AboveLevelContext[Plane][X4 + K]);
    for K := 0 to H4 - 1 do
      if Y4 + K < MaxY4 then
        Left := Max(Left, Tile.LeftLevelContext[Plane][Y4 + K]);
    Top := Min(Top, 255);
    Left := Min(Left, 255);
    if (Bw = W) and (Bh = H) then
      Result := 0
    else if (Top = 0) and (Left = 0) then
      Result := 1
    else if (Top = 0) or (Left = 0) then
      Result := 2 + Ord(Max(Top, Left) > 3)
    else if Max(Top, Left) <= 3 then
      Result := 4
    else if Min(Top, Left) <= 3 then
      Result := 5
    else
      Result := 6;
  end
  else
  begin
    Above := 0;
    Left := 0;
    for K := 0 to W4 - 1 do
      if X4 + K < MaxX4 then
        Above := Above or Tile.AboveLevelContext[Plane][X4 + K] or Tile.AboveDcContext[Plane][X4 + K];
    for K := 0 to H4 - 1 do
      if Y4 + K < MaxY4 then
        Left := Left or Tile.LeftLevelContext[Plane][Y4 + K] or Tile.LeftDcContext[Plane][Y4 + K];
    Result := Ord(Above <> 0) + Ord(Left <> 0) + 7;
    if Bw * Bh > W * H then
      Inc(Result, 3);
  end;
end;

function DcSignContext(Tile: TTileContext; Plane, X4, Y4, W4, H4: Integer): Integer;
var
  MaxX4, MaxY4, DcSign, K, Sign: Integer;
begin
  MaxX4 := Tile.Header^.MiCols;
  MaxY4 := Tile.Header^.MiRows;
  if Plane > 0 then
  begin
    MaxX4 := MaxX4 shr Tile.Sequence^.subsampling_x;
    MaxY4 := MaxY4 shr Tile.Sequence^.subsampling_y;
  end;
  DcSign := 0;
  for K := 0 to W4 - 1 do
    if X4 + K < MaxX4 then
    begin
      Sign := Tile.AboveDcContext[Plane][X4 + K];
      if Sign = 1 then
        Dec(DcSign)
      else if Sign = 2 then
        Inc(DcSign);
    end;
  for K := 0 to H4 - 1 do
    if Y4 + K < MaxY4 then
    begin
      Sign := Tile.LeftDcContext[Plane][Y4 + K];
      if Sign = 1 then
        Dec(DcSign)
      else if Sign = 2 then
        Inc(DcSign);
    end;
  if DcSign < 0 then
    Result := 1
  else if DcSign > 0 then
    Result := 2
  else
    Result := 0;
end;

type
  { What the base level and range contexts need of the transform block. }
  TCoefficientShape = record
    TxSz: Integer;
    Bwl: Integer;             { log2 of the adjusted width }
    Width, Height: Integer;   { adjusted size }
    TxClass: Integer;
  end;

function CoeffBaseContext(Tile: TTileContext; const Shape: TCoefficientShape; Pos: Integer): Integer;
var
  Row, Col, Mag, Index, RefRow, RefCol, Context, Value: Integer;
begin
  Row := Pos shr Shape.Bwl;
  Col := Pos - (Row shl Shape.Bwl);
  Mag := 0;
  for Index := 0 to SIG_REF_DIFF_OFFSET_NUM - 1 do
  begin
    RefRow := Row + Sig_Ref_Diff_Offset[Shape.TxClass, Index, 0];
    RefCol := Col + Sig_Ref_Diff_Offset[Shape.TxClass, Index, 1];
    if (RefRow >= 0) and (RefCol >= 0) and (RefRow < Shape.Height) and (RefCol < Shape.Width) then
    begin
      Value := Abs(Tile.Quant[(RefRow shl Shape.Bwl) + RefCol]);
      if Value > 3 then
        Value := 3;
      Inc(Mag, Value);
    end;
  end;
  Context := Min((Mag + 1) shr 1, 4);
  if Shape.TxClass = TX_CLASS_2D then
  begin
    if (Row = 0) and (Col = 0) then
      Exit(0);
    Exit(Context + Coeff_Base_Ctx_Offset[Shape.TxSz, Min(Row, 4), Min(Col, 4)]);
  end;
  if Shape.TxClass = TX_CLASS_VERT then
    Index := Row
  else
    Index := Col;
  Result := Context + Coeff_Base_Pos_Ctx_Offset[Min(Index, 2)];
end;

function CoeffBaseEobContext(const Shape: TCoefficientShape; C: Integer): Integer;
begin
  if C = 0 then
    Result := 0
  else if C <= (Shape.Height shl Shape.Bwl) div 8 then
    Result := 1
  else if C <= (Shape.Height shl Shape.Bwl) div 4 then
    Result := 2
  else
    Result := 3;
end;

function CoeffBrContext(Tile: TTileContext; const Shape: TCoefficientShape; Pos: Integer): Integer;
var
  Row, Col, Mag, Index, RefRow, RefCol, Value: Integer;
begin
  Row := Pos shr Shape.Bwl;
  Col := Pos - (Row shl Shape.Bwl);
  Mag := 0;
  for Index := 0 to 2 do
  begin
    RefRow := Row + Mag_Ref_Offset_With_Tx_Class[Shape.TxClass, Index, 0];
    RefCol := Col + Mag_Ref_Offset_With_Tx_Class[Shape.TxClass, Index, 1];
    if (RefRow >= 0) and (RefCol >= 0) and (RefRow < Shape.Height) and (RefCol < (1 shl Shape.Bwl)) then
    begin
      Value := Tile.Quant[RefRow * Shape.Width + RefCol];
      if Value > COEFF_BASE_RANGE + NUM_BASE_LEVELS + 1 then
        Value := COEFF_BASE_RANGE + NUM_BASE_LEVELS + 1;
      Inc(Mag, Value);
    end;
  end;
  Mag := Min((Mag + 1) shr 1, 6);
  if Pos = 0 then
    Result := Mag
  else if Shape.TxClass = TX_CLASS_2D then
  begin
    if (Row < 2) and (Col < 2) then
      Result := Mag + 7
    else
      Result := Mag + 14;
  end
  else if Shape.TxClass = TX_CLASS_HORIZ then
  begin
    if Col = 0 then
      Result := Mag + 7
    else
      Result := Mag + 14;
  end
  else if Row = 0 then
    Result := Mag + 7
  else
    Result := Mag + 14;
end;

function ReadEndOfBlock(Tile: TTileContext; TxSz, TxSzCtx, PlaneType, TxClass: Integer): Integer;
var
  EobMultisize, Context, EobPt, EobShift, Index: Integer;
  Symbols: ^TSymbolDecoder;
begin
  Symbols := @Tile.Symbols;
  EobMultisize := Min(Tx_Width_Log2[TxSz], 5) + Min(Tx_Height_Log2[TxSz], 5) - 4;
  if TxClass = TX_CLASS_2D then
    Context := 0
  else
    Context := 1;
  case EobMultisize of
    0: EobPt := ReadSymbol(Symbols^, @Tile.Cdf.EobPt16Cdf[PlaneType, Context], 5) + 1;
    1: EobPt := ReadSymbol(Symbols^, @Tile.Cdf.EobPt32Cdf[PlaneType, Context], 6) + 1;
    2: EobPt := ReadSymbol(Symbols^, @Tile.Cdf.EobPt64Cdf[PlaneType, Context], 7) + 1;
    3: EobPt := ReadSymbol(Symbols^, @Tile.Cdf.EobPt128Cdf[PlaneType, Context], 8) + 1;
    4: EobPt := ReadSymbol(Symbols^, @Tile.Cdf.EobPt256Cdf[PlaneType, Context], 9) + 1;
    5: EobPt := ReadSymbol(Symbols^, @Tile.Cdf.EobPt512Cdf[PlaneType], 10) + 1;
  else
    EobPt := ReadSymbol(Symbols^, @Tile.Cdf.EobPt1024Cdf[PlaneType], 11) + 1;
  end;
  if EobPt < 2 then
    Result := EobPt
  else
    Result := (1 shl (EobPt - 2)) + 1;
  EobShift := Max(-1, EobPt - 3);
  if EobShift >= 0 then
  begin
    if ReadSymbol(Symbols^, @Tile.Cdf.EobExtraCdf[TxSzCtx, PlaneType, EobPt - 3], 2) <> 0 then
      Inc(Result, 1 shl EobShift);
    for Index := 1 to Max(0, EobPt - 2) - 1 do
    begin
      EobShift := Max(0, EobPt - 2) - 1 - Index;
      if ReadLiteral(Symbols^, 1) <> 0 then
        Inc(Result, 1 shl EobShift);
    end;
  end;
end;

function ReadGolomb(Tile: TTileContext): Integer;
var
  Length, Index: Integer;
begin
  Length := 0;
  repeat
    Inc(Length);
    if Length > 32 then
      RaiseAv1Error('Golomb code too long');
  until ReadLiteral(Tile.Symbols, 1) <> 0;
  Result := 1;
  for Index := Length - 2 downto 0 do
    Result := (Result shl 1) or ReadLiteral(Tile.Symbols, 1);
end;

function ReadCoefficients(Tile: TTileContext; Plane, StartX, StartY, TxSz: Integer): Integer;
var
  X4, Y4, W4, H4, TxSzCtx, PlaneType, SegEob, C, Eob, CulLevel, DcCategory, Index: Integer;
  Pos, Level, CoeffBr, Sign, Value, BrIndex, AdjTxSz: Integer;
  Scan: TScanOrder;
  Shape: TCoefficientShape;
  Symbols: ^TSymbolDecoder;
  BrCtxSize: Integer;
  AllZero: Boolean;
begin
  Symbols := @Tile.Symbols;
  X4 := StartX shr 2;
  Y4 := StartY shr 2;
  W4 := Tx_Width[TxSz] shr 2;
  H4 := Tx_Height[TxSz] shr 2;
  TxSzCtx := (Tx_Size_Sqr[TxSz] + Tx_Size_Sqr_Up[TxSz] + 1) shr 1;
  PlaneType := Ord(Plane > 0);
  if (TxSz = TX_16X64) or (TxSz = TX_64X16) then
    SegEob := 512
  else
    SegEob := Min(1024, Tx_Width[TxSz] * Tx_Height[TxSz]);
  FillChar(Tile.Quant, SegEob * SizeOf(Integer), 0);
  Eob := 0;
  CulLevel := 0;
  DcCategory := 0;
  AllZero := ReadSymbol(Symbols^, @Tile.Cdf.TxbSkipCdf[TxSzCtx, AllZeroContext(Tile, Plane, TxSz, X4, Y4, W4, H4)], 2) <> 0;
  if AllZero then
  begin
    if Plane = 0 then
      for Index := 0 to W4 - 1 do
        for C := 0 to H4 - 1 do
          Tile.Frame.Block(Y4 + C, X4 + Index)^.TxType := DCT_DCT;
  end
  else
  begin
    if Plane = 0 then
      ReadTransformType(Tile, X4, Y4, TxSz);
    Tile.PlaneTxType := ComputeTxType(Tile, Plane, TxSz, X4, Y4);
    CountTransformTools(Tile, TxSz);
    Scan := GetScan(Tile, TxSz);
    AdjTxSz := Adjusted_Tx_Size[TxSz];
    Shape.TxSz := TxSz;
    Shape.Bwl := Tx_Width_Log2[AdjTxSz];
    Shape.Width := 1 shl Shape.Bwl;
    Shape.Height := Tx_Height[AdjTxSz];
    Shape.TxClass := GetTxClass(Tile.PlaneTxType);
    Eob := ReadEndOfBlock(Tile, TxSz, TxSzCtx, PlaneType, Shape.TxClass);
    BrCtxSize := Min(TxSzCtx, TX_32X32);
    for C := Eob - 1 downto 0 do
    begin
      Pos := Scan[C];
      if C = Eob - 1 then
        Level := ReadSymbol(Symbols^, @Tile.Cdf.CoeffBaseEobCdf[TxSzCtx, PlaneType, CoeffBaseEobContext(Shape, C)], 3) + 1
      else
        Level := ReadSymbol(Symbols^, @Tile.Cdf.CoeffBaseCdf[TxSzCtx, PlaneType, CoeffBaseContext(Tile, Shape, Pos)], 4);
      if Level > NUM_BASE_LEVELS then
        for BrIndex := 0 to COEFF_BASE_RANGE div (BR_CDF_SIZE - 1) - 1 do
        begin
          CoeffBr := ReadSymbol(Symbols^, @Tile.Cdf.CoeffBrCdf[BrCtxSize, PlaneType, CoeffBrContext(Tile, Shape, Pos)],
            BR_CDF_SIZE);
          Inc(Level, CoeffBr);
          if CoeffBr < BR_CDF_SIZE - 1 then
            Break;
        end;
      Tile.Quant[Pos] := Level;
    end;
    for C := 0 to Eob - 1 do
    begin
      Pos := Scan[C];
      Value := Tile.Quant[Pos];
      if Value <> 0 then
      begin
        if C = 0 then
          Sign := ReadSymbol(Symbols^, @Tile.Cdf.DcSignCdf[PlaneType, DcSignContext(Tile, Plane, X4, Y4, W4, H4)], 2)
        else
          Sign := ReadLiteral(Symbols^, 1);
      end
      else
        Sign := 0;
      if Value > NUM_BASE_LEVELS + COEFF_BASE_RANGE then
        Value := ReadGolomb(Tile) + COEFF_BASE_RANGE + NUM_BASE_LEVELS;
      if (Pos = 0) and (Value > 0) then
      begin
        if Sign <> 0 then
          DcCategory := 1
        else
          DcCategory := 2;
      end;
      Value := Value and $FFFFF;
      Inc(CulLevel, Value);
      if Sign <> 0 then
        Value := -Value;
      Tile.Quant[Pos] := Value;
    end;
    CulLevel := Min(63, CulLevel);
  end;
  for Index := 0 to W4 - 1 do
  begin
    Tile.AboveLevelContext[Plane][X4 + Index] := CulLevel;
    Tile.AboveDcContext[Plane][X4 + Index] := DcCategory;
  end;
  for Index := 0 to H4 - 1 do
  begin
    Tile.LeftLevelContext[Plane][Y4 + Index] := CulLevel;
    Tile.LeftDcContext[Plane][Y4 + Index] := DcCategory;
  end;
  Result := Eob;
end;

end.
