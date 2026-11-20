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
  Punycode (RFC 3492): a label of Unicode code points as ASCII
  ("bücher" is "bcher-kva") and back, with the parameters IDNA uses
  (base 36, tmin 1, tmax 26, skew 38, damp 700, initial bias 72,
  initial n 128). Overflow is checked, as section 6.4 says.

  UTF-8 conversion of labels is here too (code point arrays to and
  from UTF-8 strings), since the domain code needs both.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Url.Punycode;

{$mode objfpc}
{$H+}

interface

type
  TCodePointArray = array of LongWord;

function PunycodeEncode(constref Input: TCodePointArray; out Output: string): Boolean;
function PunycodeDecode(const Input: string; out Output: TCodePointArray): Boolean;

{ UTF-8 to code points; malformed sequences become U+FFFD. }
function Utf8ToCodePoints(const Text: string): TCodePointArray;
function CodePointsToUtf8(constref CodePoints: TCodePointArray): string;

implementation

const
  Base = 36;
  TMin = 1;
  TMax = 26;
  Skew = 38;
  Damp = 700;
  InitialBias = 72;
  InitialN = 128;
  MaximumValue = High(LongWord);
  ReplacementCharacter = $FFFD;

function Adapt(Delta, NumberOfPoints: QWord; FirstTime: Boolean): QWord;
var
  K: QWord;
begin
  if FirstTime then
    Delta := Delta div Damp
  else
    Delta := Delta div 2;
  Delta := Delta + Delta div NumberOfPoints;
  K := 0;
  while Delta > ((Base - TMin) * TMax) div 2 do
  begin
    Delta := Delta div (Base - TMin);
    K := K + Base;
  end;
  Result := K + (((Base - TMin + 1) * Delta) div (Delta + Skew));
end;

function EncodeDigit(Digit: QWord): Char;
begin
  if Digit < 26 then
    Result := Chr(Ord('a') + Digit)
  else
    Result := Chr(Ord('0') + Digit - 26);
end;

function DecodeDigit(Character: Char): Integer;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0') + 26;
    'A'..'Z': Result := Ord(Character) - Ord('A');
    'a'..'z': Result := Ord(Character) - Ord('a');
  else
    Result := -1;
  end;
end;

function Threshold(K, Bias: QWord): QWord;
begin
  if K <= Bias then
    Result := TMin
  else if K >= Bias + TMax then
    Result := TMax
  else
    Result := K - Bias;
end;

function PunycodeEncode(constref Input: TCodePointArray; out Output: string): Boolean;
var
  N, Delta, Bias, H, B, M, Q, K, T: QWord;
  CodePoint: LongWord;
begin
  Output := '';
  Result := False;
  for CodePoint in Input do
    if CodePoint < $80 then
      Output := Output + Chr(CodePoint);
  B := Length(Output);
  H := B;
  if B > 0 then
    Output := Output + '-';
  N := InitialN;
  Delta := 0;
  Bias := InitialBias;
  while H < QWord(Length(Input)) do
  begin
    M := MaximumValue;
    for CodePoint in Input do
      if (CodePoint >= N) and (CodePoint < M) then
        M := CodePoint;
    if (M - N) > (MaximumValue - Delta) div (H + 1) then
      Exit;
    Delta := Delta + (M - N) * (H + 1);
    N := M;
    for CodePoint in Input do
    begin
      if CodePoint < N then
      begin
        Inc(Delta);
        if Delta > MaximumValue then
          Exit;
      end;
      if CodePoint = N then
      begin
        Q := Delta;
        K := Base;
        while True do
        begin
          T := Threshold(K, Bias);
          if Q < T then
            Break;
          Output := Output + EncodeDigit(T + (Q - T) mod (Base - T));
          Q := (Q - T) div (Base - T);
          K := K + Base;
        end;
        Output := Output + EncodeDigit(Q);
        Bias := Adapt(Delta, H + 1, H = B);
        Delta := 0;
        Inc(H);
      end;
    end;
    Inc(Delta);
    Inc(N);
  end;
  Result := True;
end;

function PunycodeDecode(const Input: string; out Output: TCodePointArray): Boolean;
var
  N, I, Bias, OldI, W, K, T, Digit: QWord;
  Basic, Index, Position, Count: Integer;
  DigitValue: Integer;
