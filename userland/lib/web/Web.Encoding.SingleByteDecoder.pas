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
  The single-byte decoders (IBM866, ISO-8859-*, KOI8-*, macintosh,
  windows-*, x-mac-cyrillic: tables generated from
  data/single-byte-indexes.txt), x-user-defined, and the replacement
  decoder (one U+FFFD for the whole stream, for encodings that are unsafe
  to decode at all).
}
unit Web.Encoding.SingleByteDecoder;

{$mode objfpc}
{$H+}

interface

uses
  Web.TextBuffers,
  Web.Encoding.Labels,
  Web.Encoding.Decoders;

{$I Web.Encoding.SingleByteTables.inc}

type
  TSingleByteDecoder = class(TTextDecoder)
  private
    FIndex: Integer;
  public
    constructor Create(DecodedEncoding: TTextEncoding); override;
    procedure Decode(Input: PByte; Count: SizeInt; Output: TTextBuffer; Flush: Boolean); override;
  end;

  TUserDefinedDecoder = class(TTextDecoder)
  public
    procedure Decode(Input: PByte; Count: SizeInt; Output: TTextBuffer; Flush: Boolean); override;
  end;

  TReplacementDecoder = class(TTextDecoder)
  private
    FErrorReturned: Boolean;
  public
    procedure Decode(Input: PByte; Count: SizeInt; Output: TTextBuffer; Flush: Boolean); override;
    procedure Reset; override;
  end;

implementation

constructor TSingleByteDecoder.Create(DecodedEncoding: TTextEncoding);
begin
  inherited Create(DecodedEncoding);
  FIndex := SingleByteIndexOf[DecodedEncoding];
end;

procedure TSingleByteDecoder.Decode(Input: PByte; Count: SizeInt; Output: TTextBuffer; Flush: Boolean);
var
  Position, RunStart: SizeInt;
  CodePoint: Word;
begin
  Position := 0;
  while Position < Count do
  begin
    if Input[Position] < $80 then
    begin
      RunStart := Position;
      while (Position < Count) and (Input[Position] < $80) do
        Inc(Position);
      Output.Append(PChar(Input) + RunStart, Position - RunStart);
      Continue;
    end;
    CodePoint := SingleByteIndexes[FIndex, Input[Position] - $80];
    if CodePoint = 0 then
      EmitError(Output)
    else
      Output.AppendCodePoint(CodePoint);
    Inc(Position);
  end;
end;

procedure TUserDefinedDecoder.Decode(Input: PByte; Count: SizeInt; Output: TTextBuffer; Flush: Boolean);
var
  Position: SizeInt;
begin
  Position := 0;
  while Position < Count do
  begin
    if Input[Position] < $80 then
      Output.AppendChar(Chr(Input[Position]))
    else
      Output.AppendCodePoint($F780 + Input[Position] - $80);
    Inc(Position);
  end;
end;

procedure TReplacementDecoder.Decode(Input: PByte; Count: SizeInt; Output: TTextBuffer; Flush: Boolean);
begin
  if (Count > 0) and not FErrorReturned then
  begin
    FErrorReturned := True;
    EmitError(Output);
  end;
end;

procedure TReplacementDecoder.Reset;
begin
  FErrorReturned := False;
end;

end.
