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
  The three Vorbis header packets (specification section 4.2): the
  identification header (channels, rate, the two block sizes), the
  comment header (only checked: the tags are the container's business)
  and the setup header, with the codebooks, floors, residues, mappings
  and modes every audio packet refers to.
}
unit Media.Vorbis.Headers;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Vorbis.BitReader,
  Media.Vorbis.Codebooks,
  Media.Vorbis.Floors,
  Media.Vorbis.Residues;

type
  TVorbisMapping = record
    Submaps: Integer;
    CouplingSteps: Integer;
    Magnitudes, Angles: array of Integer;
    { Per channel: its submap. }
    Mux: array of Integer;
    SubmapFloors, SubmapResidues: array of Integer;
  end;

  TVorbisMode = record
    LongBlock: Boolean;
    Mapping: Integer;
  end;

  TVorbisSetup = class
  public
    Channels: Integer;
    SampleRate: Integer;
    BlockSizes: array[0..1] of Integer;
    Codebooks: TVorbisCodebookList;
    Floors: array of TVorbisFloor;
    Residues: array of TVorbisResidue;
    Mappings: array of TVorbisMapping;
    Modes: array of TVorbisMode;
    destructor Destroy; override;
    { Each raises EMediaError for a packet that is not that header. }
    procedure ReadIdentification(const Packet: TBytes);
    procedure ReadComment(const Packet: TBytes);
    procedure ReadSetup(const Packet: TBytes);
  end;

{ Whether Packet starts with the header type byte and "vorbis". }
function IsVorbisHeader(const Packet: TBytes; HeaderType: Byte): Boolean;

implementation

uses
  Media.Errors;

function IsVorbisHeader(const Packet: TBytes; HeaderType: Byte): Boolean;
begin
  Result := (Length(Packet) >= 7) and (Packet[0] = HeaderType) and (Packet[1] = Ord('v')) and
    (Packet[2] = Ord('o')) and (Packet[3] = Ord('r')) and (Packet[4] = Ord('b')) and (Packet[5] = Ord('i')) and
    (Packet[6] = Ord('s'));
end;

destructor TVorbisSetup.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(Codebooks) do
    Codebooks[Index].Free;
  for Index := 0 to High(Floors) do
    Floors[Index].Free;
  for Index := 0 to High(Residues) do
    Residues[Index].Free;
  inherited Destroy;
end;

procedure TVorbisSetup.ReadIdentification(const Packet: TBytes);
var
  Reader: TVorbisBitReader;
  Exponent: Integer;
begin
  if not IsVorbisHeader(Packet, 1) or (Length(Packet) < 30) then
    MediaFail('not a Vorbis identification header');
  StartBitReader(Reader, @Packet[7], Length(Packet) - 7);
  if ReadBits(Reader, 32) <> 0 then
    MediaFailUnsupported('Vorbis version other than 0');
  Channels := ReadBits(Reader, 8);
  SampleRate := ReadBits(Reader, 32);
  ReadBits(Reader, 32);
  ReadBits(Reader, 32);
  ReadBits(Reader, 32);
  Exponent := ReadBits(Reader, 4);
  BlockSizes[0] := 1 shl Exponent;
  Exponent := ReadBits(Reader, 4);
  BlockSizes[1] := 1 shl Exponent;
  if not ReadBit(Reader) then
    MediaFail('Vorbis identification header framing bit missing');
  if (Channels = 0) or (SampleRate <= 0) then
    MediaFail('Vorbis stream without channels or rate');
  if (BlockSizes[0] < 64) or (BlockSizes[1] > 8192) or (BlockSizes[0] > BlockSizes[1]) then
    MediaFail('bad Vorbis block sizes');
end;

procedure TVorbisSetup.ReadComment(const Packet: TBytes);
begin
  if not IsVorbisHeader(Packet, 3) then
    MediaFail('not a Vorbis comment header');
end;

procedure ReadMapping(var Reader: TVorbisBitReader; Setup: TVorbisSetup; var Mapping: TVorbisMapping);
var
  Step, Channel, Submap, ChannelBits: Integer;
