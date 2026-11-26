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
  Damaged streams: every test stream with bytes flipped, packets cut
  short or emptied, decoded to the end. The decoder may refuse a packet
  (EMediaError) but must not read or write outside its buffers:
  range check errors, access violations and the like fail the test
  (it is built with range checks).
}
unit VideoTest.Robustness;

{$mode objfpc}
{$H+}

interface

{ Damages the streams of Directory/manifest.txt in several ways each. }
procedure CheckDamagedStreams(const Directory: string);

implementation

uses
  SysUtils, Classes, TestChecks, Media.Frames, Media.Errors, Media.VideoDecoders, Video.Ivf, VideoTest.Streams;

var
  RandomState: LongWord = 12345;

function NextRandom(Limit: LongWord): LongWord;
begin
  RandomState := LongWord((QWord(RandomState) * 1103515245 + 12345) and $FFFFFFFF);
  Result := (RandomState shr 8) mod Limit;
end;

function IsSafeFailure(const Message: string): Boolean;
begin
  Result := (Pos('ERangeError', Message) = 0) and (Pos('EAccessViolation', Message) = 0) and
    (Pos('EIntOverflow', Message) = 0) and (Pos('EDivByZero', Message) = 0) and
    (Pos('EInvalidPointer', Message) = 0) and (Pos('EOutOfMemory', Message) = 0) and
    (Pos('EInvalidOp', Message) = 0);
end;

{ Decodes Data's packets (damaged by Damage) to the end; returns '' or
  the first unsafe failure. }
function DecodeDamaged(const Data: TBytes; Damage: LongInt; ThreadCount: LongInt): string;
var
  Reader: TIvfReader;
  Decoder: TVideoDecoder;
  Packet: TIvfFrame;
  Frame: TVideoFrame;
  PacketIndex, Index, Count: LongInt;
begin
  Result := '';
  Reader := TIvfReader.Create(Data);
  Decoder := CreateIvfDecoder(Reader.FourCC, ThreadCount);
  try
    PacketIndex := 0;
    while Reader.ReadFrame(Packet) do
    begin
      if (PacketIndex > 0) and (Length(Packet.Data) > 0) then
        case Damage mod 4 of
          0:
            begin
              Count := 1 + NextRandom(8);
              for Index := 1 to Count do
                Packet.Data[NextRandom(Length(Packet.Data))] := NextRandom(256);
            end;
          1:
            SetLength(Packet.Data, NextRandom(Length(Packet.Data)) + 1);
          2:
            if NextRandom(3) = 0 then
              SetLength(Packet.Data, 0);
          3:
            for Index := 0 to Length(Packet.Data) div 64 do
              Packet.Data[NextRandom(Length(Packet.Data))] :=
                Packet.Data[NextRandom(Length(Packet.Data))] xor (1 shl NextRandom(8));
        end;
      Inc(PacketIndex);
      if Length(Packet.Data) = 0 then
        Continue;
      try
        Decoder.SendPacket(MakePacket(Packet.Data, Packet.Timestamp));
        while Decoder.ReceiveFrame(Frame) do
          FrameMd5(Frame);
      except
        on E: EMediaError do
          if not IsSafeFailure(E.Message) then
            Exit(E.Message);
        on E: Exception do
          Exit(E.ClassName + ': ' + E.Message);
      end;
    end;
  finally
    Decoder.Free;
    Reader.Free;
  end;
end;

procedure CheckDamagedStreams(const Directory: string);
var
  Manifest: TStringList;
  Index, Damage, Separator: LongInt;
  StreamName, Failure: string;
  Data: TBytes;
begin
  Manifest := TStringList.Create;
  try
    Manifest.LoadFromFile(IncludeTrailingPathDelimiter(Directory) + 'manifest.txt');
    for Index := 0 to Manifest.Count - 1 do
    begin
      Separator := Pos(' ', Trim(Manifest[Index]));
      if Separator = 0 then
        Continue;
      StreamName := Copy(Trim(Manifest[Index]), 1, Separator - 1);
      Data := LoadFile(IncludeTrailingPathDelimiter(Directory) + StreamName);
      for Damage := 0 to 7 do
      begin
        Failure := DecodeDamaged(Data, Damage, 1 + 2 * (Damage and 1));
        Check(Failure = '', Format('%s damaged (%d) refused safely', [StreamName, Damage]));
        if Failure <> '' then
          WriteLn('     ', Failure);
      end;
    end;
  finally
    Manifest.Free;
  end;
end;

end.
