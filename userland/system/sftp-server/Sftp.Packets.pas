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
  SFTP packets on standard input and output (the SSH server's pipes):
  uint32 length, then the packet (its type byte first).
}
unit Sftp.Packets;

{$mode objfpc}{$H+}

interface

const
  { Longer packets end the server (OpenSSH's sftp-server takes 256 KiB
    and a little). }
  MaximumSftpPacket = 256 * 1024 + 1024;

{ The next packet; False at end of input or for one too long. }
function ReadPacket(out Packet: string): Boolean;
{ False when the client is gone. }
function WritePacket(const Packet: string): Boolean;

implementation

uses
  Abi.SystemCalls,
  Sys.Files,
  Ssh.Wire;

function ReadExactly(Count: Integer; out Data: string): Boolean;
var
  Done: Integer;
  Got: Int64;
begin
  Data := '';
  SetLength(Data, Count);
  Done := 0;
  while Done < Count do
  begin
    Got := ReadFile(StandardInputHandle, @Data[Done + 1], Count - Done);
    if Got <= 0 then
      Exit(False);
    Done := Done + Integer(Got);
  end;
  Result := True;
end;

function ReadPacket(out Packet: string): Boolean;
var
  LengthBytes: string;
  PacketLength: LongWord;
begin
  Packet := '';
  if not ReadExactly(4, LengthBytes) then
    Exit(False);
  PacketLength := ReadBigEndian32(LengthBytes, 1);
  if (PacketLength = 0) or (PacketLength > MaximumSftpPacket) then
    Exit(False);
  Result := ReadExactly(Integer(PacketLength), Packet);
end;

function WritePacket(const Packet: string): Boolean;
var
  Framed: string;
begin
  Framed := SshString(Packet);
  Result := WriteAll(StandardOutputHandle, @Framed[1], Length(Framed)) = 0;
end;

end.
