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
  The shared UTF-16 decoder of the Encoding Standard, for UTF-16BE and
  UTF-16LE: a lone surrogate becomes U+FFFD, and the code unit after an
  unpaired lead surrogate is looked at again.
}
unit Web.Encoding.Utf16Decoder;

{$mode objfpc}
{$H+}

interface

uses
  Web.TextBuffers,
  Web.Encoding.Labels,
  Web.Encoding.Decoders;

type
  TUtf16Decoder = class(TTextDecoder)
  private
    FBigEndian: Boolean;
    FLeadByte: Integer;
    FLeadSurrogate: Integer;
  public
    constructor Create(DecodedEncoding: TTextEncoding); override;
    procedure Decode(Input: PByte; Count: SizeInt; Output: TTextBuffer; Flush: Boolean); override;
    procedure Reset; override;
  end;

implementation

constructor TUtf16Decoder.Create(DecodedEncoding: TTextEncoding);
begin
  inherited Create(DecodedEncoding);
  FBigEndian := DecodedEncoding = TextEncodingUtf16Be;
  Reset;
end;

procedure TUtf16Decoder.Reset;
begin
  FLeadByte := -1;
  FLeadSurrogate := -1;
end;

procedure TUtf16Decoder.Decode(Input: PByte; Count: SizeInt; Output: TTextBuffer; Flush: Boolean);
var
  Position: SizeInt;
  CodeUnit, Lead: LongWord;
begin
  Position := 0;
  while Position < Count do
  begin
    if FLeadByte < 0 then
    begin
      FLeadByte := Input[Position];
      Inc(Position);
      Continue;
    end;
    if FBigEndian then
      CodeUnit := (LongWord(FLeadByte) shl 8) or Input[Position]
    else
      CodeUnit := (LongWord(Input[Position]) shl 8) or LongWord(FLeadByte);
    FLeadByte := -1;
    Inc(Position);
    if FLeadSurrogate >= 0 then
    begin
      Lead := FLeadSurrogate;
      FLeadSurrogate := -1;
      if (CodeUnit >= $DC00) and (CodeUnit <= $DFFF) then
      begin
        Output.AppendCodePoint($10000 + ((Lead - $D800) shl 10) + (CodeUnit - $DC00));
        Continue;
      end;
      { The unpaired lead is an error; the code unit is taken afresh. }
      EmitError(Output);
    end;
    if (CodeUnit >= $D800) and (CodeUnit <= $DBFF) then
      FLeadSurrogate := CodeUnit
    else if (CodeUnit >= $DC00) and (CodeUnit <= $DFFF) then
      EmitError(Output)
    else
      Output.AppendCodePoint(CodeUnit);
  end;
  if Flush and ((FLeadByte >= 0) or (FLeadSurrogate >= 0)) then
  begin
    Reset;
    EmitError(Output);
  end;
end;

end.
