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
  libav1 as libmedia's AV1 video decoder: TAv1VideoDecoder, registered
  for codecAv1 (Media.VideoDecoders) when a program uses this unit.

  Configure takes the track's av1C box (version, profile and level
  bytes, then the configuration OBUs: the sequence header), SendPacket a
  temporal unit (a Matroska block, an MP4 sample, an IVF frame); frames
  come out with the packet's presentation time. The decoder uses one
  worker per processor, up to eight, for tiles and post filters.
}
unit Av1.MediaDecoder;

{$mode objfpc}
{$H+}

interface

uses
  Classes, SysUtils, {$ifdef FREEPASCALOS}Sys.Information,{$endif} Media.Frames, Media.Packets, Media.Errors,
  Media.VideoDecoders, Av1.Common, Av1.Decoder;

type
  TAv1VideoDecoder = class(TVideoDecoder)
  private
    FDecoder: TAv1Decoder;
    FConfiguration: TBytes;
    procedure DecodeConfiguration;
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure Configure(Track: TMediaTrack); override;
    procedure SendPacket(const Packet: TMediaPacket); override;
    function ReceiveFrame(out Frame: TVideoFrame): Boolean; override;
    procedure Reset; override;
  end;

implementation

function DecoderThreads: Integer;
{$ifdef FREEPASCALOS}
var
  Information: TSystemInformation;
{$endif}
begin
{$ifdef FREEPASCALOS}
  GetSystemInformation(Information);
  Result := Information.ProcessorCount;
{$else}
  Result := TThread.ProcessorCount;
{$endif}
  if Result < 1 then
    Result := 1
  else if Result > 8 then
    Result := 8;
end;

constructor TAv1VideoDecoder.Create;
begin
  inherited Create;
  FDecoder := TAv1Decoder.Create(DecoderThreads);
end;

destructor TAv1VideoDecoder.Destroy;
begin
  FDecoder.Free;
  inherited Destroy;
end;

procedure TAv1VideoDecoder.DecodeConfiguration;
begin
  { av1C: marker and version, profile and level, depth and subsampling,
    the initial presentation delay; the configuration OBUs follow. }
  if Length(FConfiguration) > 4 then
    try
      FDecoder.Decode(@FConfiguration[4], Length(FConfiguration) - 4);
    except
      on Error: EAv1Error do
        raise EMediaError.Create(Error.Message);
    end;
end;

procedure TAv1VideoDecoder.Configure(Track: TMediaTrack);
begin
  FConfiguration := nil;
  if Length(Track.Headers) > 0 then
    FConfiguration := Copy(Track.Headers[0]);
  DecodeConfiguration;
end;

procedure TAv1VideoDecoder.SendPacket(const Packet: TMediaPacket);
begin
  if Length(Packet.Data) = 0 then
    Exit;
  try
    FDecoder.Decode(@Packet.Data[0], Length(Packet.Data), Packet.PresentationTime);
  except
    on Error: EAv1Error do
      raise EMediaError.Create(Error.Message);
  end;
end;

function TAv1VideoDecoder.ReceiveFrame(out Frame: TVideoFrame): Boolean;
begin
  Result := FDecoder.TakeFrame(Frame);
end;

procedure TAv1VideoDecoder.Reset;
begin
  FDecoder.Reset;
  DecodeConfiguration;
end;

initialization
  RegisterVideoDecoder(codecAv1, TAv1VideoDecoder);
end.
