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
  ISO base media files (MP4), plain and fragmented: placeholder until the reader is written.
}
unit Media.Mp4;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Packets,
  Media.Demuxers;

type
  TMp4Demuxer = class(TMediaDemuxer)
  public
    procedure Open; override;
    function ReadPacket(out Packet: TMediaPacket): Boolean; override;
    function FormatName: string; override;
  end;

implementation

uses
  Media.Errors;

procedure TMp4Demuxer.Open;
begin
  MediaFailUnsupported('mp4 is not read yet');
end;

function TMp4Demuxer.ReadPacket(out Packet: TMediaPacket): Boolean;
begin
  Packet := NewPacket(0);
  Result := False;
end;

function TMp4Demuxer.FormatName: string;
begin
  Result := 'mp4';
end;

end.
