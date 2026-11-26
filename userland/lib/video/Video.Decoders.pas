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
  libvideo's decoders behind one interface: packets (as a container
  holds them) go in, pictures to show come out in order, each with the
  timestamp of the packet it came from.

  A VP9 packet may hold several frames (a superframe) and an alternate
  reference frame shows nothing, so a packet gives zero or more
  pictures; ReceiveFrame takes them until there are no more.
}
unit Video.Decoders;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils, Media.Frames;

type
  EVideoDecodeError = class(Exception);

  TVideoDecoder = class
  private
    FFrames: array of TVideoFrame;
    FFirst: LongInt;
  protected
    procedure Deliver(const Frame: TVideoFrame);
    procedure DecodePacket(Data: PByte; Size: PtrInt; Timestamp: Int64); virtual; abstract;
  public
    { Decodes a packet; raises EVideoDecodeError when it cannot be
      decoded. }
    procedure Decode(Data: PByte; Size: PtrInt; Timestamp: Int64);
    { The next picture to show, if any. }
    function ReceiveFrame(out Frame: TVideoFrame): Boolean;
  end;

{ A decoder for Codec: a four character code ('VP80', 'VP90') or a
  Matroska codec identifier ('V_VP8', 'V_VP9') or an ISO sample entry
  ('vp08', 'vp09'). nil when libvideo does not know the codec.
  ThreadCount 0 means one thread per processor. }
function CreateVideoDecoder(const Codec: string; ThreadCount: LongInt = 0): TVideoDecoder;

implementation

uses
  Vp8.FrameHeader, Vp8.Decoder, Vp9.Decoder;

type
  TVp8VideoDecoder = class(TVideoDecoder)
  private
    FDecoder: TVp8Decoder;
  protected
    procedure DecodePacket(Data: PByte; Size: PtrInt; Timestamp: Int64); override;
  public
    constructor Create(ThreadCount: LongInt);
    destructor Destroy; override;
  end;

  TVp9VideoDecoder = class(TVideoDecoder)
  private
    FDecoder: TVp9Decoder;
  protected
    procedure DecodePacket(Data: PByte; Size: PtrInt; Timestamp: Int64); override;
  public
    constructor Create(ThreadCount: LongInt);
    destructor Destroy; override;
  end;

procedure TVideoDecoder.Deliver(const Frame: TVideoFrame);
begin
  SetLength(FFrames, Length(FFrames) + 1);
  FFrames[High(FFrames)] := Frame;
end;

procedure TVideoDecoder.Decode(Data: PByte; Size: PtrInt; Timestamp: Int64);
begin
  try
    DecodePacket(Data, Size, Timestamp);
  except
    on E: EVideoDecodeError do
      raise;
    on E: Exception do
      raise EVideoDecodeError.Create(E.Message);
  end;
end;

function TVideoDecoder.ReceiveFrame(out Frame: TVideoFrame): Boolean;
begin
  Frame := Default(TVideoFrame);
  if FFirst >= Length(FFrames) then
  begin
    FFrames := nil;
    FFirst := 0;
    Exit(False);
  end;
  Frame := FFrames[FFirst];
  FFrames[FFirst] := Default(TVideoFrame);
  Inc(FFirst);
  Result := True;
end;

constructor TVp8VideoDecoder.Create(ThreadCount: LongInt);
begin
  inherited Create;
  FDecoder := TVp8Decoder.Create(ThreadCount);
end;

destructor TVp8VideoDecoder.Destroy;
begin
  FDecoder.Free;
  inherited Destroy;
end;

procedure TVp8VideoDecoder.DecodePacket(Data: PByte; Size: PtrInt; Timestamp: Int64);
var
  Frame: TVideoFrame;
begin
  if FDecoder.DecodeFrame(Data, Size, Frame) then
  begin
    Frame.PresentationTime := Timestamp;
    Deliver(Frame);
  end;
end;

constructor TVp9VideoDecoder.Create(ThreadCount: LongInt);
begin
  inherited Create;
  FDecoder := TVp9Decoder.Create(ThreadCount);
end;

destructor TVp9VideoDecoder.Destroy;
begin
  FDecoder.Free;
  inherited Destroy;
end;

procedure TVp9VideoDecoder.DecodePacket(Data: PByte; Size: PtrInt; Timestamp: Int64);
var
  Frame: TVideoFrame;
begin
  FDecoder.DecodePacket(Data, Size);
  while FDecoder.ReceiveFrame(Frame) do
  begin
    Frame.PresentationTime := Timestamp;
    Deliver(Frame);
  end;
end;

function CreateVideoDecoder(const Codec: string; ThreadCount: LongInt): TVideoDecoder;
var
  Name: string;
begin
  Name := LowerCase(Codec);
  if (Name = 'vp80') or (Name = 'v_vp8') or (Name = 'vp08') or (Name = 'vp8') then
    Result := TVp8VideoDecoder.Create(ThreadCount)
  else if (Name = 'vp90') or (Name = 'v_vp9') or (Name = 'vp09') or (Name = 'vp9') then
    Result := TVp9VideoDecoder.Create(ThreadCount)
  else
    Result := nil;
end;

end.
