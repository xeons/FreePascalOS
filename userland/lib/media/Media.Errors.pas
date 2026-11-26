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
  The errors of the media library: a malformed file or stream raises
  EMediaError (a container or a decoder that cannot go on);
  EMediaUnsupported is the kind for a valid file using something this
  library does not decode.
}
unit Media.Errors;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  EMediaError = class(Exception);
  EMediaUnsupported = class(EMediaError);

procedure MediaFail(const Message: string);
procedure MediaFailUnsupported(const Message: string);

implementation

procedure MediaFail(const Message: string);
begin
  raise EMediaError.Create(Message);
end;

procedure MediaFailUnsupported(const Message: string);
begin
  raise EMediaUnsupported.Create(Message);
end;

end.
