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
  Decoding one JPEG XL frame (ISO/IEC 18181-1 annex C and K): its
  header and table of contents, then the sections: LF global (patches,
  noise, the LF dequantization, the VarDCT globals, the global modular
  stream), each LF group (VarDCT LF coefficients, modular channels
  shifted three times or more, VarDCT AC metadata), HF global (VarDCT
  dequantization matrices, coefficient orders and histograms) and each
  pass of each group (VarDCT AC coefficients, the rest of the modular
  channels).

  The frame is then rendered as libjxl's render pipeline does it:
  gaborish smoothing, the edge preserving filter, extra channel
  upsampling, patches, upsampling, noise; an LF frame stops there (its
  planes are another frame's low frequencies). A frame that is saved
  for later frames before its colour transform keeps a copy here; then
  the colour transform (XYB to sRGB, YCbCr to RGB). Blending onto the
  canvas is the caller's (Image.Jxl.Decoder).

  Splines are not supported (libjxl's encoder does not make them);
  noise is synthesized as far as Image.Jxl.Noise does.
}
unit Image.Jxl.FrameDecoder;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.Jxl.BitReader,
  Image.Jxl.Headers,
  Image.Jxl.FrameHeader,
  Image.Jxl.Planes,
  Image.Jxl.Patches;

type
  { What earlier frames left for later ones. }
  TJxlDecodingContext = record
    { The four reference slots: all channels, and whether the slot was
      saved before the colour transform. }
    References: array[0..3] of TJxlPlaneSet;
    ReferenceSizes: TJxlReferenceSizes;
    ReferenceBeforeColorTransform: array[0..3] of Boolean;
    { LF frames by level - 1: three planes. }
    LowFrequencyFrames: array[0..3] of TJxlPlaneSet;
  end;

  TJxlDecodedFrame = record
    Header: TJxlFrameHeader;
    { Three colour planes and the extra channels, the frame's
      (upsampled) size; colour transformed unless it is an LF frame. }
    Planes: TJxlPlaneSet;
    { The planes before the colour transform, when the frame is saved
      for referencing before it (else nil). }
    SavedPlanes: TJxlPlaneSet;
  end;

{ Decodes the frame at byte Position of Codestream and moves Position
  past it. }
function DecodeJxlFrame(const Codestream: TBytes; var Position: PtrInt; const Headers: TJxlImageHeaders;
  const Context: TJxlDecodingContext; IsPreview: Boolean = False): TJxlDecodedFrame;
{ Moves Position past the frame there without decoding it. }
procedure SkipJxlFrame(const Codestream: TBytes; var Position: PtrInt; const Headers: TJxlImageHeaders;
  IsPreview: Boolean);
procedure FreeJxlDecodedFrame(var Frame: TJxlDecodedFrame);

implementation

uses
  Image.Jxl.ModularFrame,
  Image.Jxl.VarDct,
  Image.Jxl.Gaborish,
  Image.Jxl.EdgePreserving,
  Image.Jxl.Noise,
  Image.Jxl.Xyb,
  Image.Jxl.Upsampling;

type
  { Hands out the bit reader of each section. }
  TSectionReaders = class
  private
    FCodestream: TBytes;
    FStart: PtrInt;
    FTable: TJxlTableOfContents;
    FSingle: TJxlBitReader;
    FCurrent: TJxlBitReader;
  public
    constructor Create(const Codestream: TBytes; Start: PtrInt; const Table: TJxlTableOfContents);
    destructor Destroy; override;
    function Section(Index: LongInt): TJxlBitReader;
  end;

constructor TSectionReaders.Create(const Codestream: TBytes; Start: PtrInt; const Table: TJxlTableOfContents);
begin
  inherited Create;
  FCodestream := Codestream;
  FStart := Start;
  FTable := Table;
  if Length(Table.Sizes) = 1 then
    FSingle := TJxlBitReader.Create(Codestream, Start, Table.Sizes[0]);
end;

destructor TSectionReaders.Destroy;
begin
  FSingle.Free;
  FCurrent.Free;
  inherited Destroy;
end;

function TSectionReaders.Section(Index: LongInt): TJxlBitReader;
begin
  if FSingle <> nil then
    Exit(FSingle);
  FreeAndNil(FCurrent);
  FCurrent := TJxlBitReader.Create(FCodestream, FStart + PtrInt(FTable.Offsets[Index]), FTable.Sizes[Index]);
  Result := FCurrent;
end;

procedure FreeJxlDecodedFrame(var Frame: TJxlDecodedFrame);
begin
  FreeJxlPlanes(Frame.Planes);
  FreeJxlPlanes(Frame.SavedPlanes);
end;

function ClonePlanes(const Planes: TJxlPlaneSet): TJxlPlaneSet;
var
  Index: LongInt;
begin
  SetLength(Result, Length(Planes));
  for Index := 0 to High(Planes) do
    Result[Index] := Planes[Index].Clone;
end;

{ Reads the header and table of contents; Position ends at the first
  section. }
procedure ReadHeaderAndTable(const Codestream: TBytes; var Position: PtrInt; const Headers: TJxlImageHeaders;
  IsPreview: Boolean; out Header: TJxlFrameHeader; out Table: TJxlTableOfContents);
var
  Reader: TJxlBitReader;
begin
  Reader := TJxlBitReader.Create(Codestream, Position, -1);
  try
    Header := ReadJxlFrameHeader(Reader, Headers, IsPreview);
    Table := ReadJxlTableOfContents(Reader, JxlSectionCount(Header));
    Position := Reader.BytePosition;
  finally
    Reader.Free;
  end;
  if Table.TotalSize > QWord(Length(Codestream) - Position) then
    RaiseImageError(ImageErrorTruncated, 'JPEG XL frame');
end;

procedure SkipJxlFrame(const Codestream: TBytes; var Position: PtrInt; const Headers: TJxlImageHeaders;
  IsPreview: Boolean);
var
  Header: TJxlFrameHeader;
  Table: TJxlTableOfContents;
begin
  ReadHeaderAndTable(Codestream, Position, Headers, IsPreview, Header, Table);
  Inc(Position, PtrInt(Table.TotalSize));
end;

procedure UpsamplePlane(var Plane: TJxlPlane; Factor: LongInt; const Headers: TJxlImageHeaders;
  Width, Height: LongInt);
var
  Enlarged: TJxlPlane;
begin
  if Factor <= 1 then
    Exit;
  Enlarged := UpsampleJxlPlane(Plane, Factor, Headers.Transform, Width, Height);
  Plane.Free;
  Plane := Enlarged;
end;

procedure RenderFrame(const Headers: TJxlImageHeaders; const Context: TJxlDecodingContext;
  var Frame: TJxlDecodedFrame; const Patches: TJxlPatches; const Noise: TJxlNoiseParameters;
  const Sigma: TJxlEpfSigma);
var
  Header: TJxlFrameHeader;
  ExtraCount: LongInt;
  ExtraIndex: LongInt;
  LateExtraUpsampling: Boolean;
  Channel: LongInt;
  ColorPlanes: TJxlPlaneSet;
  Width: LongInt;
  Height: LongInt;
begin
  Header := Frame.Header;
  ExtraCount := Length(Headers.Metadata.ExtraChannels);
  Width := Header.Dimensions.UpsampledWidth;
  Height := Header.Dimensions.UpsampledHeight;
  ColorPlanes := Copy(Frame.Planes, 0, 3);
  if Header.LoopFilter.Gaborish then
    ApplyJxlGaborish(ColorPlanes, Header.LoopFilter);
  if Header.LoopFilter.EpfIterations > 0 then
    ApplyJxlEdgePreservingFilter(ColorPlanes, Header.LoopFilter, Sigma);
  LateExtraUpsampling := Header.Upsampling <> 1;
  for ExtraIndex := 0 to ExtraCount - 1 do
    if Header.ExtraChannelUpsampling[ExtraIndex] <> Header.Upsampling then
      LateExtraUpsampling := False;
  if not LateExtraUpsampling then
    for ExtraIndex := 0 to ExtraCount - 1 do
      UpsamplePlane(Frame.Planes[3 + ExtraIndex], Header.ExtraChannelUpsampling[ExtraIndex], Headers, Width, Height);
  if (Header.Flags and JxlFlagPatches) <> 0 then
  begin
    for Channel := 1 to High(Frame.Planes) do
      if (Frame.Planes[Channel].Width <> Frame.Planes[0].Width) or
        (Frame.Planes[Channel].Height <> Frame.Planes[0].Height) then
        RaiseImageError(ImageErrorUnsupported, 'JPEG XL: patches with upsampling');
    ApplyJxlPatches(Patches, Frame.Planes, Context.References, Headers.Metadata.ExtraChannels);
  end;
  if Header.Upsampling <> 1 then
  begin
    for Channel := 0 to 2 do
      UpsamplePlane(Frame.Planes[Channel], Header.Upsampling, Headers, Width, Height);
    if LateExtraUpsampling then
      for ExtraIndex := 0 to ExtraCount - 1 do
        UpsamplePlane(Frame.Planes[3 + ExtraIndex], Header.Upsampling, Headers, Width, Height);
  end;
  if (Header.Flags and JxlFlagNoise) <> 0 then
    ApplyJxlNoise(Copy(Frame.Planes, 0, 3), Noise, Header);
  if Header.FrameType = JxlFrameLowFrequency then
    Exit;
  if JxlFrameCanBeReferenced(Header) and Header.SaveBeforeColorTransform then
    Frame.SavedPlanes := ClonePlanes(Frame.Planes);
  case Header.ColorTransform of
    JxlColorTransformXyb:
      ConvertJxlXybToSrgb(Copy(Frame.Planes, 0, 3), Headers.Transform, Headers.Metadata.ToneMapping.IntensityTarget);
    JxlColorTransformYCbCr:
      ConvertJxlYCbCrToRgb(Copy(Frame.Planes, 0, 3));
  end;
end;

function DecodeJxlFrame(const Codestream: TBytes; var Position: PtrInt; const Headers: TJxlImageHeaders;
  const Context: TJxlDecodingContext; IsPreview: Boolean): TJxlDecodedFrame;
var
  Header: TJxlFrameHeader;
  Table: TJxlTableOfContents;
  Sections: TSectionReaders;
  Reader: TJxlBitReader;
  Patches: TJxlPatches;
  Noise: TJxlNoiseParameters;
  Dequantization: TJxlLowFrequencyDequantization;
  Modular: TJxlModularFrame;
  VarDct: TJxlVarDctFrame;
  Sigma: TJxlEpfSigma;
  Dimensions: TJxlFrameDimensions;
  Group: LongInt;
  Pass: LongInt;
  ExtraIndex: LongInt;
  ExtraCount: LongInt;
  ColorPlanes: TJxlPlaneSet;
  SectionsStart: PtrInt;
begin
  Result := Default(TJxlDecodedFrame);
  ReadHeaderAndTable(Codestream, Position, Headers, IsPreview, Header, Table);
  SectionsStart := Position;
  Inc(Position, PtrInt(Table.TotalSize));
  Result.Header := Header;
  Dimensions := Header.Dimensions;
  ExtraCount := Length(Headers.Metadata.ExtraChannels);
  if not ImageSizeAllowed(Dimensions.UpsampledWidth, Dimensions.UpsampledHeight) then
    RaiseImageError(ImageErrorTooLarge, 'JPEG XL frame');
  Patches := nil;
  Noise := Default(TJxlNoiseParameters);
  Sigma := Default(TJxlEpfSigma);
  Modular := nil;
  VarDct := nil;
  Sections := TSectionReaders.Create(Codestream, SectionsStart, Table);
  try
    try
      Reader := Sections.Section(0);
      if (Header.Flags and JxlFlagPatches) <> 0 then
        Patches := ReadJxlPatches(Reader, Dimensions.PaddedWidth, Dimensions.PaddedHeight, ExtraCount,
          Context.ReferenceSizes);
      if (Header.Flags and JxlFlagSplines) <> 0 then
        RaiseImageError(ImageErrorUnsupported, 'JPEG XL: splines');
      if (Header.Flags and JxlFlagNoise) <> 0 then
        Noise := ReadJxlNoiseParameters(Reader);
      Dequantization := ReadJxlLowFrequencyDequantization(Reader);
      if Header.Encoding = JxlEncodingVarDct then
      begin
        VarDct := TJxlVarDctFrame.Create(Headers, Header, Dequantization);
        VarDct.ReadGlobal(Reader);
      end;
      Modular := TJxlModularFrame.Create(Headers, Header);
      Modular.ReadGlobal(Reader);
      if VarDct <> nil then
      begin
        VarDct.GlobalTree := Modular.GlobalTree;
        if (Header.Flags and JxlFlagUseLowFrequencyFrame) <> 0 then
        begin
          if (Header.LowFrequencyLevel > 3) or
            (Length(Context.LowFrequencyFrames[Header.LowFrequencyLevel]) < 3) then
            RaiseImageError(ImageErrorMalformed, 'JPEG XL: LF frame missing');
          VarDct.SetLowFrequencyFrame(Context.LowFrequencyFrames[Header.LowFrequencyLevel]);
        end;
      end;
      for Group := 0 to Dimensions.LowFrequencyGroupCount - 1 do
      begin
        Reader := Sections.Section(JxlLowFrequencyGroupSection(Group));
        if VarDct <> nil then
          VarDct.ReadLowFrequencyGroup(Reader, Group);
        Modular.ReadLowFrequencyGroup(Reader, Group);
        if VarDct <> nil then
          VarDct.ReadAcMetadata(Reader, Group);
      end;
      Reader := Sections.Section(JxlHighFrequencyGlobalSection(Dimensions));
      if VarDct <> nil then
        VarDct.ReadHighFrequencyGlobal(Reader);
      for Pass := 0 to LongInt(Header.Passes.Count) - 1 do
        for Group := 0 to Dimensions.GroupCount - 1 do
        begin
          Reader := Sections.Section(JxlPassGroupSection(Dimensions, Pass, Group));
          if VarDct <> nil then
            VarDct.ReadPassGroup(Reader, Pass, Group);
          Modular.ReadPassGroup(Reader, Pass, Group);
        end;
      Modular.Finish;
      if VarDct <> nil then
        VarDct.Render(ColorPlanes, Sigma)
      else
      begin
        if (Header.ColorTransform = JxlColorTransformYCbCr) and
          ((JxlChromaHorizontalShift(Header, 0) <> 0) or (JxlChromaVerticalShift(Header, 0) <> 0) or
          (JxlChromaHorizontalShift(Header, 2) <> 0) or (JxlChromaVerticalShift(Header, 2) <> 0)) then
          RaiseImageError(ImageErrorUnsupported, 'JPEG XL: subsampled modular YCbCr');
        ColorPlanes := Modular.ColorPlanes(Dequantization);
        if Header.LoopFilter.EpfIterations > 0 then
          Sigma := JxlConstantEpfSigma(ColorPlanes[0].Width, ColorPlanes[0].Height,
            JxlInverseSigmaNumerator / Header.LoopFilter.EpfSigmaForModular);
      end;
      SetLength(Result.Planes, 3 + ExtraCount);
      Result.Planes[0] := ColorPlanes[0];
      Result.Planes[1] := ColorPlanes[1];
      Result.Planes[2] := ColorPlanes[2];
      for ExtraIndex := 0 to ExtraCount - 1 do
        Result.Planes[3 + ExtraIndex] := Modular.ExtraChannelPlane(ExtraIndex);
      FreeAndNil(Modular);
      FreeAndNil(VarDct);
      RenderFrame(Headers, Context, Result, Patches, Noise, Sigma);
    except
      FreeJxlDecodedFrame(Result);
      raise;
    end;
  finally
    Modular.Free;
    VarDct.Free;
    Sections.Free;
  end;
end;

end.
