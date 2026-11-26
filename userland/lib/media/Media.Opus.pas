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
  The Opus (RFC 6716) decoder: placeholder until it is written.
}
unit Media.Opus;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Frames,
  Media.Packets,
  Media.AudioDecoders;

type
  TOpusDecoder = class(TAudioDecoder)
  public
    procedure Configure(Track: TMediaTrack); override;
    function Decode(const Packet: TMediaPacket; var Output: TAudioBuffer): Boolean; override;
  end;

implementation

uses
  Media.Errors;

procedure TOpusDecoder.Configure(Track: TMediaTrack);
begin
  MediaFailUnsupported('Opus (RFC 6716) is not decoded yet');
end;

function TOpusDecoder.Decode(const Packet: TMediaPacket; var Output: TAudioBuffer): Boolean;
begin
  Result := False;
end;

end.
