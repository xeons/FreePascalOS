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

  This file follows the Opus reference decoder (RFC 6716, libopus 1.5.2),
  which carries this notice:

  Copyright (c) 2001-2011 Xiph.Org, Skype Limited, Octasic,
                          Jean-Marc Valin, Timothy B. Terriberry,
                          CSIRO, Gregory Maxwell, Mark Borgerding,
                          Erik de Castro Lopo

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions
  are met:
  - Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
  - Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.
  - Neither the name of Internet Society, IETF or IETF Trust, nor the
    names of specific contributors, may be used to endorse or promote
    products derived from this software without specific prior written
    permission.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
  A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
  OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
}

{
  The Opus range decoder (RFC 6716 section 4.1): symbols by frequency
  counts and inverse CDF tables, raw bits from the end of the frame,
  uniform integers, the Laplace-distributed CELT energy deltas, and the
  bit counts (Tell, TellFraction) both SILK and CELT budget with.
}
unit Media.Opus.RangeDecoder;

{$mode objfpc}
{$H+}
{$pointermath on}
{ The coder works modulo 2^32 like the reference's unsigned arithmetic:
  range and overflow checks are off in this unit. }
{$R-}
{$Q-}

interface

const
  BitResolution = 3;

type
  TOpusRangeDecoder = class
  private
    FBuffer: PByte;
    FStorage: LongWord;
    FEndOffset: LongWord;
    FEndWindow: LongWord;
    FEndBits: Integer;
    FTotalBits: Integer;
    FOffset: LongWord;
    FRange: LongWord;
    FValue: LongWord;
    FScale: LongWord;
    FRemainder: Integer;
    FError: Boolean;
    function ReadByte: Integer; inline;
    function ReadByteFromEnd: Integer; inline;
    procedure Normalize;
  public
    procedure Init(Buffer: PByte; Size: LongWord);
    { The frequency of the next symbol out of Total; Update must follow. }
    function Decode(Total: LongWord): LongWord;
    function DecodeBinary(Bits: Integer): LongWord;
    procedure Update(Low, High, Total: LongWord);
    function DecodeBitLogP(LogP: Integer): Boolean;
    function DecodeIcdf(Icdf: PByte; Bits: Integer): Integer;
    function DecodeIcdf16(Icdf: PWord; Bits: Integer): Integer;
    function DecodeUInt(Total: LongWord): LongWord;
    function DecodeBits(Bits: Integer): LongWord;
    function DecodeLaplace(Frequency: LongWord; Decay: Integer): Integer;
    { Whole bits used so far (rounded up). }
    function Tell: Integer; inline;
    { Bits used so far in 1/8 bits. }
    function TellFraction: LongWord;
    { Shortens the frame (CELT in hybrid mode, after redundancy). }
    procedure SetStorage(Size: LongWord);
    property Range: LongWord read FRange;
    property Storage: LongWord read FStorage;
    property Error: Boolean read FError write FError;
    property TotalBits: Integer read FTotalBits write FTotalBits;
  end;

{ The number of significant bits of Value (0 for 0). }
function IntegerLog(Value: LongWord): Integer; inline;

implementation

const
  SymbolBits = 8;
  CodeBits = 32;
  SymbolMaximum = 255;
  CodeTop = LongWord(1) shl (CodeBits - 1);
  CodeBottom = CodeTop shr SymbolBits;
  CodeExtra = (CodeBits - 2) mod SymbolBits + 1;
  WindowSize = 32;
  UIntBits = 8;
  LaplaceMinimumProbability = 1;
  LaplaceMinimumCount = 16;

function IntegerLog(Value: LongWord): Integer;
begin
  if Value = 0 then
    Result := 0
  else
    Result := BsrDWord(Value) + 1;
end;

function TOpusRangeDecoder.ReadByte: Integer;
begin
  if FOffset < FStorage then
  begin
    Result := FBuffer[FOffset];
    Inc(FOffset);
  end
  else
    Result := 0;
end;