begin
  Output := nil;
  Result := False;
  Basic := 0;
  for Index := Length(Input) downto 1 do
    if Input[Index] = '-' then
    begin
      Basic := Index - 1;
      Break;
    end;
  SetLength(Output, Basic);
  for Index := 1 to Basic do
  begin
    if Ord(Input[Index]) >= $80 then
      Exit;
    Output[Index - 1] := Ord(Input[Index]);
  end;
  N := InitialN;
  I := 0;
  Bias := InitialBias;
  if Basic > 0 then
    Position := Basic + 2
  else
    Position := 1;
  while Position <= Length(Input) do
  begin
    OldI := I;
    W := 1;
    K := Base;
    while True do
    begin
      if Position > Length(Input) then
        Exit;
      DigitValue := DecodeDigit(Input[Position]);
      Inc(Position);
      if DigitValue < 0 then
        Exit;
      Digit := DigitValue;
      if Digit > (MaximumValue - I) div W then
        Exit;
      I := I + Digit * W;
      T := Threshold(K, Bias);
      if Digit < T then
        Break;
      if W > MaximumValue div (Base - T) then
        Exit;
      W := W * (Base - T);
      K := K + Base;
    end;
    Count := Length(Output) + 1;
    Bias := Adapt(I - OldI, Count, OldI = 0);
    if I div QWord(Count) > MaximumValue - N then
      Exit;
    N := N + I div QWord(Count);
    I := I mod QWord(Count);
    if (N > $10FFFF) or ((N >= $D800) and (N <= $DFFF)) or (N < $80) then
      Exit;
    Insert(LongWord(N), Output, Integer(I));
    Inc(I);
  end;
  Result := True;
end;

function Utf8ToCodePoints(const Text: string): TCodePointArray;
var
  Index, Count, Extra, Need: Integer;
  Lead: Byte;
  Value, Minimum: LongWord;
begin
  Result := nil;
  SetLength(Result, Length(Text));
  Count := 0;
  Index := 1;
  while Index <= Length(Text) do
  begin
    Lead := Ord(Text[Index]);
    Inc(Index);
    if Lead < $80 then
    begin
      Value := Lead;
      Need := 0;
      Minimum := 0;
    end
    else if (Lead and $E0) = $C0 then
    begin
      Value := Lead and $1F;
      Need := 1;
      Minimum := $80;
    end
    else if (Lead and $F0) = $E0 then
    begin
      Value := Lead and $0F;
      Need := 2;
      Minimum := $800;
    end
    else if (Lead and $F8) = $F0 then
    begin
      Value := Lead and $07;
      Need := 3;
      Minimum := $10000;
    end
    else
    begin
      Value := ReplacementCharacter;
      Need := -1;
      Minimum := 0;
    end;
    if Need > 0 then
    begin
      Extra := 0;
      while (Extra < Need) and (Index <= Length(Text)) and ((Ord(Text[Index]) and $C0) = $80) do
      begin
        Value := (Value shl 6) or (Ord(Text[Index]) and $3F);
        Inc(Index);
        Inc(Extra);
      end;
      if (Extra < Need) or (Value < Minimum) or (Value > $10FFFF) or ((Value >= $D800) and (Value <= $DFFF)) then
        Value := ReplacementCharacter;
    end;
    Result[Count] := Value;
    Inc(Count);
  end;
  SetLength(Result, Count);
end;

function CodePointsToUtf8(constref CodePoints: TCodePointArray): string;
var
  Value: LongWord;
begin
  Result := '';
  for Value in CodePoints do
    if Value < $80 then
      Result := Result + Chr(Value)
    else if Value < $800 then
      Result := Result + Chr($C0 or (Value shr 6)) + Chr($80 or (Value and $3F))
    else if Value < $10000 then
      Result := Result + Chr($E0 or (Value shr 12)) + Chr($80 or ((Value shr 6) and $3F)) +
        Chr($80 or (Value and $3F))
    else
      Result := Result + Chr($F0 or (Value shr 18)) + Chr($80 or ((Value shr 12) and $3F)) +
        Chr($80 or ((Value shr 6) and $3F)) + Chr($80 or (Value and $3F));
end;

end.
