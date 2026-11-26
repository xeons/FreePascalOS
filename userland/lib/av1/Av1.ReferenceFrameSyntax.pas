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
  The reference frames of an inter block (specification section
  5.11.25, read_ref_frames) with the contexts of section 8.3.2, which
  count the references of the blocks above and to the left.
}
unit Av1.ReferenceFrameSyntax;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.SymbolDecoder, Av1.TileContext;

procedure ReadRefFrames(Tile: TTileContext);

implementation

function CountRefs(Tile: TTileContext; FrameType: Integer): Integer;
begin
  Result := 0;
  if Tile.AvailU then
  begin
    if Tile.AboveRefFrame[0] = FrameType then
      Inc(Result);
    if Tile.AboveRefFrame[1] = FrameType then
      Inc(Result);
  end;
  if Tile.AvailL then
  begin
    if Tile.LeftRefFrame[0] = FrameType then
      Inc(Result);
    if Tile.LeftRefFrame[1] = FrameType then
      Inc(Result);
  end;
end;

function RefCountContext(Counts0, Counts1: Integer): Integer;
begin
  if Counts0 < Counts1 then
    Result := 0
  else if Counts0 = Counts1 then
    Result := 1
  else
    Result := 2;
end;

function CheckBackward(RefFrame: Integer): Boolean;
begin
  Result := (RefFrame >= BWDREF_FRAME) and (RefFrame <= ALTREF_FRAME);
end;

{ The contexts named after the syntax element that first uses them. }
function CompRefContext(Tile: TTileContext): Integer;
begin
  Result := RefCountContext(CountRefs(Tile, LAST_FRAME) + CountRefs(Tile, LAST2_FRAME),
    CountRefs(Tile, LAST3_FRAME) + CountRefs(Tile, GOLDEN_FRAME));
end;

function CompRefP1Context(Tile: TTileContext): Integer;
begin
  Result := RefCountContext(CountRefs(Tile, LAST_FRAME), CountRefs(Tile, LAST2_FRAME));
end;

function CompRefP2Context(Tile: TTileContext): Integer;
begin
  Result := RefCountContext(CountRefs(Tile, LAST3_FRAME), CountRefs(Tile, GOLDEN_FRAME));
end;

function CompBwdrefContext(Tile: TTileContext): Integer;
begin
  Result := RefCountContext(CountRefs(Tile, BWDREF_FRAME) + CountRefs(Tile, ALTREF2_FRAME),
    CountRefs(Tile, ALTREF_FRAME));
end;

function CompBwdrefP1Context(Tile: TTileContext): Integer;
begin
  Result := RefCountContext(CountRefs(Tile, BWDREF_FRAME), CountRefs(Tile, ALTREF2_FRAME));
end;

function SingleRefP1Context(Tile: TTileContext): Integer;
var
  ForwardCount, BackwardCount: Integer;
begin
  ForwardCount := CountRefs(Tile, LAST_FRAME) + CountRefs(Tile, LAST2_FRAME) + CountRefs(Tile, LAST3_FRAME) +
    CountRefs(Tile, GOLDEN_FRAME);
  BackwardCount := CountRefs(Tile, BWDREF_FRAME) + CountRefs(Tile, ALTREF2_FRAME) + CountRefs(Tile, ALTREF_FRAME);
  Result := RefCountContext(ForwardCount, BackwardCount);
end;

function UniCompRefP1Context(Tile: TTileContext): Integer;
begin
  Result := RefCountContext(CountRefs(Tile, LAST2_FRAME), CountRefs(Tile, LAST3_FRAME) + CountRefs(Tile, GOLDEN_FRAME));
end;

function CompModeContext(Tile: TTileContext): Integer;
begin
  if Tile.AvailU and Tile.AvailL then
  begin
    if Tile.AboveSingle and Tile.LeftSingle then
      Result := Ord(CheckBackward(Tile.AboveRefFrame[0])) xor Ord(CheckBackward(Tile.LeftRefFrame[0]))
    else if Tile.AboveSingle then
      Result := 2 + Ord(CheckBackward(Tile.AboveRefFrame[0]) or Tile.AboveIntra)
    else if Tile.LeftSingle then
      Result := 2 + Ord(CheckBackward(Tile.LeftRefFrame[0]) or Tile.LeftIntra)
    else
      Result := 4;
  end
  else if Tile.AvailU then
  begin
    if Tile.AboveSingle then
      Result := Ord(CheckBackward(Tile.AboveRefFrame[0]))
    else
      Result := 3;
  end
  else if Tile.AvailL then
  begin
    if Tile.LeftSingle then
      Result := Ord(CheckBackward(Tile.LeftRefFrame[0]))
    else
      Result := 3;
  end
  else
    Result := 1;