begin
  if ReadBits(Reader, 16) <> 0 then
    MediaFail('unknown Vorbis mapping type');
  if ReadBit(Reader) then
    Mapping.Submaps := ReadBits(Reader, 4) + 1
  else
    Mapping.Submaps := 1;
  Mapping.CouplingSteps := 0;
  ChannelBits := VorbisIntegerLog(Setup.Channels - 1);
  if ReadBit(Reader) then
  begin
    Mapping.CouplingSteps := ReadBits(Reader, 8) + 1;
    SetLength(Mapping.Magnitudes, Mapping.CouplingSteps);
    SetLength(Mapping.Angles, Mapping.CouplingSteps);
    for Step := 0 to Mapping.CouplingSteps - 1 do
    begin
      Mapping.Magnitudes[Step] := ReadBits(Reader, ChannelBits);
      Mapping.Angles[Step] := ReadBits(Reader, ChannelBits);
      if (Mapping.Magnitudes[Step] = Mapping.Angles[Step]) or (Mapping.Magnitudes[Step] >= Setup.Channels) or
        (Mapping.Angles[Step] >= Setup.Channels) then
        MediaFail('bad Vorbis channel coupling');
    end;
  end;
  if ReadBits(Reader, 2) <> 0 then
    MediaFail('Vorbis mapping reserved field set');
  SetLength(Mapping.Mux, Setup.Channels);
  for Channel := 0 to Setup.Channels - 1 do
    if Mapping.Submaps > 1 then
    begin
      Mapping.Mux[Channel] := ReadBits(Reader, 4);
      if Mapping.Mux[Channel] >= Mapping.Submaps then
        MediaFail('Vorbis mapping names a missing submap');
    end
    else
      Mapping.Mux[Channel] := 0;
  SetLength(Mapping.SubmapFloors, Mapping.Submaps);
  SetLength(Mapping.SubmapResidues, Mapping.Submaps);
  for Submap := 0 to Mapping.Submaps - 1 do
  begin
    ReadBits(Reader, 8);
    Mapping.SubmapFloors[Submap] := ReadBits(Reader, 8);
    Mapping.SubmapResidues[Submap] := ReadBits(Reader, 8);
    if (Mapping.SubmapFloors[Submap] >= Length(Setup.Floors)) or
      (Mapping.SubmapResidues[Submap] >= Length(Setup.Residues)) then
      MediaFail('Vorbis mapping names a missing floor or residue');
  end;
end;

procedure TVorbisSetup.ReadSetup(const Packet: TBytes);
var
  Reader: TVorbisBitReader;
  Count, Index, Kind: Integer;
begin
  if not IsVorbisHeader(Packet, 5) then
    MediaFail('not a Vorbis setup header');
  if Channels = 0 then
    MediaFail('Vorbis setup header before the identification header');
  StartBitReader(Reader, @Packet[7], Length(Packet) - 7);
  Count := ReadBits(Reader, 8) + 1;
  SetLength(Codebooks, Count);
  for Index := 0 to Count - 1 do
  begin
    Codebooks[Index] := TVorbisCodebook.Create;
    Codebooks[Index].ReadFrom(Reader);
  end;
  Count := ReadBits(Reader, 6) + 1;
  for Index := 0 to Count - 1 do
    if ReadBits(Reader, 16) <> 0 then
      MediaFail('Vorbis time domain transform other than 0');
  Count := ReadBits(Reader, 6) + 1;
  SetLength(Floors, Count);
  for Index := 0 to Count - 1 do
  begin
    Kind := ReadBits(Reader, 16);
    case Kind of
      0: Floors[Index] := TVorbisFloor0.Create;
      1: Floors[Index] := TVorbisFloor1.Create;
    else
      MediaFail('unknown Vorbis floor type');
    end;
    Floors[Index].ReadFrom(Reader, Codebooks);
  end;
  Count := ReadBits(Reader, 6) + 1;
  SetLength(Residues, Count);
  for Index := 0 to Count - 1 do
  begin
    Kind := ReadBits(Reader, 16);
    if Kind > 2 then
      MediaFail('unknown Vorbis residue type');
    Residues[Index] := TVorbisResidue.Create(Kind);
    Residues[Index].ReadFrom(Reader, Codebooks);
  end;
  Count := ReadBits(Reader, 6) + 1;
  SetLength(Mappings, Count);
  for Index := 0 to Count - 1 do
    ReadMapping(Reader, Self, Mappings[Index]);
  Count := ReadBits(Reader, 6) + 1;
  SetLength(Modes, Count);
  for Index := 0 to Count - 1 do
  begin
    Modes[Index].LongBlock := ReadBit(Reader);
    if (ReadBits(Reader, 16) <> 0) or (ReadBits(Reader, 16) <> 0) then
      MediaFail('Vorbis mode with a window or transform type other than 0');
    Modes[Index].Mapping := ReadBits(Reader, 8);
    if Modes[Index].Mapping >= Length(Mappings) then
      MediaFail('Vorbis mode names a missing mapping');
  end;
  if not ReadBit(Reader) or Reader.EndOfPacket then
    MediaFail('Vorbis setup header framing bit missing');
end;

end.
