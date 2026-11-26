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
  Ogg (RFC 3533) with Vorbis, Opus and FLAC streams: placeholder until the reader is written.
}
unit Media.Ogg;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Packets,
  Media.Demuxers;

type
  TOggDemuxer = class(TMediaDemuxer)
  public
    procedure Open; override;
    function ReadPacket(out Packet: TMediaPacket): Boolean; override;
    function FormatName: string; override;
  end;

implementation

uses
  Media.Errors;

procedure TOggDemuxer.Open;
begin
  MediaFailUnsupported('ogg is not read yet');
end;

function TOggDemuxer.ReadPacket(out Packet: TMediaPacket): Boolean;
begin
  Packet := NewPacket(0);
  Result := False;
end;

function TOggDemuxer.FormatName: string;
begin
  Result := 'ogg';
end;

end.
