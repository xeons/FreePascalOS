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
  Streaming decoders: bytes in any number of pieces in, UTF-8 out (what
  the DOM keeps text in). A decoder keeps the state of a sequence split
  between pieces; errors become U+FFFD (the "replacement" error mode) and
  are counted, so a "fatal" caller checks ErrorCount. The byte order mark
  is not the decoder's business: see Web.Encoding.Sniffing.
}
unit Web.Encoding.Decoders;

{$mode objfpc}
{$H+}

interface

uses
  Web.TextBuffers,
  Web.Encoding.Labels;

const
  ReplacementCharacter = $FFFD;

type
  TTextDecoder = class
  protected
    FEncoding: TTextEncoding;
    FErrorCount: SizeInt;
    procedure EmitError(Output: TTextBuffer); inline;
  public
    constructor Create(DecodedEncoding: TTextEncoding); virtual;
    { Decodes Count bytes, appending the text to Output. Flush marks the
      end of the stream: an unfinished sequence becomes U+FFFD. }
    procedure Decode(Input: PByte; Count: SizeInt; Output: TTextBuffer; Flush: Boolean); virtual; abstract;
    { Forgets an unfinished sequence. }
    procedure Reset; virtual;
    function DecodeAll(const Bytes: string): string;
    property Encoding: TTextEncoding read FEncoding;
    property ErrorCount: SizeInt read FErrorCount;
  end;

  TTextDecoderClass = class of TTextDecoder;

implementation

constructor TTextDecoder.Create(DecodedEncoding: TTextEncoding);
begin
  inherited Create;
  FEncoding := DecodedEncoding;
end;

procedure TTextDecoder.EmitError(Output: TTextBuffer);
begin
  Inc(FErrorCount);
  Output.AppendCodePoint(ReplacementCharacter);
end;

procedure TTextDecoder.Reset;
begin
end;

function TTextDecoder.DecodeAll(const Bytes: string): string;
var
  Output: TTextBuffer;
begin
  Output := TTextBuffer.Create;
  try
    Decode(PByte(PChar(Bytes)), Length(Bytes), Output, True);
    Result := Output.TakeText;
  finally
    Output.Free;
  end;
end;

end.
