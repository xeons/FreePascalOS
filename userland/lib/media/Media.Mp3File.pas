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
  MPEG audio elementary streams (.mp3) with ID3 tags: placeholder until the reader is written.
}
unit Media.Mp3File;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Packets,
  Media.Demuxers;

type
  TMp3Demuxer = class(TMediaDemuxer)
  public
    procedure Open; override;
    function ReadPacket(out Packet: TMediaPacket): Boolean; override;
    function FormatName: string; override;
  end;

implementation

uses
  Media.Errors;

procedure TMp3Demuxer.Open;
begin
  MediaFailUnsupported('mp3 is not read yet');
end;

function TMp3Demuxer.ReadPacket(out Packet: TMediaPacket): Boolean;
begin
  Packet := NewPacket(0);
  Result := False;
end;

function TMp3Demuxer.FormatName: string;
begin
  Result := 'mp3';
end;

end.
