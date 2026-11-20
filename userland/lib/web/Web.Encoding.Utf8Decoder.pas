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
  The UTF-8 decoder of the Encoding Standard. Since the output is UTF-8
  too, a well-formed sequence is copied as it is; ASCII runs are copied
  in one move. Ill-formed input becomes U+FFFD exactly where the standard
  says (one per maximal subpart), and the byte that broke a sequence is
  looked at again.
}
unit Web.Encoding.Utf8Decoder;

{$mode objfpc}
{$H+}

interface

uses
  Web.TextBuffers,
  Web.Encoding.Labels,
  Web.Encoding.Decoders;

type
  TUtf8Decoder = class(TTextDecoder)
  private
    FBytesNeeded: Integer;
    FBytesSeen: Integer;
    FLowerBoundary: Byte;
    FUpperBoundary: Byte;
    FSequence: array[0..3] of Byte;
  public
    constructor Create(DecodedEncoding: TTextEncoding); override;
    procedure Decode(Input: PByte; Count: SizeInt; Output: TTextBuffer; Flush: Boolean); override;
    procedure Reset; override;
  end;

implementation

constructor TUtf8Decoder.Create(DecodedEncoding: TTextEncoding);
begin
  inherited Create(DecodedEncoding);
  Reset;
end;

procedure TUtf8Decoder.Reset;
begin
  FBytesNeeded := 0;
  FBytesSeen := 0;
  FLowerBoundary := $80;
  FUpperBoundary := $BF;
end;

procedure TUtf8Decoder.Decode(Input: PByte; Count: SizeInt; Output: TTextBuffer; Flush: Boolean);
var
  Position, RunStart: SizeInt;
  Value: Byte;
begin
  Position := 0;
  while Position < Count do
  begin
    Value := Input[Position];
    if FBytesNeeded = 0 then
    begin
      if Value < $80 then
      begin
        RunStart := Position;
        while (Position < Count) and (Input[Position] < $80) do
          Inc(Position);
        Output.Append(PChar(Input) + RunStart, Position - RunStart);
        Continue;
      end;
      case Value of
        $C2..$DF:
          FBytesNeeded := 1;
        $E0..$EF:
          begin
            if Value = $E0 then
              FLowerBoundary := $A0;
            if Value = $ED then
              FUpperBoundary := $9F;
            FBytesNeeded := 2;
          end;
        $F0..$F4:
          begin
            if Value = $F0 then
              FLowerBoundary := $90;
            if Value = $F4 then
              FUpperBoundary := $8F;
            FBytesNeeded := 3;
          end;
      else
        EmitError(Output);
        Inc(Position);
        Continue;
      end;
      FSequence[0] := Value;
      FBytesSeen := 0;
      Inc(Position);
      Continue;
    end;
    if (Value < FLowerBoundary) or (Value > FUpperBoundary) then
    begin
      { The byte is looked at again, as the start of what follows. }
      Reset;
      EmitError(Output);
      Continue;
    end;
    FLowerBoundary := $80;
    FUpperBoundary := $BF;
    Inc(FBytesSeen);
    FSequence[FBytesSeen] := Value;
    Inc(Position);
    if FBytesSeen = FBytesNeeded then
    begin
      Output.Append(@FSequence[0], FBytesNeeded + 1);
      Reset;
    end;
  end;
  if Flush and (FBytesNeeded <> 0) then
  begin
    Reset;
    EmitError(Output);
  end;
end;

end.
