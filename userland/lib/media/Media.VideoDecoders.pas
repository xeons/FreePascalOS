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
  The video decoder: what a video codec library (libvideo for VP8 and
  VP9, libav1) offers libmedia's users.

  Video decoders live in libraries of their own, so they are found
  through a registry: a library's unit calls RegisterVideoDecoder for
  each codec it decodes (in its initialization, or the program does it),
  and CreateVideoDecoder makes one for a track's codec.

  SendPacket gives the decoder a packet (a temporal unit, a superframe);
  ReceiveFrame then gives the frames it finished, in presentation order,
  until it has no more for now. Flush (at the end of the stream) makes the
  frames it still holds available; Reset forgets everything, for a seek.
}
unit Media.VideoDecoders;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Frames,
  Media.Packets;

type
  TVideoDecoder = class
  public
    constructor Create; virtual;
    procedure Configure(Track: TMediaTrack); virtual; abstract;
    procedure SendPacket(const Packet: TMediaPacket); virtual; abstract;
    function ReceiveFrame(out Frame: TVideoFrame): Boolean; virtual; abstract;
    procedure Flush; virtual;
    procedure Reset; virtual;
  end;

  TVideoDecoderClass = class of TVideoDecoder;

procedure RegisterVideoDecoder(Codec: TCodecId; DecoderClass: TVideoDecoderClass);
{ A new decoder for Codec, or nil if none is registered. }
function CreateVideoDecoder(Codec: TCodecId): TVideoDecoder;
function VideoDecoderRegistered(Codec: TCodecId): Boolean;

implementation

var
  RegisteredDecoders: array[TCodecId] of TVideoDecoderClass;

constructor TVideoDecoder.Create;
begin
  inherited Create;
end;

procedure TVideoDecoder.Flush;
begin
end;

procedure TVideoDecoder.Reset;
begin
end;

procedure RegisterVideoDecoder(Codec: TCodecId; DecoderClass: TVideoDecoderClass);
begin
  RegisteredDecoders[Codec] := DecoderClass;
end;

function CreateVideoDecoder(Codec: TCodecId): TVideoDecoder;
begin
  if RegisteredDecoders[Codec] = nil then
    Result := nil
  else
    Result := RegisteredDecoders[Codec].Create;
end;

function VideoDecoderRegistered(Codec: TCodecId): Boolean;
begin
  Result := RegisteredDecoders[Codec] <> nil;
end;

end.
