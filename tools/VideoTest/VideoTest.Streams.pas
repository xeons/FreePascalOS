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
  Decoding a test stream: reading an IVF file, decoding every packet
  with libvideo's decoder for its codec, and the MD5 of each picture
  shown, computed as the reference tools compute it (each plane's
  visible rows, samples of more than 8 bits as 2 bytes little-endian).
}
unit VideoTest.Streams;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils, Classes, Media.Frames, Media.Packets, Media.VideoDecoders;

type
  TStringArray = array of string;

function LoadFile(const Name: string): TBytes;
{ A decoder (libmedia's interface) for an IVF four character code, with
  ThreadCount threads; nil for another codec. }
function CreateIvfDecoder(const FourCC: string; ThreadCount: LongInt): TVideoDecoder;
{ A packet holding Data with timestamp Time. }
function MakePacket(const Data: TBytes; Time: Int64): TMediaPacket;
function FrameMd5(const Frame: TVideoFrame): string;
{ The MD5s of the pictures decoding the IVF file Name gives, with
  ThreadCount threads; raises what the decoder raises. }
function DecodeStream(const Data: TBytes; ThreadCount: LongInt): TStringArray;
{ The MD5s of a reference file ('md5  name' lines). }
function ReadExpected(const Name: string): TStringArray;

implementation

uses
  md5, Video.Ivf, Video.MediaDecoders;

function CreateIvfDecoder(const FourCC: string; ThreadCount: LongInt): TVideoDecoder;
begin
  VideoThreadCount := ThreadCount;
  if FourCC = 'VP80' then
    Result := CreateVideoDecoder(codecVp8)
  else if FourCC = 'VP90' then
    Result := CreateVideoDecoder(codecVp9)
  else
    Result := nil;
end;

function MakePacket(const Data: TBytes; Time: Int64): TMediaPacket;
begin
  Result := NewPacket(0);
  Result.Data := Data;
  Result.PresentationTime := Time;
end;

function LoadFile(const Name: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  Stream := TFileStream.Create(Name, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function FrameMd5(const Frame: TVideoFrame): string;
var
  Context: TMD5Context;
  Digest: TMD5Digest;
  Plane, Row, BytesPerSample: LongInt;
begin
  MD5Init(Context);
  if Frame.BitDepth > 8 then
    BytesPerSample := 2
  else
    BytesPerSample := 1;
  for Plane := 0 to 2 do
    for Row := 0 to Frame.Planes[Plane].Height - 1 do
      MD5Update(Context, Frame.Planes[Plane].Data[Row * Frame.Planes[Plane].Stride],
        Frame.Planes[Plane].Width * BytesPerSample);
  MD5Final(Context, Digest);
  Result := MD5Print(Digest);
end;

function DecodeStream(const Data: TBytes; ThreadCount: LongInt): TStringArray;
var
  Reader: TIvfReader;
  Decoder: TVideoDecoder;
  Packet: TIvfFrame;
  Frame: TVideoFrame;
begin
  Result := nil;
  Reader := TIvfReader.Create(Data);
  Decoder := nil;
  try
    Decoder := CreateIvfDecoder(Reader.FourCC, ThreadCount);
    { Some old VP8 files have another code (vpxdec looks at the data):
      a VP8 key frame has the start code 9D 01 2A at byte 3. }
    if (Decoder = nil) and (Length(Data) > 32 + 12 + 6) and (Data[44 + 3] = $9D) and (Data[44 + 4] = $01) and
      (Data[44 + 5] = $2A) then
      Decoder := CreateIvfDecoder('VP80', ThreadCount);
    if Decoder = nil then
      raise Exception.Create('no decoder for ' + Reader.FourCC);
    while Reader.ReadFrame(Packet) do
    begin
      if Length(Packet.Data) = 0 then
        Continue;
      Decoder.SendPacket(MakePacket(Packet.Data, Packet.Timestamp));
      while Decoder.ReceiveFrame(Frame) do
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := FrameMd5(Frame);
      end;
    end;
  finally
    Decoder.Free;
    Reader.Free;
  end;
end;

function ReadExpected(const Name: string): TStringArray;
var
  Lines: TStringList;
  Index: LongInt;
begin
  Result := nil;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Name);
    for Index := 0 to Lines.Count - 1 do
      if Length(Lines[Index]) >= 32 then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Copy(Lines[Index], 1, 32);
      end;
  finally
    Lines.Free;
  end;
end;

end.