end;

function IsSameDirRefPair(Ref0, Ref1: Integer): Boolean;
begin
  Result := (Ref0 >= BWDREF_FRAME) = (Ref1 >= BWDREF_FRAME);
end;

function CompRefTypeContext(Tile: TTileContext): Integer;
var
  Above0, Above1, Left0, Left1: Integer;
  AboveCompInter, LeftCompInter, AboveUniComp, LeftUniComp, SameDir: Boolean;
begin
  Above0 := Tile.AboveRefFrame[0];
  Above1 := Tile.AboveRefFrame[1];
  Left0 := Tile.LeftRefFrame[0];
  Left1 := Tile.LeftRefFrame[1];
  AboveCompInter := Tile.AvailU and not Tile.AboveIntra and not Tile.AboveSingle;
  LeftCompInter := Tile.AvailL and not Tile.LeftIntra and not Tile.LeftSingle;
  AboveUniComp := AboveCompInter and IsSameDirRefPair(Above0, Above1);
  LeftUniComp := LeftCompInter and IsSameDirRefPair(Left0, Left1);
  if Tile.AvailU and not Tile.AboveIntra and Tile.AvailL and not Tile.LeftIntra then
  begin
    SameDir := IsSameDirRefPair(Above0, Left0);
    if (not AboveCompInter) and (not LeftCompInter) then
      Result := 1 + 2 * Ord(SameDir)
    else if not AboveCompInter then
    begin
      if not LeftUniComp then
        Result := 1
      else
        Result := 3 + Ord(SameDir);
    end
    else if not LeftCompInter then
    begin
      if not AboveUniComp then
        Result := 1
      else
        Result := 3 + Ord(SameDir);
    end
    else
    begin
      if (not AboveUniComp) and (not LeftUniComp) then
        Result := 0
      else if (not AboveUniComp) or (not LeftUniComp) then
        Result := 2
      else
        Result := 3 + Ord((Above0 = BWDREF_FRAME) = (Left0 = BWDREF_FRAME));
    end;
  end
  else if Tile.AvailU and Tile.AvailL then
  begin
    if AboveCompInter then
      Result := 1 + 2 * Ord(AboveUniComp)
    else if LeftCompInter then
      Result := 1 + 2 * Ord(LeftUniComp)
    else
      Result := 2;
  end
  else if AboveCompInter then
    Result := 4 * Ord(AboveUniComp)
  else if LeftCompInter then
    Result := 4 * Ord(LeftUniComp)
  else
    Result := 2;
end;

function ReadBit(Tile: TTileContext; Cdf: PWord): Boolean; inline;
begin
  Result := ReadSymbol(Tile.Symbols, Cdf, 2) <> 0;
end;

