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
  libvideo's decoders as libmedia video decoders (Media.VideoDecoders):
  VP8 and VP9 packets from any container go in, pictures come out with
  the packet's presentation time. Using this unit registers them (or
  call RegisterVideoCodecs); CreateVideoDecoder(codecVp8 / codecVp9)
  then makes them.

  Neither codec reorders frames, so a packet's picture comes out at once
  and Flush has nothing to give. A VP9 superframe (several frames in one
  packet) shows at most one picture, its last frame's, as the reference
  decoder does. Errors in a packet raise EMediaError.

  Decoders use DefaultVideoThreadCount threads (VideoThreadCount changes
  it for the decoders made afterwards).
}
unit Video.MediaDecoders;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils, Media.Frames, Media.Packets, Media.VideoDecoders;

type
  TVp8MediaDecoder = class(TVideoDecoder)
  private
    FDecoder: TObject;
    FFrame: TVideoFrame;
    FHasFrame: Boolean;
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure Configure(Track: TMediaTrack); override;
    procedure SendPacket(const Packet: TMediaPacket); override;
    function ReceiveFrame(out Frame: TVideoFrame): Boolean; override;
    procedure Reset; override;
  end;

  TVp9MediaDecoder = class(TVideoDecoder)
  private
    FDecoder: TObject;
    FFrame: TVideoFrame;
    FHasFrame: Boolean;
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure Configure(Track: TMediaTrack); override;
    procedure SendPacket(const Packet: TMediaPacket); override;
    function ReceiveFrame(out Frame: TVideoFrame): Boolean; override;
    procedure Reset; override;
  end;

var
  { Threads per decoder; 0 for one per processor (at most 8). }
  VideoThreadCount: LongInt = 0;

{ Registers the VP8 and VP9 decoders with libmedia (done when the unit
  is used). }
procedure RegisterVideoCodecs;

implementation

uses
  Media.Errors, Vp8.Decoder, Vp9.Decoder;

{ Decoding errors of every kind become libmedia's. }
procedure RaiseMediaError(E: Exception);
begin
  if E is EMediaError then
    raise EMediaError.Create(E.Message)
  else
    raise EMediaError.Create(E.ClassName + ': ' + E.Message);
end;

constructor TVp8MediaDecoder.Create;
begin
  inherited Create;
  FDecoder := TVp8Decoder.Create(VideoThreadCount);
end;

destructor TVp8MediaDecoder.Destroy;
begin
  FDecoder.Free;
  inherited Destroy;
end;

procedure TVp8MediaDecoder.Configure(Track: TMediaTrack);
begin
end;

procedure TVp8MediaDecoder.SendPacket(const Packet: TMediaPacket);
begin
  if Length(Packet.Data) = 0 then
    Exit;
  try
    FHasFrame := TVp8Decoder(FDecoder).DecodeFrame(@Packet.Data[0], Length(Packet.Data), FFrame);
  except
    on E: Exception do
    begin
      FHasFrame := False;
      RaiseMediaError(E);
    end;
  end;
  if FHasFrame then
    FFrame.PresentationTime := Packet.PresentationTime;
end;

function TVp8MediaDecoder.ReceiveFrame(out Frame: TVideoFrame): Boolean;
begin
  Frame := Default(TVideoFrame);
  Result := FHasFrame;
  if Result then
  begin
    Frame := FFrame;
    FFrame := Default(TVideoFrame);
    FHasFrame := False;
  end;
end;

procedure TVp8MediaDecoder.Reset;
begin
  FDecoder.Free;
  FDecoder := TVp8Decoder.Create(VideoThreadCount);
  FFrame := Default(TVideoFrame);
  FHasFrame := False;
end;

constructor TVp9MediaDecoder.Create;
begin
  inherited Create;
  FDecoder := TVp9Decoder.Create(VideoThreadCount);
end;

destructor TVp9MediaDecoder.Destroy;
begin
  FDecoder.Free;
  inherited Destroy;
end;

procedure TVp9MediaDecoder.Configure(Track: TMediaTrack);
begin
end;

procedure TVp9MediaDecoder.SendPacket(const Packet: TMediaPacket);
begin
  if Length(Packet.Data) = 0 then
    Exit;
  try
    TVp9Decoder(FDecoder).DecodePacket(@Packet.Data[0], Length(Packet.Data));
    FHasFrame := TVp9Decoder(FDecoder).ReceiveFrame(FFrame);
  except
    on E: Exception do
    begin
      FHasFrame := False;
      RaiseMediaError(E);
    end;
  end;
  if FHasFrame then
    FFrame.PresentationTime := Packet.PresentationTime;
end;

function TVp9MediaDecoder.ReceiveFrame(out Frame: TVideoFrame): Boolean;
begin
  Frame := Default(TVideoFrame);
  Result := FHasFrame;
  if Result then
  begin
    Frame := FFrame;
    FFrame := Default(TVideoFrame);
    FHasFrame := False;
  end;
end;

procedure TVp9MediaDecoder.Reset;
begin
  FDecoder.Free;
  FDecoder := TVp9Decoder.Create(VideoThreadCount);
  FFrame := Default(TVideoFrame);
  FHasFrame := False;
end;

procedure RegisterVideoCodecs;
begin
  RegisterVideoDecoder(codecVp8, TVp8MediaDecoder);
  RegisterVideoDecoder(codecVp9, TVp9MediaDecoder);
end;

initialization
  RegisterVideoCodecs;
end.
