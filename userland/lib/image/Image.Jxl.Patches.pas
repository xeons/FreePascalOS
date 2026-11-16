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
  JPEG XL's patches (ISO/IEC 18181-1 annex K.3): rectangles copied
  from a reference frame (saved before its colour transform, often a
  frame of text-like shapes kept only for this) to positions in the
  frame, each blended with modes of its own. The dictionary is entropy
  coded in ten contexts in the LF global section; patches are applied
  in the order they were listed, before the colour transform.
}
unit Image.Jxl.Patches;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.BitReader,
  Image.Jxl.Headers,
  Image.Jxl.Planes,
  Image.Jxl.Blending;

type
  TJxlPatch = record
    Reference: LongInt;
    SourceX: LongInt;
    SourceY: LongInt;
    Width: LongInt;
    Height: LongInt;
    X: LongInt;
    Y: LongInt;
    { Colour first, then one per extra channel. }
    Blendings: TJxlPatchBlendings;
  end;

  TJxlPatches = array of TJxlPatch;

  { The size of each reference frame (0 x 0 when the slot is empty). }
  TJxlReferenceSizes = array[0..3] of record
    Width: LongInt;
    Height: LongInt;
  end;

{ Reads the patch dictionary of a frame Width x Height. }
function ReadJxlPatches(Reader: TJxlBitReader; Width, Height: LongInt; ExtraChannelCount: LongInt;
  const ReferenceSizes: TJxlReferenceSizes): TJxlPatches;
{ Applies the patches to Planes (3 colour planes and the extra channels,
  at the frame's size) from the reference frames' planes. }
procedure ApplyJxlPatches(const Patches: TJxlPatches; const Planes: TJxlPlaneSet;
  const References: array of TJxlPlaneSet; const ExtraChannels: array of TJxlExtraChannelInfo);

implementation

uses
  Image.Jxl.Entropy;

const
  ReferenceCountContext = 0;
  ReferenceFrameContext = 1;
  PatchSizeContext = 2;
  ReferencePositionContext = 3;
  PatchPositionContext = 4;
  BlendModeContext = 5;
  PatchOffsetContext = 6;
  PatchCountContext = 7;
  AlphaChannelContext = 8;
  ClampContext = 9;
  PatchContextCount = 10;

procedure RaiseBadPatches(const Detail: string);
begin
  RaiseImageError(ImageErrorMalformed, 'JPEG XL patches: ' + Detail);
end;

function UsesAlpha(Mode: LongWord): Boolean;
begin
  Result := Mode in [JxlPatchBlendAbove, JxlPatchBlendBelow, JxlPatchBlendAlphaWeightedAddAbove,
    JxlPatchBlendAlphaWeightedAddBelow];
end;

function ReadJxlPatches(Reader: TJxlBitReader; Width, Height: LongInt; ExtraChannelCount: LongInt;
  const ReferenceSizes: TJxlReferenceSizes): TJxlPatches;
var
  Code: TJxlEntropyCode;
  Symbols: TJxlSymbolReader;
  ReferenceCount: QWord;
  MaximumReferences: QWord;
  MaximumPatches: QWord;
  TotalPatches: QWord;
  Reference: LongWord;
  SourceX: QWord;
  SourceY: QWord;
  PatchWidth: QWord;
  PatchHeight: QWord;
  Count: QWord;
  Index: QWord;
  ReferenceIndex: QWord;
  Patch: TJxlPatch;
  Delta: Int64;
  PreviousX: Int64;
  PreviousY: Int64;
  Channel: LongInt;
  Blending: TJxlPatchBlending;
  PatchCount: LongInt;
begin
  Result := nil;
  PatchCount := 0;
  Code := ReadJxlEntropyCode(Reader, PatchContextCount);
  try
    Symbols := TJxlSymbolReader.Create(Code, Reader);
    try
      ReferenceCount := Symbols.ReadUint(ReferenceCountContext);
      MaximumReferences := 1024 + QWord(Width) * QWord(Height) div 4;
      MaximumPatches := MaximumReferences * 4;
      if ReferenceCount > MaximumReferences then
        RaiseBadPatches('too many');
      TotalPatches := 0;
      PreviousX := 0;
      PreviousY := 0;
      ReferenceIndex := 0;
      while ReferenceIndex < ReferenceCount do
      begin
        Reference := Symbols.ReadUint(ReferenceFrameContext);
        if (Reference > 3) or (ReferenceSizes[Reference].Width = 0) then
          RaiseBadPatches('bad reference frame');
        SourceX := Symbols.ReadUint(ReferencePositionContext);
        SourceY := Symbols.ReadUint(ReferencePositionContext);
        PatchWidth := QWord(Symbols.ReadUint(PatchSizeContext)) + 1;
        PatchHeight := QWord(Symbols.ReadUint(PatchSizeContext)) + 1;
        if (SourceX + PatchWidth > QWord(ReferenceSizes[Reference].Width)) or
          (SourceY + PatchHeight > QWord(ReferenceSizes[Reference].Height)) then
          RaiseBadPatches('outside the reference frame');
        Count := Symbols.ReadUint(PatchCountContext);
        if Count > MaximumPatches then
          RaiseBadPatches('too many');
        Inc(Count);
        Inc(TotalPatches, Count);
        if TotalPatches > MaximumPatches then
          RaiseBadPatches('too many');
        Index := 0;
        while Index < Count do
        begin
          Patch := Default(TJxlPatch);
          Patch.Reference := Reference;
          Patch.SourceX := SourceX;
          Patch.SourceY := SourceY;
          Patch.Width := PatchWidth;
          Patch.Height := PatchHeight;
          if Index = 0 then
          begin
            PreviousX := Symbols.ReadUint(PatchPositionContext);
            PreviousY := Symbols.ReadUint(PatchPositionContext);
          end
          else
          begin
            Delta := JxlUnpackSigned(Symbols.ReadUint(PatchOffsetContext));
            if PreviousX + Delta < 0 then
              RaiseBadPatches('negative position');
            Inc(PreviousX, Delta);
            Delta := JxlUnpackSigned(Symbols.ReadUint(PatchOffsetContext));
            if PreviousY + Delta < 0 then
              RaiseBadPatches('negative position');
            Inc(PreviousY, Delta);
          end;
          if (PreviousX + Int64(PatchWidth) > Width) or (PreviousY + Int64(PatchHeight) > Height) then
            RaiseBadPatches('outside the frame');
          Patch.X := PreviousX;
          Patch.Y := PreviousY;
          SetLength(Patch.Blendings, ExtraChannelCount + 1);
          for Channel := 0 to ExtraChannelCount do
          begin
            Blending := Default(TJxlPatchBlending);
            Blending.Mode := Symbols.ReadUint(BlendModeContext);
            if Blending.Mode >= JxlPatchBlendModeCount then
              RaiseBadPatches('bad blend mode');
            if UsesAlpha(Blending.Mode) and (ExtraChannelCount > 1) then
            begin
              Blending.AlphaChannel := Symbols.ReadUint(AlphaChannelContext);
              if Blending.AlphaChannel >= LongWord(ExtraChannelCount) then
                RaiseBadPatches('bad alpha channel');
            end;
            if UsesAlpha(Blending.Mode) or (Blending.Mode = JxlPatchBlendMultiply) then
              Blending.Clamp := Symbols.ReadUint(ClampContext) <> 0;
            Patch.Blendings[Channel] := Blending;
          end;
          if PatchCount >= Length(Result) then
            SetLength(Result, PatchCount * 2 + 8);
          Result[PatchCount] := Patch;
          Inc(PatchCount);
          Inc(Index);
        end;
        Inc(ReferenceIndex);
      end;
      Symbols.CheckFinalState;
    finally
      Symbols.Free;
    end;
  finally
    Code.Free;
  end;
  SetLength(Result, PatchCount);
end;

procedure ApplyJxlPatches(const Patches: TJxlPatches; const Planes: TJxlPlaneSet;
  const References: array of TJxlPlaneSet; const ExtraChannels: array of TJxlExtraChannelInfo);
var
  PatchIndex: LongInt;
  Row: LongInt;
  Channel: LongInt;
  Output: TJxlRowPointers;
  Source: TJxlRowPointers;
  Reference: TJxlPlaneSet;
  ExtraBlendings: TJxlPatchBlendings;
  ChannelCount: LongInt;
  VisibleWidth: LongInt;
begin
  ChannelCount := Length(Planes);
  SetLength(Output, ChannelCount);
  SetLength(Source, ChannelCount);
  for PatchIndex := 0 to High(Patches) do
  begin
    Reference := References[Patches[PatchIndex].Reference];
    if Length(Reference) < ChannelCount then
      RaiseBadPatches('reference frame without every channel');
    ExtraBlendings := Copy(Patches[PatchIndex].Blendings, 1, ChannelCount - 3);
    { Positions may reach into the padding of a VarDCT frame. }
    VisibleWidth := Patches[PatchIndex].Width;
    if Patches[PatchIndex].X + VisibleWidth > Planes[0].Width then
      VisibleWidth := Planes[0].Width - Patches[PatchIndex].X;
    if VisibleWidth <= 0 then
      Continue;
    for Row := 0 to Patches[PatchIndex].Height - 1 do
    begin
      if Patches[PatchIndex].Y + Row >= Planes[0].Height then
        Break;
      for Channel := 0 to ChannelCount - 1 do
      begin
        Output[Channel] := Planes[Channel].Row(Patches[PatchIndex].Y + Row) + Patches[PatchIndex].X;
        Source[Channel] := Reference[Channel].Row(Patches[PatchIndex].SourceY + Row) + Patches[PatchIndex].SourceX;
      end;
      JxlPerformBlending(Output, Source, Output, VisibleWidth, Patches[PatchIndex].Blendings[0],
        ExtraBlendings, ExtraChannels);
    end;
  end;
end;

end.