procedure ReadCompoundRefs(Tile: TTileContext);
begin
  if ReadSymbol(Tile.Symbols, @Tile.Cdf.CompRefTypeCdf[CompRefTypeContext(Tile)], 2) = UNIDIR_COMP_REFERENCE then
  begin
    if ReadBit(Tile, @Tile.Cdf.UniCompRefCdf[SingleRefP1Context(Tile), 0]) then
    begin
      Tile.RefFrame[0] := BWDREF_FRAME;
      Tile.RefFrame[1] := ALTREF_FRAME;
    end
    else if ReadBit(Tile, @Tile.Cdf.UniCompRefCdf[UniCompRefP1Context(Tile), 1]) then
    begin
      if ReadBit(Tile, @Tile.Cdf.UniCompRefCdf[CompRefP2Context(Tile), 2]) then
      begin
        Tile.RefFrame[0] := LAST_FRAME;
        Tile.RefFrame[1] := GOLDEN_FRAME;
      end
      else
      begin
        Tile.RefFrame[0] := LAST_FRAME;
        Tile.RefFrame[1] := LAST3_FRAME;
      end;
    end
    else
    begin
      Tile.RefFrame[0] := LAST_FRAME;
      Tile.RefFrame[1] := LAST2_FRAME;
    end;
  end
  else
  begin
    if not ReadBit(Tile, @Tile.Cdf.CompRefCdf[CompRefContext(Tile), 0]) then
    begin
      if ReadBit(Tile, @Tile.Cdf.CompRefCdf[CompRefP1Context(Tile), 1]) then
        Tile.RefFrame[0] := LAST2_FRAME
      else
        Tile.RefFrame[0] := LAST_FRAME;
    end
    else
    begin
      if ReadBit(Tile, @Tile.Cdf.CompRefCdf[CompRefP2Context(Tile), 2]) then
        Tile.RefFrame[0] := GOLDEN_FRAME
      else
        Tile.RefFrame[0] := LAST3_FRAME;
    end;
    if not ReadBit(Tile, @Tile.Cdf.CompBwdRefCdf[CompBwdrefContext(Tile), 0]) then
    begin
      if ReadBit(Tile, @Tile.Cdf.CompBwdRefCdf[CompBwdrefP1Context(Tile), 1]) then
        Tile.RefFrame[1] := ALTREF2_FRAME
      else
        Tile.RefFrame[1] := BWDREF_FRAME;
    end
    else
      Tile.RefFrame[1] := ALTREF_FRAME;
  end;
end;

procedure ReadSingleRef(Tile: TTileContext);
begin
  if ReadBit(Tile, @Tile.Cdf.SingleRefCdf[SingleRefP1Context(Tile), 0]) then
  begin
    if not ReadBit(Tile, @Tile.Cdf.SingleRefCdf[CompBwdrefContext(Tile), 1]) then
    begin
      if ReadBit(Tile, @Tile.Cdf.SingleRefCdf[CompBwdrefP1Context(Tile), 5]) then
        Tile.RefFrame[0] := ALTREF2_FRAME
      else
        Tile.RefFrame[0] := BWDREF_FRAME;
    end
    else
      Tile.RefFrame[0] := ALTREF_FRAME;
  end
  else
  begin
    if ReadBit(Tile, @Tile.Cdf.SingleRefCdf[CompRefContext(Tile), 2]) then
    begin
      if ReadBit(Tile, @Tile.Cdf.SingleRefCdf[CompRefP2Context(Tile), 4]) then
        Tile.RefFrame[0] := GOLDEN_FRAME
      else
        Tile.RefFrame[0] := LAST3_FRAME;
    end
    else
    begin
      if ReadBit(Tile, @Tile.Cdf.SingleRefCdf[CompRefP1Context(Tile), 3]) then
        Tile.RefFrame[0] := LAST2_FRAME
      else
        Tile.RefFrame[0] := LAST_FRAME;
    end;
  end;
  Tile.RefFrame[1] := NONE;
end;

procedure ReadRefFrames(Tile: TTileContext);
var
  Bw4, Bh4, CompMode: Integer;
begin
  if Tile.skip_mode then
  begin
    Tile.RefFrame[0] := Tile.Header^.SkipModeFrame[0];
    Tile.RefFrame[1] := Tile.Header^.SkipModeFrame[1];
  end
  else if Tile.SegmentFeatureActive(SEG_LVL_REF_FRAME) then
  begin
    Tile.RefFrame[0] := Tile.Header^.Segmentation.FeatureData[Tile.segment_id, SEG_LVL_REF_FRAME];
    Tile.RefFrame[1] := NONE;
  end
  else if Tile.SegmentFeatureActive(SEG_LVL_SKIP) or Tile.SegmentFeatureActive(SEG_LVL_GLOBALMV) then
  begin
    Tile.RefFrame[0] := LAST_FRAME;
    Tile.RefFrame[1] := NONE;
  end
  else
  begin
    Bw4 := Num_4x4_Blocks_Wide[Tile.MiSize];
    Bh4 := Num_4x4_Blocks_High[Tile.MiSize];
    if Tile.Header^.reference_select and (Min(Bw4, Bh4) >= 2) then
      CompMode := ReadSymbol(Tile.Symbols, @Tile.Cdf.CompModeCdf[CompModeContext(Tile)], 2)
    else
      CompMode := SINGLE_REFERENCE;
    if CompMode = COMPOUND_REFERENCE then
      ReadCompoundRefs(Tile)
    else
      ReadSingleRef(Tile);
  end;
end;

end.