function TOpusRangeDecoder.ReadByteFromEnd: Integer;
begin
  if FEndOffset < FStorage then
  begin
    Inc(FEndOffset);
    Result := FBuffer[FStorage - FEndOffset];
  end
  else
    Result := 0;
end;

procedure TOpusRangeDecoder.Normalize;
var
  Symbol: Integer;
begin
  while FRange <= CodeBottom do
  begin
    Inc(FTotalBits, SymbolBits);
    FRange := FRange shl SymbolBits;
    Symbol := FRemainder;
    FRemainder := ReadByte;
    Symbol := ((Symbol shl SymbolBits) or FRemainder) shr (SymbolBits - CodeExtra);
    FValue := ((FValue shl SymbolBits) + (SymbolMaximum and not LongWord(Symbol))) and (CodeTop - 1);
  end;
end;

procedure TOpusRangeDecoder.Init(Buffer: PByte; Size: LongWord);
begin
  FBuffer := Buffer;
  FStorage := Size;
  FEndOffset := 0;
  FEndWindow := 0;
  FEndBits := 0;
  FTotalBits := CodeBits + 1 - ((CodeBits - CodeExtra) div SymbolBits) * SymbolBits;
  FOffset := 0;
  FRange := LongWord(1) shl CodeExtra;
  FRemainder := ReadByte;
  FValue := FRange - 1 - LongWord(FRemainder shr (SymbolBits - CodeExtra));
  FError := False;
  Normalize;
end;

function TOpusRangeDecoder.Decode(Total: LongWord): LongWord;
var
  Symbol: LongWord;
begin
  FScale := FRange div Total;
  Symbol := FValue div FScale;
  if Symbol + 1 < Total then
    Result := Total - (Symbol + 1)
  else
    Result := 0;
end;

function TOpusRangeDecoder.DecodeBinary(Bits: Integer): LongWord;
var
  Symbol, Total: LongWord;
begin
  FScale := FRange shr Bits;
  Symbol := FValue div FScale;
  Total := LongWord(1) shl Bits;
  if Symbol + 1 < Total then
    Result := Total - (Symbol + 1)
  else
    Result := 0;
end;

procedure TOpusRangeDecoder.Update(Low, High, Total: LongWord);
var
  Step: LongWord;
begin
  Step := FScale * (Total - High);
  FValue := FValue - Step;
  if Low > 0 then
    FRange := FScale * (High - Low)
  else
    FRange := FRange - Step;
  Normalize;
end;

function TOpusRangeDecoder.DecodeBitLogP(LogP: Integer): Boolean;
var
  Threshold: LongWord;
begin
  Threshold := FRange shr LogP;
  Result := FValue < Threshold;
  if Result then
    FRange := Threshold
  else
  begin
    FValue := FValue - Threshold;
    FRange := FRange - Threshold;
  end;
  Normalize;
end;

function TOpusRangeDecoder.DecodeIcdf(Icdf: PByte; Bits: Integer): Integer;
var
  Scale, Value, Low, Previous: LongWord;
begin
  Low := FRange;
  Value := FValue;
  Scale := FRange shr Bits;
  Result := -1;
  repeat
    Previous := Low;
    Inc(Result);
    Low := Scale * Icdf[Result];
  until Value >= Low;
  FValue := Value - Low;
  FRange := Previous - Low;
  Normalize;
end;

function TOpusRangeDecoder.DecodeIcdf16(Icdf: PWord; Bits: Integer): Integer;
var
  Scale, Value, Low, Previous: LongWord;
begin
  Low := FRange;
  Value := FValue;
  Scale := FRange shr Bits;
  Result := -1;
  repeat
    Previous := Low;
    Inc(Result);
    Low := Scale * Icdf[Result];
  until Value >= Low;
  FValue := Value - Low;
  FRange := Previous - Low;
  Normalize;
end;

function TOpusRangeDecoder.DecodeUInt(Total: LongWord): LongWord;
var
  TopBits, Symbol, Count: LongWord;
  ExtraBits: Integer;
  Value: LongWord;
