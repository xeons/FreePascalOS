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
  Where a response body goes as it arrives: TOutputSink writes it into
  the output file (or standard output), a libhttp sink, so libhttp's
  decoders (Http.ContentDecoding: gzip, x-gzip, deflate) can stand in
  front of it. A failed write keeps the system's error code
  (ErrorCode).
}
unit Wget.Sinks;

{$mode objfpc}
{$H+}

interface

uses
  Http.BodySinks,
  Wget.Files;

type
  TOutputSink = class(THttpBodySink)
  private
    FTarget: ^TOutputTarget;
  public
    constructor Create(var Target: TOutputTarget);
    function Write(Data: Pointer; Count: PtrUInt): Boolean; override;
  end;

{ True for a Content-Encoding wget decodes. }
function EncodingCanBeDecoded(const Encoding: string): Boolean;

implementation

uses
  Abi.SystemCalls,
  Http.ContentDecoding;

function EncodingCanBeDecoded(const Encoding: string): Boolean;
begin
  Result := ContentCodingOf(Encoding) in [CodingGzip, CodingDeflate];
end;

constructor TOutputSink.Create(var Target: TOutputTarget);
begin
  inherited Create;
  FTarget := @Target;
end;

function TOutputSink.Write(Data: Pointer; Count: PtrUInt): Boolean;
begin
  FErrorCode := WriteOutput(FTarget^, Data, Count);
  Result := FErrorCode = ErrorNone;
  if Result then
    Inc(FWritten, Count);
end;

end.