begin
  Dec(Total);
  ExtraBits := IntegerLog(Total);
  if ExtraBits > UIntBits then
  begin
    Dec(ExtraBits, UIntBits);
    Count := (Total shr ExtraBits) + 1;
    Symbol := Decode(Count);
    Update(Symbol, Symbol + 1, Count);
    Value := (Symbol shl ExtraBits) or DecodeBits(ExtraBits);
    if Value <= Total then
      Exit(Value);
    FError := True;
    Exit(Total);
  end;
  TopBits := Total + 1;
  Symbol := Decode(TopBits);
  Update(Symbol, Symbol + 1, TopBits);
  Result := Symbol;
end;

function TOpusRangeDecoder.DecodeBits(Bits: Integer): LongWord;
var
  Window: LongWord;
  Available: Integer;
begin
  Window := FEndWindow;
  Available := FEndBits;
  if Available < Bits then
    repeat
      Window := Window or (LongWord(ReadByteFromEnd) shl Available);
      Inc(Available, SymbolBits);
    until Available > WindowSize - SymbolBits;
  if Bits >= 32 then
    Result := Window
  else
    Result := Window and ((LongWord(1) shl Bits) - 1);
  if Bits >= 32 then
    Window := 0
  else
    Window := Window shr Bits;
  Dec(Available, Bits);
  FEndWindow := Window;
  FEndBits := Available;
  Inc(FTotalBits, Bits);
end;

function LaplaceFirstFrequency(FirstSymbolFrequency: LongWord; Decay: Integer): LongWord; inline;
var
  Total: LongWord;
begin
  Total := 32768 - LaplaceMinimumProbability * (2 * LaplaceMinimumCount) - FirstSymbolFrequency;
  Result := (Total * LongWord(16384 - Decay)) shr 15;
end;

function TOpusRangeDecoder.DecodeLaplace(Frequency: LongWord; Decay: Integer): Integer;
var
  Value: Integer;
  Low, Middle, Steps: LongWord;
  High: LongWord;
begin
  Value := 0;
  Middle := DecodeBinary(15);
  Low := 0;
  if Middle >= Frequency then
  begin
    Inc(Value);
    Low := Frequency;
    Frequency := LaplaceFirstFrequency(Frequency, Decay) + LaplaceMinimumProbability;
    while (Frequency > LaplaceMinimumProbability) and (Middle >= Low + 2 * Frequency) do
    begin
      Frequency := Frequency * 2;
      Inc(Low, Frequency);
      Frequency := ((Frequency - 2 * LaplaceMinimumProbability) * LongWord(Decay)) shr 15;
      Inc(Frequency, LaplaceMinimumProbability);
      Inc(Value);
    end;
    if Frequency <= LaplaceMinimumProbability then
    begin
      Steps := (Middle - Low) shr 1;
      Inc(Value, Integer(Steps));
      Inc(Low, 2 * Steps * LaplaceMinimumProbability);
    end;
    if Middle < Low + Frequency then
      Value := -Value
    else
      Inc(Low, Frequency);
  end;
  High := Low + Frequency;
  if High > 32768 then
    High := 32768;
  Update(Low, High, 32768);
  Result := Value;
end;

function TOpusRangeDecoder.Tell: Integer;
begin
  Result := FTotalBits - IntegerLog(FRange);
end;

function TOpusRangeDecoder.TellFraction: LongWord;
const
  Correction: array[0..7] of LongWord = (35733, 38967, 42495, 46340, 50535, 55109, 60097, 65535);
var
  Bits, Normalized, Step: LongWord;
  Log: Integer;
begin
  Bits := LongWord(FTotalBits) shl BitResolution;
  Log := IntegerLog(FRange);
  Normalized := FRange shr (Log - 16);
  Step := (Normalized shr 12) - 8;
  if Normalized > Correction[Step] then
    Inc(Step);
  Result := Bits - LongWord((Log shl 3) + Integer(Step));
end;

procedure TOpusRangeDecoder.SetStorage(Size: LongWord);
begin
  FStorage := Size;
end;

end.
